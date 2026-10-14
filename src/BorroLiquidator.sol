// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {IMorphoLiquidateCallback} from "morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {BorroSwap} from "./BorroSwap.sol";

/// The vaults whose shares are collateral: the Steakhouse USDG vault on the short side, the stock vaults on
/// the USDG side. Both are Morpho Vault V2s.
interface ICollateralVault {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
}

/// Where each stock trades, as listed on BorroShort.
interface IBorroDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed);
}

/// Borro's USDG markets, as listed on BorroRouter.
interface IBorroMarkets {
    function listed(bytes32 id) external view returns (bool);
}

/// @title BorroLiquidator
/// @notice Liquidates an unhealthy position in a Borro market with no money of its own, and pays the caller what
///         is left over. Anyone can call it.
///         Short markets (borrow a stock, post Steakhouse USDG vault shares): the seized shares are redeemed for
///         USDG, the stock owed is bought with it, and Morpho takes the stock back.
///         USDG markets (borrow USDG, post a stock vault's shares): the seized shares are redeemed for the stock,
///         the stock is sold for USDG, and Morpho takes the USDG back.
/// @dev Morpho hands over the seized collateral first and collects the repayment last, calling back here in
///      between; that is what makes it capital free. The stock trades through the route BorroShort lists for it,
///      so a paused stock can still be liquidated. Holds nothing between transactions, and every allowance it
///      gives is for the exact repayment, which Morpho then takes in full. A liquidation that would pay the
///      caller less than `minProfit` reverts, so a losing one never happens.
///      Only Borro's markets: a short market must be the very market BorroShort lists as the desk, and a USDG
///      market must be on BorroRouter's list.
///      A USDG market liquidation needs the stock vault to have the stock on hand to redeem. If the vault has
///      lent it all to shorters, this contract cannot do it and says so (CannotRedeem). The position can still
///      be liquidated on Morpho directly by someone with their own USDG, who then holds the stock vault shares
///      until shorts close and the vault can pay them out.
contract BorroLiquidator is BorroSwap, IMorphoLiquidateCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    IMorpho public immutable morpho;
    IBorroDesks public immutable short; // BorroShort, for where each stock trades
    address public immutable held; // the Steakhouse USDG vault, collateral of every short market
    IBorroMarkets public immutable router; // BorroRouter, whose list says which USDG markets are Borro's

    event Liquidated(address indexed caller, bytes32 indexed routeId, address indexed borrower, uint256 seized, uint256 repaid, uint256 profit);

    error OnlyMorpho();
    error BadMarket();
    error NoRoute();
    error TooLittle(uint256 got, uint256 wanted);
    /// The vault cannot pay out the seized shares right now: what is behind them is lent out. Liquidate on
    /// Morpho directly with your own money instead, and redeem the shares later.
    error CannotRedeem(address vault, uint256 shares);

    constructor(
        IMorpho morpho_,
        IPoolManager poolManager_,
        IERC20 usdg_,
        IBorroDesks short_,
        address held_,
        IBorroMarkets router_
    ) BorroSwap(poolManager_, usdg_) {
        morpho = morpho_;
        short = short_;
        held = held_;
        router = router_;
    }

    /// @notice Liquidate `borrower` on `market`. Pass exactly one of `seizedAssets` (collateral to take) and
    ///         `repaidShares` (borrow shares to repay), as Morpho's `liquidate` does.
    /// @param market A short market listed on BorroShort, or a USDG market listed on BorroRouter.
    /// @param routeId The BorroShort desk of the stock involved: the short market's id. On the USDG side it is
    ///        the id of the same stock's short market.
    /// @param minProfit The least USDG the caller must be left with. Less than this and nothing happens.
    /// @return profit USDG sent to the caller.
    function liquidate(
        MarketParams calldata market,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes32 routeId,
        uint256 minProfit
    ) external nonReentrant returns (uint256 profit) {
        (MarketParams memory desk, PoolKey[] memory route, address v3Pool,,) = short.deskOf(routeId);
        if (route.length == 0 && v3Pool == address(0)) revert NoRoute();
        address stock = desk.loanToken;

        // The short side: the desk's own market and nothing else. The USDG side: a market on the router's list,
        // lending USDG against the stock vault of the same stock.
        MarketParams memory m = market;
        bytes32 id = Id.unwrap(m.id());
        bool shortSide = id == routeId;
        if (
            !shortSide
                && (!router.listed(id) || m.loanToken != address(usdg) || ICollateralVault(m.collateralToken).asset() != stock)
        ) revert BadMarket();

        uint256 before = usdg.balanceOf(address(this));
        (uint256 seized, uint256 repaid) = morpho.liquidate(
            market, borrower, seizedAssets, repaidShares, abi.encode(shortSide, market.collateralToken, stock, route, v3Pool)
        );
        profit = usdg.balanceOf(address(this)) - before;
        if (profit < minProfit) revert TooLittle(profit, minProfit);
        if (profit != 0) usdg.safeTransfer(msg.sender, profit);
        emit Liquidated(msg.sender, routeId, borrower, seized, repaid, profit);
    }

    /// @dev Morpho has sent the seized collateral here. Turn it into what is owed, and allow Morpho to take that.
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        (bool shortSide, address collateral, address stock, PoolKey[] memory route, address v3Pool) =
            abi.decode(data, (bool, address, address, PoolKey[], address));
        uint256 seized = IERC20(collateral).balanceOf(address(this));
        try ICollateralVault(collateral).redeem(seized, address(this), address(this)) {}
        catch {
            revert CannotRedeem(collateral, seized);
        }
        if (shortSide) {
            // USDG in hand. Buy exactly the stock owed; the rest of the USDG is the profit.
            _swap(route, v3Pool, stock, repaidAssets, true, false);
            IERC20(stock).forceApprove(address(morpho), repaidAssets);
        } else {
            // Stock in hand. Sell all of it; what is left after the repayment is the profit.
            _swap(route, v3Pool, stock, IERC20(stock).balanceOf(address(this)), false, false);
            uint256 have = usdg.balanceOf(address(this));
            if (have < repaidAssets) revert TooMuch(repaidAssets, have);
            usdg.forceApprove(address(morpho), repaidAssets);
        }
    }
}
