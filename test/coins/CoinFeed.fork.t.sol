// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CoinFeed, IUniV3PoolOracle} from "../../src/coins/CoinFeed.sol";

/// No graduated Pons coin is worth CoinListing's $10M floor yet ($BORRO was about $58,000 and the deepest one about
/// $166,000 on 2026-10-06). On the copy of the chain, these tests set a coin's market cap by adding to (or taking
/// from) its total supply, held by an address that never trades: the pool, its price and its depth stay as they are.
abstract contract McapKnob is Test {
    address internal constant SUPPLY_HOLDER = address(0x5EED);

    /// Makes `coin`, worth `nowUsd` now (18 decimals), worth `wantUsd` at the same price.
    function _mcapTo(address coin, uint256 nowUsd, uint256 wantUsd) internal {
        uint256 supply = IERC20(coin).totalSupply();
        uint256 want = Math.mulDiv(supply, wantUsd, nowUsd);
        uint256 held = IERC20(coin).balanceOf(SUPPLY_HOLDER);
        if (want >= supply) deal(coin, SUPPLY_HOLDER, held + (want - supply), true);
        else deal(coin, SUPPLY_HOLDER, held - (supply - want), true);
    }
}

/// Swaps ETH and a coin in its v4 pool straight through the PoolManager, so a test can pump, dump and flash.
contract PoolTrader is IUnlockCallback {
    IPoolManager public immutable pm;
    PoolKey public key;

    constructor(IPoolManager pm_, PoolKey memory key_) {
        pm = pm_;
        key = key_;
    }

    receive() external payable {}

    function buy(uint256 ethIn) public returns (uint256 got) {
        got = abi.decode(pm.unlock(abi.encode(true, ethIn)), (uint256));
    }

    function sell(uint256 coinIn) public returns (uint256 got) {
        got = abi.decode(pm.unlock(abi.encode(false, coinIn)), (uint256));
    }

    /// Pump, check the feed, dump: all in one transaction.
    function flash(uint256 ethIn, CoinFeed feed) external returns (bool checked) {
        uint256 coins = buy(ethIn);
        checked = feed.poke();
        sell(coins);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (bool ethIn, uint256 amount) = abi.decode(data, (bool, uint256));
        BalanceDelta d = pm.swap(
            key,
            SwapParams({zeroForOne: ethIn, amountSpecified: -int256(amount), sqrtPriceLimitX96: ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        uint256 got;
        if (a0 < 0) pm.settle{value: uint256(uint128(-a0))}();
        if (a1 < 0) {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint256(uint128(-a1)));
            pm.settle();
        }
        if (a0 > 0) {
            got = uint256(uint128(a0));
            pm.take(key.currency0, address(this), got);
        }
        if (a1 > 0) {
            got = uint256(uint128(a1));
            pm.take(key.currency1, address(this), got);
        }
        return abi.encode(got);
    }
}

/// CoinFeed against the live $BORRO Pons pool (graduated, ETH against the coin, Pons's hook) and the live WETH/USDG
/// v3 pool, on a copy of Robinhood Chain. Set BORRO_FORK_RPC to run.
contract CoinFeedForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant BORRO = 0x89B76DCDDa801f2e456765742C64950eB2A0c93C;
    IUniV3PoolOracle constant ETH_POOL = IUniV3PoolOracle(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint32 constant SPACING = 120;
    uint32 constant WINDOW = 1800;
    uint16 constant MIN_OBS = 8;
    uint32 constant CHECK = 15;

    PoolKey key;
    CoinFeed feed;
    PoolTrader trader;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(BORRO), fee: 0, tickSpacing: 200, hooks: IHooks(PONS_HOOK)});
        address weth = ETH_POOL.token0() == USDG ? ETH_POOL.token1() : ETH_POOL.token0();
        feed = new CoinFeed(PM, key, ETH_POOL, weth, USDG, SPACING, WINDOW, MIN_OBS, 1800);
        trader = new PoolTrader(PM, key);
        vm.deal(address(trader), 1_000 ether);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _step(uint256 dt) internal returns (bool) {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 1);
        return feed.poke();
    }

    function _run(uint256 secs) internal {
        for (uint256 t; t < secs; t += CHECK) _step(CHECK);
    }

    function _delayed() internal view returns (uint256 p) {
        (, int256 a,,,) = feed.latestRoundData();
        p = uint256(a);
    }

    /// ETH needed to move the spot price up by `upBps`, found by doubling then halving on copies of the state.
    function _ethToPush(uint256 upBps) internal returns (uint256 lo) {
        uint256 s0 = feed.spot();
        uint256 hi = 0.01 ether;
        while (true) {
            uint256 snap = vm.snapshotState();
            trader.buy(hi);
            uint256 s1 = feed.spot();
            vm.revertToState(snap);
            if (s1 * 10_000 >= s0 * (10_000 + upBps)) break;
            lo = hi;
            hi *= 2;
            require(hi < 900 ether, "pool too deep to push in this test");
        }
        for (uint256 i; i < 24; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            trader.buy(mid);
            uint256 s1 = feed.spot();
            vm.revertToState(snap);
            if (s1 * 10_000 >= s0 * (10_000 + upBps)) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    // ------------------------------------------------------------------

    function test_fork_the_pool_and_the_price() public onFork {
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        uint128 liq = PM.getLiquidity(key.toId());
        uint256 ethDepth = (uint256(liq) * 2 ** 96) / sqrtP; // the ETH side of the in-range liquidity, virtual
        console2.log("BORRO pool liquidity", liq);
        console2.log("ETH side of the pool, virtual (wei)", ethDepth);
        console2.log("ETH in dollars (18 dec)", feed.ethUsd());
        console2.log("BORRO spot in dollars (18 dec)", feed.spot());
        assertGt(feed.spot(), 0);
        assertApproxEqRel(feed.ethUsd(), 2_700e18, 0.5e18, "ETH within a sane range");
    }

    function test_fork_a_flash_pump_in_one_transaction_does_not_move_the_price() public onFork {
        _run(WINDOW + SPACING);
        uint256 p0 = _delayed();
        uint256 eth = _ethToPush(10_000); // doubles the price
        console2.log("ETH to double the price in one go", eth);
        // Every period from here on, one check lands inside a pump-poke-dump transaction. Each round trip leaves
        // the pool a little dearer (Pons's hook keeps part of its tax), so the honest price drifts up too: the
        // feed must follow that, never the doubled price inside the flash.
        uint256 honestMax = feed.spot();
        for (uint256 k; k < 16; k++) {
            vm.warp(vm.getBlockTimestamp() + CHECK);
            vm.roll(vm.getBlockNumber() + 1);
            assertTrue(trader.flash(eth, feed), "the pumped check was taken");
            uint256 s = feed.spot();
            if (s > honestMax) honestMax = s;
            _run(SPACING - CHECK);
        }
        console2.log("honest price drift over 16 flashes (bps)", (honestMax - p0) * 10_000 / p0);
        assertLe(_delayed(), honestMax * 10_001 / 10_000, "the price never saw the flash");
        assertGe(_delayed(), p0 * 9_999 / 10_000);
        CoinFeed.Obs[] memory o = feed.observations();
        for (uint256 i; i < o.length; i++) assertLe(o[i].price, honestMax * 10_001 / 10_000, "nor did any observation");
    }

    function test_fork_a_pump_held_in_one_block_does_not_move_the_price() public onFork {
        _run(WINDOW + SPACING);
        uint256 p0 = _delayed();
        uint256 eth = _ethToPush(10_000);
        uint256 honestMax = feed.spot();
        for (uint256 k; k < 16; k++) {
            vm.warp(vm.getBlockTimestamp() + CHECK);
            vm.roll(vm.getBlockNumber() + 1);
            uint256 coins = trader.buy(eth); // pumped in this block
            assertTrue(feed.poke());
            vm.roll(vm.getBlockNumber() + 1); // and dumped at the start of the next
            trader.sell(coins);
            uint256 s = feed.spot();
            if (s > honestMax) honestMax = s;
            _run(SPACING - CHECK);
        }
        assertLe(_delayed(), honestMax * 10_001 / 10_000, "the price never saw the pump");
        assertGe(_delayed(), p0 * 9_999 / 10_000);
    }

    function test_fork_a_held_pump_moves_the_price_only_after_half_the_window() public onFork {
        _run(WINDOW + SPACING);
        uint256 p0 = _delayed();
        uint256 eth = _ethToPush(5_000); // up 50%, and held
        trader.buy(eth);
        uint256 target = feed.spot();
        assertFalse(feed.openOk(1_000), "the spot is 50% over the delayed price: no new shorts");
        uint256 start = vm.getBlockTimestamp();
        uint256 moved;
        uint256 arrived;
        while (vm.getBlockTimestamp() < start + WINDOW + SPACING) {
            _step(CHECK);
            uint256 p = _delayed();
            if (moved == 0 && p > p0 * 10_010 / 10_000) moved = vm.getBlockTimestamp() - start;
            if (arrived == 0 && p * 10_000 >= target * 9_990) arrived = vm.getBlockTimestamp() - start;
        }
        console2.log("held +50%: seconds until the price moved", moved);
        console2.log("held +50%: seconds until it arrived", arrived);
        assertGe(moved, 7 * SPACING);
        assertLe(arrived, 9 * SPACING);
        assertTrue(feed.openOk(1_000), "caught up: shorts may open again");
    }

    function test_fork_a_held_dump_moves_the_price_on_the_same_schedule() public onFork {
        _run(WINDOW + SPACING);
        uint256 p0 = _delayed();
        deal(BORRO, address(trader), IERC20(BORRO).totalSupply() / 20);
        uint256 hi = IERC20(BORRO).balanceOf(address(trader));
        // Sell enough to take the price down about 40%.
        uint256 lo;
        for (uint256 i; i < 40; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            trader.sell(mid);
            uint256 s1 = feed.spot();
            vm.revertToState(snap);
            if (s1 * 10_000 <= p0 * 6_000) hi = mid;
            else lo = mid;
        }
        trader.sell(hi);
        uint256 target = feed.spot();
        uint256 start = vm.getBlockTimestamp();
        uint256 moved;
        uint256 arrived;
        while (vm.getBlockTimestamp() < start + WINDOW + SPACING) {
            _step(CHECK);
            uint256 p = _delayed();
            if (moved == 0 && p < p0 * 9_990 / 10_000) moved = vm.getBlockTimestamp() - start;
            if (arrived == 0 && p * 10_000 <= target * 10_010) arrived = vm.getBlockTimestamp() - start;
        }
        console2.log("held -40%: seconds until the price moved", moved);
        console2.log("held -40%: seconds until it arrived", arrived);
        assertGe(moved, 7 * SPACING);
        assertLe(arrived, 9 * SPACING);
    }

    function test_fork_stale_then_back() public onFork {
        _run(WINDOW + SPACING);
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(abi.encodeWithSelector(CoinFeed.NoPrice.selector, 0, MIN_OBS));
        feed.latestRoundData();
        assertFalse(feed.openOk(100_000));
        uint256 t0 = vm.getBlockTimestamp();
        uint256 back;
        while (back == 0) {
            _step(CHECK);
            (, uint256 n,) = feed.price();
            if (n >= MIN_OBS) back = vm.getBlockTimestamp() - t0;
        }
        console2.log("seconds of pokes to have a price again", back);
        assertApproxEqRel(_delayed(), feed.spot(), 0.0001e18);
    }

    function test_fork_gas_and_manipulation_cost() public onFork {
        // Gas: a plain check, and the poke that closes a period into an observation.
        _run(WINDOW + SPACING);
        uint256 maxCheck;
        uint256 maxClose;
        for (uint256 i; i < 16; i++) {
            vm.warp(vm.getBlockTimestamp() + CHECK);
            vm.roll(vm.getBlockNumber() + 1);
            uint256 before = feed.count();
            uint256 g = gasleft();
            feed.poke();
            g -= gasleft();
            if (feed.count() > before) maxClose = g > maxClose ? g : maxClose;
            else maxCheck = g > maxCheck ? g : maxCheck;
        }
        uint256 g2 = gasleft();
        feed.latestRoundData();
        console2.log("gas: poke (check)", maxCheck);
        console2.log("gas: poke (closes a period)", maxClose);
        console2.log("gas: latestRoundData (Morpho reads it)", g2 - gasleft());

        // What one round trip costs (buy enough to push the price up, sell it all straight back), by size.
        uint256[4] memory ups = [uint256(1_000), 2_500, 5_000, 10_000];
        for (uint256 i; i < ups.length; i++) {
            uint256 eth = _ethToPush(ups[i]);
            uint256 snap = vm.snapshotState();
            uint256 balBefore = address(trader).balance;
            uint256 coins = trader.buy(eth);
            trader.sell(coins);
            uint256 lost = balBefore - address(trader).balance;
            vm.revertToState(snap);
            console2.log("push up (bps)", ups[i]);
            console2.log("  ETH in", eth);
            console2.log("  ETH lost on the round trip", lost);
        }
    }
}
