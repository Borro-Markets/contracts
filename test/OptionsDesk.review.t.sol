// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsDesk, IShareVault} from "../src/OptionsDesk.sol";
import {MarketHours} from "../src/eth/MarketHours.sol";
import {OptTok, RateVault, RoundFeed} from "./OptionsDesk.t.sol";

/// Adversarial review of OptionsDesk (2026-10-09). Each `test_finding_*` reproduces a way money was lost, stuck or
/// chosen by the wrong party before the fix and now asserts the fix; each `test_confirmed_*` confirms a class of
/// attack the contract blocks.
contract OptionsDeskReviewTest is Test {
    uint256 constant NOW = 1791817200; // Monday 2026-10-12 11:00 New York (15:00 UTC)
    uint64 constant EXP = 1792195200; // Friday 2026-10-16 20:00 EDT = 2026-10-17 00:00:00 UTC
    uint256 constant REOPEN = 1792368000; // Sunday 2026-10-18 20:00 EDT
    uint80 constant P1 = uint80(1) << 64;
    uint80 constant P2 = uint80(2) << 64;
    uint80 constant R_OLD = P1 | 9;
    uint80 constant R_LAST = P1 | 10;
    uint80 constant R_NEXT = P1 | 11;
    int256 constant REF = 180e8;
    uint128 constant K = 185e8;
    uint128 constant PREM = 2e6;
    uint128 constant MIN = 1e15;

    OptTok usdg;
    OptTok stock;
    RateVault usdgVault;
    RateVault vault;
    RoundFeed feed;
    OptionsDesk desk;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address ann = makeAddr("ann"); // writes calls from vault shares
    address bob = makeAddr("bob"); // buys
    address carl = makeAddr("carl"); // writes puts from USDG vault shares
    address dan = makeAddr("dan"); // writes from raw stock
    address eve = makeAddr("eve"); // a second buyer

    function setUp() public {
        vm.warp(NOW);
        usdg = new OptTok("USDG", 6);
        stock = new OptTok("NVDA", 18);
        usdgVault = new RateVault(usdg, 1e12, "Steakhouse USDG");
        vault = new RateVault(stock, 1, "bNVDA");
        feed = new RoundFeed(8);
        desk = new OptionsDesk(usdg, IShareVault(address(usdgVault)), owner);
        vm.startPrank(owner);
        desk.setStock(address(feed), IShareVault(address(vault)), true);
        desk.setFee(1000, keeper);
        vm.stopPrank();

        stock.mint(ann, 1_000e18);
        vm.startPrank(ann);
        stock.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18, ann);
        vault.approve(address(desk), type(uint256).max);
        vm.stopPrank();

        usdg.mint(carl, 10_000_000e6);
        vm.startPrank(carl);
        usdg.approve(address(usdgVault), type(uint256).max);
        usdgVault.deposit(10_000_000e6, carl);
        usdgVault.approve(address(desk), type(uint256).max);
        vm.stopPrank();

        usdg.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdg.approve(address(desk), type(uint256).max);
        usdg.mint(eve, 1_000_000e6);
        vm.prank(eve);
        usdg.approve(address(desk), type(uint256).max);

        stock.mint(dan, 1_000e18);
        usdg.mint(dan, 10_000_000e6);
        vm.startPrank(dan);
        stock.approve(address(desk), type(uint256).max);
        usdg.approve(address(desk), type(uint256).max);
        vm.stopPrank();
    }

    function _id(uint128 strike, bool isCall) internal view returns (bytes32) {
        return desk.seriesIdOf(address(feed), EXP, strike, isCall);
    }

    function _ask(address who, uint128 strike, bool isCall, uint128 units) internal returns (uint256 id) {
        vm.prank(who);
        id = desk.postAsk(address(feed), EXP, strike, isCall, units, PREM);
    }

    function _fill(address who, uint256 id, uint128 units) internal {
        vm.prank(who);
        desk.fillAsk(id, units, type(uint128).max);
    }

    // ================================================================ HIGH, fixed: a feed gap no longer strands a series

    /// FINDING 1 (high), fixed. A feed that stopped before the FEED_MAX_AGE window and resumed after expiry settles
    /// on its first print after expiry (the round before it is too old to be the close); a feed that never resumes
    /// is voided by anyone VOID_AFTER past expiry, and writers take their whole lock back.
    function test_finding_feed_gap_strands_every_lock_forever() public {
        // The feed's last print before a corporate-action pause: three days before the close.
        feed.set(R_OLD, REF, EXP - 3 days);
        bytes32 cid = _id(K, true);
        bytes32 pid = _id(K, false);
        uint256 callAsk = _ask(ann, K, true, 10e18);
        uint256 putAsk = _ask(carl, K, false, 10e18);
        _fill(bob, callAsk, 10e18);
        _fill(bob, putAsk, 10e18);
        uint256 callLock = desk.seriesOf(cid).lockedShares;
        uint256 putLock = desk.seriesOf(pid).lockedShares;

        // The feed resumes a week after expiry: its first print after expiry is the price.
        feed.set(R_LAST, 200e8, EXP + 7 days);
        feed.set(R_NEXT, 201e8, EXP + 8 days);
        vm.warp(EXP + 8 days + 1);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(cid, R_OLD); // too old to be the close
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(cid, R_NEXT); // not the first print after expiry
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(cid, P1 | 8); // never printed
        desk.settle(cid, R_LAST);
        desk.settle(pid, R_LAST);
        assertEq(desk.seriesOf(cid).settlePrice, 200e8);
        assertEq(desk.seriesOf(pid).payoutSharesPerUnit, 0, "the put closed out of the money");
        uint256 perUnit = desk.seriesOf(cid).payoutSharesPerUnit;
        assertEq(perUnit, vault.convertToShares(uint256(15e8) * 1e18 / 200e8));
        vm.startPrank(bob);
        assertEq(desk.claim(cid, 10e18, false), 10 * perUnit);
        assertEq(desk.claim(pid, 10e18, false), 0);
        vm.stopPrank();
        vm.prank(ann);
        assertEq(desk.release(cid), callLock - 10 * perUnit);
        vm.prank(carl);
        assertEq(desk.release(pid), putLock);
        assertEq(vault.balanceOf(address(desk)), 0, "nothing stranded");
        assertEq(usdgVault.balanceOf(address(desk)), 0);

        // A second stock whose feed never prints again: void after two weeks, the writers' locks come home.
        RoundFeed dead = new RoundFeed(8);
        vm.prank(owner);
        desk.setStock(address(dead), IShareVault(address(vault)), true);
        vm.warp(NOW);
        bytes32 did = desk.seriesIdOf(address(dead), EXP, K, true);
        vm.prank(ann);
        uint256 deadAsk = desk.postAsk(address(dead), EXP, K, true, 10e18, PREM);
        _fill(bob, deadAsk, 10e18);
        uint256 deadLock = desk.seriesOf(did).lockedShares;
        vm.warp(EXP + 14 days - 1);
        vm.expectRevert(OptionsDesk.NotExpired.selector);
        desk.void(did);
        vm.warp(EXP + 14 days);
        vm.prank(eve);
        desk.void(did);
        vm.prank(bob);
        assertEq(desk.claim(did, 10e18, false), 0, "a long gets nothing: there was no price");
        vm.prank(ann);
        assertEq(desk.release(did), deadLock, "the writer takes the whole lock");
        assertEq(vault.balanceOf(address(desk)), 0);
    }

    // ================================================================ MEDIUM, fixed: no settling on a stale print

    /// FINDING 2 (medium), fixed. FEED_MAX_AGE is two days: a print from Monday is not the Friday close, and the
    /// feed's first print after expiry settles the series instead.
    function test_finding_stale_latest_round_settles_at_the_first_second_of_expiry() public {
        feed.set(R_OLD, REF, EXP - 4 days); // Monday 20:00 NY: the last print before a pause
        bytes32 cid = _id(K, true);
        uint256 callAsk = _ask(ann, K, true, 10e18);
        _fill(bob, callAsk, 10e18);

        vm.warp(EXP + 1); // the first second settlement opens
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(cid, R_OLD); // a four-day-old price is no close
        assertFalse(desk.seriesOf(cid).settled);

        // The feed resumes with the real close an hour later: that is the price.
        feed.set(R_LAST, 200e8, EXP + 1 hours);
        vm.warp(EXP + 2 hours);
        desk.settle(cid, R_LAST);
        OptionsDesk.Series memory s = desk.seriesOf(cid);
        assertEq(s.settlePrice, 200e8);
        assertEq(s.payoutSharesPerUnit, vault.convertToShares(uint256(15e8) * 1e18 / 200e8), "the call pays");
        vm.prank(ann);
        uint256 back = desk.release(cid);
        assertEq(back, desk.writtenOf(ann, cid).lockedShares - 10 * uint256(s.payoutSharesPerUnit));
    }

    // ================================================================ MEDIUM, fixed: one phase proves

    /// FINDING 3 (medium/low), fixed. Only the feed's latest phase proves; the phase before it only when the latest
    /// phase began after expiry. An old aggregator that keeps printing after the switch offers no second price.
    function test_finding_a_live_old_aggregator_gives_the_settler_a_choice_of_price() public {
        // Phase 1: the old aggregator, still alive after the switch.
        feed.set(P1 | 10, 180e8, EXP - 2 hours);
        feed.set(P1 | 11, 180e8, REOPEN + 30);
        // Phase 2: the proxy's current aggregator since Thursday.
        feed.set(P2 | 1, 181e8, EXP - 1 days);
        feed.set(P2 | 2, 190e8, EXP - 1 hours);
        feed.set(P2 | 3, 190e8, REOPEN + 30);
        feed.setLatest(P2 | 3);

        bytes32 a = _id(K, true);
        bytes32 b = _id(K + 25_000_000, true);
        _fill(bob, _ask(ann, K, true, 1e18), 1e18);
        _fill(bob, _ask(ann, K + 25_000_000, true, 1e18), 1e18);
        vm.warp(REOPEN + 60);

        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P1 | 10); // the old aggregator's print: not the latest phase, which began before expiry
        desk.settle(a, P2 | 2);
        desk.settle(b, P2 | 2);
        assertEq(desk.seriesOf(a).settlePrice, 190e8);
        assertEq(desk.seriesOf(b).settlePrice, 190e8);
        assertGt(desk.seriesOf(a).payoutSharesPerUnit, 0, "one price, in the money");

        // Had phase 2 begun after expiry, phase 1's last print before the close would be the price instead.
        feed.set(P2 | 1, 181e8, EXP + 1 hours);
        bytes32 c = _id(K + 50_000_000, true);
        vm.warp(NOW);
        _fill(bob, _ask(ann, K + 50_000_000, true, 1e18), 1e18);
        vm.warp(REOPEN + 60);
        desk.settle(c, P1 | 10);
        assertEq(desk.seriesOf(c).settlePrice, 180e8);
    }

    // ================================================================ LOW, fixed: an ask's lock is re-measured at fill

    /// FINDING 4 (low), fixed. A fill whose moved lock is worth less than the series needs for those units now is
    /// refused (LockShort); the writer cancels and posts again at today's rate, and the long is then paid in full.
    function test_finding_fill_after_a_vault_loss_sells_a_short_lock_at_full_premium() public {
        feed.set(R_OLD, REF, NOW - 1 hours);
        bytes32 pid = _id(K, false);
        uint256 putAsk = _ask(carl, K, false, 1e18); // locks shares worth 185 USDG
        uint256 locked = desk.orderOf(putAsk).locked;
        assertApproxEqAbs(usdgVault.convertToAssets(locked), 185e6, 1);

        usdgVault.lose(5_000_000e6); // the USDG vault loses half
        assertApproxEqAbs(usdgVault.convertToAssets(locked), 925e5, 1, "the lock now covers 92.5");
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.LockShort.selector);
        desk.fillAsk(putAsk, 1e18, type(uint128).max);

        vm.prank(carl);
        desk.cancel(putAsk);
        putAsk = _ask(carl, K, false, 1e18);
        assertGt(desk.orderOf(putAsk).locked, locked * 19 / 10, "a fresh lock: about twice the shares");
        _fill(bob, putAsk, 1e18);

        feed.set(R_LAST, 50e8, EXP - 2 hours); // the stock collapses: intrinsic 135 USDG per unit
        feed.set(R_NEXT, 50e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        desk.settle(pid, R_LAST);
        assertEq(desk.seriesOf(pid).payoutUsdgPerUnit, 135e6, "not capped");
        vm.prank(bob);
        uint256 paid = desk.claim(pid, 1e18, false);
        assertApproxEqAbs(paid, 135e6, 2, "paid in full");
    }

    // ================================================================ LOW, fixed: the fee is the fee at the post

    /// FINDING 5 (low), fixed. An order carries the fee it was posted under, and `minPremium` on a bid fill is
    /// checked against what the writer nets after that fee.
    function test_finding_fee_raised_between_post_and_fill_cuts_the_writers_net() public {
        feed.set(R_OLD, REF, NOW - 1 hours);
        uint256 callAsk = _ask(ann, K, true, 1e18); // posted at 10%: Ann expects 1.8 of the 2 USDG
        vm.prank(owner);
        desk.setFee(2000, keeper);
        uint256 before = usdg.balanceOf(ann);
        _fill(bob, callAsk, 1e18);
        assertEq(usdg.balanceOf(ann) - before, 18e5, "Ann nets 1.8, as posted");
        assertEq(usdg.balanceOf(keeper), 2e5);

        vm.prank(bob);
        uint256 bid = desk.postBid(address(feed), EXP, K, true, 1e18, PREM); // posted at 20%
        vm.prank(owner);
        desk.setFee(0, keeper);
        vm.prank(ann);
        vm.expectRevert(abi.encodeWithSelector(OptionsDesk.TooLittle.selector, 16e5, 2e6));
        desk.fillBid(bid, 1e18, PREM); // the floor is on the net: 1.6 is less than 2.0
        before = usdg.balanceOf(ann);
        vm.prank(ann);
        desk.fillBid(bid, 1e18, 16e5);
        assertEq(usdg.balanceOf(ann) - before, 16e5, "net of the 20% the bid was posted under");
        assertEq(usdg.balanceOf(keeper), 6e5);
    }

    // ================================================================ confirmed safe: accounting under stress

    /// Mixed fills (whole and partial, shares and raw stock), rent between fills, then a vault loss big enough to
    /// bind the cap: every claimant is paid exactly units * payout, every writer's lock covers what it owes, and the
    /// desk never pays out more than the series locked. This is the fungibility argument of the contract's header,
    /// checked.
    function test_confirmed_claims_and_releases_never_exceed_the_series_lock() public {
        feed.set(R_OLD, REF, NOW - 1 hours);
        bytes32 cid = _id(K, true);
        uint256 a1 = _ask(ann, K, true, 3e18 + 7e15);
        _fill(bob, a1, 1e18 + 1e15); // partial: pro-rata lock, floored
        vault.accrue(50e18); // rent: later locks are thinner per unit
        vm.prank(dan);
        uint256 a2 = desk.postAskWithStock(address(feed), EXP, K, 2e18, PREM);
        _fill(eve, a2, 2e18);
        _fill(eve, a1, 2e18 + 6e15); // the rest of Ann's ask
        for (uint256 i; i < 5; i++) {
            uint256 small = _ask(ann, K, true, MIN);
            _fill(i % 2 == 0 ? bob : eve, small, MIN);
        }
        OptionsDesk.Series memory s = desk.seriesOf(cid);
        uint256 lockBefore = vault.balanceOf(address(desk));
        assertEq(lockBefore, s.lockedShares, "the desk holds exactly the series' lock");

        vault.lose(630e18); // a 60% loss before settlement
        feed.set(R_LAST, 370e8, EXP - 2 hours); // S = 2K: half a unit per unit, 1.25 shares at the new rate
        feed.set(R_NEXT, 370e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        desk.settle(cid, R_LAST);
        s = desk.seriesOf(cid);
        assertEq(s.payoutSharesPerUnit, s.minLockPerUnit, "the cap binds");

        uint256 out;
        address[2] memory buyers = [bob, eve];
        for (uint256 i; i < 2; i++) {
            uint256 units = desk.balanceOf(buyers[i], uint256(cid));
            vm.prank(buyers[i]);
            uint256 paid = desk.claim(cid, units, false);
            assertEq(paid, units * s.payoutSharesPerUnit / 1e18);
            out += paid;
        }
        address[2] memory writers = [ann, dan];
        for (uint256 i; i < 2; i++) {
            OptionsDesk.Written memory w = desk.writtenOf(writers[i], cid);
            uint256 owed = (uint256(w.units) * s.payoutSharesPerUnit + 1e18 - 1) / 1e18;
            assertGe(w.lockedShares, owed, "a writer never owes more than it locked");
            vm.prank(writers[i]);
            out += desk.release(cid);
        }
        assertLe(out, lockBefore, "never more than the lock");
        assertLt(lockBefore - out, 100, "dust only stays");
    }

    /// The owner's one new power, listing a feed, cannot reach locks on other feeds: a second feed pointed at the
    /// same vault (or a fake vault whose asset is the real share token) only ever moves what its own series locked.
    function test_confirmed_a_new_listing_cannot_reach_existing_locks() public {
        feed.set(R_OLD, REF, NOW - 1 hours);
        bytes32 cid = _id(K, true);
        _fill(bob, _ask(ann, K, true, 10e18), 10e18);
        uint256 realLock = desk.seriesOf(cid).lockedShares;

        // The owner lists a feed it controls against the real bNVDA vault and writes and buys its own series.
        RoundFeed evil = new RoundFeed(8);
        vm.prank(owner);
        desk.setStock(address(evil), IShareVault(address(vault)), true);
        vm.startPrank(ann);
        vault.transfer(owner, 1e18);
        vm.stopPrank();
        vm.startPrank(owner);
        vault.approve(address(desk), type(uint256).max);
        uint256 ask = desk.postAsk(address(evil), EXP, 1e8, true, 1e18, PREM);
        vm.stopPrank();
        usdg.mint(owner, 10e6);
        vm.startPrank(owner);
        usdg.approve(address(desk), type(uint256).max);
        desk.fillAsk(ask, 1e18, type(uint128).max);
        vm.stopPrank();
        bytes32 eid = desk.seriesIdOf(address(evil), EXP, 1e8, true);
        uint256 evilLock = desk.seriesOf(eid).lockedShares;

        // The owner's feed says the stock is worth a million dollars a share.
        evil.set(R_LAST, 1_000_000e8, EXP - 2 hours);
        evil.set(R_NEXT, 1_000_000e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        desk.settle(eid, R_LAST);
        vm.startPrank(owner);
        uint256 got = desk.claim(eid, 1e18, false);
        got += desk.release(eid);
        vm.stopPrank();
        assertLe(got, evilLock, "The owner gets back at most what it locked");
        assertGe(vault.balanceOf(address(desk)), realLock, "Ann's lock is untouched");
    }
}
