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
import {IWETH, IUniswapV3PoolSwap} from "./CoinDeps.sol";

/// @title CoinSwap
/// @notice The one route a coin short trades by: USDG and WETH in the WETH/USDG Uniswap v3 pool, then native ETH
///         and the coin in the coin's own Pons pool (Uniswap v4, Pons's hook). Shared by CoinShort and
///         CoinLiquidator. Holds nothing between transactions.
/// @dev Selling: exactly `amount` of the coin in, all the USDG it brings out. Buying: exactly `amount` of the coin
///      out, paid with USDG already here; the ETH the coin pool asks for is bought from the v3 pool as an exact
///      output, inside the same unlock. Every bound on price is the caller's (a least proceeds or a most cost);
///      there is no price limit inside the pools, and a pool that cannot fill the exact amount reverts.
///      Quoting runs the same trade and reverts with QuoteResult.
abstract contract CoinSwap is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IUniswapV3PoolSwap public immutable ethPool; // WETH/USDG
    IWETH public immutable weth;
    IERC20 public immutable usdg;
    bool internal immutable _wethIs0;

    address private _v3Live; // the v3 pool a swap is under way in, for its callback

    error OnlyPoolManager();
    error OnlyPool();
    error PoolRanDry();
    error TooMuch(uint256 cost, uint256 limit);
    error QuoteResult(uint256 amount);
    error BadEthPool();

    constructor(IPoolManager pm_, IUniswapV3PoolSwap ethPool_, IWETH weth_, IERC20 usdg_) {
        address t0 = ethPool_.token0();
        address t1 = ethPool_.token1();
        if (!((t0 == address(weth_) && t1 == address(usdg_)) || (t0 == address(usdg_) && t1 == address(weth_)))) revert BadEthPool();
        poolManager = pm_;
        ethPool = ethPool_;
        weth = weth_;
        usdg = usdg_;
        _wethIs0 = t0 == address(weth_);
    }

    /// @dev ETH arrives from the PoolManager (a coin sold) and from WETH (unwrapped to pay the coin pool).
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(weth)) revert OnlyPool();
    }

    // ------------------------------------------------------------------ trades

    /// @dev Sells exactly `coinIn` of the coin held here; returns the USDG now held here for it.
    function _sellCoin(PoolKey memory key, uint256 coinIn) internal returns (uint256 usdgOut) {
        uint256 ethOut = abi.decode(poolManager.unlock(abi.encode(key, coinIn, false, false)), (uint256));
        weth.deposit{value: ethOut}();
        usdgOut = _v3(ethOut, false, false);
    }

    /// @dev Buys exactly `coinOut` of the coin with USDG held here; returns the USDG it cost.
    function _buyCoin(PoolKey memory key, uint256 coinOut) internal returns (uint256 usdgCost) {
        usdgCost = abi.decode(poolManager.unlock(abi.encode(key, coinOut, true, false)), (uint256));
    }

    /// @dev USDG that selling `coinIn` would bring, without trading. Reverts are caught here.
    function _quoteSell(PoolKey memory key, uint256 coinIn) internal returns (uint256) {
        uint256 ethOut = _catchQuote(abi.encodeCall(IPoolManager.unlock, (abi.encode(key, coinIn, false, true))), address(poolManager));
        return _quoteV3(ethOut, false);
    }

    /// @dev USDG that buying `coinOut` would cost, without trading.
    function _quoteBuy(PoolKey memory key, uint256 coinOut) internal returns (uint256) {
        uint256 ethIn = _catchQuote(abi.encodeCall(IPoolManager.unlock, (abi.encode(key, coinOut, true, true))), address(poolManager));
        return _quoteV3(ethIn, true);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, uint256 amount, bool buying, bool quoting) = abi.decode(data, (PoolKey, uint256, bool, bool));
        // currency0 is native ETH, currency1 the coin. Buying the coin: ETH in (zeroForOne), exact coin out.
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: buying,
                amountSpecified: buying ? int256(amount) : -int256(amount),
                sqrtPriceLimitX96: buying ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 dEth = d.amount0();
        int128 dCoin = d.amount1();
        Currency coin = key.currency1;
        if (buying) {
            if (dCoin < 0 || uint256(uint128(dCoin)) != amount || dEth > 0) revert PoolRanDry();
            uint256 ethIn = uint256(uint128(-dEth));
            if (quoting) revert QuoteResult(ethIn);
            poolManager.take(coin, address(this), amount);
            uint256 cost = _v3(ethIn, true, false); // USDG to WETH, exactly ethIn out
            weth.withdraw(ethIn);
            poolManager.settle{value: ethIn}();
            return abi.encode(cost);
        }
        if (dCoin > 0 || uint256(uint128(-dCoin)) != amount || dEth < 0) revert PoolRanDry();
        uint256 ethOut = uint256(uint128(dEth));
        if (quoting) revert QuoteResult(ethOut);
        poolManager.sync(coin);
        IERC20(Currency.unwrap(coin)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
        poolManager.take(key.currency0, address(this), ethOut);
        return abi.encode(ethOut);
    }

    // ------------------------------------------------------------------ the WETH/USDG leg

    /// @dev buyingEth false: sells exactly `ethAmount` of WETH held here, returns USDG received.
    ///      buyingEth true: buys exactly `ethAmount` of WETH with USDG held here, returns the USDG it cost.
    function _v3(uint256 ethAmount, bool buyingEth, bool quoting) internal returns (uint256) {
        // Selling WETH: WETH in. Buying WETH: USDG in.
        bool zeroForOne = buyingEth ? !_wethIs0 : _wethIs0;
        _v3Live = address(ethPool);
        (int256 a0, int256 a1) = ethPool.swap(
            address(this),
            zeroForOne,
            buyingEth ? -int256(ethAmount) : int256(ethAmount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            abi.encode(ethAmount, buyingEth, quoting)
        );
        _v3Live = address(0);
        int256 dUsdg = _wethIs0 ? a1 : a0;
        return buyingEth ? uint256(dUsdg) : uint256(-dUsdg);
    }

    function _quoteV3(uint256 ethAmount, bool buyingEth) internal returns (uint256) {
        return _catchQuote(abi.encodeCall(this.quoteV3Leg, (ethAmount, buyingEth)), address(this));
    }

    /// @notice Only for quoting: always reverts with QuoteResult. Moves nothing.
    function quoteV3Leg(uint256 ethAmount, bool buyingEth) external {
        _v3(ethAmount, buyingEth, true);
    }

    /// @dev Uniswap v3 sends what was bought first, then calls here to be paid.
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        if (msg.sender != _v3Live || msg.sender == address(0)) revert OnlyPool();
        (uint256 ethAmount, bool buyingEth, bool quoting) = abi.decode(data, (uint256, bool, bool));
        (int256 dWeth, int256 dUsdg) = _wethIs0 ? (a0, a1) : (a1, a0);
        if (buyingEth) {
            if (dWeth >= 0 || uint256(-dWeth) != ethAmount) revert PoolRanDry();
            uint256 cost = uint256(dUsdg);
            if (quoting) revert QuoteResult(cost);
            uint256 have = usdg.balanceOf(address(this));
            if (have < cost) revert TooMuch(cost, have);
            usdg.safeTransfer(msg.sender, cost);
        } else {
            if (dWeth <= 0 || uint256(dWeth) != ethAmount) revert PoolRanDry();
            if (quoting) revert QuoteResult(uint256(-dUsdg));
            IERC20(address(weth)).safeTransfer(msg.sender, ethAmount);
        }
    }

    /// @dev Calls `target` with `data`, which must revert with QuoteResult; returns its amount.
    function _catchQuote(bytes memory data, address target) internal returns (uint256 amount) {
        (bool ok, bytes memory err) = target.call(data);
        if (ok || err.length != 36 || bytes4(err) != QuoteResult.selector) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
        assembly {
            amount := mload(add(err, 36))
        }
    }
}
