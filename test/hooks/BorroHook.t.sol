// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {BorroHook} from "../../src/hooks/BorroHook.sol";
import {IVault} from "../../src/hooks/BorroHookDeps.sol";
import {BorroHookShare} from "../../src/hooks/BorroHookShare.sol";
import {BorroHookBase} from "./BorroHookBase.sol";
import "./BorroHookMocks.sol";

contract BorroHookTest is BorroHookBase {
    using MarketParamsLib for MarketParams;

    // ---------------------------------------------------------------- registration and setup

    function test_register_derives_everything_from_the_desk() public view {
        BorroHook.Pool memory p = _pool();
        assertEq(p.stock, address(stock));
        assertEq(address(p.stockVault), address(sVault));
        assertEq(p.feed, address(feed));
        assertEq(p.marketId, deskId);
        assertEq(p.stockDecimals, 18);
        assertEq(share.symbol(), "bpNVDA");
        assertEq(share.name(), "Borro NVDA pool");
        assertEq(share.hook(), address(hook));
        assertEq(PoolId.unwrap(hook.poolOfStock(address(stock))), PoolId.unwrap(id));
    }

    function test_register_only_owner_once_per_stock_and_the_vault_must_lend_that_stock() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.register(deskId, IVault(address(sVault)));
        vm.startPrank(owner);
        vm.expectRevert(BorroHook.AlreadyRegistered.selector);
        hook.register(deskId, IVault(address(sVault)));
        MockToken other = new MockToken("TSLA", 18);
        MarketParams memory m = MarketParams({loanToken: address(other), collateralToken: address(0xC0), oracle: address(0x0C), irm: address(0x1), lltv: 0.625e18});
        bytes32 otherDesk = Id.unwrap(m.id());
        desks.setDesk(otherDesk, m, address(feed));
        vm.expectRevert(BorroHook.BadDesk.selector);
        hook.register(otherDesk, IVault(address(sVault))); // a vault of NVDA cannot lend TSLA
        vm.expectRevert(BorroHook.BadDesk.selector);
        hook.register(keccak256("not a desk"), IVault(address(sVault)));
        vm.stopPrank();
    }

    /// Listing closes for good at deploy, so no later pool can lend to a vault other than Borro's own.
    function test_once_the_registry_is_closed_nobody_lists_a_pool_again() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.closeRegistry();
        MockToken other = new MockToken("TSLA", 18);
        MarketParams memory m = MarketParams({loanToken: address(other), collateralToken: address(0xC0), oracle: address(0x0C), irm: address(0x1), lltv: 0.625e18});
        bytes32 otherDesk = Id.unwrap(m.id());
        desks.setDesk(otherDesk, m, address(feed));
        MockVault otherVault = new MockVault(IERC20(address(other)), 18);
        vm.startPrank(owner);
        hook.closeRegistry();
        assertTrue(hook.registryClosed());
        vm.expectRevert(BorroHook.RegistryClosed.selector);
        hook.register(otherDesk, IVault(address(otherVault)));
        vm.stopPrank();
    }

    function test_the_share_implementation_and_clones_cannot_be_taken_over() public {
        vm.expectRevert(BorroHookShare.AlreadySet.selector);
        share.initialize("x", "x");
        BorroHookShare impl = BorroHookShare(hook.shareImpl());
        vm.expectRevert(BorroHookShare.AlreadySet.selector);
        impl.initialize("x", "x");
        vm.expectRevert(BorroHookShare.OnlyHook.selector);
        share.mint(address(this), 1);
        vm.expectRevert(BorroHookShare.OnlyHook.selector);
        share.burn(alice, 1);
    }

    function test_unregistered_pools_cannot_start_and_nobody_adds_liquidity_around_the_hook() public {
        PoolKey memory k = hook.keyFor(address(new MockToken("X", 18)));
        vm.expectRevert();
        pm.initialize(k, SQRT_1_1);
        vm.expectRevert();
        pm.modifyLiquidity(key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0}), "");
    }

    // ---------------------------------------------------------------- deposits

    function test_first_deposit_sets_the_price_locks_min_shares_and_lends_the_rest() public view {
        BorroHook.Pool memory p = _pool();
        assertEq(_price(), 100e8, "price is the feed's");
        // locked for good: $1 of the USDG side and its stock (review 2026-10-08), so an emptied pool keeps its price
        uint256 locked = share.balanceOf(address(0xdEaD));
        assertGe(locked, hook.MIN_SHARES());
        assertApproxEqAbs(locked * uint256(p.resUsdg) / share.totalSupply(), hook.MIN_LOCK_USDG(), 1);
        // 30% of each side stays in the pool, 70% is lent
        assertEq(p.bufUsdg, 30_000e6);
        assertEq(p.bufStock, 300e18);
        assertApproxEqAbs(uVault.previewRedeem(p.lentUsdg), 70_000e6, 1);
        assertApproxEqAbs(sVault.previewRedeem(p.lentStock), 700e18, 1);
        _assertSolvent();
    }

    function test_first_deposit_far_from_the_feed_is_refused() public {
        vm.prank(owner);
        MockToken other = new MockToken("TSLA", 18);
        MarketParams memory m = MarketParams({loanToken: address(other), collateralToken: address(0xC0), oracle: address(0x0C), irm: address(0x1), lltv: 0.625e18});
        bytes32 d2 = Id.unwrap(m.id());
        desks.setDesk(d2, m, address(feed));
        MockVault v2 = new MockVault(other, 18);
        vm.prank(owner);
        PoolId id2 = hook.register(d2, IVault(address(v2)));
        usdg.mint(bob, 1e12);
        other.mint(bob, 1e24);
        vm.startPrank(bob);
        usdg.approve(address(hook), type(uint256).max);
        other.approve(address(hook), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BorroHook.Guard.selector, 150e8, 100e8));
        hook.deposit(id2, 150_000e6, 1_000e18, 0, bob); // $150 a share against a $100 feed
        hook.deposit(id2, 101_000e6, 1_000e18, 0, bob); // 1% off is fine
        vm.stopPrank();
    }

    function test_later_deposits_take_the_pool_ratio_and_mint_fairly() public {
        uint256 supply = share.totalSupply();
        usdg.mint(bob, 50_000e6);
        stock.mint(bob, 1_000e18);
        vm.startPrank(bob);
        usdg.approve(address(hook), type(uint256).max);
        stock.approve(address(hook), type(uint256).max);
        (uint256 shares, uint256 u, uint256 s) = hook.deposit(id, 50_000e6, 1_000e18, 0, bob);
        vm.stopPrank();
        assertEq(u, 50_000e6, "all the USDG");
        assertApproxEqAbs(s, 500e18, 1, "only the stock that matches");
        assertApproxEqRel(shares, supply / 2, 1e12);
        assertEq(stock.balanceOf(bob), 1_000e18 - s, "the rest stays with bob");
        _assertSolvent();
    }

    function test_paused_deposits_still_let_everyone_swap_and_withdraw() public {
        vm.prank(owner);
        hook.setDepositsPaused(id, true);
        usdg.mint(bob, 1e9);
        stock.mint(bob, 1e19);
        vm.startPrank(bob);
        usdg.approve(address(hook), type(uint256).max);
        stock.approve(address(hook), type(uint256).max);
        vm.expectRevert(BorroHook.IsPaused.selector);
        hook.deposit(id, 1e9, 1e19, 0, bob);
        vm.stopPrank();
        _swap(bob, true, true, 1_000e6);
        uint256 half = share.balanceOf(alice) / 2;
        (uint256 u, uint256 s,,) = _withdraw(alice, half);
        assertGt(u, 0);
        assertGt(s, 0);
    }

    // ---------------------------------------------------------------- swaps

    function test_swap_usdg_for_stock_exact_in_pays_the_curve_less_the_fee() public {
        BorroHook.Pool memory p0 = _pool();
        (uint256 paid, uint256 got) = _swap(bob, true, true, 1_000e6);
        uint256 net = 1_000e6 - 1_000e6 * 3_000 / 1e6; // 0.30%, no squeeze at 0% use
        uint256 expect = uint256(p0.resStock) * net / (uint256(p0.resUsdg) + net);
        assertEq(paid, 1_000e6);
        assertEq(got, expect);
        BorroHook.Pool memory p1 = _pool();
        assertEq(p1.squeezeHeld, 0);
        assertEq(p1.feesUsdg, 3e6, "LP fee recorded");
        assertGt(uint256(p1.resUsdg) * p1.resStock, uint256(p0.resUsdg) * p0.resStock, "k grows");
        _assertSolvent();
    }

    function test_swap_stock_for_usdg_exact_in() public {
        BorroHook.Pool memory p0 = _pool();
        (uint256 paid, uint256 got) = _swap(bob, false, true, 5e18);
        uint256 net = 5e18 - 5e18 * 3_000 / 1e6;
        assertEq(paid, 5e18);
        assertEq(got, uint256(p0.resUsdg) * net / (uint256(p0.resStock) + net));
        _assertSolvent();
    }

    function test_exact_out_both_ways_never_undercharges() public {
        BorroHook.Pool memory p0 = _pool();
        (uint256 paid, uint256 got) = _swap(bob, true, false, 2e18); // want exactly 2 stock
        assertEq(got, 2e18);
        // paying `paid` exact-in would have given at least 2 stock
        uint256 net = paid - (paid * 3_000 + 1e6 - 1) / 1e6;
        assertGe(uint256(p0.resStock) * net / (uint256(p0.resUsdg) + net), 2e18 - 1);
        (paid, got) = _swap(carol, false, false, 300e6); // want exactly $300
        assertEq(got, 300e6);
        assertGt(paid, 3e18);
        _assertSolvent();
    }

    function test_a_swap_bigger_than_the_buffer_draws_on_the_vault() public {
        // the stock doubles: buying toward the feed takes ~310 stock, more than the 300 in the buffer
        feed.set(210e8, block.timestamp);
        (, uint256 got) = _swap(bob, true, true, 46_000e6);
        assertGt(got, 300e18);
        BorroHook.Pool memory p = _pool();
        assertLt(sVault.previewRedeem(p.lentStock), 700e18, "some stock came back from the vault");
        _assertSolvent();
    }

    function test_when_the_vault_is_borrowed_out_only_the_buffer_trades() public {
        // shorters borrow every stock in the vault
        sVault.lend(stock.balanceOf(address(sVault)), shorter);
        (, uint256 got) = _swap(bob, true, true, 1_000e6); // within the buffer: fine
        assertGt(got, 0);
        uint256 left = _pool().bufStock;
        feed.set(210e8, block.timestamp);
        vm.expectRevert();
        this.swapAsBob(true, true, 46_000e6); // needs more stock than the buffer holds, and the vault has none free
        assertEq(_pool().bufStock, left, "nothing changed");
    }

    function swapAsBob(bool usdgIn, bool exactIn, uint256 amount) external {
        _swap(bob, usdgIn, exactIn, amount);
    }

    // ---------------------------------------------------------------- squeeze fee

    function test_squeeze_rises_with_short_use_and_is_capped() public {
        (uint256 use, uint256 sur) = hook.squeeze(id);
        assertEq(use, 0);
        assertEq(sur, 0);
        morpho.setUse(Id.wrap(deskId), 1000e18, 500e18);
        (, sur) = hook.squeeze(id);
        assertEq(sur, 0, "nothing at the 50% start");
        morpho.setUse(Id.wrap(deskId), 1000e18, 750e18);
        (use, sur) = hook.squeeze(id);
        assertEq(use, 7_500);
        assertEq(sur, 5_000, "half way: 0.5%");
        morpho.setUse(Id.wrap(deskId), 1000e18, 2000e18); // more borrowed than supplied (bad debt): capped
        (use, sur) = hook.squeeze(id);
        assertEq(use, 10_000);
        assertEq(sur, 10_000);
    }

    function test_the_surcharge_is_held_in_usdg_and_flush_pays_lenders_and_pots() public {
        morpho.setUse(Id.wrap(deskId), 1000e18, 1000e18); // fully borrowed: +1%
        _swap(bob, true, true, 1_000e6);
        _swap(bob, false, true, 1e18);
        BorroHook.Pool memory p = _pool();
        assertGt(p.squeezeHeld, 10e6, "about 1% of $1,100");
        _assertSolvent();
        uint256 vaultStock = stock.balanceOf(address(sVault));
        (uint256 toPots, uint256 toLenders, uint256 stockToLenders) = hook.flush(id);
        assertEq(toPots + toLenders, p.squeezeHeld);
        assertEq(toLenders, p.squeezeHeld / 2);
        assertEq(pots.funded(), toPots);
        assertEq(stock.balanceOf(address(sVault)) - vaultStock, stockToLenders, "the stock went to the lenders");
        assertLe(stockToLenders, toLenders * 1e18 / 100e6, "never more stock than the feed price gives");
        assertEq(_pool().squeezeHeld, 0);
        _assertSolvent();
    }

    function test_flush_with_a_stale_feed_still_funds_the_pots_and_keeps_the_lender_part() public {
        morpho.setUse(Id.wrap(deskId), 1000e18, 1000e18);
        _swap(bob, true, true, 1_000e6);
        uint256 held = _pool().squeezeHeld;
        vm.warp(block.timestamp + 2 days);
        (uint256 toPots, uint256 toLenders,) = hook.flush(id);
        assertEq(toLenders, 0);
        assertEq(toPots, held - held / 2);
        assertEq(_pool().squeezeHeld, held / 2);
    }

    // ---------------------------------------------------------------- holder discount

    function test_borro_holders_pay_less_but_never_below_the_floor() public {
        (uint256 lp, uint256 sur, bool holder) = hook.feeFor(id, bob);
        assertEq(lp, 3_000);
        assertFalse(holder);
        borro.mint(bob, 1_000e18);
        (lp, sur, holder) = hook.feeFor(id, bob);
        assertTrue(holder);
        assertEq(lp, 1_500);
        vm.prank(owner);
        hook.setFees(800, 10_000, 5_000, 500);
        (lp,,) = hook.feeFor(id, bob);
        assertEq(lp, 500, "half of 0.08% is under the 0.05% floor");
        sur;
    }

    function test_lenders_and_lps_count_as_holders() public {
        (,, bool holder) = hook.feeFor(id, alice); // alice is this pool's LP
        assertTrue(holder);
        (,, holder) = hook.feeFor(id, carol);
        assertFalse(holder);
        // carol lends $200 of USDG on Borro
        usdg.mint(carol, 200e6);
        vm.startPrank(carol);
        usdg.approve(address(uVault), 200e6);
        uVault.deposit(200e6, carol);
        vm.stopPrank();
        hook.rebalance(id); // the hook's view of bUSDG's price
        (,, holder) = hook.feeFor(id, carol);
        assertTrue(holder);
    }

    function test_the_discount_reaches_the_real_trader_through_a_trusted_router_only() public {
        borro.mint(bob, 1_000e18);
        // untrusted router: the hook falls back to tx.origin, which is bob in _swap
        uint256 before = _pool().feesUsdg;
        _swap(bob, true, true, 100e6);
        assertEq(_pool().feesUsdg - before, 150_000, "half fee via tx.origin");
        // carol (no BORRO) pays the full fee
        before = _pool().feesUsdg;
        _swap(carol, true, true, 100e6);
        assertEq(_pool().feesUsdg - before, 300_000);
        // a trusted router reports its caller: carol sending through it is carol, even if tx.origin were bob
        vm.prank(owner);
        hook.setRouter(address(router), true);
        usdg.mint(carol, 100e6);
        vm.startPrank(carol, bob);
        usdg.approve(address(router), 100e6);
        before = _pool().feesUsdg;
        router.swap(key, Currency.unwrap(key.currency0) == address(usdg), -100e6);
        vm.stopPrank();
        assertEq(_pool().feesUsdg - before, 300_000, "the router named carol: full fee");
    }

    // ---------------------------------------------------------------- price guard

    function test_a_swap_ending_beyond_the_guard_is_refused() public {
        // ~7% of the pool's USDG moves the price ~14% up: refused
        vm.expectRevert();
        this.swapAsBob(true, true, 7_500e6 * 10);
        // a 2% move is fine
        _swap(bob, true, true, 1_000e6);
    }

    function test_after_the_feed_moves_only_swaps_toward_it_run() public {
        feed.set(110e8, block.timestamp); // the stock went up 10%; the pool still says $100
        vm.expectRevert();
        this.swapAsBob(false, true, 1e18); // selling stock pushes further from $110: refused
        _swap(bob, true, true, 2_000e6); // buying stock moves toward $110: allowed
        assertGt(_price(), 100e8);
    }

    function test_a_stale_feed_stops_swaps_but_never_withdrawals() public {
        vm.warp(block.timestamp + 25 hours + 1);
        vm.expectRevert(); // Stale, wrapped by the PoolManager
        this.swapAsBob(true, true, 1_000e6);
        (uint256 u, uint256 s,,) = _withdraw(alice, share.balanceOf(alice));
        assertGt(u, 99_000e6);
        assertGt(s, 990e18);
    }

    // ---------------------------------------------------------------- withdrawals

    function test_withdraw_pays_tokens_pro_rata() public {
        _swap(bob, true, true, 1_000e6);
        BorroHook.Pool memory p = _pool();
        uint256 sh = share.balanceOf(alice);
        uint256 supply = share.totalSupply();
        uint256 wantU = uint256(p.bufUsdg) * sh / supply + uVault.previewRedeem(uint256(p.lentUsdg) * sh / supply);
        (uint256 u, uint256 s, uint256 us, uint256 ss) = _withdraw(alice, sh);
        assertEq(us, 0);
        assertEq(ss, 0);
        assertApproxEqAbs(u, wantU, 2);
        assertGt(s, 0);
        _assertSolvent();
    }

    function test_withdraw_while_the_stock_is_rented_out_hands_over_the_vault_shares() public {
        sVault.lend(stock.balanceOf(address(sVault)), shorter); // every lent stock is out with shorters
        uint256 sh = share.balanceOf(alice);
        (uint256 u, uint256 s, uint256 us, uint256 ss) = _withdraw(alice, sh);
        assertGt(u, 0, "USDG side paid");
        assertApproxEqRel(s, 300e18 * sh / (sh + 1000), 1e15, "the stock buffer paid");
        assertGt(ss, 0, "the rented part comes as vault shares");
        assertEq(us, 0);
        assertEq(sVault.balanceOf(alice), ss);
        // shorters return the stock: alice redeems herself, straight from the vault
        stock.mint(shorter, 1); // rounding room
        vm.startPrank(shorter);
        stock.approve(address(sVault), type(uint256).max);
        sVault.repay(sVault.lentOut());
        vm.stopPrank();
        vm.prank(alice);
        uint256 later = sVault.redeem(ss, alice, alice);
        assertApproxEqRel(later, 700e18 * sh / (sh + 1000), 1e15);
    }

    function test_partly_free_vault_pays_what_is_free_and_hands_the_rest() public {
        uint256 inVault = stock.balanceOf(address(sVault));
        sVault.lend(inVault / 2, shorter); // half rented out
        (, uint256 s, , uint256 ss) = _withdraw(alice, share.balanceOf(alice));
        assertGt(s, 300e18 + 300e18, "buffer plus most of the free half");
        assertGt(ss, 0);
    }

    function test_withdraw_works_while_the_pool_manager_is_busy() public {
        // claims from swaps cannot be turned into tokens inside someone else's unlock; they are paid as claims
        _swap(bob, false, true, 10e18); // the hook now holds stock claims
        BusyCaller busy = new BusyCaller(pm);
        uint256 sh = share.balanceOf(alice) / 2;
        vm.prank(alice);
        share.transfer(address(busy), sh);
        busy.run(address(hook), abi.encodeCall(hook.withdraw, (id, sh, 0, 0, address(busy))));
        uint256 claims = pm.balanceOf(address(busy), uint256(uint160(address(stock))));
        assertGt(stock.balanceOf(address(busy)) + claims, 0);
        _assertSolvent();
    }

    function test_withdraw_respects_minimums() public {
        uint256 sh = share.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        hook.withdraw(id, sh, 200_000e6, 0, alice);
    }

    // ---------------------------------------------------------------- rent

    function test_rent_raises_what_the_pool_is_worth_and_lps_get_it() public {
        uint256 before = _pool().resStock;
        sVault.accrue(70e18); // 10% rent on the lent 700
        hook.rebalance(id);
        assertApproxEqAbs(_pool().resStock - before, 70e18, 1e9);
        // pay the rent in so the vault can pay out
        stock.mint(address(this), 70e18);
        stock.approve(address(sVault), 70e18);
        sVault.repay(70e18);
        (, uint256 s,,) = _withdraw(alice, share.balanceOf(alice));
        assertGt(s, 1_000e18 + 69e18 - 1e18);
    }

    function test_rebalance_tops_the_buffer_up_from_the_vault_and_lends_excess() public {
        feed.set(150e8, block.timestamp);
        _swap(bob, true, true, 22_000e6); // the stock rose 50%; buying toward it drains the stock buffer
        hook.rebalance(id);
        BorroHook.Pool memory p = _pool();
        assertApproxEqRel(p.bufStock, uint256(p.resStock) * 3 / 10, 1e16, "stock buffer back to 30%");
        assertApproxEqRel(p.bufUsdg, uint256(p.resUsdg) * 3 / 10, 1e16, "USDG excess lent");
        _assertSolvent();
    }

    function test_a_vault_that_refuses_deposits_leaves_money_in_the_pool() public {
        sVault.setRefuseDeposits(true);
        _deposit(bob, 10_000e6, 100e18);
        _assertSolvent();
        assertGt(_pool().bufStock, 300e18 + 99e18);
    }

    // ---------------------------------------------------------------- owner limits

    function test_owner_settings_stay_inside_the_hard_caps() public {
        vm.startPrank(owner);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setFees(10_001, 0, 0, 0);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setFees(3_000, 20_001, 0, 0);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setFees(3_000, 0, 10_000, 0);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setFees(3_000, 0, 0, 3_001);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setDiscount(5_001, 0, 0);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setGuard(49, 1 hours);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setGuard(1_501, 1 hours);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setGuard(300, 4 days + 1);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setBuffer(999);
        vm.expectRevert(BorroHook.OutOfBounds.selector);
        hook.setLenderShare(10_001);
        hook.setFees(10_000, 20_000, 0, 0);
        hook.setGuard(1_500, 4 days);
        vm.stopPrank();
    }

    function test_a_vault_calling_back_into_the_hook_gets_nowhere() public {
        // a second stock whose vault tries to swap and to withdraw while the hook is lending to it
        MockToken other = new MockToken("TSLA", 18);
        MarketParams memory m = MarketParams({loanToken: address(other), collateralToken: address(0xC0), oracle: address(0x0C), irm: address(0x1), lltv: 0.625e18});
        bytes32 d2 = Id.unwrap(m.id());
        desks.setDesk(d2, m, address(feed));
        ReenteringVault evil = new ReenteringVault(other, 18);
        vm.prank(owner);
        PoolId id2 = hook.register(d2, IVault(address(evil)));
        PoolKey memory k2 = hook.keyFor(address(other));
        pm.initialize(k2, SQRT_1_1);
        usdg.mint(address(evil), 1e12);
        other.mint(address(evil), 1e24);
        vm.startPrank(address(evil));
        usdg.approve(address(router), type(uint256).max);
        other.approve(address(router), type(uint256).max);
        vm.stopPrank();
        evil.arm(router, k2, address(hook), abi.encodeCall(hook.withdraw, (id, 1, 0, 0, address(evil))));
        usdg.mint(bob, 100_000e6);
        other.mint(bob, 1_000e18);
        vm.startPrank(bob);
        usdg.approve(address(hook), type(uint256).max);
        other.approve(address(hook), type(uint256).max);
        hook.deposit(id2, 100_000e6, 1_000e18, 0, bob);
        vm.stopPrank();
        assertFalse(evil.swapGotIn(), "a swap inside the hook's own call is refused");
        assertFalse(evil.withdrawGotIn(), "a withdrawal inside the hook's own call is refused");
        BorroHook.Pool memory p2 = hook.poolOf(id2);
        assertEq(p2.resStock, 1_000e18, "nothing moved");
    }

    /// Wallets estimate gas by finding the least that makes a transaction succeed. With the vault calls in try/catch,
    /// a limit that starves the vault call must fail the whole deposit, never succeed with the lending skipped.
    function test_no_gas_limit_lets_a_deposit_skip_its_lending() public {
        usdg.mint(bob, 1e12);
        stock.mint(bob, 1e22);
        vm.startPrank(bob);
        usdg.approve(address(hook), type(uint256).max);
        stock.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        sVault.setDepositGas(350_000); // like the real NVDA vault, through its adapter into Morpho
        uint256 lentBefore = _pool().lentStock;
        uint256 snap = vm.snapshotState();
        uint256 succeeded;
        for (uint256 g = 150_000; g < 1_200_000; g += 2_500) {
            vm.revertToState(snap);
            vm.prank(bob);
            try hook.deposit{gas: g}(id, 10_000e6, 100e18, 0, bob) {
                succeeded++;
                assertGt(_pool().lentStock, lentBefore, "a deposit that went through also lent");
                _assertSolvent();
            } catch {}
        }
        assertGt(succeeded, 0, "enough gas works");
    }

    function test_only_the_pool_manager_calls_the_hook_callbacks() public {
        vm.expectRevert(BorroHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(BorroHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_1_1);
    }

    function test_settings_never_trap_lp_money() public {
        vm.startPrank(owner);
        hook.setFees(10_000, 20_000, 0, 10_000);
        hook.setGuard(50, 1 hours);
        hook.setBuffer(10_000);
        hook.setLenderShare(10_000);
        hook.setDepositsPaused(id, true);
        hook.setDiscount(0, 0, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        feed.set(1, 0);
        (uint256 u, uint256 s,,) = _withdraw(alice, share.balanceOf(alice));
        assertApproxEqRel(u, 100_000e6, 1e14);
        assertApproxEqRel(s, 1_000e18, 1e14);
    }
}
