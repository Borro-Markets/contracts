// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CallsCalendar} from "../../src/calls/CallsCalendar.sol";
import {MarketHours} from "../../src/eth/MarketHours.sol";

contract CalendarHarness {
    function expiryOf(uint256 t) external pure returns (uint256) {
        return CallsCalendar.expiryOf(t);
    }

    function fresh(uint256 u, uint256 t) external pure returns (bool) {
        return CallsCalendar.fresh(u, t, 25 hours);
    }

    function secondsIntoDate(uint256 t) external pure returns (uint256) {
        return CallsCalendar.secondsIntoDate(t);
    }
}

/// When rounds expire and when a feed price counts as current, against the calendar written by hand (UTC times worked
/// out from New York's: EDT is UTC-4 until 2026-11-01, EST UTC-5 after).
contract CallsCalendarTest is Test {
    CalendarHarness h = new CalendarHarness();
    uint256 constant DAY = 1 days;
    uint256 constant MON_OCT12 = 1791763200; // Monday 2026-10-12 00:00 UTC

    function test_a_summer_week_expires_friday_20_00_new_york() public view {
        uint256 sat = MON_OCT12 + 5 * DAY; // Saturday 00:00 UTC = Friday 20:00 EDT
        assertEq(h.expiryOf(MON_OCT12 + 14 hours), sat, "monday");
        assertEq(h.expiryOf(MON_OCT12 + 2 * DAY + 3 hours), sat, "wednesday night");
        assertEq(h.expiryOf(sat - 1), sat, "the last second of friday");
        // Sunday 20:00 EDT is already Monday's trading date.
        assertEq(h.expiryOf(MON_OCT12), sat, "sunday 20:00 new york");
    }

    function test_a_winter_week_expires_an_hour_later_in_utc() public view {
        uint256 mon = MON_OCT12 + 28 * DAY; // Monday 2026-11-09, after daylight saving ended on 11-01
        assertEq(h.expiryOf(mon + 15 hours), mon + 5 * DAY + 1 hours, "friday 20:00 EST = saturday 01:00 UTC");
    }

    function test_christmas_friday_moves_expiry_to_thursday() public view {
        uint256 mon = 1797811200; // Monday 2026-12-21 00:00 UTC
        assertEq(h.expiryOf(mon + 15 hours), mon + 4 * DAY + 1 hours, "thursday 20:00 EST");
    }

    function test_good_friday_2027_moves_expiry_to_thursday() public view {
        uint256 mon = 1805673600; // Monday 2027-03-22 00:00 UTC (daylight saving from 03-14)
        assertEq(h.expiryOf(mon + 14 hours), mon + 4 * DAY, "thursday 20:00 EDT");
    }

    function test_thanksgiving_thursday_keeps_a_friday_expiry() public view {
        uint256 mon = 1795392000; // Monday 2026-11-23 00:00 UTC
        assertEq(h.expiryOf(mon + 15 hours), mon + 5 * DAY + 1 hours, "friday 20:00 EST");
    }

    function test_no_expiry_while_the_market_is_shut() public {
        vm.expectRevert(CallsCalendar.MarketShut.selector);
        h.expiryOf(MON_OCT12 - 12 hours); // Sunday noon UTC
        vm.expectRevert(CallsCalendar.MarketShut.selector);
        h.expiryOf(1797811200 + 4 * DAY + 10 hours); // Christmas Day
    }

    function test_the_regular_open_is_13_5_hours_into_the_date() public view {
        assertEq(h.secondsIntoDate(MON_OCT12 + 13.5 hours), 13.5 hours, "09:30 EDT");
        assertEq(h.secondsIntoDate(MON_OCT12 + 28 * DAY + 14.5 hours), 13.5 hours, "09:30 EST");
        assertEq(h.secondsIntoDate(MON_OCT12), 0, "20:00 the evening before");
    }

    function test_fresh_follows_the_market_not_just_the_clock() public view {
        uint256 fri = MON_OCT12 - 3 * DAY; // Friday 2026-10-09 00:00 UTC
        // A Friday afternoon price is still the price at the close, but never on Monday, however small the move it missed.
        assertTrue(h.fresh(fri + 17 hours, fri + DAY - 1), "friday 13:00 at the close");
        assertFalse(h.fresh(fri + 23 hours, MON_OCT12 + 10 minutes), "friday's price after the weekend");
        // Monday night's price is current on Tuesday morning: no closed date in between, within 25 hours.
        assertTrue(h.fresh(MON_OCT12 + 17 hours, MON_OCT12 + DAY + 14 hours), "monday 13:00 at tuesday 10:00");
        assertFalse(h.fresh(MON_OCT12 + 10 hours, MON_OCT12 + DAY + 12 hours), "26 hours old");
        assertFalse(h.fresh(0, MON_OCT12), "never posted");
        assertFalse(h.fresh(MON_OCT12 + 2 hours, MON_OCT12 + 1 hours), "from the future");
        // Thanksgiving: Wednesday 19:30 New York's price is not current at Thursday 20:10 (Friday's trading date), though
        // only 24 hours 40 minutes have passed: the market was shut in between.
        uint256 mon = 1795392000;
        assertFalse(h.fresh(mon + 3 * DAY + 30 minutes, mon + 4 * DAY + 70 minutes), "across the holiday");
        assertTrue(h.fresh(mon + 2 * DAY + 30 minutes, mon + 3 * DAY + 10 minutes), "tuesday night to wednesday night");
    }

    /// Any time the market is open, the expiry is after it, within the week, at 20:00 New York, the market is open just
    /// before it and shut at it.
    function testFuzz_expiry_is_the_close_of_the_week(uint256 t) public view {
        t = bound(t, MON_OCT12 - 280 days, MON_OCT12 + 800 days);
        vm.assume(MarketHours.isOpen(t));
        uint256 x = h.expiryOf(t);
        assertGt(x, t, "after");
        assertLe(x - t, 5 days + 1 hours, "within the week");
        assertTrue(MarketHours.isOpen(x - 1), "open just before");
        assertFalse(MarketHours.isOpen(x), "shut at it");
        assertEq(h.secondsIntoDate(x), 0, "at 20:00 new york");
    }
}
