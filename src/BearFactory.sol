// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BearVault} from "./BearVault.sol";

/// @title BearFactory
/// @notice Makes bear vaults and keeps the list: every vault it made, and, once a vault has bound its coin (which
///         checks Pons's own record that the coin pays its creator fees to that vault), which vault backs which coin.
///         The site and the keeper read the list from here, and from its events.
///
///         Anyone may make a vault with `createVault`: they own it (their wallet launches the coin and is the one who
///         can unwind the short and, after 7 days of public notice, take the money out), Borro's keeper keeps it, and it
///         starts on the default limits, which its owner may change inside the vault's hard caps.
/// @dev A vault's creation code (about 25 KB) is too big for this contract (24 KB limit), so the constructor stores it
///      in two data contracts that cannot run (each starts with STOP) and `createVault` copies it back from them. The
///      code is fixed at deploy; `vaultCodeHash` is its hash, so anyone can check every vault listed here runs exactly
///      BearVault's published code.
contract BearFactory is Ownable2Step {
    bytes32 public immutable vaultCodeHash;
    address internal immutable _codeA;
    address internal immutable _codeB;
    uint256 internal immutable _lenA;
    uint256 internal immutable _lenB;
    BearVault.Env internal _env;
    address public keeper; // the keeper new vaults get; the owner of this factory (a Safe) may change it for new ones
    address[] internal _vaults;
    mapping(address vault => bool) public isVault;
    mapping(address coin => address vault) public vaultOf;

    event VaultCreated(address indexed vault, bytes32 indexed deskId, address indexed owner, address keeper);
    event CoinRegistered(address indexed coin, address indexed vault);
    event KeeperSet(address keeper);

    error NotVault();
    error Taken();
    error CreateFailed();
    error ZeroAddress();

    /// @param code BearVault's creation code, exactly (`type(BearVault).creationCode`).
    /// @param keeper_ The keeper every vault made here starts with.
    /// @param admin Who may change that keeper for vaults made later (a Safe). It has no say over any vault.
    constructor(BearVault.Env memory env_, bytes memory code, address keeper_, address admin) Ownable(admin) {
        if (keeper_ == address(0)) revert ZeroAddress();
        _env = env_;
        keeper = keeper_;
        vaultCodeHash = keccak256(code);
        uint256 half = code.length / 2;
        _lenA = half;
        _lenB = code.length - half;
        _codeA = _store(code, 0, half);
        _codeB = _store(code, half, code.length - half);
        emit KeeperSet(keeper_);
    }

    /// @notice Make a bear vault for one stock desk (a BorroShort market id). The caller owns it.
    function createVault(bytes32 deskId) external returns (address vault) {
        address k = keeper;
        bytes memory init = abi.encodePacked(vaultCode(), abi.encode(_env, deskId, msg.sender, k, defaultLimits(), address(this)));
        assembly {
            vault := create(0, add(init, 0x20), mload(init))
        }
        if (vault == address(0)) revert CreateFailed();
        isVault[vault] = true;
        _vaults.push(vault);
        emit VaultCreated(vault, deskId, msg.sender, k);
    }

    /// @notice Called by a vault this factory made, when it binds its coin. One vault per coin.
    function register(address coin) external {
        if (!isVault[msg.sender]) revert NotVault();
        if (vaultOf[coin] != address(0)) revert Taken();
        vaultOf[coin] = msg.sender;
        emit CoinRegistered(coin, msg.sender);
    }

    /// @notice The keeper vaults made from now on start with. Vaults already made keep theirs; only their owners change it.
    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function env() external view returns (BearVault.Env memory) {
        return _env;
    }

    /// @notice BearVault's creation code, as stored at deploy.
    function vaultCode() public view returns (bytes memory code) {
        (address a, address b, uint256 la, uint256 lb) = (_codeA, _codeB, _lenA, _lenB);
        code = new bytes(la + lb);
        assembly {
            extcodecopy(a, add(code, 0x20), 1, la)
            extcodecopy(b, add(add(code, 0x20), la), 1, lb)
        }
    }

    /// @notice The limits docs/BEAR-COINS.md argues for: 40% of the limit used at most after growing, the keeper
    ///         trims above 50%, anyone above 70%; 3% from the outside price; profit taken a quarter at a time once the
    ///         stock is 5% below entry; small per-call caps.
    function defaultLimits() public pure returns (BearVault.Limits memory) {
        return BearVault.Limits({
            targetUseBps: 4_000,
            maxUseBps: 5_000,
            emergencyUseBps: 7_000,
            slipBps: 300,
            minProfitBps: 500,
            profitCloseBps: 2_500,
            maxFeedAge: 3 hours,
            growCooldown: 1 hours,
            swapCooldown: 10 minutes,
            burnCooldown: 10 minutes,
            maxGrowUsdg: 1_000e6,
            maxBurnUsdg: 500e6,
            maxSwapEth: 0.5 ether
        });
    }

    /// @dev Deploys `data[from:from+len]` as the code of a new contract, behind a leading STOP so it can never run.
    function _store(bytes memory data, uint256 from, uint256 len) internal returns (address at) {
        bytes memory init = new bytes(11 + len);
        uint256 size = len + 1;
        // PUSH2 size, DUP1, PUSH1 10, RETURNDATASIZE, CODECOPY, RETURNDATASIZE, RETURN: returns the bytes after these 10.
        init[0] = 0x61;
        init[1] = bytes1(uint8(size >> 8));
        init[2] = bytes1(uint8(size));
        init[3] = 0x80;
        init[4] = 0x60;
        init[5] = 0x0a;
        init[6] = 0x3d;
        init[7] = 0x39;
        init[8] = 0x3d;
        init[9] = 0xf3;
        init[10] = 0x00; // STOP
        assembly {
            mcopy(add(init, 0x2b), add(add(data, 0x20), from), len)
            at := create(0, add(init, 0x20), mload(init))
        }
        if (at == address(0)) revert CreateFailed();
    }
}
