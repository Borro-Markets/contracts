// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IPaysToken {
    function token() external view returns (IERC20);
    function paused() external view returns (bool);
}

/// @title BorroDrip
/// @notice Holds Roy's $BORRO and lets it out to Borro's depositors over 104 weeks, halving every 26 weeks.
///         Roy, 2026-10-07: "drip out over a long time horizon so that it incentivizes long term holding and use of
///         the platform rather than short term".
/// @dev Roy funds it with a plain transfer, then calls start(). start() fixes the schedule: `total` is what the
///      contract holds at that moment, and the schedule runs from that moment over four periods of PERIOD (26 weeks)
///      each. Each period lets out half as much as the one before: 8/15, 4/15, 2/15 and 1/15 of the total, the last
///      taking the rounding remainder, at a steady rate within each period. So the daily amount halves at each
///      period's end and everything is out after DURATION (104 weeks).
///
///      drip() is open to anyone and sends what the schedule has let out so far and not yet sent, to one fixed
///      distributor (a BorroDistributor for $BORRO, checked at deploy). The keeper's drip job calls it once a day and
///      shares it out from there. Nothing else ever leaves, except by stop().
///
///      The owner (Roy's wallet; two-step transfer, no renounce) has two powers: start() once, and stop(to), which
///      sends every token this contract still holds (everything not yet let out) to `to`, at once, and ends the
///      schedule for good (before or after start()). stop() can be called again later and sends whatever has arrived
///      since, so a token sent here by mistake is never stuck. What was already let out sits in the distributor,
///      where what each depositor has been promised stays theirs (the distributor's owner can take back only what no
///      root promises). Tokens that arrive after start() are not part of the schedule; only stop() sends them.
contract BorroDrip is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant PERIOD = 26 weeks; // 182 days
    uint256 public constant PERIODS = 4;
    uint256 public constant DURATION = PERIOD * PERIODS; // 104 weeks, 728 days

    IERC20 public immutable token;
    address public immutable distributor;

    uint256 public total; // what the schedule lets out in all: the balance when start() was called
    uint256 public startedAt; // when start() was called; zero before
    uint256 public sent; // sent to the distributor so far
    uint256 public stoppedAt; // when stop() was first called; zero while it has not been

    event Started(uint256 total, uint256 startedAt);
    event Dripped(uint256 amount, uint256 sent);
    event Stopped(address indexed to, uint256 amount, uint256 stoppedAt);

    error ZeroAddress();
    error WrongToken();
    error AlreadyStarted();
    error NothingHeld();
    error IsStopped();
    error NoRenounce();

    /// @param token_ $BORRO.
    /// @param distributor_ The distributor every drip goes to. It must pay `token_`.
    /// @param owner_ The only address that can start and stop the drip (Roy's wallet).
    constructor(IERC20 token_, address distributor_, address owner_) Ownable(owner_) {
        if (address(token_) == address(0) || distributor_ == address(0)) revert ZeroAddress();
        if (IPaysToken(distributor_).token() != token_) revert WrongToken();
        // It must answer paused() too (drip() asks it every time), so a distributor without it is refused here.
        IPaysToken(distributor_).paused();
        token = token_;
        distributor = distributor_;
    }

    /// @notice Starts the schedule now, over everything this contract holds now. Only the owner, only once, never
    ///         after stop(), never with nothing held. Fund first, then start.
    function start() external onlyOwner returns (uint256 total_) {
        if (startedAt != 0) revert AlreadyStarted();
        if (stoppedAt != 0) revert IsStopped();
        total_ = token.balanceOf(address(this));
        if (total_ == 0) revert NothingHeld();
        total = total_;
        startedAt = block.timestamp;
        emit Started(total_, block.timestamp);
    }

    /// @notice What period `i` (0 to 3) lets out in all: 8/15, 4/15, 2/15 of the total, and the rest. Zero before start.
    function periodAmount(uint256 i) public view returns (uint256) {
        uint256 a = (total * 8) / 15;
        uint256 b = (total * 4) / 15;
        uint256 c = (total * 2) / 15;
        if (i == 0) return a;
        if (i == 1) return b;
        if (i == 2) return c;
        if (i == 3) return total - a - b - c;
        return 0;
    }

    /// @notice What the schedule has let out by time `t`, from the start: never down as `t` grows, `total` from
    ///         startedAt + DURATION on, zero before start(). It does not stop with stop(); releasable() does.
    function scheduled(uint256 t) public view returns (uint256) {
        uint256 s = startedAt;
        if (s == 0 || t <= s) return 0;
        uint256 e = t - s;
        if (e >= DURATION) return total;
        uint256 k = e / PERIOD;
        uint256 done;
        for (uint256 i; i < k; ++i) done += periodAmount(i);
        return done + (periodAmount(k) * (e - k * PERIOD)) / PERIOD;
    }

    /// @notice What drip() would send now: what the schedule has let out and not yet been sent, at most what this
    ///         contract holds. Zero before start(), after stop(), and while the distributor's guardian has it paused:
    ///         then nothing more goes in, and what has not gone in stays where stop() reaches it. The schedule keeps
    ///         running meanwhile, so an unpause sends what accrued.
    function releasable() public view returns (uint256) {
        if (stoppedAt != 0 || startedAt == 0) return 0;
        if (IPaysToken(distributor).paused()) return 0;
        uint256 due = scheduled(block.timestamp) - sent;
        uint256 held = token.balanceOf(address(this));
        return due < held ? due : held;
    }

    /// @notice Sends what is releasable to the distributor. Anyone can call it. Returns what it sent (maybe zero).
    function drip() external returns (uint256 amount) {
        if (stoppedAt != 0) revert IsStopped();
        amount = releasable();
        if (amount == 0) return 0;
        sent += amount;
        token.safeTransfer(distributor, amount);
        emit Dripped(amount, sent);
    }

    /// @notice Ends the schedule for good and sends `to` every token this contract holds: all that was not yet let
    ///         out. Only the owner. Called again, it sends whatever has arrived since. Returns what it sent.
    /// @dev To let the share so far go out first, call drip() before this.
    function stop(address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        if (stoppedAt == 0) stoppedAt = block.timestamp;
        amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(to, amount);
        emit Stopped(to, amount, stoppedAt);
    }

    /// @notice The owner can hand the drip over (two steps), never give it up: with no owner, nothing could start or
    ///         stop it.
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }
}
