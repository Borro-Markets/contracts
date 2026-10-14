// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {BorroLib} from "../script/BorroLib.sol";
import {BorroLiquidator} from "../src/BorroLiquidator.sol";
import {BorroSetup} from "./BorroSetup.sol";

/// Runs against a fork of Robinhood Chain: BORRO_FORK_RPC=<rpc> forge test
/// Liquidations with no money in the liquidator: the seized collateral pays for the repayment.
contract BorroLiquidatorForkTest is BorroSetup {
    function _empty(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(liquidator)), 0, "nothing stays in the liquidator");
    }

    /// Opens a short for bob worth $1,500 on a $1,000 deposit: 60% of what is held, under the 62.5% limit.
    function _shortNearTheLimit(string memory sym) internal returns (address acct) {
        bytes32 id = desk[sym].marketId;
        uint256 amount = (1_500e6 * 1e20) / _price(sym);
        uint256 quote = _quote(id, amount, false);
        uint256 net = quote - (quote * OPEN_FEE_BPS) / 10_000;
        deal(address(usdg), bob, 1_000e6);
        vm.startPrank(bob);
        usdg.approve(address(short), 1_000e6);
        short.open(id, 1_000e6, amount, (net * 995) / 1000, DL);
        vm.stopPrank();
        acct = short.accountOf(bob);
    }

    function test_liquidates_a_short_after_a_jump_with_no_capital() public onFork {
        string[2] memory syms = ["MSTR", "GME"]; // one trades on Uniswap v4, one on v3
        for (uint256 i; i < 2; i++) {
            string memory sym = syms[i];
            BorroLib.Desk memory d = desk[sym];
            _lend(sym, ann, (5_000e6 * 1e20) / _price(sym));
            address acct = _shortNearTheLimit(sym);
            Position memory p = morpho.position(Id.wrap(d.marketId), acct);

            vm.prank(eve);
            vm.expectRevert(bytes("position is healthy"));
            liquidator.liquidate(d.market, acct, 0, p.borrowShares, d.marketId, 0);

            // The stock jumps 20% by its feed. Owed: $1,800. Held: about $2,500. Over the limit.
            uint256 jumped = (_price(sym) * 120) / 100;
            _setFeed(sym, jumped);
            uint256 snap = vm.snapshotState();
            vm.prank(eve);
            uint256 profit = liquidator.liquidate(d.market, acct, 0, p.borrowShares, d.marketId, 0);
            vm.revertToState(snap);
            _setFeed(sym, jumped);

            // Asking for a cent more than it pays: nothing happens.
            vm.prank(eve);
            vm.expectRevert(abi.encodeWithSelector(BorroLiquidator.TooLittle.selector, profit, profit + 1));
            liquidator.liquidate(d.market, acct, 0, p.borrowShares, d.marketId, profit + 1);

            uint256 before = usdg.balanceOf(eve);
            vm.prank(eve);
            assertEq(liquidator.liquidate(d.market, acct, 0, p.borrowShares, d.marketId, profit), profit);
            assertGt(profit, 0);
            assertEq(usdg.balanceOf(eve) - before, profit, "the caller is paid the profit");
            assertEq(morpho.position(Id.wrap(d.marketId), acct).borrowShares, 0, "the short is gone");
            assertEq(morpho.market(Id.wrap(d.marketId)).totalBorrowAssets, 0, "every share of stock came back");
            _empty(address(usdg));
            _empty(d.token);
            _empty(address(held));
            emit log_named_decimal_uint(string.concat(sym, " short liquidation paid the caller USD"), profit, 6);
        }
    }

    function test_liquidates_a_usdg_borrow_after_a_drop_with_no_capital() public onFork {
        _lendUsdg(carl, 50_000e6);
        _allocate("NVDA", 40_000e6);
        BorroLib.Desk memory d = desk["NVDA"];
        BorroLib.Loan memory l = loan["NVDA"];
        _lendAndPost("NVDA", ann, 20e18);
        uint256 price = _price("NVDA");
        uint256 borrowed = (_worth("NVDA", 20e18) * 60) / 100; // 60% of the collateral, under the 62.5% limit
        vm.prank(ann);
        morpho.borrow(l.market, borrowed, 0, ann, ann);
        Position memory p = morpho.position(Id.wrap(l.marketId), ann);

        vm.prank(eve);
        vm.expectRevert(bytes("position is healthy"));
        liquidator.liquidate(l.market, ann, 0, p.borrowShares, d.marketId, 0);

        // NVDA falls 10% by its feed: owed 60, held 90. Over the limit.
        _setFeed("NVDA", (price * 90) / 100);
        uint256 before = usdg.balanceOf(eve);
        vm.prank(eve);
        uint256 profit = liquidator.liquidate(l.market, ann, 0, p.borrowShares, d.marketId, 1);
        assertGt(profit, 0);
        assertEq(usdg.balanceOf(eve) - before, profit, "the caller is paid the profit");
        Position memory after_ = morpho.position(Id.wrap(l.marketId), ann);
        assertEq(after_.borrowShares, 0, "the loan is repaid");
        assertGt(after_.collateral, 0, "what was not seized is still hers");
        Market memory m = morpho.market(Id.wrap(l.marketId));
        assertEq(m.totalBorrowAssets, 0);
        assertGe(m.totalSupplyAssets, 40_000e6, "USDG lenders are whole");
        _empty(address(usdg));
        _empty(d.token);
        _empty(d.vault);
        emit log_named_decimal_uint("USDG liquidation paid the caller USD", profit, 6);
    }

    function test_a_usdg_loan_against_a_lent_out_stock_vault_is_liquidated_on_morpho_directly() public onFork {
        _lendUsdg(carl, 50_000e6);
        _allocate("NVDA", 40_000e6);
        BorroLib.Desk memory d = desk["NVDA"];
        BorroLib.Loan memory l = loan["NVDA"];
        _lendAndPost("NVDA", ann, 20e18);
        uint256 price = _price("NVDA");
        uint256 borrowed = (_worth("NVDA", 20e18) * 60) / 100; // 60% of the collateral, under the 62.5% limit
        vm.prank(ann);
        morpho.borrow(l.market, borrowed, 0, ann, ann);

        // Bob borrows every NVDA the vault has lent into its market: the vault is 100% lent out.
        Market memory s = morpho.market(Id.wrap(d.marketId));
        uint256 all = s.totalSupplyAssets - s.totalBorrowAssets;
        deal(address(usdg), bob, 100_000e6);
        vm.startPrank(bob);
        usdg.approve(address(short), 100_000e6);
        short.addDeposit(d.marketId, 100_000e6);
        short.borrow(d.marketId, all);
        vm.stopPrank();
        s = morpho.market(Id.wrap(d.marketId));
        assertEq(s.totalBorrowAssets, s.totalSupplyAssets, "every NVDA lent out");
        assertEq(IERC20(d.token).balanceOf(d.vault), 0, "none idle in the vault");

        // NVDA falls 10%: Ann's loan is over the limit.
        _setFeed("NVDA", (price * 90) / 100);
        Position memory p = morpho.position(Id.wrap(l.marketId), ann);

        // The capital-free liquidator cannot turn bNVDA into NVDA right now, and says so.
        vm.prank(eve);
        vm.expectPartialRevert(BorroLiquidator.CannotRedeem.selector);
        liquidator.liquidate(l.market, ann, 0, p.borrowShares, d.marketId, 0);

        // Eve brings her own USDG, liquidates on Morpho directly and receives the bNVDA.
        uint256 owed = _owedUsdg("NVDA", ann) + 1e6;
        deal(address(usdg), eve, owed);
        vm.startPrank(eve);
        usdg.approve(address(morpho), owed);
        (uint256 seized, uint256 repaid) = morpho.liquidate(l.market, ann, 0, p.borrowShares, "");
        vm.stopPrank();
        assertEq(IERC20(d.vault).balanceOf(eve), seized, "she holds the stock vault shares");
        assertEq(morpho.position(Id.wrap(l.marketId), ann).borrowShares, 0, "the loan is repaid");
        assertGe(morpho.market(Id.wrap(l.marketId)).totalSupplyAssets, 40_000e6, "USDG lenders are whole");
        assertGt(_worth("NVDA", IVaultV2(d.vault).previewRedeem(seized)), repaid, "worth more than she paid, at the feed");

        // She cannot redeem them while the vault is lent out, and can once the short is repaid.
        vm.prank(eve);
        vm.expectRevert();
        IVaultV2(d.vault).redeem(seized, eve, eve);
        address acct = short.accountOf(bob);
        deal(d.token, bob, all * 2);
        vm.startPrank(bob);
        IERC20(d.token).approve(address(morpho), type(uint256).max);
        morpho.repay(d.market, 0, morpho.position(Id.wrap(d.marketId), acct).borrowShares, acct, "");
        vm.stopPrank();
        vm.prank(eve);
        uint256 got = IVaultV2(d.vault).redeem(seized, eve, eve);
        assertEq(IERC20(d.token).balanceOf(eve), got);
        assertGt(_worth("NVDA", got), repaid, "the stock is worth more than the USDG she paid");
        emit log_named_decimal_uint("NVDA she redeemed", got, 18);
    }

    function test_liquidator_takes_only_markets_borro_lists() public onFork {
        BorroLib.Desk memory d = desk["NVDA"];
        BorroLib.Loan memory l = loan["NVDA"];
        // Look-alikes anyone can make on Morpho: the same tokens and oracle, another limit.
        MarketParams memory fakeShort = d.market;
        fakeShort.lltv = 0.77e18;
        MarketParams memory fakeUsdg = l.market;
        fakeUsdg.lltv = 0.77e18;
        vm.startPrank(eve);
        morpho.createMarket(fakeShort);
        morpho.createMarket(fakeUsdg);
        vm.expectRevert(BorroLiquidator.BadMarket.selector);
        liquidator.liquidate(fakeShort, ann, 0, 1, d.marketId, 0);
        vm.expectRevert(BorroLiquidator.BadMarket.selector);
        liquidator.liquidate(fakeUsdg, ann, 0, 1, d.marketId, 0);
        vm.stopPrank();
        assertEq(address(liquidator.router()), address(router));

        // A market the owner takes off the router's list is off the liquidator's too.
        vm.prank(owner);
        router.unlist(l.marketId);
        vm.prank(eve);
        vm.expectRevert(BorroLiquidator.BadMarket.selector);
        liquidator.liquidate(l.market, ann, 0, 1, d.marketId, 0);
    }

    function test_liquidator_refuses_a_route_for_another_stock() public onFork {
        BorroLib.Loan memory l = loan["NVDA"];
        vm.startPrank(eve);
        vm.expectRevert(BorroLiquidator.BadMarket.selector);
        liquidator.liquidate(l.market, ann, 0, 1, desk["TSLA"].marketId, 0);
        vm.expectRevert(BorroLiquidator.BadMarket.selector);
        liquidator.liquidate(desk["NVDA"].market, ann, 0, 1, desk["TSLA"].marketId, 0);
        vm.expectRevert(BorroLiquidator.NoRoute.selector);
        liquidator.liquidate(l.market, ann, 0, 1, bytes32(uint256(1)), 0);
        vm.expectRevert(BorroLiquidator.OnlyMorpho.selector);
        liquidator.onMorphoLiquidate(1, "");
        vm.stopPrank();
    }
}
