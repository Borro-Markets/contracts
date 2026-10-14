// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {EthPrice} from "../../../src/coins/EthPrice.sol";
import {IUniV3PoolOracle} from "../../../src/coins/CoinFeed.sol";
import {IWETH} from "../../../src/coins/CoinDeps.sol";
import {IHeld} from "../../../src/coins/CoinShort.sol";
import {IHeldRedeem} from "../../../src/coins/CoinLiquidator.sol";
import {CoinCollateral} from "../../../src/coins/CoinCollateral.sol";
import {CoinLens} from "../../../src/coins/v2/CoinLens.sol";
import {CuratedFeeds} from "../../../src/coins/v2/CuratedFeeds.sol";
import {CuratedListing} from "../../../src/coins/v2/CuratedListing.sol";
import {CoinRouter} from "../../../src/coins/v2/CoinRouter.sol";
import {CuratedShort} from "../../../src/coins/v2/CuratedShort.sol";
import {CuratedLiquidator} from "../../../src/coins/v2/CuratedLiquidator.sol";
import {CuratedLoans} from "../../../src/coins/v2/CuratedLoans.sol";
import {CuratedLoanLiquidator} from "../../../src/coins/v2/CuratedLoanLiquidator.sol";
import {PriceMover} from "./CoinLens.fork.t.sol";
import {Venue, CuratedDesk, ICoinFeed, ICuratedListing, IV3Pool, IV3Factory, IStockDesks, VENUE_V3, VENUE_V4, PAIR_ETH} from "../../../src/coins/v2/VenueDeps.sol";

/// Random traffic against curated coins on a copy of the live chain, two coins on two kinds of venue at once (NOVAAI
/// on Uniswap v4 through Pons's hook, CHUMP on Uniswap v3): shorts, coin loans, price moves, squeezes, liquidations,
/// pauses and strangers at the callbacks. Every way out is tried as it comes, and every failure is counted.
contract CuratedHandler is Test {
    using MarketParamsLib for MarketParams;

    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    CuratedListing public listing;
    CuratedShort public short;
    CuratedLiquidator public liq;
    CuratedLoans public loans;
    CuratedLoanLiquidator public lliq;
    CoinRouter public router;
    CoinLens public lens;
    PriceMover public mover;
    address[2] public coins;
    Venue[2] internal venues;
    address[3] public actors;
    address public keeper = makeAddr("cinv keeper");
    address public stranger = makeAddr("cinv stranger");

    uint256 public capBreaches;
    uint256 public closeFailures;
    uint256 public repayFailures;
    uint256 public strangerWins;
    uint256 public opens;
    uint256 public closes;
    uint256 public borrows;
    uint256 public repays;
    uint256 public liquidations;

    constructor(CuratedListing l, CuratedShort s, CuratedLiquidator q, CuratedLoans ln, CuratedLoanLiquidator lq, CoinRouter r, CoinLens le, PriceMover m, address[2] memory c, Venue[2] memory v) {
        (listing, short, liq, loans, lliq, router, lens, mover) = (l, s, q, ln, lq, r, le, m);
        coins = c;
        venues[0] = v[0];
        venues[1] = v[1];
        actors = [makeAddr("cinv a"), makeAddr("cinv b"), makeAddr("cinv c")];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(actors[i]);
            USDG.approve(address(short), type(uint256).max);
            USDG.approve(address(loans), type(uint256).max);
            IERC20(c[0]).approve(address(loans), type(uint256).max);
            IERC20(c[1]).approve(address(loans), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _desk(uint256 i) internal view returns (CuratedDesk memory) {
        return listing.deskOf(coins[i % 2]);
    }

    function _steps(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.warp(vm.getBlockTimestamp() + 15);
            vm.roll(vm.getBlockNumber() + 1);
            for (uint256 k; k < 2; k++) try ICoinFeed(_desk(k).feed).poke() {} catch {}
        }
    }

    function _price(uint256 k) internal view returns (bool ok, uint256 p) {
        try ICoinFeed(_desk(k).feed).latestRoundData() returns (uint80, int256 a, uint256, uint256, uint80) {
            return (true, uint256(a));
        } catch {
            return (false, 0);
        }
    }

    function open(uint256 who, uint256 coin, uint256 size, uint256 ltv) external {
        uint256 k = coin % 2;
        address a = actors[who % 3];
        (bool ok, uint256 p) = _price(k);
        if (!ok) return;
        CuratedDesk memory d = _desk(k);
        uint256 cap;
        try listing.capOf(coins[k]) returns (uint256 c, uint256) {
            cap = c;
        } catch {
            return;
        }
        uint256 owed = MORPHO.market(d.market.id()).totalBorrowAssets;
        uint256 room = cap > owed ? cap - owed : 0;
        uint256 borrow = size % 5 == 0 ? room + 1e18 : bound(size, 1e18, room / 2 + 1e18); // over the cap one time in five
        uint256 debtUsd = (borrow * p) / 1e30 + 1;
        uint256 deposit = (debtUsd * 10_000) / bound(ltv, 800, 1_900);
        deal(address(USDG), a, USDG.balanceOf(a) + deposit);
        vm.prank(a);
        try short.open(coins[k], deposit, borrow, 0, vm.getBlockTimestamp() + 1) {
            opens++;
            if (MORPHO.market(d.market.id()).totalBorrowAssets > cap + 1) capBreaches++;
        } catch {}
    }

    function close(uint256 who, uint256 coin) external {
        uint256 k = coin % 2;
        address a = actors[who % 3];
        address acct = short.accountOf(a);
        if (acct.code.length == 0) return;
        Position memory pos = MORPHO.position(_desk(k).market.id(), acct);
        if (pos.borrowShares == 0 && pos.collateral == 0) return;
        deal(address(USDG), a, USDG.balanceOf(a) + 1_000_000e6);
        vm.prank(a);
        try short.close(coins[k], type(uint256).max, type(uint256).max, 1_000_000e6, type(uint256).max, vm.getBlockTimestamp() + 1) {
            closes++;
        } catch {
            closeFailures++;
        }
    }

    function borrow(uint256 who, uint256 coin, uint256 part) external {
        uint256 k = coin % 2;
        address a = actors[who % 3];
        (bool ok, uint256 p) = _price(k);
        if (!ok) return;
        try loans.loanCapOf(coins[k]) returns (uint256 cap, uint256) {
            CuratedLoans.LoanDesk memory ld = loans.loanDeskOf(coins[k]);
            uint256 owed = MORPHO.market(ld.market.id()).totalBorrowAssets;
            uint256 room = cap > owed ? cap - owed : 0;
            uint256 amount = bound(part, 1e6, room / 2 + 1e6);
            uint256 col = (amount * 1e30 * 10_000) / p / 1_800;
            deal(coins[k], a, IERC20(coins[k]).balanceOf(a) + col);
            vm.prank(a);
            try loans.borrow(coins[k], col, amount, vm.getBlockTimestamp() + 1) {
                borrows++;
                if (MORPHO.market(ld.market.id()).totalBorrowAssets > cap + 1) capBreaches++;
            } catch {}
        } catch {}
    }

    function repay(uint256 who, uint256 coin) external {
        uint256 k = coin % 2;
        address a = actors[who % 3];
        address acct = loans.accountOf(a);
        if (acct.code.length == 0) return;
        Position memory pos = MORPHO.position(loans.loanDeskOf(coins[k]).market.id(), acct);
        if (pos.borrowShares == 0 && pos.collateral == 0) return;
        deal(address(USDG), a, USDG.balanceOf(a) + 1_000_000e6);
        vm.prank(a);
        try loans.repay(coins[k], type(uint256).max, type(uint256).max, type(uint256).max) {
            repays++;
        } catch {
            repayFailures++;
        }
    }

    /// Moves a coin's pool price up to 8% either way in one trade, and lets a little time pass, so the guards
    /// mostly stay open and traffic flows.
    function move(uint256 coin, uint256 bps) external {
        _move(coin % 2, bound(bps, 9_200, 10_800));
        _steps(20);
    }

    /// A squeeze or a crash held while the delayed prices follow, one call in two; otherwise a smaller held move.
    function hold(uint256 coin, uint256 bps) external {
        if (bps % 2 == 0) _move(coin % 2, bps % 4 == 0 ? bound(bps, 15_000, 26_000) : bound(bps, 4_000, 6_500));
        else _move(coin % 2, bound(bps, 8_500, 11_500));
        _steps(130);
    }

    function wait(uint256 n) external {
        _steps(bound(n, 1, 80));
    }

    function liquidate(uint256 who, uint256 coin) external {
        uint256 k = coin % 2;
        (bool ok,) = _price(k);
        if (!ok) return;
        address s = short.accountOf(actors[who % 3]);
        if (s.code.length != 0) {
            (uint256 seize, uint256 rep) = liq.plan(_desk(k).market, s);
            if (seize != 0 || rep != 0) {
                vm.prank(keeper);
                try liq.liquidate(coins[k], s, 0, keeper) {
                    liquidations++;
                } catch {}
            }
        }
        address l = loans.accountOf(actors[who % 3]);
        if (l.code.length != 0) {
            (uint256 seize, uint256 rep) = lliq.plan(loans.loanDeskOf(coins[k]).market, l);
            if (seize != 0 || rep != 0) {
                vm.prank(keeper);
                try lliq.liquidate(coins[k], l, 0, keeper) {
                    liquidations++;
                } catch {}
            }
        }
    }

    function safePauses(uint256 seed) external {
        bool on = seed % 4 == 0;
        vm.startPrank(SAFE);
        short.pauseAll(on);
        loans.pauseAll(on);
        vm.stopPrank();
    }

    /// A stranger tries the doors that must stay shut.
    function strangerTries(uint256 which) external {
        which = which % 7;
        vm.startPrank(stranger);
        bool ok;
        if (which == 0) (ok,) = address(short).call(abi.encodeCall(short.onMorphoRepay, (1, abi.encode(short.accountOf(actors[0]), coins[0], 1, type(uint256).max))));
        else if (which == 1) (ok,) = address(short).call(abi.encodeCall(short.onMorphoSupplyCollateral, (1, abi.encode(short.accountOf(actors[0]), coins[0], 1, 0, 0))));
        else if (which == 2) (ok,) = address(router).call(abi.encodeCall(router.unlockCallback, (abi.encode(venues[0].key, true, 1, false, false))));
        else if (which == 3) (ok,) = address(router).call(abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(1e9), int256(-1), abi.encode(address(USDG), 1, false, false)));
        else if (which == 4) (ok,) = address(short.collateral()).call(abi.encodeCall(CoinCollateral.wrap, (1, stranger)));
        else if (which == 5) (ok,) = address(liq).call(abi.encodeCall(liq.onMorphoLiquidate, (1, abi.encode(coins[0]))));
        else (ok,) = address(lliq).call(abi.encodeCall(lliq.onMorphoLiquidate, (1, abi.encode(coins[1]))));
        vm.stopPrank();
        if (ok) strangerWins++;
    }

    function _move(uint256 k, uint256 multBps) internal {
        Venue memory v = venues[k];
        CoinLens.Pool memory p = lens.pool(coins[k], v);
        uint160 s;
        if (v.kind == VENUE_V3) (s,,,,,,) = IV3Pool(v.pool).slot0();
        else s = uint160(uint256(IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951).extsload(keccak256(abi.encodePacked(keccak256(abi.encode(v.key)), uint256(6))))));
        uint256 f = Math.sqrt(multBps * 1e14);
        bool rawUp = p.coinIs0 == (multBps > 10_000);
        uint160 limit = uint160(rawUp ? Math.mulDiv(s, Math.max(f, 1e9), Math.min(f, 1e9)) : Math.mulDiv(s, Math.min(f, 1e9), Math.max(f, 1e9)));
        if (v.kind == VENUE_V3) mover.v3(v.pool, limit);
        else mover.v4(v.key, limit, !rawUp);
    }
}

/// forge-config: default.invariant.runs = 20
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = false
contract CuratedInvariantTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant HELD = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant BORRO_SHORT = 0xd2D686cEdf225c5C9815187A08812783904E62Eb;
    address constant BUSDG = 0xF8e0ab443098c0738489B5BAFFbd32A1341F2289;
    bytes32 constant NVDA_MARKET = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;
    address constant PONS_LISTING = 0x04b67bF99bf4C2803F38a1351A861Fc8A1f72010;
    address constant NOVAAI = 0x51250B135174Ca09450EC01c4afF73CF69DBb590;
    address constant CHUMP = 0x0E0d2C89a5a019FE1cF762e5e33187631DACC21B;

    CuratedHandler h;
    CuratedShort short;
    CoinRouter router;
    CuratedLiquidator liq;
    CuratedLoans loans;
    CuratedLoanLiquidator lliq;
    Market nvda0;
    uint256 bUsdg0;
    uint256 safeUsdg0;
    uint256 ponsCoins0;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        EthPrice ep = new EthPrice(IUniV3PoolOracle(ETH_POOL), WETH, address(USDG), 1800);
        CoinLens lens = new CoinLens(PM, IV3Factory(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA), WETH, address(USDG), ep, IStockDesks(BORRO_SHORT));
        CuratedFeeds feeds = new CuratedFeeds(lens);
        address shortAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        CuratedListing listing = new CuratedListing(lens, feeds, address(USDG), SAFE, shortAt);
        router = new CoinRouter(PM, IV3Pool(ETH_POOL), IWETH(WETH), USDG, ICuratedListing(address(listing)), IStockDesks(BORRO_SHORT));
        short = new CuratedShort(MORPHO, USDG, IHeld(HELD), ICuratedListing(address(listing)), router, SAFE);
        liq = new CuratedLiquidator(MORPHO, USDG, IHeldRedeem(HELD), ICuratedListing(address(listing)), router);
        loans = new CuratedLoans(MORPHO, ICuratedListing(address(listing)), USDG, SAFE);
        lliq = new CuratedLoanLiquidator(MORPHO, USDG, loans, router);
        Venue[2] memory v;
        v[0].kind = VENUE_V4;
        v[0].key = PoolKey(Currency.wrap(address(0)), Currency.wrap(NOVAAI), 0, 200, IHooks(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044));
        v[0].pair = PAIR_ETH;
        v[1].kind = VENUE_V3;
        v[1].pool = 0x714442e9A611f8561A7dF108D6d925132937cFb8;
        v[1].pair = PAIR_ETH;
        address[2] memory c = [NOVAAI, CHUMP];
        for (uint256 i; i < 2; i++) {
            vm.prank(SAFE);
            listing.allow(c[i], v[i], 5_000e18);
            uint256 seed = listing.seedOf(c[i]);
            deal(c[i], address(this), seed);
            IERC20(c[i]).approve(address(listing), seed);
            listing.list(c[i]);
        }
        for (uint256 i; i < 80; i++) {
            vm.warp(vm.getBlockTimestamp() + 15);
            vm.roll(vm.getBlockNumber() + 1);
            for (uint256 k; k < 2; k++) ICoinFeed(listing.deskOf(c[k]).feed).poke();
        }
        for (uint256 i; i < 2; i++) {
            CuratedDesk memory d = listing.deskOf(c[i]);
            (, int256 p,,,) = ICoinFeed(d.feed).latestRoundData();
            address lender = makeAddr(string.concat("cinv lender ", vm.toString(i)));
            uint256 lend = (200_000e18 * 1e18) / uint256(p);
            deal(c[i], lender, lend);
            vm.startPrank(lender);
            IERC20(c[i]).approve(d.vault, type(uint256).max);
            IVaultV2(d.vault).deposit(lend, lender);
            vm.stopPrank();
            deal(address(USDG), address(this), 1e6);
            USDG.approve(address(loans), 1e6);
            loans.openLoans(c[i]);
            CuratedLoans.LoanDesk memory ld = loans.loanDeskOf(c[i]);
            deal(address(USDG), lender, 9_000e6);
            vm.startPrank(lender);
            USDG.approve(ld.vault, type(uint256).max);
            IVaultV2(ld.vault).deposit(9_000e6, lender);
            vm.stopPrank();
        }
        PriceMover mover = new PriceMover(PM);
        h = new CuratedHandler(listing, short, liq, loans, lliq, router, lens, mover, c, v);
        nvda0 = MORPHO.market(Id.wrap(NVDA_MARKET));
        bUsdg0 = IVaultV2(BUSDG).totalAssets();
        safeUsdg0 = USDG.balanceOf(SAFE);
        ponsCoins0 = ICoinsLength(PONS_LISTING).coinsLength();
        targetContract(address(h));
        // Only the actions: the handler's getters would otherwise take most of the calls.
        bytes4[] memory s = new bytes4[](10);
        (s[0], s[1], s[2], s[3], s[4]) = (h.open.selector, h.close.selector, h.borrow.selector, h.repay.selector, h.move.selector);
        (s[5], s[6], s[7], s[8], s[9]) = (h.hold.selector, h.wait.selector, h.liquidate.selector, h.safePauses.selector, h.strangerTries.selector);
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    function _skipUnlessForked() internal {
        if (!forked) vm.skip(true);
    }

    function _nothingHeld(address who) internal view {
        assertEq(USDG.balanceOf(who), 0, "no USDG held");
        assertEq(IERC20(NOVAAI).balanceOf(who), 0, "no NOVAAI held");
        assertEq(IERC20(CHUMP).balanceOf(who), 0, "no CHUMP held");
        assertEq(IERC20(WETH).balanceOf(who), 0, "no WETH held");
        assertEq(IERC20(HELD).balanceOf(who), 0, "no Steakhouse shares held");
        assertEq(who.balance, 0, "no ETH held");
    }

    function invariant_nothing_is_held_between_transactions() public {
        _skipUnlessForked();
        _nothingHeld(address(short));
        _nothingHeld(address(router));
        _nothingHeld(address(liq));
        _nothingHeld(address(lliq));
        _nothingHeld(address(loans));
    }

    function invariant_cusdg_is_backed_one_for_one() public {
        _skipUnlessForked();
        CoinCollateral c = short.collateral();
        assertEq(IERC20(HELD).balanceOf(address(c)), c.totalSupply());
    }

    function invariant_caps_closes_repays_and_doors() public {
        _skipUnlessForked();
        assertEq(h.capBreaches(), 0, "no open or borrow left a coin over its cap");
        assertEq(h.closeFailures(), 0, "every full close went through");
        assertEq(h.repayFailures(), 0, "every full repay went through");
        assertEq(h.strangerWins(), 0, "no stranger got through a callback or the gate");
    }

    function invariant_nothing_outside_the_curated_markets_moved() public {
        _skipUnlessForked();
        Market memory n = MORPHO.market(Id.wrap(NVDA_MARKET));
        assertEq(n.totalSupplyAssets, nvda0.totalSupplyAssets, "NVDA's market");
        assertEq(n.totalBorrowAssets, nvda0.totalBorrowAssets, "NVDA's market");
        assertGe(IVaultV2(BUSDG).totalAssets(), bUsdg0, "Borro's USDG vault");
        assertEq(USDG.balanceOf(SAFE), safeUsdg0, "the Safe received nothing");
        assertEq(ICoinsLength(PONS_LISTING).coinsLength(), ponsCoins0, "the Pons coin shorts untouched");
    }

    /// The handler's traffic gets through: each kind of position opens and closes on both coins.
    function test_fork_handler_opens_and_closes_on_both_venues() public {
        _skipUnlessForked();
        for (uint256 k; k < 2; k++) {
            h.open(k, k, 7e18 + 3, 1_200);
            h.borrow(k, k, 50e6 + 3);
        }
        assertEq(h.opens(), 2, "a short opened on each coin");
        assertEq(h.borrows(), 2, "a loan opened on each coin");
        for (uint256 k; k < 2; k++) {
            h.close(k, k);
            h.repay(k, k);
        }
        assertEq(h.closes(), 2);
        assertEq(h.repays(), 2);
    }

    function afterInvariant() public {
        if (!forked) return;
        string memory line = string.concat(
            "opens ", vm.toString(h.opens()), ", closes ", vm.toString(h.closes()), ", borrows ", vm.toString(h.borrows()),
            ", repays ", vm.toString(h.repays()), ", liquidations ", vm.toString(h.liquidations())
        );
        console2.log(line);
        vm.writeLine(string.concat(vm.projectRoot(), "/script/out/curated-invariant-tally.txt"), line);
    }
}

interface ICoinsLength {
    function coinsLength() external view returns (uint256);
}
