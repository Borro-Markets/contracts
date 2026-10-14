// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {CoinLens} from "./CoinLens.sol";
import {Venue, VENUE_V3, IV3Pool} from "./VenueDeps.sol";

/// @title CoinTwapFeed
/// @notice A curated coin's delayed dollar price when it trades in a Uniswap v3 pool: the pool's own time-weighted
///         average over TWAP seconds (30 minutes, Uniswap's own observations), times the pair's dollars (ETH by
///         the WETH/USDG pool's 30-minute average, USDG one, a stock token by its Chainlink feed). Chainlink's shape,
///         for a Morpho oracle. No owner, no state, nothing to poke.
/// @dev A v3 pool writes at most one observation a second, so with at least MIN_CARDINALITY observation slots its
///      history always covers 30 minutes and cannot be crowded out by many trades; CuratedListing raises the slots
///      when it lists the coin. Until the pool's slots and history cover 30 minutes there is no price: latestRoundData
///      reverts and the guards say no. A coin with no price has no positions, since nothing opens without one.
///      openOk and borrowOk are the guards for new positions; nothing on the way out reads them.
contract CoinTwapFeed {
    uint8 public constant decimals = 18;
    uint256 public constant version = 1;
    uint32 public constant TWAP = 1800;
    uint16 public constant MIN_CARDINALITY = 1801;
    uint256 internal constant BPS = 10_000;

    CoinLens public immutable lens;
    address public immutable coin;
    address public immutable pool;
    uint8 internal immutable _pair;
    bytes32 internal immutable _stockDesk;
    address internal immutable _pairFeed;

    error BadPool();
    error NoPrice(uint256 observations, uint256 needed);

    constructor(CoinLens lens_, address coin_, Venue memory v) {
        if (v.kind != VENUE_V3) revert BadPool();
        (bool ok,) = lens_.check(coin_, v);
        if (!ok) revert BadPool();
        lens = lens_;
        coin = coin_;
        pool = v.pool;
        _pair = v.pair;
        _stockDesk = v.stockDesk;
        _pairFeed = v.pairFeed;
    }

    /// @notice The pool and pair this feed prices.
    function venue() public view returns (Venue memory v) {
        v.kind = VENUE_V3;
        v.pool = pool;
        v.pair = _pair;
        v.stockDesk = _stockDesk;
        v.pairFeed = _pairFeed;
    }

    /// @notice Nothing to do: the pool keeps its own history. Always false, so a keeper that simulates first never
    ///         sends one.
    function poke() external pure returns (bool) {
        return false;
    }

    /// @notice Chainlink's shape: the 30-minute average, dollars per whole coin with 18 decimals. Reverts while the
    ///         pool's history is too short for it.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 p = lens.twapUsd(coin, venue(), TWAP);
        if (p == 0) revert NoPrice(0, 1);
        return (1, int256(p), block.timestamp, block.timestamp, 1);
    }

    /// @notice The delayed price, and (in the shape of the median feeds) 8 "observations" while it exists, 0 while it
    ///         does not; newest is now.
    function price() external view returns (uint256 delayed, uint256 observations, uint256 newest) {
        delayed = lens.twapUsd(coin, venue(), TWAP);
        return (delayed, delayed == 0 ? 0 : 8, block.timestamp);
    }

    /// @notice May a short open or grow? Only with a price, enough observation slots that the window holds, a fresh
    ///         pair price, and the pool's price now no more than `maxAboveBps` above the 30-minute average.
    function openOk(uint256 maxAboveBps) external view returns (bool) {
        (uint256 med, uint256 s) = _ready();
        return med != 0 && s != 0 && s * BPS <= med * (BPS + maxAboveBps);
    }

    /// @notice May a loan against the coin open or grow? As openOk, with the pool's price no more than
    ///         `maxBelowBps` below the average.
    function borrowOk(uint256 maxBelowBps) external view returns (bool) {
        (uint256 med, uint256 s) = _ready();
        return med != 0 && s * BPS >= med * (BPS - maxBelowBps);
    }

    /// @notice A whole coin in dollars at the pool's price now.
    function spot() public view returns (uint256) {
        return lens.spotUsd(coin, venue());
    }

    /// @notice How many observation slots the pool keeps, and how many it will.
    function cardinality() public view returns (uint16 now_, uint16 next) {
        (,,, now_, next,,) = IV3Pool(pool).slot0();
    }

    function _ready() internal view returns (uint256 med, uint256 s) {
        (uint16 slots,) = cardinality();
        if (slots < MIN_CARDINALITY) return (0, 0);
        Venue memory v = venue();
        (, bool fresh) = lens.pairUsd(v);
        if (!fresh) return (0, 0);
        med = lens.twapUsd(coin, v, TWAP);
        s = lens.spotUsd(coin, v);
    }
}
