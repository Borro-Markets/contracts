// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {BorroLib, IAdapterTimelocks} from "../script/BorroLib.sol";
import {BorroRouter} from "../src/BorroRouter.sol";
import {BorroSetup} from "./BorroSetup.sol";

/// Runs against a fork of Robinhood Chain: BORRO_FORK_RPC=<rpc> forge test
/// The USDG side: borrow USDG against lent stock, and lend USDG through the Borro USDG vault.
contract BorroUsdgForkTest is BorroSetup {
    // ------------------------------------------------------------------ the USDG markets

    function test_every_usdg_market_prices_a_vault_share_at_the_feed() public onFork {
        // Let NVDA earn rent for two months first, so its vault share is worth more than one NVDA.
        _lend("NVDA", ann, 100e18);
        deal(address(usdg), bob, 50_000e6);
        vm.startPrank(bob);
        usdg.approve(address(short), 50_000e6);
        short.addDeposit(desk["NVDA"].marketId, 50_000e6);
        short.borrow(desk["NVDA"].marketId, 90e18);
        vm.stopPrank();
        uint256 price = _price("NVDA");
        vm.warp(block.timestamp + 60 days);
        _setFeed("NVDA", price);
        assertGt(IVaultV2(desk["NVDA"].vault).convertToAssets(1e18), 1e18, "a bNVDA is worth more than one NVDA");

        (, int256 usdgUsd,,,) = AggregatorV3Interface(BorroLib.USDG_FEED).latestRoundData();
        for (uint256 i; i < stocks.length; i++) {
            BorroLib.Stock memory s = stocks[i];
            BorroLib.Loan memory l = loan[s.symbol];
            IVaultV2 v = IVaultV2(desk[s.symbol].vault);

            assertEq(l.market.loanToken, address(usdg));
            assertEq(l.market.collateralToken, address(v));
            assertEq(l.market.lltv, s.lltvUsdg);
            assertTrue(morpho.isLltvEnabled(s.lltvUsdg));
            Market memory m = morpho.market(Id.wrap(l.marketId));
            assertGt(m.lastUpdate, 0, "market exists");
            assertGt(morpho.position(Id.wrap(l.marketId), BorroLib.DEAD).supplyShares, 0, "seeded by the dead address");
            assertGe(m.totalSupplyAssets, BorroLib.USDG_MARKET_SEED);
            assertEq(v.maxRate(), BorroLib.STOCK_MAX_RATE, "50% a year");

            // Oracle: USDG wei per wei of share, scaled 1e36. One whole share in USDG wei is price / 1e18.
            uint256 perShare = IOracle(l.oracle).price() / 1e18;
            uint256 expected = (_price(s.symbol) * v.convertToAssets(1e18) * 1e8) / (1e18 * 100 * uint256(usdgUsd));
            assertApproxEqRel(perShare, expected, 0.005e18, string.concat(s.symbol, ": feed times share price"));
            emit log_named_decimal_uint(string.concat("b", s.symbol, " in USDG"), perShare, 6);
        }
        assertEq(stockOf["SPY"].lltvUsdg, 0.625e18);
        assertEq(stockOf["QQQ"].lltvUsdg, 0.625e18);
        assertEq(stockOf["NVDA"].lltvUsdg, 0.625e18);
        assertEq(stockOf["GME"].lltvUsdg, 0.385e18);
        assertEq(stockOf["TSLA"].lltvUsdg, 0.385e18);
    }

    // ------------------------------------------------------------------ the Borro USDG vault

    function test_usdg_vault_is_set_up_as_planned() public onFork {
        assertEq(bUsdg.asset(), address(usdg));
        assertEq(bUsdg.name(), "Borro USDG");
        assertEq(bUsdg.symbol(), "bUSDG");
        assertEq(bUsdg.owner(), owner);
        assertEq(bUsdg.curator(), owner);
        assertTrue(bUsdg.isAllocator(owner));
        assertTrue(bUsdg.isAllocator(keeper));
        assertEq(bUsdg.performanceFee(), FEE);
        assertEq(bUsdg.performanceFeeRecipient(), sink);
        assertEq(bUsdg.liquidityAdapter(), lender.adapter);
        assertEq(keccak256(bUsdg.liquidityData()), keccak256(abi.encode(loan["SPY"].market)), "deposits land in the SPY market");
        assertEq(lender.liquidityMarketId, loan["SPY"].marketId);
        assertEq(bUsdg.totalAssets(), BorroLib.USDG_SEED, "seed is in");
        assertEq(bUsdg.balanceOf(BorroLib.DEAD), bUsdg.totalSupply(), "the dead address holds every share");

        uint256 total;
        uint256 others;
        for (uint256 i; i < stocks.length; i++) {
            bytes[2] memory ids = BorroLib.loanIdData(lender.adapter, loan[stocks[i].symbol]);
            for (uint256 j; j < 2; j++) {
                assertEq(bUsdg.absoluteCap(keccak256(ids[j])), stocks[i].capUsdg);
                assertEq(bUsdg.relativeCap(keccak256(ids[j])), 1e18);
            }
            total += stocks[i].capUsdg;
            if (keccak256(bytes(stocks[i].symbol)) != keccak256("SPY")) others += stocks[i].capUsdg;
        }
        assertEq(bUsdg.absoluteCap(keccak256(abi.encode("this", lender.adapter))), total, "the adapter: all markets together");
        assertEq(stockOf["SPY"].capUsdg, others, "the liquidity market's cap is every other cap added up");
    }

    function test_usdg_lender_earns_from_a_stock_borrower_and_the_fee_is_taken() public onFork {
        uint256 lent = 100_000e6;
        uint256 shares = _lendUsdg(carl, lent);
        assertApproxEqAbs(bUsdg.previewRedeem(shares), lent, 1);
        _allocate("NVDA", 50_000e6);

        // Ann lends 100 NVDA, posts the bNVDA and borrows 10,000 USDG on Morpho.
        _lendAndPost("NVDA", ann, 100e18);
        vm.prank(ann);
        morpho.borrow(loan["NVDA"].market, 10_000e6, 0, ann, ann);
        assertEq(usdg.balanceOf(ann), 10_000e6);

        uint256 price = _price("NVDA");
        vm.warp(block.timestamp + 30 days);
        _setFeed("NVDA", price);
        bUsdg.accrueInterest();
        uint256 worth = bUsdg.previewRedeem(shares);
        assertGt(worth, lent, "the USDG lender earned interest");
        uint256 feeWorth = bUsdg.previewRedeem(bUsdg.balanceOf(sink));
        assertGt(feeWorth, 0, "fee shares minted");
        assertApproxEqRel(feeWorth, (worth - lent + feeWorth) / 10, 0.03e18, "the fee is a tenth of the interest");
        emit log_named_decimal_uint("USDG lender earned in 30 days", worth - lent, 6);
        emit log_named_decimal_uint("fee in USDG", feeWorth, 6);

        // Ann pays back with interest and takes her stock home.
        uint256 owed = _owedUsdg("NVDA", ann);
        deal(address(usdg), ann, owed);
        Position memory p = morpho.position(Id.wrap(loan["NVDA"].marketId), ann);
        vm.startPrank(ann);
        usdg.approve(address(morpho), owed);
        morpho.repay(loan["NVDA"].market, 0, p.borrowShares, ann, "");
        morpho.withdrawCollateral(loan["NVDA"].market, p.collateral, ann, ann);
        uint256 back = IVaultV2(desk["NVDA"].vault).redeem(p.collateral, ann, ann);
        vm.stopPrank();
        assertGe(back, 100e18 - 10, "her NVDA back, and rent if any was earned");

        // The keeper brings the money home, and Carl leaves with interest.
        uint256 inNvda = IAdapterView(lender.adapter).expectedSupplyAssets(loan["NVDA"].marketId);
        assertGt(inNvda, 50_000e6, "the NVDA market paid interest");
        vm.prank(keeper);
        bUsdg.deallocate(lender.adapter, abi.encode(loan["NVDA"].market), inNvda);
        vm.prank(carl);
        uint256 out = bUsdg.redeem(shares, carl, carl);
        assertGt(out, lent, "more USDG out than in");
        assertEq(bUsdg.balanceOf(carl), 0);
    }

    function test_deposits_and_withdrawals_go_through_the_spy_market() public onFork {
        _lendUsdg(carl, 20_000e6);
        Market memory m = morpho.market(Id.wrap(loan["SPY"].marketId));
        assertApproxEqAbs(m.totalSupplyAssets, 20_000e6 + BorroLib.USDG_SEED + BorroLib.USDG_MARKET_SEED, 2, "deposit reached the SPY market");
        assertEq(usdg.balanceOf(address(bUsdg)), 0, "nothing idle");

        // Money moved out of SPY cannot be withdrawn until it is brought back.
        _allocate("TSLA", 15_000e6);
        uint256 shares = bUsdg.balanceOf(carl);
        vm.prank(carl);
        vm.expectRevert();
        bUsdg.redeem(shares, carl, carl);
        vm.prank(carl);
        bUsdg.withdraw(5_000e6, carl, carl);
        assertEq(usdg.balanceOf(carl), 5_000e6);

        // Only allocators move money, and only within the caps.
        vm.prank(eve);
        vm.expectRevert();
        bUsdg.allocate(lender.adapter, abi.encode(loan["GME"].market), 1e6);
        _lendUsdg(carl, 200_000e6);
        uint256 cap = stockOf["GME"].capUsdg;
        vm.startPrank(keeper);
        bUsdg.deallocate(lender.adapter, bUsdg.liquidityData(), cap + 1);
        vm.expectRevert();
        bUsdg.allocate(lender.adapter, abi.encode(loan["GME"].market), cap + 1);
        bUsdg.allocate(lender.adapter, abi.encode(loan["GME"].market), cap);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the router

    function test_router_lends_and_posts_in_one_step_and_keeps_nothing() public onFork {
        _lendUsdg(carl, 50_000e6);
        _allocate("NVDA", 40_000e6);
        BorroLib.Desk memory d = desk["NVDA"];
        uint256 shares = _lendAndPost("NVDA", ann, 20e18);

        Position memory p = morpho.position(Id.wrap(loan["NVDA"].marketId), ann);
        assertEq(p.collateral, shares, "the shares are posted in her name");
        assertApproxEqAbs(IVaultV2(d.vault).previewRedeem(shares), 20e18, 1, "worth what she lent");
        assertEq(IERC20(d.token).balanceOf(ann), 0);
        assertEq(IERC20(d.token).balanceOf(address(router)), 0, "no stock left in the router");
        assertEq(IERC20(d.vault).balanceOf(address(router)), 0, "no shares left in the router");
        assertEq(IERC20(d.token).allowance(ann, address(router)), 0, "her exact approval was used up");
        assertEq(IERC20(d.token).allowance(address(router), d.vault), 0, "no allowance left behind");
        assertEq(IERC20(d.vault).allowance(address(router), address(morpho)), 0);
        assertFalse(morpho.isAuthorized(ann, address(router)), "she never authorized the router");

        // She borrows on Morpho directly, up to the limit and no further.
        uint256 value = (_worth("NVDA", 20e18) * stockOf["NVDA"].lltvUsdg) / 1e18;
        vm.startPrank(ann);
        vm.expectRevert(bytes("insufficient collateral"));
        morpho.borrow(loan["NVDA"].market, value + 10e6, 0, ann, ann);
        morpho.borrow(loan["NVDA"].market, value - 10e6, 0, ann, ann);
        vm.stopPrank();

        // Later she repays and withdraws on Morpho directly, then takes her stock out of the vault.
        vm.warp(block.timestamp + 7 days);
        uint256 owed = _owedUsdg("NVDA", ann);
        deal(address(usdg), ann, owed);
        vm.startPrank(ann);
        usdg.approve(address(morpho), owed);
        morpho.repay(loan["NVDA"].market, 0, morpho.position(Id.wrap(loan["NVDA"].marketId), ann).borrowShares, ann, "");
        morpho.withdrawCollateral(loan["NVDA"].market, shares, ann, ann);
        uint256 back = IVaultV2(d.vault).redeem(shares, ann, ann);
        vm.stopPrank();
        assertGe(back, 20e18 - 1);
    }

    function test_router_refuses_a_market_that_does_not_match() public onFork {
        BorroLib.Desk memory d = desk["NVDA"];
        deal(d.token, ann, 10e18);
        vm.startPrank(ann);
        IERC20(d.token).approve(address(router), 10e18);
        // A short market lends the stock, not USDG.
        vm.expectRevert(BorroRouter.BadMarket.selector);
        router.lendAndPost(d.market, d.token, 1e18, 0);
        // TSLA's market for NVDA.
        vm.expectRevert(BorroRouter.BadMarket.selector);
        router.lendAndPost(loan["TSLA"].market, d.token, 1e18, 0);
        // A market Borro did not list.
        MarketParams memory fake = loan["NVDA"].market;
        fake.collateralToken = d.token;
        vm.expectRevert(BorroRouter.BadMarket.selector);
        router.lendAndPost(fake, d.token, 1e18, 0);
        vm.expectRevert(BorroRouter.Nothing.selector);
        router.lendAndPost(loan["NVDA"].market, d.token, 0, 0);
        vm.stopPrank();
        assertEq(IERC20(d.token).balanceOf(ann), 10e18, "nothing moved");
    }

    // ------------------------------------------------------------------ handing over

    function test_lock_and_hand_over_leave_the_setup_wallet_nothing() public onFork {
        address safe = makeAddr("safe");
        vm.startPrank(owner);
        BorroLib.lock(address(bUsdg), 3 days);
        BorroLib.handOver(address(bUsdg), owner, safe);
        BorroLib.lock(desk["NVDA"].vault, 3 days);
        BorroLib.handOver(desk["NVDA"].vault, owner, safe);
        vm.stopPrank();

        assertEq(IAdapterTimelocks(lender.adapter).timelock(IAdapterTimelocks.burnShares.selector), 3 days, "the adapter cannot write off loans at once");
        assertEq(IAdapterTimelocks(desk["NVDA"].adapter).timelock(IAdapterTimelocks.burnShares.selector), 3 days);
        bytes4[15] memory sel = BorroLib.lockedSelectors();
        for (uint256 i; i < 2; i++) {
            IVaultV2 v = i == 0 ? bUsdg : IVaultV2(desk["NVDA"].vault);
            for (uint256 k; k < sel.length; k++) assertEq(v.timelock(sel[k]), 3 days, "every risky setting waits");
            assertEq(v.timelock(IVaultV2.setIsAllocator.selector), 0, "removing an allocator does not wait");
            assertEq(v.owner(), safe);
            assertEq(v.curator(), safe);
            assertTrue(v.isAllocator(safe));
            assertTrue(v.isSentinel(safe), "the Safe is a sentinel");
            assertFalse(v.isAllocator(owner), "the setup wallet is no allocator");
            assertFalse(v.isSentinel(owner), "nor a sentinel");
        }
        assertTrue(bUsdg.isAllocator(keeper), "the keeper still allocates");

        vm.startPrank(owner);
        vm.expectRevert();
        bUsdg.setCurator(owner);
        vm.expectRevert();
        bUsdg.submit(abi.encodeCall(IVaultV2.setIsAllocator, (owner, true)));
        vm.stopPrank();
    }

    function test_gates_fee_recipients_and_abdicating_wait_but_the_keeper_goes_at_once() public onFork {
        address safe = makeAddr("safe");
        vm.startPrank(owner);
        BorroLib.lock(address(bUsdg), 3 days);
        BorroLib.handOver(address(bUsdg), owner, safe);
        vm.stopPrank();

        // Each of these could stop lenders getting out or redirect their fees: each waits three days in public.
        bytes[6] memory risky = [
            abi.encodeCall(IVaultV2.setReceiveSharesGate, (eve)),
            abi.encodeCall(IVaultV2.setSendAssetsGate, (eve)),
            abi.encodeCall(IVaultV2.setAdapterRegistry, (eve)),
            abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (eve)),
            abi.encodeCall(IVaultV2.setManagementFeeRecipient, (eve)),
            abi.encodeCall(IVaultV2.abdicate, (IVaultV2.setIsAllocator.selector))
        ];
        vm.startPrank(safe);
        for (uint256 i; i < risky.length; i++) {
            bUsdg.submit(risky[i]);
            assertEq(bUsdg.executableAt(risky[i]), block.timestamp + 3 days);
            (bool ok,) = address(bUsdg).call(risky[i]);
            assertFalse(ok, "not before the wait");
            bUsdg.revoke(risky[i]);
        }

        // A keeper gone bad is removed in one transaction, with no wait.
        bytes memory remove = abi.encodeCall(IVaultV2.setIsAllocator, (keeper, false));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IVaultV2.submit, (remove));
        calls[1] = remove;
        bUsdg.multicall(calls);
        vm.stopPrank();
        assertFalse(bUsdg.isAllocator(keeper), "the keeper is out at once");
        vm.prank(keeper);
        vm.expectRevert();
        bUsdg.setMaxRate(0);
    }

    function test_the_keeper_cannot_take_money_and_the_safe_undoes_what_it_can_do() public onFork {
        address safe = makeAddr("safe");
        vm.startPrank(owner);
        BorroLib.lock(address(bUsdg), 3 days);
        BorroLib.handOver(address(bUsdg), owner, safe);
        vm.stopPrank();
        uint256 shares = _lendUsdg(carl, 100_000e6);
        uint256 cap = stockOf["GME"].capUsdg;

        // The worst a keeper can do: move money within the caps, and stop interest reaching the share price.
        vm.startPrank(keeper);
        vm.expectRevert();
        bUsdg.redeem(shares, keeper, carl);
        vm.expectRevert();
        bUsdg.transferFrom(carl, keeper, shares);
        bUsdg.deallocate(lender.adapter, bUsdg.liquidityData(), 100_000e6);
        bUsdg.allocate(lender.adapter, abi.encode(loan["GME"].market), cap);
        vm.expectRevert();
        bUsdg.allocate(lender.adapter, abi.encode(loan["GME"].market), 1e6);
        bUsdg.setMaxRate(0);
        vm.stopPrank();
        assertEq(usdg.balanceOf(keeper), 0, "nothing reached the keeper");
        assertEq(bUsdg.balanceOf(keeper), 0);

        // The Safe answers at once: the keeper out, the cap cut (as sentinel), the money back, the rate back.
        bytes memory remove = abi.encodeCall(IVaultV2.setIsAllocator, (keeper, false));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IVaultV2.submit, (remove));
        calls[1] = remove;
        vm.startPrank(safe);
        bUsdg.multicall(calls);
        bUsdg.decreaseAbsoluteCap(BorroLib.loanIdData(lender.adapter, loan["GME"])[1], 0);
        bUsdg.deallocate(lender.adapter, abi.encode(loan["GME"].market), cap);
        bUsdg.setMaxRate(BorroLib.MAX_MAX_RATE);
        vm.stopPrank();
        assertTrue(bUsdg.isSentinel(safe));
        assertEq(bUsdg.absoluteCap(keccak256(BorroLib.loanIdData(lender.adapter, loan["GME"])[1])), 0);

        vm.prank(carl);
        uint256 out = bUsdg.redeem(shares, carl, carl);
        assertApproxEqAbs(out, 100_000e6, 2, "the lender leaves with what he put in");
    }

    // ------------------------------------------------------------------ the liquidity market

    function test_a_deposit_bigger_than_any_other_cap_lands_in_the_spy_market() public onFork {
        uint256 biggestOther;
        for (uint256 i; i < stocks.length; i++) {
            if (keccak256(bytes(stocks[i].symbol)) == keccak256("SPY")) continue;
            if (stocks[i].capUsdg > biggestOther) biggestOther = stocks[i].capUsdg;
        }
        uint256 amount = biggestOther * 3;
        _lendUsdg(carl, amount);
        Market memory m = morpho.market(Id.wrap(loan["SPY"].marketId));
        assertApproxEqAbs(m.totalSupplyAssets, amount + BorroLib.USDG_SEED + BorroLib.USDG_MARKET_SEED, 2, "all of it in SPY");

        // It fills up to the SPY market's cap, every other cap added up, and no further.
        uint256 room = stockOf["SPY"].capUsdg - amount - BorroLib.USDG_SEED;
        _lendUsdg(ann, room);
        deal(address(usdg), bob, 1e6);
        vm.startPrank(bob);
        usdg.approve(address(bUsdg), 1e6);
        vm.expectRevert();
        bUsdg.deposit(1e6, bob);
        vm.stopPrank();
    }

    function test_force_deallocate_lets_a_lender_out_when_the_spy_market_is_fully_borrowed() public onFork {
        uint256 shares = _lendUsdg(carl, 20_000e6);
        _allocate("NVDA", 15_000e6);

        // Ann borrows every USDG left in the SPY market, against bSPY worth $10,000.
        _lendAndPost("SPY", ann, (10_000e6 * 1e20) / _price("SPY"));
        Market memory m = morpho.market(Id.wrap(loan["SPY"].marketId));
        vm.prank(ann);
        morpho.borrow(loan["SPY"].market, m.totalSupplyAssets - m.totalBorrowAssets, 0, ann, ann);

        // An ordinary withdrawal is paid from the SPY market, so it cannot be paid now.
        vm.prank(carl);
        vm.expectRevert();
        bUsdg.withdraw(1_000e6, carl, carl);

        // Carl moves his money out of the NVDA market into the vault himself, and takes it. No penalty.
        assertEq(bUsdg.forceDeallocatePenalty(lender.adapter), 0);
        vm.startPrank(carl);
        assertEq(bUsdg.forceDeallocate(lender.adapter, abi.encode(loan["NVDA"].market), 15_000e6, carl), 0);
        bUsdg.withdraw(15_000e6, carl, carl);
        vm.stopPrank();
        assertEq(usdg.balanceOf(carl), 15_000e6);
        assertApproxEqAbs(bUsdg.previewRedeem(bUsdg.balanceOf(carl)), 5_000e6, 2, "the rest waits for SPY borrowers to repay");
        assertLt(bUsdg.balanceOf(carl), shares);
    }

    // ------------------------------------------------------------------ the router's list

    function test_router_posts_only_to_markets_the_owner_lists_and_honours_min_shares() public onFork {
        BorroLib.Desk memory d = desk["NVDA"];
        bytes32 id = loan["NVDA"].marketId;
        assertTrue(router.listed(id));
        assertEq(router.owner(), owner);

        // Nobody else lists or unlists, and a market that does not lend USDG can never be listed.
        vm.startPrank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        router.unlist(id);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        router.list(loan["NVDA"].market);
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(BorroRouter.BadMarket.selector);
        router.list(d.market);

        // Fewer shares than asked for: nothing happens.
        deal(d.token, ann, 10e18);
        vm.prank(ann);
        IERC20(d.token).approve(address(router), 10e18);
        uint256 expected = IVaultV2(d.vault).previewDeposit(10e18);
        vm.prank(ann);
        vm.expectRevert(abi.encodeWithSelector(BorroRouter.TooFewShares.selector, expected, expected + 1));
        router.lendAndPost(loan["NVDA"].market, d.token, 10e18, expected + 1);

        // Unlisted, the market is refused; listed again, it works.
        vm.prank(owner);
        router.unlist(id);
        vm.prank(ann);
        vm.expectRevert(BorroRouter.BadMarket.selector);
        router.lendAndPost(loan["NVDA"].market, d.token, 10e18, expected);
        vm.prank(owner);
        router.list(loan["NVDA"].market);
        vm.prank(ann);
        assertEq(router.lendAndPost(loan["NVDA"].market, d.token, 10e18, expected), expected);
        assertEq(morpho.position(Id.wrap(id), ann).collateral, expected);
    }
}

interface IAdapterView {
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}
