// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

/// A Morpho Vault V2 seen as an ERC-4626 vault: the stock vaults (bNVDA etc.).
interface IStockVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
}

/// @title BorroRouter
/// @notice Lend a stock and post what you get for it as collateral, in one transaction: the stock goes into its
///         vault, and the vault shares (bNVDA etc.) are posted on the stock's USDG market in the caller's name.
///         From there the caller borrows USDG on Morpho directly, and takes the shares back on Morpho directly.
/// @dev Holds nothing between transactions. Every allowance it gives is for the exact amount about to be used,
///      so none is left behind. Morpho lets anyone post collateral for anyone, so the caller never authorizes
///      this contract on Morpho.
///      Only Borro's own USDG markets can be used: the owner (the Safe) lists them, and the list is also how
///      BorroLiquidator tells a Borro USDG market from any other. Listing or unlisting never touches a
///      position: it only decides where this contract will post, and which markets the liquidator takes.
contract BorroRouter is Ownable2Step {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    IMorpho public immutable morpho;
    address public immutable usdg;

    mapping(bytes32 id => bool) public listed; // Borro's USDG markets

    event Listed(bytes32 indexed id, address indexed vault, bool listed);
    event LentAndPosted(address indexed who, bytes32 indexed id, address stock, uint256 assets, uint256 shares);

    error BadMarket();
    error Nothing();
    error TooFewShares(uint256 got, uint256 wanted);

    /// @param markets_ Borro's USDG markets, listed from the start.
    constructor(IMorpho morpho_, address usdg_, address owner_, MarketParams[] memory markets_) Ownable(owner_) {
        morpho = morpho_;
        usdg = usdg_;
        for (uint256 i; i < markets_.length; i++) _list(markets_[i]);
    }

    /// @notice Add one of Borro's USDG markets: it lends USDG against a vault's shares, and exists on Morpho.
    function list(MarketParams calldata market) external onlyOwner {
        _list(market);
    }

    /// @notice Take a market off the list. Positions in it stay on Morpho, untouched.
    function unlist(bytes32 id) external onlyOwner {
        if (!listed[id]) revert BadMarket();
        listed[id] = false;
        emit Listed(id, address(0), false);
    }

    /// @notice Take `assets` of `stock` from the caller, lend it to the stock's vault, and post the vault shares as
    ///         the caller's collateral on `market`.
    /// @param market One of Borro's USDG markets, whose collateral is the vault of `stock`.
    /// @param minShares The fewest vault shares the deposit may bring. Fewer than this and nothing happens.
    /// @return shares Vault shares posted.
    function lendAndPost(MarketParams calldata market, address stock, uint256 assets, uint256 minShares)
        external
        returns (uint256 shares)
    {
        if (assets == 0) revert Nothing();
        MarketParams memory m = market;
        bytes32 id = Id.unwrap(m.id());
        if (!listed[id]) revert BadMarket();
        address vault = m.collateralToken;
        if (IStockVault(vault).asset() != stock) revert BadMarket();

        IERC20(stock).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(stock).forceApprove(vault, assets);
        shares = IStockVault(vault).deposit(assets, address(this));
        if (shares < minShares) revert TooFewShares(shares, minShares);
        IERC20(vault).forceApprove(address(morpho), shares);
        morpho.supplyCollateral(m, shares, msg.sender, "");
        emit LentAndPosted(msg.sender, id, stock, assets, shares);
    }

    function _list(MarketParams memory market) internal {
        bytes32 id = Id.unwrap(market.id());
        if (market.loanToken != usdg || morpho.market(Id.wrap(id)).lastUpdate == 0) revert BadMarket();
        // The collateral must be a vault: it answers what it lends.
        if (IStockVault(market.collateralToken).asset() == address(0)) revert BadMarket();
        listed[id] = true;
        emit Listed(id, market.collateralToken, true);
    }
}
