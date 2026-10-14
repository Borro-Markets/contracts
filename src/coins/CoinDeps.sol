// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

/// What Pons's factory records about a coin it launched (read from the live factory, 2026-10-06).
struct PonsLaunch {
    address token;
    address curve;
    address deployer;
    address creatorFeeRecipient;
    address pairToken; // zero: native ETH
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    uint8 phase; // 0 on the curve, 1 swept, 2 in its pool (graduated), 3 rescued
    uint256 sweptQuote;
    uint256 sweptTokens;
    uint256 sweptAt;
    bool exists;
}

interface IPonsFactory {
    function getLaunchedToken(address token) external view returns (PonsLaunch memory);
    function memeHook() external view returns (address);
    function locker() external view returns (address);
}

/// Pons's hook on every graduated pool. Its fee is set by Pons's owner, at most 10% (checked on chain).
interface IPonsHook {
    function hookFeeBps() external view returns (uint256);
}

/// Pons's locker: owns each graduated pool's liquidity NFT for good. It has no function that moves an NFT or a
/// token out (read from its bytecode on 2026-10-06: its only external call pulls tokens in).
interface IPonsLocker {
    function lockedPositions(address token) external view returns (uint256 tokenId);
    function isLocked(address token) external view returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV3PoolSwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// One listed coin, as CoinListing records it and CoinShort and CoinLiquidator read it.
struct CoinDesk {
    MarketParams market; // loan: the coin; collateral: cUSDG; the coin's oracle; the adaptive IRM; LLTV 38.5%
    PoolKey key; // the coin's Pons pool: native ETH against the coin, Pons's hook
    address feed; // the coin's CoinFeed
    address vault; // b<COIN>, the coin's lending vault
    uint256 lockedId; // Pons's locked liquidity NFT for the pool
    uint64 listedAt;
}

interface ICoinListing {
    function deskOf(address coin) external view returns (CoinDesk memory);
    function capOf(address coin) external view returns (uint256 cap, uint256 depthCoins);
    function coinShort() external view returns (address);
}
