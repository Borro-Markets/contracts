// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMorpho, MarketParams, Id, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {BorroHook} from "../../src/hooks/BorroHook.sol";
import {IVault, IDesks, IFeed} from "../../src/hooks/BorroHookDeps.sol";
import {BorroHookShare} from "../../src/hooks/BorroHookShare.sol";
import {TestRouter} from "./BorroHookMocks.sol";
import {DeployBorroHook} from "../../script/BorroHook.s.sol";

interface IPotsR {
    function rentPot() external view returns (uint256);
    function week() external view returns (uint256);
    function prizePot(uint256) external view returns (uint256);
}

interface IHeldVault {
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
}

interface IVaultV2R {
    function totalAssets() external view returns (uint256);
    function maxRate() external view returns (uint256);
}

/// The review of 2026-10-08 on a copy of the LIVE chain at its latest block: BorroHook deployed by its own deploy script
/// (script/BorroHook.s.sol: every desk in desks.json registered, the registry closed, ownership offered to the Hoard
/// Safe, which accepts), then every pool used for real and the attacks the review looked at tried against it.
///   BORRO_FORK_RPC=<rpc> forge test --match-contract BorroHookReviewForkTest -vv
contract BorroHookReviewForkTest is Test {
    using StateLibrary for IPoolManager;
    using MarketParamsLib for MarketParams;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    IDesks constant SHORT = IDesks(0xd2D686cEdf225c5C9815187A08812783904E62Eb);
    IVault constant BUSDG = IVault(0xF8e0ab443098c0738489B5BAFFbd32A1341F2289);
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    struct Desk {
        address adapter;
        bytes32 marketId;
        address oracle;
        string symbol;
        bytes32 usdgMarketId;
        address usdgOracle;
        address vault;
    }

    bool forked;
    BorroHook hook;
    TestRouter router;
    IMorpho morpho;
    Desk[] desks;
    PoolId[] ids;

    address lp = makeAddr("review lp");
    address lp2 = makeAddr("review lp2");
    address trader = makeAddr("review trader");
    address attacker = makeAddr("review attacker");
    address victim = makeAddr("review victim");
    address shorter = makeAddr("review shorter");

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
        Desk[] memory ds = abi.decode(vm.parseJson(vm.readFile("script/out/desks.json"), ".desks"), (Desk[]));
        for (uint256 i; i < ds.length; i++) desks.push(ds[i]);

        // The deploy script itself, as the owner runs it (its record goes to a file of its own, removed below).
        vm.setEnv("HOOK_OUT", "borro-hook-reviewfork");
        DeployBorroHook script = new DeployBorroHook();
        hook = script.run();
        vm.removeFile("script/out/borro-hook-reviewfork.dryrun.json");
        PoolId[] memory all = hook.pools();
        for (uint256 i; i < all.length; i++) ids.push(all[i]);
        vm.prank(SAFE);
        hook.acceptOwnership();
        router = new TestRouter(PM);
    }

    // ---------------------------------------------------------------- helpers

    function _p(uint256 i) internal view returns (BorroHook.Pool memory) {
        return hook.poolOf(ids[i]);
    }

    function _feedE8(BorroHook.Pool memory p) internal view returns (uint256 px, bool fresh) {
        (, int256 a,, uint256 at,) = IFeed(p.feed).latestRoundData();
        px = uint256(a) * 1e8 / p.feedScale;
        fresh = block.timestamp - at <= hook.maxFeedAge();
    }

    /// Tokens for tests: deal, or from the PoolManager (it holds every token) when deal cannot find the balance slot.
    function _give(address token, address to, uint256 amount) internal {
        try this.dealExt(token, to, amount) {}
        catch {
            vm.prank(address(PM));
            IERC20(token).transfer(to, amount);
        }
    }

    function dealExt(address token, address to, uint256 amount) external {
        deal(token, to, IERC20(token).balanceOf(to) + amount);
    }

    /// `who` deposits `usd` dollars a side at the feed price.
    function _deposit(uint256 i, address who, uint256 usd) internal returns (uint256 shares, uint256 u, uint256 s) {
        BorroHook.Pool memory p = _p(i);
        (uint256 px,) = _feedE8(p);
        uint256 uAmt = usd * 1e6;
        uint256 sAmt = usd * 1e8 * 10 ** p.stockDecimals / px;
        _give(address(USDG), who, uAmt);
        _give(p.stock, who, sAmt);
        vm.startPrank(who);
        USDG.approve(address(hook), uAmt);
        IERC20(p.stock).approve(address(hook), sAmt);
        (shares, u, s) = hook.deposit(ids[i], uAmt, sAmt, 0, who);
        vm.stopPrank();
    }

    function _key(uint256 i) internal view returns (PoolKey memory) {
        return hook.keyFor(_p(i).stock);
    }

    /// Exact-in swap through the router as `who` (msg.sender and tx.origin). Returns what came out.
    function _swap(uint256 i, address who, bool usdgIn, uint256 amountIn) internal returns (uint256 got) {
        BorroHook.Pool memory p = _p(i);
        IERC20 tIn = usdgIn ? USDG : IERC20(p.stock);
        IERC20 tOut = usdgIn ? IERC20(p.stock) : USDG;
        _give(address(tIn), who, amountIn);
        uint256 before = tOut.balanceOf(who);
        vm.startPrank(who, who);
        tIn.approve(address(router), amountIn);
        router.swap(_key(i), usdgIn == p.usdgIs0, -int256(amountIn));
        vm.stopPrank();
        got = tOut.balanceOf(who) - before;
    }

    function swapExt(uint256 i, address who, bool usdgIn, uint256 amountIn) external returns (uint256) {
        return _swap(i, who, usdgIn, amountIn);
    }

    function _withdrawAll(uint256 i, address who) internal returns (uint256 u, uint256 s, uint256 us, uint256 ss) {
        uint256 bal = _p(i).share.balanceOf(who);
        vm.prank(who);
        return hook.withdraw(ids[i], bal, 0, 0, who);
    }

    /// The hook's tokens and claims cover every pool's buffer and held surcharge; its vault shares match the books.
    function _solvent() internal view {
        uint256 bufU;
        uint256 lentU;
        for (uint256 i; i < ids.length; i++) {
            BorroHook.Pool memory p = _p(i);
            bufU += uint256(p.bufUsdg) + p.squeezeHeld;
            lentU += p.lentUsdg;
            uint256 heldS = IERC20(p.stock).balanceOf(address(hook)) + PM.balanceOf(address(hook), uint160(p.stock));
            assertGe(heldS, p.bufStock, "stock covers its buffer");
            assertEq(IERC20(address(p.stockVault)).balanceOf(address(hook)), p.lentStock, "stock vault shares match");
        }
        assertGe(USDG.balanceOf(address(hook)) + PM.balanceOf(address(hook), uint160(address(USDG))), bufU, "USDG covers every buffer and surcharge");
        assertEq(BUSDG.balanceOf(address(hook)), lentU, "bUSDG shares match");
    }

    function _idx(string memory sym) internal view returns (uint256) {
        for (uint256 i; i < desks.length; i++) if (keccak256(bytes(desks[i].symbol)) == keccak256(bytes(sym))) return i;
        revert("no desk");
    }

    function _poolPrice(uint256 i) internal view returns (uint256) {
        BorroHook.Pool memory p = _p(i);
        return uint256(p.resUsdg) * 1e8 * 10 ** p.stockDecimals / (uint256(p.resStock) * 1e6);
    }

    /// A shorter borrows `amount` of the stock from its Borro market against USDG in BorroShort's held vault.
    function _short(uint256 i, uint256 amount) internal {
        (MarketParams memory m,,,,) = SHORT.deskOf(desks[i].marketId);
        (uint256 px,) = _feedE8(_p(i));
        uint256 cash = amount * px / 1e20 * 4 + 1e6;
        _give(address(USDG), shorter, cash);
        vm.startPrank(shorter);
        USDG.approve(m.collateralToken, cash);
        uint256 sh = IHeldVault(m.collateralToken).deposit(cash, shorter);
        IERC20(m.collateralToken).approve(address(morpho), sh);
        morpho.supplyCollateral(m, sh, shorter, "");
        morpho.borrow(m, amount, 0, shorter, shorter);
        vm.stopPrank();
    }

    function _free(uint256 i) internal view returns (uint256) {
        Market memory m = morpho.market(Id.wrap(desks[i].marketId));
        return m.totalSupplyAssets - m.totalBorrowAssets;
    }

    // ---------------------------------------------------------------- deploy readiness

    function test_review_fork_the_script_deploys_every_live_desk_and_hands_the_hook_to_the_safe() public onFork {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS, "exactly the four permissions");
        assertEq(ids.length, desks.length, "a pool per desk");
        assertEq(desks.length, 9);
        assertTrue(hook.registryClosed(), "listing closed for good");
        assertEq(hook.owner(), SAFE, "the Safe owns it after acceptOwnership");
        assertEq(address(hook.desks()), address(SHORT));
        assertEq(address(hook.usdgVault()), address(BUSDG));
        for (uint256 i; i < ids.length; i++) {
            BorroHook.Pool memory p = _p(i);
            (MarketParams memory m,,,, address feed) = SHORT.deskOf(desks[i].marketId);
            assertEq(p.marketId, desks[i].marketId, desks[i].symbol);
            assertEq(Id.unwrap(m.id()), desks[i].marketId, "the live desk's market");
            assertEq(p.stock, m.loanToken, "the desk's stock");
            assertEq(address(p.stockVault), desks[i].vault, "desks.json's vault");
            assertEq(IVault(desks[i].vault).asset(), p.stock, "which lends that stock");
            assertEq(p.feed, feed, "BorroShort's feed");
            assertEq(p.stockDecimals, 18);
            (uint160 sqrtP,,,) = PM.getSlot0(ids[i]);
            assertGt(sqrtP, 0, "started in Uniswap v4");
            assertEq(BorroHookShare(address(p.share)).hook(), address(hook));
            (uint256 px, bool fresh) = _feedE8(p);
            emit log_named_string("pool", string.concat(desks[i].symbol, fresh ? " (feed fresh)" : " (feed STALE)"));
            emit log_named_uint("  feed E8", px);
        }
        // nobody lists a pool again, not even the Safe
        vm.prank(SAFE);
        vm.expectRevert(BorroHook.RegistryClosed.selector);
        hook.register(desks[0].marketId, IVault(desks[0].vault));
    }

    // ---------------------------------------------------------------- every pool, used for real

    function test_review_fork_every_pool_takes_lps_and_swaps_both_ways() public onFork {
        for (uint256 i; i < ids.length; i++) {
            BorroHook.Pool memory p = _p(i);
            (uint256 px, bool fresh) = _feedE8(p);
            if (!fresh) {
                emit log_named_string("skipped (feed stale, swaps and first deposits wait for it)", desks[i].symbol);
                continue;
            }
            _deposit(i, lp, 20_000);
            _deposit(i, lp2, 1_000);
            p = _p(i);
            assertApproxEqRel(_poolPrice(i), px, 1e15, "priced at the feed");
            assertGt(p.lentStock, 0, "stock lent to the desk's vault");
            assertGt(p.lentUsdg, 0, "USDG lent to bUSDG");
            uint256 k0 = uint256(p.resUsdg) * p.resStock;
            uint256 got = _swap(i, trader, true, 100e6);
            uint256 fair = 100e6 * 10 ** p.stockDecimals * 1e2 / px;
            assertApproxEqRel(got, fair, 0.02e18, "$100 in: within 2% of the feed");
            uint256 back = _swap(i, trader, false, got);
            assertLt(back, 100e6, "the round trip pays the fee");
            assertGt(back, 98e6, "and only the fee");
            p = _p(i);
            assertGe(uint256(p.resUsdg) * p.resStock, k0, "k never falls");
            (uint256 u2, uint256 s2,,) = _withdrawAll(i, lp2);
            assertApproxEqRel(u2 + s2 * px / 1e20, 2_000e6, 0.005e18, "lp2 leaves with its $2,000, less a little");
            emit log_named_string("pool used", desks[i].symbol);
        }
        _solvent();
    }

    // ---------------------------------------------------------------- squeeze fee and flush, with real shorts

    function test_review_fork_squeeze_and_flush_with_real_shorts() public onFork {
        uint256 i = _idx("NVDA");
        _deposit(i, lp, 50_000);
        _short(i, _free(i) * 9 / 10);
        (uint256 use, uint256 sur) = hook.squeeze(ids[i]);
        emit log_named_uint("NVDA use bps", use);
        emit log_named_uint("surcharge pips", sur);
        assertGt(sur, 5_000);
        _swap(i, trader, true, 300e6);
        _swap(i, trader, false, 1e18);
        uint256 held = _p(i).squeezeHeld;
        assertGt(held, 0);
        address pots = SHORT.rewards();
        uint256 potsBefore = IPotsR(pots).rentPot() + IPotsR(pots).prizePot(IPotsR(pots).week());
        BorroHook.Pool memory p = _p(i);
        uint256 vaultIdle = IERC20(p.stock).balanceOf(address(p.stockVault));
        uint256 vaultTa = IVaultV2R(address(p.stockVault)).totalAssets();
        (uint256 toPots, uint256 toLenders, uint256 stockToLenders) = hook.flush(ids[i]);
        assertEq(toPots + toLenders, held, "all of it");
        assertEq(IPotsR(pots).rentPot() + IPotsR(pots).prizePot(IPotsR(pots).week()) - potsBefore, toPots, "pots funded");
        assertEq(IERC20(p.stock).balanceOf(address(p.stockVault)) - vaultIdle, stockToLenders, "stock to the vault");
        (uint256 px,) = _feedE8(p);
        assertLe(stockToLenders, toLenders * 1e20 / px, "never more stock than the feed price gives");
        // The vault shows the gift in its share price over time (its maxRate caps how fast; 10% performance fee).
        vm.warp(block.timestamp + 1 days);
        uint256 grew = IVaultV2R(address(p.stockVault)).totalAssets() - vaultTa;
        emit log_named_uint("stock to lenders", stockToLenders);
        emit log_named_uint("vault totalAssets grew by (a day later, with rent)", grew);
        emit log_named_uint("vault maxRate", IVaultV2R(address(p.stockVault)).maxRate());
        assertGe(grew, stockToLenders * 9 / 10, "the lenders get it (less the vault's fee)");
        _solvent();
    }

    // ---------------------------------------------------------------- withdrawals when the vault cannot pay

    function test_review_fork_withdrawal_while_every_lent_stock_is_out_with_shorters() public onFork {
        uint256 i = _idx("NVDA");
        _deposit(i, lp, 10_000);
        _short(i, _free(i)); // every NVDA in the market borrowed, the pool's lent part included
        BorroHook.Pool memory p = _p(i);
        assertEq(_free(i), 0);
        (uint256 u, uint256 s, uint256 us, uint256 ss) = _withdrawAll(i, lp);
        assertGt(u, 0, "USDG side paid");
        assertGt(s, 0, "stock buffer paid");
        assertGt(ss, 0, "the rented part handed over as NVDA vault shares");
        assertEq(us, 0, "bUSDG had room: paid in USDG");
        assertEq(IERC20(address(p.stockVault)).balanceOf(lp), ss);
        // The shorter repays; the LP redeems its vault shares straight from the vault.
        (MarketParams memory m,,,,) = SHORT.deskOf(desks[i].marketId);
        vm.warp(block.timestamp + 7 days);
        morpho.accrueInterest(m);
        uint256 owed = morpho.position(m.id(), shorter).borrowShares;
        _give(p.stock, shorter, 1_000e18);
        vm.startPrank(shorter);
        IERC20(p.stock).approve(address(morpho), type(uint256).max);
        morpho.repay(m, 0, owed, shorter, "");
        vm.stopPrank();
        vm.prank(lp);
        uint256 later = p.stockVault.redeem(ss, lp, lp);
        (uint256 px,) = _feedE8(p);
        uint256 lentAtStart = 10_000e8 * 1e18 / px * 7 / 10;
        emit log_named_uint("NVDA redeemed later", later);
        assertGt(later, lentAtStart * 999 / 1000, "the lent stock came back, with rent");
        _solvent();
    }

    // ---------------------------------------------------------------- attacks

    /// H-1 (fixed): a griefer is first into a fresh pool and leaves. The locked part keeps the price; the next LP is safe.
    function test_review_fork_a_griefed_empty_pool_keeps_its_price_and_the_next_lp_is_safe() public onFork {
        uint256 i = _idx("TSLA");
        BorroHook.Pool memory p = _p(i);
        (uint256 px, bool fresh) = _feedE8(p);
        if (!fresh) return;
        _give(address(USDG), attacker, 1e9);
        _give(p.stock, attacker, 1e20);
        vm.startPrank(attacker);
        USDG.approve(address(hook), type(uint256).max);
        IERC20(p.stock).approve(address(hook), type(uint256).max);
        vm.expectRevert(); // $0.001 cannot lock $1
        hook.deposit(ids[i], 1e3, 1e3 * 1e20 / px, 0, attacker);
        hook.deposit(ids[i], 2e6, 2e6 * 1e20 / px, 0, attacker);
        vm.stopPrank();
        _withdrawAll(i, attacker);
        assertApproxEqRel(_poolPrice(i), px, 0.001e18, "the emptied pool still prices at the feed");
        (, uint256 u, uint256 s) = _deposit(i, victim, 5_000);
        uint256 putIn = u + s * px / 1e20;
        try this.swapExt(i, attacker, false, 1e17) {} catch {}
        (uint256 u2, uint256 s2,,) = _withdrawAll(i, victim);
        assertGe((u2 + s2 * px / 1e20) * 1000, putIn * 995, "the victim keeps its money");
        _solvent();
    }

    /// Sandwiching a flush: buy the stock up to the guard, let the flush buy at the higher price, sell back. The fees
    /// cost more than the flush's own move gives back.
    function test_review_fork_sandwiching_a_flush_does_not_pay() public onFork {
        uint256 i = _idx("NVDA");
        _deposit(i, lp, 50_000);
        _short(i, _free(i) * 9 / 10);
        for (uint256 k; k < 10; k++) {
            uint256 bought = _swap(i, trader, true, 300e6);
            _swap(i, trader, false, bought);
        }
        uint256 held = _p(i).squeezeHeld;
        emit log_named_uint("surcharge held before the flush", held);
        BorroHook.Pool memory p = _p(i);
        // front run: buy NVDA, the price up about 2.4%
        uint256 spent = 600e6;
        uint256 got = _swap(i, attacker, true, spent);
        hook.flush(ids[i]);
        uint256 back = _swap(i, attacker, false, got);
        emit log_named_uint("attacker paid", spent);
        emit log_named_uint("attacker got back", back);
        assertLt(back, spent, "the sandwich loses money");
        p;
        _solvent();
    }

    /// M-1 (not fixed, revenue only): the surcharge reads the market's use at the moment of the swap, so a trader can
    /// supply the stock to Borro's market in the same transaction (from any balance, or a flash loan), swap with no
    /// surcharge, and take the supply back. LPs lose nothing; the surcharge's lenders and pots get less.
    function test_review_fork_squeeze_dodge_by_supplying_the_market_first() public onFork {
        uint256 i = _idx("NVDA");
        _deposit(i, lp, 50_000);
        _short(i, _free(i) * 9 / 10);
        (, uint256 surBefore) = hook.squeeze(ids[i]);
        assertGt(surBefore, 5_000);
        (MarketParams memory m,,,,) = SHORT.deskOf(desks[i].marketId);
        Market memory mk = morpho.market(m.id());
        uint256 supply = uint256(mk.totalSupplyAssets) * 4; // enough to bring use under the 50% start
        _give(m.loanToken, attacker, supply);
        vm.startPrank(attacker);
        IERC20(m.loanToken).approve(address(morpho), supply);
        (, uint256 supShares) = morpho.supply(m, supply, 0, attacker, "");
        vm.stopPrank();
        (, uint256 surDuring) = hook.squeeze(ids[i]);
        uint256 heldBefore = _p(i).squeezeHeld;
        _swap(i, attacker, true, 300e6);
        uint256 paid = _p(i).squeezeHeld - heldBefore;
        vm.prank(attacker);
        morpho.withdraw(m, 0, supShares, attacker, attacker);
        emit log_named_uint("surcharge pips before", surBefore);
        emit log_named_uint("surcharge pips with the supply in", surDuring);
        assertEq(surDuring, 0, "no surcharge while the supply sits in the market");
        assertEq(paid, 0, "the $300 swap paid none");
        _solvent();
    }

    /// Donations: tokens or claims sent straight to the hook are no one's; they move no pool's numbers or share price.
    function test_review_fork_donations_move_no_share_price() public onFork {
        uint256 i = _idx("SPY");
        BorroHook.Pool memory p = _p(i);
        (, bool fresh) = _feedE8(p);
        if (!fresh) return;
        _deposit(i, lp, 2_000);
        BorroHook.Pool memory before = _p(i);
        _give(address(USDG), address(hook), 50_000e6);
        _give(p.stock, address(hook), 10e18);
        BorroHook.Pool memory afterD = _p(i);
        assertEq(afterD.resUsdg, before.resUsdg);
        assertEq(afterD.resStock, before.resStock);
        hook.rebalance(ids[i]);
        BorroHook.Pool memory synced = _p(i);
        assertApproxEqRel(synced.resUsdg, before.resUsdg, 1e12, "a sync counts only the pool's own buffer and lending");
        (uint256 sh,,) = _deposit(i, victim, 2_000);
        assertApproxEqRel(sh, p.share.balanceOf(lp), 0.001e18, "the same money buys the same shares");
        _solvent();
    }

    /// The owner (the Safe) at every extreme the caps allow, with the feed dead: an LP still takes out everything.
    function test_review_fork_the_owner_cannot_reach_lp_money() public onFork {
        uint256 i = _idx("NVDA");
        (, uint256 u0, uint256 s0) = _deposit(i, lp, 10_000);
        vm.startPrank(SAFE);
        hook.setFees(10_000, 20_000, 0, 10_000);
        hook.setGuard(50, 1 hours);
        hook.setBuffer(10_000);
        hook.setLenderShare(10_000);
        hook.setDiscount(5_000, 0, 0);
        hook.setRouter(SAFE, true);
        hook.setDepositsPaused(ids[i], true);
        vm.expectRevert(BorroHook.RegistryClosed.selector);
        hook.register(desks[i].marketId, IVault(desks[i].vault));
        vm.stopPrank();
        BorroHook.Pool memory p = _p(i);
        vm.mockCall(p.feed, abi.encodeWithSelector(IFeed.latestRoundData.selector), abi.encode(uint80(1), int256(0), uint256(0), uint256(0), uint80(1)));
        vm.expectRevert();
        this.swapExt(i, trader, true, 10e6); // no feed: no swaps
        (uint256 u, uint256 s,,) = _withdrawAll(i, lp);
        assertApproxEqRel(u, u0, 0.0003e18, "every USDG back (less the $1 locked)");
        assertApproxEqRel(s, s0, 0.0003e18, "every NVDA back");
        _solvent();
    }

    /// Anyone holding $100 of Borro lending pays half; a trader can become one for the length of a transaction (deposit
    /// $100 into the pool, swap, take it out). By design: the discount only lowers a fee, inside the cap.
    function test_review_fork_the_discount_is_open_to_anyone_who_lends_100_dollars() public onFork {
        uint256 i = _idx("NVDA");
        _deposit(i, lp, 10_000);
        (uint256 full,,) = hook.feeFor(ids[i], trader);
        _deposit(i, trader, 100);
        (uint256 half,, bool holder) = hook.feeFor(ids[i], trader);
        assertTrue(holder);
        assertEq(half, full / 2);
    }

    function test_review_fork_gas() public onFork {
        uint256 i = _idx("NVDA");
        uint256 g = gasleft();
        _deposit(i, lp, 20_000);
        emit log_named_uint("gas: first deposit (lends both sides)", g - gasleft());
        g = gasleft();
        _swap(i, trader, true, 100e6);
        emit log_named_uint("gas: swap through the router", g - gasleft());
        g = gasleft();
        _withdrawAll(i, lp);
        emit log_named_uint("gas: withdraw everything", g - gasleft());
    }
}
