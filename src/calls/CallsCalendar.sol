// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MarketHours} from "../eth/MarketHours.sol";

/// @title CallsCalendar
/// @notice When a covered call round expires and when a stock price counts as current, from the 24/5 calendar Borro
///         already uses for Borrow ETH (MarketHours: Sunday 20:00 to Friday 20:00 New York, less the exchange's full-day
///         holidays 2026 to 2028, daylight saving computed).
/// @dev "Desk time" is New York plus four hours, so a trading date runs from 20:00 New York the evening before to
///      20:00 New York on the date. A Robinhood stock feed posts on a 0.5% move or after 24 hours, around the clock
///      while its market is open, and not at all while it is shut.
library CallsCalendar {
    uint256 internal constant DAY = 1 days;

    error MarketShut();

    /// @notice True if trading date `date` (days since 1970-01-01) is a weekday the exchange is open.
    function isOpenDate(uint256 date) internal pure returns (bool) {
        uint256 weekday = (date + 4) % 7; // 0 is Sunday
        return weekday != 0 && weekday != 6 && !MarketHours.isHoliday(date);
    }

    /// @notice Seconds into the trading date at `t`: 0 is 20:00 New York the evening before, 13.5 hours is the 09:30
    ///         regular open.
    function secondsIntoDate(uint256 t) internal pure returns (uint256) {
        uint256 desk = MarketHours.isDaylightSaving(t) ? t : t - 1 hours;
        return desk % DAY;
    }

    /// @notice The expiry of a round started at `t`: the end of the last open trading date of `t`'s week, the moment the
    ///         24/5 market shuts for the weekend. Normally Friday 20:00 New York; Thursday 20:00 when Friday is a
    ///         holiday (Good Friday). Reverts unless trading date `t` is open.
    function expiryOf(uint256 t) internal pure returns (uint256) {
        uint256 d = MarketHours.tradingDate(t);
        if (!isOpenDate(d)) revert MarketShut();
        uint256 last = d + (5 - (d + 4) % 7); // the Friday of this week
        while (last > d && !isOpenDate(last)) last--;
        // The end of trading date `last`, from desk time back to UTC: the same in summer, an hour later in winter. Daylight
        // saving changes on a Sunday, never between Friday evening and Saturday, so reading it at the instant is exact.
        uint256 deskEnd = (last + 1) * DAY;
        return MarketHours.isDaylightSaving(deskEnd) ? deskEnd : deskEnd + 1 hours;
    }

    /// @notice True if a price posted at `u` is still the stock's price at `t`: posted at or before `t`, no more than
    ///         `maxAge` before it, and with the market open on every trading date from the post to `t`. A price from
    ///         before a weekend or a holiday is never current after it, however small the move it missed.
    function fresh(uint256 u, uint256 t, uint256 maxAge) internal pure returns (bool) {
        if (u == 0 || u > t || t - u > maxAge) return false;
        uint256 to = MarketHours.tradingDate(t);
        for (uint256 d = MarketHours.tradingDate(u); d <= to; d++) {
            if (!isOpenDate(d)) return false;
        }
        return true;
    }
}
