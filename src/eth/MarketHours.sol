// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title MarketHours
/// @notice Whether the "24/5" US stock market behind Robinhood's stock tokens and Chainlink's stock feeds is open:
///         Sunday 20:00 to Friday 20:00 New York time, less the New York Stock Exchange's full-day holidays.
/// @dev The week and US daylight saving are computed, with the same math as the Stock-hours kit's MarketClock
///      (~/stock-hours-kit, MIT, replayed there against Python's time zone database). There is no owner and no
///      calendar upkeep: the exchange's published 2026 to 2028 holidays are written in below. After 2028 no holiday
///      is known, so a holiday reads as open; the oracle's feed age rule is then the only thing that notices it.
///      Early closes are ignored: on those days the market shuts at 17:00 and the evening session opens at 20:00,
///      and those three hours read as open.
///
///      Time is kept in "desk time": New York time moved forward four hours, so that a trading date runs from 20:00
///      New York on the evening before to 20:00 New York on the date itself. A trading date that falls on a Saturday,
///      a Sunday or a holiday is closed from end to end.
library MarketHours {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant MAX_CLOSED = 10; // the most trading dates nextOpen steps over (a weekend and a holiday is three)

    error NoOpenFound();

    /// @dev New York Stock Exchange full-day closures 2026 to 2028 (nyse.com, read 2026-10-03; the same list as
    ///      ~/stock-hours-kit/contracts/data/nyse-calendar.json), as days since 1970-01-01, two bytes each, in order.
    bytes internal constant HOLIDAYS =
        hex"4fe64ff8501450425076508f509d50df512f514c51535164518051a751e951fb520c524b529b52b852d052f353285355536a537953b754075427";

    /// @notice True while the 24/5 market is open at `timestamp` (a Unix time after 1970-01-02).
    function isOpen(uint256 timestamp) internal pure returns (bool) {
        uint256 date = tradingDate(timestamp);
        uint256 weekday = (date + 4) % 7; // 0 is Sunday; 1970-01-01 was a Thursday
        if (weekday == 0 || weekday == 6) return false;
        return !isHoliday(date);
    }

    /// @notice The first moment at or after `timestamp` when the market is open: `timestamp` itself while it is open,
    ///         otherwise the start of the next open trading date (20:00 New York on the evening before it, which is
    ///         00:00 UTC in daylight saving and 01:00 UTC in winter). Pure and bounded: it steps at most MAX_CLOSED
    ///         trading dates, more than any closure the calendar allows, and reverts past that.
    function nextOpen(uint256 timestamp) internal pure returns (uint256) {
        if (isOpen(timestamp)) return timestamp;
        uint256 date = tradingDate(timestamp);
        for (uint256 i; i < MAX_CLOSED; i++) {
            date += 1;
            uint256 start = date * DAY;
            if (!isDaylightSaving(start)) start += 1 hours;
            if (isOpen(start)) return start;
        }
        revert NoOpenFound();
    }

    /// @notice True when `timestamp` is exactly a week's close: Friday 20:00 New York, the start of a Saturday trading
    ///         date (00:00 UTC Saturday in daylight saving, 01:00 UTC in winter). Holidays do not move it: a holiday
    ///         Friday's week still closes at that boundary. The Options desk's expiries are these moments.
    function isWeekClose(uint256 timestamp) internal pure returns (bool) {
        uint256 desk = isDaylightSaving(timestamp) ? timestamp : timestamp - 1 hours;
        if (desk % DAY != 0) return false;
        return (desk / DAY + 4) % 7 == 6;
    }

    /// @notice The first week close strictly after `timestamp`: the next Friday 20:00 New York. A timestamp that is
    ///         itself a week close gets the one a week later.
    function weekCloseAfter(uint256 timestamp) internal pure returns (uint256) {
        uint256 date = tradingDate(timestamp);
        uint256 weekday = (date + 4) % 7;
        uint256 ahead = (6 + 7 - weekday) % 7; // days to the next Saturday trading date
        if (ahead == 0) ahead = 7; // inside a Saturday trading date: the close already passed
        uint256 start = (date + ahead) * DAY;
        if (!isDaylightSaving(start)) start += 1 hours;
        return start;
    }

    /// @notice The trading date `timestamp` belongs to, as days since 1970-01-01. After 20:00 New York it is the next
    ///         calendar date.
    function tradingDate(uint256 timestamp) internal pure returns (uint256) {
        // New York is UTC-4 in summer and UTC-5 in winter; desk time is New York plus four hours.
        uint256 desk = isDaylightSaving(timestamp) ? timestamp : timestamp - 1 hours;
        return desk / DAY;
    }

    /// @notice True if the exchange is shut all of trading date `date` (days since 1970-01-01).
    function isHoliday(uint256 date) internal pure returns (bool) {
        bytes memory h = HOLIDAYS;
        for (uint256 i; i < h.length; i += 2) {
            uint256 d = (uint256(uint8(h[i])) << 8) | uint256(uint8(h[i + 1]));
            if (d == date) return true;
            if (d > date) return false;
        }
        return false;
    }

    /// @notice True while US daylight saving time is in force: from 02:00 New York on the second Sunday of March to
    ///         02:00 New York on the first Sunday of November.
    function isDaylightSaving(uint256 timestamp) internal pure returns (bool) {
        uint256 year = _yearOf(timestamp / DAY);
        uint256 start = _nthSunday(year, 3, 2) * DAY + 7 hours; // 02:00 EST
        uint256 end = _nthSunday(year, 11, 1) * DAY + 6 hours; // 02:00 EDT
        return timestamp >= start && timestamp < end;
    }

    function _nthSunday(uint256 year, uint256 month, uint256 n) private pure returns (uint256) {
        uint256 first = _daysFromCivil(year, month, 1);
        uint256 weekday = (first + 4) % 7;
        return first + ((7 - weekday) % 7) + 7 * (n - 1);
    }

    /// @dev Days since 1970-01-01 for a Gregorian date (Howard Hinnant's algorithm), 1970 onward.
    function _daysFromCivil(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    /// @dev The Gregorian year a day number falls in.
    function _yearOf(uint256 day) private pure returns (uint256) {
        uint256 z = day + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        return yoe + era * 400 + (month <= 2 ? 1 : 0);
    }
}
