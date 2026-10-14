// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {CoinFeed, IUniV3PoolOracle} from "../../src/coins/CoinFeed.sol";
import {CoinListing, IPositionManager} from "../../src/coins/CoinListing.sol";
import {CoinShort, CoinAccount, IHeld} from "../../src/coins/CoinShort.sol";
import {CoinLoans} from "../../src/coins/CoinLoans.sol";
import {CoinLoanLiquidator} from "../../src/coins/CoinLoanLiquidator.sol";
import {GatedCoin} from "../../src/coins/GatedCoin.sol";
import {IPonsFactory, IPonsLocker, IWETH, IUniswapV3PoolSwap, ICoinListing} from "../../src/coins/CoinDeps.sol";
import {PoolTrader, McapKnob} from "./CoinFeed.fork.t.sol";

/// Shared setup for loans against coins on a copy of Robinhood Chain: coin shorts and coin loans deployed, $BORRO and
/// a second graduated Pons coin listed with loans open, and each coin's USDG vault funded by its own lender.
abstract contract CoinLoansBase is McapKnob {
    using MarketParamsLib for MarketParams;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant LOCKER = 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant HELD = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    IERC20 constant COIN2 = IERC20(0xA36FbBE342E511825F59769E94a64E96D6f87773); // the deepest graduated Pons coin on 2026-10-06
    address constant BUSDG = 0xF8e0ab443098c0738489B5BAFFbd32A1341F2289; // Borro's USDG vault: must never be touched
    bytes32 constant NVDA_MARKET = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;
    uint32 constant CHECK = 15;

    CoinListing listing;
    CoinShort short;
    CoinLoans loans;
    CoinLoanLiquidator liq;
    PoolTrader trader;
    PoolTrader trader2;
    bool forked;
    address lender = makeAddr("dollar lender");
    address lender2 = makeAddr("coin2 dollar lender");

    function _deployAndList() internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        listing = new CoinListing(PM, IPositionManager(POSM), IPonsFactory(PONS), IPonsLocker(LOCKER), IUniV3PoolOracle(ETH_POOL), WETH, address(USDG), SAFE, predicted);
        short = new CoinShort(MORPHO, PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), USDG, IHeld(HELD), ICoinListing(address(listing)), PONS_HOOK, SAFE);
        loans = new CoinLoans(MORPHO, ICoinListing(address(listing)), USDG, PONS_HOOK, SAFE);
        liq = new CoinLoanLiquidator(MORPHO, PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), USDG, loans);
        vm.warp(vm.getBlockTimestamp() + 3 days); // both coins old enough, whatever day the fork is from
        for (uint256 i; i < 2; i++) {
            address c = i == 0 ? address(BORRO) : address(COIN2);
            _mcapTo(c, listing.checks(c).mcapUsd, 15_000_000e18); // over the $10M floor
            deal(c, address(this), 1e18);
            IERC20(c).approve(address(listing), 1e18);
            listing.list(c);
        }
        _pokeFor(18 minutes);
        for (uint256 i; i < 2; i++) {
            address c = i == 0 ? address(BORRO) : address(COIN2);
            deal(address(USDG), address(this), 1e6);
            USDG.approve(address(loans), 1e6);
            uint256 g = gasleft();
            loans.openLoans(c);
            if (i == 0) console2.log("gas: openLoans", g - gasleft());
        }
        trader = new PoolTrader(PM, listing.keyOf(address(BORRO)));
        trader2 = new PoolTrader(PM, listing.keyOf(address(COIN2)));
        vm.deal(address(trader), 1_000 ether);
        vm.deal(address(trader2), 1_000 ether);
        _lend(lender, address(BORRO), 5_000e6);
        _lend(lender2, address(COIN2), 5_000e6);
    }

    function _lend(address who, address coin, uint256 amount) internal {
        CoinLoans.LoanDesk memory d = loans.loanDeskOf(coin);
        deal(address(USDG), who, USDG.balanceOf(who) + amount);
        vm.startPrank(who);
        USDG.approve(d.vault, type(uint256).max);
        IVaultV2(d.vault).deposit(amount, who);
        vm.stopPrank();
    }

    function _feed(address coin) internal view returns (CoinFeed f) {
        f = CoinFeed(listing.deskOf(coin).feed);
    }

    function _step() internal {
        vm.warp(vm.getBlockTimestamp() + CHECK);
        vm.roll(vm.getBlockNumber() + 1);
        _feed(address(BORRO)).poke();
        _feed(address(COIN2)).poke();
    }

    function _pokeFor(uint256 secs) internal {
        for (uint256 t; t < secs; t += CHECK) _step();
    }

    function _delayed(address coin) internal view returns (uint256 p) {
        (p,,) = _feed(coin).price();
    }

    /// Coins worth `usd` (USDG wei) at the delayed price.
    function _coinsFor(address coin, uint256 usd) internal view returns (uint256) {
        return (usd * 1e30) / _delayed(coin);
    }

    /// Borrows `amount` USDG against enough of the coin to sit at `ltvBps`.
    function _borrow(address who, address coin, uint256 amount, uint256 ltvBps) internal returns (uint256 collateral) {
        collateral = _coinsFor(coin, (amount * 10_000) / ltvBps);
        deal(coin, who, IERC20(coin).balanceOf(who) + collateral);
        vm.startPrank(who);
        IERC20(coin).approve(address(loans), type(uint256).max);
        USDG.approve(address(loans), type(uint256).max);
        loans.borrow(coin, collateral, amount, block.timestamp + 1);
        vm.stopPrank();
    }

    function _room(address coin) internal view returns (uint256) {
        (uint256 cap,) = loans.loanCapOf(coin);
        uint256 owed = MORPHO.market(loans.loanDeskOf(coin).market.id()).totalBorrowAssets;
        return cap > owed ? cap - owed : 0;
    }

    function _owed(address coin, address acct) internal view returns (uint256) {
        MarketParams memory mp = loans.loanDeskOf(coin).market;
        Position memory p = MORPHO.position(mp.id(), acct);
        Market memory m = MORPHO.market(mp.id());
        return m.totalBorrowShares == 0 ? 0 : (uint256(p.borrowShares) * m.totalBorrowAssets + m.totalBorrowShares - 1) / m.totalBorrowShares;
    }

    /// Sells the coin into its pool until the spot is `factorBps` of what it was; returns coins sold.
    function _dump(PoolTrader t, address coin, uint256 factorBps) internal returns (uint256 sold) {
        uint256 s0 = _feed(coin).spot();
        uint256 lo;
        uint256 hi = IERC20(coin).totalSupply() / 2;
        for (uint256 i; i < 50; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            deal(coin, address(t), mid);
            t.sell(mid);
            uint256 s1 = _feed(coin).spot();
            vm.revertToState(snap);
            if (s1 * 10_000 <= s0 * factorBps) hi = mid;
            else lo = mid;
        }
        deal(coin, address(t), hi);
        t.sell(hi);
        sold = hi;
    }
}

contract CoinLoansForkTest is CoinLoansBase {
    using MarketParamsLib for MarketParams;

    address ann = makeAddr("ann");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        _deployAndList();
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_loans_open_with_their_own_vault_and_nothing_else() public onFork {
        CoinLoans.LoanDesk memory d = loans.loanDeskOf(address(BORRO));
        assertEq(d.market.loanToken, address(USDG));
        assertEq(address(GatedCoin(d.wrapper).coin()), address(BORRO));
        assertEq(d.market.lltv, 0.385e18);
        IVaultV2 v = IVaultV2(d.vault);
        assertEq(v.asset(), address(USDG));
        assertEq(v.owner(), SAFE);
        assertEq(v.curator(), SAFE);
        assertFalse(v.isAllocator(address(loans)), "CoinLoans keeps no role");
        assertEq(v.timelock(IVaultV2.increaseAbsoluteCap.selector), 3 days);
        assertTrue(d.vault != loans.loanDeskOf(address(COIN2)).vault, "each coin its own vault");
        // Refusals.
        vm.expectRevert(CoinLoans.AlreadyOpen.selector);
        loans.openLoans(address(BORRO));
        vm.expectRevert(CoinListing.NotListed.selector);
        loans.openLoans(address(USDG));
        vm.prank(SAFE);
        loans.pauseOpening(true);
        vm.expectRevert(CoinLoans.IsPaused.selector);
        loans.openLoans(address(BORRO));
        (uint256 cap, uint256 depthUsd) = loans.loanCapOf(address(BORRO));
        console2.log("BORRO loan cap (USDG)", cap);
        console2.log("BORRO locked coin side in dollars (USDG)", depthUsd);
        assertEq(cap, (depthUsd * 120) / 10_000);
    }

    function test_fork_borrow_within_cap_refused_over_cap_over_limit_after_a_dump_and_paused() public onFork {
        uint256 room = _room(address(BORRO));
        // Over the cap.
        uint256 big = _coinsFor(address(BORRO), room * 10);
        deal(address(BORRO), ann, big);
        vm.startPrank(ann);
        BORRO.approve(address(loans), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoinLoans.OverCap.selector, room + 1, room));
        loans.borrow(address(BORRO), big, room + 1, block.timestamp + 1);
        // Over the open limit (30% LTV).
        uint256 small = _coinsFor(address(BORRO), (room * 10_000) / 2 / 3_000);
        vm.expectRevert();
        loans.borrow(address(BORRO), small, room / 2, block.timestamp + 1);
        vm.stopPrank();
        // Within: half the room at 15%.
        uint256 g = gasleft();
        _borrow(ann, address(BORRO), room / 2, 1_500);
        console2.log("gas: borrow (incl. setup)", g - gasleft());
        assertEq(USDG.balanceOf(ann), room / 2, "ann has the dollars");
        // A dump the delayed price has not caught up with: new borrows wait.
        _dump(trader, address(BORRO), 8_000);
        vm.prank(ann);
        vm.expectRevert(CoinLoans.GuardClosed.selector);
        loans.borrow(address(BORRO), 0, 1e6, block.timestamp + 1);
        // Paused: no new borrows; repaying and taking everything back always work, guard or not.
        vm.prank(SAFE);
        loans.pauseAll(true);
        vm.prank(bob);
        vm.expectRevert(CoinLoans.IsPaused.selector);
        loans.borrow(address(BORRO), 1, 1, block.timestamp + 1);
        deal(address(USDG), ann, 1_000e6);
        uint256 before = BORRO.balanceOf(ann);
        vm.prank(ann);
        g = gasleft();
        loans.repay(address(BORRO), type(uint256).max, type(uint256).max, type(uint256).max);
        console2.log("gas: repay all", g - gasleft());
        assertGt(BORRO.balanceOf(ann), before, "collateral back");
        assertEq(_owed(address(BORRO), loans.accountOf(ann)), 0);
    }

    /// A coin that falls under $10M at the delayed price takes no new loans; a loan already open repays in full.
    function test_fork_under_the_floor_no_new_loans_but_repaying_works() public onFork {
        _borrow(ann, address(BORRO), _room(address(BORRO)) / 4, 1_000);
        // Worth $11M, then holders dump 20% and it holds for 18 minutes.
        _mcapTo(address(BORRO), listing.mcapOf(address(BORRO)), 11_000_000e18);
        _dump(trader, address(BORRO), 8_000);
        _pokeFor(18 minutes);
        console2.log("market cap at the delayed price after the dump (dollars)", listing.mcapOf(address(BORRO)) / 1e18);
        assertLt(listing.mcapOf(address(BORRO)), 10_000_000e18);
        (uint256 cap,) = loans.loanCapOf(address(BORRO));
        assertEq(cap, 0, "no loan room under the floor");
        (uint256 shortCap,) = listing.capOf(address(BORRO));
        assertEq(shortCap, 0, "and no short room");
        uint256 col = _coinsFor(address(BORRO), 1_000e6);
        deal(address(BORRO), bob, col);
        vm.startPrank(bob);
        BORRO.approve(address(loans), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoinLoans.OverCap.selector, 1e6, 0));
        loans.borrow(address(BORRO), col, 1e6, block.timestamp + 1);
        vm.stopPrank();
        assertGt(_room(address(COIN2)), 0, "the other coin is untouched");
        // Repaying and taking every coin back never look at the floor.
        deal(address(USDG), ann, USDG.balanceOf(ann) + 1_000e6);
        uint256 before = BORRO.balanceOf(ann);
        vm.prank(ann);
        loans.repay(address(BORRO), type(uint256).max, type(uint256).max, type(uint256).max);
        assertEq(_owed(address(BORRO), loans.accountOf(ann)), 0, "repaid under the floor");
        assertGt(BORRO.balanceOf(ann), before, "coins back");
    }

    function test_fork_outside_supply_does_not_lift_the_cap_and_nobody_borrows_around_it() public onFork {
        CoinLoans.LoanDesk memory d = loans.loanDeskOf(address(BORRO));
        // A stranger supplies $50,000 straight into the market.
        deal(address(USDG), stranger, 50_000e6);
        vm.startPrank(stranger);
        USDG.approve(address(MORPHO), type(uint256).max);
        MORPHO.supply(d.market, 50_000e6, 0, stranger, "");
        vm.stopPrank();
        uint256 room = _room(address(BORRO));
        (uint256 cap,) = loans.loanCapOf(address(BORRO));
        assertEq(room, cap, "the cap is on what is borrowed, not on what is supplied");
        // The stranger cannot post the coin as collateral: the market's collateral is GatedCoin.
        deal(address(BORRO), stranger, 1e24);
        vm.startPrank(stranger);
        BORRO.approve(address(MORPHO), type(uint256).max);
        vm.expectRevert();
        MORPHO.supplyCollateral(d.market, 1e24, stranger, "");
        vm.expectRevert(GatedCoin.OnlyGate.selector);
        GatedCoin(d.wrapper).wrap(1, stranger);
        vm.stopPrank();
        // Still capped through CoinLoans.
        uint256 big = _coinsFor(address(BORRO), cap * 20);
        deal(address(BORRO), bob, big);
        vm.startPrank(bob);
        BORRO.approve(address(loans), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CoinLoans.OverCap.selector, cap + 1, cap));
        loans.borrow(address(BORRO), big, cap + 1, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_fork_a_held_dump_liquidates_through_the_pool() public onFork {
        uint256 room = _room(address(BORRO));
        _borrow(ann, address(BORRO), room / 2, 1_900);
        address acct = loans.accountOf(ann);
        _dump(trader, address(BORRO), 4_500); // down 55%, held
        vm.expectRevert(CoinLoanLiquidator.Healthy.selector);
        liq.liquidate(address(BORRO), acct, 0, keeper);
        _pokeFor(18 minutes);
        assertLt(listing.mcapOf(address(BORRO)), 10_000_000e18, "under the $10M floor: liquidating never looks at it");
        uint256 g = gasleft();
        vm.prank(keeper);
        uint256 profit = liq.liquidate(address(BORRO), acct, 0, keeper);
        console2.log("gas: liquidate a loan", g - gasleft());
        console2.log("liquidator profit (USDG)", profit);
        assertGt(profit, 0);
        assertEq(_owed(address(BORRO), acct), 0, "debt repaid from the sale");
        assertGt(MORPHO.position(loans.loanDeskOf(address(BORRO)).market.id(), acct).collateral, 0, "ann keeps the rest");
        assertEq(BORRO.balanceOf(address(liq)), 0);
        assertEq(USDG.balanceOf(address(liq)), 0);
        // Ann takes what is left, no price needed.
        vm.prank(ann);
        loans.repay(address(BORRO), 0, type(uint256).max, 0);
    }

    function test_fork_bad_debt_stays_with_this_coins_dollar_lenders() public onFork {
        uint256 room = _room(address(BORRO));
        _borrow(ann, address(BORRO), room / 2, 1_900);
        address acct = loans.accountOf(ann);
        _borrow(bob, address(COIN2), _room(address(COIN2)) / 2, 1_500);
        uint256 v1 = IVaultV2(loans.loanDeskOf(address(BORRO)).vault).totalAssets();
        uint256 v2 = IVaultV2(loans.loanDeskOf(address(COIN2)).vault).totalAssets();
        uint256 bu = IVaultV2(BUSDG).totalAssets();
        Market memory nvda0 = MORPHO.market(Id.wrap(NVDA_MARKET));
        _dump(trader, address(BORRO), 1_200); // down 88%: past the collateral before liquidations see it
        _pokeFor(18 minutes);
        vm.prank(keeper);
        uint256 profit = liq.liquidate(address(BORRO), acct, 0, keeper);
        console2.log("bad-debt liquidation profit (USDG)", profit);
        Position memory p = MORPHO.position(loans.loanDeskOf(address(BORRO)).market.id(), acct);
        assertEq(p.collateral, 0);
        assertEq(p.borrowShares, 0, "the rest written off");
        uint256 v1after = IVaultV2(loans.loanDeskOf(address(BORRO)).vault).totalAssets();
        console2.log("BORRO's dollar lenders before", v1);
        console2.log("BORRO's dollar lenders after", v1after);
        assertLt(v1after, v1, "BORRO's dollar lenders took the loss");
        assertGe(IVaultV2(loans.loanDeskOf(address(COIN2)).vault).totalAssets(), v2, "COIN2's dollar lenders untouched");
        assertGe(IVaultV2(BUSDG).totalAssets(), bu, "Borro's USDG vault untouched");
        Market memory nvda1 = MORPHO.market(Id.wrap(NVDA_MARKET));
        assertEq(nvda1.totalSupplyAssets, nvda0.totalSupplyAssets);
    }

    function test_fork_partial_withdraw_keeps_the_open_limit_and_the_way_out_without_coinloans() public onFork {
        uint256 room = _room(address(BORRO));
        uint256 col = _borrow(ann, address(BORRO), room / 2, 1_000); // 10%
        vm.startPrank(ann);
        vm.expectRevert();
        loans.repay(address(BORRO), 0, (col * 8) / 10, 0); // would pass 19.25%
        loans.repay(address(BORRO), 0, col / 3, 0);
        // Add some back.
        deal(address(BORRO), ann, BORRO.balanceOf(ann) + col / 3);
        loans.addCollateral(address(BORRO), col / 3);
        vm.stopPrank();
        // Someone repays ann's loan on Morpho directly; ann takes the collateral out without CoinLoans.
        CoinLoans.LoanDesk memory d = loans.loanDeskOf(address(BORRO));
        CoinAccount acct = CoinAccount(loans.accountOf(ann));
        uint256 shares = MORPHO.position(d.market.id(), address(acct)).borrowShares;
        deal(address(USDG), stranger, 10_000e6);
        vm.startPrank(stranger);
        USDG.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(d.market, 0, shares, address(acct), "");
        vm.stopPrank();
        uint256 left = MORPHO.position(d.market.id(), address(acct)).collateral;
        uint256 before = BORRO.balanceOf(ann);
        vm.startPrank(ann);
        acct.withdrawHeld(d.market, left, ann);
        GatedCoin(d.wrapper).unwrap(left, ann);
        vm.stopPrank();
        assertEq(BORRO.balanceOf(ann) - before, left);
    }

    function test_fork_dollar_lenders_earn_and_withdraw() public onFork {
        CoinLoans.LoanDesk memory d = loans.loanDeskOf(address(BORRO));
        uint256 shares = IVaultV2(d.vault).balanceOf(lender);
        uint256 w0 = IVaultV2(d.vault).previewRedeem(shares);
        _borrow(ann, address(BORRO), _room(address(BORRO)) / 2, 1_500);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _pokeFor(18 minutes);
        deal(address(USDG), ann, 1_000e6);
        vm.prank(ann);
        loans.repay(address(BORRO), type(uint256).max, type(uint256).max, type(uint256).max);
        uint256 w1 = IVaultV2(d.vault).previewRedeem(shares);
        console2.log("a month of interest to the dollar lender (USDG wei)", w1 - w0);
        assertGt(w1, w0);
        vm.prank(lender);
        uint256 out = IVaultV2(d.vault).redeem(shares, lender, lender);
        assertEq(USDG.balanceOf(lender), out);
    }
}
