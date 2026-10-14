// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {BorroHook} from "../../src/hooks/BorroHook.sol";
import {IVault} from "../../src/hooks/BorroHookDeps.sol";
import {BorroHookShare} from "../../src/hooks/BorroHookShare.sol";
import {BorroHookBase} from "./BorroHookBase.sol";
import "./BorroHookMocks.sol";

/// The independent review of 2026-10-08 (docs/HOOKS.md, "Review 2026-10-08"): one test per finding.
contract BorroHookReviewTest is BorroHookBase {
    using MarketParamsLib for MarketParams;

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    /// A second stock (TSLA at $100) with nobody in its pool yet.
    function _freshPool() internal returns (PoolId id2, PoolKey memory k2, MockToken t2, MockVault v2) {
        t2 = new MockToken("TSLA", 18);
        MarketParams memory m = MarketParams({loanToken: address(t2), collateralToken: address(0xC0), oracle: address(0x0C), irm: address(0x1), lltv: 0.625e18});
        bytes32 d2 = Id.unwrap(m.id());
        desks.setDesk(d2, m, address(feed));
        morpho.setUse(Id.wrap(d2), 1000e18, 0);
        v2 = new MockVault(t2, 18);
        vm.prank(owner);
        id2 = hook.register(d2, IVault(address(v2)));
        k2 = hook.keyFor(address(t2));
        pm.initialize(k2, SQRT_1_1);
    }

    function _dep(PoolId pid, MockToken t, address who, uint256 u, uint256 s) internal returns (uint256 shares) {
        usdg.mint(who, u);
        t.mint(who, s);
        vm.startPrank(who);
        usdg.approve(address(hook), u);
        t.approve(address(hook), s);
        (shares,,) = hook.deposit(pid, u, s, 0, who);
        vm.stopPrank();
    }

    function _out(PoolId pid, address who) internal returns (uint256 u, uint256 s) {
        BorroHookShare sh = BorroHookShare(address(hook.poolOf(pid).share));
        uint256 bal = sh.balanceOf(who);
        vm.prank(who);
        (u, s,,) = hook.withdraw(pid, bal, 0, 0, who);
    }

    function _priceOf(PoolId pid) internal view returns (uint256) {
        BorroHook.Pool memory p = hook.poolOf(pid);
        return uint256(p.resUsdg) * 1e8 * 1e18 / (uint256(p.resStock) * 1e6);
    }

    /// Exact-in swap on any pool through the test router, as `who` (tx.origin too).
    function _swapOn(PoolKey memory k, MockToken t, address who, bool usdgIn, uint256 amount) internal returns (uint256 got) {
        bool zeroForOne = usdgIn == (Currency.unwrap(k.currency0) == address(usdg));
        MockToken tIn = usdgIn ? usdg : t;
        MockToken tOut = usdgIn ? t : usdg;
        tIn.mint(who, amount);
        uint256 before = tOut.balanceOf(who);
        vm.startPrank(who, who);
        tIn.approve(address(router), amount);
        router.swap(k, zeroForOne, -int256(amount));
        vm.stopPrank();
        got = tOut.balanceOf(who) - before;
    }

    function swapOnExt(PoolKey memory k, MockToken t, address who, bool usdgIn, uint256 amount) external returns (uint256) {
        return _swapOn(k, t, who, usdgIn, amount);
    }

    // ---------------------------------------------------------------- H-1: the pool's price after every LP leaves

    /// After the last LP leaves, what stays in the pool (the locked shares' part) must keep the pool's price. Before the
    /// fix only 1,000 shares were locked: a few wei of USDG against 1e8 wei of stock, a price 100x the feed's.
    function test_after_every_lp_leaves_the_pool_keeps_its_price() public {
        _withdraw(alice, share.balanceOf(alice));
        assertEq(share.totalSupply(), share.balanceOf(DEAD_()), "only the locked shares remain");
        uint256 px = _price();
        assertApproxEqRel(px, 100e8, 0.001e18, "the price is still the feed's, to 0.1%");
        BorroHook.Pool memory p = _pool();
        assertGe(uint256(p.resUsdg), 1e6, "at least $1 of USDG stays");
        assertGe(uint256(p.resStock), 0.009e18, "and its stock");
    }

    /// The attack H-1 made possible: be first into a fresh pool with a tiny deposit, leave, so the pool's ratio is
    /// rounding dust 100x off the feed; the next LP must deposit at that ratio (no check against the feed after the
    /// first deposit); then sell the stock back toward the feed and take most of the LP's USDG.
    function test_a_griefed_first_deposit_cannot_trap_the_next_lp() public {
        (PoolId id2, PoolKey memory k2, MockToken t2,) = _freshPool();
        // The attacker's tiny first deposit, at the feed price. After the fix it must lock $1: too little is refused.
        usdg.mint(attacker, 1e12);
        t2.mint(attacker, 1e24);
        vm.startPrank(attacker);
        usdg.approve(address(hook), type(uint256).max);
        t2.approve(address(hook), type(uint256).max);
        vm.expectRevert();
        hook.deposit(id2, 1e3, 1e13, 0, attacker); // $0.001 and 0.00001 TSLA
        hook.deposit(id2, 2e6, 0.02e18, 0, attacker); // $2 and 0.02 TSLA: the least that works
        vm.stopPrank();
        _out(id2, attacker);
        assertApproxEqRel(_priceOf(id2), 100e8, 0.001e18, "the dust keeps the feed's price");

        // The victim deposits $10,000 and 100 TSLA (at the feed), as the site would offer.
        uint256 vu = 10_000e6;
        uint256 vs = 100e18;
        usdg.mint(victim, vu);
        t2.mint(victim, vs);
        vm.startPrank(victim);
        usdg.approve(address(hook), vu);
        t2.approve(address(hook), vs);
        (, uint256 inU, uint256 inS) = hook.deposit(id2, vu, vs, 0, victim);
        vm.stopPrank();
        uint256 putIn = inU + inS * 100e6 / 1e18;
        // The attacker trades the pool toward the feed if it can (it is already there), then the victim leaves.
        try this.swapOnExt(k2, t2, attacker, false, 1e18) {} catch {}
        (uint256 u, uint256 s) = _out(id2, victim);
        uint256 got = u + s * 100e6 / 1e18;
        assertGe(got * 1000, putIn * 990, "the victim keeps at least 99% (a swap's fees aside)");
    }

    function DEAD_() internal view returns (address) {
        return hook.DEAD();
    }
}
