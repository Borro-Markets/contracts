// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title BorroRewards
/// @notice Two pots of USDG, filled by anyone (in practice: the Borro coin's fees).
///         The rent pot refunds the rent a shorter paid, when they close, for as long as it has money.
///         The prize pot of each week goes to the best short closed that week.
/// @dev Money leaves only as a rent refund or a prize. There is no way for the owner to take it out.
///      Only the shorting contract can report a close, and that address is fixed for good. The owner sets
///      how incoming money is split, the limits on a rent refund, and the smallest short that can win.
///      A change to those terms starts with the week after next, so there is always a full week's notice.
///      A week runs Monday 00:00 UTC to the next.
///      The rent pot is a subsidy, and a subsidy can be collected by someone who lends to themselves and
///      shorts their own stock. Three limits keep that slow and costly: rent comes back only up to a yearly
///      rate on the short's size, one close takes at most a set share of the pot, and the rate has a hard cap.
contract BorroRewards is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant WEEK = 7 days;
    uint256 public constant ANCHOR = 4 days; // 1970-01-05 00:00 UTC was a Monday
    uint256 public constant MAX_RENT_CAP_BPS = 2_000; // rent is never refunded past 20% a year of the short's size
    uint256 public constant MAX_REFUND_SHARE_BPS = 1_000; // one close never takes more than a tenth of the pot
    uint256 public constant MIN_HOLD = 1 hours; // a short must have been open this long to win the prize

    IERC20 public immutable usdg;
    address public immutable short;

    struct Terms {
        uint16 prizeShareBps; // of each funding, this much goes to the week's prize; the rest refunds rent
        uint16 rentCapBps; // rent is refunded up to this yearly rate on the short's size
        uint16 refundShareBps; // one close takes at most this share of the rent pot
        uint128 minNotional; // a short must be at least this big, in USDG wei, to win the prize
    }

    Terms internal _terms = Terms({prizeShareBps: 3_000, rentCapBps: 500, refundShareBps: 500, minNotional: 500e6});
    Terms internal _next;
    uint256 public nextFromWeek; // zero: no change waiting

    uint256 public rentPot;
    uint256 public prizeTotal; // the sum of every week's unpaid prize pot
    mapping(uint256 week => uint256) public prizePot;
    mapping(uint256 week => bool) public settled;

    struct Best {
        address who;
        uint32 returnBps;
        uint128 notional;
        bytes32 id;
    }

    mapping(uint256 week => Best) public best;

    event Funded(address indexed from, uint256 toRent, uint256 toPrize, uint256 week);
    event RentRefunded(address indexed shorter, bytes32 indexed id, uint256 amount, uint256 rentPaid);
    event Leader(uint256 indexed week, address indexed shorter, bytes32 indexed id, uint256 returnBps, uint256 notional);
    event PrizePaid(uint256 indexed week, address indexed shorter, uint256 amount);
    event PrizeRolled(uint256 indexed week, uint256 amount);
    event TermsQueued(uint256 fromWeek, uint256 prizeShareBps, uint256 rentCapBps, uint256 refundShareBps, uint256 minNotional);

    error OnlyShort();
    error BadTerms();
    error NotOver();
    error AlreadySettled();

    constructor(IERC20 usdg_, address short_, address owner_) Ownable(owner_) {
        usdg = usdg_;
        short = short_;
    }

    function week() public view returns (uint256) {
        return (block.timestamp - ANCHOR) / WEEK;
    }

    /// @notice When the current week closes.
    function weekEnds() external view returns (uint256) {
        return ANCHOR + (week() + 1) * WEEK;
    }

    /// @notice The terms in force right now.
    function terms() public view returns (Terms memory) {
        return nextFromWeek != 0 && week() >= nextFromWeek ? _next : _terms;
    }

    /// @notice Terms waiting for the next week, if any.
    function nextTerms() external view returns (Terms memory) {
        return _next;
    }

    function _roll() internal returns (Terms memory t) {
        if (nextFromWeek != 0 && week() >= nextFromWeek) {
            _terms = _next;
            nextFromWeek = 0;
        }
        return _terms;
    }

    /// @notice Put USDG into the pots. Anyone can. It is split between this week's prize and the rent pot.
    function fund(uint256 amount) external {
        Terms memory t = _roll();
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        uint256 toPrize = (amount * t.prizeShareBps) / BPS;
        uint256 w = week();
        prizePot[w] += toPrize;
        prizeTotal += toPrize;
        rentPot += amount - toPrize;
        emit Funded(msg.sender, amount - toPrize, toPrize, w);
    }

    /// @notice USDG sent here without `fund` belongs to no pot. This adds it to the rent pot. Anyone can call it.
    function absorb() external returns (uint256 extra) {
        extra = usdg.balanceOf(address(this)) - rentPot - prizeTotal;
        rentPot += extra;
        emit Funded(msg.sender, extra, 0, week());
    }

    /// @notice Called by the shorting contract on every close of a short it opened.
    /// @param notional What the closed stock was worth when it was borrowed, in USDG wei.
    /// @param rentPaid The rent paid on it, in USDG wei.
    /// @param heldFor Seconds the short was open.
    /// @param returnBps What the short made, in hundredths of a percent of its size.
    function onClose(address shorter, bytes32 id, uint256 notional, uint256 rentPaid, uint256 heldFor, int256 returnBps) external {
        if (msg.sender != short) revert OnlyShort();
        Terms memory t = _roll();

        uint256 refund = rentPaid;
        uint256 cap = (notional * t.rentCapBps * heldFor) / (BPS * 365 days);
        if (refund > cap) refund = cap;
        uint256 slice = (rentPot * t.refundShareBps) / BPS;
        if (refund > slice) refund = slice;
        if (refund != 0) {
            rentPot -= refund;
            usdg.safeTransfer(shorter, refund);
            emit RentRefunded(shorter, id, refund, rentPaid);
        }

        if (returnBps > 0 && notional >= t.minNotional && heldFor >= MIN_HOLD) {
            uint256 w = week();
            uint256 r = uint256(returnBps);
            if (r > best[w].returnBps) {
                best[w] = Best({who: shorter, returnBps: uint32(r), notional: uint128(notional), id: id});
                emit Leader(w, shorter, id, r, notional);
            }
        }
    }

    /// @notice Pay a finished week's prize to its best short. Anyone can call it. With no winner, or a
    ///         winner who cannot be paid, the pot moves to the current week.
    function settle(uint256 w) external {
        if (w >= week()) revert NotOver();
        if (settled[w]) revert AlreadySettled();
        settled[w] = true;
        uint256 pot = prizePot[w];
        prizePot[w] = 0;
        address who = best[w].who;
        if (pot == 0) return;
        if (who != address(0) && _pay(who, pot)) {
            prizeTotal -= pot;
            emit PrizePaid(w, who, pot);
        } else {
            prizePot[week()] += pot;
            emit PrizeRolled(w, pot);
        }
    }

    /// @notice Change the terms. The change starts with the week after next, so there is always a full
    ///         week's notice.
    function setTerms(uint256 prizeShareBps, uint256 rentCapBps, uint256 refundShareBps, uint256 minNotional) external onlyOwner {
        if (prizeShareBps > BPS || rentCapBps > MAX_RENT_CAP_BPS || refundShareBps > MAX_REFUND_SHARE_BPS) revert BadTerms();
        if (minNotional > type(uint128).max) revert BadTerms();
        _roll();
        _next = Terms({
            prizeShareBps: uint16(prizeShareBps),
            rentCapBps: uint16(rentCapBps),
            refundShareBps: uint16(refundShareBps),
            minNotional: uint128(minNotional)
        });
        nextFromWeek = week() + 2;
        emit TermsQueued(nextFromWeek, prizeShareBps, rentCapBps, refundShareBps, minNotional);
    }

    /// @dev A transfer that reports failure instead of reverting, so one unpayable winner cannot lock a pot.
    function _pay(address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(usdg).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
