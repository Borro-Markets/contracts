// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {IStockVault, IRoundFeed} from "../../src/calls/CallsDeps.sol";
import {MarketHours} from "../../src/eth/MarketHours.sol";
import {MockStock, MockUsdg, MockStockVault, MockRoundFeed} from "./CallsMocks.sol";

/// Random depositors, buyers and weeks against one calls vault. Every call keeps to what a real user can do; time only
/// moves forward; the feed posts at the time of each move.
contract CallsHandler is Test {
    BorroCalls public calls;
    MockStock public stock;
    MockUsdg public usdg;
    MockStockVault public bv;
    MockRoundFeed public feed;

    address[4] public actors = [makeAddr("h alice"), makeAddr("h bob"), makeAddr("h carol"), makeAddr("h dan")];
    address[2] public buyers = [makeAddr("h buyer"), makeAddr("h buyer2")];
    address public donor = makeAddr("h donor");

    int256 public price = 230e8;
    uint256 public mon; // the Monday of the current week, 00:00 UTC (a summer week: New York is UTC-4)

    // ghosts
    uint256 public sharesIn; // Borro vault shares put in by depositors
    uint256 public sharesOut; // and taken out by depositors and option holders
    uint256 public donatedShares;
    uint256 public donatedUsdg;
    uint256 public premiumIn;
    uint256 public usdgOut; // premium collected and refunds
    uint256 public rounds;
    uint256 public itm;
    uint256 public voided;

    constructor(BorroCalls c, MockStock s, MockUsdg u, MockStockVault b, MockRoundFeed f, uint256 mon_) {
        calls = c;
        stock = s;
        usdg = u;
        bv = b;
        feed = f;
        mon = mon_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _post() internal {
        if (MarketHours.isOpen(block.timestamp)) feed.post(price);
    }

    function deposit(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1e9, 1_000e18);
        if (bv.convertToShares(amount) == 0) return;
        stock.mint(who, amount);
        vm.startPrank(who);
        stock.approve(address(calls), amount);
        uint256 before = bv.balanceOf(address(calls));
        calls.deposit(amount, who);
        sharesIn += bv.balanceOf(address(calls)) - before;
        vm.stopPrank();
    }

    function depositShares(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1e9, 1_000e18);
        stock.mint(who, amount);
        vm.startPrank(who);
        stock.approve(address(bv), amount);
        uint256 got = bv.deposit(amount, who);
        bv.approve(address(calls), got);
        calls.depositShares(got, who);
        sharesIn += got;
        vm.stopPrank();
    }

    function withdraw(uint256 seed, uint256 frac) external {
        address who = _actor(seed);
        if (calls.live()) return;
        uint256 s = Math.mulDiv(calls.balanceOf(who), bound(frac, 0, 100), 100);
        vm.prank(who);
        (uint256 v, uint256 u) = calls.withdraw(s, who, false);
        sharesOut += v;
        usdgOut += u;
    }

    function requestWithdraw(uint256 seed, uint256 frac) external {
        address who = _actor(seed);
        if (!calls.live()) return;
        uint256 s = Math.mulDiv(calls.balanceOf(who), bound(frac, 1, 100), 100);
        if (s == 0) return;
        vm.prank(who);
        calls.requestWithdraw(s);
    }

    function cancel(uint256 seed, bool dep) external {
        address who = _actor(seed);
        if (!calls.live()) return;
        if (dep) {
            (uint64 r, uint192 a) = calls.depositQueued(who);
            if (a == 0 || r != calls.currentRound()) return;
            vm.prank(who);
            uint256 v = calls.cancelDeposit();
            sharesOut += v;
        } else {
            (uint64 r, uint192 a) = calls.withdrawQueued(who);
            if (a == 0 || r != calls.currentRound()) return;
            vm.prank(who);
            calls.cancelWithdraw();
        }
    }

    function collect(uint256 seed) external {
        address who = _actor(seed);
        vm.prank(who);
        (uint256 v, uint256 u) = calls.collect(who, false);
        sharesOut += v;
        usdgOut += u;
    }

    function transfer(uint256 a, uint256 b, uint256 frac) external {
        address from = _actor(a);
        address to = _actor(b);
        uint256 s = Math.mulDiv(calls.balanceOf(from), bound(frac, 0, 100), 100);
        vm.prank(from);
        calls.transfer(to, s);
    }

    /// Next week's round: Monday 09:30 New York, the feed posting then.
    function start() external {
        if (calls.live()) return;
        while (mon + 13.5 hours <= block.timestamp) mon += 7 days;
        vm.warp(mon + 13.5 hours);
        feed.post(price);
        try calls.startRound() {
            rounds++;
        } catch {}
    }

    function buy(uint256 seed, uint256 amount, uint256 wait) external {
        if (!calls.live()) return;
        BorroCalls.Round memory r = calls.roundOf(calls.currentRound());
        uint256 t = r.startedAt + bound(wait, 0, r.auctionEnd - r.startedAt - 1);
        if (t > block.timestamp) vm.warp(t);
        if (block.timestamp >= r.auctionEnd) return;
        _post();
        amount = bound(amount, 1, r.capacity);
        try calls.quote(amount) returns (uint256 filled, uint256 cost) {
            if (cost < calls.MIN_COST() && r.sold + filled < r.capacity) return; // too small: the vault refuses it
            address b = buyers[seed % 2];
            usdg.mint(b, cost);
            vm.startPrank(b);
            usdg.approve(address(calls), cost);
            calls.buy(amount, cost, b);
            vm.stopPrank();
            premiumIn += cost;
        } catch {}
    }

    function move(int256 bps) external {
        bps = bound(bps, -1000, 1000);
        price = price * (10_000 + bps) / 10_000;
        _post();
    }

    /// Rent on the Borro vault: up to 1% of what it holds at a time (a real vault's rate is capped too).
    function rent(uint256 amount) external {
        bv.gain(bound(amount, 0, bv.totalAssets() / 100));
    }

    function donate(uint256 amount, bool shares) external {
        amount = bound(amount, 1, 1e18);
        if (shares) {
            stock.mint(donor, amount);
            vm.startPrank(donor);
            stock.approve(address(bv), amount);
            uint256 got = bv.deposit(amount, donor);
            bv.transfer(address(calls), got);
            vm.stopPrank();
            donatedShares += got;
        } else {
            usdg.mint(address(calls), amount);
            donatedUsdg += amount;
        }
    }

    /// Settle at a final price from 70% to 130% of the strike, posted Friday 19:00 New York; or, now and then, a round
    /// whose feed died and that is called off.
    function settle(uint256 seed) external {
        if (!calls.live()) return;
        BorroCalls.Round memory r = calls.roundOf(calls.currentRound());
        if (r.sold == 0) {
            if (block.timestamp < r.auctionEnd) vm.warp(r.auctionEnd);
            calls.settle(0);
            return;
        }
        if (seed % 9 == 0) {
            vm.warp(r.expiry + 31 days);
            calls.voidRound(0);
            voided++;
            return;
        }
        if (block.timestamp < r.expiry - 1 hours) vm.warp(r.expiry - 1 hours);
        price = int256(r.strike * bound(seed, 70, 130) / 100);
        uint80 hint;
        if (block.timestamp < r.expiry) {
            hint = feed.post(price);
        } else {
            hint = feed.latestId();
        }
        vm.warp(r.expiry + 1);
        try calls.settle(hint) {
            if (calls.roundOf(calls.currentRound()).owedShares != 0) itm++;
        } catch {
            vm.warp(r.expiry + 31 days);
            calls.voidRound(0);
            voided++;
        }
    }

    function exercise(uint256 seed, uint256 id) external {
        uint256 n = calls.currentRound();
        if (n == 0) return;
        id = bound(id, 1, n);
        address b = buyers[seed % 2];
        if (calls.optionsOf(id, b) == 0) return;
        BorroCalls.Round memory r = calls.roundOf(id);
        if (r.outcome != BorroCalls.Outcome.Settled && r.outcome != BorroCalls.Outcome.Void) return;
        vm.prank(b);
        (uint256 v, uint256 refund) = calls.exercise(id, b, false);
        sharesOut += v;
        usdgOut += refund;
    }

    /// Everyone takes everything out (between rounds): what the invariant suite checks at the end of a run.
    function everyoneLeaves() external {
        if (calls.live()) {
            this.settle(1);
        }
        for (uint256 id = 1; id <= calls.currentRound(); id++) {
            for (uint256 i; i < 2; i++) {
                if (calls.optionsOf(id, buyers[i]) == 0) continue;
                vm.prank(buyers[i]);
                (uint256 v, uint256 refund) = calls.exercise(id, buyers[i], false);
                sharesOut += v;
                usdgOut += refund;
            }
        }
        for (uint256 i; i < actors.length; i++) {
            vm.prank(actors[i]);
            (uint256 v, uint256 u) = calls.withdraw(type(uint256).max, actors[i], false);
            sharesOut += v;
            usdgOut += u;
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract BorroCallsInvariantTest is Test {
    CallsHandler h;
    BorroCalls calls;
    MockStockVault bv;
    MockUsdg usdg;
    address safe = makeAddr("safe");

    function setUp() public {
        uint256 mon = 1791763200; // Monday 2026-10-12
        vm.warp(mon + 1 hours);
        MockStock stock = new MockStock();
        usdg = new MockUsdg();
        bv = new MockStockVault(stock);
        MockRoundFeed feed = new MockRoundFeed();
        calls = new BorroCalls(
            stock,
            IStockVault(address(bv)),
            usdg,
            IRoundFeed(address(feed)),
            safe,
            BorroCalls.Params(500, 120, 13, 125, 10_000, 6 hours, 13.5 hours),
            "Borro NVDA Calls",
            "ccNVDA"
        );
        feed.post(230e8);
        h = new CallsHandler(calls, stock, usdg, bv, feed, mon);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](15);
        sel[0] = h.deposit.selector;
        sel[1] = h.depositShares.selector;
        sel[2] = h.withdraw.selector;
        sel[3] = h.requestWithdraw.selector;
        sel[4] = h.cancel.selector;
        sel[5] = h.collect.selector;
        sel[6] = h.transfer.selector;
        sel[7] = h.start.selector;
        sel[8] = h.buy.selector;
        sel[9] = h.move.selector;
        sel[10] = h.rent.selector;
        sel[11] = h.donate.selector;
        sel[12] = h.settle.selector;
        sel[13] = h.exercise.selector;
        sel[14] = h.start.selector; // weeks come round often
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// Every book is held: the vault's Borro vault shares cover what backs depositors, what waits to join, what is set
    /// aside for leavers and for option holders; its USDG covers premium and refunds owed.
    function invariant_the_books_are_held() public view {
        assertGe(bv.balanceOf(address(calls)), calls.active() + calls.pendingIn() + calls.leaving() + calls.forOptions());
        assertGe(usdg.balanceOf(address(calls)), calls.usdgOwed());
    }

    /// Nothing comes out that did not go in: Borro vault shares out never pass shares in plus donations; USDG out never
    /// passes what buyers paid.
    function invariant_nothing_is_made_from_nothing() public view {
        assertLe(h.sharesOut(), h.sharesIn());
        assertLe(h.usdgOut(), h.premiumIn());
    }

    /// The owner can take back at least every donation, and never a share of the books (checked above with the
    /// reclaimable view's own arithmetic).
    function invariant_the_owner_reaches_only_strays() public view {
        uint256 books = calls.active() + calls.pendingIn() + calls.leaving() + calls.forOptions();
        assertEq(calls.reclaimable(address(bv)), bv.balanceOf(address(calls)) - books);
        assertGe(calls.reclaimable(address(bv)), h.donatedShares());
        assertGe(calls.reclaimable(address(usdg)), h.donatedUsdg());
    }

    /// At the end of every run everyone takes everything out, and it all comes out: nothing is stuck but dust.
    function afterInvariant() external {
        // One line per run, so a run's coverage can be read back (script/out is the folder tests may write).
        vm.writeLine(
            "script/out/calls-invariant-tally.txt",
            string.concat("rounds ", vm.toString(h.rounds()), " itm ", vm.toString(h.itm()), " void ", vm.toString(h.voided()))
        );
        h.everyoneLeaves();
        uint256 books = calls.active() + calls.pendingIn() + calls.leaving() + calls.forOptions();
        assertEq(calls.pendingIn(), 0, "every queued deposit joined or was cancelled");
        assertLe(books, 1e3, "only rounding dust stays booked");
        assertEq(bv.balanceOf(address(calls)), books + h.donatedShares(), "the rest is exactly the donations");
        assertLe(calls.usdgOwed(), 1e3, "premium dust");
        assertEq(h.sharesIn(), h.sharesOut() + books, "every share put in came out, but dust");
    }
}
