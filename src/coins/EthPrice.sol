// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IUniV3PoolOracle, IDecimals} from "./CoinFeed.sol";

/// @title EthPrice
/// @notice Dollars per ETH (18 decimals) from a WETH/USDG Uniswap v3 pool's own time-weighted average over `twap`
///         seconds: the same number, by the same math, that every CoinFeed multiplies a coin's ETH price by.
///         CoinListing makes one in its constructor and reads it to measure a coin's market cap before the coin has
///         a feed. No owner, no state but its settings.
contract EthPrice {
    uint256 internal constant Q96 = 2 ** 96;

    IUniV3PoolOracle public immutable pool;
    uint32 public immutable twap;
    bool internal immutable _wethIs0;
    uint256 internal immutable _usdScale; // 1e18 (one ETH) * 10^(18 - USDG decimals)

    error BadPool();

    constructor(IUniV3PoolOracle pool_, address weth, address usdg, uint32 twap_) {
        address t0 = pool_.token0();
        address t1 = pool_.token1();
        if (!((t0 == weth && t1 == usdg) || (t0 == usdg && t1 == weth)) || twap_ == 0) revert BadPool();
        if (IDecimals(weth).decimals() != 18) revert BadPool();
        pool = pool_;
        twap = twap_;
        _wethIs0 = t0 == weth;
        _usdScale = 10 ** (36 - uint256(IDecimals(usdg).decimals()));
    }

    /// @notice Dollars per ETH, 18 decimals. Reverts if the pool cannot give its average.
    function ethUsd() external view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twap;
        (int56[] memory cum,) = pool.observe(ago);
        int56 d = cum[1] - cum[0];
        int56 span = int56(uint56(twap));
        int24 tick = int24(d / span);
        if (d < 0 && d % span != 0) tick--; // round toward minus infinity, as Uniswap does
        uint256 sq = TickMath.getSqrtPriceAtTick(tick);
        // token1 per token0 = sq^2 / 2^192, in wei.
        if (_wethIs0) return FullMath.mulDiv(FullMath.mulDiv(_usdScale, sq, Q96), sq, Q96);
        return FullMath.mulDiv(FullMath.mulDiv(_usdScale, Q96, sq), Q96, sq);
    }
}
