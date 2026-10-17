// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BorroLock
/// @notice Lock your own $BORRO until a date you choose (1, 3, 6 or 12 months out) for a boost on Borro's depositor
///         drip. 2026-10-07: "add the borro lock boost to the drip".
/// @dev One lock per address: an amount and an unlock time. lock() adds tokens and moves the unlock time to the later
///      of the current one and now plus the chosen duration; extend() moves it later; nothing ever moves it earlier.
///      withdraw() pays the whole lock back to the locker at or after the unlock time, and then always works.
///
///      There is no owner, no admin, no pause and no early unlock. Nobody but the locker can move a locked token, and
///      the locker only by withdraw() once the unlock time has come. $BORRO sent here other than through lock() is
///      nobody's lock: anyone can skim() it to `strays`, an address fixed at deploy (the Hoard Safe), so a mistaken
///      transfer is never lost. skim() can only ever send what is held beyond every lock (balance less totalLocked).
contract BorroLock {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable strays; // where skim() sends $BORRO that is nobody's lock

    struct Lock {
        uint128 amount;
        uint64 unlockAt;
    }

    mapping(address account => Lock) internal _locks;
    uint256 public totalLocked;

    /// @notice Every change to a lock, with what it is afterwards (amount 0, unlockAt 0 after a withdrawal).
    event LockChanged(address indexed account, uint256 amount, uint256 unlockAt);
    event Withdrawn(address indexed account, uint256 amount);
    event Skimmed(address indexed to, uint256 amount);

    error ZeroAmount();
    error BadDuration();
    error NoLock();
    error NotLonger(uint256 unlockAt, uint256 wanted);
    error StillLocked(uint256 unlockAt);
    error TooMuch();
    error ZeroAddress();

    constructor(IERC20 token_, address strays_) {
        if (address(token_) == address(0) || strays_ == address(0)) revert ZeroAddress();
        token = token_;
        strays = strays_;
    }

    /// @notice The lock lengths on offer: 0 = 1 month (30 days), 1 = 3 months (91 days), 2 = 6 months (182 days),
    ///         3 = 12 months (365 days).
    function durationOf(uint8 choice) public pure returns (uint256) {
        if (choice == 0) return 30 days;
        if (choice == 1) return 91 days;
        if (choice == 2) return 182 days;
        if (choice == 3) return 365 days;
        revert BadDuration();
    }

    /// @notice `account`'s lock: what it holds and when it can be withdrawn (0 and 0: none).
    function lockOf(address account) external view returns (uint256 amount, uint256 unlockAt) {
        Lock memory l = _locks[account];
        return (l.amount, l.unlockAt);
    }

    /// @notice Locks `amount` more of your $BORRO (approve it first). The whole lock then unlocks at the later of its
    ///         current unlock time and now plus the chosen duration. Returns the unlock time.
    function lock(uint256 amount, uint8 choice) external returns (uint256 unlockAt) {
        if (amount == 0) revert ZeroAmount();
        uint256 wanted = block.timestamp + durationOf(choice);
        Lock memory l = _locks[msg.sender];
        unlockAt = l.unlockAt > wanted ? l.unlockAt : wanted;
        // Count what actually arrived.
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = token.balanceOf(address(this)) - before;
        if (got == 0) revert ZeroAmount();
        uint256 next = uint256(l.amount) + got;
        if (next > type(uint128).max) revert TooMuch();
        _locks[msg.sender] = Lock(uint128(next), uint64(unlockAt));
        totalLocked += got;
        emit LockChanged(msg.sender, next, unlockAt);
    }

    /// @notice Moves your unlock time to now plus the chosen duration, which must be later than it is now.
    function extend(uint8 choice) external returns (uint256 unlockAt) {
        Lock memory l = _locks[msg.sender];
        if (l.amount == 0) revert NoLock();
        unlockAt = block.timestamp + durationOf(choice);
        if (unlockAt <= l.unlockAt) revert NotLonger(l.unlockAt, unlockAt);
        _locks[msg.sender].unlockAt = uint64(unlockAt);
        emit LockChanged(msg.sender, l.amount, unlockAt);
    }

    /// @notice Pays your whole lock back to you. Only at or after its unlock time; then it always works.
    function withdraw() external returns (uint256 amount) {
        Lock memory l = _locks[msg.sender];
        if (l.amount == 0) revert NoLock();
        if (block.timestamp < l.unlockAt) revert StillLocked(l.unlockAt);
        amount = l.amount;
        delete _locks[msg.sender];
        totalLocked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit LockChanged(msg.sender, 0, 0);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Sends $BORRO held beyond every lock (sent here by mistake, not through lock()) to `strays`. Anyone can
    ///         call it; it never touches a locked token. Returns what it sent.
    function skim() external returns (uint256 amount) {
        uint256 held = token.balanceOf(address(this));
        amount = held > totalLocked ? held - totalLocked : 0;
        if (amount != 0) {
            token.safeTransfer(strays, amount);
            emit Skimmed(strays, amount);
        }
    }
}
