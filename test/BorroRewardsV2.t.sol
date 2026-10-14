// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BorroRewards} from "../src/BorroRewards.sol";
import {BorroRewardsV2} from "../src/BorroRewardsV2.sol";

/// USDG for the tests: 6 decimals, mintable, and able to refuse transfers to one address (a frozen wallet), which
/// is what makes a winner unpayable.
contract TestUsdg is ERC20 {
    address public frozen;

    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze(address who) external {
        frozen = who;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(to != frozen || to == address(0), "frozen");
        super._update(from, to, value);
    }
}

/// What both versions share: everything BorroShort and the keeper call.
interface IPots {
    struct Terms {
        uint16 prizeShareBps;
        uint16 rentCapBps;
        uint16 refundShareBps;
        uint128 minNotional;
    }

    function week() external view returns (uint256);
    function weekEnds() external view returns (uint256);
    function terms() external view returns (Terms memory);
    function rentPot() external view returns (uint256);
    function prizeTotal() external view returns (uint256);
    function prizePot(uint256) external view returns (uint256);
    function settled(uint256) external view returns (bool);
    function best(uint256) external view returns (address who, uint32 returnBps, uint128 notional, bytes32 id);
    function fund(uint256 amount) external;
    function absorb() external returns (uint256);
    function onClose(address shorter, bytes32 id, uint256 notional, uint256 rentPaid, uint256 heldFor, int256 returnBps) external;
    function settle(uint256 w) external;
    function setTerms(uint256 prizeShareBps, uint256 rentCapBps, uint256 refundShareBps, uint256 minNotional) external;
}

/// Every behavior of the first version's pots, run against whichever version `deployPots` makes.
abstract contract PotsBehavior is Test {
    TestUsdg usdg;
    IPots pots;
    address short = makeAddr("short");
    address owner = makeAddr("owner");
    address funder = makeAddr("funder");
    address ann = makeAddr("ann");
    address bea = makeAddr("bea");
    bytes32 constant ID = keccak256("NVDA");

    event Funded(address indexed from, uint256 toRent, uint256 toPrize, uint256 week);
    event RentRefunded(address indexed shorter, bytes32 indexed id, uint256 amount, uint256 rentPaid);
    event Leader(uint256 indexed week, address indexed shorter, bytes32 indexed id, uint256 returnBps, uint256 notional);
    event PrizePaid(uint256 indexed week, address indexed shorter, uint256 amount);
    event PrizeRolled(uint256 indexed week, uint256 amount);

    function deployPots() internal virtual returns (address);

    function setUp() public virtual {
        vm.warp(1_791_205_200); // Monday 2026-10-05 13:00 UTC, the week Borro launched
        usdg = new TestUsdg();
        pots = IPots(deployPots());
        usdg.mint(funder, 1_000_000e6);
        vm.prank(funder);
        usdg.approve(address(pots), type(uint256).max);
    }

    function fund(uint256 amount) internal {
        vm.prank(funder);
        pots.fund(amount);
    }

    function close(address who, uint256 notional, uint256 rentPaid, uint256 heldFor, int256 returnBps) internal {
        vm.prank(short);
        pots.onClose(who, ID, notional, rentPaid, heldFor, returnBps);
    }

    function test_week_starts_monday_midnight_utc() public view {
        uint256 ends = pots.weekEnds();
        assertEq((ends / 1 days + 4) % 7, 1, "a Monday"); // 1970-01-01 was a Thursday
        assertEq(ends % 1 days, 0, "midnight");
    }

    function test_funding_splits_between_rent_and_the_weeks_prize() public {
        vm.expectEmit(address(pots));
        emit Funded(funder, 700e6, 300e6, pots.week());
        fund(1_000e6);
        assertEq(pots.rentPot(), 700e6);
        assertEq(pots.prizePot(pots.week()), 300e6);
        assertEq(pots.prizeTotal(), 300e6);
        assertEq(usdg.balanceOf(address(pots)), 1_000e6);
    }

    function test_stray_usdg_is_absorbed_into_the_rent_pot() public {
        fund(100e6);
        usdg.mint(address(pots), 50e6);
        pots.absorb();
        assertEq(pots.rentPot(), 70e6 + 50e6);
        assertEq(usdg.balanceOf(address(pots)), pots.rentPot() + pots.prizeTotal());
    }

    function test_only_the_short_desk_reports_closes() public {
        vm.expectRevert(BorroRewards.OnlyShort.selector);
        pots.onClose(ann, ID, 1_000e6, 1e6, 1 days, 100);
    }

    function test_rent_refund_is_limited_by_rent_paid_yearly_cap_and_pot_share() public {
        fund(10_000e6); // rent pot 7,000
        // rent paid is the limit: 1 USDG back on a big, long short
        close(ann, 100_000e6, 1e6, 365 days, 0);
        assertEq(usdg.balanceOf(ann), 1e6);
        // the yearly cap: 5% a year of 1,000 for 73 days is 10, under the 50 paid
        close(bea, 1_000e6, 50e6, 73 days, 0);
        assertEq(usdg.balanceOf(bea), 10e6);
        // a share of the pot: one close takes at most 5% of what is left
        uint256 pot = pots.rentPot();
        address cal = makeAddr("cal");
        vm.expectEmit(address(pots));
        emit RentRefunded(cal, ID, pot * 500 / 10_000, 1_000_000e6);
        close(cal, 100_000_000e6, 1_000_000e6, 365 days, 0);
        assertEq(pots.rentPot(), pot - pot * 500 / 10_000);
    }

    function test_only_a_big_enough_profitable_short_held_an_hour_leads() public {
        uint256 w = pots.week();
        close(ann, 400e6, 0, 2 hours, 500); // too small
        close(ann, 600e6, 0, 30 minutes, 500); // too short
        close(ann, 600e6, 0, 2 hours, 0); // no gain
        (address who,,,) = pots.best(w);
        assertEq(who, address(0));
        vm.expectEmit(address(pots));
        emit Leader(w, ann, ID, 300, 600e6);
        close(ann, 600e6, 0, 2 hours, 300);
        close(bea, 800e6, 0, 2 hours, 200); // lower: ann keeps the lead
        (who,,,) = pots.best(w);
        assertEq(who, ann);
        close(bea, 800e6, 0, 2 hours, 900);
        (who,,,) = pots.best(w);
        assertEq(who, bea);
    }

    function test_best_short_of_the_week_is_paid_once_the_week_is_over() public {
        fund(1_000e6);
        uint256 w = pots.week();
        close(ann, 600e6, 0, 2 hours, 300);
        vm.expectRevert(BorroRewards.NotOver.selector);
        pots.settle(w);
        vm.warp(pots.weekEnds() + 1);
        vm.expectEmit(address(pots));
        emit PrizePaid(w, ann, 300e6);
        pots.settle(w);
        assertEq(usdg.balanceOf(ann), 300e6);
        assertEq(pots.prizeTotal(), 0);
        vm.expectRevert(BorroRewards.AlreadySettled.selector);
        pots.settle(w);
    }

    function test_an_unwon_pot_rolls_into_the_current_week() public {
        fund(1_000e6);
        uint256 w = pots.week();
        vm.warp(pots.weekEnds() + 1);
        vm.expectEmit(address(pots));
        emit PrizeRolled(w, 300e6);
        pots.settle(w);
        assertEq(pots.prizePot(w + 1), 300e6);
        assertEq(pots.prizeTotal(), 300e6);
    }

    function test_an_unpayable_winner_does_not_lock_the_pot() public {
        fund(1_000e6);
        uint256 w = pots.week();
        close(ann, 600e6, 0, 2 hours, 300);
        usdg.freeze(ann);
        vm.warp(pots.weekEnds() + 1);
        pots.settle(w);
        assertEq(pots.prizePot(w + 1), 300e6, "rolled on");
    }

    function test_terms_are_owner_only_bounded_and_wait_until_the_week_after_next() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ann));
        vm.prank(ann);
        pots.setTerms(5_000, 500, 500, 500e6);
        vm.startPrank(owner);
        vm.expectRevert(BorroRewards.BadTerms.selector);
        pots.setTerms(10_001, 500, 500, 500e6);
        vm.expectRevert(BorroRewards.BadTerms.selector);
        pots.setTerms(3_000, 2_001, 500, 500e6);
        vm.expectRevert(BorroRewards.BadTerms.selector);
        pots.setTerms(3_000, 500, 1_001, 500e6);
        pots.setTerms(10_000, 500, 500, 500e6);
        vm.stopPrank();
        assertEq(pots.terms().prizeShareBps, 3_000, "not this week");
        vm.warp(pots.weekEnds() + 1);
        assertEq(pots.terms().prizeShareBps, 3_000, "not next week");
        vm.warp(pots.weekEnds() + 1);
        assertEq(pots.terms().prizeShareBps, 10_000, "the week after next");
        fund(100e6);
        assertEq(pots.prizePot(pots.week()), 100e6, "all to the prize now");
    }
}

contract BorroRewardsV1Test is PotsBehavior {
    function deployPots() internal override returns (address) {
        return address(new BorroRewards(IERC20(address(usdg)), short, owner));
    }
}

contract BorroRewardsV2Test is PotsBehavior {
    BorroRewardsV2 v2;

    event ReclaimQueued(address indexed to, uint256 prizeAmount, uint256 rentAmount, uint256 readyAt);
    event ReclaimCancelled(address indexed to, uint256 prizeAmount, uint256 rentAmount);
    event Reclaimed(address indexed to, uint256 prize, uint256 rent, uint256 extra);

    address safe = makeAddr("safe");

    function deployPots() internal override returns (address) {
        v2 = new BorroRewardsV2(IERC20(address(usdg)), short, owner, BorroRewardsV2.Terms({prizeShareBps: 3_000, rentCapBps: 500, refundShareBps: 500, minNotional: 500e6}));
        return address(v2);
    }

    function queue(uint256 prize, uint256 rent) internal {
        vm.prank(owner);
        v2.queueReclaim(safe, prize, rent);
    }

    function execute() internal returns (uint256 prize, uint256 rent, uint256 extra) {
        vm.prank(owner);
        return v2.executeReclaim();
    }

    function consistent() internal view {
        assertEq(usdg.balanceOf(address(v2)), v2.rentPot() + v2.prizeTotal(), "pots add up to the balance");
    }

    function test_constructor_takes_the_terms_it_is_given_and_checks_them() public {
        BorroRewardsV2 other = new BorroRewardsV2(IERC20(address(usdg)), short, owner, BorroRewardsV2.Terms({prizeShareBps: 10_000, rentCapBps: 100, refundShareBps: 200, minNotional: 1e6}));
        assertEq(other.terms().prizeShareBps, 10_000);
        assertEq(other.terms().minNotional, 1e6);
        vm.expectRevert(BorroRewardsV2.BadTerms.selector);
        new BorroRewardsV2(IERC20(address(usdg)), short, owner, BorroRewardsV2.Terms({prizeShareBps: 10_001, rentCapBps: 100, refundShareBps: 200, minNotional: 1e6}));
        vm.expectRevert(BorroRewardsV2.ZeroAddress.selector);
        new BorroRewardsV2(IERC20(address(usdg)), address(0), owner, BorroRewardsV2.Terms({prizeShareBps: 3_000, rentCapBps: 500, refundShareBps: 500, minNotional: 500e6}));
    }

    function test_only_the_owner_can_queue_cancel_or_execute() public {
        vm.startPrank(ann);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ann));
        v2.queueReclaim(ann, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ann));
        v2.cancelReclaim();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ann));
        v2.executeReclaim();
        vm.stopPrank();
        vm.expectRevert(BorroRewardsV2.ZeroAddress.selector);
        vm.prank(owner);
        v2.queueReclaim(address(0), 1, 1);
    }

    function test_a_reclaim_waits_seven_days_in_public() public {
        fund(1_000e6);
        vm.expectRevert(BorroRewardsV2.NothingQueued.selector);
        execute();
        uint256 readyAt = vm.getBlockTimestamp() + 7 days;
        vm.expectEmit(address(v2));
        emit ReclaimQueued(safe, 300e6, 700e6, readyAt);
        queue(300e6, 700e6);
        (address to, uint256 p, uint256 r, uint256 at) = v2.pendingReclaim();
        assertEq(to, safe);
        assertEq(p, 300e6);
        assertEq(r, 700e6);
        assertEq(at, readyAt);
        vm.warp(readyAt - 1);
        vm.expectRevert(BorroRewardsV2.NotReady.selector);
        execute();
    }

    function test_queuing_again_replaces_and_restarts_the_wait() public {
        fund(1_000e6);
        queue(300e6, 0);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        queue(0, 700e6);
        vm.warp(vm.getBlockTimestamp() + 2 days); // 8 days after the first, 2 after the second
        vm.expectRevert(BorroRewardsV2.NotReady.selector);
        execute();
        vm.warp(vm.getBlockTimestamp() + 5 days);
        (uint256 prize, uint256 rent,) = execute();
        assertEq(prize, 0, "the replaced request is gone");
        assertEq(rent, 700e6);
    }

    function test_cancel_drops_the_request() public {
        fund(1_000e6);
        queue(300e6, 700e6);
        vm.expectEmit(address(v2));
        emit ReclaimCancelled(safe, 300e6, 700e6);
        vm.prank(owner);
        v2.cancelReclaim();
        (,,, uint256 at) = v2.pendingReclaim();
        assertEq(at, 0);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.expectRevert(BorroRewardsV2.NothingQueued.selector);
        execute();
        vm.expectRevert(BorroRewardsV2.NothingQueued.selector);
        vm.prank(owner);
        v2.cancelReclaim();
    }

    function test_reclaim_takes_what_is_there_up_to_what_was_asked() public {
        fund(1_000e6); // prize 300 this week, rent 700
        queue(type(uint256).max, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        // a week later the pot of the launch week is still in the launch week: settle rolls it to the current one
        pots.settle(pots.week() - 1);
        vm.expectEmit(address(v2));
        emit Reclaimed(safe, 300e6, 700e6, 0);
        (uint256 prize, uint256 rent, uint256 extra) = execute();
        assertEq(prize, 300e6);
        assertEq(rent, 700e6);
        assertEq(extra, 0);
        assertEq(usdg.balanceOf(safe), 1_000e6, "all of it back");
        assertEq(v2.rentPot(), 0);
        assertEq(v2.prizeTotal(), 0);
        consistent();
    }

    function test_a_partial_reclaim_leaves_the_rest_working() public {
        fund(1_000e6);
        queue(100e6, 200e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        pots.settle(pots.week() - 1);
        execute();
        assertEq(usdg.balanceOf(safe), 300e6);
        assertEq(v2.rentPot(), 500e6);
        assertEq(v2.prizePot(v2.week()), 200e6);
        consistent();
        // closes still refund rent from what is left, and the week's pot is still won and paid
        close(ann, 1_000e6, 10e6, 365 days, 400);
        assertEq(usdg.balanceOf(ann), 10e6);
        uint256 w = v2.week();
        vm.warp(v2.weekEnds() + 1);
        pots.settle(w);
        assertEq(usdg.balanceOf(ann), 10e6 + 200e6, "refund plus the prize");
        consistent();
    }

    function test_a_prize_someone_leads_for_is_never_reclaimed() public {
        fund(1_000e6);
        queue(300e6, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        pots.settle(pots.week() - 1); // the launch week's 300 rolls into this week
        close(ann, 600e6, 0, 2 hours, 300); // ann leads this week
        (uint256 prize,,) = execute();
        assertEq(prize, 0, "ann's prize stays");
        assertEq(v2.prizePot(v2.week()), 300e6);
        uint256 w = v2.week();
        vm.warp(v2.weekEnds() + 1);
        pots.settle(w);
        assertEq(usdg.balanceOf(ann), 300e6, "and is paid");
        consistent();
    }

    function test_with_nobody_leading_the_prize_comes_back() public {
        fund(1_000e6);
        close(ann, 400e6, 0, 2 hours, 300); // under $500: does not lead
        queue(300e6, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        pots.settle(pots.week() - 1);
        (uint256 prize,,) = execute();
        assertEq(prize, 300e6);
        consistent();
    }

    function test_usdg_sent_without_fund_comes_back_with_a_reclaim() public {
        fund(1_000e6);
        usdg.mint(address(v2), 25e6);
        queue(0, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 prize, uint256 rent, uint256 extra) = execute();
        assertEq(prize + rent, 0);
        assertEq(extra, 25e6);
        assertEq(usdg.balanceOf(safe), 25e6);
        assertEq(v2.rentPot(), 700e6, "the pots are untouched");
        consistent();
    }

    function test_reclaiming_more_than_exists_is_capped_not_refused() public {
        fund(10e6);
        queue(1_000_000e6, 1_000_000e6);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        pots.settle(pots.week() - 1);
        (uint256 prize, uint256 rent,) = execute();
        assertEq(prize, 3e6);
        assertEq(rent, 7e6);
        consistent();
        // and a second reclaim with nothing left moves nothing but still clears
        queue(1, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (prize, rent,) = execute();
        assertEq(prize + rent, 0);
    }
}
