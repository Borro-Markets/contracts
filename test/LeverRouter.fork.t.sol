// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {MarketParams, Id, Position, Authorization, Signature} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {AUTHORIZATION_TYPEHASH} from "morpho-blue/libraries/ConstantsLib.sol";
import {BorroSetup} from "./BorroSetup.sol";
import {BorroSwap} from "../src/BorroSwap.sol";
import {LeverRouter, ILeverDesks, ILeverMarkets} from "../src/LeverRouter.sol";

interface ISwapRouter02 {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
    function refundETH() external payable;
}

/// Moves a stock's pool price for the tests: buys or sells through the same route Borro trades on.
contract PoolMover is BorroSwap {
    ILeverDesks immutable desks;

    constructor(IPoolManager pm, IERC20 usdg_, ILeverDesks desks_) BorroSwap(pm, usdg_) {
        desks = desks_;
    }

    function buy(bytes32 id, uint256 amount) external {
        (MarketParams memory m, PoolKey[] memory route, address v3Pool,,) = desks.deskOf(id);
        _swap(route, v3Pool, m.loanToken, amount, true, false);
    }

    function sell(bytes32 id, uint256 amount) external {
        (MarketParams memory m, PoolKey[] memory route, address v3Pool,,) = desks.deskOf(id);
        _swap(route, v3Pool, m.loanToken, amount, false, false);
    }
}

/// One-click leveraged longs on a fork of Robinhood Chain, against a fresh Borro (BorroSetup) wired to the real
/// Morpho, pools, feeds and tokens. BORRO_FORK_RPC=<rpc> forge test --match-contract LeverRouterForkTest
contract LeverRouterForkTest is BorroSetup {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 constant ETH_POOL_FEE = 100; // the WETH/USDG 0.01% v3 pool

    LeverRouter lever;
    PoolMover mover;
    uint256 dana; // a user with a private key, to sign a Morpho authorization
    address danaAddr;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        lever = new LeverRouter(morpho, IPoolManager(POOL_MANAGER), usdg, ILeverDesks(address(short)), ILeverMarkets(address(router)), owner);
        mover = new PoolMover(IPoolManager(POOL_MANAGER), usdg, ILeverDesks(address(short)));
        (danaAddr, dana) = makeAddrAndKey("dana");
        // USDG to borrow: carl lends to the Borro USDG vault, the keeper moves it into the stocks' USDG markets.
        _lendUsdg(carl, 20_000e6);
        _allocate("NVDA", 8_000e6);
        _allocate("TSLA", 4_000e6);
    }

    // ------------------------------------------------------------------ helpers

    /// What the site sends for `margin` USDG at `levBps` (15_000 = 1.5x): the debt, and the stock it buys with a
    /// little room under margin + debt for the pool's cost.
    function _plan(string memory sym, uint256 margin, uint256 levBps) internal returns (LeverRouter.Open memory o) {
        uint256 debt = (margin * (levBps - 10_000)) / 10_000;
        uint256 spend = margin + debt;
        uint256 a0 = (spend * 1e20) / _price(sym);
        uint256 q = _quote(desk[sym].marketId, a0, true);
        uint256 amount = (((a0 * spend) / q) * 995) / 1000;
        o = LeverRouter.Open({
            desk: desk[sym].marketId,
            market: loan[sym].market,
            margin: margin,
            stockAmount: amount,
            maxCost: spend,
            debt: debt,
            minShares: 0,
            deadline: DL
        });
    }

    function _authorize(address who) internal {
        vm.prank(who);
        morpho.setAuthorization(address(lever), true);
    }

    function _open(address who, string memory sym, uint256 margin, uint256 levBps) internal returns (LeverRouter.Open memory o) {
        o = _plan(sym, margin, levBps);
        deal(address(usdg), who, usdg.balanceOf(who) + margin);
        vm.startPrank(who);
        usdg.approve(address(lever), margin);
        lever.open(o);
        vm.stopPrank();
    }

    function _close(address who, string memory sym, uint256 shareBps) internal returns (uint256 back) {
        vm.prank(who);
        back = lever.close(LeverRouter.Close({desk: desk[sym].marketId, market: loan[sym].market, shareBps: shareBps, minOut: 0, deadline: DL}));
    }

    function _pos(string memory sym, address who) internal view returns (Position memory) {
        return morpho.position(Id.wrap(loan[sym].marketId), who);
    }

    /// Collateral worth at the market's own price, and the debt, in USDG wei.
    function _book(string memory sym, address who) internal returns (uint256 worth, uint256 owed) {
        Position memory p = _pos(sym, who);
        worth = (uint256(p.collateral) * IOracle(loan[sym].market.oracle).price()) / 1e36;
        owed = _owedUsdg(sym, who);
    }

    function _empty(string memory sym) internal view {
        assertEq(usdg.balanceOf(address(lever)), 0, "router holds no USDG");
        assertEq(IERC20(desk[sym].token).balanceOf(address(lever)), 0, "router holds no stock");
        assertEq(IERC20(desk[sym].vault).balanceOf(address(lever)), 0, "router holds no vault shares");
    }

    // ------------------------------------------------------------------ opens

    function test_open_1_5x_nvda_from_usdg() public onFork {
        _authorize(ann);
        uint256 before = usdg.balanceOf(ann);
        LeverRouter.Open memory o = _open(ann, "NVDA", 300e6, 15_000);
        Position memory p = _pos("NVDA", ann);
        assertGt(p.collateral, 0, "vault shares posted for ann");
        (uint256 worth, uint256 owed) = _book("NVDA", ann);
        assertApproxEqAbs(owed, o.debt, 2, "ann owes exactly the debt");
        // Leverage is worth / (worth - debt): about 1.5x after the pool's cost.
        uint256 lev = (worth * 1e4) / (worth - owed);
        assertApproxEqRel(lev, 15_000, 0.03e18, "about 1.5x");
        assertGt(usdg.balanceOf(ann) + 300e6, before, "the unspent USDG came back");
        bytes32 mid = loan["NVDA"].marketId;
        assertEq(lever.basisOf(ann, mid), before + 300e6 - usdg.balanceOf(ann), "basis: what ann put in");
        _empty("NVDA");
    }

    function test_open_1_5x_nvda_from_eth() public onFork {
        _authorize(bob);
        LeverRouter.Open memory o = _plan("NVDA", 250e6, 15_000);
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        // Pay with ETH, as the site does it: exactly the margin in USDG from the WETH/USDG pool, the rest of the ETH back.
        ISwapRouter02(SWAP_ROUTER).exactOutputSingle{value: 1 ether}(
            ISwapRouter02.ExactOutputSingleParams({
                tokenIn: WETH, tokenOut: address(usdg), fee: ETH_POOL_FEE, recipient: bob, amountOut: o.margin, amountInMaximum: 1 ether, sqrtPriceLimitX96: 0
            })
        );
        ISwapRouter02(SWAP_ROUTER).refundETH();
        assertEq(usdg.balanceOf(bob), o.margin, "the margin, bought with ETH");
        usdg.approve(address(lever), o.margin);
        lever.open(o);
        vm.stopPrank();
        assertGt(_pos("NVDA", bob).collateral, 0);
        assertGt(bob.balance, 0, "unspent ETH came back");
        _empty("NVDA");
    }

    function test_open_with_signature_even_when_someone_submits_it_first() public onFork {
        LeverRouter.Open memory o = _plan("NVDA", 200e6, 14_000);
        Authorization memory auth = Authorization({authorizer: danaAddr, authorized: address(lever), isAuthorized: true, nonce: morpho.nonce(danaAddr), deadline: block.timestamp + 1 hours});
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", morpho.DOMAIN_SEPARATOR(), keccak256(abi.encode(AUTHORIZATION_TYPEHASH, auth))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(dana, digest);
        Signature memory sig = Signature(v, r, s);
        // eve sees the signature and submits it first: it only does what dana signed for.
        vm.prank(eve);
        morpho.setAuthorizationWithSig(auth, sig);
        deal(address(usdg), danaAddr, o.margin);
        vm.startPrank(danaAddr);
        usdg.approve(address(lever), o.margin);
        lever.openWithSig(o, auth, sig);
        vm.stopPrank();
        assertGt(_pos("NVDA", danaAddr).collateral, 0, "dana's long is open");
        _empty("NVDA");
    }

    function test_opens_are_held_to_three_quarters_of_the_lltv() public onFork {
        _authorize(ann);
        // NVDA's USDG market lends at 62.5%: 1.8x opens, 2x (50% LTV, past 46.875%) does not.
        _open(ann, "NVDA", 200e6, 18_000);
        (uint256 worth, uint256 owed) = _book("NVDA", ann);
        assertLe(owed * 1e18 / worth, (0.625e18 * 7_500) / 10_000, "under three quarters of the LLTV");
        LeverRouter.Open memory o = _plan("NVDA", 200e6, 20_000);
        deal(address(usdg), carl, o.margin);
        _authorize(carl);
        vm.startPrank(carl);
        usdg.approve(address(lever), o.margin);
        vm.expectPartialRevert(LeverRouter.OverLimit.selector);
        lever.open(o);
        vm.stopPrank();
        // TSLA's lends at 38.5%: 1.35x opens, 1.5x does not.
        _authorize(bob);
        _open(bob, "TSLA", 200e6, 13_500);
        o = _plan("TSLA", 200e6, 15_000);
        deal(address(usdg), bob, o.margin);
        vm.startPrank(bob);
        usdg.approve(address(lever), o.margin);
        vm.expectPartialRevert(LeverRouter.OverLimit.selector);
        lever.open(o);
        vm.stopPrank();
    }

    function test_slippage_bounds() public onFork {
        _authorize(ann);
        LeverRouter.Open memory o = _plan("NVDA", 200e6, 15_000);
        o.maxCost = (o.maxCost * 90) / 100; // less than the purchase costs
        deal(address(usdg), ann, o.margin);
        vm.startPrank(ann);
        usdg.approve(address(lever), o.margin);
        vm.expectPartialRevert(BorroSwap.TooMuch.selector);
        lever.open(o);
        o = _plan("NVDA", 200e6, 15_000);
        o.minShares = type(uint256).max;
        vm.expectPartialRevert(LeverRouter.TooFewShares.selector);
        lever.open(o);
        vm.stopPrank();
        // A close that would bring back less than asked does not happen.
        _open(ann, "NVDA", 200e6, 15_000);
        vm.prank(ann);
        vm.expectPartialRevert(LeverRouter.TooLittleBack.selector);
        lever.close(LeverRouter.Close({desk: desk["NVDA"].marketId, market: loan["NVDA"].market, shareBps: 10_000, minOut: 1_000e6, deadline: DL}));
    }

    // ------------------------------------------------------------------ closes

    function test_price_up_then_close_at_a_profit() public onFork {
        _authorize(ann);
        _open(ann, "NVDA", 300e6, 15_000);
        // Buyers push NVDA's pool up.
        bytes32 id = desk["NVDA"].marketId;
        uint256 probe = (100e6 * 1e20) / _price("NVDA");
        uint256 before = _quote(id, probe, false);
        deal(address(usdg), address(mover), 400_000e6);
        mover.buy(id, (80_000e6 * 1e20) / _price("NVDA"));
        uint256 after_ = _quote(id, probe, false);
        assertGt(after_, (before * 102) / 100, "the pool moved up more than 2%");
        uint256 back = _close(ann, "NVDA", 10_000);
        assertGt(back, 300e6, "more than the margin came back");
        Position memory p = _pos("NVDA", ann);
        assertEq(p.collateral, 0, "no collateral left");
        assertEq(p.borrowShares, 0, "no debt left");
        assertEq(lever.basisOf(ann, loan["NVDA"].marketId), 0, "no basis left");
        _empty("NVDA");
    }

    function test_price_down_then_partial_close() public onFork {
        _authorize(ann);
        _open(ann, "NVDA", 300e6, 15_000);
        Position memory p0 = _pos("NVDA", ann);
        // Sellers push NVDA's pool down.
        bytes32 id = desk["NVDA"].marketId;
        uint256 dump = (1_000e6 * 1e20) / _price("NVDA");
        deal(desk["NVDA"].token, address(mover), dump);
        mover.sell(id, dump);
        uint256 back = _close(ann, "NVDA", 5_000);
        assertLt(back, 150e6, "half the margin, less the fall");
        Position memory p1 = _pos("NVDA", ann);
        assertApproxEqAbs(p1.collateral, p0.collateral / 2, 1, "half the collateral left");
        assertApproxEqAbs(p1.borrowShares, p0.borrowShares / 2, 1, "half the debt left");
        assertGt(lever.basisOf(ann, loan["NVDA"].marketId), 0, "half the basis left");
        _empty("NVDA");
    }

    function test_a_falling_stock_is_liquidated_by_the_existing_liquidator() public onFork {
        _authorize(ann);
        _open(ann, "NVDA", 300e6, 18_000);
        // NVDA's feed falls 35%: past the 28% the open allowed for.
        _setFeed("NVDA", (_price("NVDA") * 65) / 100);
        (uint256 worth, uint256 owed) = _book("NVDA", ann);
        assertGt(owed * 1e18 / worth, 0.625e18, "unhealthy");
        Position memory p = _pos("NVDA", ann);
        vm.prank(eve);
        uint256 profit = liquidator.liquidate(loan["NVDA"].market, ann, 0, p.borrowShares, desk["NVDA"].marketId, 0);
        assertGt(profit, 0, "the liquidator was paid");
        assertEq(_pos("NVDA", ann).borrowShares, 0, "the debt is gone");
    }

    function test_close_while_the_vault_stock_is_lent_out_says_so() public onFork {
        _authorize(ann);
        _open(ann, "NVDA", 300e6, 15_000);
        // A shorter borrows every NVDA the vault lent out.
        bytes32 id = desk["NVDA"].marketId;
        MarketParams memory m = desk["NVDA"].market;
        (uint128 supplied,, uint128 borrowed,,,) = _marketTotals(id);
        uint256 free = uint256(supplied) - uint256(borrowed);
        uint256 collateral = 2 * (free * _price("NVDA")) / 1e20 * 10;
        deal(address(usdg), bob, collateral);
        vm.startPrank(bob);
        usdg.approve(address(held), collateral);
        uint256 heldShares = held.deposit(collateral, bob);
        IERC20(address(held)).approve(address(morpho), heldShares);
        morpho.supplyCollateral(m, heldShares, bob, "");
        morpho.borrow(m, free, 0, bob, bob);
        vm.stopPrank();
        vm.prank(ann);
        vm.expectRevert(LeverRouter.CannotRedeem.selector);
        lever.close(LeverRouter.Close({desk: id, market: loan["NVDA"].market, shareBps: 10_000, minOut: 0, deadline: DL}));
        // The way out the site shows: repay on Morpho directly and take the vault shares, which keep earning.
        uint256 owed = _owedUsdg("NVDA", ann);
        deal(address(usdg), ann, owed);
        vm.startPrank(ann);
        usdg.approve(address(morpho), owed);
        morpho.repay(loan["NVDA"].market, 0, _pos("NVDA", ann).borrowShares, ann, "");
        morpho.withdrawCollateral(loan["NVDA"].market, _pos("NVDA", ann).collateral, ann, ann);
        vm.stopPrank();
        assertGt(IERC20(desk["NVDA"].vault).balanceOf(ann), 0, "ann holds the vault shares");
    }

    function _marketTotals(bytes32 id) internal view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        (bool ok, bytes memory r) = address(morpho).staticcall(abi.encodeWithSignature("market(bytes32)", id));
        require(ok);
        return abi.decode(r, (uint128, uint128, uint128, uint128, uint128, uint128));
    }

    // ------------------------------------------------------------------ nobody acts for anybody else

    function test_an_authorization_never_lets_anyone_else_move_a_position() public onFork {
        _authorize(ann);
        _open(ann, "NVDA", 300e6, 15_000);
        Position memory before = _pos("NVDA", ann);
        // eve has no position: a close acts on eve, not on ann.
        vm.prank(eve);
        vm.expectRevert(LeverRouter.NotAuthorized.selector);
        lever.close(LeverRouter.Close({desk: desk["NVDA"].marketId, market: loan["NVDA"].market, shareBps: 10_000, minOut: 0, deadline: DL}));
        _authorize(eve);
        vm.prank(eve);
        vm.expectRevert(LeverRouter.Nothing.selector);
        lever.close(LeverRouter.Close({desk: desk["NVDA"].marketId, market: loan["NVDA"].market, shareBps: 10_000, minOut: 0, deadline: DL}));
        // ann's signature in eve's hands does not open anything for ann.
        LeverRouter.Open memory o = _plan("NVDA", 100e6, 15_000);
        Authorization memory auth = Authorization({authorizer: ann, authorized: address(lever), isAuthorized: true, nonce: 0, deadline: DL});
        vm.prank(eve);
        vm.expectRevert(LeverRouter.BadSignature.selector);
        lever.openWithSig(o, auth, Signature(27, bytes32(0), bytes32(0)));
        // The flash loan callback only runs inside the router's own call.
        vm.prank(eve);
        vm.expectRevert(LeverRouter.OnlyMorpho.selector);
        lever.onMorphoFlashLoan(1, "");
        vm.prank(address(morpho));
        vm.expectRevert(LeverRouter.NotInFlight.selector);
        lever.onMorphoFlashLoan(1, "");
        Position memory after_ = _pos("NVDA", ann);
        assertEq(after_.collateral, before.collateral, "ann's collateral untouched");
        assertEq(after_.borrowShares, before.borrowShares, "ann's debt untouched");
    }

    function test_pause_stops_opens_never_closes() public onFork {
        _authorize(ann);
        _open(ann, "NVDA", 300e6, 15_000);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        lever.setOpensPaused(true);
        vm.prank(owner);
        lever.setOpensPaused(true);
        LeverRouter.Open memory o = _plan("NVDA", 100e6, 15_000);
        deal(address(usdg), ann, o.margin);
        vm.startPrank(ann);
        usdg.approve(address(lever), o.margin);
        vm.expectRevert(LeverRouter.Paused.selector);
        lever.open(o);
        vm.stopPrank();
        uint256 back = _close(ann, "NVDA", 10_000);
        assertGt(back, 0, "the close went through while opens are paused");
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_router_never_keeps_anything(uint96 marginSeed, uint16 levSeed, uint16 shareSeed) public onFork {
        uint256 margin = bound(uint256(marginSeed), 20e6, 600e6);
        uint256 lev = bound(uint256(levSeed), 10_500, 17_000);
        uint256 share = bound(uint256(shareSeed), 1, 10_000);
        _authorize(ann);
        _open(ann, "NVDA", margin, lev);
        _empty("NVDA");
        (uint256 worth, uint256 owed) = _book("NVDA", ann);
        assertLe(owed * 1e18 / worth, (0.625e18 * 7_500) / 10_000 + 1e12, "within the open limit");
        _close(ann, "NVDA", share);
        _empty("NVDA");
        if (share == 10_000) assertEq(_pos("NVDA", ann).borrowShares, 0);
    }
}
