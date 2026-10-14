// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

interface IUniV3PoolOracle {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title CoinFeed
/// @notice A delayed dollar price (USDG per whole coin, 18 decimals) for one coin that trades against ETH in a
///         Uniswap v4 pool (a graduated Pons coin), in the shape of a Chainlink feed so a Morpho oracle can read it.
///         It is the price a coin-shorts market lends and liquidates by (docs/COIN-SHORTS.md).
/// @dev Nobody sets the price and nothing here has an owner. Anyone may poke(); a keeper only pays the gas.
///      How a price gets in:
///      - Each poke is a check: the coin's spot price now (the v4 pool's sqrtPrice, times ETH's dollar price from
///        the WETH/USDG Uniswap v3 pool's own time-weighted average over `ethTwap` seconds). At most one check per
///        block, and checks at least `spacing / MAX_CHECKS` seconds apart.
///      - Checks gather into a period. Once a period is `spacing` seconds old and holds at least MIN_CHECKS
///        checks, the next poke closes it: the median of its checks becomes one observation. A price pushed for
///        one transaction or one block (pump, poke, dump) is one check out of several; to move an observation it
///        must be the price at more than half of a period's checks, which are made by whoever pokes (the keeper,
///        every short opened or closed, every liquidator), so it must hold across blocks.
///      - A period left open longer than `window` is thrown away.
///      The price is the median of the observations made in the last `window` seconds. A median, not an average:
///      a minority of bad observations cannot move it at all, where one extreme sample moves an average in
///      proportion. With fewer than `minObs` of them the feed has no price and latestRoundData reverts: Morpho then
///      refuses every action that needs a price (borrowing, taking collateral out of a position with debt,
///      liquidating) until enough fresh observations are made. Repaying, and taking collateral out of a position
///      with no debt left, never need a price.
///      openOk() is the guard a shorting contract checks before a short opens or grows: no price, or a spot price
///      far above the delayed one (the delayed price lagging a rise, which would let shorts borrow too much coin
///      for their collateral), and it says no.
contract CoinFeed {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 public constant decimals = 18;
    uint256 public constant version = 1;
    uint256 public constant SLOTS = 32; // observations kept
    uint256 public constant MAX_CHECKS = 8; // checks per period
    uint256 public constant MIN_CHECKS = 3; // the fewest checks a period needs to count
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;
    address public immutable coin;
    IUniV3PoolOracle public immutable ethPool;
    bool internal immutable _wethIs0; // in the ETH/USDG pool
    uint256 internal immutable _coinUnit; // 10 ** coin decimals
    uint256 internal immutable _usdScale; // 1e18 (one ETH) * 10^(18 - USDG decimals)

    uint32 public immutable spacing; // the length of a period
    uint32 public immutable window; // observations older than this do not count
    uint16 public immutable minObs; // fewer observations in the window than this: no price
    uint32 public immutable ethTwap; // seconds of the ETH/USDG pool's time-weighted average

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

    /// @param key The coin's v4 pool: native ETH (currency0) against the coin.
    /// @param ethPool_ A Uniswap v3 pool of WETH and USDG with enough observation history for `ethTwap_`.
    constructor(
        IPoolManager poolManager_,
        PoolKey memory key,
        IUniV3PoolOracle ethPool_,
        address weth,
        address usdg,
        uint32 spacing_,
        uint32 window_,
        uint16 minObs_,
        uint32 ethTwap_
    ) {
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)) revert BadPool();
        address t0 = ethPool_.token0();
        address t1 = ethPool_.token1();
        if (!((t0 == weth && t1 == usdg) || (t0 == usdg && t1 == weth))) revert BadPool();
        if (IDecimals(weth).decimals() != 18) revert BadPool();
        if (spacing_ < MAX_CHECKS || minObs_ < 3 || ethTwap_ == 0) revert BadParams();
        // Every observation the window can hold must still be kept, and the window must fit minObs of them.
        if (uint256(window_) / spacing_ >= SLOTS || uint256(window_) / spacing_ < minObs_) revert BadParams();
        poolManager = poolManager_;
        poolId = key.toId();
        (uint160 sqrtP,,,) = poolManager_.getSlot0(key.toId());
        if (sqrtP == 0) revert BadPool();
        coin = Currency.unwrap(key.currency1);
        ethPool = ethPool_;
        _wethIs0 = t0 == weth;
        _coinUnit = 10 ** IDecimals(coin).decimals();
        _usdScale = 10 ** (36 - uint256(IDecimals(usdg).decimals()));
        spacing = spacing_;
        window = window_;
        minObs = minObs_;
        ethTwap = ethTwap_;
    }

    // ------------------------------------------------------------------ poke

    /// @notice Close the open period into an observation once it is due, and check the spot price into the period
    ///         that is open after that. Anyone may call it. Returns whether anything changed (a period closed or a
    ///         check taken), so a caller that simulates first knows whether sending it is worth the gas.
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
            _check[n] = uint128(s);
            n++;
            lastCheckAt = uint64(block.timestamp);
            lastCheckBlock = uint64(block.number);
            emit Checked(s, n);
            changed = true;
        }
        checks = uint8(n);
    }

    // ------------------------------------------------------------------ the price

    /// @notice Chainlink's shape. The answer is the median of the observations in the window, in USDG per whole
    ///         coin with 18 decimals; updatedAt is the newest of them. Reverts when there is no price.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 med, uint256 n, uint256 newest) = _median();
        if (n < minObs) revert NoPrice(n, minObs);
        return (uint80(count), int256(med), newest, newest, uint80(count));
    }

    /// @notice The delayed price, the number of observations behind it and the newest one's time. With fewer than
    ///         minObs observations there is no price.
    function price() external view returns (uint256 delayed, uint256 observations_, uint256 newest) {
        return _median();
    }

    /// @notice May a short open or grow now? No without a price, and no while the spot price is more than
    ///         `maxAboveBps` above the delayed one.
    function openOk(uint256 maxAboveBps) external view returns (bool) {
        (uint256 med, uint256 n,) = _median();
        if (n < minObs || med == 0) return false;
        return spot() * BPS <= med * (BPS + maxAboveBps);
    }

    /// @notice The coin's price right now: the v4 pool's spot price times ETH's time-weighted dollar price.
    function spot() public view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        if (sqrtP == 0) revert NoSpot();
        // The pool prices coin wei per ETH wei (currency1 per currency0) as sqrtP^2 / 2^192, so a coin wei costs
        // 2^192 / sqrtP^2 ETH wei; a whole coin, that times the coin's unit, in dollars per ETH over 1e18.
        uint256 x = FullMath.mulDiv(FullMath.mulDiv(ethUsd(), Q96, sqrtP), Q96, sqrtP);
        return FullMath.mulDiv(x, _coinUnit, 1e18);
    }

    /// @notice Dollars per ETH, 18 decimals, from the WETH/USDG v3 pool's own average over `ethTwap` seconds.
    function ethUsd() public view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = ethTwap;
        (int56[] memory cum,) = ethPool.observe(ago);
        int56 d = cum[1] - cum[0];
        int24 tick = int24(d / int56(uint56(ethTwap)));
        if (d < 0 && (d % int56(uint56(ethTwap)) != 0)) tick--; // round toward minus infinity, as Uniswap does
        uint256 sq = TickMath.getSqrtPriceAtTick(tick);
        // token1 per token0 = sq^2 / 2^192, in wei.
        if (_wethIs0) return FullMath.mulDiv(FullMath.mulDiv(_usdScale, sq, Q96), sq, Q96);
        return FullMath.mulDiv(FullMath.mulDiv(_usdScale, Q96, sq), Q96, sq);
    }

    /// @notice Every observation still kept, oldest first.
    function observations() external view returns (Obs[] memory out) {
        uint256 n = count < SLOTS ? count : SLOTS;
        out = new Obs[](n);
        for (uint256 i; i < n; i++) out[i] = _obs[(count - n + i) % SLOTS];
    }

    /// @notice The open period's checks so far.
    function openChecks() external view returns (uint256[] memory out) {
        out = new uint256[](checks);
        for (uint256 i; i < out.length; i++) out[i] = _check[i];
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

    /// @dev Inserts x into the sorted first n entries of xs; returns n + 1.
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
