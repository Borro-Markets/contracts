// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// A Morpho Vault V2 seen as an ERC-4626 vault: the stock vaults (bNVDA etc.) and the Borro USDG vault.
interface IBuilderVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
}

/// @title BorroBuilders
/// @notice Borro's referral program, on chain (docs/BUILDERS.md). A builder registers a code and the wallet it is
///         paid to. A deposit made through here with that code goes to one of Borro's vaults in the caller's name
///         and is announced as `Referred`; the keeper counts those toward the builder's share of the performance fee
///         the deposit's rent produces. The depositor keeps the vault shares and everything else a plain deposit
///         would give them.
/// @dev Holds nothing between transactions: what is pulled from the caller is deposited in the same call, and the
///      shares go straight to the caller. Deposits only go to vaults the owner listed (Borro's nine stock vaults and
///      the USDG vault), so a page that passes a lookalike vault cannot route a caller's money anywhere else. A code
///      is first come, first served, and only its payee can move it. Anything sent here by mistake can be swept out
///      by the owner.
contract BorroBuilders is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(bytes32 code => address payee) public builders; // the wallet each code is paid to
    mapping(address vault => bool) public vaults; // Borro's vaults

    event Registered(bytes32 indexed code, address indexed payee);
    event VaultListed(address indexed vault, address indexed asset, bool listed);
    event Referred(bytes32 indexed code, address indexed who, address indexed vault, uint256 assets, uint256 shares);

    error BadCode();
    error Taken();
    error NotPayee();
    error BadPayee();
    error NotRegistered();
    error BadVault();
    error Nothing();
    error TooFewShares(uint256 got, uint256 wanted);

    /// @param vaults_ Borro's vaults, listed from the start.
    constructor(address owner_, address[] memory vaults_) Ownable(owner_) {
        for (uint256 i; i < vaults_.length; i++) _setVault(vaults_[i], true);
    }

    /// @notice Claim an unclaimed code for the caller: deposits referred with it are credited to the caller.
    function register(bytes32 code) external {
        if (code == bytes32(0)) revert BadCode();
        if (builders[code] != address(0)) revert Taken();
        builders[code] = msg.sender;
        emit Registered(code, msg.sender);
    }

    /// @notice Move a code to another wallet. Only the code's current payee can, and the move is announced the same
    ///         way the claim was, so the whole history of a code is in its `Registered` events.
    function setPayee(bytes32 code, address to) external {
        if (builders[code] != msg.sender) revert NotPayee();
        if (to == address(0)) revert BadPayee();
        builders[code] = to;
        emit Registered(code, to);
    }

    /// @notice Deposit `assets` of `vault`'s asset into `vault` for the caller, credited to the builder behind `code`.
    /// @param vault One of Borro's vaults, listed here.
    /// @param assets Asset wei to deposit. This much is taken from the caller.
    /// @param code A registered builder code.
    /// @param minShares The fewest vault shares the deposit may bring.
    /// @return shares Vault shares the caller now owns.
    function deposit(address vault, uint256 assets, bytes32 code, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert Nothing();
        if (!vaults[vault]) revert BadVault();
        if (builders[code] == address(0)) revert NotRegistered();
        IERC20 asset = IERC20(IBuilderVault(vault).asset());
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(vault, assets);
        shares = IBuilderVault(vault).deposit(assets, msg.sender);
        if (shares < minShares) revert TooFewShares(shares, minShares);
        emit Referred(code, msg.sender, vault, assets, shares);
    }

    /// @notice List or unlist one of Borro's vaults. Unlisting only stops new deposits through here.
    function setVault(address vault, bool listed) external onlyOwner {
        _setVault(vault, listed);
    }

    /// @notice Send out a token left here by mistake. Between transactions this contract holds nothing of anyone's.
    function sweep(IERC20 token, address to) external onlyOwner {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    function _setVault(address vault, bool listed) internal {
        address asset = IBuilderVault(vault).asset();
        if (asset == address(0)) revert BadVault();
        vaults[vault] = listed;
        emit VaultListed(vault, asset, listed);
    }
}
