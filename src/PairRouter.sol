// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroSwap} from "./BorroSwap.sol";

/// BorroShort's desks: each short market, and the route its stock trades through.
interface IShortDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed);
}

/// A Morpho Vault V2 seen as an ERC-4626 vault: the stock vaults (bNVDA etc.).
interface IPairVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
}

/// @title PairRouter
/// @notice The long leg of a pair trade, in one transaction: buy exactly `amount` of a stock with USDG, through the
///         route Borro's short desk uses for that stock, and lend it straight to the stock's Borro vault in the
///         caller's name. The caller ends up owning the vault shares (bNVDA etc.), so the long leg earns rent from
///         shorters while it is held.
/// @dev The short leg is the caller's own BorroShort.open: BorroShort only ever opens a short for the account that
///      calls it, so no contract can open one for someone else. The site sends both in one wallet batch where the
///      wallet can do that, and as two transactions where it cannot.
///      Holds nothing between transactions: the USDG not spent goes back to the caller in the same call, and every
///      share of stock bought is deposited. Deposits only go to vaults the owner listed (Borro's own stock vaults),
///      so a page that passes a lookalike vault cannot route a caller's stock anywhere else. Anything sent here by
///      mistake can be swept out by the owner.
contract PairRouter is BorroSwap, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IShortDesks public immutable desks;

    mapping(address vault => bool) public vaults; // Borro's stock vaults

    event VaultListed(address indexed vault, address indexed stock, bool listed);
    event BoughtAndLent(
        address indexed who, bytes32 indexed id, address stock, uint256 amount, uint256 cost, uint256 vaultShares
    );

    error Expired();
    error Nothing();
    error NotListed();
    error BadVault();
    error TooFewShares(uint256 got, uint256 wanted);

    /// @param vaults_ Borro's stock vaults, listed from the start.
    constructor(IPoolManager poolManager_, IERC20 usdg_, IShortDesks desks_, address owner_, address[] memory vaults_)
        BorroSwap(poolManager_, usdg_)
        Ownable(owner_)
    {
        desks = desks_;
        for (uint256 i; i < vaults_.length; i++) _setVault(vaults_[i], true);
    }

    /// @notice Buy exactly `amount` of the stock that short desk `id` lends, and lend it to `vault` for the caller.
    /// @param id A BorroShort desk: the short market whose loan token is the stock.
    /// @param vault That stock's Borro vault. It must be listed here and hold the same stock.
    /// @param amount Stock wei to buy and lend.
    /// @param maxCost The most USDG the purchase may cost. This much is taken, and what is not spent comes back.
    /// @param minVaultShares The fewest vault shares the deposit may bring.
    /// @param deadline The transaction is worthless after this time.
    /// @return cost USDG the stock cost.
    /// @return vaultShares Vault shares the caller now owns.
    function buyAndLend(bytes32 id, address vault, uint256 amount, uint256 maxCost, uint256 minVaultShares, uint256 deadline)
        external
        nonReentrant
        returns (uint256 cost, uint256 vaultShares)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amount == 0) revert Nothing();
        if (!vaults[vault]) revert BadVault();
        (MarketParams memory market, PoolKey[] memory route, address v3Pool,,) = desks.deskOf(id);
        if (route.length == 0 && v3Pool == address(0)) revert NotListed();
        address stock = market.loanToken;
        if (IPairVault(vault).asset() != stock) revert BadVault();

        usdg.safeTransferFrom(msg.sender, address(this), maxCost);
        cost = _swap(route, v3Pool, stock, amount, true, false);
        // The swap pays from whatever USDG is here; anything beyond maxCost was never the caller's to spend.
        if (cost > maxCost) revert TooMuch(cost, maxCost);
        if (maxCost > cost) usdg.safeTransfer(msg.sender, maxCost - cost);

        IERC20(stock).forceApprove(vault, amount);
        vaultShares = IPairVault(vault).deposit(amount, msg.sender);
        if (vaultShares < minVaultShares) revert TooFewShares(vaultShares, minVaultShares);
        emit BoughtAndLent(msg.sender, id, stock, amount, cost, vaultShares);
    }

    /// @notice List or unlist one of Borro's stock vaults. Unlisting only stops new deposits through here.
    function setVault(address vault, bool listed) external onlyOwner {
        _setVault(vault, listed);
    }

    /// @notice Send out a token left here by mistake. Between transactions this contract holds nothing of anyone's.
    function sweep(IERC20 token, address to) external onlyOwner {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    function _setVault(address vault, bool listed) internal {
        address stock = IPairVault(vault).asset();
        if (stock == address(0)) revert BadVault();
        vaults[vault] = listed;
        emit VaultListed(vault, stock, listed);
    }
}
