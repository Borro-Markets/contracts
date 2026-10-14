// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CoinLens} from "../../../src/coins/v2/CoinLens.sol";
import {CuratedFeeds} from "../../../src/coins/v2/CuratedFeeds.sol";
import {CuratedListing} from "../../../src/coins/v2/CuratedListing.sol";
import {CoinTwapFeed} from "../../../src/coins/v2/CoinTwapFeed.sol";
import {CoinMedianFeed} from "../../../src/coins/v2/CoinMedianFeed.sol";
import {Venue, VENUE_V3, VENUE_V4, PAIR_ETH, IV3Pool} from "../../../src/coins/v2/VenueDeps.sol";

contract Dec18 {
    uint8 public constant decimals = 18;
    uint256 public totalSupply = 1e27;
}

/// CuratedListing's doors and the feeds' guards, with CoinLens answered by mocked calls.
contract CuratedUnitTest is Test {
    address lens = makeAddr("lens");
    address safe = makeAddr("safe");
    address pool = makeAddr("v3 pool");
    Dec18 coin = new Dec18();
    CuratedListing listing;

    function setUp() public {
        listing = new CuratedListing(CoinLens(lens), CuratedFeeds(makeAddr("feeds")), makeAddr("usdg"), safe, makeAddr("short"));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.check.selector), abi.encode(true, ""));
    }

    function _v3() internal view returns (Venue memory v) {
        v.kind = VENUE_V3;
        v.pool = pool;
        v.pair = PAIR_ETH;
    }

    function test_only_the_safe_allows_and_only_with_a_cap_up_to_5000() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        listing.allow(address(coin), _v3(), 1_000e18);
        vm.startPrank(safe);
        vm.expectRevert(CuratedListing.BadCap.selector);
        listing.allow(address(coin), _v3(), 0);
        vm.expectRevert(CuratedListing.BadCap.selector);
        listing.allow(address(coin), _v3(), 5_000e18 + 1);
        listing.allow(address(coin), _v3(), 2_500e18);
        (Venue memory v, uint256 cap, bool set) = listing.allowedOf(address(coin));
        assertTrue(set);
        assertEq(cap, 2_500e18);
        assertEq(v.pool, pool);
        // Before it lists, allowing it again replaces the venue and the cap.
        listing.allow(address(coin), _v3(), 5_000e18);
        (, cap,) = listing.allowedOf(address(coin));
        assertEq(cap, 5_000e18);
        vm.stopPrank();
    }

    function test_a_venue_the_lens_refuses_is_never_allowed() public {
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.check.selector), abi.encode(false, "the pool does not hold the coin"));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(CuratedListing.CheckFailed.selector, "the pool does not hold the coin"));
        listing.allow(address(coin), _v3(), 1_000e18);
    }

    function test_nothing_lists_unless_allowed_and_a_pause_stops_listing() public {
        vm.expectRevert(CuratedListing.NotAllowed.selector);
        listing.list(address(coin));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        listing.setPaused(true);
        vm.prank(safe);
        listing.setPaused(true);
        vm.expectRevert(CuratedListing.IsPaused.selector);
        listing.list(address(coin));
    }

    function test_listing_refuses_under_ten_million_or_too_shallow() public {
        vm.prank(safe);
        listing.allow(address(coin), _v3(), 5_000e18);
        // A dollar a coin, a billion coins: $1B. Depth $9,999 one way: refused.
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.spotUsd.selector), abi.encode(1e18));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.mcap.selector), abi.encode(1e27));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.depth.selector), abi.encode(9_999e18, 50_000e18));
        CuratedListing.Checks memory c = listing.checks(address(coin));
        assertTrue(c.allowed && c.venueOk && c.decimals18 && c.poolLive && c.mcapOk);
        assertFalse(c.deepEnough);
        vm.expectRevert(abi.encodeWithSelector(CuratedListing.CheckFailed.selector, "depth"));
        listing.list(address(coin));
        // Deep enough both ways but worth a dollar under $10M: refused.
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.depth.selector), abi.encode(10_000e18, 10_000e18));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.mcap.selector), abi.encode(10_000_000e18 - 1e18));
        vm.expectRevert(abi.encodeWithSelector(CuratedListing.CheckFailed.selector, "market cap"));
        listing.list(address(coin));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.mcap.selector), abi.encode(10_000_000e18));
        c = listing.checks(address(coin));
        assertTrue(c.mcapOk && c.deepEnough, "exactly at both floors passes");
    }

    /// The v3 feed: no price and no opens until the pool keeps 1,801 observation slots and a fresh pair price.
    function test_twap_feed_guards() public {
        vm.mockCall(pool, abi.encodeWithSelector(IV3Pool.slot0.selector), abi.encode(uint160(1 << 96), int24(0), uint16(0), uint16(1800), uint16(1801), uint8(0), true));
        CoinTwapFeed f = new CoinTwapFeed(CoinLens(lens), address(coin), _v3());
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.twapUsd.selector), abi.encode(1e18));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.spotUsd.selector), abi.encode(1e18));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.pairUsd.selector), abi.encode(2_000e18, true));
        assertFalse(f.openOk(1_000), "1,800 slots is not enough");
        assertFalse(f.borrowOk(1_000));
        vm.mockCall(pool, abi.encodeWithSelector(IV3Pool.slot0.selector), abi.encode(uint160(1 << 96), int24(0), uint16(0), uint16(1801), uint16(1801), uint8(0), true));
        assertTrue(f.openOk(1_000));
        assertTrue(f.borrowOk(1_000));
        // Spot 11% over the average: no new shorts; loans fine. 11% under: the other way round.
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.spotUsd.selector), abi.encode(1.11e18));
        assertFalse(f.openOk(1_000));
        assertTrue(f.borrowOk(1_000));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.spotUsd.selector), abi.encode(0.89e18));
        assertTrue(f.openOk(1_000));
        assertFalse(f.borrowOk(1_000));
        // A stale stock price behind the pair: nothing new opens, the price still reads.
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.spotUsd.selector), abi.encode(1e18));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.pairUsd.selector), abi.encode(2_000e18, false));
        assertFalse(f.openOk(1_000));
        assertFalse(f.borrowOk(1_000));
        (, int256 p,,,) = f.latestRoundData();
        assertEq(p, 1e18);
        // History too short: no price at all.
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.twapUsd.selector), abi.encode(0));
        vm.expectRevert(abi.encodeWithSelector(CoinTwapFeed.NoPrice.selector, 0, 1));
        f.latestRoundData();
        assertFalse(f.poke(), "nothing to poke");
    }

    /// The v4 feed: a median of observations, as the Pons coins' feed, from the lens's price.
    function testFuzz_median_feed_needs_eight_observations_and_follows_a_held_price(uint64 p0, uint16 jumpBps) public {
        uint256 start = bound(p0, 1e9, 1e24);
        uint256 jump = bound(jumpBps, 1, 50_000);
        Venue memory v;
        v.kind = VENUE_V4;
        v.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(coin)), 0, 200, IHooks(address(0)));
        v.pair = PAIR_ETH;
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.spotUsd.selector), abi.encode(start));
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.pairUsd.selector), abi.encode(2_000e18, true));
        CoinMedianFeed f = new CoinMedianFeed(CoinLens(lens), address(coin), v, 120, 1800, 8);
        vm.expectRevert();
        f.latestRoundData();
        for (uint256 i; i < 80; i++) _step(f);
        (, int256 a,,,) = f.latestRoundData();
        assertEq(uint256(a), start);
        assertTrue(f.openOk(1_000) && f.borrowOk(1_000));
        // A new price held for 20 minutes is the price.
        uint256 moved = (start * (10_000 + jump)) / 10_000;
        vm.mockCall(lens, abi.encodeWithSelector(CoinLens.spotUsd.selector), abi.encode(moved));
        for (uint256 i; i < 80; i++) _step(f);
        (, a,,,) = f.latestRoundData();
        assertEq(uint256(a), moved);
    }

    function _step(CoinMedianFeed f) internal {
        vm.warp(block.timestamp + 15);
        vm.roll(block.number + 1);
        f.poke();
    }
}
