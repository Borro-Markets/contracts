// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CoinFeed, IUniV3PoolOracle} from "../../src/coins/CoinFeed.sol";

contract FeedToken {
    uint8 public decimals;
    uint256 public totalSupply;

    constructor(uint8 d) {
        decimals = d;
    }

    function setSupply(uint256 s) external {
        totalSupply = s;
    }
}

/// Answers StateLibrary.getSlot0 for any pool: sqrtPrice in the low 160 bits.
contract FakeManager {
    uint160 public sqrtP;

    function set(uint160 s) external {
        sqrtP = s;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(sqrtP));
    }
}

/// A v3 pool whose average tick over any span is `tick`.
contract FakeV3 {
    address public token0;
    address public token1;
    int24 public tick;

    constructor(address t0, address t1, int24 t) {
        (token0, token1, tick) = (t0, t1, t);
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory cum, uint160[] memory) {
        cum = new int56[](ago.length);
        for (uint256 i; i < ago.length; i++) cum[i] = int56(tick) * int56(int256(block.timestamp - ago[i]));
        return (cum, new uint160[](ago.length));
    }
}

/// The delayed coin price (docs/COIN-SHORTS.md): checks, periods, the median, staleness and the open guard.
contract CoinFeedTest is Test {
    FeedToken weth = new FeedToken(18);
    FeedToken usdg = new FeedToken(6);
    FeedToken coin = new FeedToken(18);
    FakeManager pm = new FakeManager();
    FakeV3 v3;
    CoinFeed feed;
    uint160 base; // the coin's starting sqrtPrice

    uint32 constant SPACING = 120;
    uint32 constant WINDOW = 1800;
    uint16 constant MIN_OBS = 8;
    uint32 constant CHECK = 15; // SPACING / MAX_CHECKS

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1_000_000);
        // ETH at tick -200311: about 2,000 USDG (6 decimals) per WETH (18 decimals).
        v3 = new FakeV3(address(weth), address(usdg), -200_311);
        // 1e9 coin per ETH: sqrtPrice = sqrt(1e9) * 2^96.
        base = uint160(Math.sqrt(1e9) * 2 ** 96);
        pm.set(base);
        feed = new CoinFeed(IPoolManager(address(pm)), _key(), IUniV3PoolOracle(address(v3)), address(weth), address(usdg), SPACING, WINDOW, MIN_OBS, 1800);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(coin)), fee: 0, tickSpacing: 200, hooks: IHooks(address(0))});
    }

    /// The coin's price times m/10_000 (a lower sqrtPrice is fewer coins per ETH: a dearer coin).
    function _setPrice(uint256 mBps) internal {
        pm.set(uint160((uint256(base) * 100 * 1e9) / Math.sqrt(mBps * 1e18)));
    }

    function _step(uint256 dt) internal returns (bool) {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 1);
        return feed.poke();
    }

    /// Pokes every CHECK seconds for `secs`.
    function _run(uint256 secs) internal {
        for (uint256 t; t < secs; t += CHECK) _step(CHECK);
    }

    function _delayed() internal view returns (uint256 p) {
        (, int256 a,,,) = feed.latestRoundData();
        p = uint256(a);
    }

    function _near(uint256 a, uint256 b, uint256 bps) internal pure returns (bool) {
        uint256 d = a > b ? a - b : b - a;
        return d * 10_000 <= b * bps;
    }

    // ------------------------------------------------------------------ the numbers

    function test_spot_is_the_pool_price_times_eth_in_dollars() public view {
        uint256 eth = feed.ethUsd();
        assertApproxEqRel(eth, 2_000e18, 0.002e18, "ETH about $2,000");
        // 1e9 coins per ETH: a coin is ETH / 1e9.
        assertApproxEqRel(feed.spot(), eth / 1e9, 1e14, "a coin is a billionth of an ETH");
    }

    function test_constructor_refuses_a_pool_not_against_eth_and_bad_numbers() public {
        PoolKey memory k = _key();
        k.currency0 = Currency.wrap(address(usdg));
        vm.expectRevert(CoinFeed.BadPool.selector);
        new CoinFeed(IPoolManager(address(pm)), k, IUniV3PoolOracle(address(v3)), address(weth), address(usdg), SPACING, WINDOW, MIN_OBS, 1800);
        FakeV3 other = new FakeV3(address(weth), address(coin), 0);
        vm.expectRevert(CoinFeed.BadPool.selector);
        new CoinFeed(IPoolManager(address(pm)), _key(), IUniV3PoolOracle(address(other)), address(weth), address(usdg), SPACING, WINDOW, MIN_OBS, 1800);
        vm.expectRevert(CoinFeed.BadParams.selector);
        new CoinFeed(IPoolManager(address(pm)), _key(), IUniV3PoolOracle(address(v3)), address(weth), address(usdg), SPACING, WINDOW, 16, 1800); // 15 fit, 16 asked
        vm.expectRevert(CoinFeed.BadParams.selector);
        new CoinFeed(IPoolManager(address(pm)), _key(), IUniV3PoolOracle(address(v3)), address(weth), address(usdg), 60, 3600, MIN_OBS, 1800); // 60 would not be kept
    }

    // ------------------------------------------------------------------ checks and periods

    function test_one_check_per_block_and_checks_spaced() public {
        assertTrue(_step(1));
        assertFalse(feed.poke(), "same block");
        assertFalse(_step(CHECK - 2), "too soon after the last check");
        assertTrue(_step(2));
        assertEq(feed.checks(), 2);
    }

    function test_no_price_until_min_obs_observations() public {
        vm.expectRevert(abi.encodeWithSelector(CoinFeed.NoPrice.selector, 0, MIN_OBS));
        feed.latestRoundData();
        _run(SPACING * (MIN_OBS - 1) + CHECK);
        (, uint256 n,) = feed.price();
        assertEq(n, MIN_OBS - 1);
        vm.expectRevert(abi.encodeWithSelector(CoinFeed.NoPrice.selector, MIN_OBS - 1, MIN_OBS));
        feed.latestRoundData();
        _run(SPACING);
        assertEq(_delayed(), feed.spot(), "steady price: the delayed price is the spot price");
    }

    function test_a_spike_in_one_check_does_not_move_its_observation() public {
        _run(WINDOW);
        uint256 p0 = _delayed();
        // In each of the next periods, one check of eight sees the coin at ten times its price.
        for (uint256 k; k < 20; k++) {
            _setPrice(100_000);
            _step(CHECK);
            _setPrice(10_000);
            _run(SPACING - CHECK);
        }
        assertEq(_delayed(), p0, "spikes in a minority of checks never reach the price");
        Obs[] memory obs = _obsOf();
        for (uint256 i; i < obs.length; i++) assertEq(obs[i].price, p0, "nor any observation");
    }

    struct Obs {
        uint64 t;
        uint192 price;
    }

    function _obsOf() internal view returns (Obs[] memory out) {
        CoinFeed.Obs[] memory o = feed.observations();
        out = new Obs[](o.length);
        for (uint256 i; i < o.length; i++) out[i] = Obs(o[i].t, o[i].price);
    }

    function test_a_held_rise_reaches_the_price_after_half_the_window() public {
        _run(WINDOW);
        uint256 p0 = _delayed();
        _setPrice(15_000); // up 50%, and it stays
        uint256 start = vm.getBlockTimestamp();
        uint256 moved;
        while (vm.getBlockTimestamp() < start + WINDOW) {
            _step(CHECK);
            if (moved == 0 && _delayed() > p0) moved = vm.getBlockTimestamp() - start;
        }
        // 15 observations fit the window: the median moves once 8 are new, the 8th closing about 16 minutes in.
        assertGe(moved, 7 * SPACING, "not before half the window");
        assertLe(moved, 9 * SPACING, "by just over half the window");
        assertTrue(_near(_delayed(), (p0 * 15_000) / 10_000, 1), "then all the way");
    }

    function test_a_held_fall_reaches_the_price_on_the_same_schedule() public {
        _run(WINDOW);
        uint256 p0 = _delayed();
        _setPrice(5_000);
        uint256 start = vm.getBlockTimestamp();
        uint256 moved;
        while (vm.getBlockTimestamp() < start + WINDOW) {
            _step(CHECK);
            if (moved == 0 && _delayed() < p0) moved = vm.getBlockTimestamp() - start;
        }
        assertGe(moved, 7 * SPACING);
        assertLe(moved, 9 * SPACING);
        assertTrue(_near(_delayed(), p0 / 2, 1));
    }

    function test_without_pokes_the_feed_goes_without_a_price_and_comes_back() public {
        _run(WINDOW);
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(abi.encodeWithSelector(CoinFeed.NoPrice.selector, 0, MIN_OBS));
        feed.latestRoundData();
        assertFalse(feed.openOk(10_000), "no price: no opens");
        // The price moved while nobody looked; it comes back at the new price, never the old one.
        _setPrice(30_000);
        _run(SPACING * MIN_OBS + CHECK);
        assertTrue(_near(_delayed(), feed.spot(), 1));
    }

    function test_a_period_left_open_past_the_window_is_thrown_away() public {
        _step(CHECK);
        _step(CHECK); // two checks at the old price, period still open
        _setPrice(20_000);
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        vm.roll(vm.getBlockNumber() + 1);
        feed.poke();
        assertEq(feed.checks(), 1, "a fresh period with today's check only");
        assertEq(feed.openChecks()[0], feed.spot());
    }

    // ------------------------------------------------------------------ the open guard

    function test_open_guard_holds_shorts_while_the_spot_runs_ahead() public {
        _run(WINDOW);
        assertTrue(feed.openOk(1_000));
        _setPrice(12_000); // spot 20% over the delayed price
        assertFalse(feed.openOk(1_000), "10% allowed, 20% ahead: no");
        assertTrue(feed.openOk(2_500));
        _run(WINDOW);
        assertTrue(feed.openOk(1_000), "caught up");
    }

    // ------------------------------------------------------------------ fuzz

    /// An observation is the median of its period's checks, whatever they are.
    function testFuzz_observation_is_the_median_of_its_checks(uint256[8] memory raw) public {
        uint256[] memory seen = new uint256[](8);
        for (uint256 i; i < 8; i++) {
            uint256 m = bound(raw[i], 100, 1_000_000); // 0.01x to 100x
            _setPrice(m);
            _step(CHECK);
            seen[i] = feed.spot();
        }
        assertEq(feed.checks(), 8);
        _step(CHECK); // the period is 120s old: this poke closes it (no room for a ninth check)
        CoinFeed.Obs[] memory o = feed.observations();
        assertEq(o.length, 1);
        // reference median of the 8 checks
        for (uint256 i; i < 8; i++) {
            for (uint256 j = i + 1; j < 8; j++) if (seen[j] < seen[i]) (seen[i], seen[j]) = (seen[j], seen[i]);
        }
        assertEq(o[0].price, (seen[3] + seen[4]) / 2);
    }

    /// Whatever a minority of each period's checks see, every observation stays within the honest checks' range.
    function testFuzz_a_minority_of_checks_cannot_move_observations(uint256 seed) public {
        // Six periods; in each, the checks at three of the eight places see 100x or 0.01x.
        uint256 target = feed.count() + 6;
        uint256 guard;
        while (feed.count() < target && guard++ < 200) {
            // Where this check lands: a full period closes first, and the check opens the next one.
            uint256 pos = feed.checks();
            uint256 cnt = feed.count();
            if (pos == 8) (pos, cnt) = (0, cnt + 1);
            bool bad = (pos + cnt + (seed % 8)) % 8 < 3;
            uint256 x = uint256(keccak256(abi.encode(seed, guard)));
            _setPrice(bad ? (x % 2 == 0 ? 1_000_000 : 100) : 10_000 + (x % 200)); // honest: within 2%
            _step(CHECK);
        }
        _setPrice(10_000);
        uint256 honestLo = feed.spot() * 9_990 / 10_000;
        _setPrice(10_200);
        uint256 honestHi = feed.spot() * 10_010 / 10_000;
        CoinFeed.Obs[] memory o = feed.observations();
        assertGt(o.length, 0);
        for (uint256 i; i < o.length; i++) {
            assertGe(o[i].price, honestLo);
            assertLe(o[i].price, honestHi);
        }
    }
}
