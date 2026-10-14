// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {BorroLock} from "../src/BorroLock.sol";
import {WatchedCoin} from "./WatchedCoin.sol";

/// A token that keeps a cut of every transfer (feeBps 10000 keeps all of it), to show lock() counts what arrived.
contract CutCoin is ERC20 {
    uint256 public feeBps;

    constructor(uint256 feeBps_) ERC20("CUT", "CUT") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 cut = (value * feeBps) / 10000;
        super._update(from, address(0xdead), cut);
        super._update(from, to, value - cut);
    }
}

/// Times are read with vm.getBlockTimestamp(): under via_ir the compiler may treat block.timestamp as fixed for the
/// whole test and read it after a later vm.warp.
contract BorroLockBase is Test {
    uint256 constant T0 = 1_800_000_000;
    uint256 constant M1 = 30 days;
    uint256 constant M3 = 91 days;
    uint256 constant M6 = 182 days;
    uint256 constant M12 = 365 days;

    WatchedCoin coin;
    BorroLock lk;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address eve = makeAddr("eve");
    address straysTo = makeAddr("hoardSafe"); // where skim() sends what is nobody's lock

    function setUp() public virtual {
        vm.warp(T0);
        coin = new WatchedCoin();
        lk = new BorroLock(IERC20(address(coin)), straysTo);
        coin.watch(address(lk));
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            coin.mint(who[i], 10_000_000e18);
            vm.prank(who[i]);
            coin.approve(address(lk), type(uint256).max);
        }
    }

    function now_() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function lockOf(address a) internal view returns (uint256 amount, uint256 unlockAt) {
        return lk.lockOf(a);
    }
}

contract BorroLockTest is BorroLockBase {
    // ------------------------------------------------------------------ set up

    function test_starts_empty_with_four_lengths() public view {
        assertEq(address(lk.token()), address(coin));
        assertEq(lk.strays(), straysTo);
        assertEq(lk.totalLocked(), 0);
        assertEq(lk.durationOf(0), 30 days);
        assertEq(lk.durationOf(1), 91 days);
        assertEq(lk.durationOf(2), 182 days);
        assertEq(lk.durationOf(3), 365 days);
        (uint256 a, uint256 u) = lockOf(alice);
        assertEq(a, 0);
        assertEq(u, 0);
    }

    /// Deploys through an external call, so vm.expectRevert sees the constructor's revert as the call's.
    function newLock(IERC20 t, address strays_) external returns (BorroLock) {
        return new BorroLock(t, strays_);
    }

    function test_constructor_refusals() public {
        vm.expectRevert(BorroLock.ZeroAddress.selector);
        this.newLock(IERC20(address(0)), straysTo);
        vm.expectRevert(BorroLock.ZeroAddress.selector);
        this.newLock(IERC20(address(coin)), address(0));
        BorroLock ok = this.newLock(IERC20(address(coin)), straysTo);
        assertEq(ok.strays(), straysTo);
    }

    function testFuzz_any_other_length_is_refused(uint8 choice) public {
        choice = uint8(bound(choice, 4, 255));
        vm.expectRevert(BorroLock.BadDuration.selector);
        lk.durationOf(choice);
        vm.prank(alice);
        vm.expectRevert(BorroLock.BadDuration.selector);
        lk.lock(1e18, choice);
        vm.prank(alice);
        lk.lock(1e18, 0);
        vm.prank(alice);
        vm.expectRevert(BorroLock.BadDuration.selector);
        lk.extend(choice);
    }

    // ------------------------------------------------------------------ lock()

    function test_lock_records_emits_and_takes_exactly_the_amount() public {
        uint256 u = T0 + M3;
        vm.expectEmit(address(lk));
        emit BorroLock.LockChanged(alice, 1_000e18, u);
        vm.prank(alice);
        assertEq(lk.lock(1_000e18, 1), u);
        (uint256 a, uint256 ul) = lockOf(alice);
        assertEq(a, 1_000e18);
        assertEq(ul, u);
        assertEq(lk.totalLocked(), 1_000e18);
        assertEq(coin.balanceOf(address(lk)), 1_000e18);
        assertEq(coin.balanceOf(alice), 10_000_000e18 - 1_000e18);
        // Locks are per address.
        (a, ul) = lockOf(bob);
        assertEq(a + ul, 0);
    }

    function test_lock_refusals() public {
        vm.prank(alice);
        vm.expectRevert(BorroLock.ZeroAmount.selector);
        lk.lock(0, 0);
        coin.mint(eve, 5e18);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(lk), 0, 1e18));
        lk.lock(1e18, 0);
        vm.prank(eve);
        coin.approve(address(lk), type(uint256).max);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, eve, 5e18, 6e18));
        lk.lock(6e18, 0);
        assertEq(lk.totalLocked(), 0);
    }

    function test_locking_more_never_shortens() public {
        vm.prank(alice);
        uint256 u1 = lk.lock(100e18, 3);
        assertEq(u1, T0 + M12);
        // A shorter length on top keeps the later unlock.
        vm.warp(T0 + 10 days);
        vm.prank(alice);
        assertEq(lk.lock(50e18, 0), u1);
        (uint256 a, uint256 u) = lockOf(alice);
        assertEq(a, 150e18);
        assertEq(u, u1);
        // A longer one moves the whole lock out.
        vm.warp(T0 + 20 days);
        vm.prank(alice);
        assertEq(lk.lock(1e18, 3), T0 + 20 days + M12);
        (a, u) = lockOf(alice);
        assertEq(a, 151e18);
        assertEq(u, T0 + 20 days + M12);
        assertEq(lk.totalLocked(), 151e18);
    }

    function test_locking_more_after_the_unlock_locks_the_whole_again() public {
        vm.prank(alice);
        lk.lock(100e18, 0);
        vm.warp(T0 + 40 days); // unlocked, not withdrawn
        vm.prank(alice);
        uint256 u = lk.lock(1e18, 0);
        assertEq(u, T0 + 40 days + M1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorroLock.StillLocked.selector, u));
        lk.withdraw();
    }

    function test_counts_what_arrived() public {
        CutCoin cut = new CutCoin(100); // 1%
        BorroLock l2 = new BorroLock(IERC20(address(cut)), straysTo);
        cut.mint(alice, 100e18);
        vm.startPrank(alice);
        cut.approve(address(l2), type(uint256).max);
        l2.lock(100e18, 0);
        (uint256 a,) = l2.lockOf(alice);
        assertEq(a, 99e18);
        assertEq(l2.totalLocked(), 99e18);
        vm.warp(T0 + M1);
        assertEq(l2.withdraw(), 99e18);
        assertEq(l2.totalLocked(), 0);
        vm.stopPrank();
        // A token that delivers nothing: refused.
        CutCoin all = new CutCoin(10000);
        BorroLock l3 = new BorroLock(IERC20(address(all)), straysTo);
        all.mint(alice, 1e18);
        vm.startPrank(alice);
        all.approve(address(l3), type(uint256).max);
        vm.expectRevert(BorroLock.ZeroAmount.selector);
        l3.lock(1e18, 0);
        vm.stopPrank();
    }

    function test_too_much_for_one_lock() public {
        coin.mint(alice, type(uint128).max);
        vm.prank(alice);
        lk.lock(type(uint128).max, 0);
        vm.prank(alice);
        vm.expectRevert(BorroLock.TooMuch.selector);
        lk.lock(1, 0);
        (uint256 a,) = lockOf(alice);
        assertEq(a, type(uint128).max);
    }

    // ------------------------------------------------------------------ extend()

    function test_extend_only_lengthens() public {
        vm.prank(alice);
        vm.expectRevert(BorroLock.NoLock.selector);
        lk.extend(0);
        vm.prank(alice);
        uint256 u = lk.lock(100e18, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorroLock.NotLonger.selector, u, T0 + M1));
        lk.extend(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorroLock.NotLonger.selector, u, u)); // the same is not longer
        lk.extend(1);
        vm.warp(T0 + 1);
        vm.expectEmit(address(lk));
        emit BorroLock.LockChanged(alice, 100e18, T0 + 1 + M3);
        vm.prank(alice);
        assertEq(lk.extend(1), T0 + 1 + M3);
        vm.prank(alice);
        assertEq(lk.extend(3), T0 + 1 + M12);
        (uint256 a, uint256 ul) = lockOf(alice);
        assertEq(a, 100e18);
        assertEq(ul, T0 + 1 + M12);
        assertEq(lk.totalLocked(), 100e18);
        assertEq(coin.balanceOf(address(lk)), 100e18);
        // After a withdrawal there is nothing to extend.
        vm.warp(T0 + 1 + M12);
        vm.prank(alice);
        lk.withdraw();
        vm.prank(alice);
        vm.expectRevert(BorroLock.NoLock.selector);
        lk.extend(3);
    }

    // ------------------------------------------------------------------ withdraw()

    function test_withdraw_only_at_or_after_the_unlock() public {
        vm.prank(alice);
        uint256 u = lk.lock(500e18, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorroLock.StillLocked.selector, u));
        lk.withdraw();
        vm.warp(u - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BorroLock.StillLocked.selector, u));
        lk.withdraw();
        vm.warp(u);
        uint256 before = coin.balanceOf(alice);
        vm.expectEmit(address(lk));
        emit BorroLock.LockChanged(alice, 0, 0);
        vm.expectEmit(address(lk));
        emit BorroLock.Withdrawn(alice, 500e18);
        vm.prank(alice);
        assertEq(lk.withdraw(), 500e18);
        assertEq(coin.balanceOf(alice), before + 500e18);
        (uint256 a, uint256 ul) = lockOf(alice);
        assertEq(a + ul, 0);
        assertEq(lk.totalLocked(), 0);
        assertEq(coin.balanceOf(address(lk)), 0);
        vm.prank(alice);
        vm.expectRevert(BorroLock.NoLock.selector);
        lk.withdraw();
        // Long after the unlock it still works.
        vm.prank(bob);
        uint256 ub = lk.lock(7e18, 3);
        vm.warp(ub + 10 * 365 days);
        vm.prank(bob);
        assertEq(lk.withdraw(), 7e18);
    }

    function test_only_the_locker_moves_a_lock() public {
        vm.prank(alice);
        uint256 ua = lk.lock(100e18, 0);
        vm.prank(bob);
        uint256 ub = lk.lock(5e18, 3);
        vm.warp(ua);
        // Bob's withdraw is his own lock, still locked; it never reaches alice's.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BorroLock.StillLocked.selector, ub));
        lk.withdraw();
        // Eve has none.
        vm.prank(eve);
        vm.expectRevert(BorroLock.NoLock.selector);
        lk.withdraw();
        // Nobody can pull the lock's tokens through the token: it approves no one.
        assertEq(coin.allowance(address(lk), eve), 0);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, eve, 0, 1));
        coin.transferFrom(address(lk), eve, 1);
        // Alice takes exactly hers, to herself.
        vm.prank(alice);
        assertEq(lk.withdraw(), 100e18);
        assertEq(coin.paidToCount(), 1);
        assertEq(coin.paidTo(0), alice);
        assertEq(coin.balanceOf(address(lk)), 5e18);
        assertEq(lk.totalLocked(), 5e18);
    }

    // ------------------------------------------------------------------ skim()

    /// $BORRO sent here outside lock() is nobody's lock: no withdraw reaches it, and anyone's skim() sends exactly it
    /// to the strays address, never a locked token.
    function test_skim_sends_exactly_the_stray_excess() public {
        vm.prank(alice);
        uint256 ua = lk.lock(10e18, 0);
        vm.prank(bob);
        lk.lock(3e18, 3);
        coin.mint(eve, 5e18);
        vm.prank(eve);
        coin.transfer(address(lk), 5e18);
        assertEq(lk.totalLocked(), 13e18);
        vm.prank(eve);
        vm.expectRevert(BorroLock.NoLock.selector);
        lk.withdraw();
        vm.expectEmit(address(lk));
        emit BorroLock.Skimmed(straysTo, 5e18);
        vm.prank(eve);
        assertEq(lk.skim(), 5e18);
        assertEq(coin.balanceOf(straysTo), 5e18);
        assertEq(coin.balanceOf(eve), 0, "the caller gets nothing");
        assertEq(coin.balanceOf(address(lk)), 13e18);
        assertEq(lk.totalLocked(), 13e18);
        (uint256 a, uint256 u) = lockOf(alice);
        assertEq(a, 10e18);
        assertEq(u, ua);
        (a,) = lockOf(bob);
        assertEq(a, 3e18);
        // Again: nothing left beyond the locks.
        vm.recordLogs();
        assertEq(lk.skim(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        // The locks still pay exactly.
        vm.warp(ua);
        vm.prank(alice);
        assertEq(lk.withdraw(), 10e18);
        assertEq(coin.balanceOf(address(lk)), 3e18);
    }

    function test_skim_with_no_excess_sends_nothing() public {
        vm.recordLogs();
        assertEq(lk.skim(), 0); // nothing held at all
        vm.prank(alice);
        lk.lock(100e18, 1);
        vm.prank(bob);
        assertEq(lk.skim(), 0); // everything held is locked
        assertEq(coin.balanceOf(straysTo), 0);
        assertEq(coin.balanceOf(address(lk)), 100e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) assertTrue(logs[i].topics[0] != BorroLock.Skimmed.selector, "no Skimmed");
    }

    /// Strays sitting here before and between locks change nothing: a lock counts only what it brought, and a
    /// withdrawal pays exactly the lock.
    function test_lock_and_withdraw_stay_exact_with_strays_present() public {
        coin.mint(eve, 20e18);
        vm.prank(eve);
        coin.transfer(address(lk), 7e18);
        vm.prank(alice);
        uint256 u = lk.lock(100e18, 0);
        (uint256 a,) = lockOf(alice);
        assertEq(a, 100e18, "only what the lock brought");
        assertEq(lk.totalLocked(), 100e18);
        vm.prank(eve);
        coin.transfer(address(lk), 13e18);
        vm.prank(alice);
        lk.lock(1e18, 0);
        (a,) = lockOf(alice);
        assertEq(a, 101e18);
        vm.warp(u);
        uint256 before = coin.balanceOf(alice);
        vm.prank(alice);
        assertEq(lk.withdraw(), 101e18);
        assertEq(coin.balanceOf(alice), before + 101e18);
        assertEq(coin.balanceOf(address(lk)), 20e18);
        assertEq(lk.skim(), 20e18);
        assertEq(coin.balanceOf(address(lk)), 0);
    }

    /// Whoever calls it, whatever is locked and strayed: skim() sends exactly the strays, and every lock and
    /// totalLocked stay as they were, every lock still paying exactly at its unlock.
    function testFuzz_skim_never_touches_a_lock(uint256 a1, uint256 a2, uint256 a3, uint256 stray, address caller, uint8 c)
        public
    {
        vm.assume(caller != address(0) && caller != address(vm) && caller != address(lk));
        a1 = bound(a1, 1, 5_000_000e18);
        a2 = bound(a2, 1, 5_000_000e18);
        a3 = bound(a3, 1, 5_000_000e18);
        stray = bound(stray, 0, 5_000_000e18);
        c = uint8(bound(c, 0, 3));
        vm.prank(alice);
        lk.lock(a1, c);
        coin.mint(eve, stray);
        vm.prank(eve);
        coin.transfer(address(lk), stray);
        vm.prank(bob);
        lk.lock(a2, 3);
        vm.prank(carol);
        lk.lock(a3, 0);
        (uint256 la, uint256 ua) = lockOf(alice);
        (uint256 lb, uint256 ub) = lockOf(bob);
        (uint256 lc, uint256 uc) = lockOf(carol);
        uint256 total = lk.totalLocked();
        uint256 callerBefore = coin.balanceOf(caller);
        uint256 straysBefore = coin.balanceOf(straysTo);
        vm.prank(caller);
        assertEq(lk.skim(), stray);
        if (caller != straysTo) assertEq(coin.balanceOf(caller), callerBefore, "the caller gets nothing");
        assertEq(coin.balanceOf(straysTo), straysBefore + stray);
        assertEq(lk.totalLocked(), total);
        assertEq(coin.balanceOf(address(lk)), total);
        (uint256 x, uint256 y) = lockOf(alice);
        assertEq(x, la);
        assertEq(y, ua);
        (x, y) = lockOf(bob);
        assertEq(x, lb);
        assertEq(y, ub);
        (x, y) = lockOf(carol);
        assertEq(x, lc);
        assertEq(y, uc);
        vm.warp(T0 + M12);
        vm.prank(alice);
        assertEq(lk.withdraw(), a1);
        vm.prank(bob);
        assertEq(lk.withdraw(), a2);
        vm.prank(carol);
        assertEq(lk.withdraw(), a3);
        assertEq(coin.balanceOf(address(lk)), 0);
    }

    // ------------------------------------------------------------------ no admin

    /// No owner, no admin, no pause, no rescue: calls to such functions find nothing to run.
    function test_no_owner_admin_pause_or_rescue() public {
        vm.prank(alice);
        lk.lock(100e18, 3);
        bytes[] memory calls = new bytes[](22);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("pendingOwner()");
        calls[2] = abi.encodeWithSignature("transferOwnership(address)", eve);
        calls[3] = abi.encodeWithSignature("acceptOwnership()");
        calls[4] = abi.encodeWithSignature("renounceOwnership()");
        calls[5] = abi.encodeWithSignature("pause()");
        calls[6] = abi.encodeWithSignature("unpause()");
        calls[7] = abi.encodeWithSignature("paused()");
        calls[8] = abi.encodeWithSignature("rescue(address,uint256)", eve, 100e18);
        calls[9] = abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(coin), eve, 100e18);
        calls[10] = abi.encodeWithSignature("sweep(address)", eve);
        calls[11] = abi.encodeWithSignature("recover(address,uint256)", address(coin), 100e18);
        calls[12] = abi.encodeWithSignature("emergencyWithdraw()");
        calls[13] = abi.encodeWithSignature("withdrawFor(address)", alice);
        calls[14] = abi.encodeWithSignature("withdrawTo(address)", eve);
        calls[15] = abi.encodeWithSignature("unlock(address)", alice);
        calls[16] = abi.encodeWithSignature("setUnlock(address,uint256)", alice, 0);
        calls[17] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", eve, "");
        calls[18] = abi.encodeWithSignature("initialize(address)", eve);
        calls[19] = abi.encodeWithSignature("setAdmin(address)", eve);
        calls[20] = abi.encodeWithSignature("execute(address,uint256,bytes)", address(coin), 0, abi.encodeCall(IERC20.transfer, (eve, 100e18)));
        calls[21] = "";
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(eve);
            (bool ok,) = address(lk).call{value: 0}(calls[i]);
            assertFalse(ok, "an admin-style call found something to run");
        }
        // Sending ETH is refused too (no receive or fallback).
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        (bool sentEth,) = address(lk).call{value: 1 ether}("");
        assertFalse(sentEth);
        (uint256 a, uint256 u) = lockOf(alice);
        assertEq(a, 100e18);
        assertEq(u, T0 + M12);
        assertEq(coin.balanceOf(address(lk)), 100e18);
        assertEq(coin.balanceOf(eve), 0);
    }

    /// Any selector other than the nine public functions finds nothing to run.
    function testFuzz_unknown_calls_revert(bytes4 sel, bytes calldata args) public {
        vm.assume(
            sel != lk.token.selector && sel != lk.durationOf.selector && sel != lk.lockOf.selector
                && sel != lk.lock.selector && sel != lk.extend.selector && sel != lk.withdraw.selector
                && sel != lk.totalLocked.selector && sel != lk.skim.selector && sel != lk.strays.selector
        );
        vm.prank(eve);
        (bool ok,) = address(lk).call(bytes.concat(sel, args));
        assertFalse(ok);
    }

    /// The deployed code holds no selector beyond its nine functions, its errors and the three token calls it makes
    /// (a function selector the dispatcher could match would show up as one of its constants). The compiler may store
    /// a selector shifted right to drop leading zero bits, so each constant is also tried shifted back.
    function test_the_code_has_no_hidden_functions() public view {
        bytes4[20] memory allowed = [
            lk.token.selector,
            lk.strays.selector,
            lk.skim.selector,
            BorroLock.ZeroAddress.selector,
            lk.durationOf.selector,
            lk.lockOf.selector,
            lk.lock.selector,
            lk.extend.selector,
            lk.withdraw.selector,
            lk.totalLocked.selector,
            BorroLock.ZeroAmount.selector,
            BorroLock.BadDuration.selector,
            BorroLock.NoLock.selector,
            BorroLock.NotLonger.selector,
            BorroLock.StillLocked.selector,
            BorroLock.TooMuch.selector,
            bytes4(keccak256("SafeERC20FailedOperation(address)")),
            bytes4(keccak256("Panic(uint256)")),
            IERC20.balanceOf.selector,
            IERC20.transferFrom.selector
        ];
        bytes memory code = address(lk).code;
        uint256 meta = (uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1]);
        uint256 end = code.length - 2 - meta; // the compiler's metadata sits at the end
        uint256 seen;
        for (uint256 i; i < end;) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                if (op == 0x63) {
                    uint32 v = uint32(bytes4(bytes.concat(code[i + 1], code[i + 2], code[i + 3], code[i + 4])));
                    bool ok = v == 365 days || v == type(uint32).max; // the 12-month length; a mask
                    for (uint256 s; s < 8 && !ok; ++s) {
                        uint256 w = uint256(v) << s;
                        if (w > type(uint32).max) break;
                        for (uint256 k; k < allowed.length; ++k) if (bytes4(uint32(w)) == allowed[k]) ok = true;
                        if (bytes4(uint32(w)) == IERC20.transfer.selector) ok = true;
                    }
                    assertTrue(ok, string.concat("unknown 4-byte constant in BorroLock's code: ", vm.toString(bytes4(v))));
                    seen++;
                }
                i += 1 + (op - 0x5f);
            } else {
                ++i;
            }
        }
        assertGt(seen, 10, "the scan read the dispatcher");
    }

    // ------------------------------------------------------------------ fuzz

    /// For any locker, amount and length: a withdrawal before the unlock reverts, and at or after it pays exactly the
    /// lock to the locker.
    function testFuzz_withdraw_reverts_before_and_works_from_the_unlock(
        address who,
        uint256 amount,
        uint8 choice,
        uint256 early,
        uint256 late
    ) public {
        vm.assume(who != address(0) && who != address(lk) && who != address(vm));
        amount = bound(amount, 1, 1e30);
        choice = uint8(bound(choice, 0, 3));
        coin.mint(who, amount);
        vm.prank(who);
        coin.approve(address(lk), amount);
        uint256 d = lk.durationOf(choice);
        vm.prank(who);
        uint256 u = lk.lock(amount, choice);
        assertEq(u, T0 + d);
        vm.warp(T0 + bound(early, 0, d - 1));
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(BorroLock.StillLocked.selector, u));
        lk.withdraw();
        vm.warp(u + bound(late, 0, 20 * 365 days));
        uint256 before = coin.balanceOf(who);
        vm.prank(who);
        assertEq(lk.withdraw(), amount);
        assertEq(coin.balanceOf(who), before + amount);
        assertEq(lk.totalLocked(), 0);
    }

    /// Locking more never moves the unlock earlier; extend moves it later or is refused.
    function testFuzz_lock_and_extend_never_shorten(uint8 c1, uint8 c2, uint8 c3, uint256 gap1, uint256 gap2, uint256 more)
        public
    {
        c1 = uint8(bound(c1, 0, 3));
        c2 = uint8(bound(c2, 0, 3));
        c3 = uint8(bound(c3, 0, 3));
        vm.prank(alice);
        uint256 u1 = lk.lock(100e18, c1);
        uint256 t = T0 + bound(gap1, 0, 400 days);
        vm.warp(t);
        vm.prank(alice);
        uint256 u2 = lk.lock(bound(more, 1, 1_000_000e18), c2);
        uint256 wanted = t + lk.durationOf(c2);
        assertEq(u2, u1 > wanted ? u1 : wanted);
        assertGe(u2, u1, "lock never shortens");
        t += bound(gap2, 0, 400 days);
        vm.warp(t);
        wanted = t + lk.durationOf(c3);
        vm.prank(alice);
        if (wanted > u2) {
            assertEq(lk.extend(c3), wanted);
        } else {
            vm.expectRevert(abi.encodeWithSelector(BorroLock.NotLonger.selector, u2, wanted));
            lk.extend(c3);
        }
        (, uint256 u3) = lockOf(alice);
        assertGe(u3, u2, "extend never shortens");
    }

    // ------------------------------------------------------------------ gas, for the report

    function test_gas() public {
        vm.prank(alice);
        uint256 g = gasleft();
        lk.lock(1_000e18, 1);
        emit log_named_uint("gas lock(), a new lock", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        lk.lock(1_000e18, 3);
        emit log_named_uint("gas lock(), adding to one", g - gasleft());
        vm.warp(T0 + 10 days);
        vm.prank(alice);
        g = gasleft();
        lk.extend(3);
        emit log_named_uint("gas extend()", g - gasleft());
        vm.warp(T0 + 10 days + M12);
        vm.prank(alice);
        g = gasleft();
        lk.withdraw();
        emit log_named_uint("gas withdraw()", g - gasleft());
    }
}

/// Many lockers locking, adding, extending and withdrawing at random times; outsiders trying to move anything; stray
/// tokens sent in and skimmed by anyone. A ghost copy of every lock is kept and checked.
contract LockHandler is Test {
    BorroLock public lk;
    WatchedCoin public coin;
    address[] public actors;
    address public eve;
    mapping(address => uint256) public amountOf; // what each lock should hold
    mapping(address => uint256) public unlockOf; // when it should unlock
    mapping(address => uint256) public withdrawn; // paid to each actor by its own withdrawals
    address public straysTo; // the lock's strays address
    uint256 public strayIn; // every token sent to the lock outside lock()
    uint256 public skimmed; // every token skim() sent to straysTo
    uint256 public skims;
    uint256 public shortened; // a lock or extend that moved an unlock earlier (must stay 0)
    uint256 public sneaks; // anything an outsider managed to move (must stay 0)
    uint256 public locks;
    uint256 public extends;
    uint256 public withdrawals;
    uint256 public refusedEarly;

    constructor(BorroLock lk_, WatchedCoin coin_) {
        lk = lk_;
        coin = coin_;
        for (uint256 i; i < 8; ++i) actors.push(makeAddr(string.concat("locker", vm.toString(i))));
        eve = makeAddr("eve");
        straysTo = lk_.strays();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function now_() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function lock(uint256 who, uint256 amount, uint256 choice) external {
        address a = actors[who % actors.length];
        uint8 c = uint8(bound(choice, 0, 3));
        amount = bound(amount, 1, 5_000_000e18);
        coin.mint(a, amount);
        vm.prank(a);
        coin.approve(address(lk), amount);
        uint256 old = unlockOf[a];
        uint256 wanted = now_() + lk.durationOf(c);
        vm.prank(a);
        uint256 u = lk.lock(amount, c);
        assertEq(u, old > wanted ? old : wanted, "lock sets the later of the two");
        if (u < old) shortened++;
        amountOf[a] += amount;
        unlockOf[a] = u;
        locks++;
    }

    function extend(uint256 who, uint256 choice) external {
        address a = actors[who % actors.length];
        uint8 c = uint8(bound(choice, 0, 3));
        uint256 old = unlockOf[a];
        uint256 wanted = now_() + lk.durationOf(c);
        vm.prank(a);
        try lk.extend(c) returns (uint256 u) {
            assertGt(amountOf[a], 0, "extend without a lock went through");
            assertGt(wanted, old, "extend went through without lengthening");
            assertEq(u, wanted);
            if (u <= old) shortened++;
            unlockOf[a] = u;
            extends++;
        } catch (bytes memory err) {
            if (amountOf[a] == 0) {
                assertEq(bytes4(err), BorroLock.NoLock.selector);
            } else {
                assertLe(wanted, old, "an extend that lengthens was refused");
                assertEq(err, abi.encodeWithSelector(BorroLock.NotLonger.selector, old, wanted));
            }
        }
    }

    function withdraw(uint256 who) external {
        address a = actors[who % actors.length];
        uint256 bal = coin.balanceOf(a);
        vm.prank(a);
        try lk.withdraw() returns (uint256 got) {
            assertGt(amountOf[a], 0, "a withdraw with no lock went through");
            assertGe(now_(), unlockOf[a], "a withdraw before the unlock went through");
            assertEq(got, amountOf[a], "a withdraw pays the whole lock");
            assertEq(coin.balanceOf(a), bal + got, "to the locker");
            withdrawn[a] += got;
            amountOf[a] = 0;
            unlockOf[a] = 0;
            withdrawals++;
        } catch (bytes memory err) {
            if (amountOf[a] == 0) {
                assertEq(bytes4(err), BorroLock.NoLock.selector);
            } else {
                assertLt(now_(), unlockOf[a], "a withdraw at or after the unlock failed");
                assertEq(err, abi.encodeWithSelector(BorroLock.StillLocked.selector, unlockOf[a]));
                refusedEarly++;
            }
        }
    }

    function warp(uint256 secs) external {
        vm.warp(now_() + bound(secs, 1, 60 days));
    }

    /// Lands exactly on someone's unlock (or one second before or after it), where off-by-one mistakes would show.
    function warpToUnlock(uint256 who, uint256 offset) external {
        uint256 u = unlockOf[actors[who % actors.length]];
        if (u == 0) return;
        uint256 target = u + (offset % 3) - 1;
        if (target > now_()) vm.warp(target);
    }

    function stray(uint256 amount) external {
        amount = bound(amount, 0, 1_000_000e18);
        coin.mint(eve, amount);
        vm.prank(eve);
        coin.transfer(address(lk), amount);
        strayIn += amount;
    }

    /// Anyone skims: exactly what is held beyond every lock goes to the strays address; no lock changes.
    function skim(uint256 who) external {
        address caller = who % 3 == 0 ? eve : who % 3 == 1 ? actors[who % actors.length] : address(uint160(who));
        if (caller == address(0) || caller == straysTo || caller == address(lk) || caller == address(vm)) caller = eve;
        uint256 excess = coin.balanceOf(address(lk)) - lk.totalLocked();
        uint256 total = lk.totalLocked();
        uint256[] memory amounts = new uint256[](actors.length);
        uint256[] memory unlocks = new uint256[](actors.length);
        for (uint256 i; i < actors.length; ++i) (amounts[i], unlocks[i]) = lk.lockOf(actors[i]);
        uint256 callerBefore = coin.balanceOf(caller);
        uint256 toBefore = coin.balanceOf(straysTo);
        vm.prank(caller);
        uint256 got = lk.skim();
        assertEq(got, excess, "skim sends exactly the excess");
        assertEq(coin.balanceOf(straysTo), toBefore + got);
        assertEq(coin.balanceOf(caller), callerBefore, "the caller gets nothing");
        assertEq(lk.totalLocked(), total, "skim never changes totalLocked");
        for (uint256 i; i < actors.length; ++i) {
            (uint256 a, uint256 u) = lk.lockOf(actors[i]);
            assertEq(a, amounts[i], "skim never changes a lock");
            assertEq(u, unlocks[i]);
        }
        skimmed += got;
        skims++;
    }

    /// An outsider tries to move tokens out of the lock: through the token, or through any function on the lock.
    function sneak(uint256 who, uint256 what, uint256 amount) external {
        address victim = actors[who % actors.length];
        amount = bound(amount, 1, 1_000_000e18);
        uint256 held = coin.balanceOf(address(lk));
        vm.startPrank(eve);
        uint256 w = what % 4;
        if (w == 0) {
            try coin.transferFrom(address(lk), eve, amount) {
                sneaks++;
            } catch {}
        } else if (w == 1) {
            try lk.withdraw() {
                sneaks++;
            } catch {}
        } else if (w == 2) {
            (bool ok,) = address(lk).call(abi.encodeWithSignature("withdrawFor(address)", victim));
            if (ok) sneaks++;
        } else {
            try lk.extend(0) {
                sneaks++;
            } catch {}
        }
        vm.stopPrank();
        if (coin.balanceOf(address(lk)) != held) sneaks++;
    }
}

contract BorroLockInvariantTest is StdInvariant, BorroLockBase {
    LockHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new LockHandler(lk, coin);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](8);
        sel[0] = LockHandler.lock.selector;
        sel[1] = LockHandler.extend.selector;
        sel[2] = LockHandler.withdraw.selector;
        sel[3] = LockHandler.warp.selector;
        sel[4] = LockHandler.warpToUnlock.selector;
        sel[5] = LockHandler.stray.selector;
        sel[6] = LockHandler.sneak.selector;
        sel[7] = LockHandler.skim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_every_lock_is_what_its_locker_did() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            (uint256 amount, uint256 unlockAt) = lk.lockOf(a);
            assertEq(amount, handler.amountOf(a));
            assertEq(unlockAt, handler.unlockOf(a));
            assertTrue((amount == 0) == (unlockAt == 0), "a lock with an amount has an unlock time, and only then");
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_total_locked_is_the_sum_and_is_held() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) sum += handler.amountOf(handler.actors(i));
        assertEq(lk.totalLocked(), sum);
        assertEq(coin.balanceOf(address(lk)), lk.totalLocked() + handler.strayIn() - handler.skimmed());
        assertGe(coin.balanceOf(address(lk)), lk.totalLocked(), "every lock is held");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_only_lockers_receive_and_only_their_own() public view {
        uint256 n = coin.paidToCount();
        for (uint256 i; i < n; ++i) {
            address a = coin.paidTo(i);
            if (a == handler.straysTo()) continue;
            assertGt(handler.withdrawn(a), 0, "someone received from the lock without a withdrawal of their own");
        }
        assertEq(coin.paidFromWatched(handler.straysTo()), handler.skimmed(), "the strays address got only skims");
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(coin.paidFromWatched(a), handler.withdrawn(a), "a locker received other than its own withdrawals");
            sum += handler.withdrawn(a);
        }
        assertEq(coin.paidOutTotal(), sum + handler.skimmed());
        assertEq(coin.balanceOf(handler.eve()), 0);
        assertEq(handler.sneaks(), 0);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_no_unlock_ever_moves_earlier() public view {
        assertEq(handler.shortened(), 0);
    }

    /// At every step, for every locker: a withdrawal now reverts if the unlock has not come, and works, paying exactly
    /// the lock to the locker, if it has. Tried and then undone, so the run goes on as it was.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_withdraw_works_exactly_when_unlocked() public {
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            (uint256 amount, uint256 unlockAt) = lk.lockOf(a);
            uint256 before = coin.balanceOf(a);
            uint256 snap = vm.snapshotState();
            vm.prank(a);
            if (amount == 0) {
                vm.expectRevert(BorroLock.NoLock.selector);
                lk.withdraw();
            } else if (t < unlockAt) {
                vm.expectRevert(abi.encodeWithSelector(BorroLock.StillLocked.selector, unlockAt));
                lk.withdraw();
            } else {
                assertEq(lk.withdraw(), amount);
                assertEq(coin.balanceOf(a), before + amount);
            }
            vm.revertToState(snap);
        }
    }

    function afterInvariant() external {
        // Far past every unlock, every locker takes back exactly its lock; only the strays stay, and skim() takes them.
        vm.warp(vm.getBlockTimestamp() + 366 days);
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            uint256 amount = handler.amountOf(a);
            if (amount == 0) continue;
            vm.prank(a);
            assertEq(lk.withdraw(), amount);
        }
        assertEq(lk.totalLocked(), 0);
        uint256 left = handler.strayIn() - handler.skimmed();
        assertEq(coin.balanceOf(address(lk)), left);
        assertEq(lk.skim(), left);
        assertEq(coin.balanceOf(address(lk)), 0);
    }
}
