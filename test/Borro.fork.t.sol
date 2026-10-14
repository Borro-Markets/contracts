// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {BorroLib, IERC20Min} from "../script/BorroLib.sol";
import {StockList} from "../script/StockList.sol";

/// Runs against a fork of Robinhood Chain: BORRO_FORK_RPC=<rpc> forge test
/// Morpho, the price feeds, the stock tokens and USDG are the real ones. Only the people are made up.
contract BorroForkTest is Test, StockList {
    IMorpho constant morpho = IMorpho(BorroLib.MORPHO);
    address constant USDG = BorroLib.USDG;
    IVaultV2 constant held = IVaultV2(BorroLib.HELD); // the USDG lending vault whose shares are the collateral

    address owner = makeAddr("owner");
    address sink = makeAddr("sink");
    address ann = makeAddr("ann"); // lends stock
    address bob = makeAddr("bob"); // shorts
    address liq = makeAddr("liquidator");

    BorroLib.Stock[] stocks;
    mapping(string => BorroLib.Desk) desk;
    mapping(string => BorroLib.Stock) stockOf;
    bool forked;

    uint256 constant FEE = 0.1e18;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        BorroLib.Stock[] memory list = loadStocks();
        BorroLib.Terms memory t =
            BorroLib.Terms({owner: owner, feeRecipient: sink, performanceFee: FEE, salt: bytes32("test")});
        for (uint256 i; i < list.length; i++) {
            deal(list[i].token, owner, list[i].seed);
            vm.startPrank(owner);
            BorroLib.Desk memory d = BorroLib.open(list[i], t);
            vm.stopPrank();
            stocks.push(list[i]);
            desk[list[i].symbol] = d;
            stockOf[list[i].symbol] = list[i];
        }
    }

    modifier onFork() {
        if (!forked) return;
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _lend(string memory sym, address who, uint256 amount) internal returns (uint256 shares) {
        BorroLib.Desk memory d = desk[sym];
        deal(d.token, who, amount);
        vm.startPrank(who);
        IERC20Min(d.token).approve(d.vault, amount);
        shares = IVaultV2(d.vault).deposit(amount, who);
        vm.stopPrank();
    }

    function _short(string memory sym, address who, uint256 dollars, uint256 borrowAmt) internal {
        BorroLib.Desk memory d = desk[sym];
        deal(USDG, who, dollars);
        vm.startPrank(who);
        IERC20Min(USDG).approve(address(held), dollars);
        uint256 shares = held.deposit(dollars, who);
        held.approve(address(morpho), shares);
        morpho.supplyCollateral(d.market, shares, who, "");
        morpho.borrow(d.market, borrowAmt, 0, who, who);
        vm.stopPrank();
    }

    function _held(string memory sym, address who) internal view returns (uint256) {
        return morpho.position(Id.wrap(desk[sym].marketId), who).collateral;
    }

    /// Dollar price of one token, 8 decimals, as the feed reports it.
    function _feedPrice(string memory sym) internal view returns (uint256) {
        (, int256 a,,,) = AggregatorV3Interface(stockOf[sym].feed).latestRoundData();
        return uint256(a);
    }

    function _setFeedPrice(string memory sym, uint256 price) internal {
        vm.mockCall(
            stockOf[sym].feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _debt(string memory sym, address who) internal returns (uint256) {
        BorroLib.Desk memory d = desk[sym];
        morpho.accrueInterest(d.market);
        Position memory p = morpho.position(Id.wrap(d.marketId), who);
        Market memory m = morpho.market(Id.wrap(d.marketId));
        return (uint256(p.borrowShares) * (uint256(m.totalBorrowAssets) + 1)) / (uint256(m.totalBorrowShares) + 1e6) + 1;
    }

    // ------------------------------------------------------------------ setup

    function test_every_desk_opens_with_a_sane_price() public onFork {
        assertEq(stocks.length, 9);
        for (uint256 i; i < stocks.length; i++) {
            BorroLib.Stock memory s = stocks[i];
            BorroLib.Desk memory d = desk[s.symbol];
            IVaultV2 v = IVaultV2(d.vault);

            assertEq(IERC20Min(s.token).symbol(), s.symbol, "token symbol");
            assertEq(v.asset(), s.token, "vault asset");
            assertEq(v.owner(), owner);
            assertEq(v.curator(), owner);
            assertEq(v.performanceFee(), FEE);
            assertEq(v.performanceFeeRecipient(), sink);
            assertEq(v.liquidityAdapter(), d.adapter);
            assertEq(v.totalAssets(), s.seed, "seed is in");

            Market memory m = morpho.market(Id.wrap(d.marketId));
            assertGt(m.lastUpdate, 0, "market exists");
            assertEq(m.totalSupplyAssets, s.seed, "seed reached the market");

            // Oracle: stock wei per 1 wei of vault share, scaled 1e36. One whole share redeems for a little
            // over one USDG. Turn the price back into dollars per token.
            uint256 p = IOracle(d.oracle).price();
            uint256 dollars8 = (1e36 * held.convertToAssets(1e18) * 1e2) / p;
            uint256 feed = _feedPrice(s.symbol);
            assertApproxEqRel(dollars8, feed, 0.005e18, "oracle agrees with the feed");
            assertGt(feed, 5e8);
            assertLt(feed, 5000e8);
            emit log_named_decimal_uint(s.symbol, feed, 8);
        }
    }

    // ------------------------------------------------------------------ lending

    function test_lender_gets_the_stock_back() public onFork {
        uint256 shares = _lend("NVDA", ann, 10e18);
        IVaultV2 v = IVaultV2(desk["NVDA"].vault);
        assertEq(IERC20Min(desk["NVDA"].token).balanceOf(desk["NVDA"].vault), 0, "nothing idle, all in the market");
        vm.prank(ann);
        uint256 out = v.redeem(shares, ann, ann);
        assertApproxEqAbs(out, 10e18, 10, "whole deposit back");
    }

    function test_lender_cannot_lend_past_the_cap() public onFork {
        uint256 cap = stockOf["SPY"].cap;
        deal(desk["SPY"].token, ann, cap + 1e18);
        vm.startPrank(ann);
        IERC20Min(desk["SPY"].token).approve(desk["SPY"].vault, type(uint256).max);
        vm.expectRevert();
        IVaultV2(desk["SPY"].vault).deposit(cap + 1e18, ann);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ shorting

    function test_short_pays_the_lender_and_the_fee() public onFork {
        uint256 shares = _lend("NVDA", ann, 100e18);
        uint256 price = _feedPrice("NVDA");
        uint256 borrowAmt = 90e18;
        uint256 dollars = (borrowAmt * price * 2) / 1e20; // 2x the borrowed value, in USDG (6 decimals)
        _short("NVDA", bob, dollars, borrowAmt);
        assertEq(IERC20Min(desk["NVDA"].token).balanceOf(bob), borrowAmt, "bob holds the stock to sell");

        vm.warp(block.timestamp + 30 days);
        _setFeedPrice("NVDA", price);

        IVaultV2 v = IVaultV2(desk["NVDA"].vault);
        v.accrueInterest();
        uint256 worth = v.previewRedeem(shares);
        assertGt(worth, 100e18, "lender earned stock");
        assertGt(v.balanceOf(sink), 0, "fee shares minted");
        uint256 feeWorth = v.previewRedeem(v.balanceOf(sink));
        uint256 earned = worth - 100e18;
        assertApproxEqRel(feeWorth, (earned + feeWorth) / 10, 0.02e18, "fee is a tenth of the interest");
        emit log_named_decimal_uint("lender earned NVDA in 30 days", earned, 18);
        emit log_named_decimal_uint("fee in NVDA", feeWorth, 18);

        // Bob buys back and closes.
        uint256 owed = _debt("NVDA", bob);
        deal(desk["NVDA"].token, bob, owed);
        vm.startPrank(bob);
        IERC20Min(desk["NVDA"].token).approve(address(morpho), owed);
        Position memory p = morpho.position(Id.wrap(desk["NVDA"].marketId), bob);
        morpho.repay(desk["NVDA"].market, 0, p.borrowShares, bob, "");
        morpho.withdrawCollateral(desk["NVDA"].market, p.collateral, bob, bob);
        uint256 back = held.redeem(p.collateral, bob, bob);
        vm.stopPrank();
        assertGt(back, dollars, "the held money came back with 30 days of interest");
        emit log_named_decimal_uint("held money earned USDG in 30 days", back - dollars, 6);

        vm.prank(ann);
        uint256 out = v.redeem(shares, ann, ann);
        assertGt(out, 100e18);
    }

    function test_short_cannot_borrow_past_the_limit() public onFork {
        _lend("NVDA", ann, 100e18);
        uint256 price = _feedPrice("NVDA");
        uint256 dollars = (10e18 * price) / 1e20; // worth exactly 10 NVDA
        deal(USDG, bob, dollars);
        vm.startPrank(bob);
        IERC20Min(USDG).approve(address(held), dollars);
        uint256 shares = held.deposit(dollars, bob);
        held.approve(address(morpho), shares);
        morpho.supplyCollateral(desk["NVDA"].market, shares, bob, "");
        vm.expectRevert(bytes("insufficient collateral"));
        morpho.borrow(desk["NVDA"].market, 6.3e18, 0, bob, bob); // 63% > 62.5%
        morpho.borrow(desk["NVDA"].market, 6.2e18, 0, bob, bob);
        vm.stopPrank();
    }

    function test_lender_waits_when_everything_is_lent_out() public onFork {
        uint256 shares = _lend("TSLA", ann, 50e18);
        uint256 price = _feedPrice("TSLA");
        _short("TSLA", bob, (50e18 * price * 2) / 1e20, 50e18);

        vm.prank(ann);
        vm.expectRevert();
        IVaultV2(desk["TSLA"].vault).redeem(shares, ann, ann);

        // Once the short closes, the lender can leave.
        uint256 owed = _debt("TSLA", bob);
        deal(desk["TSLA"].token, bob, owed);
        vm.startPrank(bob);
        IERC20Min(desk["TSLA"].token).approve(address(morpho), owed);
        Position memory p = morpho.position(Id.wrap(desk["TSLA"].marketId), bob);
        morpho.repay(desk["TSLA"].market, 0, p.borrowShares, bob, "");
        vm.stopPrank();

        vm.prank(ann);
        uint256 out = IVaultV2(desk["TSLA"].vault).redeem(shares, ann, ann);
        assertGe(out, 50e18 - 10);
    }

    // ------------------------------------------------------------------ liquidation

    function test_squeeze_liquidates_the_short_and_the_lender_is_whole() public onFork {
        uint256 shares = _lend("MSTR", ann, 100e18);
        uint256 price = _feedPrice("MSTR");
        uint256 borrowAmt = 60e18;
        uint256 dollars = (100e18 * price) / 1e20; // collateral worth 100 MSTR, borrow 60: just under the 62.5% limit
        _short("MSTR", bob, dollars, borrowAmt);

        // Not liquidatable yet.
        deal(desk["MSTR"].token, liq, 100e18);
        vm.startPrank(liq);
        IERC20Min(desk["MSTR"].token).approve(address(morpho), type(uint256).max);
        vm.expectRevert(bytes("position is healthy"));
        morpho.liquidate(desk["MSTR"].market, bob, 0, 1e18, "");
        vm.stopPrank();

        // The stock jumps 20%.
        _setFeedPrice("MSTR", (price * 120) / 100);

        Position memory p = morpho.position(Id.wrap(desk["MSTR"].marketId), bob);
        vm.prank(liq);
        (uint256 seized, uint256 repaid) = morpho.liquidate(desk["MSTR"].market, bob, 0, p.borrowShares, "");
        assertApproxEqAbs(repaid, borrowAmt, 1e12, "whole debt repaid");
        assertEq(held.balanceOf(liq), seized, "the liquidator is paid in vault shares");

        // Redeemed, they are worth more dollars than the stock cost.
        vm.prank(liq);
        uint256 got = held.redeem(seized, liq, liq);
        uint256 cost = (repaid * (price * 120 / 100)) / 1e20;
        assertGt(got, cost, "liquidation pays");
        emit log_named_decimal_uint("liquidator paid (USD value of MSTR)", cost, 6);
        emit log_named_decimal_uint("liquidator received USDG", got, 6);

        Market memory m = morpho.market(Id.wrap(desk["MSTR"].marketId));
        assertEq(m.totalBorrowAssets, 0);
        vm.prank(ann);
        uint256 out = IVaultV2(desk["MSTR"].vault).redeem(shares, ann, ann);
        assertGe(out, 100e18 - 10, "lender whole");
    }

    function test_gap_past_the_collateral_costs_the_lender() public onFork {
        uint256 shares = _lend("COIN", ann, 100e18);
        uint256 price = _feedPrice("COIN");
        _short("COIN", bob, (100e18 * price) / 1e20, 60e18);

        // The stock doubles over a weekend: debt is now worth 120, collateral 100.
        _setFeedPrice("COIN", price * 2);
        deal(desk["COIN"].token, liq, 100e18);
        vm.startPrank(liq);
        IERC20Min(desk["COIN"].token).approve(address(morpho), type(uint256).max);
        morpho.liquidate(desk["COIN"].market, bob, _held("COIN", bob), 0, "");
        vm.stopPrank();

        IVaultV2 v = IVaultV2(desk["COIN"].vault);
        v.accrueInterest();
        uint256 worth = v.previewRedeem(shares);
        assertLt(worth, 100e18, "loss lands on lenders");
        emit log_named_decimal_uint("lender left with COIN out of 100", worth, 18);
    }

    // ------------------------------------------------------------------ locks

    function test_lock_puts_a_wait_on_risky_settings() public onFork {
        IVaultV2 v = IVaultV2(desk["SPY"].vault);
        vm.startPrank(owner);
        BorroLib.lock(address(v), 3 days);
        assertEq(v.timelock(IVaultV2.addAdapter.selector), 3 days);
        assertEq(v.timelock(IVaultV2.setPerformanceFee.selector), 3 days);

        bytes memory raise = abi.encodeCall(IVaultV2.setPerformanceFee, (0.5e18));
        v.submit(raise);
        vm.expectRevert();
        v.setPerformanceFee(0.5e18);
        vm.warp(block.timestamp + 3 days);
        v.setPerformanceFee(0.5e18);
        vm.stopPrank();
        assertEq(v.performanceFee(), 0.5e18);
    }

    function test_owner_cannot_take_lender_stock() public onFork {
        _lend("QQQ", ann, 10e18);
        IVaultV2 v = IVaultV2(desk["QQQ"].vault);
        vm.startPrank(owner);
        vm.expectRevert();
        v.redeem(1e18, owner, ann);
        vm.expectRevert();
        v.withdraw(1e18, owner, ann);
        vm.stopPrank();
    }
}
