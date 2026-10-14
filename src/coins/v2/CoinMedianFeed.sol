// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CoinLens} from "./CoinLens.sol";
import {Venue, VENUE_V4} from "./VenueDeps.sol";

/// @title CoinMedianFeed
/// @notice A curated coin's delayed dollar price when it trades in a Uniswap v4 pool (any hook, any pair Borro
///         prices), in Chainlink's shape for a Morpho oracle. The same scheme as the Pons coins' CoinFeed: pokes
///         check the pool's price (through CoinLens), checks gather into periods, the median of a period's checks
///         is an observation, and the price is the median of the observations in the last `window` seconds.
/// @dev Nobody sets the price and nothing here has an owner. Anyone may poke(); a keeper only pays the gas.
///      With fewer than `minObs` observations in the window there is no price and latestRoundData reverts.
///      openOk and borrowOk are the guards for new positions: no price, a stale stock price behind the pair, or the
///      pool's price now too far from the delayed one, and they say no. Nothing on the way out reads them.
contract CoinMedianFeed {
    uint8 public constant decimals = 18;
    uint256 public constant version = 1;
    uint256 public constant SLOTS = 32; // observations kept
    uint256 public constant MAX_CHECKS = 8; // checks per period
    uint256 public constant MIN_CHECKS = 3; // the fewest checks a period needs to count
    uint256 internal constant BPS = 10_000;

    CoinLens public immutable lens;
    address public immutable coin;
    // The venue, kept as immutables.
    address internal immutable _c0;
    address internal immutable _c1;
    uint24 internal immutable _fee;
    int24 internal immutable _spacing;
    address internal immutable _hooks;
    uint8 internal immutable _pair;
    bytes32 internal immutable _stockDesk;
    address internal immutable _pairFeed;

    uint32 public immutable spacing; // the length of a period
    uint32 public immutable window; // observations older than this do not count
    uint16 public immutable minObs; // fewer observations in the window than this: no price

    struct Obs {
        uint64 t;
        uint192 price;
    }

    Obs[SLOTS] internal _obs;
    uint256 public count; // observations ever made

    // The open period.
    uint64 public periodStart;
    uint64 public lastCheckAt;
    uint64 public lastCheckBlock;
    uint8 public checks;
    uint128[MAX_CHECKS] internal _check;

    event Checked(uint256 spot, uint256 checks);
    event Observed(uint256 indexed n, uint256 price, uint256 checks);

    error BadPool();
    error BadParams();
    error NoPrice(uint256 observations, uint256 needed);
    error NoSpot();

    constructor(CoinLens lens_, address coin_, Venue memory v, uint32 spacing_, uint32 window_, uint16 minObs_) {
        if (v.kind != VENUE_V4) revert BadPool();
        (bool ok,) = lens_.check(coin_, v);
        if (!ok) revert BadPool();
        if (spacing_ < MAX_CHECKS || minObs_ < 3) revert BadParams();
        if (uint256(window_) / spacing_ >= SLOTS || uint256(window_) / spacing_ < minObs_) revert BadParams();
        lens = lens_;
        coin = coin_;
        _c0 = Currency.unwrap(v.key.currency0);
        _c1 = Currency.unwrap(v.key.currency1);
        _fee = v.key.fee;
        _spacing = v.key.tickSpacing;
        _hooks = address(v.key.hooks);
        _pair = v.pair;
        _stockDesk = v.stockDesk;
        _pairFeed = v.pairFeed;
        spacing = spacing_;
        window = window_;
        minObs = minObs_;
        if (lens_.spotUsd(coin_, v) == 0) revert BadPool();
    }

    /// @notice The pool and pair this feed prices.
    function venue() public view returns (Venue memory v) {
        v.kind = VENUE_V4;
        v.key = PoolKey(Currency.wrap(_c0), Currency.wrap(_c1), _fee, _spacing, IHooks(_hooks));
        v.pair = _pair;
        v.stockDesk = _stockDesk;
        v.pairFeed = _pairFeed;
    }

    // ------------------------------------------------------------------ poke

    /// @notice Close the open period into an observation once it is due, and check the spot price into the period
    ///         that is open after that. Anyone may call it. Returns whether anything changed.
    function poke() external returns (bool changed) {
        if (block.number == lastCheckBlock) return false; // one check per block
        uint256 n = checks;
        if (periodStart == 0 || block.timestamp > uint256(periodStart) + window) {
            periodStart = uint64(block.timestamp); // nothing open, or left open too long: start afresh
            n = 0;
        }
        if (n >= MIN_CHECKS && block.timestamp >= uint256(periodStart) + spacing) {
            uint256 m = _medianOfChecks(n);
            _obs[count % SLOTS] = Obs(uint64(block.timestamp), uint192(m));
            count++;
            emit Observed(count, m, n);
            periodStart = uint64(block.timestamp);
            n = 0;
            changed = true;
        }
        if (n < MAX_CHECKS && (n == 0 || block.timestamp >= uint256(lastCheckAt) + spacing / MAX_CHECKS)) {
            uint256 s = spot();
            if (s != 0) {
                _check[n] = uint128(s);
                n++;
                lastCheckAt = uint64(block.timestamp);
                lastCheckBlock = uint64(block.number);
                emit Checked(s, n);
                changed = true;
            }
        }
        checks = uint8(n);
    }

    // ------------------------------------------------------------------ the price

    /// @notice Chainlink's shape: the median of the observations in the window, dollars per whole coin with 18
    ///         decimals; updatedAt is the newest of them. Reverts when there is no price.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 med, uint256 n, uint256 newest) = _median();
        if (n < minObs) revert NoPrice(n, minObs);
        return (uint80(count), int256(med), newest, newest, uint80(count));
    }

    /// @notice The delayed price, the number of observations behind it and the newest one's time.
    function price() external view returns (uint256 delayed, uint256 observations_, uint256 newest) {
        return _median();
    }

    /// @notice May a short open or grow? Not without a price or a fresh pair price, nor while the pool's price is
    ///         more than `maxAboveBps` above the delayed one.
    function openOk(uint256 maxAboveBps) external view returns (bool) {
        (uint256 med, uint256 n,) = _median();
        if (n < minObs || med == 0 || !_fresh()) return false;
        uint256 s = spot();
        return s != 0 && s * BPS <= med * (BPS + maxAboveBps);
    }

    /// @notice May a loan against the coin open or grow? Not without a price or a fresh pair price, nor while the
    ///         pool's price is more than `maxBelowBps` below the delayed one.
    function borrowOk(uint256 maxBelowBps) external view returns (bool) {
        (uint256 med, uint256 n,) = _median();
        if (n < minObs || med == 0 || !_fresh()) return false;
        return spot() * BPS >= med * (BPS - maxBelowBps);
    }

    /// @notice A whole coin in dollars at the pool's price now, through CoinLens. Zero without a pair price.
    function spot() public view returns (uint256) {
        return lens.spotUsd(coin, venue());
    }

    function _fresh() internal view returns (bool fresh) {
        (, fresh) = lens.pairUsd(venue());
    }

    // ------------------------------------------------------------------ internals

    function _median() internal view returns (uint256 med, uint256 n, uint256 newest) {
        uint256 kept = count < SLOTS ? count : SLOTS;
        uint256[] memory xs = new uint256[](kept);
        uint256 since = block.timestamp > window ? block.timestamp - window : 0;
        for (uint256 i; i < kept; i++) {
            Obs memory o = _obs[(count - 1 - i) % SLOTS];
            if (o.t < since) break; // newest first: everything further back is older
            if (o.t > newest) newest = o.t;
            n = _insert(xs, n, o.price);
        }
        if (n == 0) return (0, 0, 0);
        med = _mid(xs, n);
    }

    function _medianOfChecks(uint256 n) internal view returns (uint256) {
        uint256[] memory xs = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; i++) k = _insert(xs, k, _check[i]);
        return _mid(xs, n);
    }

    function _insert(uint256[] memory xs, uint256 n, uint256 x) internal pure returns (uint256) {
        uint256 j = n;
        while (j > 0 && xs[j - 1] > x) {
            xs[j] = xs[j - 1];
            j--;
        }
        xs[j] = x;
        return n + 1;
    }

    function _mid(uint256[] memory xs, uint256 n) internal pure returns (uint256) {
        return n % 2 == 1 ? xs[n / 2] : (xs[n / 2 - 1] + xs[n / 2]) / 2;
    }
}
