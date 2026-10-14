// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {CallsCalendar} from "../../src/calls/CallsCalendar.sol";
import {IStockVault, IRoundFeed} from "../../src/calls/CallsDeps.sol";
import {CallsBase} from "./CallsBase.sol";

/// Independent review (2026-10-09), docs/COVERED-CALLS.md "Review". The reviewer's proofs of concept, kept as regression
/// tests after the fixes: each now shows the attack refused at the guard that fixed it. L-5 was accepted, not fixed: its
/// test shows the accepted behaviour.

/// Test only: a Chainlink proxy whose older phase's aggregator keeps receiving posts after the proxy moved on (what
/// happens while Chainlink runs an old and a new aggregator side by side during an upgrade).
contract TwoPhaseFeed {
    struct R {
        int256 answer;
        uint256 updatedAt;
    }

    uint16 public phase = 1;
    mapping(uint16 => R[]) internal _r;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function postIn(uint16 p, int256 answer, uint256 at) public returns (uint80) {
        require(p >= 1 && p <= phase, "no phase");
        _r[p].push(R(answer, at));
        return _id(p, _r[p].length);
    }

    function newPhase() external {
        phase++;
    }

    function _id(uint16 p, uint256 n) internal pure returns (uint80) {
        return uint80((uint256(p) << 64) | n);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint16 p = phase;
        while (p > 1 && _r[p].length == 0) p--;
        uint80 id = _id(p, _r[p].length);
        (int256 a, uint256 u) = _get(id);
        return (id, a, u, u, id);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        uint16 p = uint16(uint256(id) >> 64);
        require(p >= 1 && p <= phase, "no phase");
        (int256 a, uint256 u) = _get(id);
        return (id, a, u, u, id);
    }

    function _get(uint80 id) internal view returns (int256, uint256) {
        uint16 p = uint16(uint256(id) >> 64);
        uint256 n = uint64(id);
        if (n == 0 || n > _r[p].length) return (0, 0);
        R memory x = _r[p][n - 1];
        return (x.answer, x.updatedAt);
    }
}

contract ReviewCalendar {
    function expiryOf(uint256 t) external pure returns (uint256) {
        return CallsCalendar.expiryOf(t);
    }
}

contract BorroCallsReviewTest is CallsBase {
    // ---------------------------------------------------------------- L-1: a post at exactly expiry (fixed)

    /// A post stamped exactly Friday 20:00 New York (the market already shut) once made the Friday post "not the answer",
    /// itself "from the future", and so handed settlement to Sunday night's post. Now the cutoff is the last second before
    /// expiry: the post at expiry counts as after it, and the Friday 19:00 post settles.
    function test_review_L1_a_post_at_exactly_expiry_no_longer_hands_settlement_to_the_weekend() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 friday = _postAt(240e8, EXPIRY - 1 hours);
        uint80 atX = _postAt(240_5000_0000, EXPIRY); // block timestamp == expiry
        uint80 sunday = _postAt(260e8, EXPIRY + 2 days);
        vm.expectRevert(BorroCalls.FreshAtExpiry.selector);
        calls.settle(atX);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(sunday);
        calls.settle(friday);
        assertEq(_round(1).settlePrice, 240e8);
        assertEq(_round(1).owedShares, 0, "under the strike, as the week ended");
    }

    // ---------------------------------------------------------------- L-2: a feed upgrade after a stale expiry (fixed)

    /// Stale at expiry, then the proxy moves to a new phase over the weekend. The round reads only its own phase, which
    /// never posts again, so after SETTLE_WAIT (7 days, not 30) it is called off with proof and the buyer refunded.
    function test_review_L2_a_feed_upgrade_after_a_stale_expiry_is_called_off_after_the_wait() public {
        _deposit(alice, 100e18);
        _start();
        (, uint256 paid) = _buy(buyer, 10e18);
        uint80 stale = _postAt(250e8, EXPIRY - 30 hours);
        vm.warp(EXPIRY + 2 days);
        feed.newPhase();
        uint80 first = feed.post(260e8);
        vm.expectRevert(BorroCalls.StaleAtExpiry.selector);
        calls.settle(stale);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(first); // another phase
        vm.warp(EXPIRY + 7 days);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.voidRound(stale);
        vm.warp(EXPIRY + 7 days + 1);
        calls.voidRound(stale);
        vm.prank(buyer);
        (, uint256 refund) = calls.exercise(1, buyer, false);
        assertEq(refund, paid);
    }

    // ---------------------------------------------------------------- L-3: two aggregators, one price (fixed)

    /// The old aggregator keeps receiving posts after the proxy moved on. The round settles in the newest phase begun
    /// before expiry (the proxy's answer, 243), and the old phase's answer is refused: exactly one round passes, whoever
    /// settles first.
    function test_review_L3_an_old_phase_still_posting_gives_one_price() public {
        TwoPhaseFeed f = new TwoPhaseFeed();
        f.postIn(1, P0, block.timestamp);
        BorroCalls c = new BorroCalls(stock, IStockVault(address(bv)), usdg, IRoundFeed(address(f)), safe, _params(), "x", "x");
        stock.mint(alice, 100e18);
        vm.startPrank(alice);
        stock.approve(address(c), 100e18);
        c.deposit(100e18, alice);
        vm.stopPrank();
        vm.warp(OPEN);
        f.postIn(1, P0, block.timestamp);
        c.startRound();
        assertEq(c.roundOf(1).phase, 1);
        (, uint256 q) = c.quote(10e18);
        usdg.mint(buyer, q);
        vm.startPrank(buyer);
        usdg.approve(address(c), q);
        c.buy(10e18, q, buyer);
        vm.stopPrank();
        uint80 oldAtX = f.postIn(1, 240e8, EXPIRY - 1 hours);
        f.newPhase();
        uint80 newAtX = f.postIn(2, 243e8, EXPIRY - 30 minutes);
        vm.warp(EXPIRY + 2 days);
        f.postIn(1, 245e8, block.timestamp);
        f.postIn(2, 245e8, block.timestamp);
        vm.expectRevert(BorroCalls.BadHint.selector);
        c.settle(oldAtX);
        c.settle(newAtX);
        assertEq(c.roundOf(1).settlePrice, 243e8);
    }

    // ---------------------------------------------------------------- M-2: the hard limits (fixed)

    /// The settings that sold 100 near-the-money NVDA calls for $2.30 in a 1-hour sale from Sunday 20:00 are refused: the
    /// floor must be a fortieth of the step, the sale must sit inside 09:30 to 16:00 New York, and one change can at most
    /// halve the step, the start or the floor.
    function test_review_M2_the_owner_cannot_queue_a_fire_sale() public {
        vm.startPrank(safe);
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(BorroCalls.Params(100, 1, 1, 50, 10_000, 1 hours, 0));
        vm.expectRevert(BorroCalls.BadParams.selector); // inside the static limits, but a quarter of the step at once
        calls.queueParams(BorroCalls.Params(125, 4, 4, 50, 10_000, 1 hours, 13.5 hours));
        calls.queueParams(BorroCalls.Params(250, 60, 7, 50, 10_000, 1 hours, 13.5 hours)); // the most one change can do
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- M-1: pause, then unpause and buy (fixed)

    /// A pause in the block the round starts now ends its sale at once; unpausing in the sale's last second reopens
    /// nothing, and no second round can start that week. The Safe cannot buy the week at the floor.
    function test_review_M1_a_pause_cannot_hold_the_price_falling_for_one_buyer() public {
        _deposit(alice, 100e18);
        _start();
        vm.prank(safe);
        calls.setPaused(true);
        vm.warp(OPEN + 6 hours - 1);
        usdg.mint(safe, 1_000e6);
        vm.startPrank(safe);
        calls.setPaused(false);
        usdg.approve(address(calls), 1_000e6);
        vm.expectRevert(BorroCalls.SaleOver.selector);
        calls.buy(100e18, 1_000e6, safe);
        calls.settle(0); // nothing sold: the round ends
        vm.expectRevert(BorroCalls.WeekDone.selector);
        calls.startRound();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- L-4: the calendar after 2028 (fixed)

    /// MarketHours knows no holiday after 2028, so Good Friday 2029 would expire a day late and settle across Easter. No
    /// round starts from 2029-01-01: a vault for those years needs a new deploy with a longer calendar.
    function test_review_L4_no_round_starts_after_the_calendar_ends() public {
        uint256 mon = 1869177600; // Monday 2029-03-26 00:00 UTC
        _deposit(alice, 100e18);
        vm.warp(mon + 13.75 hours);
        feed.post(P0);
        vm.expectRevert(BorroCalls.CalendarEnded.selector);
        calls.startRound();
        ReviewCalendar h = new ReviewCalendar();
        assertEq(h.expiryOf(mon + 14 hours), mon + 5 days, "the 2029 calendar would still say Friday (known, and now unused)");
    }

    // ---------------------------------------------------------------- L-5: a corporate action across expiry (accepted)

    /// Accepted, documented: settle() waits while oraclePaused is true when it is called, but cannot see a pause that
    /// covered expiry and lifted before anyone settled. If the feed posted a mid-action price before expiry, it settles
    /// on it. The keeper settles within minutes of expiry, when a pause still in force makes it wait.
    function test_review_L5_accepted_a_price_from_inside_a_corporate_action_settles_once_the_pause_lifts() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        _postAt(232e8, EXPIRY - 3 hours);
        vm.warp(EXPIRY - 2 hours);
        stock.setOraclePaused(true);
        uint80 mid = _postAt(2_300e8, EXPIRY - 1 hours); // posted while paused
        vm.warp(EXPIRY + 1);
        vm.expectRevert(BorroCalls.StockPaused.selector); // the keeper's prompt settle waits
        calls.settle(mid);
        vm.warp(EXPIRY + 3 hours);
        stock.setOraclePaused(false);
        calls.settle(mid);
        assertGt(bv.convertToAssets(_round(1).owedShares), 8.9e18, "the accepted outcome");
    }

    // ---------------------------------------------------------------- I-1: one wei holds the week (fixed)

    /// A purchase under 1 USDG is refused unless it takes the last options: a wei can no longer keep a round that sold
    /// nothing open until Friday.
    function test_review_I1_a_wei_can_no_longer_hold_the_week() public {
        _deposit(alice, 100e18);
        _start();
        usdg.mint(makeAddr("griefer"), 1e6);
        vm.startPrank(makeAddr("griefer"));
        usdg.approve(address(calls), 1e6);
        vm.expectRevert(abi.encodeWithSelector(BorroCalls.TooSmall.selector, 1, 1e6));
        calls.buy(1, 1e6, makeAddr("griefer"));
        vm.stopPrank();
        vm.warp(OPEN + 6 hours);
        calls.settle(0);
        vm.prank(alice);
        calls.withdraw(1e18, alice, false); // free on Monday afternoon
    }

    // ---------------------------------------------------------------- I-2: once a week (fixed)

    /// After a round that sold nothing closes, the next round waits for next week.
    function test_review_I2_one_round_a_week() public {
        _deposit(alice, 100e18);
        _start();
        vm.warp(OPEN + 6 hours);
        calls.settle(0);
        feed.post(233e8);
        vm.expectRevert(BorroCalls.WeekDone.selector);
        calls.startRound();
        vm.warp(OPEN + 1 days);
        feed.post(234e8);
        vm.expectRevert(BorroCalls.WeekDone.selector);
        calls.startRound();
    }
}
