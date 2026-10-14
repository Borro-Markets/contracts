// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {OptionsDesk, IShareVault, IPriceFeed} from "../src/OptionsDesk.sol";
import {OptTok, RateVault, RoundFeed, MockAggregator} from "./OptionsDesk.t.sol";

/// A phase aggregator whose reads are gated, as Ethereum mainnet's AccessControlledOffchainAggregator gates them
/// for any caller that is not the proxy and not tx.origin: `latestRound()` reverts "No access" for a contract.
contract GatedAggregator {
    function latestRound() external pure returns (uint256) {
        revert("No access");
    }
}

/// A buyer with code that answers the ERC-1155 receiver hook wrongly: the safe mint would have refused it.
contract RejectingBuyer {
    OptionsDesk immutable desk;

    constructor(OptionsDesk d, IERC20 usdg) {
        desk = d;
        usdg.approve(address(d), type(uint256).max);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }

    function buy(uint256 orderId, uint128 units) external {
        desk.fillAsk(orderId, units, type(uint128).max);
    }

    function claim(bytes32 id, uint256 units) external returns (uint256) {
        return desk.claim(id, units, false);
    }
}

/// Second adversarial review of OptionsDesk (2026-10-09), after the first review's fixes. `test_finding_*` reproduces
/// a gap as the contract stands (the fix each wants is in its comment); `test_confirmed_*` pins a rule that holds.
contract OptionsDeskReview2Test is Test {
    uint256 constant NOW = 1791817200; // Monday 2026-10-12 11:00 New York (15:00 UTC)
    uint64 constant EXP = 1792195200; // Friday 2026-10-16 20:00 EDT = 2026-10-17 00:00:00 UTC
    uint256 constant REOPEN = 1792368000; // Sunday 2026-10-18 20:00 EDT
    uint256 constant AGE = 2 days; // FEED_MAX_AGE
    uint80 constant P1 = uint80(1) << 64;
    uint80 constant P2 = uint80(2) << 64;
    int256 constant REF = 180e8;
    uint128 constant K = 185e8;
    uint128 constant TICK = 25_000_000;
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
    address dan = makeAddr("dan"); // writes from raw stock or USDG
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

    /// A filled call series at `strike`, one unit, so there is something to settle.
    function _series(uint128 strike) internal returns (bytes32 id) {
        id = _id(strike, true);
        _fill(bob, _ask(ann, strike, true, 1e18), 1e18);
    }

    // ================================================================ MEDIUM: a failed phase lookup accepts, not refuses

    /// FINDING 1 (medium). When the phase switched after expiry, the old phase's last round (printed at the close)
    /// proves by rule 1, and the new phase's first round (printed after expiry) is refused by rule 2 only because
    /// `_prevRoundTime` finds the old phase's last round through `phaseAggregators(phase-1).latestRound()`. When
    /// that lookup fails, `_prevRoundTime` answers zero, which rule 2 reads as "no round before it": the new
    /// phase's first round proves too, and the settler picks the price. Three ways the lookup fails: an aggregator
    /// that gates reads from contracts (mainnet's AccessControlledOffchainAggregator reverts "No access"), a proxy
    /// that names no aggregator for the phase, a proxy without `phaseAggregators`. On Robinhood Chain today the
    /// RHNVDA feed's phase-1 DualAggregator answers a contract, so this bites only at a later switch whose old
    /// aggregator does not. Fix: in `_prevRoundTime`, when `phase > 1` and the lookup fails (any `!ok`, a zero
    /// aggregator, a zero or oversize `latestRound`), revert WrongRound instead of returning 0: the series then
    /// settles on the old phase's close (rule 1) and, if the old phase is also stale, voids after VOID_AFTER. Two
    /// prices is worse than no price.
    function test_finding_a_failed_phase_lookup_lets_the_settler_choose_the_price() public {
        feed.set(P1 | 10, 180e8, EXP - 1 hours); // the close, in the old phase
        feed.set(P2 | 1, 200e8, EXP + 1 hours); // the new phase's first print, after expiry
        feed.setLatest(P2 | 1);
        bytes32 a = _series(K);
        bytes32 b = _series(K + TICK);
        bytes32 c = _series(K + 2 * TICK);
        bytes32 d = _series(K + 3 * TICK);
        bytes32 e = _series(K + 4 * TICK);
        vm.warp(REOPEN);

        // With the lookup working, one price: the close.
        MockAggregator agg = new MockAggregator();
        agg.set(10);
        feed.setPhaseAggregator(1, address(agg));
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P2 | 1);
        desk.settle(a, P1 | 10);
        assertEq(desk.seriesOf(a).settlePrice, 180e8);

        // (i) The old aggregator gates reads from contracts: both rounds prove.
        feed.setPhaseAggregator(1, address(new GatedAggregator()));
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P2 | 1); // a lookup that fails is a failed proof
        desk.settle(c, P1 | 10);
        assertFalse(desk.seriesOf(b).settled, "not settled at the Monday print");
        assertEq(desk.seriesOf(c).settlePrice, 180e8, "only the close proves");

        // (ii) The proxy names no aggregator for the old phase.
        feed.setPhaseAggregator(1, address(0));
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(d, P2 | 1);
        assertFalse(desk.seriesOf(d).settled);

        // (iii) The proxy has no `phaseAggregators` at all.
        vm.mockCallRevert(address(feed), abi.encodeWithSelector(IPriceFeed.phaseAggregators.selector, uint16(1)), "");
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(e, P2 | 1);
        assertFalse(desk.seriesOf(e).settled);
    }

    // ================================================================ LOW: the first second of expiry is a race

    /// FINDING 2 (low). `settle` opens at `block.timestamp == expiry`, and a round printed in that same second is
    /// "at or before expiry" by the contract's own rule. A settle that lands before the feed's print in the expiry
    /// second fixes the price on the round before it, and an identical series settled a block later gets the other
    /// price. Robinhood Chain stamps many blocks with one second, and the feed prints on deviation, so the window is
    /// real though narrow. Fix: `if (block.timestamp <= sr.expiry) revert NotExpired();` (settle from expiry + 1).
    function test_finding_settling_in_the_expiry_second_races_a_print_in_that_second() public {
        feed.set(P1 | 10, 180e8, EXP - 1 hours);
        bytes32 a = _series(K);
        bytes32 b = _series(K + TICK);
        vm.warp(EXP);
        vm.expectRevert(OptionsDesk.NotExpired.selector);
        desk.settle(a, P1 | 10); // the expiry second itself is closed to settlement
        vm.warp(EXP + 1);
        desk.settle(a, P1 | 10);
        feed.set(P1 | 11, 190e8, EXP); // the feed prints in a later block with the same timestamp
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P1 | 10); // R10 is no longer the last round at or before expiry
        desk.settle(b, P1 | 11);
        assertEq(desk.seriesOf(a).settlePrice, 180e8);
        assertEq(desk.seriesOf(b).settlePrice, 190e8, "two prices for one expiry, chosen by the settler's block");
    }

    // ================================================================ LOW: LockShort's slack floors to zero

    /// FINDING 3 (low). LOCK_SLACK_PPM gives a fill `need / 1e6` of slack, which is zero whenever the fill needs
    /// less than 1 USDG (a put) and small for a few USDG, while the rounding between post and fill loses up to two
    /// base units: the pro-rata share floors, `convertToAssets` floors, and the partial fill's need rounds up where
    /// the whole ask's need did not. A partial fill of 1e15 + 1 units of a $185 put needs 185001 and the moved lock
    /// converts to 185000: refused as LockShort on a healthy vault. A `postAskWithUsdg` ask deposits at the vault's
    /// floor too, so under interest even a whole fill can fall one unit short. Fix: an absolute floor on the slack,
    /// `uint256 slack = need * LOCK_SLACK_PPM / 1e6; if (slack < 3) slack = 3;` (three base units: 3e-6 USDG or
    /// 3 wei of stock, far below anything a real vault loss costs; the fuzz below bounds the rounding at 2).
    function test_finding_lock_short_refuses_a_rounding_shortfall_on_a_healthy_vault() public {
        feed.set(P1 | 9, REF, NOW - 1 hours);
        uint256 putAsk = _ask(carl, K, false, 10e18);
        uint256 locked = desk.orderOf(putAsk).locked;
        uint128 units = MIN + 1;
        uint256 moved = locked * units / 10e18;
        uint256 need = (uint256(units) * K + 1e20 - 1) / 1e20;
        assertEq(need, 185001);
        assertEq(usdgVault.convertToAssets(moved), 185000, "one base unit short by rounding alone");
        assertEq(need / 1e6, 0, "the proportional slack is zero: the three-unit floor carries it");
        _fill(bob, putAsk, units);
        assertEq(desk.balanceOf(bob, uint256(desk.seriesIdOf(address(feed), EXP, K, false))), units, "filled on a healthy vault");
        // The same ask fills for a round number of units.
        _fill(bob, putAsk, MIN);

        // A USDG-funded put ask under interest: the deposit floors, and a whole fill can come up one unit short.
        usdgVault.accrue(123_456_789); // the vault earned, so a share is worth an odd amount
        vm.prank(dan);
        uint256 small = desk.postAskWithUsdg(address(feed), EXP, K, 3e15 + 1, PREM);
        uint256 have = usdgVault.convertToAssets(desk.orderOf(small).locked);
        uint256 needAll = (uint256(3e15 + 1) * K + 1e20 - 1) / 1e20;
        assertLt(have, needAll, "the lock converts to less than the ask needs");
        assertLe(needAll - have, 2, "by rounding only");
        _fill(bob, small, 3e15 + 1);
        assertEq(desk.orderOf(small).maker, address(0), "filled whole");
    }

    /// The rounding shortfall between a healthy post and a healthy fill is at most two base units, with or without
    /// interest (up to the vault tripling, far past any real rate; a Steakhouse share is worth about 1e-12 USDG, so
    /// a share's floor costs well under a unit), on both funding paths; LockShort fires only when the slack cannot
    /// absorb it. (Bounds the fix above.)
    function testFuzz_lock_short_rounding_is_at_most_two_units(uint128 total, uint128 part, uint64 ticks, uint64 earn, bool byUsdg)
        public
    {
        total = uint128(bound(total, 2 * MIN, 1_000e18));
        part = uint128(bound(part, MIN, total - MIN));
        uint128 strike = uint128(bound(ticks, 1, 40_000)) * TICK; // $0.25 to $10,000
        feed.set(P1 | 9, REF, NOW - 1 hours);
        if (earn != 0) usdgVault.accrue(bound(earn, 1, 20_000_000e6));
        uint256 askId;
        if (byUsdg) {
            vm.prank(dan);
            askId = desk.postAskWithUsdg(address(feed), EXP, strike, total, PREM);
        } else {
            askId = _ask(carl, strike, false, total);
        }
        uint256 moved = uint256(desk.orderOf(askId).locked) * part / total;
        uint256 need = (uint256(part) * strike + 1e20 - 1) / 1e20;
        uint256 have = usdgVault.convertToAssets(moved);
        uint256 short = have < need ? need - have : 0;
        assertLe(short, 2, "rounding never costs more than two base units");
        uint256 slack = need / 1e6;
        if (slack < 3) slack = 3;
        vm.prank(bob);
        if (have + slack < need) {
            vm.expectRevert(OptionsDesk.LockShort.selector);
            desk.fillAsk(askId, part, type(uint128).max);
        } else {
            desk.fillAsk(askId, part, type(uint128).max);
        }
    }

    /// A truly short lock is still refused with the slack floored at three units: a loss of one part in ten
    /// thousand on a $185 put of 10 units is 185 base units short, far past any rounding.
    function test_confirmed_lock_short_still_catches_a_real_loss() public {
        feed.set(P1 | 9, REF, NOW - 1 hours);
        uint256 putAsk = _ask(carl, K, false, 10e18);
        usdgVault.lose(1_000e6); // 0.01% of the vault
        uint256 have = usdgVault.convertToAssets(desk.orderOf(putAsk).locked);
        assertGt(1850e6 - have, 100, "well past three units");
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.LockShort.selector);
        desk.fillAsk(putAsk, 10e18, type(uint128).max);
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.LockShort.selector);
        desk.fillAsk(putAsk, 1e18, type(uint128).max);
    }

    // ================================================================ LOW: void beats a settle that still proves

    /// FINDING 4 (low, documented). `void` checks only the clock, so VOID_AFTER past expiry it closes a series whose
    /// round still proves, and a writer who owes a payout can send it in the block before a settle. The long had 14
    /// days to settle itself, so this is a liveness assumption, not a theft; it is stated in the contract notes.
    /// Possible tightening, if wanted: void only when the feed's latest print is older than expiry - FEED_MAX_AGE
    /// (the feed stopped before the window, so nothing can ever prove), with the unconditional void kept behind a
    /// longer wait for the phase dead ends. After a void: claims burn and pay zero, releases return the whole lock.
    function test_finding_void_closes_a_series_whose_round_still_proves() public {
        feed.set(P1 | 10, 200e8, EXP - 1 hours); // in the money for the call by $15
        bytes32 cid = _series(K);
        uint256 lock = desk.seriesOf(cid).lockedShares;
        vm.warp(EXP + 14 days);
        vm.prank(ann); // the writer, who would owe 15/200 of a share
        desk.void(cid);
        vm.expectRevert(OptionsDesk.AlreadySettled.selector);
        desk.settle(cid, P1 | 10);
        OptionsDesk.Series memory s = desk.seriesOf(cid);
        assertTrue(s.settled);
        assertEq(s.settlePrice, 0);
        assertEq(s.payoutSharesPerUnit, 0);
        vm.prank(bob);
        assertEq(desk.claim(cid, 1e18, false), 0, "the long is paid nothing");
        assertEq(desk.balanceOf(bob, uint256(cid)), 0, "and its tokens are burned");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 0, 1, uint256(cid)));
        desk.claim(cid, 1, false);
        vm.prank(ann);
        assertEq(desk.release(cid), lock, "the writer takes the whole lock");
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.AlreadyReleased.selector);
        desk.release(cid);
        assertEq(vault.balanceOf(address(desk)), 0);
        vm.expectRevert(OptionsDesk.AlreadySettled.selector);
        desk.void(cid);
    }

    // ================================================================ confirmed: the proof's edges

    /// A round printed in the expiry second is the close; a round printed exactly FEED_MAX_AGE before expiry is not,
    /// and the first print after expiry proves instead; one second inside the window proves by rule 1.
    function test_confirmed_rounds_exactly_at_the_boundaries() public {
        bytes32 a = _series(K);
        bytes32 b = _series(K + TICK);
        bytes32 c = _series(K + 2 * TICK);

        // Exactly at expiry.
        feed.set(P1 | 10, 180e8, EXP - 1 hours);
        feed.set(P1 | 11, 181e8, EXP);
        feed.set(P1 | 12, 182e8, REOPEN);
        vm.warp(REOPEN + 1);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P1 | 10);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P1 | 12);
        desk.settle(a, P1 | 11);
        assertEq(desk.seriesOf(a).settlePrice, 181e8);

        // Exactly FEED_MAX_AGE before expiry: not the close; the first print after is the price. (Fresh round ids:
        // a hole in the ids would read as "no round before", which real aggregators never produce: the RHNVDA
        // feed's 1203 rounds have none.)
        feed.set(P1 | 20, 180e8, EXP - AGE);
        feed.set(P1 | 21, 182e8, REOPEN);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P1 | 20);
        desk.settle(b, P1 | 21);
        assertEq(desk.seriesOf(b).settlePrice, 182e8);

        // One second inside the window: the close, and the first print after is refused.
        feed.set(P1 | 30, 180e8, EXP - AGE + 1);
        feed.set(P1 | 31, 182e8, REOPEN);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(c, P1 | 31);
        desk.settle(c, P1 | 30);
        assertEq(desk.seriesOf(c).settlePrice, 180e8);
    }

    /// Two rounds in one second: before expiry only the later one proves; after expiry only the earlier one.
    function test_confirmed_two_rounds_in_one_second_prove_once() public {
        bytes32 a = _series(K);
        bytes32 b = _series(K + TICK);
        feed.set(P1 | 10, 180e8, EXP - 1 hours);
        feed.set(P1 | 11, 181e8, EXP - 1 hours);
        feed.set(P1 | 12, 190e8, REOPEN);
        feed.set(P1 | 13, 191e8, REOPEN);
        vm.warp(REOPEN + 1);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P1 | 10);
        desk.settle(a, P1 | 11);
        assertEq(desk.seriesOf(a).settlePrice, 181e8);

        // The window is empty: the first print after expiry, and not its twin.
        feed.set(P1 | 10, 180e8, EXP - 3 days);
        feed.set(P1 | 11, 181e8, EXP - 3 days);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P1 | 11);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P1 | 13);
        desk.settle(b, P1 | 12);
        assertEq(desk.seriesOf(b).settlePrice, 190e8);
    }

    /// The latest phase began before expiry: only its rounds prove, by the ordinary rules, however the old
    /// aggregator keeps printing; and when it began after expiry, the old phase's last print proves and nothing
    /// else does, including the old aggregator's own later prints.
    function test_confirmed_a_phase_that_began_before_expiry_is_the_only_phase() public {
        bytes32 a = _series(K);
        bytes32 b = _series(K + TICK);
        MockAggregator agg = new MockAggregator();
        feed.setPhaseAggregator(1, address(agg));
        agg.set(12);
        feed.set(P1 | 10, 180e8, EXP - 2 hours);
        feed.set(P1 | 11, 180e8, EXP - 30 minutes); // the old aggregator's close, later than the new phase's
        feed.set(P1 | 12, 180e8, REOPEN + 10);
        feed.set(P2 | 1, 185e8, EXP - 3 days); // the new phase began Tuesday
        feed.set(P2 | 2, 190e8, EXP - 1 hours);
        feed.set(P2 | 3, 195e8, REOPEN + 30);
        feed.setLatest(P2 | 3);
        vm.warp(REOPEN + 60);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P1 | 11);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P1 | 12);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P2 | 1);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P2 | 3);
        desk.settle(a, P2 | 2);
        assertEq(desk.seriesOf(a).settlePrice, 190e8);

        // The new phase's first round after expiry, with the old aggregator still printing after it.
        feed.set(P2 | 1, 185e8, EXP + 5 minutes);
        feed.set(P2 | 2, 190e8, REOPEN + 20);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P2 | 1); // the old phase's last round (12) printed after expiry, so not stale
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P2 | 2);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P1 | 12); // the round before it is the close
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(b, P1 | 10); // a later round of its phase printed before expiry
        desk.settle(b, P1 | 11);
        assertEq(desk.seriesOf(b).settlePrice, 180e8);
    }

    /// Two phase switches after one expiry leave nothing provable: the old close is two phases back, and each new
    /// phase's first round has a recent round before it. The 14-day void is the only exit. Noted, not fixed: a
    /// double switch inside two weeks is not a realistic feed operation.
    function test_confirmed_two_phase_switches_after_expiry_end_in_a_void() public {
        bytes32 a = _series(K);
        MockAggregator agg1 = new MockAggregator();
        MockAggregator agg2 = new MockAggregator();
        feed.setPhaseAggregator(1, address(agg1));
        feed.setPhaseAggregator(2, address(agg2));
        agg1.set(10);
        agg2.set(1);
        feed.set(P1 | 10, 180e8, EXP - 1 hours);
        feed.set(P2 | 1, 181e8, EXP + 1 days);
        feed.set((uint80(3) << 64) | 1, 182e8, EXP + 2 days);
        feed.setLatest((uint80(3) << 64) | 1);
        vm.warp(EXP + 3 days);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P1 | 10);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, P2 | 1);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(a, (uint80(3) << 64) | 1);
        vm.warp(EXP + 14 days);
        desk.void(a);
    }

    // ================================================================ confirmed: the fee snapshot on bids

    /// A bid carries the fee it was posted under through every partial fill; `minPremium` is the writer's net.
    function test_confirmed_fee_snapshot_holds_across_partial_bid_fills() public {
        feed.set(P1 | 9, REF, NOW - 1 hours);
        vm.prank(bob);
        uint256 bid = desk.postBid(address(feed), EXP, K, true, 4e18, PREM); // 8 USDG locked at 10%
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        desk.setFee(2000, treasury); // raised, and a new recipient
        uint256 annBefore = usdg.balanceOf(ann);
        vm.prank(ann);
        vm.expectRevert(abi.encodeWithSelector(OptionsDesk.TooLittle.selector, 18e5, 18e5 + 1));
        desk.fillBid(bid, 1e18, 18e5 + 1);
        vm.prank(ann);
        desk.fillBid(bid, 1e18, 18e5);
        assertEq(usdg.balanceOf(ann) - annBefore, 18e5, "nets 90% as posted");
        assertEq(usdg.balanceOf(treasury), 2e5, "the fee goes to the recipient of the day");
        assertEq(desk.orderOf(bid).feeBps, 1000);
        assertEq(desk.orderOf(bid).locked, 6e6);
        vm.prank(owner);
        desk.setFee(0, keeper);
        vm.prank(dan);
        desk.fillBidWithStock(bid, 3e18, 54e5); // the rest, still at 10%
        assertEq(usdg.balanceOf(treasury), 2e5);
        assertEq(usdg.balanceOf(keeper), 6e5);
        assertEq(desk.orderOf(bid).maker, address(0), "consumed, nothing left behind");
        assertEq(usdg.balanceOf(address(desk)), 0);
    }

    // ================================================================ confirmed: the hook-free mint

    /// A long is credited to any buyer with code, even one that answers the receiver hook wrongly; the balances
    /// add up to the series' open units; transfers still run the acceptance check, so a long cannot be pushed into
    /// the desk or into a rejecting contract. A contract that cannot call out holds a long it cannot move or claim:
    /// its own limitation, and the writer's lock is unaffected (released after settlement less what it owes).
    function test_confirmed_hook_free_mint_credits_any_buyer_and_keeps_transfers_safe() public {
        feed.set(P1 | 9, REF, NOW - 1 hours);
        bytes32 cid = _id(K, true);
        RejectingBuyer rej = new RejectingBuyer(desk, usdg);
        usdg.mint(address(rej), 100e6);
        uint256 ask = _ask(ann, K, true, 3e18);
        vm.expectEmit(true, true, true, true, address(desk));
        emit TransferSingle(address(rej), address(0), address(rej), uint256(cid), 1e18);
        rej.buy(ask, 1e18);
        assertEq(desk.balanceOf(address(rej), uint256(cid)), 1e18, "credited despite the wrong hook answer");

        // A contract bid maker is filled the same way.
        address maker = address(new RejectingBuyer(desk, usdg));
        usdg.mint(maker, 100e6);
        vm.prank(maker);
        uint256 bid = desk.postBid(address(feed), EXP, K, true, 1e18, PREM);
        vm.prank(ann);
        desk.fillBid(bid, 1e18, 0);
        assertEq(desk.balanceOf(maker, uint256(cid)), 1e18);
        _fill(bob, ask, 2e18); // the rest of the ask
        assertEq(
            desk.balanceOf(address(rej), uint256(cid)) + desk.balanceOf(maker, uint256(cid)) + desk.balanceOf(bob, uint256(cid)),
            desk.seriesOf(cid).openUnits,
            "balances add up to the open units"
        );

        // Transfers keep the acceptance check: into the desk, or into a rejecting contract, refused.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(desk)));
        desk.safeTransferFrom(bob, address(desk), uint256(cid), 1e18, "");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(rej)));
        desk.safeTransferFrom(bob, address(rej), uint256(cid), 1e18, "");

        // Settlement: the rejecting buyer claims through its own call; the stuck maker's share stays in the desk
        // until it finds a way to call, and Ann's release is unaffected.
        feed.set(P1 | 10, 200e8, EXP - 1 hours);
        vm.warp(EXP + 1);
        desk.settle(cid, P1 | 10);
        uint256 per = desk.seriesOf(cid).payoutSharesPerUnit;
        assertEq(rej.claim(cid, 1e18), per);
        vm.prank(ann);
        uint256 back = desk.release(cid);
        assertEq(back, desk.writtenOf(ann, cid).lockedShares - 4 * per);
        assertEq(vault.balanceOf(address(desk)), 3 * per, "three unclaimed units' payouts wait for their holders");
    }

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
}
