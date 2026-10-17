// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title TeamReserve
/// @notice Holds the $BORRO kept for future team hires, in public. 2026-10-07: "Reserve + 30-day timelock".
///         Tokens leave it only two ways:
///           1. A hire's grant: the owner grants an amount with a start date; it vests over four years with a one year
///              cliff (nothing before start + 365 days, a quarter at the cliff, then 1/48 of the grant at each further
///              full month, all of it at start + 4 years). Only the grant's beneficiary can claim what has vested. If the
///              hire leaves, the owner revokes: what has vested by then stays the beneficiary's to claim, the rest goes
///              back to the unallocated balance.
///           2. A queued withdrawal: the owner queues (to, amount) out of the unallocated balance; it can be executed
///              by anyone, sending to `to`, only from 30 days after it was queued, and only for the 14 days after that
///              (so a queued withdrawal cannot sit as a standing order to fire unannounced months later; past its
///              window it is dead and the owner cancels it to free the amount). The owner can cancel it at any time
///              before it is executed.
/// @dev The owner (the Hoard Safe; two-step transfer, no renounce) has exactly these powers: grant, revoke,
///      queueWithdraw, cancelWithdraw, and sweep() of OTHER tokens sent here by mistake (to itself). No pause, no
///      upgrade, no other way to move $BORRO. The owner can never take a vested token: revoke freezes what has vested
///      and leaves it to the beneficiary, and withdrawals and grants only ever come out of the unallocated balance.
///
///      Accounting. totalGranted is what grants still hold (granted, less claimed, less what revokes returned),
///      vested or not. totalQueued is what queued withdrawals hold. unallocated() is the $BORRO balance less both: the
///      only part a new grant or withdrawal may use. Every way in or out keeps totalGranted + totalQueued at or under
///      the balance: a grant or a withdrawal must fit in unallocated(), a claim or an executed withdrawal lowers the
///      balance and its total by the same amount, a revoke or a cancel only lowers a total. Funding is a plain transfer.
///
///      Time. A year is 365 days and a month a twelfth of it (30 days 10 hours), so the cliff is start + 365 days and
///      the grant is whole at start + 1,460 days. A grant's start may be up to 90 days back (so a hire's clock can begin
///      on their first day even when the Safe signs later) and up to 365 days ahead. Even backdated in full, a grant
///      pays nothing for 275 days after it is public, far beyond the 30 days a withdrawal waits.
contract TeamReserve is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant MONTH = 365 days / 12; // 2,628,000 seconds: 30 days 10 hours
    uint256 public constant CLIFF_MONTHS = 12;
    uint256 public constant VEST_MONTHS = 48;
    uint256 public constant CLIFF = CLIFF_MONTHS * MONTH; // 365 days
    uint256 public constant DURATION = VEST_MONTHS * MONTH; // 1,460 days
    uint256 public constant WITHDRAW_DELAY = 30 days;
    uint256 public constant EXECUTE_WINDOW = 14 days; // after the delay; then the withdrawal can only be cancelled
    uint256 public constant MAX_BACKDATE = 90 days;
    uint256 public constant MAX_LEAD = 365 days;

    IERC20 public immutable token;

    struct Grant {
        address beneficiary;
        uint64 start;
        uint64 revokedAt; // zero while the grant is live
        uint128 amount; // as granted
        uint128 claimed;
        uint128 vestedAtRevoke; // what had vested when revoked: the grant's final size from then on
    }

    enum Status {
        None,
        Queued,
        Executed,
        Cancelled
    }

    struct Withdrawal {
        address to;
        uint64 queuedAt;
        Status status;
        uint128 amount;
    }

    /// @notice One grant's state, for reading. remaining = what the grant still holds (vested or not, not claimed).
    struct GrantView {
        uint256 id;
        address beneficiary;
        uint256 amount;
        uint256 start;
        uint256 cliffAt;
        uint256 endAt;
        uint256 revokedAt;
        uint256 vested;
        uint256 claimed;
        uint256 claimable;
        uint256 unvested;
        uint256 remaining;
    }

    Grant[] internal _grants;
    Withdrawal[] internal _withdrawals;

    /// @notice What grants still hold: granted, less claimed, less what revokes returned. Vested or not.
    uint256 public totalGranted;
    /// @notice What queued withdrawals hold until they are executed or cancelled.
    uint256 public totalQueued;

    event Granted(uint256 indexed id, address indexed beneficiary, uint256 amount, uint256 start, uint256 cliffAt, uint256 endAt);
    event Claimed(uint256 indexed id, address indexed beneficiary, uint256 amount, uint256 claimedInAll);
    event Revoked(uint256 indexed id, address indexed beneficiary, uint256 vested, uint256 returned);
    event GrantMoved(uint256 indexed id, address indexed from, address indexed to);
    event WithdrawQueued(uint256 indexed id, address indexed to, uint256 amount, uint256 readyAt, uint256 expiresAt);
    event WithdrawCancelled(uint256 indexed id, address indexed to, uint256 amount);
    event WithdrawExecuted(uint256 indexed id, address indexed to, uint256 amount, address caller);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error BadAddress();
    error BadStart(uint256 start, uint256 earliest, uint256 latest);
    error NotEnoughUnallocated(uint256 amount, uint256 unallocated);
    error NoSuchGrant(uint256 id);
    error NotBeneficiary();
    error NothingToClaim();
    error AlreadyRevoked();
    error NoSuchWithdrawal(uint256 id);
    error NotQueued(Status status);
    error NotReady(uint256 readyAt);
    error Expired(uint256 expiresAt);
    error SweepMovedToken();
    error NotOtherToken();
    error NoRenounce();

    /// @param token_ $BORRO.
    /// @param owner_ The Hoard Safe: the only address that can grant, revoke, queue and cancel withdrawals.
    constructor(IERC20 token_, address owner_) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    // ------------------------------------------------------------------ grants

    /// @notice Grants `amount` to `beneficiary`, vesting from `start` (a 365 day cliff, then monthly to 1,460 days).
    ///         Only the owner. The amount must fit in unallocated(). `start` may be up to 90 days back and up to 365
    ///         days ahead. A beneficiary can hold several grants. Returns the grant's id.
    function grant(address beneficiary, uint256 amount, uint256 start) external onlyOwner returns (uint256 id) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (beneficiary == address(this)) revert BadAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 earliest = block.timestamp > MAX_BACKDATE ? block.timestamp - MAX_BACKDATE : 0;
        uint256 latest = block.timestamp + MAX_LEAD;
        if (start < earliest || start > latest) revert BadStart(start, earliest, latest);
        uint256 free = unallocated();
        if (amount > free) revert NotEnoughUnallocated(amount, free);
        id = _grants.length;
        // start <= now + a year fits in 64 bits; the amount is checked to fit in 128.
        _grants.push(Grant(beneficiary, uint64(start), 0, SafeCast.toUint128(amount), 0, 0));
        totalGranted += amount;
        emit Granted(id, beneficiary, amount, start, start + CLIFF, start + DURATION);
    }

    /// @notice Sends the beneficiary what grant `id` has vested and not yet paid. Only the grant's beneficiary.
    function claim(uint256 id) external returns (uint256 amount) {
        Grant storage g = _grant(id);
        address to = g.beneficiary;
        if (msg.sender != to) revert NotBeneficiary();
        amount = _vested(g) - g.claimed;
        if (amount == 0) revert NothingToClaim();
        g.claimed += uint128(amount);
        totalGranted -= amount;
        token.safeTransfer(to, amount);
        emit Claimed(id, to, amount, g.claimed);
    }

    /// @notice Ends grant `id` (the hire left). What has vested by now stays the beneficiary's to claim; the rest goes
    ///         back to the unallocated balance. Only the owner, once per grant.
    function revoke(uint256 id) external onlyOwner returns (uint256 returned) {
        Grant storage g = _grant(id);
        if (g.revokedAt != 0) revert AlreadyRevoked();
        uint256 v = vestedAt(g.amount, g.start, block.timestamp);
        returned = g.amount - v;
        g.revokedAt = uint64(block.timestamp);
        g.vestedAtRevoke = uint128(v);
        totalGranted -= returned;
        emit Revoked(id, g.beneficiary, v, returned);
    }

    /// @notice Hands grant `id` to a new wallet (say the hire moves to a hardware wallet). Only the grant's
    ///         beneficiary; the owner cannot.
    function moveGrant(uint256 id, address to) external {
        Grant storage g = _grant(id);
        if (msg.sender != g.beneficiary) revert NotBeneficiary();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert BadAddress();
        g.beneficiary = to;
        emit GrantMoved(id, msg.sender, to);
    }

    // ------------------------------------------------------------------ withdrawals

    /// @notice Queues sending `amount` of the unallocated balance to `to`. Anyone can execute it from 30 days from now
    ///         for 14 days; the owner can cancel it until it is executed. Until it is executed or cancelled the amount
    ///         is held back from new grants and withdrawals (an expired one too, until cancelled). Only the owner.
    ///         Returns the withdrawal's id.
    function queueWithdraw(address to, uint256 amount) external onlyOwner returns (uint256 id) {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert BadAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 free = unallocated();
        if (amount > free) revert NotEnoughUnallocated(amount, free);
        id = _withdrawals.length;
        _withdrawals.push(Withdrawal(to, uint64(block.timestamp), Status.Queued, SafeCast.toUint128(amount)));
        totalQueued += amount;
        emit WithdrawQueued(id, to, amount, block.timestamp + WITHDRAW_DELAY, block.timestamp + WITHDRAW_DELAY + EXECUTE_WINDOW);
    }

    /// @notice Cancels a queued withdrawal (waiting, ready or expired); its amount is unallocated again. Only the owner.
    function cancelWithdraw(uint256 id) external onlyOwner {
        Withdrawal storage w = _withdrawal(id);
        if (w.status != Status.Queued) revert NotQueued(w.status);
        w.status = Status.Cancelled;
        totalQueued -= w.amount;
        emit WithdrawCancelled(id, w.to, w.amount);
    }

    /// @notice Sends a queued withdrawal to its `to`, from 30 days after it was queued until 14 days after that.
    ///         Anyone can call it.
    function executeWithdraw(uint256 id) external {
        Withdrawal storage w = _withdrawal(id);
        if (w.status != Status.Queued) revert NotQueued(w.status);
        uint256 readyAt = uint256(w.queuedAt) + WITHDRAW_DELAY;
        if (block.timestamp < readyAt) revert NotReady(readyAt);
        if (block.timestamp >= readyAt + EXECUTE_WINDOW) revert Expired(readyAt + EXECUTE_WINDOW);
        w.status = Status.Executed;
        uint256 amount = w.amount;
        totalQueued -= amount;
        token.safeTransfer(w.to, amount);
        emit WithdrawExecuted(id, w.to, amount, msg.sender);
    }

    // ------------------------------------------------------------------ the rest

    /// @notice Sends the owner every unit of a token that is NOT $BORRO and was sent here by mistake. Only the owner.
    function sweep(IERC20 other) external onlyOwner returns (uint256 amount) {
        if (address(other) == address(token)) revert NotOtherToken();
        uint256 held = token.balanceOf(address(this));
        amount = other.balanceOf(address(this));
        address to = owner();
        if (amount != 0) other.safeTransfer(to, amount);
        // A second address for the same balance (a token with two entry points) would get past the check above.
        if (token.balanceOf(address(this)) != held) revert SweepMovedToken();
        emit Swept(address(other), to, amount);
    }

    /// @notice The owner can hand the reserve over (two steps), never give it up: with no owner no grant could be
    ///         made and the unallocated balance could never leave.
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }

    // ------------------------------------------------------------------ views

    /// @notice The $BORRO balance less what grants hold and what queued withdrawals hold: what a new grant or
    ///         withdrawal may use.
    function unallocated() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 held = totalGranted + totalQueued;
        return bal > held ? bal - held : 0;
    }

    /// @notice What a grant of `amount` starting at `start` has vested by time `t`: zero before start + 365 days, then
    ///         amount * (full months since start) / 48, the whole amount from start + 1,460 days.
    function vestedAt(uint256 amount, uint256 start, uint256 t) public pure returns (uint256) {
        if (t < start + CLIFF) return 0;
        uint256 months = (t - start) / MONTH;
        if (months >= VEST_MONTHS) return amount;
        return (amount * months) / VEST_MONTHS;
    }

    function grantCount() external view returns (uint256) {
        return _grants.length;
    }

    function withdrawalCount() external view returns (uint256) {
        return _withdrawals.length;
    }

    /// @notice What grant `id` has vested by now (frozen at the revoke for a revoked grant).
    function vested(uint256 id) public view returns (uint256) {
        return _vested(_grant(id));
    }

    /// @notice What the beneficiary of grant `id` can claim now.
    function claimable(uint256 id) public view returns (uint256) {
        Grant storage g = _grant(id);
        return _vested(g) - g.claimed;
    }

    /// @notice What grant `id` still holds for its beneficiary: vested or not, not yet claimed.
    function remaining(uint256 id) public view returns (uint256) {
        Grant storage g = _grant(id);
        return (g.revokedAt != 0 ? g.vestedAtRevoke : g.amount) - g.claimed;
    }

    /// @notice Everything about grant `id`, at this moment.
    function grantInfo(uint256 id) public view returns (GrantView memory v) {
        Grant storage g = _grant(id);
        bool revoked = g.revokedAt != 0;
        uint256 vest = _vested(g);
        v = GrantView({
            id: id,
            beneficiary: g.beneficiary,
            amount: g.amount,
            start: g.start,
            cliffAt: uint256(g.start) + CLIFF,
            endAt: uint256(g.start) + DURATION,
            revokedAt: g.revokedAt,
            vested: vest,
            claimed: g.claimed,
            claimable: vest - g.claimed,
            unvested: revoked ? 0 : g.amount - vest,
            remaining: (revoked ? g.vestedAtRevoke : g.amount) - g.claimed
        });
    }

    /// @notice The ids of every grant `beneficiary` holds now, live or revoked.
    function grantsOf(address beneficiary) external view returns (uint256[] memory ids) {
        uint256 n = _grants.length;
        uint256 k;
        for (uint256 i; i < n; ++i) if (_grants[i].beneficiary == beneficiary) ++k;
        ids = new uint256[](k);
        k = 0;
        for (uint256 i; i < n; ++i) if (_grants[i].beneficiary == beneficiary) ids[k++] = i;
    }

    /// @notice Withdrawal `id`: where it goes, how much, when it was queued, when it can be executed (from readyAt
    ///         until just before expiresAt), and its status (1 queued, 2 executed, 3 cancelled).
    function withdrawalInfo(uint256 id)
        external
        view
        returns (address to, uint256 amount, uint256 queuedAt, uint256 readyAt, uint256 expiresAt, Status status)
    {
        Withdrawal storage w = _withdrawal(id);
        uint256 ready = uint256(w.queuedAt) + WITHDRAW_DELAY;
        return (w.to, w.amount, w.queuedAt, ready, ready + EXECUTE_WINDOW, w.status);
    }

    /// @notice Every withdrawal still queued (neither executed nor cancelled), with the time it can be executed from.
    ///         One past readyAt + EXECUTE_WINDOW has expired: it can only be cancelled.
    function pendingWithdrawals()
        external
        view
        returns (uint256[] memory ids, address[] memory to, uint256[] memory amounts, uint256[] memory readyAt)
    {
        uint256 n = _withdrawals.length;
        uint256 k;
        for (uint256 i; i < n; ++i) if (_withdrawals[i].status == Status.Queued) ++k;
        ids = new uint256[](k);
        to = new address[](k);
        amounts = new uint256[](k);
        readyAt = new uint256[](k);
        k = 0;
        for (uint256 i; i < n; ++i) {
            Withdrawal storage w = _withdrawals[i];
            if (w.status != Status.Queued) continue;
            ids[k] = i;
            to[k] = w.to;
            amounts[k] = w.amount;
            readyAt[k] = uint256(w.queuedAt) + WITHDRAW_DELAY;
            ++k;
        }
    }

    // ------------------------------------------------------------------ internal

    function _grant(uint256 id) internal view returns (Grant storage) {
        if (id >= _grants.length) revert NoSuchGrant(id);
        return _grants[id];
    }

    function _withdrawal(uint256 id) internal view returns (Withdrawal storage) {
        if (id >= _withdrawals.length) revert NoSuchWithdrawal(id);
        return _withdrawals[id];
    }

    function _vested(Grant storage g) internal view returns (uint256) {
        return g.revokedAt != 0 ? g.vestedAtRevoke : vestedAt(g.amount, g.start, block.timestamp);
    }
}
