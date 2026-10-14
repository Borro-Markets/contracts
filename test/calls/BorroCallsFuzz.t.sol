// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {CallsBase} from "./CallsBase.sol";

/// Fuzzed properties of the sale, the payout, the share price and the premium.
contract BorroCallsFuzzTest is CallsBase {
    /// The sale's price never rises with time, and stays between the floor and the start (both of the live price).
    function testFuzz_the_sale_price_only_falls_and_stays_in_its_band(uint256 a, uint256 b, uint256 amount) public {
        _deposit(alice, 1_000e18);
        _start();
        amount = bound(amount, 10e18, 1_000e18); // ten calls or more: at least $1 even at the floor
        a = bound(a, 0, 6 hours - 1);
        b = bound(b, a, 6 hours - 1);
        vm.warp(OPEN + a);
        (, uint256 ca) = calls.quote(amount);
        vm.warp(OPEN + b);
        (, uint256 cb) = calls.quote(amount);
        assertLe(cb, ca, "never rises");
        uint256 hi = Math.mulDiv(amount, uint256(P0) * 120, 1e4 * 1e20, Math.Rounding.Ceil);
        uint256 lo = Math.mulDiv(amount, uint256(P0) * 13, 1e4 * 1e20);
        assertLe(ca, hi, "at most the start");
        assertGe(cb, lo, "at least the floor");
    }

    /// Whatever the price at expiry, the vault's own rent or losses, and how much sold: the payout is set aside from the
    /// depositors' stock and never more than it; holders' claims add up to at most what was set aside; every book is
    /// covered by what the vault holds; the depositors keep the rest.
    function testFuzz_the_payout_is_always_covered(uint256 dep, uint256 sold, uint256 px, uint256 gain, uint256 loss)
        public
    {
        dep = bound(dep, 3e18, 1_000_000e18);
        _deposit(alice, dep);
        _start();
        sold = bound(sold, 3e18, dep); // every purchase at least a dollar
        _buy(buyer, sold / 3 + 1);
        _buy(buyer2, sold - sold / 3);
        // Rent, or a bad-debt loss in the Borro vault, during the week.
        gain = bound(gain, 0, dep / 10);
        loss = bound(loss, 0, dep / 2);
        bv.gain(gain);
        bv.lose(loss);
        px = bound(px, 1e8, 100_000e8);
        _expireAt(int256(px));
        BorroCalls.Round memory r = _round(1);
        uint256 activeAfter = calls.active();
        assertEq(activeAfter + r.owedShares, dep, "the payout came out of the depositors' shares");
        if (px <= r.strike) assertEq(r.owedShares, 0, "nothing at or under the strike");
        uint256 o1 = calls.optionsOf(1, buyer);
        uint256 o2 = calls.optionsOf(1, buyer2);
        assertLe(Math.mulDiv(o1, r.owedShares, r.sold) + Math.mulDiv(o2, r.owedShares, r.sold), r.owedShares);
        assertGe(bv.balanceOf(address(calls)), calls.active() + calls.forOptions());
        // Everyone leaves: nothing reverts and nothing is left but dust.
        vm.prank(buyer);
        calls.exercise(1, buyer, false);
        vm.prank(buyer2);
        calls.exercise(1, buyer2, false);
        vm.prank(alice);
        calls.withdraw(type(uint256).max, alice, false);
        assertLe(bv.balanceOf(address(calls)), 2, "dust");
        assertLe(usdg.balanceOf(address(calls)), 1, "premium dust");
    }

    /// In and out between rounds never returns more than was put in, and never takes from the others.
    function testFuzz_deposit_and_withdraw_never_gain(uint256 a, uint256 b, uint256 c, uint256 out) public {
        a = bound(a, 1, 1e30);
        b = bound(b, 1, 1e30);
        c = bound(c, 1, 1e30);
        _deposit(alice, a);
        _deposit(bob, b);
        uint256 cs = _deposit(carol, c);
        out = bound(out, 1, cs);
        vm.prank(carol);
        (uint256 got,) = calls.withdraw(out, carol, false);
        assertLe(got, c, "carol never gets more than she put in");
        vm.prank(carol);
        (uint256 rest,) = calls.withdraw(type(uint256).max, carol, false);
        assertLe(got + rest, c);
        vm.prank(alice);
        (uint256 ga,) = calls.withdraw(type(uint256).max, alice, false);
        vm.prank(bob);
        (uint256 gb,) = calls.withdraw(type(uint256).max, bob, false);
        assertGe(ga + 1, a, "alice is whole to the wei");
        assertGe(gb + 1, b, "bob is whole to the wei");
    }

    /// Premium paid out to depositors, however their shares moved and queued, never adds up to more than buyers paid.
    function testFuzz_premium_never_pays_out_more_than_buyers_paid(uint256 a, uint256 b, uint256 n, uint256 move, uint256 q)
        public
    {
        a = bound(a, 1e18, 1e27);
        b = bound(b, 1e18, 1e27);
        _deposit(alice, a);
        _deposit(bob, b);
        _start();
        // Carol joins during the round (no premium for her this round), Bob queues part of his shares out.
        _deposit(carol, a);
        q = bound(q, 0, calls.balanceOf(bob));
        if (q != 0) {
            vm.prank(bob);
            calls.requestWithdraw(q);
        }
        n = bound(n, 1e18, a + b); // every purchase at least a dollar
        (, uint256 cost) = _buy(buyer, n);
        move = bound(move, 0, calls.balanceOf(alice));
        vm.prank(alice);
        calls.transfer(bob, move);
        _expireAt(200e8);
        uint256 paid;
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 3; i++) {
            vm.prank(who[i]);
            (, uint256 u) = calls.collect(who[i], false);
            paid += u;
        }
        assertLe(paid, cost, "never more than was paid");
        assertGe(paid + 4, cost, "and all of it, less a wei each");
        assertGe(usdg.balanceOf(address(calls)), calls.usdgOwed());
    }
}
