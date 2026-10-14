// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Id} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroHook} from "../../src/hooks/BorroHook.sol";
import {BorroHookShare} from "../../src/hooks/BorroHookShare.sol";
import {BorroHookBase} from "./BorroHookBase.sol";
import "./BorroHookMocks.sol";

contract BorroHookFuzzTest is BorroHookBase {
    /// Any swap the hook lets through leaves the LPs' curve no smaller (k never falls) and the books covered.
    function testFuzz_a_swap_never_makes_lps_poorer(bool usdgIn, bool exactIn, uint256 amount, uint16 use) public {
        morpho.setUse(Id.wrap(deskId), 1000e18, uint128(bound(use, 0, 10_000)) * 1e17);
        amount = usdgIn ? bound(amount, 1e4, 1_400e6) : bound(amount, 1e12, 14e18);
        BorroHook.Pool memory p0 = _pool();
        try this.doSwap(bob, usdgIn, exactIn, amount) {} catch {
            return; // refused (guard, too small): nothing to check
        }
        BorroHook.Pool memory p1 = _pool();
        assertGe(uint256(p1.resUsdg) * p1.resStock, uint256(p0.resUsdg) * p0.resStock, "k never falls");
        _assertSolvent();
    }

    function doSwap(address who, bool usdgIn, bool exactIn, uint256 amount) external {
        _swap(who, usdgIn, exactIn, amount);
    }

    /// Depositing and taking it straight back out never gives more than was put in (no free money from rounding).
    function testFuzz_deposit_then_withdraw_never_profits(uint256 u, uint256 s) public {
        u = bound(u, 1e6, 1e12);
        s = bound(s, 1e16, 1e22);
        uint256 shares = _deposit(bob, u, s);
        (uint256 inU, uint256 inS) = (u - usdg.balanceOf(bob), s - stock.balanceOf(bob));
        (uint256 outU, uint256 outS,,) = _withdraw(bob, shares);
        assertLe(outU, inU, "USDG");
        assertLe(outS, inS, "stock");
        assertGe(outU + 2, inU * 999_999 / 1_000_000, "and loses only dust");
        _assertSolvent();
    }

    /// The fee is always between the floor and the LPs' fee plus the full surcharge, whatever the owner set.
    function testFuzz_fee_stays_in_bounds(uint24 base, uint24 sq, uint16 start, uint24 floor, uint16 disc, uint16 use, bool hold)
        public
    {
        base = uint24(bound(base, 0, hook.MAX_BASE_FEE_PIPS()));
        sq = uint24(bound(sq, 0, hook.MAX_SQUEEZE_PIPS()));
        start = uint16(bound(start, 0, 9_999));
        floor = uint24(bound(floor, 0, base));
        disc = uint16(bound(disc, 0, hook.MAX_DISCOUNT_BPS()));
        vm.startPrank(owner);
        hook.setFees(base, sq, start, floor);
        hook.setDiscount(disc, 1e18, 0);
        vm.stopPrank();
        morpho.setUse(Id.wrap(deskId), 1000e18, uint128(bound(use, 0, 12_000)) * 1e17);
        if (hold) borro.mint(carol, 1e18);
        (uint256 lp, uint256 sur, bool holder) = hook.feeFor(id, carol);
        assertEq(holder, hold);
        assertGe(lp + sur, floor);
        assertLe(lp + sur, uint256(base) + sq + floor);
        assertLe(sur, sq);
    }

    /// A swap that went through ended within the guard of the feed, or closer to it than it started.
    function testFuzz_guard_holds(int256 move, bool usdgIn, uint256 amount, uint16 band) public {
        band = uint16(bound(band, hook.MIN_GUARD_BPS(), hook.MAX_GUARD_BPS()));
        vm.prank(owner);
        hook.setGuard(band, 25 hours);
        move = bound(move, -3_000, 3_000);
        feed.set(int256(100e8) * (10_000 + move) / 10_000, block.timestamp);
        uint256 f = uint256(feed.answer());
        amount = usdgIn ? bound(amount, 1e6, 30_000e6) : bound(amount, 1e16, 300e18);
        uint256 before = _price();
        try this.doSwap(bob, usdgIn, true, amount) {} catch {
            return;
        }
        uint256 afterP = _price();
        uint256 devAfter = (afterP > f ? afterP - f : f - afterP) * 10_000 / f;
        uint256 devBefore = (before > f ? before - f : f - before) * 10_000 / f;
        assertTrue(devAfter <= band + 1 || devAfter < devBefore + 1, "guard");
    }

    /// Whatever the owner sets, an LP takes out what they put in (less dust), feed or no feed.
    function testFuzz_owner_settings_cannot_touch_lp_money(uint24 base, uint16 buffer, uint16 lenderShare, uint16 band, uint32 age, bool pause)
        public
    {
        vm.startPrank(owner);
        hook.setFees(uint24(bound(base, 0, 10_000)), 20_000, 0, 0);
        hook.setBuffer(uint16(bound(buffer, 1_000, 10_000)));
        hook.setLenderShare(uint16(bound(lenderShare, 0, 10_000)));
        hook.setGuard(uint16(bound(band, 50, 1_500)), uint32(bound(age, 1 hours, 4 days)));
        hook.setDepositsPaused(id, pause);
        hook.setRouter(address(this), true);
        vm.stopPrank();
        hook.rebalance(id);
        feed.set(0, 0);
        (uint256 u, uint256 s,,) = _withdraw(alice, share.balanceOf(alice));
        // less only the first deposit's locked part: $1 of $100,000 (1e-5) since the review of 2026-10-08
        assertApproxEqRel(u, 100_000e6, 2e13);
        assertApproxEqRel(s, 1_000e18, 2e13);
    }
}

/// Random sequences of everything anyone can do; withdrawals must never fail and the books must always balance.
contract BorroHookHandler is Test {
    BorroHookInvariantTest t;
    address[3] lps;
    bool public withdrawFailed;
    bytes public lastError;
    uint256 public swaps;
    uint256 public refused;

    constructor(BorroHookInvariantTest t_, address[3] memory lps_) {
        t = t_;
        lps = lps_;
    }

    function deposit(uint256 who, uint256 u, uint256 s) external {
        address a = lps[who % 3];
        u = bound(u, 1e6, 1e11);
        s = bound(s, 1e16, 1e21);
        try t.depositFor(a, u, s) {} catch {}
    }

    function withdraw(uint256 who, uint256 part) external {
        address a = lps[who % 3];
        uint256 bal = t.lpShare().balanceOf(a);
        if (bal == 0) return;
        uint256 sh = bound(part, 1, bal);
        try t.withdrawFor(a, sh) {} catch (bytes memory err) {
            withdrawFailed = true;
            lastError = err;
        }
    }

    function swap(bool usdgIn, bool exactIn, uint256 amount) external {
        amount = usdgIn ? bound(amount, 1e5, 2_000e6) : bound(amount, 1e14, 20e18);
        try t.swapFor(usdgIn, exactIn, amount) {
            swaps++;
        } catch {
            refused++;
        }
    }

    function moveFeed(int256 bps) external {
        t.moveFeed(bound(bps, -500, 500));
    }

    function rent(uint256 amount) external {
        t.accrueRent(bound(amount, 0, 5e18));
    }

    function shortersBorrow(uint256 part) external {
        t.borrowOut(bound(part, 0, 10_000));
    }

    function shortersRepay() external {
        t.repayAll();
    }

    function setUse(uint256 use) external {
        t.setUse(bound(use, 0, 10_000));
    }

    function rebalance() external {
        t.rebalanceAny();
    }

    function flush() external {
        t.flushAny();
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 6 hours));
        if (secs % 2 == 0) t.moveFeed(0); // the feed updates now and then, as a live one does
    }
}

contract BorroHookInvariantTest is BorroHookBase {
    BorroHookHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new BorroHookHandler(this, [alice, bob, carol]);
        targetContract(address(handler));
    }

    function lpShare() external view returns (BorroHookShare) {
        return share;
    }

    function depositFor(address who, uint256 u, uint256 s) external {
        _deposit(who, u, s);
    }

    function withdrawFor(address who, uint256 sh) external {
        // startPrank, not prank: a refused swap earlier may have left its prank on
        vm.startPrank(who);
        hook.withdraw(id, sh, 0, 0, who);
        vm.stopPrank();
    }

    function swapFor(bool usdgIn, bool exactIn, uint256 amount) external {
        _swap(makeAddr("trader"), usdgIn, exactIn, amount);
    }

    function moveFeed(int256 bps) external {
        int256 a = feed.answer() * (10_000 + bps) / 10_000;
        if (a > 1e8) feed.set(a, block.timestamp);
    }

    function accrueRent(uint256 amount) external {
        if (sVault.lentOut() > 0) sVault.accrue(amount);
    }

    function borrowOut(uint256 partBps) external {
        uint256 idle = stock.balanceOf(address(sVault));
        sVault.lend(idle * partBps / 10_000, shorter);
    }

    function repayAll() external {
        uint256 owed = sVault.lentOut();
        stock.mint(shorter, owed);
        vm.startPrank(shorter);
        stock.approve(address(sVault), owed);
        sVault.repay(owed);
        vm.stopPrank();
    }

    function setUse(uint256 use) external {
        morpho.setUse(Id.wrap(deskId), 1000e18, uint128(use) * 1e17);
    }

    function rebalanceAny() external {
        hook.rebalance(id);
    }

    function flushAny() external {
        hook.flush(id);
    }

    function afterInvariant() public {
        emit log_named_uint("swaps filled", handler.swaps());
        emit log_named_uint("swaps refused", handler.refused());
    }

    function invariant_withdrawals_never_fail() public {
        if (handler.withdrawFailed()) emit log_named_bytes("withdraw error", handler.lastError());
        assertFalse(handler.withdrawFailed(), "a withdrawal failed");
    }

    function invariant_the_books_balance() public view {
        _assertSolvent();
    }

    function invariant_the_pool_is_never_emptied() public view {
        BorroHook.Pool memory p = _pool();
        assertGt(p.resUsdg, 0);
        assertGt(p.resStock, 0);
        assertGe(share.balanceOf(address(0xdEaD)), hook.MIN_SHARES());
    }

    function invariant_shares_add_up() public view {
        assertEq(share.totalSupply(), share.balanceOf(alice) + share.balanceOf(bob) + share.balanceOf(carol) + share.balanceOf(address(0xdEaD)));
    }
}
