// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

// Curated coins (phase 2, docs/COIN-SHORTS.md): coins the Safe allows one by one, wherever they trade on Uniswap,
// beside the Pons-only coin shorts of contracts/src/coins (left exactly as deployed).

uint8 constant VENUE_V3 = 1; // a Uniswap v3 pool
uint8 constant VENUE_V4 = 2; // a Uniswap v4 pool, any hook
uint8 constant PAIR_ETH = 1; // native ETH (v4) or WETH
uint8 constant PAIR_USDG = 2;
uint8 constant PAIR_STOCK = 3; // a stock token Borro lists on BorroShort

/// Where a curated coin trades, and how its pair token becomes dollars (docs/COIN-SHORTS.md). The Safe names it when
/// it allows a coin; CuratedListing checks it on chain and it never changes once the coin is listed.
struct Venue {
    uint8 kind; // VENUE_V3 or VENUE_V4
    address pool; // VENUE_V3: the pool; VENUE_V4: zero
    PoolKey key; // VENUE_V4: the pool's key; VENUE_V3: zero
    uint8 pair; // PAIR_ETH, PAIR_USDG or PAIR_STOCK
    bytes32 stockDesk; // PAIR_STOCK: the stock's market id on BorroShort (its route to USDG, its Chainlink feed)
    address pairFeed; // PAIR_STOCK: that desk's Chainlink feed (checked against BorroShort when allowed)
}

/// One listed coin, as CuratedListing records it and the curated coin contracts read it.
struct CuratedDesk {
    MarketParams market; // loan: the coin; collateral: cUSDG; the coin's oracle; the adaptive IRM; LLTV 38.5%
    Venue venue; // where it trades and is priced
    address feed; // the coin's delayed price (CoinFeed for v4, CoinTwapFeed for v3)
    address vault; // b<COIN>, the coin's lending vault
    uint64 listedAt;
}

/// What a coin's delayed price feed answers, whichever kind it is.
interface ICoinFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function price() external view returns (uint256 delayed, uint256 observations, uint256 newest);
    function spot() external view returns (uint256);
    function openOk(uint256 maxAboveBps) external view returns (bool);
    function borrowOk(uint256 maxBelowBps) external view returns (bool);
    function poke() external returns (bool);
}

interface ICuratedListing {
    function deskOf(address coin) external view returns (CuratedDesk memory);
    /// Coins that may be shorted in all now, and the coins the pool gives up within a 10% rise at the delayed price.
    function capOf(address coin) external view returns (uint256 cap, uint256 depthCoins);
    /// Coins the pool gives up within a 10% rise and takes in within a 10% fall, at the delayed price, and whether
    /// the coin clears every floor there (market cap and depth).
    function depthOf(address coin) external view returns (uint256 up, uint256 down, uint256 delayed, bool floorsOk);
    /// USDG (6 decimals) that may be lent against the coin in all now, and the dollars the pool takes in during a 10% fall.
    function loanCapOf(address coin) external view returns (uint256 cap, uint256 downUsd);
    function curatedShort() external view returns (address);
}

/// Uniswap v3, as far as the coin contracts read and trade it.
interface IV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function factory() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
    function tickBitmap(int16 wordPosition) external view returns (uint256);
    function ticks(int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet, uint256, uint256, int56, uint160, uint32, bool initialized);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// BorroShort's record of a stock: its market (the stock is the loan token), its route to USDG and its feed.
interface IStockDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed);
}
