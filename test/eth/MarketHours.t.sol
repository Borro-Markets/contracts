// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MarketHours} from "../../src/eth/MarketHours.sol";
import {MarketHoursCases} from "./MarketHoursCases.sol";

contract MarketHoursHarness {
    function isOpen(uint256 t) external pure returns (bool) {
        return MarketHours.isOpen(t);
    }
}

/// MarketHours against an independent reference: Python's time zone database and the exchange calendar.
contract MarketHoursTest is Test {
    MarketHoursHarness h = new MarketHoursHarness();

    /// Every generated moment from 2026 to March 2029 agrees with the reference.
    function test_matchesReference() public view {
        bytes memory c = MarketHoursCases.CASES;
        assertEq(c.length, MarketHoursCases.COUNT * 5);
        uint256 opens;
        for (uint256 i; i < c.length; i += 5) {
            uint256 t = (uint256(uint8(c[i])) << 24) | (uint256(uint8(c[i + 1])) << 16) | (uint256(uint8(c[i + 2])) << 8)
                | uint256(uint8(c[i + 3]));
            bool want = c[i + 4] != 0;
            if (want) opens++;
            if (MarketHours.isOpen(t) != want) revert(string.concat("disagrees at ", vm.toString(t)));
        }
        assertGt(opens, 0);
    }

    // A few hand-checked moments, in UTC.

    /// Friday 2026-10-09: open at 19:59:59 New York (23:59:59 UTC), shut at 20:00.
    function test_fridayClose() public view {
        assertTrue(h.isOpen(1791590399)); // 2026-10-09 23:59:59 UTC
        assertFalse(h.isOpen(1791590400)); // 2026-10-10 00:00:00 UTC
    }

    /// Sunday 2026-10-04 20:00 New York (2026-10-05 00:00 UTC): the stock feeds all posted between 00:00:20 and 00:00:51.
    function test_sundayOpen() public view {
        assertFalse(h.isOpen(1791158399)); // 2026-10-04 23:59:59 UTC
        assertTrue(h.isOpen(1791158400)); // 2026-10-05 00:00:00 UTC
    }

    /// After daylight saving ends (2026-11-01), New York is UTC-5: Friday 2026-11-06 closes at 01:00 UTC Saturday.
    function test_winterHours() public view {
        assertTrue(h.isOpen(1794013199)); // 2026-11-07 00:59:59 UTC = Friday 19:59:59 EST
        assertFalse(h.isOpen(1794013200)); // 2026-11-07 01:00:00 UTC = Friday 20:00 EST
    }

    /// Thanksgiving 2026-11-26 (a Thursday): shut from Wednesday 20:00 to Thursday 20:00 New York (EST).
    function test_thanksgiving() public view {
        assertTrue(h.isOpen(1795654799)); // 2026-11-26 00:59:59 UTC = Wed 19:59:59 EST
        assertFalse(h.isOpen(1795654800)); // 2026-11-26 01:00:00 UTC = Wed 20:00 EST
        assertFalse(h.isOpen(1795741199)); // 2026-11-27 00:59:59 UTC = Thu 19:59:59 EST
        assertTrue(h.isOpen(1795741200)); // 2026-11-27 01:00:00 UTC = Thu 20:00 EST (Friday's session)
    }

    /// After 2028 no holiday is known: Monday 2029-01-01 (a real holiday) reads as open.
    function test_noHolidaysAfter2028() public view {
        assertTrue(h.isOpen(1861981200)); // 2029-01-01 12:00 EST
    }

    /// Any moment in a Saturday's or Sunday's trading date is shut, and every holiday on the list is shut at noon.
    function testFuzz_weekendsShut(uint256 t) public view {
        t = bound(t, 1767225600, 1893456000); // 2026 to 2029
        uint256 desk = MarketHours.isDaylightSaving(t) ? t : t - 1 hours;
        uint256 weekday = (desk / 1 days + 4) % 7;
        if (weekday == 0 || weekday == 6) assertFalse(h.isOpen(t));
    }

    function test_everyHolidayShutAtNoon() public view {
        bytes memory list = MarketHours.HOLIDAYS;
        assertEq(list.length, 58);
        uint256 last;
        for (uint256 i; i < list.length; i += 2) {
            uint256 d = (uint256(uint8(list[i])) << 8) | uint256(uint8(list[i + 1]));
            assertGt(d, last, "in order");
            last = d;
            assertFalse(h.isOpen(d * 1 days + 17 hours), "noon New York"); // 12:00 EST or 13:00 EDT, both shut
            assertTrue(MarketHours.isHoliday(d));
            assertFalse(MarketHours.isHoliday(d + 1) && d + 1 != _next(list, i));
        }
    }

    // The week close: Friday 20:00 New York, the Options desk's expiry.

    function test_weekClose_in_both_regimes_and_on_a_holiday() public pure {
        assertTrue(MarketHours.isWeekClose(1791590400)); // Friday 2026-10-09 20:00 EDT = 2026-10-10 00:00 UTC
        assertFalse(MarketHours.isWeekClose(1791590399));
        assertFalse(MarketHours.isWeekClose(1791590401));
        assertFalse(MarketHours.isWeekClose(1791590400 + 1 hours)); // 21:00 EDT
        assertFalse(MarketHours.isWeekClose(1791590400 - 1 days)); // Thursday 20:00
        assertFalse(MarketHours.isWeekClose(1791158400)); // Sunday 20:00 EDT, the open
        assertTrue(MarketHours.isWeekClose(1794013200)); // Friday 2026-11-06 20:00 EST = 2026-11-07 01:00 UTC
        assertFalse(MarketHours.isWeekClose(1794013200 - 1 hours)); // 00:00 UTC is 19:00 EST
        assertTrue(MarketHours.isWeekClose(1798246800)); // Christmas 2026, a Friday and a holiday: still the close
        assertTrue(MarketHours.isHoliday(MarketHours.tradingDate(1798246800 - 1)));
        assertTrue(MarketHours.isWeekClose(1805500800)); // Friday 2027-03-19 20:00 EDT, after the March switch
        assertTrue(MarketHours.isWeekClose(1804899600)); // Friday 2027-03-12 20:00 EST, before it
    }

    function test_weekCloseAfter_is_the_next_friday_close() public pure {
        assertEq(MarketHours.weekCloseAfter(1791568800), 1791590400); // Friday afternoon to that evening
        assertEq(MarketHours.weekCloseAfter(1791590399), 1791590400);
        assertEq(MarketHours.weekCloseAfter(1791590400), 1792195200, "a close's next is a week on");
        assertEq(MarketHours.weekCloseAfter(1791644400), 1792195200); // Saturday afternoon
        assertEq(MarketHours.weekCloseAfter(1791158400), 1791590400); // Sunday evening open
        assertEq(MarketHours.weekCloseAfter(1793408400), 1794013200, "late October into the first winter Friday");
        assertEq(MarketHours.weekCloseAfter(1804899600), 1805500800, "across the March 2027 switch");
    }

    /// From any moment: the next close is after it, within a week, is a close, and the close a week before it is
    /// not after the moment (so it is the first).
    function testFuzz_weekCloseAfter_is_the_first_close_after(uint256 t) public pure {
        t = bound(t, 1767225600, 1893456000); // 2026 to 2029
        uint256 c = MarketHours.weekCloseAfter(t);
        assertGt(c, t);
        assertLe(c - t, 7 days + 1 hours);
        assertTrue(MarketHours.isWeekClose(c));
        uint256 prev = c - 7 days;
        if (!MarketHours.isWeekClose(prev)) prev = MarketHours.isWeekClose(prev - 1 hours) ? prev - 1 hours : prev + 1 hours;
        assertTrue(MarketHours.isWeekClose(prev), "the close a week before is a close too");
        assertLe(prev, t, "and not after t");
        assertFalse(MarketHours.isOpen(c), "the close is shut");
        assertTrue(MarketHours.isOpen(c - 1) || MarketHours.isHoliday(MarketHours.tradingDate(c - 1)), "the moment before is open, or a holiday");
    }

    function _next(bytes memory list, uint256 i) internal pure returns (uint256) {
        if (i + 2 >= list.length) return 0;
        return (uint256(uint8(list[i + 2])) << 8) | uint256(uint8(list[i + 3]));
    }
}
