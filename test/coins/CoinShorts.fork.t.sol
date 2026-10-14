// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {CoinFeed, IUniV3PoolOracle} from "../../src/coins/CoinFeed.sol";
import {CoinListing, IPositionManager} from "../../src/coins/CoinListing.sol";
import {CoinShort, CoinAccount, IHeld} from "../../src/coins/CoinShort.sol";
import {CoinLiquidator, IHeldRedeem} from "../../src/coins/CoinLiquidator.sol";
import {CoinCollateral} from "../../src/coins/CoinCollateral.sol";
import {IPonsFactory, IPonsLocker, IWETH, IUniswapV3PoolSwap, ICoinListing, CoinDesk} from "../../src/coins/CoinDeps.sol";
import {PoolTrader, McapKnob} from "./CoinFeed.fork.t.sol";

/// Coin shorts end to end on a copy of Robinhood Chain: the real Pons factory, locker, hook and $BORRO pool, the
/// real Morpho, its oracle, vault and adapter factories, Steakhouse USDG and the WETH/USDG pool. Set BORRO_FORK_RPC.
contract CoinShortsForkTest is McapKnob {
    using MarketParamsLib for MarketParams;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant LOCKER = 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant HELD = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    bytes32 constant NVDA_MARKET = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;
    uint32 constant CHECK = 15;

    CoinListing listing;
    CoinShort short;
    CoinLiquidator liq;
    CoinCollateral cusdg;
    PoolTrader trader;
    CoinDesk d;
    bool forked;

    address lister = makeAddr("lister");
    address lender = makeAddr("lender");
    address ann = makeAddr("ann");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        listing = new CoinListing(
            PM, IPositionManager(POSM), IPonsFactory(PONS), IPonsLocker(LOCKER), IUniV3PoolOracle(ETH_POOL), WETH, address(USDG), SAFE, predicted
        );
        short = new CoinShort(
            MORPHO, PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), USDG, IHeld(HELD), ICoinListing(address(listing)), PONS_HOOK, SAFE
        );
        assertEq(address(short), predicted);
        liq = new CoinLiquidator(MORPHO, PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), USDG, IHeldRedeem(HELD), ICoinListing(address(listing)));
        cusdg = short.collateral();
        trader = new PoolTrader(PM, listing.keyOf(address(BORRO)));
        vm.deal(address(trader), 200 ether);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _step() internal {
        vm.warp(vm.getBlockTimestamp() + CHECK);
        vm.roll(vm.getBlockNumber() + 1);
        _feed().poke();
    }

    /// Pokes every 15 seconds for `secs` (the keeper's rhythm).
    function _pokeFor(uint256 secs) internal {
        for (uint256 t; t < secs; t += CHECK) _step();
    }

    function _feed() internal view returns (CoinFeed f) {
        f = CoinFeed(listing.deskOf(address(BORRO)).feed);
    }

    function _delayed() internal view returns (uint256 p) {
        (, int256 a,,,) = _feed().latestRoundData();
        p = uint256(a);
    }

    /// Prepare, wait out LIST_WAIT, warm the feed, list; then a lender lends 40M $BORRO.
    function _listAndLend() internal {
        _oldEnough();
        _bigEnough();
        uint256 seed = listing.SEED();
        deal(address(BORRO), lister, seed);
        vm.startPrank(lister);
        BORRO.approve(address(listing), seed);
        uint256 g = gasleft();
        listing.list(address(BORRO));
        console2.log("gas: list", g - gasleft());
        vm.stopPrank();
        d = listing.deskOf(address(BORRO));
        _pokeFor(18 minutes); // the new feed gets its price
        deal(address(BORRO), lender, 40_000_000e18);
        vm.startPrank(lender);
        BORRO.approve(d.vault, type(uint256).max);
        IVaultV2(d.vault).deposit(40_000_000e18, lender);
        vm.stopPrank();
    }

    /// $BORRO launched 2026-10-05 14:31 UTC: on a fork of an earlier day it is not three days old yet.
    function _oldEnough() internal {
        uint256 ready = 1791227460 + 3 days;
        if (vm.getBlockTimestamp() < ready) vm.warp(ready + 1);
    }

    /// $BORRO worth $15M at the pool's price: over the $10M floor with room for the tests' moves.
    function _bigEnough() internal {
        _mcapTo(address(BORRO), listing.checks(address(BORRO)).mcapUsd, 15_000_000e18);
    }

    /// USDG (6 decimals) worth `coins` at the delayed price.
    function _usd(uint256 coins) internal view returns (uint256) {
        return (coins * _delayed()) / 1e30;
    }

    /// Opens a short of `borrow` coins for `who` with collateral so the position sits near `ltvBps`.
    function _open(address who, uint256 borrow, uint256 ltvBps) internal returns (uint256 proceeds) {
        uint256 debtUsd = _usd(borrow);
        uint256 deposit = (debtUsd * 10_000) / ltvBps - (debtUsd * 95) / 100; // the sale brings about 95% of it
        deal(address(USDG), who, USDG.balanceOf(who) + deposit);
        vm.startPrank(who);
        USDG.approve(address(short), type(uint256).max);
        proceeds = short.open(address(BORRO), deposit, borrow, (debtUsd * 90) / 100, block.timestamp + 1);
        vm.stopPrank();
    }

    function _room() internal view returns (uint256) {
        (uint256 cap,) = listing.capOf(address(BORRO));
        uint256 owed = MORPHO.market(d.market.id()).totalBorrowAssets;
        return cap > owed ? cap - owed : 0;
    }

    /// Pushes the spot up to `mult`x by buying with ETH; returns the coins bought.
    function _pump(uint256 multBps) internal returns (uint256 coins) {
        uint256 s0 = _feed().spot();
        uint256 lo;
        uint256 hi = 1 ether;
        while (true) {
            uint256 snap = vm.snapshotState();
            trader.buy(hi);
            uint256 s1 = _feed().spot();
            vm.revertToState(snap);
            if (s1 * 10_000 >= s0 * multBps) break;
            lo = hi;
            hi *= 2;
        }
        for (uint256 i; i < 30; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            trader.buy(mid);
            uint256 s1 = _feed().spot();
            vm.revertToState(snap);
            if (s1 * 10_000 >= s0 * multBps) hi = mid;
            else lo = mid;
        }
        coins = trader.buy(hi);
    }

    function _owed(address acct) internal view returns (uint256) {
        Position memory p = MORPHO.position(d.market.id(), acct);
        Market memory m = MORPHO.market(d.market.id());
        return m.totalBorrowShares == 0 ? 0 : (uint256(p.borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;
    }

    function _nothingHeld(address who) internal view {
        assertEq(USDG.balanceOf(who), 0, "no USDG left");
        assertEq(BORRO.balanceOf(who), 0, "no coin left");
        assertEq(IERC20(HELD).balanceOf(who), 0, "no Steakhouse shares left");
        assertEq(IERC20(address(cusdg)).balanceOf(who), 0, "no cUSDG left");
        assertEq(IERC20(WETH).balanceOf(who), 0, "no WETH left");
        assertEq(who.balance, 0, "no ETH left");
    }

    // ------------------------------------------------------------------ listing

    function test_fork_listing_checks_refusals_and_listing() public onFork {
        // A coin Pons did not launch.
        vm.expectRevert(abi.encodeWithSelector(CoinListing.CheckFailed.selector, "launched by Pons"));
        listing.list(address(USDG));
        CoinListing.Checks memory c = listing.checks(address(BORRO));
        assertTrue(c.launchedByPons && c.pairedWithEth && c.graduated && c.decimals18 && c.taxOk && c.hookFeeOk && c.poolLive);
        assertTrue(c.liquidityLocked, "Pons's locker holds the full-range graduation position");
        assertEq(c.lockedId, 3616551);
        assertEq(c.launchedAt, 1791227460, "the curve's launch time: the launch block's");
        assertEq(c.readyAt, 1791227460 + 3 days);
        assertTrue(c.deepEnough && c.notListed && c.open);
        console2.log("locked ETH side at the pool's price (wei)", c.ethDepth);
        console2.log("$BORRO market cap at the pool's price (dollars)", c.mcapUsd / 1e18);
        assertFalse(c.mcapOk, "$BORRO is worth far less than $10M");

        // A second before it is three days old: refused. Then old enough.
        vm.warp(1791227460 + 3 days - 1);
        assertFalse(listing.checks(address(BORRO)).oldEnough);
        vm.expectRevert(abi.encodeWithSelector(CoinListing.CheckFailed.selector, "3 days since launch"));
        listing.list(address(BORRO));
        vm.warp(1791227460 + 3 days + 1 hours);
        assertTrue(listing.checks(address(BORRO)).oldEnough);

        // Old enough, but worth under $10M: refused. Then a dollar over $10M (the supply knob): it passes.
        vm.expectRevert(abi.encodeWithSelector(CoinListing.CheckFailed.selector, "market cap"));
        listing.list(address(BORRO));
        _mcapTo(address(BORRO), listing.checks(address(BORRO)).mcapUsd, 9_999_999e18);
        assertFalse(listing.checks(address(BORRO)).mcapOk);
        _mcapTo(address(BORRO), listing.checks(address(BORRO)).mcapUsd, 10_000_001e18);
        c = listing.checks(address(BORRO));
        assertTrue(c.mcapOk && c.mcapUsd >= 10_000_000e18 && c.mcapUsd < 10_000_002e18);

        // The Safe can pause listings; nothing else.
        vm.prank(SAFE);
        listing.setPaused(true);
        vm.expectRevert(CoinListing.IsPaused.selector);
        listing.list(address(BORRO));
        vm.prank(SAFE);
        listing.setPaused(false);

        deal(address(BORRO), lister, 1e18);
        vm.startPrank(lister);
        BORRO.approve(address(listing), 1e18);
        uint256 g = gasleft();
        listing.list(address(BORRO));
        console2.log("gas: list (one step)", g - gasleft());
        vm.stopPrank();
        d = listing.deskOf(address(BORRO));
        assertEq(d.market.collateralToken, address(cusdg));
        assertEq(d.market.lltv, 0.385e18);
        assertTrue(MORPHO.market(d.market.id()).lastUpdate != 0, "market created");
        IVaultV2 v = IVaultV2(d.vault);
        assertEq(v.owner(), SAFE, "the vault is the Safe's");
        assertEq(v.curator(), SAFE);
        assertTrue(v.isAllocator(SAFE));
        assertFalse(v.isAllocator(address(listing)), "the listing keeps no role");
        assertEq(v.timelock(IVaultV2.increaseAbsoluteCap.selector), 3 days);
        assertEq(BORRO.balanceOf(address(listing)), 0);
        vm.expectRevert(abi.encodeWithSelector(CoinListing.CheckFailed.selector, "not listed"));
        listing.list(address(BORRO));
        // Nothing can be shorted until the new feed has a price.
        vm.expectRevert();
        listing.capOf(address(BORRO));
        vm.expectRevert();
        listing.mcapOf(address(BORRO));
        _bigEnough(); // well over the floor from here, so only depth decides the cap
        _pokeFor(18 minutes);
        assertApproxEqRel(listing.mcapOf(address(BORRO)), 15_000_000e18, 0.001e18, "the market cap at the delayed price");
        (uint256 cap, uint256 depth) = listing.capOf(address(BORRO));
        console2.log("cap (coins)", cap / 1e18);
        console2.log("cap in USDG", _usd(cap));
        console2.log("locked coin side (coins)", depth / 1e18);
        assertEq(cap, (depth * 200) / 10_000, "2% of the locked coin side binds before $5,000");
    }

    /// A buy that lifts the pool's price until $BORRO is worth $10M lets it list (the listing reads the spot price),
    /// but sold straight back the delayed price never sees it: the cap stays zero and no short opens.
    function test_fork_a_one_block_pump_lists_the_coin_but_opens_nothing() public onFork {
        _oldEnough();
        uint256 mcap0 = listing.checks(address(BORRO)).mcapUsd;
        // The least ETH that makes it worth $10M at the pool's price.
        uint256 lo;
        uint256 hi = 200 ether;
        for (uint256 i; i < 40; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            trader.buy(mid);
            bool ok = listing.checks(address(BORRO)).mcapOk;
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        uint256 coins = trader.buy(hi);
        console2.log("$BORRO market cap before the pump (dollars)", mcap0 / 1e18);
        console2.log("ETH it took to show $10M at the pool's price (milli-ETH)", hi / 1e15);
        assertTrue(listing.checks(address(BORRO)).mcapOk);
        deal(address(BORRO), lister, 1e18);
        vm.startPrank(lister);
        BORRO.approve(address(listing), 1e18);
        listing.list(address(BORRO));
        vm.stopPrank();
        d = listing.deskOf(address(BORRO));
        trader.sell(coins);
        _pokeFor(18 minutes);
        assertApproxEqRel(listing.mcapOf(address(BORRO)), mcap0, 0.05e18, "the delayed price is the pre-pump one");
        (uint256 cap,) = listing.capOf(address(BORRO));
        assertEq(cap, 0, "under $10M at the delayed price: no room");
        deal(address(USDG), ann, 1_000e6);
        vm.startPrank(ann);
        USDG.approve(address(short), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoinShort.OverCap.selector, 1e18, 0));
        short.open(address(BORRO), 1_000e6, 1e18, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    /// A listed coin that falls under $10M at the delayed price takes no new shorts; a short already open closes.
    function test_fork_under_the_floor_no_new_shorts_but_closing_works() public onFork {
        _listAndLend();
        _open(ann, _room() / 4, 1_000);
        // Worth $11M, then holders dump about 17% and it holds for 18 minutes.
        _mcapTo(address(BORRO), listing.mcapOf(address(BORRO)), 11_000_000e18);
        deal(address(BORRO), address(trader), 10_000_000e18);
        trader.sell(10_000_000e18);
        _pokeFor(18 minutes);
        console2.log("market cap at the delayed price after the dump (dollars)", listing.mcapOf(address(BORRO)) / 1e18);
        assertLt(listing.mcapOf(address(BORRO)), 10_000_000e18);
        (uint256 cap, uint256 depth) = listing.capOf(address(BORRO));
        assertEq(cap, 0, "no room under the floor");
        assertGt(depth, 0);
        deal(address(USDG), bob, 1_000e6);
        vm.startPrank(bob);
        USDG.approve(address(short), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoinShort.OverCap.selector, 1e18, 0));
        short.open(address(BORRO), 1_000e6, 1e18, 0, block.timestamp + 1);
        vm.stopPrank();
        // Closing never looks at the floor.
        uint256 before = USDG.balanceOf(ann);
        vm.prank(ann);
        uint256 paid = short.close(address(BORRO), type(uint256).max, type(uint256).max, 0, type(uint256).max, block.timestamp + 1);
        assertEq(USDG.balanceOf(ann) - before, paid);
        assertGt(paid, 0);
        assertEq(_owed(short.accountOf(ann)), 0, "closed under the floor");
        _nothingHeld(address(short));
    }

    // ------------------------------------------------------------------ shorting

    function test_fork_short_within_cap_refused_over_cap_and_during_a_pump() public onFork {
        _listAndLend();
        uint256 room = _room();
        // Over the cap: refused.
        deal(address(USDG), ann, 100_000e6);
        vm.startPrank(ann);
        USDG.approve(address(short), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoinShort.OverCap.selector, room + 1, room));
        short.open(address(BORRO), 1_000e6, room + 1, 0, block.timestamp + 1);
        // Too much borrowed for the collateral (over the open limit, still under the LLTV): refused.
        uint256 small = _usd(room / 2) * 2;
        vm.expectRevert();
        short.open(address(BORRO), small, room / 2, 0, block.timestamp + 1);
        vm.stopPrank();

        // Within: ann shorts half the room at about 15% LTV.
        uint256 g = gasleft();
        uint256 proceeds = _open(ann, room / 2, 1_500);
        console2.log("gas: open (incl. test setup)", g - gasleft());
        console2.log("ann sold for (USDG)", proceeds);
        assertGt(proceeds, 0);
        _nothingHeld(address(short));
        assertEq(_owed(short.accountOf(ann)), room / 2 + 0, "owes what she borrowed");

        // A spot pump past 10% over the delayed price: new shorts wait.
        uint256 coins = _pump(12_000);
        vm.prank(bob);
        vm.expectRevert(CoinShort.GuardClosed.selector);
        short.open(address(BORRO), 100e6, 1e18, 0, block.timestamp + 1);
        trader.sell(coins);

        // Paused by the Safe: no new shorts; ann can still close at once.
        vm.prank(SAFE);
        short.pause(address(BORRO), true);
        vm.prank(bob);
        vm.expectRevert(CoinShort.IsPaused.selector);
        short.open(address(BORRO), 100e6, 1e18, 0, block.timestamp + 1);
        uint256 before = USDG.balanceOf(ann);
        vm.prank(ann);
        g = gasleft();
        uint256 paid = short.close(address(BORRO), type(uint256).max, type(uint256).max, 0, type(uint256).max, block.timestamp + 1);
        console2.log("gas: close", g - gasleft());
        assertEq(USDG.balanceOf(ann) - before, paid);
        assertEq(_owed(short.accountOf(ann)), 0, "closed while paused");
        assertEq(MORPHO.position(d.market.id(), short.accountOf(ann)).collateral, 0);
        _nothingHeld(address(short));
    }

    function test_fork_a_dump_and_the_short_closes_in_profit() public onFork {
        _listAndLend();
        uint256 room = _room();
        deal(address(USDG), bob, 0);
        _open(bob, room / 2, 1_500);
        uint256 spent = 0;
        {
            uint256 debtUsd = _usd(room / 2);
            spent = (debtUsd * 10_000) / 1_500 - (debtUsd * 95) / 100;
        }
        // Holders dump 40% and it holds.
        deal(address(BORRO), address(trader), 30_000_000e18);
        trader.sell(30_000_000e18);
        _pokeFor(18 minutes);
        vm.prank(bob);
        uint256 paid = short.close(address(BORRO), type(uint256).max, type(uint256).max, 0, type(uint256).max, block.timestamp + 1);
        console2.log("bob put in (USDG)", spent);
        console2.log("bob got back (USDG)", paid);
        assertGt(paid, spent, "the short made money");
    }

    function test_fork_partial_close_and_collateral_keep_the_open_limit() public onFork {
        _listAndLend();
        uint256 room = _room();
        _open(ann, room / 2, 1_000); // 10% LTV
        address acct = short.accountOf(ann);
        uint256 col = MORPHO.position(d.market.id(), acct).collateral;
        vm.startPrank(ann);
        // Taking most collateral out would pass 19.25%: refused.
        vm.expectRevert();
        short.takeDeposit(address(BORRO), (col * 8) / 10);
        // A third is fine.
        short.takeDeposit(address(BORRO), col / 3);
        // Reduce: repay half, take nothing.
        deal(address(USDG), ann, USDG.balanceOf(ann) + 1_000e6);
        uint256 shares = MORPHO.position(d.market.id(), acct).borrowShares;
        short.close(address(BORRO), shares / 2, 0, 1_000e6, type(uint256).max, block.timestamp + 1);
        // Add collateral back.
        deal(address(USDG), ann, 50e6);
        short.addDeposit(address(BORRO), 50e6);
        vm.stopPrank();
        _nothingHeld(address(short));
    }

    // ------------------------------------------------------------------ liquidation and bad debt

    function test_fork_a_held_pump_liquidates_through_the_liquidator() public onFork {
        _listAndLend();
        uint256 room = _room();
        _open(ann, room / 2, 1_900);
        address acct = short.accountOf(ann);
        // 2.5x, held long enough for the delayed price to follow.
        _pump(25_000);
        vm.expectRevert(CoinLiquidator.Healthy.selector);
        liq.liquidate(address(BORRO), acct, 0, keeper); // the feed has not caught up yet
        _pokeFor(18 minutes);
        uint256 g = gasleft();
        vm.prank(keeper);
        uint256 profit = liq.liquidate(address(BORRO), acct, 0, keeper);
        console2.log("gas: liquidate", g - gasleft());
        console2.log("liquidator profit (USDG)", profit);
        assertGt(profit, 0);
        assertEq(USDG.balanceOf(keeper), profit);
        assertEq(_owed(acct), 0, "the whole debt repaid");
        assertGt(MORPHO.position(d.market.id(), acct).collateral, 0, "ann keeps what was left");
        _nothingHeld(address(liq));
        // Ann takes the rest out: nothing owed, no price needed.
        vm.prank(ann);
        uint256 back = short.close(address(BORRO), 0, type(uint256).max, 0, 0, block.timestamp + 1);
        assertGt(back, 0);
    }

    function test_fork_bad_debt_stays_with_this_coins_lenders() public onFork {
        _listAndLend();
        uint256 room = _room();
        _open(ann, room / 2, 1_900);
        address acct = short.accountOf(ann);
        Market memory nvda0 = MORPHO.market(Id.wrap(NVDA_MARKET));
        uint256 heldPrice0 = IVaultV2(HELD).convertToAssets(1e18);
        uint256 vaultAssets0 = IVaultV2(d.vault).totalAssets();
        // 7x faster than the feed follows: liquidations only see it once it is past the collateral.
        _pump(70_000);
        _pokeFor(18 minutes);
        uint256 owed = _owed(acct);
        vm.prank(keeper);
        uint256 profit = liq.liquidate(address(BORRO), acct, 0, keeper);
        console2.log("bad-debt liquidation profit (USDG)", profit);
        Position memory p = MORPHO.position(d.market.id(), acct);
        assertEq(p.collateral, 0, "all collateral seized");
        assertEq(p.borrowShares, 0, "the rest written off");
        uint256 vaultAssets1 = IVaultV2(d.vault).totalAssets();
        console2.log("owed before (coins)", owed / 1e18);
        console2.log("lenders' vault before", vaultAssets0 / 1e18);
        console2.log("lenders' vault after", vaultAssets1 / 1e18);
        assertLt(vaultAssets1, vaultAssets0, "the coin's lenders took the loss");
        // Nothing else moved: the NVDA market and Steakhouse USDG.
        Market memory nvda1 = MORPHO.market(Id.wrap(NVDA_MARKET));
        assertEq(nvda1.totalSupplyAssets, nvda0.totalSupplyAssets);
        assertEq(nvda1.totalBorrowAssets, nvda0.totalBorrowAssets);
        assertGe(IVaultV2(HELD).convertToAssets(1e18), heldPrice0);
        _nothingHeld(address(liq));
    }

    // ------------------------------------------------------------------ the gate, the way out, lenders

    function test_fork_cusdg_cannot_reach_morpho_except_through_coinshort() public onFork {
        _listAndLend();
        _open(ann, _room() / 2, 1_900);
        address acct = short.accountOf(ann);
        _pump(25_000);
        _pokeFor(18 minutes);
        // A stranger liquidates on Morpho directly and gets cUSDG.
        deal(address(BORRO), stranger, 10_000_000e18);
        vm.startPrank(stranger);
        BORRO.approve(address(MORPHO), type(uint256).max);
        (uint256 seize, uint256 repayShares) = liq.plan(d.market, acct);
        MORPHO.liquidate(d.market, acct, seize, repayShares, "");
        uint256 got = IERC20(address(cusdg)).balanceOf(stranger);
        assertGt(got, 0);
        // It cannot post it anywhere on Morpho, nor send it there.
        IERC20(address(cusdg)).approve(address(MORPHO), got);
        vm.expectRevert(bytes("transferFrom reverted")); // Morpho's wording for the gate's refusal
        MORPHO.supplyCollateral(d.market, got, stranger, "");
        vm.expectRevert(CoinCollateral.OnlyShortToMorpho.selector);
        IERC20(address(cusdg)).transfer(address(MORPHO), got);
        // Nor make more.
        vm.expectRevert(CoinCollateral.OnlyShort.selector);
        cusdg.wrap(1, stranger);
        // It can always turn it back into Steakhouse shares.
        cusdg.unwrap(got, stranger);
        assertEq(IERC20(HELD).balanceOf(stranger), got);
        vm.stopPrank();
        assertEq(IERC20(HELD).balanceOf(address(cusdg)), IERC20(address(cusdg)).totalSupply(), "every cUSDG backed one for one");
    }

    function test_fork_the_way_out_without_coinshort() public onFork {
        _listAndLend();
        _open(ann, _room() / 2, 1_500);
        CoinAccount acct = CoinAccount(short.accountOf(ann));
        vm.startPrank(ann);
        vm.expectRevert(CoinAccount.StillOwed.selector);
        acct.withdrawHeld(d.market, 1, ann);
        vm.stopPrank();
        // Someone repays her debt on Morpho directly (with coins bought anywhere).
        uint256 shares = MORPHO.position(d.market.id(), address(acct)).borrowShares;
        deal(address(BORRO), stranger, 10_000_000e18);
        vm.startPrank(stranger);
        BORRO.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(d.market, 0, shares, address(acct), "");
        vm.stopPrank();
        uint256 col = MORPHO.position(d.market.id(), address(acct)).collateral;
        vm.startPrank(ann);
        acct.withdrawHeld(d.market, col, ann);
        cusdg.unwrap(col, ann);
        vm.stopPrank();
        assertEq(IERC20(HELD).balanceOf(ann), col);
    }

    function test_fork_lenders_earn_rent_and_withdraw() public onFork {
        _listAndLend();
        uint256 shares = IVaultV2(d.vault).balanceOf(lender);
        uint256 worth0 = IVaultV2(d.vault).previewRedeem(shares);
        _open(ann, _room() / 2, 1_500);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _pokeFor(18 minutes);
        deal(address(USDG), ann, USDG.balanceOf(ann) + 1_000e6);
        vm.prank(ann);
        short.close(address(BORRO), type(uint256).max, type(uint256).max, 1_000e6, type(uint256).max, block.timestamp + 1);
        uint256 worth1 = IVaultV2(d.vault).previewRedeem(shares);
        console2.log("lender rent over a week (coins)", (worth1 - worth0) / 1e18);
        assertGt(worth1, worth0, "rent earned");
        vm.prank(lender);
        uint256 out = IVaultV2(d.vault).redeem(shares, lender, lender);
        assertEq(BORRO.balanceOf(lender), out);
        assertGe(out, 40_000_000e18 - 1);
    }

    function test_fork_quotes() public onFork {
        _listAndLend();
        uint256 sell = short.quoteSell(address(BORRO), 1_000_000e18);
        uint256 buy = short.quoteBuy(address(BORRO), 1_000_000e18);
        console2.log("1M BORRO: sells for (USDG)", sell);
        console2.log("1M BORRO: buys for (USDG)", buy);
        assertGt(buy, sell, "round trip costs the tax");
        console2.log("round trip cost (bps)", ((buy - sell) * 10_000) / buy);
    }
}
