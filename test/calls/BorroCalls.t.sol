// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {IStockVault, IRoundFeed} from "../../src/calls/CallsDeps.sol";
import {CallsBase} from "./CallsBase.sol";
import {MockStock, MockUsdg, MockStockVault, MockRoundFeed} from "./CallsMocks.sol";

/// USDG that calls back into the calls vault on every transfer out of it: reentrancy must be refused.
contract ReentrantUsdg is ERC20 {
    BorroCalls public target;
    bytes public payload;
    bool public tried;
    bool public refused;

    constructor() ERC20("Bad USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(BorroCalls t, bytes calldata p) external {
        target = t;
        payload = p;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(target) != address(0) && from == address(target) && !tried) {
            tried = true;
            (bool ok, bytes memory ret) = address(target).call(payload);
            refused = !ok && bytes4(ret) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
        }
    }
}

contract BorroCallsTest is CallsBase {
    // ---------------------------------------------------------------- setup

    function test_setup_checks_the_tokens_the_feed_and_the_settings() public {
        assertEq(calls.owner(), safe);
        assertEq(calls.symbol(), "ccNVDA");
        MockUsdg wrong = new MockUsdg();
        vm.expectRevert(BorroCalls.BadSetup.selector); // the vault's asset is not the stock
        new BorroCalls(IERC20(address(wrong)), IStockVault(address(bv)), usdg, IRoundFeed(address(feed)), safe, _params(), "x", "x");
        vm.expectRevert(BorroCalls.BadSetup.selector); // "USDG" with 18 decimals
        new BorroCalls(stock, IStockVault(address(bv)), IERC20(address(stock)), IRoundFeed(address(feed)), safe, _params(), "x", "x");
        BorroCalls.Params memory p = _params();
        p.floorBps = 0;
        vm.expectRevert(BorroCalls.BadParams.selector);
        _deploy(p);
    }

    // ---------------------------------------------------------------- deposits between rounds

    function test_deposits_lend_the_stock_and_mint_pro_rata() public {
        uint256 a = _deposit(alice, 100e18);
        assertEq(a, 100e18, "first deposit one for one");
        assertEq(bv.balanceOf(address(calls)), 100e18, "the stock went into the Borro vault");
        assertEq(stock.balanceOf(address(calls)), 0, "no stock held");
        uint256 got = _vaultShares(bob, 50e18);
        vm.startPrank(bob);
        bv.approve(address(calls), got);
        uint256 b = calls.depositShares(got, bob);
        vm.stopPrank();
        assertEq(b, 50e18, "vault shares in at the same price");
        assertEq(calls.active(), 150e18);
        vm.expectRevert(BorroCalls.Nothing.selector);
        calls.deposit(0, alice);
    }

    function test_withdraw_between_rounds_pays_vault_shares_or_stock() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        (uint256 out,) = calls.withdraw(40e18, alice, false);
        assertEq(out, 40e18, "its part of the vault");
        assertEq(bv.balanceOf(alice), out);
        vm.prank(alice);
        (uint256 out2,) = calls.withdraw(type(uint256).max, alice, true);
        assertEq(out2, 60e18);
        assertEq(stock.balanceOf(alice), 60e18, "redeemed for the stock");
        assertEq(calls.totalSupply(), 0);
        assertEq(calls.active(), 0);
    }

    // ---------------------------------------------------------------- starting a round

    function test_a_round_starts_at_the_open_with_a_rounded_up_strike() public {
        _deposit(alice, 100e18);
        vm.warp(OPEN);
        feed.post(230_1234_5678); // $230.12345678
        uint256 id = calls.startRound();
        BorroCalls.Round memory r = _round(id);
        assertEq(id, 1);
        assertEq(r.spot, 230_1234_5678);
        // 230.12345678 x 1.05 = 241.6296296..., up to the cent
        assertEq(r.strike, 241_6300_0000, "strike");
        assertEq(r.capacity, 100e18, "every stock token offered");
        assertEq(r.expiry, EXPIRY, "friday 20:00 new york");
        assertEq(r.auctionEnd, OPEN + 6 hours);
        assertTrue(calls.live());
        vm.expectRevert(BorroCalls.RoundLive.selector);
        calls.startRound();
    }

    function test_no_round_before_the_open_on_a_closed_market_or_with_a_stale_price() public {
        _deposit(alice, 100e18);
        vm.warp(OPEN - 1);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.startRound();
        vm.warp(MON - 1 hours); // Sunday 19:00 New York
        vm.expectRevert(BorroCalls.MarketClosed.selector);
        calls.startRound();
        // Friday's last price, seen on Monday morning before the feed's first post of the week.
        BorroCalls fresh = _deploy(_params());
        MockRoundFeed f2 = feed;
        vm.warp(MON - 3 days + 23 hours); // Friday 19:00 New York
        f2.post(P0);
        vm.warp(OPEN);
        vm.expectRevert(BorroCalls.NoPrice.selector);
        fresh.startRound();
    }

    function test_no_round_too_late_in_the_week_paused_or_empty() public {
        vm.warp(OPEN);
        feed.post(P0);
        vm.expectRevert(BorroCalls.NothingToWrite.selector);
        calls.startRound();
        _deposit(alice, 100e18);
        vm.prank(safe);
        calls.setPaused(true);
        vm.expectRevert(BorroCalls.IsPaused.selector);
        calls.startRound();
        vm.prank(safe);
        calls.setPaused(false);
        stock.setOraclePaused(true);
        vm.expectRevert(BorroCalls.StockPaused.selector);
        calls.startRound();
        stock.setOraclePaused(false);
        // Thursday at the open: the sale would end at 15:30 Thursday, 28.5 hours before expiry: allowed.
        vm.warp(OPEN + 3 days);
        feed.post(P0);
        assertEq(calls.startRound(), 1);
    }

    function test_friday_is_too_late() public {
        _deposit(alice, 100e18);
        vm.warp(OPEN + 4 days);
        feed.post(P0);
        vm.expectRevert(BorroCalls.TooLate.selector);
        calls.startRound();
    }

    // ---------------------------------------------------------------- the sale

    function test_the_price_falls_from_start_to_floor_with_the_live_price() public {
        _deposit(alice, 100e18);
        _start();
        // Ten calls at a time (a single call near the floor is under the $1 minimum).
        // At the start: 1.20% of $230 = $2.76 a call.
        (, uint256 c0) = calls.quote(10e18);
        assertEq(c0, 27_600_000);
        // Halfway: (120 + 13) / 2 = 66.5 bps of $230 = $1.5295.
        vm.warp(OPEN + 3 hours);
        (, uint256 c1) = calls.quote(10e18);
        assertEq(c1, 15_295_000);
        // The live price moves the price too: at $232.30 halfway, 66.5 bps = $1.544795.
        feed.post(232_30000000);
        (, uint256 c2) = calls.quote(10e18);
        assertEq(c2, 15_447_950);
        // A second before the end: just over the floor (13.005 bps of $232.30 = $0.302106).
        vm.warp(OPEN + 6 hours - 1);
        (, uint256 c3) = calls.quote(10e18);
        assertGe(c3, 3_019_900);
        assertLt(c3, 3_022_000);
        vm.warp(OPEN + 6 hours);
        vm.expectRevert(BorroCalls.SaleOver.selector);
        calls.quote(10e18);
    }

    function test_buy_fills_what_is_left_and_respects_max_cost() public {
        _deposit(alice, 10e18);
        _start();
        (uint256 f1, uint256 c1) = _buy(buyer, 4e18);
        assertEq(f1, 4e18);
        assertEq(c1, 11_040_000);
        assertEq(calls.optionsOf(1, buyer), 4e18);
        assertEq(calls.usdgOwed(), c1);
        // Asking for 100 fills the 6 left.
        (uint256 f2,) = _buy(buyer2, 100e18);
        assertEq(f2, 6e18);
        vm.expectRevert(BorroCalls.SoldOut.selector);
        calls.quote(1e18);
        // maxCost below the price refuses.
        BorroCalls c = _deploy(_params());
        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(c), 1e18);
        c.deposit(1e18, alice);
        vm.stopPrank();
        c.startRound();
        usdg.mint(buyer, 10e6);
        vm.startPrank(buyer);
        usdg.approve(address(c), 10e6);
        vm.expectRevert(abi.encodeWithSelector(BorroCalls.TooMuch.selector, 2_760_000, 2_759_999));
        c.buy(1e18, 2_759_999, buyer);
        vm.stopPrank();
    }

    function test_sales_stop_while_the_price_runs_up_or_the_feed_goes_quiet() public {
        _deposit(alice, 10e18);
        _start();
        // 1.25% over the start: allowed; one cent more: no sale.
        feed.post(232_87500000);
        calls.quote(1e18);
        feed.post(232_87500001);
        vm.expectRevert(abi.encodeWithSelector(BorroCalls.PriceMoved.selector, 232_87500001, 232_87500000));
        calls.quote(1e18);
        feed.post(P0);
        calls.quote(1e18);
        stock.setOraclePaused(true);
        vm.expectRevert(BorroCalls.StockPaused.selector);
        calls.quote(1e18);
        stock.setOraclePaused(false);
        vm.prank(safe);
        calls.setPaused(true);
        usdg.mint(buyer, 1e9);
        vm.prank(buyer);
        vm.expectRevert(BorroCalls.IsPaused.selector);
        calls.buy(1e18, 1e9, buyer);
    }

    // ---------------------------------------------------------------- settling

    function test_otm_expiry_pays_the_premium_to_depositors() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _start();
        (, uint256 cost) = _buy(buyer, 50e18);
        vm.warp(EXPIRY);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.settle(0);
        _expireAt(240e8); // under the 241.50 strike
        BorroCalls.Round memory r = _round(1);
        assertEq(uint8(r.outcome), uint8(BorroCalls.Outcome.Settled));
        assertEq(r.settlePrice, 240e8);
        assertEq(r.owedShares, 0);
        assertFalse(calls.live());
        assertApproxEqAbs(calls.premiumOf(alice), cost * 60 / 100, 1);
        assertApproxEqAbs(calls.premiumOf(bob), cost * 40 / 100, 1);
        vm.prank(alice);
        (, uint256 u) = calls.collect(alice, false);
        assertEq(usdg.balanceOf(alice), u);
        // The buyer's options close with nothing.
        vm.prank(buyer);
        (uint256 vs, uint256 refund) = calls.exercise(1, buyer, false);
        assertEq(vs + refund, 0);
        // The stock never left the Borro vault: depositors still own every share of it.
        assertEq(calls.active(), 100e18);
    }

    function test_itm_expiry_pays_holders_in_borro_vault_shares() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 30e18);
        _buy(buyer2, 10e18);
        _expireAt(253e8); // strike 241.50
        uint256 owed = Math.mulDiv(40e18, 253e8 - 241_5000_0000, 253e8); // stock
        BorroCalls.Round memory r = _round(1);
        assertEq(r.owedShares, bv.convertToShares(owed), "set aside at settlement");
        assertEq(calls.forOptions(), r.owedShares);
        assertEq(calls.active(), 100e18 - r.owedShares, "the depositors gave up the upside above the strike");
        vm.prank(buyer);
        (uint256 got,) = calls.exercise(1, buyer, false);
        assertEq(got, Math.mulDiv(30e18, r.owedShares, 40e18));
        assertEq(bv.balanceOf(buyer), got, "paid in bNVDA, still lent");
        vm.prank(buyer2);
        calls.exercise(1, buyer2, true);
        assertApproxEqAbs(stock.balanceOf(buyer2), owed / 4, 2, "redeemed to the stock");
        vm.prank(buyer);
        vm.expectRevert(BorroCalls.Nothing.selector);
        calls.exercise(1, buyer, false);
    }

    function test_a_round_that_sold_nothing_ends_with_its_sale() public {
        _deposit(alice, 100e18);
        _start();
        vm.warp(OPEN + 6 hours - 1);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.settle(0);
        vm.warp(OPEN + 6 hours);
        calls.settle(0);
        assertFalse(calls.live());
        vm.prank(alice);
        calls.withdraw(10e18, alice, false); // free on Monday afternoon
    }

    function test_only_the_answer_at_expiry_settles() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 early = _postAt(250e8, EXPIRY - 5 hours);
        uint80 last = _postAt(240e8, EXPIRY - 1 hours);
        vm.warp(EXPIRY + 2 days);
        uint80 after1 = feed.post(260e8); // Monday's first post
        vm.expectRevert(BorroCalls.BadHint.selector); // an earlier round
        calls.settle(early);
        vm.expectRevert(BorroCalls.FreshAtExpiry.selector); // a later round, while the answer at expiry was current
        calls.settle(after1);
        vm.expectRevert(BorroCalls.BadHint.selector); // nothing
        calls.settle(0);
        calls.settle(last);
        assertEq(_round(1).settlePrice, 240e8);
    }

    function test_a_stale_feed_at_expiry_settles_on_the_first_post_after_it() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        // The feed's last post is Thursday 09:00 New York: 35 hours before expiry.
        uint80 stale = _postAt(250e8, EXPIRY - 35 hours);
        vm.warp(EXPIRY + 1);
        vm.expectRevert(BorroCalls.StaleAtExpiry.selector);
        calls.settle(stale);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(stale + 1);
        // Monday's first post settles it.
        uint80 first = _postAt(244e8, EXPIRY + 2 days + 1 minutes);
        uint80 second = _postAt(270e8, EXPIRY + 2 days + 2 hours);
        vm.expectRevert(BorroCalls.BadHint.selector); // not the first after expiry
        calls.settle(second);
        calls.settle(first);
        assertEq(_round(1).settlePrice, 244e8);
        assertGt(_round(1).owedShares, 0, "244 is over the 241.50 strike");
    }

    function test_a_post_too_long_after_expiry_cannot_settle_and_the_round_is_called_off() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _start();
        (, uint256 c1) = _buy(buyer, 10e18);
        (, uint256 c2) = _buy(buyer2, 5e18);
        uint80 stale = _postAt(250e8, EXPIRY - 30 hours);
        // Nothing for eight days.
        vm.warp(EXPIRY + 7 days);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.voidRound(stale);
        uint80 late = _postAt(245e8, EXPIRY + 8 days);
        vm.expectRevert(BorroCalls.TooLate.selector);
        calls.settle(late);
        calls.voidRound(stale);
        assertEq(uint8(_round(1).outcome), uint8(BorroCalls.Outcome.Void));
        assertFalse(calls.live());
        vm.prank(buyer);
        (, uint256 r1) = calls.exercise(1, buyer, false);
        vm.prank(buyer2);
        (, uint256 r2) = calls.exercise(1, buyer2, false);
        assertEq(r1, c1, "every buyer gets the payment back");
        assertEq(r2, c2);
        assertEq(calls.usdgOwed(), 0);
        assertEq(calls.premiumOf(alice), 0, "no premium for a round called off");
        assertEq(calls.active(), 200e18, "and no payout");
    }

    function test_a_round_cannot_be_called_off_while_a_price_exists() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 last = _postAt(240e8, EXPIRY - 1 hours);
        vm.warp(EXPIRY + 8 days);
        vm.expectRevert(BorroCalls.FreshAtExpiry.selector);
        calls.voidRound(last);
        // A round still unsettled 30 days on is called off by anyone, whatever the feed did (nobody settled it).
        vm.warp(EXPIRY + 30 days + 1);
        calls.voidRound(0);
        assertEq(uint8(_round(1).outcome), uint8(BorroCalls.Outcome.Void));
    }

    function test_void_refused_when_a_post_came_within_the_wait() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 stale = _postAt(250e8, EXPIRY - 30 hours);
        _postAt(246e8, EXPIRY + 3 days);
        vm.warp(EXPIRY + 7 days + 1);
        vm.expectRevert(BorroCalls.NotVoid.selector);
        calls.voidRound(stale);
        calls.settle(stale + 1);
        assertEq(_round(1).settlePrice, 246e8);
    }

    function test_a_new_feed_phase_after_expiry_still_settles() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 last = _postAt(240e8, EXPIRY - 1 hours);
        vm.warp(EXPIRY + 2 days);
        feed.newPhase();
        feed.post(255e8);
        calls.settle(last);
        assertEq(_round(1).settlePrice, 240e8);
    }

    /// A feed upgrade before expiry (review L-3, re-check R-1): the round settles in the newest phase begun before
    /// expiry, the proxy's own answer, and only there. Exactly one round passes.
    function test_a_feed_upgrade_before_expiry_settles_in_the_new_phase() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        assertEq(_round(1).phase, 1);
        uint80 old = _postAt(240e8, EXPIRY - 3 hours);
        vm.warp(EXPIRY - 2 hours);
        feed.newPhase();
        uint80 cur = feed.post(250e8);
        vm.warp(EXPIRY + 1);
        assertEq(calls.settlementPhase(1), 2);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(old);
        calls.settle(cur);
        assertEq(_round(1).settlePrice, 250e8);
    }

    /// Review L-2: stale at expiry, then the feed is upgraded before it posts again. The round's own phase never posts
    /// again, so after SETTLE_WAIT the round is called off with proof (not left for 30 days).
    function test_a_feed_upgrade_after_a_stale_expiry_calls_the_round_off_after_the_wait() public {
        _deposit(alice, 100e18);
        _start();
        (, uint256 cost) = _buy(buyer, 10e18);
        uint80 stale = _postAt(250e8, EXPIRY - 30 hours);
        vm.warp(EXPIRY + 1 days);
        feed.newPhase();
        uint80 cur = feed.post(260e8);
        vm.warp(EXPIRY + 2 days);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(cur);
        vm.warp(EXPIRY + 7 days + 1);
        calls.voidRound(stale);
        vm.prank(buyer);
        (, uint256 refund) = calls.exercise(1, buyer, false);
        assertEq(refund, cost);
    }

    /// Review L-1: a post landing exactly at expiry (the market already shut) counts as after it; the post before it
    /// settles, and the weekend never decides the week.
    function test_a_post_at_exactly_expiry_counts_as_after_it() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 friday = _postAt(240_50000000, EXPIRY - 4 hours);
        uint80 atExpiry = _postAt(241_00000000, EXPIRY);
        vm.warp(EXPIRY + 2 days);
        uint80 monday = feed.post(260e8);
        vm.expectRevert(BorroCalls.FreshAtExpiry.selector);
        calls.settle(atExpiry);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(monday);
        calls.settle(friday);
        assertEq(_round(1).settlePrice, 240_50000000);
        assertEq(_round(1).owedShares, 0, "under the 241.50 strike");
    }

    function test_settling_waits_out_a_corporate_action() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        uint80 last = _postAt(240e8, EXPIRY - 1 hours);
        vm.warp(EXPIRY + 1);
        stock.setOraclePaused(true);
        vm.expectRevert(BorroCalls.StockPaused.selector);
        calls.settle(last);
        stock.setOraclePaused(false);
        calls.settle(last);
    }

    // ---------------------------------------------------------------- queues

    function test_withdrawals_during_a_round_wait_for_its_end_and_share_its_payout() public {
        _deposit(alice, 50e18);
        _deposit(bob, 50e18);
        _start();
        vm.prank(alice);
        vm.expectRevert(BorroCalls.RoundLive.selector);
        calls.withdraw(1e18, alice, false);
        vm.prank(alice);
        calls.requestWithdraw(type(uint256).max);
        assertEq(calls.balanceOf(alice), 0);
        assertEq(calls.queuedOut(), 50e18);
        (, uint256 cost) = _buy(buyer, 100e18);
        _expireAt(253e8);
        uint256 owed = _round(1).owedShares;
        // Alice leaves with half of what is left after the payout, and half the premium.
        vm.prank(alice);
        (uint256 vs, uint256 u) = calls.collect(alice, false);
        assertApproxEqAbs(vs, (100e18 - owed) / 2, 1);
        assertApproxEqAbs(u, cost / 2, 1);
        assertLe(calls.leaving(), 1, "only rounding dust stays set aside");
        assertEq(bv.balanceOf(alice), vs);
        // Bob still holds his shares, worth the other half.
        vm.prank(bob);
        (uint256 vb, uint256 ub) = calls.withdraw(type(uint256).max, bob, false);
        assertApproxEqAbs(vb, (100e18 - owed) / 2, 2);
        assertApproxEqAbs(ub, cost / 2, 1);
    }

    function test_cancel_a_queued_withdrawal() public {
        _deposit(alice, 50e18);
        _start();
        vm.startPrank(alice);
        calls.requestWithdraw(20e18);
        assertEq(calls.cancelWithdraw(), 20e18);
        vm.stopPrank();
        assertEq(calls.balanceOf(alice), 50e18);
        assertEq(calls.queuedOut(), 0);
    }

    function test_deposits_during_a_round_join_after_it_at_the_new_price() public {
        _deposit(alice, 100e18);
        _start();
        _deposit(bob, 50e18); // queued: not in this round
        assertEq(calls.balanceOf(bob), 0);
        assertEq(calls.pendingIn(), 50e18);
        (, uint256 cost) = _buy(buyer, 100e18);
        _expireAt(253e8);
        uint256 owed = _round(1).owedShares;
        // Bob gets no part of round 1's premium or payout; his shares are priced after it.
        assertEq(calls.premiumOf(bob), 0);
        vm.prank(bob);
        calls.collect(bob, false);
        uint256 bobShares = calls.balanceOf(bob);
        assertApproxEqRel(bobShares, Math.mulDiv(50e18, 100e18, 100e18 - owed), 1e12);
        (uint256 bobValue,) = calls.previewWithdraw(bobShares);
        assertApproxEqAbs(bobValue, 50e18, 2, "bob owns what he put in");
        assertApproxEqAbs(calls.premiumOf(alice), cost, 1, "alice owns all of round 1's premium");
    }

    function test_cancel_a_queued_deposit() public {
        _deposit(alice, 100e18);
        _start();
        _deposit(bob, 5e18);
        vm.prank(bob);
        assertEq(calls.cancelDeposit(), 5e18);
        assertEq(bv.balanceOf(bob), 5e18);
        assertEq(calls.pendingIn(), 0);
    }

    function test_premium_follows_shares_moved_between_rounds() public {
        _deposit(alice, 100e18);
        _start();
        (, uint256 c1) = _buy(buyer, 100e18);
        _expireAt(240e8);
        // Round 1's premium stays with Alice after she hands Bob half her shares.
        vm.prank(alice);
        calls.transfer(bob, 50e18);
        assertApproxEqAbs(calls.premiumOf(alice), c1, 1);
        assertEq(calls.premiumOf(bob), 0);
    }

    // ---------------------------------------------------------------- the owner

    function test_settings_changes_wait_and_apply_at_a_later_round_start() public {
        BorroCalls.Params memory p = _params();
        p.stepBps = 1000;
        p.maxMoveBps = 250;
        p.floorBps = 25; // at least a fortieth of the step
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        calls.queueParams(p);
        vm.prank(safe);
        calls.queueParams(p);
        _deposit(alice, 100e18);
        // Monday: not three days yet, the old step applies.
        _start();
        assertEq(_round(1).strike, 241_5000_0000);
        vm.warp(OPEN + 6 hours);
        calls.settle(0);
        // Next Monday: the new step.
        vm.warp(OPEN + 7 days);
        feed.post(P0);
        calls.startRound();
        assertEq(_round(2).strike, 253_0000_0000);
        (uint16 step,,,,,,) = calls.params();
        assertEq(step, 1000);
    }

    function test_settings_stay_inside_hard_limits() public {
        BorroCalls.Params memory p = _params();
        vm.startPrank(safe);
        p.stepBps = 99;
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.startBps = 2001;
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.floorBps = p.startBps + 1;
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.maxMoveBps = p.stepBps / 2 + 1;
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.auctionSeconds = 25 hours;
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.writeBps = 10_001;
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.startOffset = 13.5 hours - 1; // before the regular open
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.startOffset = 14 hours + 1; // the 6 hour sale would run past 16:00 New York
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p = _params();
        p.stepBps = 249; // more than halves the step in one change
        p.maxMoveBps = 100;
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        calls.cancelParams();
        vm.expectRevert(BorroCalls.NoRenounce.selector);
        calls.renounceOwnership();
        vm.stopPrank();
    }

    function test_the_owner_reclaims_only_what_nobody_is_owed() public {
        _deposit(alice, 100e18);
        _start();
        (, uint256 cost) = _buy(buyer, 10e18);
        _deposit(bob, 5e18); // queued
        // Donations: Borro vault shares and USDG sent straight here, and another token.
        uint256 gift = _vaultShares(carol, 3e18);
        vm.prank(carol);
        bv.transfer(address(calls), gift);
        usdg.mint(address(calls), 7e6);
        MockStock other = new MockStock();
        other.mint(address(calls), 1e18);
        assertEq(calls.reclaimable(address(bv)), gift);
        assertEq(calls.reclaimable(address(usdg)), 7e6);
        assertEq(calls.reclaimable(address(other)), 1e18);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(BorroCalls.OverReclaimable.selector, gift + 1, gift));
        calls.reclaim(address(bv), safe, gift + 1);
        calls.reclaim(address(bv), safe, gift);
        calls.reclaim(address(usdg), safe, 7e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(calls)), cost, "the premium stays");
        assertEq(bv.balanceOf(address(calls)), 105e18, "every depositor's share stays");
        // The donation never moved the share price.
        _expireAt(240e8);
        vm.prank(bob);
        calls.collect(bob, false);
        (uint256 v,) = calls.previewWithdraw(calls.balanceOf(bob));
        assertApproxEqAbs(v, 5e18, 1);
    }

    function test_the_owner_at_every_extreme_cannot_reach_money() public {
        _deposit(alice, 100e18);
        _start();
        (, uint256 cost) = _buy(buyer, 10e18);
        // The furthest one change can go from the NVDA settings: half the step, half the floor, the shortest sale.
        BorroCalls.Params memory p = BorroCalls.Params(250, 60, 7, 25, 100, 1 hours, 13.5 hours);
        vm.startPrank(safe);
        calls.queueParams(p);
        calls.setPaused(true);
        assertEq(calls.reclaimable(address(bv)), 0);
        assertEq(calls.reclaimable(address(usdg)), 0);
        vm.stopPrank();
        // Paused, the round still settles and everyone is paid.
        _expireAt(253e8);
        vm.prank(alice);
        (uint256 v, uint256 u) = calls.withdraw(type(uint256).max, alice, false);
        vm.prank(buyer);
        (uint256 o,) = calls.exercise(1, buyer, false);
        assertApproxEqAbs(v + o, 100e18, 2, "the depositor and the holder split the stock");
        assertApproxEqAbs(u, cost, 1, "the premium");
    }

    function test_a_paused_usdg_never_stops_the_stock_from_leaving() public {
        _deposit(alice, 100e18);
        _start();
        (, uint256 cost) = _buy(buyer, 10e18);
        _expireAt(240e8);
        usdg.setFrozen(true);
        vm.prank(alice);
        (uint256 v, uint256 u) = calls.withdraw(type(uint256).max, alice, false);
        assertEq(v, 100e18, "the stock left");
        assertEq(u, 0, "the premium could not");
        assertApproxEqAbs(calls.premiumOf(alice), cost, 1, "and is still owed");
        assertEq(calls.usdgOwed(), cost);
        usdg.setFrozen(false);
        vm.prank(alice);
        (, uint256 u2) = calls.collect(alice, false);
        assertApproxEqAbs(u2, cost, 1);
    }

    function test_nobody_deposits_or_buys_for_address_zero() public {
        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(calls), 1e18);
        vm.expectRevert(BorroCalls.ZeroAddress.selector);
        calls.deposit(1e18, address(0));
        vm.stopPrank();
        _deposit(alice, 10e18);
        _start();
        usdg.mint(buyer, 1e9);
        vm.startPrank(buyer);
        usdg.approve(address(calls), 1e9);
        vm.expectRevert(BorroCalls.ZeroAddress.selector);
        calls.buy(1e18, 1e9, address(0));
        vm.stopPrank();
    }

    function test_the_floor_is_at_least_a_fortieth_of_the_step_and_settings_halve_at_most() public {
        BorroCalls.Params memory p = _params(); // step 500, floor 13
        p.floorBps = 12; // under 500 / 40
        p.stepBps = 500;
        vm.prank(safe);
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p.floorBps = 13;
        vm.prank(safe);
        calls.queueParams(p);
        p.stepBps = 260; // half of 500 and a little
        p.floorBps = 7; // more than half of 13
        p.maxMoveBps = 100;
        vm.prank(safe);
        calls.queueParams(p);
        p.floorBps = 6; // less than half of 13
        vm.prank(safe);
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
        p.floorBps = 7;
        p.startBps = 59; // less than half of 120
        vm.prank(safe);
        vm.expectRevert(BorroCalls.BadParams.selector);
        calls.queueParams(p);
    }

    /// Review M-1: a pause ends a live sale for good. Unpausing does not reopen it, and no second round starts that week,
    /// so a pause can never hold the price falling for one buyer.
    function test_a_pause_ends_the_sale_for_good() public {
        _deposit(alice, 100e18);
        _start();
        _buy(buyer, 10e18);
        vm.warp(OPEN + 1 hours);
        vm.prank(safe);
        calls.setPaused(true);
        assertEq(_round(1).auctionEnd, OPEN + 1 hours, "the sale ended at the pause");
        vm.warp(OPEN + 6 hours - 1);
        vm.prank(safe);
        calls.setPaused(false);
        vm.expectRevert(BorroCalls.SaleOver.selector);
        calls.quote(1e18);
        _expireAt(240e8);
        assertEq(_round(1).sold, 10e18, "what sold stays written");
    }

    /// Review I-2: one round a week. After a round that sold nothing ends on Monday afternoon, the next starts next week.
    function test_one_round_a_week() public {
        _deposit(alice, 100e18);
        _start();
        vm.warp(OPEN + 6 hours);
        calls.settle(0);
        vm.warp(OPEN + 1 days);
        feed.post(P0);
        vm.expectRevert(BorroCalls.WeekDone.selector);
        calls.startRound();
        vm.warp(OPEN + 7 days);
        feed.post(P0);
        assertEq(calls.startRound(), 2);
    }

    /// Review I-1: a purchase under 1 USDG is refused unless it takes the last options, so a wei cannot hold a round
    /// that sold nothing open all week.
    function test_a_purchase_costs_at_least_a_dollar_unless_it_takes_the_last_options() public {
        _deposit(alice, 1e18);
        _start();
        usdg.mint(buyer, 10e6);
        vm.startPrank(buyer);
        usdg.approve(address(calls), 10e6);
        vm.expectRevert(abi.encodeWithSelector(BorroCalls.TooSmall.selector, 1, 1e6));
        calls.buy(1, 10e6, buyer);
        (uint256 filled,) = calls.buy(1e18 - 1, 10e6, buyer);
        (uint256 last, uint256 c) = calls.buy(1e18, 10e6, buyer); // the last wei: allowed
        vm.stopPrank();
        assertEq(filled + last, 1e18);
        assertLt(c, 1e6);
    }

    /// Review L-4: the calendar knows holidays through 2028, so no round starts in 2029 or after.
    function test_no_round_after_the_calendar_ends() public {
        _deposit(alice, 1e18);
        uint256 mon2029 = 1861920000 + 6 days; // Monday 2029-01-07 00:00 UTC (winter)
        vm.warp(mon2029 + 14 hours + 50 minutes);
        feed.post(P0);
        vm.expectRevert(BorroCalls.CalendarEnded.selector);
        calls.startRound();
    }

    // ---------------------------------------------------------------- reentrancy

    function test_a_token_calling_back_is_refused() public {
        ReentrantUsdg bad = new ReentrantUsdg();
        BorroCalls c = new BorroCalls(stock, IStockVault(address(bv)), IERC20(address(bad)), IRoundFeed(address(feed)), safe, _params(), "x", "x");
        stock.mint(alice, 10e18);
        vm.startPrank(alice);
        stock.approve(address(c), 10e18);
        c.deposit(10e18, alice);
        vm.stopPrank();
        vm.warp(OPEN);
        feed.post(P0);
        c.startRound();
        bad.mint(buyer, 1e9);
        vm.startPrank(buyer);
        bad.approve(address(c), 1e9);
        c.buy(1e18, 1e9, buyer);
        vm.stopPrank();
        uint80 hint = _postAt(240e8, EXPIRY - 1 hours);
        vm.warp(EXPIRY + 1);
        c.settle(hint);
        // Alice collects her premium; the token calls back into collect on the way out.
        bad.arm(c, abi.encodeCall(BorroCalls.collect, (alice, false)));
        vm.prank(alice);
        c.collect(alice, false);
        assertTrue(bad.tried() && bad.refused(), "the call back was refused");
    }
}
