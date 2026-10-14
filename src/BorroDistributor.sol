// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title BorroDistributor
/// @notice Pays out BORRO by cumulative Merkle claims. Each leaf is an account and the total it has earned so
///         far; a claim pays the difference between that total and what the account has already claimed.
/// @dev The keeper (the root updater) publishes a new root every so often, with the total it promises (the sum
///      of every leaf). A new root waits ROOT_DELAY before it can be claimed against, and in that time the
///      guardian can revoke it. A proposal replaces a root still waiting, and that wait starts again, so the
///      keeper proposes only once the last root has taken effect.
///      Bounds on what a root can promise, so a stolen updater key cannot promise much before the guardian
///      steps in: the total never goes down; it is never more than this contract holds plus what has been
///      claimed; it grows no faster than `maxIncreasePerSecond` (by default the distributor's share of
///      emissions) since the root in force was proposed, plus MARGIN of growth for the keeper's timing;
///      proposals are MIN_GAP apart. Claims never pay out more in all than the total of the root in force.
///      The guardian can pause claims and proposals, and while paused can throw out a waiting root even after
///      its wait is over. Only the owner (the Safe) names the updater and the guardian, and they must differ.
///      Anyone can claim for any account; the tokens always go to the account. Tokens leave by claims, and by
///      the owner's reclaim of what no root promises: the owner (the Safe) can take back, at once, any tokens
///      beyond what the root in force and any waiting root still owe, never a token an account is owed.
///      Roy, 2026-10-06: "if no one uses it i want to be sure i can pull it back out no problems instantly".
///      Leaves are hashed twice, keccak256(bytes.concat(keccak256(abi.encode(account, cumulativeAmount)))), so a
///      leaf can never pass for an inner node of the tree. Pairs are hashed sorted (OpenZeppelin's MerkleProof).
contract BorroDistributor is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant ROOT_DELAY = 2 hours;
    uint256 public constant MIN_GAP = 30 minutes; // the least time between two proposals
    uint256 public constant MARGIN = 1 hours; // slack on the growth limit, as this many seconds of growth

    IERC20 public immutable token;

    address public updater;
    address public guardian;
    bool public paused; // no claims, no proposals
    uint256 public maxIncreasePerSecond; // the fastest the promised total may grow, in token wei per second

    bytes32 internal _root; // the root claims are checked against, until a pending one takes over
    uint256 internal _total; // what that root promises in all
    uint256 internal _totalAt; // when that root was proposed
    bytes32 public pendingRoot;
    uint256 public pendingTotal;
    uint256 public pendingProposedAt;
    uint256 public pendingAt; // when the pending root takes over; zero: none
    uint256 public lastProposal; // when a root was last proposed, whether or not it took effect
    uint256 public totalClaimed; // every claim ever paid, added up
    mapping(address account => uint256) public claimed;

    event RootProposed(bytes32 root, uint256 total, uint256 readyAt);
    event RootRevoked(bytes32 root);
    event Claimed(address indexed account, uint256 amount, uint256 cumulative);
    event UpdaterSet(address updater);
    event GuardianSet(address guardian);
    event PausedSet(bool paused);
    event MaxIncreaseSet(uint256 maxIncreasePerSecond);
    event Reclaimed(address to, uint256 amount);

    error OnlyUpdater();
    error OnlyGuardian();
    error NothingPending();
    error BadProof();
    error NothingToClaim();
    error IsPaused();
    error TooSoon(uint256 readyAt);
    error TotalDown(uint256 total, uint256 previous);
    error TotalNotHeld(uint256 total, uint256 held);
    error TotalTooFast(uint256 increase, uint256 allowed);
    error OverTotal(uint256 wanted, uint256 left);
    error GuardianIsUpdater();
    error OverReclaimable(uint256 wanted, uint256 free);

    /// @param maxIncreasePerSecond_ The fastest the promised total may grow. Pass the distributor's share of
    ///        the emitter's rate.
    constructor(IERC20 token_, address owner_, address updater_, address guardian_, uint256 maxIncreasePerSecond_)
        Ownable(owner_)
    {
        if (updater_ == guardian_) revert GuardianIsUpdater();
        token = token_;
        updater = updater_;
        guardian = guardian_;
        maxIncreasePerSecond = maxIncreasePerSecond_;
        _totalAt = block.timestamp;
        emit UpdaterSet(updater_);
        emit GuardianSet(guardian_);
        emit MaxIncreaseSet(maxIncreasePerSecond_);
    }

    /// @notice The root claims are checked against right now.
    function root() public view returns (bytes32) {
        return _ready() ? pendingRoot : _root;
    }

    /// @notice What the root claims are checked against promises in all.
    function total() public view returns (uint256) {
        return _ready() ? pendingTotal : _total;
    }

    /// @notice When the root claims are checked against was proposed. A new total is measured from here.
    function totalAt() public view returns (uint256) {
        return _ready() ? pendingProposedAt : _totalAt;
    }

    /// @notice Publish a new root and the total it promises (the sum of every leaf). It can be claimed against
    ///         after ROOT_DELAY. A root still waiting is replaced. Measured against the root in force:
    ///         `newTotal` must be at least its total, at most what this contract holds plus what has been
    ///         claimed, and more than its total by no more than maxIncreasePerSecond times the seconds since it
    ///         was proposed, plus MARGIN. At least MIN_GAP after the last proposal, and not while paused.
    function proposeRoot(bytes32 newRoot, uint256 newTotal) external {
        if (msg.sender != updater) revert OnlyUpdater();
        if (paused) revert IsPaused();
        if (block.timestamp < lastProposal + MIN_GAP) revert TooSoon(lastProposal + MIN_GAP);
        _promote();
        uint256 previous = _total;
        if (newTotal < previous) revert TotalDown(newTotal, previous);
        uint256 held = token.balanceOf(address(this)) + totalClaimed;
        if (newTotal > held) revert TotalNotHeld(newTotal, held);
        uint256 allowed = maxIncreasePerSecond * (block.timestamp - _totalAt + MARGIN);
        if (newTotal - previous > allowed) revert TotalTooFast(newTotal - previous, allowed);

        pendingRoot = newRoot;
        pendingTotal = newTotal;
        pendingProposedAt = block.timestamp;
        pendingAt = block.timestamp + ROOT_DELAY;
        lastProposal = block.timestamp;
        emit RootProposed(newRoot, newTotal, pendingAt);
    }

    /// @notice Throw out a root that is still waiting. Only the guardian can. While paused, a root whose wait is
    ///         over can be thrown out too, as long as nothing has been claimed against it.
    function revokeRoot() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        if (pendingAt == 0 || (block.timestamp >= pendingAt && !paused)) revert NothingPending();
        emit RootRevoked(pendingRoot);
        _clearPending();
    }

    /// @notice Stop claims and proposals, or let them go on. The guardian or the owner.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner()) revert OnlyGuardian();
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Pay `account` what it has earned and not yet claimed. Anyone can call it; the tokens go to `account`.
    /// @param cumulative The account's total earned so far, as written in the tree.
    function claim(address account, uint256 cumulative, bytes32[] calldata proof) external returns (uint256 amount) {
        if (paused) revert IsPaused();
        _promote();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
        if (!MerkleProof.verifyCalldata(proof, _root, leaf)) revert BadProof();
        uint256 done = claimed[account];
        if (cumulative <= done) revert NothingToClaim();
        amount = cumulative - done;
        if (totalClaimed + amount > _total) revert OverTotal(amount, _total - totalClaimed);
        claimed[account] = cumulative;
        totalClaimed += amount;
        token.safeTransfer(account, amount);
        emit Claimed(account, amount, cumulative);
    }

    /// @notice What the owner could take back right now: tokens held beyond what is still owed under the root in
    ///         force or a waiting root, whichever promises more.
    function reclaimable() public view returns (uint256) {
        uint256 promised = pendingTotal > _total ? pendingTotal : _total;
        uint256 owed = promised > totalClaimed ? promised - totalClaimed : 0;
        uint256 held = token.balanceOf(address(this));
        return held > owed ? held - owed : 0;
    }

    /// @notice Send `amount` of the tokens no root promises to `to`. Only the owner; never more than reclaimable().
    function reclaim(address to, uint256 amount) external onlyOwner {
        uint256 free = reclaimable();
        if (amount > free) revert OverReclaimable(amount, free);
        token.safeTransfer(to, amount);
        emit Reclaimed(to, amount);
    }

    function setUpdater(address updater_) external onlyOwner {
        if (updater_ == guardian) revert GuardianIsUpdater();
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == updater) revert GuardianIsUpdater();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @notice How fast the promised total may grow, in token wei per second.
    function setMaxIncreasePerSecond(uint256 maxIncreasePerSecond_) external onlyOwner {
        maxIncreasePerSecond = maxIncreasePerSecond_;
        emit MaxIncreaseSet(maxIncreasePerSecond_);
    }

    function _ready() internal view returns (bool) {
        return pendingAt != 0 && block.timestamp >= pendingAt;
    }

    /// @dev A pending root whose wait is over becomes the root.
    function _promote() internal {
        if (_ready()) {
            _root = pendingRoot;
            _total = pendingTotal;
            _totalAt = pendingProposedAt;
            _clearPending();
        }
    }

    function _clearPending() internal {
        delete pendingRoot;
        delete pendingTotal;
        delete pendingProposedAt;
        delete pendingAt;
    }
}
