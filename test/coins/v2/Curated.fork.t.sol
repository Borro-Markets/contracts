// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {
    Venue, CuratedDesk, ICoinFeed, ICuratedListing, IV3Pool, IV3Factory, IStockDesks, VENUE_V3, VENUE_V4, PAIR_ETH, PAIR_USDG, PAIR_STOCK
} from "../../../src/coins/v2/VenueDeps.sol";

/// Curated coin shorts and coin loans end to end on a copy of Robinhood Chain, one subclass per kind of venue: the
/// real pools, Morpho and its factories, Steakhouse USDG, BorroShort's stock desks. Every number the contracts use
/// is the live chain's. The tests trade through CoinRouter itself to pump and dump. Set BORRO_FORK_RPC.
abstract contract CuratedForkBase is Test {
    using MarketParamsLib for MarketParams;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant HELD = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant BORRO_SHORT = 0xd2D686cEdf225c5C9815187A08812783904E62Eb;
    address constant BUSDG = 0xF8e0ab443098c0738489B5BAFFbd32A1341F2289; // Borro's USDG vault: never touched
    bytes32 constant NVDA_MARKET = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;
    // The Pons coin shorts deployed 2026-10-06: never touched.
    address constant PONS_LISTING = 0x04b67bF99bf4C2803F38a1351A861Fc8A1f72010;

    CoinLens lens;
    CuratedFeeds feeds;
    CuratedListing listing;
    CoinRouter router;
    CuratedShort short;
    CuratedLiquidator liq;
    CuratedLoans loans;
    CuratedLoanLiquidator lliq;
    CuratedDesk d;
    PriceMover mover;
    bool forked;

    address lender = makeAddr("lender");
    address ann = makeAddr("ann");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function _coin() internal pure virtual returns (address);

    /// Anything a venue needs on this copy of the chain before it is listed.
    function _prepare() internal virtual {}
    function _venue() internal view virtual returns (Venue memory);
    function _name() internal pure virtual returns (string memory);

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        EthPrice ep = new EthPrice(IUniV3PoolOracle(ETH_POOL), WETH, address(USDG), 1800);
        lens = new CoinLens(PM, IV3Factory(V3_FACTORY), WETH, address(USDG), ep, IStockDesks(BORRO_SHORT));
        feeds = new CuratedFeeds(lens);
        uint256 n = vm.getNonce(address(this));
        address shortAt = vm.computeCreateAddress(address(this), n + 2);
        listing = new CuratedListing(lens, feeds, address(USDG), SAFE, shortAt);
        router = new CoinRouter(PM, IV3Pool(ETH_POOL), IWETH(WETH), USDG, ICuratedListing(address(listing)), IStockDesks(BORRO_SHORT));
        short = new CuratedShort(MORPHO, USDG, IHeld(HELD), ICuratedListing(address(listing)), router, SAFE);
        assertEq(address(short), shortAt);
        liq = new CuratedLiquidator(MORPHO, USDG, IHeldRedeem(HELD), ICuratedListing(address(listing)), router);
        loans = new CuratedLoans(MORPHO, ICuratedListing(address(listing)), USDG, SAFE);
        lliq = new CuratedLoanLiquidator(MORPHO, USDG, loans, router);
        mover = new PriceMover(PM);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _feed() internal view returns (ICoinFeed) {
        return ICoinFeed(d.feed);
    }

    /// Lets `secs` pass with a feed check every 15 seconds (the keeper's rhythm); a v3 coin's feed needs none.
    function _hold(uint256 secs) internal {
        for (uint256 t; t < secs; t += 15) {
            vm.warp(vm.getBlockTimestamp() + 15);
            vm.roll(vm.getBlockNumber() + 1);
            try ICoinFeed(d.feed).poke() {} catch {}
        }
    }

    function _delayed() internal view returns (uint256 p) {
        (, int256 a,,,) = _feed().latestRoundData();
        p = uint256(a);
    }

    /// The Safe allows the coin at a $5,000 cap; a lister lists it; the feed gets a price; a lender lends coins worth
    /// $100,000.
    function _listAndLend() internal {
        _prepare();
        Venue memory v = _venue(); // before the prank: a stock venue reads BorroShort
        vm.prank(SAFE);
        listing.allow(_coin(), v, 5_000e18);
        CuratedListing.Checks memory c = listing.checks(_coin());
        console2.log(string.concat(_name(), " market cap at the pool's price (dollars)"), c.mcapUsd / 1e18);
        console2.log("depth +10% / -10% (dollars)", c.upUsd / 1e18, c.downUsd / 1e18);
        uint256 seed = listing.seedOf(_coin());
        deal(_coin(), address(this), seed);
        IERC20(_coin()).approve(address(listing), seed);
        uint256 g = gasleft();
        listing.list(_coin());
        console2.log("gas: list", g - gasleft());
        d = listing.deskOf(_coin());
        _hold(20 minutes);
        uint256 lend = (100_000e18 * 1e18) / _delayed();
        deal(_coin(), lender, lend);
        vm.startPrank(lender);
        IERC20(_coin()).approve(d.vault, type(uint256).max);
        IVaultV2(d.vault).deposit(lend, lender);
        vm.stopPrank();
    }

    function _room() internal view returns (uint256) {
        (uint256 cap,) = listing.capOf(_coin());
        uint256 owed = MORPHO.market(d.market.id()).totalBorrowAssets;
        return cap > owed ? cap - owed : 0;
    }

    /// Opens a short of `borrow` coins for `who`, with collateral so the position sits near `ltvBps`.
    function _open(address who, uint256 borrow, uint256 ltvBps) internal returns (uint256 deposit) {
        uint256 debtUsd = (borrow * _delayed()) / 1e30;
        deposit = (debtUsd * 10_000) / ltvBps - (debtUsd * 90) / 100;
        deal(address(USDG), who, USDG.balanceOf(who) + deposit);
        vm.startPrank(who);
        USDG.approve(address(short), type(uint256).max);
        short.open(_coin(), deposit, borrow, 0, vm.getBlockTimestamp() + 1);
        vm.stopPrank();
    }

    /// Trades the coin's pool straight to `multBps` of its price now (a pump above 10,000, a dump below); returns
    /// the coins the trade moved.
    function _move(uint256 multBps) internal returns (uint256 coins) {
        Venue memory v = _venue();
        CoinLens.Pool memory p = lens.pool(_coin(), v);
        uint160 s;
        if (v.kind == VENUE_V3) (s,,,,,,) = IV3Pool(v.pool).slot0();
        else s = _slot0v4(v.key);
        uint256 f = Math.sqrt(multBps * 1e14); // sqrt(multBps / 10,000), 9 decimals
        bool rawUp = p.coinIs0 == (multBps > 10_000); // the coin's price is the raw price, or its inverse
        uint160 limit = uint160(rawUp ? Math.mulDiv(s, Math.max(f, 1e9), Math.min(f, 1e9)) : Math.mulDiv(s, Math.min(f, 1e9), Math.max(f, 1e9)));
        (int256 a0, int256 a1) = v.kind == VENUE_V3 ? mover.v3(v.pool, limit) : mover.v4(v.key, limit, !rawUp);
        int256 c = p.coinIs0 ? a0 : a1;
        coins = uint256(c < 0 ? -c : c);
    }

    function _pump(uint256 multBps) internal returns (uint256) {
        return _move(multBps);
    }

    function _dump(uint256 multBps) internal returns (uint256) {
        return _move(multBps);
    }

    function _slot0v4(PoolKey memory key) internal view returns (uint160) {
        bytes32 id = keccak256(abi.encode(key));
        return uint160(uint256(PM.extsload(keccak256(abi.encodePacked(id, uint256(6))))));
    }

    function _owed(MarketParams memory m, address acct) internal view returns (uint256) {
        Position memory p = MORPHO.position(m.id(), acct);
        Market memory mk = MORPHO.market(m.id());
        return mk.totalBorrowShares == 0 ? 0 : (uint256(p.borrowShares) * mk.totalBorrowAssets + mk.totalBorrowShares - 1) / mk.totalBorrowShares;
    }

    function _nothingHeld(address who) internal view {
        assertEq(USDG.balanceOf(who), 0, "no USDG left");
        assertEq(IERC20(_coin()).balanceOf(who), 0, "no coin left");
        assertEq(IERC20(HELD).balanceOf(who), 0, "no Steakhouse shares left");
        assertEq(IERC20(WETH).balanceOf(who), 0, "no WETH left");
        assertEq(who.balance, 0, "no ETH left");
    }

    /// Makes the coin's total supply read so it is worth `usd` at the delayed price (a test knob, by a mocked call:
    /// some coins keep their supply in code; the pool stays as it is).
    function _mcapAtDelayed(uint256 usd) internal {
        vm.mockCall(_coin(), abi.encodeWithSignature("totalSupply()"), abi.encode((usd * 1e18) / _delayed()));
    }

    // ------------------------------------------------------------------ the tests, for every venue

    function test_fork_list_short_within_cap_refused_over_it_and_the_safe_cannot_change_a_listed_coin() public onFork {
        // Not allowed: nobody can list it.
        vm.expectRevert(CuratedListing.NotAllowed.selector);
        listing.list(_coin());
        _listAndLend();
        // Once listed, the Safe can change nothing about it.
        Venue memory v = _venue();
        vm.prank(SAFE);
        vm.expectRevert(CuratedListing.AlreadyListed.selector);
        listing.allow(_coin(), v, 1e18);
        (uint256 cap, uint256 up) = listing.capOf(_coin());
        console2.log("short cap (coins)", cap / 1e18, "in dollars", (cap * _delayed()) / 1e36);
        console2.log("pool gives up in a 10% rise (coins)", up / 1e18);
        assertGt(cap, 0);
        uint256 room = _room();
        deal(address(USDG), ann, 1_000_000e6);
        vm.startPrank(ann);
        USDG.approve(address(short), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CuratedShort.OverCap.selector, room + 1, room));
        short.open(_coin(), 1_000_000e6, room + 1, 0, vm.getBlockTimestamp() + 1);
        vm.stopPrank();
        uint256 g = gasleft();
        _open(bob, room / 2, 1_000);
        console2.log("gas: open (with test setup)", g - gasleft());
        assertEq(_owed(d.market, short.accountOf(bob)), room / 2);
        _nothingHeld(address(short));
        _nothingHeld(address(router));
    }

    function test_fork_a_dump_and_the_short_closes_in_profit() public onFork {
        _listAndLend();
        uint256 spent = _open(bob, _room() / 2, 1_500);
        _dump(7_000);
        _hold(35 minutes);
        uint256 g = gasleft();
        vm.prank(bob);
        uint256 paid = short.close(_coin(), type(uint256).max, type(uint256).max, 0, type(uint256).max, vm.getBlockTimestamp() + 1);
        console2.log("gas: close", g - gasleft());
        console2.log("bob put in, got back (USDG)", spent, paid);
        assertGt(paid, spent, "the short made money");
        _nothingHeld(address(short));
        _nothingHeld(address(router));
    }

    function test_fork_a_held_squeeze_liquidates_through_curated_liquidator() public onFork {
        _listAndLend();
        _open(ann, _room() / 2, 1_900);
        address acct = short.accountOf(ann);
        _pump(23_000);
        vm.expectRevert(CuratedLiquidator.Healthy.selector);
        liq.liquidate(_coin(), acct, 0, keeper);
        _hold(35 minutes);
        uint256 g = gasleft();
        vm.prank(keeper);
        uint256 profit = liq.liquidate(_coin(), acct, 0, keeper);
        console2.log("gas: liquidate", g - gasleft());
        console2.log("liquidator profit (USDG)", profit);
        assertGt(profit, 0);
        assertEq(_owed(d.market, acct), 0, "debt repaid");
        _nothingHeld(address(liq));
        _nothingHeld(address(router));
    }

    function test_fork_under_ten_million_no_new_shorts_but_closing_works() public onFork {
        _listAndLend();
        _open(ann, _room() / 4, 1_000);
        _mcapAtDelayed(11_000_000e18);
        _dump(8_000);
        _hold(35 minutes);
        console2.log("market cap at the delayed price (dollars)", listing.mcapOf(_coin()) / 1e18);
        assertLt(listing.mcapOf(_coin()), 10_000_000e18);
        (uint256 cap,) = listing.capOf(_coin());
        assertEq(cap, 0, "no room under the floor");
        (uint256 loanCap,) = listing.loanCapOf(_coin());
        assertEq(loanCap, 0, "nor for loans");
        deal(address(USDG), bob, 1_000e6);
        vm.startPrank(bob);
        USDG.approve(address(short), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CuratedShort.OverCap.selector, 1e18, 0));
        short.open(_coin(), 1_000e6, 1e18, 0, vm.getBlockTimestamp() + 1);
        vm.stopPrank();
        vm.prank(ann);
        uint256 paid = short.close(_coin(), type(uint256).max, type(uint256).max, 0, type(uint256).max, vm.getBlockTimestamp() + 1);
        assertGt(paid, 0);
        assertEq(_owed(d.market, short.accountOf(ann)), 0, "closed under the floor");
    }

    function test_fork_a_coin_loan_and_a_held_dump_liquidates_it() public onFork {
        _listAndLend();
        deal(address(USDG), address(this), 1e6);
        USDG.approve(address(loans), 1e6);
        uint256 g = gasleft();
        loans.openLoans(_coin());
        console2.log("gas: openLoans", g - gasleft());
        CuratedLoans.LoanDesk memory ld = loans.loanDeskOf(_coin());
        deal(address(USDG), lender, 9_000e6);
        vm.startPrank(lender);
        USDG.approve(ld.vault, type(uint256).max);
        IVaultV2(ld.vault).deposit(9_000e6, lender); // the vault takes $10,000 in all
        vm.stopPrank();
        (uint256 cap, uint256 downUsd) = loans.loanCapOf(_coin());
        console2.log("loan cap (USDG)", cap, "pool takes in during a 10% fall (dollars)", downUsd / 1e18);
        assertGt(cap, 0);
        uint256 amount = cap / 2;
        uint256 col = (amount * 1e30 * 10_000) / _delayed() / 1_900;
        deal(_coin(), ann, col);
        vm.startPrank(ann);
        IERC20(_coin()).approve(address(loans), type(uint256).max);
        loans.borrow(_coin(), col, amount, vm.getBlockTimestamp() + 1);
        vm.stopPrank();
        address acct = loans.accountOf(ann);
        _dump(4_500);
        _hold(35 minutes);
        vm.prank(keeper);
        uint256 profit = lliq.liquidate(_coin(), acct, 0, keeper);
        console2.log("loan liquidation profit (USDG)", profit);
        assertGt(profit, 0);
        assertEq(_owed(ld.market, acct), 0);
        _nothingHeld(address(lliq));
        _nothingHeld(address(router));
    }

    function test_fork_bad_debt_stays_with_this_coins_lenders() public onFork {
        _listAndLend();
        _open(ann, _room() / 2, 1_900);
        address acct = short.accountOf(ann);
        Market memory nvda0 = MORPHO.market(Id.wrap(NVDA_MARKET));
        uint256 bu = IVaultV2(BUSDG).totalAssets();
        uint256 vault0 = IVaultV2(d.vault).totalAssets();
        _pump(70_000); // 7x, faster than the delayed price follows
        _hold(35 minutes);
        vm.prank(keeper);
        try liq.liquidate(_coin(), acct, 0, keeper) {} catch {
            // Buying back may cost more than the collateral brings: liquidate on Morpho directly, seizing all.
            Position memory p = MORPHO.position(d.market.id(), acct);
            vm.prank(keeper);
            MORPHO.liquidate(d.market, acct, p.collateral, 0, "");
        }
        Position memory p1 = MORPHO.position(d.market.id(), acct);
        assertEq(p1.collateral, 0, "all collateral seized");
        assertEq(p1.borrowShares, 0, "the rest written off");
        assertLt(IVaultV2(d.vault).totalAssets(), vault0, "this coin's lenders took the loss");
        Market memory nvda1 = MORPHO.market(Id.wrap(NVDA_MARKET));
        assertEq(nvda1.totalSupplyAssets, nvda0.totalSupplyAssets, "NVDA's market untouched");
        assertGe(IVaultV2(BUSDG).totalAssets(), bu, "Borro's USDG vault untouched");
    }
}

/// A Pons coin: NOVAAI, Uniswap v4 against native ETH through Pons's hook, liquidity locked by Pons's locker.
contract CuratedPonsForkTest is CuratedForkBase {
    function _coin() internal pure override returns (address) {
        return 0x51250B135174Ca09450EC01c4afF73CF69DBb590;
    }

    function _name() internal pure override returns (string memory) {
        return "NOVAAI";
    }

    function _venue() internal pure override returns (Venue memory v) {
        v.kind = VENUE_V4;
        v.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(_coin()), 0, 200, IHooks(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044));
        v.pair = PAIR_ETH;
    }
}

/// A Uniswap v3 coin against WETH: CHUMP's 1% pool, priced by its own 30-minute average.
contract CuratedV3ForkTest is CuratedForkBase {
    function _coin() internal pure override returns (address) {
        return 0x0E0d2C89a5a019FE1cF762e5e33187631DACC21B;
    }

    function _name() internal pure override returns (string memory) {
        return "CHUMP";
    }

    function _venue() internal pure override returns (Venue memory v) {
        v.kind = VENUE_V3;
        v.pool = 0x714442e9A611f8561A7dF108D6d925132937cFb8;
        v.pair = PAIR_ETH;
    }
}

/// Adds liquidity to a Uniswap v3 pool on the copy of the chain, paying with dealt tokens.
contract LiquidityAdder is Test {
    function add(address pool, int24 lower, int24 upper, uint128 liquidity) external {
        IV3PoolMint(pool).mint(address(this), lower, upper, liquidity, "");
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        address t0 = IV3Pool(msg.sender).token0();
        address t1 = IV3Pool(msg.sender).token1();
        if (owed0 != 0) {
            deal(t0, address(this), owed0);
            IERC20(t0).transfer(msg.sender, owed0);
        }
        if (owed1 != 0) {
            deal(t1, address(this), owed1);
            IERC20(t1).transfer(msg.sender, owed1);
        }
    }
}

interface IV3PoolMint {
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data) external returns (uint256, uint256);
}

/// A coin paired with a Borro stock token through a Uniswap v3 pool: AI against NVDA in the v3 1% pool, priced by
/// its 30-minute average times NVDA's Chainlink price, traded to USDG through BorroShort's NVDA route. That v3 pool
/// held only about $40 each way within 10% on 2026-10-06 (AI's real liquidity is in its v4 pool, CuratedStockV4ForkTest),
/// so this copy of the chain adds a full-range position worth about $400,000 and fills its observation slots first.
contract CuratedStockForkTest is CuratedForkBase {
    address constant POOL = 0x40ea3e3A6aB2A95F35fD26BCD227AE1F0D5A58Cc;

    function _coin() internal pure override returns (address) {
        return 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
    }

    function _name() internal pure override returns (string memory) {
        return "AI";
    }

    function _venue() internal view override returns (Venue memory v) {
        v.kind = VENUE_V3;
        v.pool = POOL;
        v.pair = PAIR_STOCK;
        v.stockDesk = NVDA_MARKET;
        (,,,, v.pairFeed) = IStockDesks(BORRO_SHORT).deskOf(NVDA_MARKET);
    }

    function _prepare() internal override {
        LiquidityAdder a = new LiquidityAdder();
        a.add(POOL, -887200, 887200, 6e22);
        IV3Pool(POOL).increaseObservationCardinalityNext(1801);
        // One trade writes an observation, and with it the pool takes up its new slots; then 31 minutes of history.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        mover.v3(POOL, uint160((uint256(_slot0v3()) * 10_001) / 10_000));
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _slot0v3() internal view returns (uint160 s) {
        (s,,,,,,) = IV3Pool(POOL).slot0();
    }
}

/// A Bankr coin: STATICS in its Uniswap v4 pool against WETH (an ERC-20 in this pool, not native ETH), run by Bankr's
/// hook, which also holds the pool's liquidity.
contract CuratedBankrForkTest is CuratedForkBase {
    function _coin() internal pure override returns (address) {
        return 0x2d8d6F4A93AcD7a916A5a654ec8b690bA3B3EAdd;
    }

    function _name() internal pure override returns (string memory) {
        return "STATICS";
    }

    function _venue() internal pure override returns (Venue memory v) {
        v.kind = VENUE_V4;
        v.key = PoolKey(Currency.wrap(WETH), Currency.wrap(_coin()), 15_000, 100, IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544));
        v.pair = PAIR_ETH;
    }
}

/// A coin paired with a Borro stock token, as it really trades today: AI against NVDA in its Uniswap v4 pool run by
/// Bankr's hook (dynamic fee), the pool the vetting measured for AI. Priced by the median feed times NVDA's Chainlink
/// price, traded to USDG through BorroShort's NVDA route. Nothing added to the pool.
contract CuratedStockV4ForkTest is CuratedForkBase {
    function _coin() internal pure override returns (address) {
        return 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
    }

    function _name() internal pure override returns (string memory) {
        return "AI (v4, NVDA)";
    }

    function _venue() internal view override returns (Venue memory v) {
        v.kind = VENUE_V4;
        v.key = PoolKey(
            Currency.wrap(_coin()), Currency.wrap(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), 0x800000, 8, IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        v.pair = PAIR_STOCK;
        v.stockDesk = NVDA_MARKET;
        (,,,, v.pairFeed) = IStockDesks(BORRO_SHORT).deskOf(NVDA_MARKET);
    }
}
