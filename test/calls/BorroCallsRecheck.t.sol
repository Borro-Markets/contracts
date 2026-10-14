// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {CallsCalendar} from "../../src/calls/CallsCalendar.sol";
import {CallsBase} from "./CallsBase.sol";

/// The independent reviewer's re-check of the review fixes (2026-10-09), docs/COVERED-CALLS.md "Review". Its proofs of
/// concept for R-1, R-2 and I-1 are kept as regression tests after their fixes; H-1 and H-2 check that earlier fixes hold.
contract BorroCallsRecheckTest is CallsBase {
    /// R-1 (fixed). Chainlink moves the proxy to a new aggregator on Wednesday and the old one stops posting. The round
    /// settles in the newest phase begun before expiry: the proxy's own answer at expiry (Friday 19:00, 260, over the
    /// 241.50 strike), not a call-off on the old phase's stale price.
    function test_recheck_R1_a_mid_week_feed_upgrade_settles_on_the_new_phase() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 tue = _postAt(240e8, MON + 1 days + 16 hours); // Tuesday 12:00 New York: phase 1's last post
        vm.warp(MON + 2 days + 14 hours); // Wednesday 10:00
        feed.newPhase();
        feed.post(250e8);
        uint80 fri = _postAt(260e8, EXPIRY - 1 hours);
        vm.warp(EXPIRY + 1);
        assertEq(calls.settlementPhase(1), 2);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(tue); // the old phase no longer answers for this round
        vm.warp(EXPIRY + 7 days + 1);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.voidRound(tue); // and cannot call it off
        calls.settle(fri);
        assertEq(_round(1).settlePrice, 260e8);
        assertGt(_round(1).owedShares, 0);
    }

    /// R-2 (fixed). A round first startable late in the day no longer sells overnight: started Monday 19:00 New York it is
    /// refused (under an hour of the regular session left); the next morning it starts, and a start at 10:30 has its sale
    /// cut at 16:00 New York, on the same price schedule (it never reaches its floor).
    function test_recheck_R2_a_late_start_never_sells_overnight() public {
        vm.warp(MON + 23 hours); // Monday 19:00 New York: the first deposit arrives
        _deposit(alice, 100e18);
        feed.post(P0);
        vm.expectRevert(BorroCalls.TooLate.selector);
        calls.startRound();
        vm.warp(MON + 1 days + 14.5 hours); // Tuesday 10:30
        feed.post(P0);
        calls.startRound();
        BorroCalls.Round memory r = _round(1);
        assertEq(r.auctionEnd, MON + 1 days + 20 hours, "the sale ends at 16:00 New York");
        assertEq(CallsCalendar.secondsIntoDate(r.auctionEnd), calls.SALE_CLOSE());
        vm.warp(r.auctionEnd - 1);
        feed.post(P0);
        (, uint256 c) = calls.quote(10e18);
        // 5.5 of the 6 hours of the schedule: 120 - 107 x 5.5 / 6 = 21.9 bps, over the 13 bps floor
        assertGt(c, 10 * 230 * 1e6 * 21 / 10_000);
    }

    /// I-1 (fixed). quote() applies the $1 minimum as buy() does: a single call near the floor is refused by both.
    function test_recheck_I1_quote_refuses_what_buy_refuses() public {
        _deposit(alice, 100e18);
        _start();
        vm.warp(OPEN + 6 hours - 60);
        vm.expectRevert();
        calls.quote(1e18);
        (, uint256 q) = calls.quote(10e18);
        assertGe(q, calls.MIN_COST());
    }

    /// H-1. Pausing mid-sale after some sales: the sale ends there, what sold stays written and settles at expiry with
    /// its payout, unpausing does not reopen it, the week's round cannot be restarted, and next week starts normally.
    function test_recheck_H1_a_pause_mid_sale_after_sales_ends_cleanly() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        vm.warp(OPEN + 1 hours);
        vm.prank(safe);
        calls.setPaused(true);
        assertEq(_round(1).auctionEnd, OPEN + 1 hours);
        vm.prank(safe);
        calls.setPaused(false);
        usdg.mint(buyer2, 1_000e6);
        vm.startPrank(buyer2);
        usdg.approve(address(calls), 1_000e6);
        vm.expectRevert(BorroCalls.SaleOver.selector);
        calls.buy(1e18, 1_000e6, buyer2);
        vm.stopPrank();
        vm.warp(OPEN + 1 days);
        feed.post(P0);
        vm.expectRevert(BorroCalls.RoundLive.selector);
        calls.startRound();
        _expireAt(253e8);
        assertGt(_round(1).owedShares, 0, "the payout on what sold");
        vm.warp(OPEN + 7 days);
        feed.post(P0);
        assertEq(calls.startRound(), 2, "next week starts");
    }

    /// H-2. MIN_COST and partial fills: an order for more than is left takes the rest at any cost (under a dollar here),
    /// so the last options always sell; and a dollar's worth is the least anyone can buy otherwise.
    function test_recheck_H2_the_last_options_sell_at_any_cost() public {
        _deposit(alice, 1e18);
        _start();
        _buy(buyer, 0.9e18); // $2.48
        vm.warp(OPEN + 6 hours - 60);
        (uint256 f, uint256 c) = _buy(buyer2, 5e18); // asks for 5, 0.1 left
        assertEq(f, 0.1e18);
        assertLt(c, calls.MIN_COST());
        assertEq(_round(1).sold, _round(1).capacity);
    }
}
