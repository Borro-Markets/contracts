// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @title BorroSwap
/// @notice Trades a stock against USDG, through Uniswap v4 (a route of hookless pools) or one Uniswap v3 pool.
/// @dev Shared by BorroShort (open and close a short) and BorroLiquidator (turn seized collateral into what is
///      owed), so both trade the same way, through the routes BorroShort lists. Holds nothing between calls:
///      a sale pays out to this contract, and a purchase is paid from USDG already here.
abstract contract BorroSwap is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IERC20 public immutable usdg;

    // The v3 pool being traded with, set only for the length of one swap.
    address private _v3Live;

    error OnlyPoolManager();
    error OnlyPool();
    error PoolRanDry();
    error TooMuch(uint256 cost, uint256 limit);
    error QuoteResult(uint256 amount);

    constructor(IPoolManager poolManager_, IERC20 usdg_) {
        poolManager = poolManager_;
        usdg = usdg_;
    }

    /// @dev buying = false: sells exactly `amount` of the stock, returns USDG received and held here.
    ///      buying = true:  buys exactly `amount` of the stock with USDG held here, returns the USDG cost.
    ///      quoting = true: reverts with QuoteResult instead of trading.
    ///      Pass a v3 pool, or a v4 route from USDG to the stock and no pool.
    function _swap(PoolKey[] memory route, address v3Pool, address stock, uint256 amount, bool buying, bool quoting)
        internal
        returns (uint256)
    {
        if (v3Pool != address(0)) return _tradeV3(v3Pool, stock, amount, buying, quoting);
        return abi.decode(poolManager.unlock(abi.encode(route, stock, amount, buying, quoting)), (uint256));
    }

    function _tradeV3(address pool, address stock, uint256 amount, bool buying, bool quoting) internal returns (uint256) {
        bool stockIs0 = IUniswapV3Pool(pool).token0() == stock;
        // Selling: the stock goes in. Buying: USDG goes in.
        bool zeroForOne = buying ? !stockIs0 : stockIs0;
        _v3Live = pool;
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            buying ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            abi.encode(stockIs0, amount, buying, quoting)
        );
        _v3Live = address(0);
        int256 dUsdg = stockIs0 ? a1 : a0;
        return buying ? uint256(dUsdg) : uint256(-dUsdg);
    }

    /// @dev Uniswap v3 sends what was bought first, then calls here to be paid.
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        if (msg.sender != _v3Live || msg.sender == address(0)) revert OnlyPool();
        (bool stockIs0, uint256 amount, bool buying, bool quoting) = abi.decode(data, (bool, uint256, bool, bool));
        (int256 dStock, int256 dUsdg) = stockIs0 ? (a0, a1) : (a1, a0);
        if (buying) {
            // Owed: USDG. Received: exactly the stock asked for, or the pool ran dry.
            if (dStock >= 0 || uint256(-dStock) != amount) revert PoolRanDry();
            uint256 cost = uint256(dUsdg);
            if (quoting) revert QuoteResult(cost);
            uint256 have = usdg.balanceOf(address(this));
            if (have < cost) revert TooMuch(cost, have);
            usdg.safeTransfer(msg.sender, cost);
        } else {
            if (dStock <= 0 || uint256(dStock) != amount) revert PoolRanDry();
            if (quoting) revert QuoteResult(uint256(-dUsdg));
            IERC20(stockIs0 ? IUniswapV3Pool(msg.sender).token0() : IUniswapV3Pool(msg.sender).token1()).safeTransfer(msg.sender, amount);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey[] memory route, address stock, uint256 amount, bool buying, bool quoting) =
            abi.decode(data, (PoolKey[], address, uint256, bool, bool));

        // Both directions walk the route from the stock end back to USDG.
        // Selling: each hop spends an exact input. Buying: each hop asks for an exact output.
        address at = stock;
        uint256 running = amount;
        for (uint256 i = route.length; i > 0; i--) {
            PoolKey memory key = route[i - 1];
            bool atIs0 = Currency.unwrap(key.currency0) == at;
            // Selling `at`: at is the input. Buying `at`: at is the output, so the input is the other side.
            bool zeroForOne = buying ? !atIs0 : atIs0;
            BalanceDelta delta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: buying ? int256(running) : -int256(running),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 dAt = atIs0 ? delta.amount0() : delta.amount1();
            int128 dOther = atIs0 ? delta.amount1() : delta.amount0();
            if (buying) {
                if (dAt < 0 || uint256(uint128(dAt)) != running) revert PoolRanDry();
                running = uint256(uint128(-dOther));
            } else {
                if (dAt > 0 || uint256(uint128(-dAt)) != running) revert PoolRanDry();
                running = uint256(uint128(dOther));
            }
            at = Currency.unwrap(atIs0 ? key.currency1 : key.currency0);
        }
        if (quoting) revert QuoteResult(running);

        // Middle tokens net to zero. Only the two ends are paid and collected.
        (address pay, uint256 payAmount, address get, uint256 getAmount) =
            buying ? (address(usdg), running, stock, amount) : (stock, amount, address(usdg), running);
        poolManager.take(Currency.wrap(get), address(this), getAmount);
        if (buying) {
            // The purchase is paid from USDG already here. It has to cover the cost.
            uint256 have = usdg.balanceOf(address(this));
            if (have < payAmount) revert TooMuch(payAmount, have);
        }
        poolManager.sync(Currency.wrap(pay));
        IERC20(pay).safeTransfer(address(poolManager), payAmount);
        poolManager.settle();
        return abi.encode(running);
    }
}
