// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Market, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVault} from "./BorroHookDeps.sol";

/// @title BorroHookMath
/// @notice BorroHook's curve and its read of what a vault can pay, kept out of the hook so the hook fits the
///         24 KB contract limit. Linked at deploy; called by delegatecall, so it holds and touches nothing.
library BorroHookMath {
    using MarketParamsLib for MarketParams;

    uint256 internal constant PIPS = 1_000_000;

    error Zero();
    error TooMuch();

    /// What a wallet's lending on Borro is worth is read against: the vaults' last synced share prices, the pool,
    /// and the feed price of the stock (8 decimals).
    struct Lending {
        IVault usdgVault;
        uint256 usdgPerShare;
        IVault stockVault;
        uint256 stockPerShare;
        address share;
        uint256 resUsdg;
        uint256 resStock;
        uint8 stockDecimals;
        uint256 feedE8;
    }

    /// @notice Whether `who` lends at least `minUsdg` on Borro: bUSDG, the stock's vault shares, the pool's shares.
    function lends(Lending memory l, address who, uint256 minUsdg) external view returns (bool) {
        uint256 v = l.usdgVault.balanceOf(who) * l.usdgPerShare / 1e18;
        if (v >= minUsdg) return true;
        uint256 stockHeld = l.stockVault.balanceOf(who) * l.stockPerShare / 1e18;
        uint256 supply = IERC20(l.share).totalSupply();
        uint256 lp = IERC20(l.share).balanceOf(who);
        if (lp != 0 && supply != 0) {
            v += Math.mulDiv(l.resUsdg, lp, supply);
            stockHeld += Math.mulDiv(l.resStock, lp, supply);
        }
        if (l.feedE8 != 0 && stockHeld != 0) v += Math.mulDiv(stockHeld * l.feedE8, 1e6, 1e8 * 10 ** l.stockDecimals);
        return v >= minUsdg;
    }

    struct Fill {
        uint256 amountIn;
        uint256 amountOut; // to the swapper
        uint256 lpFee; // in the input token
        uint256 surcharge; // in USDG
        uint256 usdgLeaving; // USDG leaving the pool's reserves (stock in: what the swapper gets plus the surcharge)
    }

    /// @dev The constant-product fill, rounded for the pool. Fees: the LPs' in the input token, stays in the pool;
    ///      the surcharge in USDG (from the input when USDG goes in, from the output when it comes out).
    function fill(uint256 rU, uint256 rS, bool usdgIn, bool exactIn, uint256 amount, uint256 lpPips, uint256 surPips)
        external
        pure
        returns (Fill memory f)
    {
        if (rU == 0 || rS == 0) revert Zero();
        if (usdgIn) {
            if (exactIn) {
                f.amountIn = amount;
                f.surcharge = Math.mulDiv(amount, surPips, PIPS, Math.Rounding.Ceil);
                f.lpFee = Math.mulDiv(amount, lpPips, PIPS, Math.Rounding.Ceil);
                if (f.surcharge + f.lpFee >= amount) revert Zero();
                uint256 net = amount - f.surcharge - f.lpFee;
                f.amountOut = Math.mulDiv(rS, net, rU + net);
            } else {
                if (amount >= rS) revert TooMuch();
                f.amountOut = amount;
                uint256 net = Math.mulDiv(rU, amount, rS - amount, Math.Rounding.Ceil);
                f.amountIn = Math.mulDiv(net, PIPS, PIPS - lpPips - surPips, Math.Rounding.Ceil);
                uint256 fees = f.amountIn - net;
                f.surcharge = lpPips + surPips == 0 ? 0 : fees * surPips / (lpPips + surPips);
                f.lpFee = fees - f.surcharge;
            }
        } else {
            if (exactIn) {
                f.amountIn = amount;
                f.lpFee = Math.mulDiv(amount, lpPips, PIPS, Math.Rounding.Ceil);
                if (f.lpFee >= amount) revert Zero();
                uint256 net = amount - f.lpFee;
                f.usdgLeaving = Math.mulDiv(rU, net, rS + net);
                f.surcharge = Math.mulDiv(f.usdgLeaving, surPips, PIPS, Math.Rounding.Ceil);
                if (f.surcharge >= f.usdgLeaving) revert Zero();
                f.amountOut = f.usdgLeaving - f.surcharge;
            } else {
                f.amountOut = amount;
                f.usdgLeaving = Math.mulDiv(amount, PIPS, PIPS - surPips, Math.Rounding.Ceil);
                if (f.usdgLeaving >= rU) revert TooMuch();
                f.surcharge = f.usdgLeaving - amount;
                uint256 net = Math.mulDiv(rS, f.usdgLeaving, rU - f.usdgLeaving, Math.Rounding.Ceil);
                f.amountIn = Math.mulDiv(net, PIPS, PIPS - lpPips, Math.Rounding.Ceil);
                f.lpFee = f.amountIn - net;
            }
        }
    }

    /// @dev The first deposit's shares (sqrt of the product) and the part locked for good: at least `minShares`, and at
    ///      least `minLockUsdg` of the USDG side (with the same part of the stock), so that once every LP has left the
    ///      pool still holds enough of both to keep its price. `usdgIn` is never 0 here (the guard refuses it first).
    function firstShares(uint256 usdgIn, uint256 stockIn, uint256 minShares, uint256 minLockUsdg)
        external
        pure
        returns (uint256 shares, uint256 lock)
    {
        shares = Math.sqrt(usdgIn * stockIn);
        lock = Math.max(minShares, Math.mulDiv(shares, minLockUsdg, usdgIn, Math.Rounding.Ceil));
    }

    /// @dev What a vault can pay out right now: its idle tokens, plus what its liquidity adapter's Morpho market has
    ///      free, up to what the adapter has supplied there.
    function free(IVault v, IMorpho morpho) external view returns (uint256) {
        address asset = v.asset();
        uint256 idle = IERC20(asset).balanceOf(address(v));
        address adapter = v.liquidityAdapter();
        if (adapter == address(0)) return idle;
        bytes memory data = v.liquidityData();
        if (data.length < 160) return idle;
        MarketParams memory mp = abi.decode(data, (MarketParams));
        Id mid = mp.id();
        Market memory m = morpho.market(mid);
        Position memory pos = morpho.position(mid, adapter);
        uint256 supplied = m.totalSupplyShares == 0
            ? 0
            : Math.mulDiv(pos.supplyShares, uint256(m.totalSupplyAssets) + 1, uint256(m.totalSupplyShares) + 1e6);
        uint256 liquidity = m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0;
        return idle + Math.min(supplied, liquidity);
    }

}
