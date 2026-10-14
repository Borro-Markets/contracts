// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMorpho, MarketParams, Id, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroHook} from "../../src/hooks/BorroHook.sol";
import {IVault, IDesks, IFeed} from "../../src/hooks/BorroHookDeps.sol";
import {BorroHookShare} from "../../src/hooks/BorroHookShare.sol";
import {TestRouter} from "./BorroHookMocks.sol";

interface IPotsView {
    function rentPot() external view returns (uint256);
    function week() external view returns (uint256);
    function prizePot(uint256) external view returns (uint256);
}

interface IHeld {
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
}

/// BorroHook on a copy of the live chain: the real PoolManager, USDG, NVDA and its Chainlink feed, NVDA's Borro
/// vault, Borro's USDG vault, BorroShort, the pots and Morpho. Shorters are real Morpho borrowers of NVDA.
///   BORRO_FORK_RPC=<rpc> forge test --match-contract BorroHookForkTest
contract BorroHookForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IERC20 constant NVDA = IERC20(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    IVault constant NVDA_VAULT = IVault(0x508E23274C39C60c345e35B1f0188bE180717CB9);
    IVault constant BUSDG = IVault(0xF8e0ab443098c0738489B5BAFFbd32A1341F2289);
    IDesks constant SHORT = IDesks(0xd2D686cEdf225c5C9815187A08812783904E62Eb);
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    bytes32 constant NVDA_DESK = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    bool forked;
    BorroHook hook;
    TestRouter router;
    PoolKey key;
    PoolId id;
    BorroHookShare share;
    IMorpho morpho;
    MarketParams market;
    address feed;
    uint256 feedE8;

    address owner = makeAddr("safe");
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");
    address shorter = makeAddr("shorter");

    modifier onFork() {
        if (!forked) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        morpho = SHORT.morpho();
        (market,,,, feed) = SHORT.deskOf(NVDA_DESK);
        (, int256 a,,,) = IFeed(feed).latestRoundData();
        feedE8 = uint256(a) * 1e8 / 10 ** IFeed(feed).decimals();

        bytes memory args = abi.encode(PM, SHORT, BUSDG, BORRO, owner);
        bytes32 initHash = keccak256(abi.encodePacked(type(BorroHook).creationCode, args));
        bytes32 salt;
        for (uint256 i; i < 400_000; i++) {
            address h = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash)))));
            if (uint160(h) & Hooks.ALL_HOOK_MASK == FLAGS && h.code.length == 0) {
                salt = bytes32(i);
                break;
            }
        }
        hook = new BorroHook{salt: salt}(PM, SHORT, BUSDG, BORRO, owner);
        vm.prank(owner);
        id = hook.register(NVDA_DESK, NVDA_VAULT);
        key = hook.keyFor(address(NVDA));
        PM.initialize(key, 79228162514264337593543950336);
        share = BorroHookShare(address(hook.poolOf(id).share));
        router = new TestRouter(PM);

        // 100 NVDA and its worth in USDG, at the feed price
        _deposit(lp, 100e18 * feedE8 / 1e20, 100e18);
    }

    function _deposit(address who, uint256 u, uint256 s) internal returns (uint256 shares) {
        deal(address(USDG), who, USDG.balanceOf(who) + u);
        deal(address(NVDA), who, NVDA.balanceOf(who) + s);
        vm.startPrank(who);
        USDG.approve(address(hook), u);
        NVDA.approve(address(hook), s);
        (shares,,) = hook.deposit(id, u, s, 0, who);
        vm.stopPrank();
    }

    function _swap(address who, bool usdgIn, uint256 amountIn) internal returns (uint256 got) {
        IERC20 tIn = usdgIn ? USDG : NVDA;
        IERC20 tOut = usdgIn ? NVDA : USDG;
        deal(address(tIn), who, tIn.balanceOf(who) + amountIn);
        uint256 before = tOut.balanceOf(who);
        vm.startPrank(who, who);
        tIn.approve(address(router), amountIn);
        router.swap(key, usdgIn == (Currency.unwrap(key.currency0) == address(USDG)), -int256(amountIn));
        vm.stopPrank();
        got = tOut.balanceOf(who) - before;
    }

    function swapExt(address who, bool usdgIn, uint256 amountIn) external returns (uint256) {
        return _swap(who, usdgIn, amountIn);
    }

    /// A shorter borrows `amount` NVDA from its Borro market on Morpho, against USDG in BorroShort's held vault.
    function _short(uint256 amount) internal {
        IHeld held = IHeld(market.collateralToken);
        uint256 cash = amount * feedE8 / 1e20 * 4; // well over the 62.5% limit
        deal(address(USDG), shorter, cash);
        vm.startPrank(shorter);
        USDG.approve(address(held), cash);
        uint256 shares = held.deposit(cash, shorter);
        IERC20(market.collateralToken).approve(address(morpho), shares);
        morpho.supplyCollateral(market, shares, shorter, "");
        morpho.borrow(market, amount, 0, shorter, shorter);
        vm.stopPrank();
    }

    function _free() internal view returns (uint256) {
        Market memory m = morpho.market(Id.wrap(NVDA_DESK));
        return m.totalSupplyAssets - m.totalBorrowAssets;
    }

    function _solvent() internal view {
        BorroHook.Pool memory p = hook.poolOf(id);
        assertGe(USDG.balanceOf(address(hook)) + PM.balanceOf(address(hook), uint160(address(USDG))), uint256(p.bufUsdg) + p.squeezeHeld);
        assertGe(NVDA.balanceOf(address(hook)) + PM.balanceOf(address(hook), uint160(address(NVDA))), p.bufStock);
        assertEq(BUSDG.balanceOf(address(hook)), p.lentUsdg);
        assertEq(NVDA_VAULT.balanceOf(address(hook)), p.lentStock);
    }

    // ----------------------------------------------------------------

    function test_fork_deposit_lends_70_percent_on_borro() public onFork {
        BorroHook.Pool memory p = hook.poolOf(id);
        assertEq(p.bufStock, 30e18);
        assertApproxEqAbs(NVDA_VAULT.previewRedeem(p.lentStock), 70e18, 1e6, "70 NVDA lent to NVDA's Borro vault");
        assertGt(p.lentUsdg, 0, "USDG lent to Borro's USDG vault");
        assertApproxEqRel(hook.poolOf(id).resUsdg * uint256(1e20) / p.resStock, feedE8, 1e15, "priced at the feed");
        _solvent();
    }

    function test_fork_swaps_both_ways() public onFork {
        // the pool holds about $24k a side: $200 moves it under 2%
        uint256 got = _swap(trader, true, 200e6);
        uint256 fair = 200e6 * 1e20 / feedE8;
        assertApproxEqRel(got, fair, 0.015e18, "within 1.5% of the feed for $200");
        uint256 back = _swap(trader, false, got);
        assertApproxEqRel(back, 200e6, 0.01e18);
        assertLt(back, 200e6, "round trip pays the fee");
        _solvent();
    }

    function test_fork_a_stock_move_drains_the_buffer_and_the_swap_draws_on_the_vault() public onFork {
        // NVDA's feed more than doubles: buying toward it takes about 32 of the pool's 100 NVDA, more than the 30 in
        // the buffer (feed answers are 8 decimals on this chain)
        vm.mockCall(feed, abi.encodeWithSelector(IFeed.latestRoundData.selector), abi.encode(uint80(1), int256(feedE8 * 22 / 10), block.timestamp, block.timestamp, uint80(1)));
        uint256 lentBefore = hook.poolOf(id).lentStock;
        uint256 got = _swap(trader, true, 100e18 * feedE8 / 1e20 / 2);
        assertGt(got, 30e18);
        assertLt(hook.poolOf(id).lentStock, lentBefore, "NVDA came back out of the vault");
        _solvent();
    }

    function test_fork_squeeze_fee_from_real_shorts_and_flush_to_the_pots() public onFork {
        _short(_free() * 9 / 10); // 90% of NVDA's market borrowed
        (uint256 use, uint256 sur) = hook.squeeze(id);
        assertGt(use, 8_000);
        assertGt(sur, 5_000, "over 0.5% surcharge");
        _swap(trader, true, 200e6);
        _swap(trader, false, 0.5e18);
        uint256 held = hook.poolOf(id).squeezeHeld;
        assertGt(held, 1e6, "about 0.8% of $320");
        address pots = SHORT.rewards();
        uint256 rentBefore = IPotsView(pots).rentPot();
        uint256 prizeBefore = IPotsView(pots).prizePot(IPotsView(pots).week());
        uint256 vaultIdle = NVDA.balanceOf(address(NVDA_VAULT));
        (uint256 toPots, uint256 toLenders, uint256 stockToLenders) = hook.flush(id);
        assertEq(toPots + toLenders, held);
        assertEq(IPotsView(pots).rentPot() + IPotsView(pots).prizePot(IPotsView(pots).week()) - rentBefore - prizeBefore, toPots, "pots funded");
        assertEq(NVDA.balanceOf(address(NVDA_VAULT)) - vaultIdle, stockToLenders, "NVDA handed to NVDA's lenders");
        assertLe(stockToLenders, toLenders * 1e20 / feedE8, "never above the feed price");
        _solvent();
    }

    function test_fork_borro_holder_discount() public onFork {
        (uint256 lpPips,,) = hook.feeFor(id, trader);
        deal(address(BORRO), trader, 1_000e18);
        (uint256 lpHolder,, bool holder) = hook.feeFor(id, trader);
        assertTrue(holder);
        assertEq(lpHolder, lpPips / 2);
        uint256 before = hook.poolOf(id).feesUsdg;
        _swap(trader, true, 200e6);
        assertEq(hook.poolOf(id).feesUsdg - before, 300_000, "0.15% instead of 0.30%");
    }

    function test_fork_guard_refuses_a_swap_that_pushes_too_far() public onFork {
        vm.expectRevert();
        this.swapExt(trader, true, 3_000e6 * 10); // ~12% of the pool's USDG: far past 3%
    }

    function test_fork_rent_while_lent_and_withdrawal_while_borrowed_out() public onFork {
        _short(_free()); // every NVDA in the market borrowed, including the pool's 70
        uint256 resBefore = hook.poolOf(id).resStock;
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(market);
        hook.rebalance(id);
        uint256 resAfter = hook.poolOf(id).resStock;
        assertGt(resAfter, resBefore, "shorters' rent raised what the pool owns");
        // the LP leaves while all lent NVDA is out with shorters: buffer as tokens, the rest as vault shares
        uint256 sh = share.balanceOf(lp);
        vm.prank(lp);
        (uint256 u, uint256 s, uint256 us, uint256 ss) = hook.withdraw(id, sh, 0, 0, lp);
        assertGt(u, 0);
        assertApproxEqRel(s, 30e18, 0.001e18, "the buffer");
        assertGt(ss, 0, "the rented NVDA as NVDA vault shares");
        assertEq(NVDA_VAULT.balanceOf(lp), ss);
        assertGt(NVDA_VAULT.previewRedeem(ss), 69e18, "worth the 70 lent plus rent, less dust");
        us;
        _solvent();
    }

    function test_fork_full_exit() public onFork {
        _swap(trader, true, 200e6);
        uint256 u0 = 10e18 * feedE8 / 1e20;
        _deposit(lp2, u0, 10e18);
        uint256 putU = u0 - USDG.balanceOf(lp2);
        uint256 putS = 10e18 - NVDA.balanceOf(lp2);
        uint256 sh2 = share.balanceOf(lp2);
        vm.prank(lp2);
        (uint256 u2, uint256 s2,,) = hook.withdraw(id, sh2, 0, 0, lp2);
        assertApproxEqRel(u2, putU, 0.0001e18, "lp2 gets back its USDG");
        assertApproxEqRel(s2, putS, 0.0001e18, "and its NVDA");
        uint256 sh = share.balanceOf(lp);
        vm.prank(lp);
        (uint256 u, uint256 s, uint256 us, uint256 ss) = hook.withdraw(id, sh, 0, 0, lp);
        assertEq(us + ss, 0, "everything free: all paid as tokens");
        assertGt(u * 1e20 / feedE8 + s, 199e18);
        assertEq(share.totalSupply(), share.balanceOf(hook.DEAD()), "only the locked shares remain");
        _solvent();
    }

    function test_fork_gas() public onFork {
        deal(address(USDG), trader, 1_000e6);
        vm.startPrank(trader, trader);
        USDG.approve(address(router), 1_000e6);
        bool zfo = Currency.unwrap(key.currency0) == address(USDG);
        uint256 g = gasleft();
        router.swap(key, zfo, -100e6);
        emit log_named_uint("gas: a swap through the router", g - gasleft());
        vm.stopPrank();
        g = gasleft();
        hook.rebalance(id);
        emit log_named_uint("gas: rebalance", g - gasleft());
        deal(address(USDG), lp2, 2_500e6);
        deal(address(NVDA), lp2, 10e18);
        vm.startPrank(lp2);
        USDG.approve(address(hook), 2_500e6);
        NVDA.approve(address(hook), 10e18);
        g = gasleft();
        hook.deposit(id, 2_500e6, 10e18, 0, lp2);
        emit log_named_uint("gas: deposit (with lending)", g - gasleft());
        uint256 sh = share.balanceOf(lp2);
        g = gasleft();
        hook.withdraw(id, sh, 0, 0, lp2);
        emit log_named_uint("gas: withdraw", g - gasleft());
        vm.stopPrank();
    }
}
