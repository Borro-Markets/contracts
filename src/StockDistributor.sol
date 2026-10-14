// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title StockDistributor
/// @notice Pays a basket of stock tokens to $BORRO holders by cumulative Merkle claims: BorroDistributor made for
///         several tokens. Each leaf is (account, token, the total of that token the account has earned so far); a
///         claim pays the difference between that total and what the account has already claimed of the token.
/// @dev One root covers every token, so the whole basket goes out under one 2 hour wait and one guardian check.
///      Every bound BorroDistributor keeps on its one total is kept here per token. A proposal carries one total per
///      listed token (in the order of tokens()), and for each: it never goes down; it is never more than this
///      contract holds of the token plus what has been claimed of it; it grows no faster than that token's
///      `maxIncreasePerSecond` since the root in force was proposed, plus MARGIN. Proposals are MIN_GAP apart; a
///      new root waits ROOT_DELAY, in which the guardian can revoke it; a proposal replaces a root still waiting.
///      Claims never pay more of a token in all than the total of the root in force for it.
///      Anyone can claim for any account, alone or in a batch (the keeper pushes claims so stocks simply arrive);
///      the tokens always go to the account in the leaf. Tokens leave only by claims, and by the owner's reclaim of
///      what no root promises: the owner (the Hoard Safe) can take back, at once, any amount of a token beyond what
///      the root in force and any waiting root still owe of it, and all of any token that is not listed.
///      Leaves are hashed twice, keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulative)))), so a
///      leaf can never pass for an inner node; pairs are hashed sorted (OpenZeppelin's MerkleProof), as
///      OpenZeppelin's StandardMerkleTree builds them over ["address", "address", "uint256"].
contract StockDistributor is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant ROOT_DELAY = 2 hours;
    uint256 public constant MIN_GAP = 30 minutes; // the least time between two proposals
    uint256 public constant MARGIN = 1 hours; // slack on each growth limit, as this many seconds of growth
    uint256 public constant MAX_TOKENS = 16; // keeps every per-token loop short

    struct TokenState {
        bool listed;
        uint256 maxIncreasePerSecond; // the fastest its promised total may grow, in token wei per second
        uint256 total; // what the root in force promises of it in all (until a waiting root takes over)
        uint256 pendingTotal; // what the waiting root promises of it
        uint256 claimed; // every claim of it ever paid, added up
    }

    /// One claim in a batch.
    struct Claim {
        address account;
        address token;
        uint256 cumulative;
        bytes32[] proof;
    }

    address[] internal _tokens;
    mapping(address token => TokenState) internal _state;

    address public updater;
    address public guardian;
    bool public paused; // no claims, no proposals

    bytes32 internal _root; // the root claims are checked against, until a pending one takes over
    uint256 internal _totalAt; // when that root was proposed
    bytes32 public pendingRoot;
    uint256 public pendingProposedAt;
    uint256 public pendingAt; // when the pending root takes over; zero: none
    uint256 public lastProposal; // when a root was last proposed, whether or not it took effect
    mapping(address account => mapping(address token => uint256)) public claimed;

    event TokenListed(address indexed token, uint256 maxIncreasePerSecond);
    event MaxIncreaseSet(address indexed token, uint256 maxIncreasePerSecond);
    event RootProposed(bytes32 root, uint256[] totals, uint256 readyAt);
    event RootRevoked(bytes32 root);
    event Claimed(address indexed account, address indexed token, uint256 amount, uint256 cumulative);
    event UpdaterSet(address updater);
    event GuardianSet(address guardian);
    event PausedSet(bool paused);
    event Reclaimed(address indexed token, address to, uint256 amount);

    error OnlyUpdater();
    error OnlyGuardian();
    error NothingPending();
    error BadProof();
    error NothingToClaim();
    error IsPaused();
    error TooSoon(uint256 readyAt);
    error WrongLength(uint256 got, uint256 want);
    error TotalDown(address token, uint256 total, uint256 previous);
    error TotalNotHeld(address token, uint256 total, uint256 held);
    error TotalTooFast(address token, uint256 increase, uint256 allowed);
    error OverTotal(address token, uint256 wanted, uint256 left);
    error GuardianIsUpdater();
    error OverReclaimable(address token, uint256 wanted, uint256 free);
    error NotListed(address token);
    error AlreadyListed(address token);
    error TooManyTokens();
    error ZeroAddress();

    /// @param tokens_ The basket, listed from the start. More can be listed later by the owner, never removed.
    /// @param maxIncreasePerSecond_ For each token, the fastest its promised total may grow, in token wei a second.
    constructor(
        address owner_,
        address updater_,
        address guardian_,
        address[] memory tokens_,
        uint256[] memory maxIncreasePerSecond_
    ) Ownable(owner_) {
        if (updater_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (updater_ == guardian_) revert GuardianIsUpdater();
        if (tokens_.length != maxIncreasePerSecond_.length) revert WrongLength(maxIncreasePerSecond_.length, tokens_.length);
        updater = updater_;
        guardian = guardian_;
        _totalAt = block.timestamp;
        emit UpdaterSet(updater_);
        emit GuardianSet(guardian_);
        for (uint256 i; i < tokens_.length; ++i) {
            _list(tokens_[i], maxIncreasePerSecond_[i]);
        }
    }

    // ------------------------------------------------------------------ reads

    /// @notice The listed tokens, in the order a proposal's totals follow.
    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    /// @notice A token's settings and counts, as they stand (a waiting root whose wait is over counts as in force).
    function tokenState(address token)
        external
        view
        returns (bool listed, uint256 maxIncrease, uint256 total_, uint256 pendingTotal_, uint256 claimed_)
    {
        TokenState storage s = _state[token];
        return (s.listed, s.maxIncreasePerSecond, total(token), _ready() ? 0 : s.pendingTotal, s.claimed);
    }

    /// @notice The root claims are checked against right now.
    function root() public view returns (bytes32) {
        return _ready() ? pendingRoot : _root;
    }

    /// @notice What the root claims are checked against promises of `token` in all.
    function total(address token) public view returns (uint256) {
        TokenState storage s = _state[token];
        return _ready() ? s.pendingTotal : s.total;
    }

    /// @notice What the waiting root promises of `token` (zero once its wait is over: then it is the root in force).
    function pendingTotal(address token) external view returns (uint256) {
        return _ready() ? 0 : _state[token].pendingTotal;
    }

    /// @notice Every claim of `token` ever paid, added up.
    function totalClaimed(address token) external view returns (uint256) {
        return _state[token].claimed;
    }

    function maxIncreasePerSecond(address token) external view returns (uint256) {
        return _state[token].maxIncreasePerSecond;
    }

    /// @notice When the root claims are checked against was proposed. Each new total is measured from here.
    function totalAt() public view returns (uint256) {
        return _ready() ? pendingProposedAt : _totalAt;
    }

    /// @notice What the owner could take back of `token` right now: what this contract holds of it beyond what is
    ///         still owed under the root in force or a waiting root, whichever promises more. All of it for a token
    ///         that is not listed (no root can promise one).
    function reclaimable(address token) public view returns (uint256) {
        TokenState storage s = _state[token];
        uint256 promised = s.pendingTotal > s.total ? s.pendingTotal : s.total;
        uint256 owed = promised > s.claimed ? promised - s.claimed : 0;
        uint256 held = IERC20(token).balanceOf(address(this));
        return held > owed ? held - owed : 0;
    }

    // ------------------------------------------------------------------ the updater

    /// @notice Publish a new root and, for each listed token in the order of tokens(), the total it promises (the
    ///         sum of every leaf for that token). It can be claimed against after ROOT_DELAY. A root still waiting
    ///         is replaced. For each token, measured against the root in force: at least its total, at most what
    ///         this contract holds of the token plus what has been claimed of it, and more than its total by no
    ///         more than the token's maxIncreasePerSecond times the seconds since that root was proposed, plus
    ///         MARGIN. At least MIN_GAP after the last proposal, and not while paused.
    function proposeRoot(bytes32 newRoot, uint256[] calldata newTotals) external {
        if (msg.sender != updater) revert OnlyUpdater();
        if (paused) revert IsPaused();
        if (block.timestamp < lastProposal + MIN_GAP) revert TooSoon(lastProposal + MIN_GAP);
        uint256 n = _tokens.length;
        if (newTotals.length != n) revert WrongLength(newTotals.length, n);
        _promote();
        uint256 since = block.timestamp - _totalAt + MARGIN;
        for (uint256 i; i < n; ++i) {
            address token = _tokens[i];
            TokenState storage s = _state[token];
            uint256 newTotal = newTotals[i];
            uint256 previous = s.total;
            if (newTotal < previous) revert TotalDown(token, newTotal, previous);
            uint256 held = IERC20(token).balanceOf(address(this)) + s.claimed;
            if (newTotal > held) revert TotalNotHeld(token, newTotal, held);
            uint256 allowed = s.maxIncreasePerSecond * since;
            if (newTotal - previous > allowed) revert TotalTooFast(token, newTotal - previous, allowed);
            s.pendingTotal = newTotal;
        }
        pendingRoot = newRoot;
        pendingProposedAt = block.timestamp;
        pendingAt = block.timestamp + ROOT_DELAY;
        lastProposal = block.timestamp;
        emit RootProposed(newRoot, newTotals, pendingAt);
    }

    // ------------------------------------------------------------------ the guardian

    /// @notice Throw out a root that is still waiting. Only the guardian can. While paused, a root whose wait is over
    ///         can be thrown out too: nothing can have been claimed against it, since claims stop while paused and a
    ///         root only takes over at a claim or a proposal.
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

    // ------------------------------------------------------------------ claims

    /// @notice Pay `account` what it has earned of `token` and not yet claimed. Anyone can call it; the tokens go to
    ///         `account`.
    /// @param cumulative The account's total earned of the token so far, as written in the tree.
    function claim(address account, address token, uint256 cumulative, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (paused) revert IsPaused();
        _promote();
        amount = _claim(account, token, cumulative, proof);
        if (amount == 0) revert NothingToClaim();
    }

    /// @notice Many claims in one transaction, for any accounts; each one's tokens go to its own account. A claim
    ///         with nothing left to pay (already claimed, by the account or anyone) is passed over; anything else
    ///         wrong (a bad proof, more than the total, a transfer the token refuses) undoes the whole batch.
    /// @return paid How many of the claims paid something.
    function claimMany(Claim[] calldata claims) external nonReentrant returns (uint256 paid) {
        if (paused) revert IsPaused();
        _promote();
        for (uint256 i; i < claims.length; ++i) {
            Claim calldata c = claims[i];
            if (_claim(c.account, c.token, c.cumulative, c.proof) > 0) ++paid;
        }
    }

    /// @dev Checks the leaf against the root in force and pays what is new; returns 0 (and pays nothing) when the
    ///      account has already been paid this cumulative amount.
    function _claim(address account, address token, uint256 cumulative, bytes32[] calldata proof)
        internal
        returns (uint256 amount)
    {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulative))));
        if (!MerkleProof.verifyCalldata(proof, _root, leaf)) revert BadProof();
        uint256 done = claimed[account][token];
        if (cumulative <= done) return 0;
        TokenState storage s = _state[token];
        amount = cumulative - done;
        if (s.claimed + amount > s.total) revert OverTotal(token, amount, s.total - s.claimed);
        claimed[account][token] = cumulative;
        s.claimed += amount;
        IERC20(token).safeTransfer(account, amount);
        emit Claimed(account, token, amount, cumulative);
    }

    // ------------------------------------------------------------------ the owner

    /// @notice Send `amount` of `token` that no root promises to `to`. Only the owner; never more than reclaimable().
    function reclaim(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        uint256 free = reclaimable(token);
        if (amount > free) revert OverReclaimable(token, amount, free);
        IERC20(token).safeTransfer(to, amount);
        emit Reclaimed(token, to, amount);
    }

    /// @notice List another token for the basket. Listed tokens are never removed (a token's growth limit can be set
    ///         to zero instead, and whatever no root promises of it reclaimed).
    function listToken(address token, uint256 maxIncreasePerSecond_) external onlyOwner {
        _list(token, maxIncreasePerSecond_);
    }

    /// @notice How fast the promised total of `token` may grow, in token wei per second.
    function setMaxIncreasePerSecond(address token, uint256 maxIncreasePerSecond_) external onlyOwner {
        if (!_state[token].listed) revert NotListed(token);
        _state[token].maxIncreasePerSecond = maxIncreasePerSecond_;
        emit MaxIncreaseSet(token, maxIncreasePerSecond_);
    }

    function setUpdater(address updater_) external onlyOwner {
        if (updater_ == address(0)) revert ZeroAddress();
        if (updater_ == guardian) revert GuardianIsUpdater();
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        if (guardian_ == updater) revert GuardianIsUpdater();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    // ------------------------------------------------------------------ internals

    function _list(address token, uint256 maxIncreasePerSecond_) internal {
        if (token == address(0)) revert ZeroAddress();
        if (_state[token].listed) revert AlreadyListed(token);
        if (_tokens.length >= MAX_TOKENS) revert TooManyTokens();
        _tokens.push(token);
        _state[token].listed = true;
        _state[token].maxIncreasePerSecond = maxIncreasePerSecond_;
        emit TokenListed(token, maxIncreasePerSecond_);
    }

    function _ready() internal view returns (bool) {
        return pendingAt != 0 && block.timestamp >= pendingAt;
    }

    /// @dev A pending root whose wait is over becomes the root, with its totals.
    function _promote() internal {
        if (!_ready()) return;
        _root = pendingRoot;
        _totalAt = pendingProposedAt;
        uint256 n = _tokens.length;
        for (uint256 i; i < n; ++i) {
            TokenState storage s = _state[_tokens[i]];
            s.total = s.pendingTotal;
        }
        _clearPending();
    }

    function _clearPending() internal {
        uint256 n = _tokens.length;
        for (uint256 i; i < n; ++i) {
            delete _state[_tokens[i]].pendingTotal;
        }
        delete pendingRoot;
        delete pendingProposedAt;
        delete pendingAt;
    }
}
