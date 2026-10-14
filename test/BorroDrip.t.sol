// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BorroDrip} from "../src/BorroDrip.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";
import {WatchedCoin} from "./WatchedCoin.sol";

/// Merkle trees over (account, cumulative) leaves, hashed the way BorroDistributor checks them (leaf hashed twice,
/// pairs hashed sorted). The last node of an odd layer moves up as it is.
library DripTree {
    function leaf(address account, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    function hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function up(bytes32[] memory layer) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((layer.length + 1) / 2);
        for (uint256 i; i < next.length; ++i) {
            next[i] = 2 * i + 1 < layer.length ? hashPair(layer[2 * i], layer[2 * i + 1]) : layer[2 * i];
        }
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory layer = leaves;
        while (layer.length > 1) layer = up(layer);
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        bytes32[] memory tmp = new bytes32[](64);
        uint256 n;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 sib = index ^ 1;
            if (sib < layer.length) tmp[n++] = layer[sib];
            layer = up(layer);
            index /= 2;
        }
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) out[i] = tmp[i];
    }
}

/// Pays a token but has no paused(): not a BorroDistributor, so the drip must refuse it.
contract TokenOnly {
    IERC20 public token;

    constructor(IERC20 t) {
        token = t;
    }
}

/// Times are read with vm.getBlockTimestamp(): under via_ir the compiler may treat block.timestamp as fixed for the
/// whole test and read it after a later vm.warp.
contract BorroDripBase is Test {
    uint256 constant DAY = 1 days;
    uint256 constant PERIOD = 26 weeks; // 182 days
    uint256 constant DURATION = 104 weeks; // 728 days
    uint256 constant T0 = 1_800_000_000; // 2027-01-15 08:00 UTC, deploy time: not a midnight
    uint256 constant FUND = 50_000_000e18; // what Roy sends before start()
    uint256 constant EXPECTED = 50_000_000e18; // what the deploy script sizes the distributor's growth limit for
    uint256 constant SUPPLY = 1_000_000_000e18;

    WatchedCoin coin;
    BorroDistributor dist;
    BorroDrip drip;
    address safe = makeAddr("safe"); // the Hoard Safe: owns the distributor
    address keeper = makeAddr("keeper"); // the distributor's updater
    address guardian = makeAddr("guardian");
    address roy = makeAddr("roy"); // owns the drip: the only one who can start or stop it
    address royCold = makeAddr("royCold"); // where Roy's stop sends
    address holder = makeAddr("holder"); // the wallet that holds Roy's $BORRO
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function setUp() public virtual {
        vm.warp(T0);
        coin = new WatchedCoin();
        coin.mint(holder, SUPPLY);
        dist = new BorroDistributor(IERC20(address(coin)), safe, keeper, guardian, limitFor(EXPECTED));
        drip = new BorroDrip(IERC20(address(coin)), address(dist), roy);
        coin.watch(address(drip));
    }

    /// The deploy script's growth limit: twice the first period's rate for the expected total.
    function limitFor(uint256 expected) internal pure returns (uint256) {
        return (2 * ((expected * 8) / 15)) / PERIOD;
    }

    function fund(uint256 a) internal {
        vm.prank(holder);
        coin.transfer(address(drip), a);
    }

    function startAt(uint256 t) internal returns (uint256 total) {
        vm.warp(t);
        vm.prank(roy);
        total = drip.start();
    }

    /// What day `day` after start lets out (days counted from startedAt).
    function dayAfterStart(BorroDrip d, uint256 day) internal view returns (uint256) {
        uint256 s = d.startedAt();
        return d.scheduled(s + (day + 1) * DAY) - d.scheduled(s + day * DAY);
    }

    /// What UTC day `e` lets out, the way the keeper counts it: base(e) = scheduled((e+1)E) - scheduled(eE).
    function base(BorroDrip d, uint256 e) internal view returns (uint256) {
        return d.scheduled((e + 1) * DAY) - d.scheduled(e * DAY);
    }

    /// A started drip of `total` on its own coin, for schedule math on any total.
    function make(uint256 total, uint256 at) internal returns (BorroDrip d) {
        WatchedCoin c = new WatchedCoin();
        BorroDistributor bd = new BorroDistributor(IERC20(address(c)), safe, keeper, guardian, 0);
        d = new BorroDrip(IERC20(address(c)), address(bd), roy);
        c.mint(address(d), total);
        vm.warp(at);
        vm.prank(roy);
        d.start();
    }
}

contract BorroDripTest is BorroDripBase {
    // ------------------------------------------------------------------ deploy

    function test_constructor_links_and_nothing_else() public view {
        assertEq(address(drip.token()), address(coin));
        assertEq(drip.distributor(), address(dist));
        assertEq(drip.owner(), roy);
        assertEq(drip.pendingOwner(), address(0));
        assertEq(drip.PERIOD(), 182 days);
        assertEq(drip.PERIODS(), 4);
        assertEq(drip.DURATION(), 728 days);
        assertEq(drip.total(), 0);
        assertEq(drip.startedAt(), 0);
        assertEq(drip.sent(), 0);
        assertEq(drip.stoppedAt(), 0);
        assertEq(drip.releasable(), 0);
        for (uint256 i; i < 5; ++i) assertEq(drip.periodAmount(i), 0);
    }

    /// Deploys through an external call, so vm.expectRevert sees the constructor's revert as the call's (forge turns
    /// `new` in a test into a cheatcode, and a revert expected on that would end the test early).
    function newDrip(IERC20 t, address d, address o) external returns (BorroDrip) {
        return new BorroDrip(t, d, o);
    }

    function test_constructor_refusals() public {
        IERC20 t = IERC20(address(coin));
        vm.expectRevert(BorroDrip.ZeroAddress.selector);
        this.newDrip(IERC20(address(0)), address(dist), roy);
        vm.expectRevert(BorroDrip.ZeroAddress.selector);
        this.newDrip(t, address(0), roy);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        this.newDrip(t, address(dist), address(0));
        // A distributor that pays another token.
        WatchedCoin other = new WatchedCoin();
        BorroDistributor otherDist = new BorroDistributor(IERC20(address(other)), safe, keeper, guardian, 1);
        vm.expectRevert(BorroDrip.WrongToken.selector);
        this.newDrip(t, address(otherDist), roy);
        // Not a distributor at all: a wallet has no token() to answer.
        vm.expectRevert();
        this.newDrip(t, eve, roy);
        // Pays the token but cannot answer paused(): drip() would ask it every time, so it is refused at deploy.
        address noPause = address(new TokenOnly(t));
        vm.expectRevert();
        this.newDrip(t, noPause, roy);
        // The right ones deploy, and the checks above all ran.
        BorroDrip ok = this.newDrip(t, address(dist), roy);
        assertEq(ok.owner(), roy);
        assertEq(ok.distributor(), address(dist));
    }

    // ------------------------------------------------------------------ start()

    function test_start_fixes_total_to_the_balance_at_any_moment() public {
        fund(30_000_000e18);
        fund(20_000_000e18);
        uint256 t = T0 + 3 days + 7 hours + 11 minutes + 5; // not a midnight: any moment will do
        vm.warp(t);
        vm.expectEmit(address(drip));
        emit BorroDrip.Started(FUND, t);
        vm.prank(roy);
        assertEq(drip.start(), FUND);
        assertEq(drip.total(), FUND);
        assertEq(drip.startedAt(), t);
        assertEq(drip.scheduled(t), 0);
        assertEq(drip.releasable(), 0);
        assertEq(drip.periodAmount(0), 26_666_666_666666666666666666);
        assertEq(drip.periodAmount(1), 13_333_333_333333333333333333);
        assertEq(drip.periodAmount(2), 6_666_666_666666666666666666);
        assertEq(drip.periodAmount(3), 3_333_333_333333333333333335); // the rounding remainder: 2 wei
        assertEq(drip.periodAmount(4), 0);
        assertEq(drip.periodAmount(type(uint256).max), 0);
        // Per day, as Roy was told: 146,520 / 73,260 / 36,630 / 18,315.
        assertEq(dayAfterStart(drip, 0) / 1e18, 146_520);
        assertEq(dayAfterStart(drip, 182) / 1e18, 73_260);
        assertEq(dayAfterStart(drip, 364) / 1e18, 36_630);
        assertEq(dayAfterStart(drip, 546) / 1e18, 18_315);
    }

    function test_start_only_once_never_after_stop_never_empty() public {
        // Nothing held: refused.
        vm.prank(roy);
        vm.expectRevert(BorroDrip.NothingHeld.selector);
        drip.start();
        fund(FUND);
        vm.prank(roy);
        drip.start();
        // Only once, even with more arriving.
        fund(1e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(roy);
        vm.expectRevert(BorroDrip.AlreadyStarted.selector);
        drip.start();
        assertEq(drip.total(), FUND);
        assertEq(drip.startedAt(), T0);
    }

    function test_stop_before_start_returns_everything_and_start_never_comes() public {
        fund(FUND);
        vm.warp(T0 + 5 hours);
        vm.expectEmit(address(drip));
        emit BorroDrip.Stopped(royCold, FUND, T0 + 5 hours);
        vm.prank(roy);
        assertEq(drip.stop(royCold), FUND);
        assertEq(coin.balanceOf(royCold), FUND);
        assertEq(drip.stoppedAt(), T0 + 5 hours);
        fund(10e18);
        vm.prank(roy);
        vm.expectRevert(BorroDrip.IsStopped.selector);
        drip.start();
        assertEq(drip.startedAt(), 0);
        assertEq(drip.total(), 0);
        assertEq(drip.releasable(), 0);
        vm.expectRevert(BorroDrip.IsStopped.selector);
        drip.drip();
        // The later arrival comes back with a second stop.
        vm.prank(roy);
        assertEq(drip.stop(royCold), 10e18);
        assertEq(drip.stoppedAt(), T0 + 5 hours);
        assertEq(coin.paidToCount(), 1);
        assertEq(coin.paidTo(0), royCold);
    }

    function testFuzz_only_the_owner_can_start(address who) public {
        vm.assume(who != roy);
        fund(FUND);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        drip.start();
        assertEq(drip.startedAt(), 0);
        assertEq(drip.total(), 0);
    }

    // ------------------------------------------------------------------ the schedule

    function test_nothing_before_start() public {
        fund(FUND);
        // Time passes, the drip holds 50M, nothing goes out until Roy starts it.
        for (uint256 i; i < 5; ++i) {
            vm.warp(T0 + i * 100 days);
            assertEq(drip.scheduled(vm.getBlockTimestamp()), 0);
            assertEq(drip.scheduled(type(uint256).max), 0);
            assertEq(drip.releasable(), 0);
            vm.prank(eve);
            assertEq(drip.drip(), 0);
        }
        assertEq(drip.sent(), 0);
        assertEq(coin.balanceOf(address(dist)), 0);
        assertEq(coin.paidToCount(), 0);
        // Started late: the schedule runs from the start, not from the deploy.
        uint256 s = T0 + 400 days + 3 hours;
        startAt(s);
        assertEq(drip.scheduled(s), 0);
        assertEq(drip.scheduled(s - 1), 0);
        assertEq(drip.scheduled(T0), 0);
        assertEq(drip.releasable(), 0);
        vm.warp(s + 1);
        assertEq(drip.releasable(), drip.periodAmount(0) / PERIOD);
    }

    function test_scheduled_at_each_point() public {
        fund(FUND);
        uint256 s = T0 + 13 hours + 1;
        startAt(s);
        uint256 a = drip.periodAmount(0);
        uint256 b = drip.periodAmount(1);
        uint256 c = drip.periodAmount(2);
        uint256 d = drip.periodAmount(3);
        assertEq(a + b + c + d, FUND);
        assertEq(drip.scheduled(0), 0);
        assertEq(drip.scheduled(s - 1), 0);
        assertEq(drip.scheduled(s), 0);
        assertEq(drip.scheduled(s + 1), a / PERIOD);
        assertEq(drip.scheduled(s + PERIOD / 2), a / 2);
        assertEq(drip.scheduled(s + PERIOD - 1), (a * (PERIOD - 1)) / PERIOD);
        assertEq(drip.scheduled(s + PERIOD), a);
        assertEq(drip.scheduled(s + PERIOD + PERIOD / 2), a + b / 2);
        assertEq(drip.scheduled(s + 2 * PERIOD), a + b);
        assertEq(drip.scheduled(s + 2 * PERIOD + 1), a + b + c / PERIOD);
        assertEq(drip.scheduled(s + 3 * PERIOD), a + b + c);
        assertEq(drip.scheduled(s + DURATION - 1), a + b + c + (d * (PERIOD - 1)) / PERIOD);
        assertEq(drip.scheduled(s + DURATION), FUND);
        assertEq(drip.scheduled(s + DURATION + 1), FUND);
        assertEq(drip.scheduled(s + 100 * 365 days), FUND);
        assertEq(drip.scheduled(type(uint256).max), FUND);
    }

    function test_awkward_totals_add_up_and_the_last_period_takes_the_remainder() public {
        uint256[12] memory ts = [
            uint256(1), 2, 7, 14, 15, 16, 29, 1e18 + 7, 84_100_000e18, 50_000_000e18 + 13, SUPPLY, type(uint128).max
        ];
        for (uint256 i; i < ts.length; ++i) {
            uint256 t = ts[i];
            BorroDrip d = make(t, T0 + i * 1 hours + 17);
            uint256 a = d.periodAmount(0);
            uint256 b = d.periodAmount(1);
            uint256 c = d.periodAmount(2);
            uint256 last = d.periodAmount(3);
            assertEq(a, (t * 8) / 15);
            assertEq(b, (t * 4) / 15);
            assertEq(c, (t * 2) / 15);
            assertEq(a + b + c + last, t, "the four periods add up to the total");
            assertGe(last, t / 15);
            assertLe(last - t / 15, 3, "the last period takes at most 3 wei of rounding");
            uint256 s = d.startedAt();
            assertEq(d.scheduled(s + DURATION), t);
            assertEq(d.scheduled(s + DURATION - 1), a + b + c + (last * (PERIOD - 1)) / PERIOD);
        }
        // 84.1M, exactly.
        BorroDrip big = make(84_100_000e18, T0 + 1 days);
        assertEq(big.periodAmount(0), 44_853_333_333333333333333333);
        assertEq(big.periodAmount(1), 22_426_666_666666666666666666);
        assertEq(big.periodAmount(2), 11_213_333_333333333333333333);
        assertEq(big.periodAmount(3), 5_606_666_666666666666666668);
    }

    /// Days counted from the start: steady within a period, and halving at each period's end (day 181 vs 182, 363 vs
    /// 364, 545 vs 546), to within a few wei of rounding.
    function test_the_daily_amount_halves_at_each_boundary() public {
        fund(FUND);
        startAt(T0 + 9 hours + 33 minutes);
        uint256 sum;
        uint256[4] memory perPeriod;
        for (uint256 day; day < 728; ++day) {
            uint256 x = dayAfterStart(drip, day);
            uint256 k = day / 182;
            uint256 p = drip.periodAmount(k);
            assertGe(x, p / 182, "steady within the period");
            assertLe(x, p / 182 + 1, "steady within the period");
            perPeriod[k] += x;
            sum += x;
        }
        for (uint256 k; k < 4; ++k) assertEq(perPeriod[k], drip.periodAmount(k), "each period lets out its amount");
        assertEq(sum, FUND);
        assertEq(dayAfterStart(drip, 728), 0);
        assertEq(dayAfterStart(drip, 5000), 0);
        for (uint256 k = 1; k < 4; ++k) {
            uint256 before = dayAfterStart(drip, 182 * k - 1);
            uint256 after_ = dayAfterStart(drip, 182 * k);
            assertApproxEqAbs(before, 2 * after_, 3, "halves at the boundary");
        }
    }

    /// A total that divides evenly halves exactly to the wei.
    function test_an_even_total_halves_exactly() public {
        BorroDrip d = make(15 * 182 * 1e18, T0 + 1234);
        assertEq(dayAfterStart(d, 0), 8e18);
        assertEq(dayAfterStart(d, 181), 8e18);
        assertEq(dayAfterStart(d, 182), 4e18);
        assertEq(dayAfterStart(d, 181), 2 * dayAfterStart(d, 182));
        assertEq(dayAfterStart(d, 363), 2 * dayAfterStart(d, 364));
        assertEq(dayAfterStart(d, 545), 2 * dayAfterStart(d, 546));
        assertEq(dayAfterStart(d, 727), 1e18);
        assertEq(dayAfterStart(d, 728), 0);
    }

    /// UTC days, as the keeper counts them: the first day is partial, a day holding a halving or the end is blended,
    /// whole days on either side of a halving are 2:1, and the days from the start day to the end day add up to the
    /// total exactly.
    function test_utc_days_as_the_keeper_counts_them() public {
        fund(FUND);
        uint256 s = T0 + 2 days + 15 hours + 37 minutes + 12; // 15:37:12 UTC
        startAt(s);
        uint256 startDay = s / DAY;
        uint256 endDay = (s + DURATION - 1) / DAY;
        assertEq(endDay - startDay, 728, "a start mid-day ends mid-day 728 days on");
        assertEq(base(drip, startDay - 1), 0);
        assertEq(base(drip, endDay + 1), 0);
        uint256 sum;
        for (uint256 e = startDay; e <= endDay; ++e) sum += base(drip, e);
        assertEq(sum, FUND, "every UTC day from the start day to the end day adds up to the total");
        // The first day: only the hours after the start.
        uint256 full = dayAfterStart(drip, 0);
        assertApproxEqAbs(base(drip, startDay), (full * ((startDay + 1) * DAY - s)) / DAY, 2);
        assertLt(base(drip, startDay), full);
        for (uint256 k = 1; k < 4; ++k) {
            uint256 bDay = (s + k * PERIOD) / DAY;
            uint256 before = base(drip, bDay - 1);
            uint256 after_ = base(drip, bDay + 1);
            uint256 blended = base(drip, bDay);
            assertApproxEqAbs(before, 2 * after_, 3, "whole days either side of a halving are 2:1");
            assertGt(blended, after_);
            assertLt(blended, before);
        }
        // The last day is partial too.
        assertLt(base(drip, endDay), base(drip, endDay - 1));
    }

    // ------------------------------------------------------------------ drip()

    function test_drip_by_anyone_sends_exactly_releasable_to_the_distributor() public {
        fund(FUND);
        uint256 s = T0 + 1 hours;
        startAt(s);
        vm.warp(s + 10 days + 5 hours);
        uint256 due = drip.scheduled(vm.getBlockTimestamp());
        assertEq(drip.releasable(), due);
        vm.expectEmit(address(drip));
        emit BorroDrip.Dripped(due, due);
        vm.prank(eve);
        assertEq(drip.drip(), due);
        assertEq(coin.balanceOf(address(dist)), due);
        assertEq(coin.balanceOf(eve), 0);
        assertEq(drip.sent(), due);
        assertEq(coin.balanceOf(address(drip)), FUND - due);
        // The same second again: nothing more.
        assertEq(drip.releasable(), 0);
        vm.prank(alice);
        assertEq(drip.drip(), 0);
        // An hour later: exactly the hour's share.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 hour = drip.scheduled(vm.getBlockTimestamp()) - due;
        assertEq(drip.drip(), hour);
        assertEq(drip.sent(), due + hour);
        // Only the distributor has ever received.
        assertEq(coin.paidToCount(), 1);
        assertEq(coin.paidTo(0), address(dist));
    }

    function test_tokens_arriving_after_start_are_outside_the_schedule() public {
        fund(FUND);
        uint256 s = T0 + 30 minutes;
        startAt(s);
        vm.warp(s + 100 days);
        fund(1_000_000e18); // a stray, or a second transfer after start
        assertEq(drip.total(), FUND);
        assertEq(drip.releasable(), drip.scheduled(vm.getBlockTimestamp()));
        drip.drip();
        // At the end everything scheduled has gone, and only the schedule's total.
        vm.warp(s + DURATION + 30 days);
        drip.drip();
        assertEq(drip.sent(), FUND);
        assertEq(coin.balanceOf(address(dist)), FUND);
        assertEq(coin.balanceOf(address(drip)), 1_000_000e18);
        assertEq(drip.releasable(), 0);
        assertEq(drip.drip(), 0);
        // Only stop() sends the extra.
        vm.prank(roy);
        assertEq(drip.stop(royCold), 1_000_000e18);
        assertEq(coin.balanceOf(royCold), 1_000_000e18);
    }

    // ------------------------------------------------------------------ a paused distributor

    /// While the distributor's guardian (or its owner) has it paused, nothing goes in: drip() by anyone sends nothing
    /// and sent stays. The schedule keeps running, and after the unpause one drip sends exactly what accrued.
    function test_a_paused_distributor_gets_nothing_until_unpaused() public {
        fund(FUND);
        uint256 s = T0 + 1 hours;
        startAt(s);
        vm.warp(s + 3 days);
        uint256 before = drip.drip();
        assertGt(before, 0);
        vm.prank(guardian);
        dist.setPaused(true);
        assertEq(drip.releasable(), 0, "nothing releasable while paused");
        vm.warp(s + 10 days);
        assertEq(drip.releasable(), 0);
        assertGt(drip.scheduled(s + 10 days), before, "the schedule keeps running");
        uint256 distHeld = coin.balanceOf(address(dist));
        vm.recordLogs();
        vm.prank(eve);
        assertEq(drip.drip(), 0);
        assertEq(vm.getRecordedLogs().length, 0, "no transfer, no Dripped");
        vm.prank(keeper);
        assertEq(drip.drip(), 0);
        assertEq(drip.sent(), before, "sent unchanged");
        assertEq(coin.balanceOf(address(dist)), distHeld);
        assertEq(coin.balanceOf(address(drip)), FUND - before, "what accrued stays where stop() reaches it");
        // The distributor's owner can unpause too; then one drip sends exactly what accrued.
        vm.warp(s + 12 days + 5 hours);
        vm.prank(safe);
        dist.setPaused(false);
        uint256 due = drip.scheduled(s + 12 days + 5 hours) - before;
        assertEq(drip.releasable(), due);
        vm.expectEmit(address(drip));
        emit BorroDrip.Dripped(due, before + due);
        vm.prank(eve);
        assertEq(drip.drip(), due);
        assertEq(drip.sent(), drip.scheduled(s + 12 days + 5 hours));
        assertEq(coin.balanceOf(address(dist)), drip.sent());
        assertEq(drip.releasable(), 0);
    }

    function test_stop_while_paused_returns_everything_not_let_out() public {
        fund(FUND);
        uint256 s = T0 + 1 hours;
        startAt(s);
        vm.warp(s + 5 days);
        drip.drip();
        uint256 sent = drip.sent();
        vm.prank(guardian);
        dist.setPaused(true);
        vm.warp(s + 40 days); // 35 days accrue while paused
        vm.prank(roy);
        assertEq(drip.stop(royCold), FUND - sent, "the accrued days come back too");
        assertEq(coin.balanceOf(royCold), FUND - sent);
        assertEq(coin.balanceOf(address(dist)), sent);
        assertEq(drip.sent(), sent);
        vm.prank(guardian);
        dist.setPaused(false);
        assertEq(drip.releasable(), 0);
        vm.expectRevert(BorroDrip.IsStopped.selector);
        drip.drip();
    }

    function test_paused_before_start_changes_nothing() public {
        fund(FUND);
        vm.prank(guardian);
        dist.setPaused(true);
        startAt(T0 + 1 hours); // start does not depend on the distributor
        assertEq(drip.total(), FUND);
        vm.warp(T0 + 1 hours + 2 days);
        assertEq(drip.drip(), 0);
        vm.prank(guardian);
        dist.setPaused(false);
        assertEq(drip.drip(), drip.scheduled(T0 + 1 hours + 2 days));
    }

    /// Pauses and unpauses at random times between drips by anyone: while paused every drip sends nothing; while not,
    /// sent is exactly on the schedule after a drip; at the end, unpaused, sent is exactly the total.
    function testFuzz_pauses_hold_back_and_unpauses_catch_up(uint256 seed, uint256 n) public {
        n = bound(n, 1, 40);
        fund(FUND);
        uint256 s = T0 + 1 hours;
        startAt(s);
        uint256 t = s;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            t += bound(r, 0, 40 days);
            vm.warp(t);
            if ((r >> 128) % 3 == 0) {
                bool on = !dist.paused();
                vm.prank(on ? guardian : safe);
                dist.setPaused(on);
            }
            uint256 before = drip.sent();
            vm.prank(address(uint160(r)));
            uint256 got = drip.drip();
            if (dist.paused()) {
                assertEq(got, 0, "a paused distributor gets nothing");
                assertEq(drip.sent(), before);
            } else {
                assertEq(drip.sent(), drip.scheduled(t), "unpaused: exactly on schedule");
            }
            assertEq(coin.balanceOf(address(dist)), drip.sent());
        }
        if (dist.paused()) {
            vm.prank(guardian);
            dist.setPaused(false);
        }
        vm.warp((t > s + DURATION ? t : s + DURATION) + 1);
        drip.drip();
        assertEq(drip.sent(), FUND);
        assertEq(coin.balanceOf(address(drip)), 0);
    }

    // ------------------------------------------------------------------ stop()

    function testFuzz_only_the_owner_can_stop(address who, address to) public {
        vm.assume(who != roy);
        vm.assume(to != address(0));
        fund(FUND);
        startAt(T0 + 1);
        vm.warp(T0 + 5 days);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        drip.stop(to);
        assertEq(drip.stoppedAt(), 0);
        assertEq(coin.balanceOf(address(drip)), FUND);
    }

    function test_stop_takes_back_everything_not_let_out() public {
        fund(FUND);
        uint256 s = T0 + 2 hours;
        startAt(s);
        vm.warp(s + 100 days + 7 hours);
        drip.drip();
        uint256 sent = drip.sent();
        // Three more hours were due and not dripped: they come back too.
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        uint256 stopTime = vm.getBlockTimestamp();
        vm.expectEmit(address(drip));
        emit BorroDrip.Stopped(royCold, FUND - sent, stopTime);
        vm.prank(roy);
        assertEq(drip.stop(royCold), FUND - sent);
        assertEq(coin.balanceOf(royCold), FUND - sent);
        assertEq(coin.balanceOf(address(drip)), 0);
        assertEq(coin.balanceOf(address(dist)), sent);
        assertEq(drip.stoppedAt(), stopTime);
        assertEq(drip.sent(), sent);
        assertEq(drip.releasable(), 0);
        vm.expectRevert(BorroDrip.IsStopped.selector);
        drip.drip();
        // Later: still stopped. The schedule reads on, nothing goes.
        vm.warp(s + 1000 days);
        assertEq(drip.releasable(), 0);
        vm.expectRevert(BorroDrip.IsStopped.selector);
        drip.drip();
        assertEq(drip.scheduled(vm.getBlockTimestamp()), FUND);
        // Tokens sent after the stop: a second stop sweeps them; stoppedAt stays the first.
        fund(123e18);
        address royVault = makeAddr("royVault");
        vm.expectEmit(address(drip));
        emit BorroDrip.Stopped(royVault, 123e18, stopTime);
        vm.prank(roy);
        assertEq(drip.stop(royVault), 123e18);
        assertEq(coin.balanceOf(royVault), 123e18);
        assertEq(drip.stoppedAt(), stopTime);
        // With nothing held it sends nothing and still succeeds.
        vm.prank(roy);
        assertEq(drip.stop(royCold), 0);
        assertEq(drip.sent(), sent);
    }

    function test_stop_to_zero_is_refused() public {
        fund(FUND);
        vm.prank(roy);
        vm.expectRevert(BorroDrip.ZeroAddress.selector);
        drip.stop(address(0));
        assertEq(drip.stoppedAt(), 0);
        startAt(T0 + 1);
        vm.prank(roy);
        drip.stop(royCold);
        fund(1e18);
        vm.prank(roy);
        vm.expectRevert(BorroDrip.ZeroAddress.selector);
        drip.stop(address(0));
        assertEq(coin.balanceOf(address(drip)), 1e18);
    }

    function test_after_the_end_stop_returns_only_strays() public {
        fund(FUND);
        startAt(T0 + 1);
        vm.warp(T0 + DURATION + 1);
        assertEq(drip.drip(), FUND);
        vm.prank(roy);
        assertEq(drip.stop(royCold), 0);
    }

    // ------------------------------------------------------------------ ownership

    function test_renounce_is_refused() public {
        vm.prank(roy);
        vm.expectRevert(BorroDrip.NoRenounce.selector);
        drip.renounceOwnership();
        vm.prank(eve);
        vm.expectRevert(BorroDrip.NoRenounce.selector);
        drip.renounceOwnership();
        assertEq(drip.owner(), roy);
    }

    function test_ownership_moves_in_two_steps() public {
        address next = makeAddr("next");
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        drip.transferOwnership(eve);
        vm.prank(roy);
        drip.transferOwnership(next);
        assertEq(drip.owner(), roy);
        assertEq(drip.pendingOwner(), next);
        // Named but not yet the owner: it cannot start or stop.
        fund(FUND);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        drip.start();
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        drip.stop(next);
        // Only the one named can accept.
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        drip.acceptOwnership();
        vm.prank(next);
        drip.acceptOwnership();
        assertEq(drip.owner(), next);
        assertEq(drip.pendingOwner(), address(0));
        // Roy no longer can; the new owner can.
        vm.prank(roy);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, roy));
        drip.start();
        vm.prank(next);
        drip.start();
        vm.prank(roy);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, roy));
        drip.stop(roy);
        vm.prank(next);
        assertEq(drip.stop(next), FUND);
    }

    function test_a_mistaken_handover_can_be_cancelled_before_it_is_accepted() public {
        vm.prank(roy);
        drip.transferOwnership(eve);
        vm.prank(roy);
        drip.transferOwnership(address(0));
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        drip.acceptOwnership();
        assertEq(drip.owner(), roy);
    }

    // ------------------------------------------------------------------ fuzz

    /// For any total and any start, the schedule never goes down and never passes the total; it is zero to the
    /// start and the total from the end.
    function testFuzz_scheduled_is_monotonic_and_bounded(uint256 total, uint256 at, uint256 t1, uint256 t2) public {
        total = bound(total, 1, type(uint128).max);
        at = bound(at, T0, T0 + 5 * 365 days);
        BorroDrip d = make(total, at);
        uint256 s = d.startedAt();
        t1 = bound(t1, 0, s + 2 * DURATION);
        t2 = bound(t2, t1, s + 2 * DURATION);
        uint256 v1 = d.scheduled(t1);
        uint256 v2 = d.scheduled(t2);
        assertLe(v1, v2, "never down");
        assertLe(v2, total, "never over the total");
        assertLe(v1, d.scheduled(t1 + 1));
        if (t1 <= s) assertEq(v1, 0);
        if (t2 >= s + DURATION) assertEq(v2, total);
        uint256 sum;
        for (uint256 i; i < 4; ++i) sum += d.periodAmount(i);
        assertEq(sum, total);
    }

    /// Drips at random times by random callers keep sent exactly on the schedule, and a drip after the end brings sent
    /// to exactly the total.
    function testFuzz_random_drip_times(uint256 seed, uint256 n, uint256 startDelay) public {
        n = bound(n, 1, 40);
        fund(FUND);
        uint256 s = T0 + bound(startDelay, 0, 30 days);
        uint256 t = T0;
        for (uint256 i; i < n; ++i) {
            t += bound(uint256(keccak256(abi.encode(seed, i))), 0, 60 days);
            vm.warp(t);
            if (drip.startedAt() == 0 && t >= s) {
                vm.prank(roy);
                drip.start();
            }
            address caller = address(uint160(uint256(keccak256(abi.encode(seed, i, "caller")))));
            uint256 before = drip.sent();
            vm.prank(caller);
            uint256 got = drip.drip();
            assertEq(drip.sent(), before + got);
            assertEq(drip.sent(), drip.scheduled(t), "exactly on schedule");
            assertLe(drip.sent(), FUND);
            assertEq(coin.balanceOf(address(dist)), drip.sent());
        }
        if (drip.startedAt() == 0) {
            vm.prank(roy);
            drip.start();
        }
        uint256 end = drip.startedAt() + DURATION;
        vm.warp((t > end ? t : end) + (seed % 1000 days));
        drip.drip();
        assertEq(drip.sent(), FUND);
        assertEq(coin.balanceOf(address(drip)), 0);
        assertEq(coin.balanceOf(address(dist)), FUND);
        assertEq(coin.paidToCount(), 1);
    }

    /// Whenever Roy stops, before or after start, with or without a drip first and strays, he gets exactly what was
    /// funded less what was sent.
    function testFuzz_stop_returns_exactly_funded_less_sent(
        uint256 funded,
        uint256 stray,
        uint256 startDelay,
        uint256 dripAt,
        uint256 stopAt,
        bool started,
        bool dripFirst
    ) public {
        funded = bound(funded, 1, 2 * FUND);
        stray = bound(stray, 0, 1_000_000e18);
        fund(funded);
        uint256 s = T0 + bound(startDelay, 0, 60 days);
        if (started) startAt(s);
        dripAt = bound(dripAt, vm.getBlockTimestamp(), s + DURATION + 30 days);
        stopAt = bound(stopAt, dripAt, dripAt + 400 days);
        vm.warp(dripAt);
        if (stray > 0) fund(stray);
        if (dripFirst) drip.drip();
        vm.warp(stopAt);
        uint256 sent = drip.sent();
        vm.prank(roy);
        uint256 back = drip.stop(royCold);
        assertEq(back, funded + stray - sent);
        assertEq(coin.balanceOf(royCold), funded + stray - sent);
        assertEq(coin.balanceOf(address(dist)), sent);
        assertEq(coin.balanceOf(address(drip)), 0);
        assertEq(drip.stoppedAt(), stopAt);
        if (!started) assertEq(sent, 0);
    }

    // ------------------------------------------------------------------ gas, for the report

    function test_gas() public {
        fund(FUND);
        vm.warp(T0 + 1 hours);
        vm.prank(roy);
        uint256 g = gasleft();
        drip.start();
        emit log_named_uint("gas start()", g - gasleft());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        g = gasleft();
        drip.drip();
        emit log_named_uint("gas drip(), the first", g - gasleft());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        g = gasleft();
        drip.drip();
        emit log_named_uint("gas drip(), a later day", g - gasleft());
        vm.warp(vm.getBlockTimestamp() + 600 days);
        g = gasleft();
        drip.drip();
        emit log_named_uint("gas drip(), in the last period", g - gasleft());
        vm.prank(roy);
        g = gasleft();
        drip.stop(royCold);
        emit log_named_uint("gas stop()", g - gasleft());
    }
}

/// The drip feeding the real BorroDistributor: owner a stand-in Safe, the keeper as updater, a guardian.
contract BorroDripDistributorTest is BorroDripBase {
    function two(address a, uint256 ca, address b, uint256 cb) internal pure returns (bytes32 r, bytes32[] memory l) {
        l = new bytes32[](2);
        l[0] = DripTree.leaf(a, ca);
        l[1] = DripTree.leaf(b, cb);
        r = DripTree.root(l);
    }

    function test_drip_claims_reclaim_and_stop_with_the_real_distributor() public {
        fund(FUND);
        uint256 s = T0 + 2 days + 5 hours + 17 minutes;
        startAt(s);
        // A day on, the keeper drips...
        vm.warp(s + 1 days);
        uint256 d1 = drip.drip();
        assertEq(d1, drip.scheduled(vm.getBlockTimestamp()));
        assertEq(coin.balanceOf(address(dist)), d1);
        // ...and promises part of it, as cumulative amounts: alice 60,000 and bob 40,000.
        (bytes32 r1, bytes32[] memory l1) = two(alice, 60_000e18, bob, 40_000e18);
        vm.prank(keeper);
        dist.proposeRoot(r1, 100_000e18);
        assertEq(dist.reclaimable(), d1 - 100_000e18, "a waiting root is already owed");
        vm.warp(vm.getBlockTimestamp() + dist.ROOT_DELAY());
        vm.prank(eve);
        assertEq(dist.claim(alice, 60_000e18, DripTree.proof(l1, 0)), 60_000e18);
        assertEq(coin.balanceOf(alice), 60_000e18);
        assertEq(coin.balanceOf(eve), 0);
        // The next day: another drip, and a bigger root waits.
        vm.warp(s + 2 days);
        uint256 d2 = drip.drip();
        (bytes32 r2, bytes32[] memory l2) = two(alice, 150_000e18, bob, 100_000e18);
        vm.prank(keeper);
        dist.proposeRoot(r2, 250_000e18);
        // Roy stops: everything not yet let out comes back at once; what was let out stays in the distributor.
        vm.prank(roy);
        uint256 back = drip.stop(royCold);
        assertEq(back, FUND - d1 - d2);
        // The Safe takes back what no root promises, never the waiting root's.
        uint256 owed = 250_000e18 - 60_000e18;
        uint256 free = dist.reclaimable();
        assertEq(free, d1 + d2 - 60_000e18 - owed);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.OverReclaimable.selector, free + 1, free));
        dist.reclaim(royCold, free + 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        dist.reclaim(keeper, 1);
        vm.prank(safe);
        dist.reclaim(royCold, free);
        assertEq(coin.balanceOf(address(dist)), owed);
        // Every promise still pays, after the stop and the reclaim: bob's from the live root now, the rest once the
        // waiting root is live.
        assertEq(dist.claim(bob, 40_000e18, DripTree.proof(l1, 1)), 40_000e18);
        vm.warp(vm.getBlockTimestamp() + dist.ROOT_DELAY());
        assertEq(dist.claim(alice, 150_000e18, DripTree.proof(l2, 0)), 90_000e18);
        assertEq(dist.claim(bob, 100_000e18, DripTree.proof(l2, 1)), 60_000e18);
        assertEq(coin.balanceOf(alice), 150_000e18);
        assertEq(coin.balanceOf(bob), 100_000e18);
        assertEq(coin.balanceOf(address(dist)), 0);
        assertEq(coin.balanceOf(royCold), back + free);
        assertEq(coin.balanceOf(royCold) + 250_000e18, FUND, "every token is with a depositor or back with Roy");
        // Nothing more can be promised: it is not held.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TotalNotHeld.selector, 250_000e18 + 1, 250_000e18));
        dist.proposeRoot(bytes32(uint256(1)), 250_000e18 + 1);
        vm.expectRevert(BorroDrip.IsStopped.selector);
        drip.drip();
        // The drip only ever paid the distributor and Roy's chosen address.
        assertEq(coin.paidToCount(), 2);
        assertEq(coin.paidFromWatched(address(dist)), d1 + d2);
        assertEq(coin.paidFromWatched(royCold), back);
    }

    /// The deploy script's limit (twice the first period's rate for 50M) lets the keeper promise everything the drip
    /// lets out, day by day, for any funding up to twice the expected total; a stolen updater key that promises
    /// faster is refused.
    function test_growth_limit_keeps_up_with_the_drip() public {
        uint256 limitPerDay = limitFor(EXPECTED) * 1 days;
        // Twice the first period's daily amount for 50M.
        assertApproxEqAbs(limitPerDay, 2 * (((EXPECTED * 8) / 15) / 182), 1e6);
        // Funded with 84.1M instead, the first period still fits; past twice the expected total it would not.
        assertGt(limitPerDay, ((uint256(84_100_000e18) * 8) / 15) / 182);
        assertLt(limitPerDay, ((uint256(100_100_000e18) * 8) / 15) / 182);

        fund(84_100_000e18);
        uint256 s = T0 + 3 hours;
        startAt(s);
        uint256 cum;
        for (uint256 day = 1; day <= 5; ++day) {
            vm.warp(s + day * 1 days);
            drip.drip();
            cum = drip.sent();
            vm.prank(keeper);
            dist.proposeRoot(DripTree.leaf(alice, cum), cum); // a one-leaf tree: the root is the leaf
        }
        // Tokens sitting in the distributor that no root promises (a stray, or a share not yet given out): a stolen
        // updater key that promises them all at once is refused; the guardian has time to step in.
        vm.prank(holder);
        coin.transfer(address(dist), 1_000_000e18);
        vm.warp(s + 6 days);
        drip.drip();
        uint256 all = drip.sent() + 1_000_000e18;
        uint256 allowed = limitFor(EXPECTED) * (1 days + dist.MARGIN()); // since the day-5 root was proposed
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TotalTooFast.selector, all - cum, allowed));
        dist.proposeRoot(DripTree.leaf(eve, all), all);
        // The honest day-6 root still goes through, and pays.
        cum = drip.sent();
        vm.prank(keeper);
        dist.proposeRoot(DripTree.leaf(alice, cum), cum);
        vm.warp(vm.getBlockTimestamp() + dist.ROOT_DELAY());
        assertEq(dist.claim(alice, cum, new bytes32[](0)), cum);
        assertEq(coin.balanceOf(eve), 0);
    }

    /// Whenever Roy stops and the Safe reclaims, every promised token still pays.
    function testFuzz_promises_survive_stop_and_reclaim(uint256 days_, uint256 pct, uint256 stopDelay, bool waiting) public {
        days_ = bound(days_, 1, 60);
        pct = bound(pct, 0, 100);
        fund(FUND);
        uint256 s = T0 + 1 hours;
        startAt(s);
        vm.warp(s + days_ * 1 days);
        drip.drip();
        uint256 promised = (drip.sent() * pct) / 100;
        vm.prank(keeper);
        dist.proposeRoot(DripTree.leaf(alice, promised), promised);
        if (!waiting) vm.warp(vm.getBlockTimestamp() + dist.ROOT_DELAY());
        vm.warp(vm.getBlockTimestamp() + bound(stopDelay, 0, 30 days));
        vm.prank(roy);
        drip.stop(royCold);
        uint256 free = dist.reclaimable();
        assertEq(free, drip.sent() - promised);
        vm.prank(safe);
        dist.reclaim(royCold, free);
        assertEq(coin.balanceOf(address(dist)), promised);
        if (waiting) vm.warp(vm.getBlockTimestamp() + dist.ROOT_DELAY());
        if (promised > 0) assertEq(dist.claim(alice, promised, new bytes32[](0)), promised);
        assertEq(coin.balanceOf(alice) + coin.balanceOf(royCold), FUND);
    }
}

/// Drives the drip with random warps, fundings and strays, the owner's start and stops to random recipients, drips by
/// anyone, and outsiders trying to start, stop or take the drip.
contract DripHandler is Test {
    BorroDrip public drip;
    WatchedCoin public coin;
    address public dist;
    address public roy;
    address public holder;
    address[] public recipients; // where the owner may send a stop
    address[] public outsiders; // call drip(), try everything else; never receive
    mapping(address => bool) public chosen; // recipients the owner actually sent a stop to
    uint256 public inflow; // every token ever sent to the drip
    uint256 public stopOut; // every token stops sent out
    uint256 public totalAtStart;
    uint256 public startTime;
    uint256 public sentAtStop;
    uint256 public firstStopAt;
    uint256 public sneaks; // outsiders' start, stop or takeover attempts that went through (must stay 0)
    uint256 public starts;
    uint256 public stops;
    uint256 public drips;
    uint256 public refusedDrips;
    uint256 public startGate; // a start goes ahead when gate % startGate == 0
    uint256 public stopGate;
    address public guardian; // the distributor's guardian: pauses and unpauses it
    uint256 public pauses;
    uint256 public pausedDrips; // drips tried while the distributor was paused (each must send nothing)

    constructor(BorroDrip d, WatchedCoin c, address roy_, address holder_, uint256 startGate_, uint256 stopGate_) {
        drip = d;
        coin = c;
        dist = d.distributor();
        roy = roy_;
        holder = holder_;
        startGate = startGate_;
        stopGate = stopGate_;
        recipients.push(roy_);
        recipients.push(makeAddr("royCold"));
        recipients.push(makeAddr("hoardSafe"));
        outsiders.push(makeAddr("eve"));
        outsiders.push(makeAddr("mallory"));
        outsiders.push(makeAddr("keeper"));
        outsiders.push(makeAddr("guardian"));
        outsiders.push(holder_);
        outsiders.push(dist);
        guardian = makeAddr("guardian");
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    /// The drip's state before any handler call (set up by the test) counts as funded.
    function noteFunded(uint256 amount, uint256 total, uint256 startedAt) external {
        inflow += amount;
        totalAtStart = total;
        startTime = startedAt;
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 30 days));
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 0, 10_000_000e18); // 64 calls of this stay within the holder's 1B
        vm.prank(holder);
        coin.transfer(address(drip), amount);
        inflow += amount;
    }

    function start(uint256 gate) external {
        if (uint256(keccak256(abi.encode(gate))) % startGate != 0) return; // hashed: fuzzers favour 0
        uint256 held = coin.balanceOf(address(drip));
        bool may = drip.startedAt() == 0 && drip.stoppedAt() == 0 && held > 0;
        vm.prank(roy);
        try drip.start() returns (uint256 total) {
            assertTrue(may, "a start went through that should not");
            assertEq(total, held, "total is the balance at start");
            assertEq(drip.total(), held);
            assertEq(drip.startedAt(), vm.getBlockTimestamp());
            totalAtStart = held;
            startTime = vm.getBlockTimestamp();
            starts++;
        } catch (bytes memory err) {
            assertFalse(may, "the owner's start failed");
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == BorroDrip.AlreadyStarted.selector || sel == BorroDrip.IsStopped.selector
                    || sel == BorroDrip.NothingHeld.selector,
                "start refused for another reason"
            );
        }
    }

    function dripAny(uint256 who) external {
        address caller = outsiders[who % outsiders.length];
        uint256 sentBefore = drip.sent();
        uint256 distBefore = coin.balanceOf(dist);
        uint256 expected = drip.releasable();
        bool stopped = drip.stoppedAt() != 0;
        bool paused = BorroDistributor(dist).paused();
        if (paused) {
            assertEq(expected, 0, "nothing releasable while the distributor is paused");
        } else if (!stopped && drip.startedAt() != 0) {
            assertEq(expected, drip.scheduled(vm.getBlockTimestamp()) - sentBefore, "what is due is always held");
        }
        vm.prank(caller);
        try drip.drip() returns (uint256 got) {
            assertFalse(stopped, "a drip after stop went through");
            assertEq(got, expected, "drip sends exactly releasable");
            assertEq(drip.sent(), sentBefore + got);
            assertEq(coin.balanceOf(dist), distBefore + got);
            if (paused) {
                assertEq(got, 0, "a paused distributor got tokens");
                pausedDrips++;
            }
            drips++;
        } catch (bytes memory err) {
            assertTrue(stopped, "a drip failed while running");
            assertEq(bytes4(err), BorroDrip.IsStopped.selector);
            refusedDrips++;
        }
    }

    /// The guardian pauses the distributor (about a third of the calls) or unpauses it.
    function pause(uint256 seed) external {
        bool on = uint256(keccak256(abi.encode(seed))) % 3 == 0;
        vm.prank(guardian);
        BorroDistributor(dist).setPaused(on);
        if (on) pauses++;
    }

    function stopOwner(uint256 to, uint256 gate) external {
        // Rare, so most runs spend time running as well (hashed: fuzzers favour 0).
        if (uint256(keccak256(abi.encode(gate))) % stopGate != 0) return;
        address r = recipients[to % recipients.length];
        uint256 held = coin.balanceOf(address(drip));
        uint256 before = coin.balanceOf(r);
        bool first = drip.stoppedAt() == 0;
        vm.prank(roy);
        uint256 got = drip.stop(r);
        assertEq(got, held, "stop sends the whole balance");
        assertEq(coin.balanceOf(r), before + got);
        assertEq(coin.balanceOf(address(drip)), 0);
        chosen[r] = true;
        stopOut += got;
        if (first) {
            sentAtStop = drip.sent();
            firstStopAt = vm.getBlockTimestamp();
        }
        stops++;
    }

    function sneak(uint256 who, uint256 what, uint256 to) external {
        address caller = outsiders[who % outsiders.length];
        address target = to % 2 == 0 ? caller : recipients[to % recipients.length];
        uint256 w = what % 5;
        vm.startPrank(caller);
        if (w == 0) {
            try drip.stop(target) {
                sneaks++;
            } catch {}
        } else if (w == 1) {
            try drip.start() {
                sneaks++;
            } catch {}
        } else if (w == 2) {
            try drip.transferOwnership(caller) {
                sneaks++;
            } catch {}
        } else if (w == 3) {
            try drip.acceptOwnership() {
                sneaks++;
            } catch {}
        } else {
            try drip.renounceOwnership() {
                sneaks++;
            } catch {}
        }
        vm.stopPrank();
    }
}

contract BorroDripInvariantTest is StdInvariant, BorroDripBase {
    DripHandler handler;

    function setUp() public virtual override {
        super.setUp();
        handler = new DripHandler(drip, coin, roy, holder, 3, 64);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = DripHandler.warp.selector;
        sel[1] = DripHandler.fund.selector;
        sel[2] = DripHandler.start.selector;
        sel[3] = DripHandler.dripAny.selector;
        sel[4] = DripHandler.stopOwner.selector;
        sel[5] = DripHandler.sneak.selector;
        sel[6] = DripHandler.pause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_sent_never_ahead_of_the_schedule() public view {
        assertLe(drip.sent(), drip.scheduled(vm.getBlockTimestamp()));
        assertLe(drip.sent(), drip.total());
        if (drip.startedAt() == 0) assertEq(drip.sent(), 0);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_every_token_is_accounted_for() public view {
        assertEq(coin.balanceOf(address(drip)) + drip.sent() + handler.stopOut(), handler.inflow());
        assertEq(coin.balanceOf(address(dist)), drip.sent());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_the_schedule_is_fixed_at_start() public view {
        assertEq(drip.total(), handler.totalAtStart());
        assertEq(drip.startedAt(), handler.startTime());
        if (drip.startedAt() == 0) assertEq(drip.total(), 0);
        else assertGt(drip.total(), 0);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_once_stopped_nothing_more_is_let_out() public view {
        if (drip.stoppedAt() != 0) {
            assertEq(drip.sent(), handler.sentAtStop());
            assertEq(drip.stoppedAt(), handler.firstStopAt());
            assertEq(drip.releasable(), 0);
        } else {
            assertEq(handler.stops(), 0);
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_only_the_distributor_and_the_owners_recipients_receive() public view {
        uint256 n = coin.paidToCount();
        for (uint256 i; i < n; ++i) {
            address a = coin.paidTo(i);
            assertTrue(a == address(dist) || handler.chosen(a), "someone else received from the drip");
        }
        assertEq(coin.paidFromWatched(address(dist)), drip.sent());
        uint256 toRecipients;
        for (uint256 i; i < handler.recipientCount(); ++i) toRecipients += coin.paidFromWatched(handler.recipients(i));
        assertEq(toRecipients, handler.stopOut());
        assertEq(coin.paidOutTotal(), drip.sent() + handler.stopOut());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_no_one_else_controls_it() public view {
        assertEq(handler.sneaks(), 0);
        assertEq(drip.owner(), roy);
        assertEq(drip.pendingOwner(), address(0));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_a_paused_distributor_gets_nothing() public view {
        if (dist.paused()) assertEq(drip.releasable(), 0);
    }

    function afterInvariant() external {
        // Whatever happened, once unpaused the end of the schedule lets out exactly the total, and a stop returns all
        // the rest.
        if (dist.paused()) {
            vm.prank(guardian);
            dist.setPaused(false);
        }
        if (drip.stoppedAt() == 0 && drip.startedAt() != 0) {
            vm.warp(drip.startedAt() + DURATION);
            drip.drip();
            assertEq(drip.sent(), drip.total());
        }
        uint256 held = coin.balanceOf(address(drip));
        vm.prank(roy);
        assertEq(drip.stop(royCold), held);
        assertEq(coin.balanceOf(address(drip)), 0);
    }
}

/// The same, from a drip Roy funded with 50M and started before the first call, so every run is spent running.
contract BorroDripStartedInvariantTest is BorroDripInvariantTest {
    function setUp() public override {
        super.setUp();
        fund(FUND);
        vm.warp(T0 + 4 hours + 1);
        vm.prank(roy);
        drip.start();
        handler.noteFunded(FUND, FUND, T0 + 4 hours + 1);
    }
}
