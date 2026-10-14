// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BorroLib, IAdapterTimelocks} from "../script/BorroLib.sol";
import {StockList} from "../script/StockList.sol";
import {AddDesksLib} from "../script/AddDesksLib.sol";
import {BorroShort} from "../src/BorroShort.sol";
import {BorroRouter} from "../src/BorroRouter.sol";
import {PairRouter} from "../src/PairRouter.sol";
import {BorroLiquidator} from "../src/BorroLiquidator.sol";
import {BorroSwap} from "../src/BorroSwap.sol";
import {OptionsDesk, IPriceFeed} from "../src/OptionsDesk.sol";

/// Adding desks to the LIVE Borro, on a fork of Robinhood Chain: the deployer opens AAPL (a Uniswap v4 route)
/// and CRCL (a v3 pool) from script/stocks-add.json exactly as script/AddDesks.s.sol does, the Hoard Safe runs
/// batch 1 (the listings on the live BorroShort, BorroRouter, PairRouter and OptionsDesk, and the bUSDG cap
/// submits), three days pass, batch 2 runs the caps, and then the new desks are used through the live contracts:
/// lend, borrow USDG, short, pair, write and fill an option, liquidate.
///   export BORRO_FORK_RPC="$(cat ~/.config/hoard/rpc_url)"; forge test --match-contract AddDesksForkTest
contract AddDesksForkTest is Test, StockList {
    using stdJson for string;

    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant DEPLOYER = 0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6;
    string constant FILE = "stocks-add.json";
    uint256 constant OPEN_FEE_BPS = 10;
    uint256 constant DL = type(uint256).max;
    uint256 constant TICK = 25_000_000;
    uint128 constant PREM = 2e6;
    IMorpho constant morpho = IMorpho(BorroLib.MORPHO);
    IERC20 constant usdg = IERC20(BorroLib.USDG);
    IVaultV2 constant held = IVaultV2(BorroLib.HELD);

    address ann = makeAddr("ann"); // lends stock, borrows USDG, writes a call
    address bob = makeAddr("bob"); // shorts, pairs, buys the call
    address carl = makeAddr("carl"); // lends USDG
    address eve = makeAddr("eve"); // liquidates

    AddDesksLib.Live live;
    AddDesksLib.CapPlan plan;
    string[] syms;
    mapping(string => BorroLib.Stock) stockOf;
    mapping(string => BorroLib.Desk) desk;
    mapping(string => BorroLib.Loan) loan;
    mapping(string => uint256) indexOf;
    BorroShort short;
    BorroRouter router;
    PairRouter pair;
    OptionsDesk options;
    BorroLiquidator liquidator;
    IVaultV2 bUsdg;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        string memory desks = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        live.safe = SAFE;
        live.keeper = KEEPER;
        live.short = desks.readAddress(".short");
        live.router = desks.readAddress(".router");
        live.usdgVault = desks.readAddress(".usdgVault");
        live.usdgAdapter = desks.readAddress(".usdgAdapter");
        live.liquidator = desks.readAddress(".liquidator");
        live.pair = vm.readFile(string.concat(vm.projectRoot(), "/script/out/pair-router.json")).readAddress(".pairRouter");
        live.options = vm.readFile(string.concat(vm.projectRoot(), "/script/out/options-desk.json")).readAddress(".optionsDesk");
        short = BorroShort(live.short);
        router = BorroRouter(live.router);
        pair = PairRouter(live.pair);
        options = OptionsDesk(live.options);
        liquidator = BorroLiquidator(live.liquidator);
        bUsdg = IVaultV2(live.usdgVault);

        // The deployer opens two desks: one on a v4 route, one on a v3 pool.
        syms.push("AAPL");
        syms.push("CRCL");
        BorroLib.Stock[] memory all = loadStocksFrom(FILE);
        IVaultV2 spy = IVaultV2(desks.readAddress(".desks[0].vault"));
        BorroLib.Terms memory t = BorroLib.Terms({
            owner: DEPLOYER, feeRecipient: spy.performanceFeeRecipient(), performanceFee: spy.performanceFee(), salt: bytes32("borro-add-test")
        });
        deal(address(usdg), DEPLOYER, syms.length * BorroLib.USDG_MARKET_SEED);
        for (uint256 k; k < syms.length; k++) {
            uint256 i = _find(all, syms[k]);
            indexOf[syms[k]] = i;
            stockOf[syms[k]] = all[i];
            deal(all[i].token, DEPLOYER, all[i].seed);
            vm.startPrank(DEPLOYER);
            desk[syms[k]] = BorroLib.open(all[i], t);
            loan[syms[k]] = BorroLib.openUsdg(all[i], desk[syms[k]], t.salt);
            BorroLib.lock(desk[syms[k]].vault, 3 days);
            BorroLib.handOver(desk[syms[k]].vault, DEPLOYER, SAFE);
            vm.stopPrank();
        }

        // Batch 1, from the Safe: the listings and the cap submits.
        AddDesksLib.Added[] memory a = _added();
        plan = AddDesksLib.capPlan(live, a);
        AddDesksLib.Call[] memory listings = AddDesksLib.listings(live, a);
        (AddDesksLib.Call[] memory submits, AddDesksLib.Call[] memory executes) = AddDesksLib.capSubmits(live, a, plan);
        for (uint256 i; i < listings.length; i++) {
            vm.prank(SAFE);
            AddDesksLib.send(listings[i]);
        }
        for (uint256 i; i < submits.length; i++) {
            vm.prank(SAFE);
            AddDesksLib.send(submits[i]);
        }
        AddDesksLib.checkListed(live, a);
        AddDesksLib.checkSubmitted(live, executes);
    }

    modifier onFork() {
        if (!forked) return;
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _find(BorroLib.Stock[] memory all, string memory sym) internal pure returns (uint256) {
        for (uint256 i; i < all.length; i++) {
            if (keccak256(bytes(all[i].symbol)) == keccak256(bytes(sym))) return i;
        }
        revert("no such stock");
    }

    function _added() internal view returns (AddDesksLib.Added[] memory a) {
        a = new AddDesksLib.Added[](syms.length);
        for (uint256 k; k < syms.length; k++) {
            a[k].stock = stockOf[syms[k]];
            a[k].desk = desk[syms[k]];
            a[k].loan = loan[syms[k]];
            a[k].route = loadRouteFrom(FILE, indexOf[syms[k]]);
            a[k].v3Pool = loadV3PoolFrom(FILE, indexOf[syms[k]]);
            a[k].name = loadNameFrom(FILE, indexOf[syms[k]]);
        }
    }

    function _executes() internal view returns (AddDesksLib.Call[] memory executes) {
        (, executes) = AddDesksLib.capSubmits(live, _added(), plan);
    }

    /// Three days pass and batch 2 runs (from the keeper: Vault V2 lets anyone run a submitted setting).
    function _executeCaps() internal {
        vm.warp(block.timestamp + 3 days);
        AddDesksLib.Call[] memory executes = _executes();
        for (uint256 i; i < executes.length; i++) {
            vm.prank(KEEPER);
            AddDesksLib.send(executes[i]);
        }
        AddDesksLib.checkCaps(live, _added(), plan);
    }

    /// Carl lends USDG to bUSDG and the keeper moves `amount` of it into `sym`'s new USDG market.
    function _fundUsdgMarket(string memory sym, uint256 amount) internal {
        deal(address(usdg), carl, amount * 2);
        vm.startPrank(carl);
        usdg.approve(address(bUsdg), amount * 2);
        bUsdg.deposit(amount * 2, carl);
        vm.stopPrank();
        vm.startPrank(KEEPER);
        bUsdg.deallocate(live.usdgAdapter, bUsdg.liquidityData(), amount);
        bUsdg.allocate(live.usdgAdapter, abi.encode(loan[sym].market), amount);
        vm.stopPrank();
    }

    function _price(string memory sym) internal view returns (uint256) {
        (, int256 a,,,) = AggregatorV3Interface(stockOf[sym].feed).latestRoundData();
        return uint256(a);
    }

    function _setFeed(string memory sym, uint256 price) internal {
        vm.mockCall(
            stockOf[sym].feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// Dollar value (USDG wei) of `amount` stock wei at the feed price.
    function _worth(string memory sym, uint256 amount) internal view returns (uint256) {
        return (amount * _price(sym)) / 1e20;
    }

    function _quote(bytes32 id, uint256 amount, bool buying) internal returns (uint256 out) {
        bytes memory call_ =
            buying ? abi.encodeCall(BorroShort.quoteBuy, (id, amount)) : abi.encodeCall(BorroShort.quoteSell, (id, amount));
        (bool ok, bytes memory err) = address(short).call(call_);
        require(!ok, "quote did not revert");
        bytes4 sel;
        assembly {
            sel := mload(add(err, 32))
        }
        require(sel == BorroSwap.QuoteResult.selector, "unexpected revert");
        assembly {
            out := mload(add(err, 36))
        }
    }

    /// Lends `amount` of the stock straight to its new vault.
    function _lend(string memory sym, address who, uint256 amount) internal returns (uint256 shares) {
        BorroLib.Desk memory d = desk[sym];
        deal(d.token, who, amount);
        vm.startPrank(who);
        IERC20(d.token).approve(d.vault, amount);
        shares = IVaultV2(d.vault).deposit(amount, who);
        vm.stopPrank();
    }

    /// Bob shorts about $1,500 of `sym` on a $1,000 deposit through the live BorroShort.
    function _short(string memory sym) internal returns (bytes32 id, uint256 proceeds) {
        id = desk[sym].marketId;
        uint256 amount = (1_500e6 * 1e20) / _price(sym);
        uint256 quote = _quote(id, amount, false);
        uint256 net = quote - (quote * OPEN_FEE_BPS) / 10_000;
        deal(address(usdg), bob, 1_000e6);
        vm.startPrank(bob);
        usdg.approve(address(short), 1_000e6);
        proceeds = short.open(id, 1_000e6, amount, (net * 995) / 1000, DL);
        vm.stopPrank();
    }

    function _owedUsdg(string memory sym, address who) internal returns (uint256) {
        MarketParams memory m = loan[sym].market;
        morpho.accrueInterest(m);
        Position memory p = morpho.position(Id.wrap(loan[sym].marketId), who);
        Market memory mk = morpho.market(Id.wrap(loan[sym].marketId));
        return (uint256(p.borrowShares) * (uint256(mk.totalBorrowAssets) + 1)) / (uint256(mk.totalBorrowShares) + 1e6) + 1;
    }

    // ------------------------------------------------------------------ the desks as the deployer left them

    function test_the_deployer_keeps_no_role_and_every_risky_setting_waits() public onFork {
        for (uint256 k; k < syms.length; k++) {
            string memory sym = syms[k];
            BorroLib.Stock memory s = stockOf[sym];
            BorroLib.Desk memory d = desk[sym];
            IVaultV2 v = IVaultV2(d.vault);
            assertEq(v.asset(), s.token, "vault asset");
            assertEq(v.owner(), SAFE, "the Safe owns the vault");
            assertEq(v.curator(), SAFE, "the Safe curates it");
            assertTrue(v.isSentinel(SAFE), "and is its sentinel");
            assertTrue(v.isAllocator(SAFE));
            assertFalse(v.isAllocator(DEPLOYER), "the deployer allocates nothing");
            assertEq(v.liquidityAdapter(), d.adapter);
            assertEq(v.totalAssets(), s.seed, "the seed is in");
            assertEq(v.performanceFee(), IVaultV2(0xC3ED4a5A7dB4102F4Ed37Af26ef0d3f21e2360c1).performanceFee(), "same fee as the SPY vault");
            bytes4[15] memory sel = BorroLib.lockedSelectors();
            for (uint256 i; i < sel.length; i++) assertEq(v.timelock(sel[i]), 3 days, "every risky setting waits");
            assertEq(v.timelock(IVaultV2.setIsAllocator.selector), 0, "removing an allocator does not wait");
            assertEq(IAdapterTimelocks(d.adapter).timelock(IAdapterTimelocks.burnShares.selector), 3 days);

            Market memory m = morpho.market(Id.wrap(d.marketId));
            assertGt(m.lastUpdate, 0, "short market exists");
            assertEq(m.totalSupplyAssets, s.seed, "the seed reached the market");
            Market memory u = morpho.market(Id.wrap(loan[sym].marketId));
            assertEq(u.totalSupplyAssets, BorroLib.USDG_MARKET_SEED, "the USDG market has its dead supply");

            // The short market prices the stock by its feed; the USDG market prices one vault share in USDG.
            uint256 feed = _price(sym);
            uint256 dollars8 = (1e36 * held.convertToAssets(1e18) * 1e2) / IOracle(d.oracle).price();
            assertApproxEqRel(dollars8, feed, 0.005e18, "short oracle agrees with the feed");
            uint256 shareUsdg = (IOracle(loan[sym].oracle).price() * IVaultV2(d.vault).convertToAssets(1e18)) / 1e36; // USDG wei per share
            assertApproxEqRel(shareUsdg, feed / 100, 0.005e18, "USDG oracle agrees with the feed");
            emit log_named_decimal_uint(string.concat(sym, " feed"), feed, 8);
        }
    }

    function test_the_batch_listed_everything_and_the_caps_wait_three_days() public onFork {
        // Listed: the live short desk, the router, the pair router and the options desk know both stocks.
        AddDesksLib.checkListed(live, _added());
        (, PoolKey[] memory route, address v3Pool,,) = short.deskOf(desk["AAPL"].marketId);
        assertEq(route.length, 1, "AAPL trades on v4");
        assertEq(v3Pool, address(0));
        (, route, v3Pool,,) = short.deskOf(desk["CRCL"].marketId);
        assertEq(route.length, 0);
        assertEq(v3Pool, 0x654E4143e82a5824445Ade0824351C2A9ACD95a8, "CRCL trades on its v3 pool");

        // The caps are submitted and wait: running them now fails, and the keeper cannot lend into the market.
        AddDesksLib.Call[] memory executes = _executes();
        assertEq(executes.length, syms.length * 4 + 1 + (plan.raiseLiquidity ? 2 : 0));
        vm.prank(KEEPER);
        vm.expectRevert();
        AddDesksLib.send(executes[0]);
        deal(address(usdg), carl, 10_000e6);
        vm.startPrank(carl);
        usdg.approve(address(bUsdg), 10_000e6);
        bUsdg.deposit(10_000e6, carl);
        vm.stopPrank();
        vm.startPrank(KEEPER);
        bUsdg.deallocate(live.usdgAdapter, bUsdg.liquidityData(), 1_000e6);
        vm.expectRevert();
        bUsdg.allocate(live.usdgAdapter, abi.encode(loan["AAPL"].market), 1_000e6);
        vm.stopPrank();

        // Shorting and lending work at once; only USDG borrowing waits for the caps.
        _lend("AAPL", ann, 5e18);
        (bytes32 id,) = _short("AAPL");
        (uint256 shares,,,,) = short.tabOf(bob, id);
        assertGt(shares, 0, "a short is open before the caps are in");

        // Three days later the caps run and the keeper lends into the new market.
        _executeCaps();
        IVaultV2 v = bUsdg;
        bytes[2] memory ids = BorroLib.loanIdData(live.usdgAdapter, loan["AAPL"]);
        assertEq(v.absoluteCap(keccak256(ids[1])), stockOf["AAPL"].capUsdg);
        assertEq(v.relativeCap(keccak256(ids[1])), BorroLib.WAD);
        assertEq(v.absoluteCap(keccak256(abi.encode("this", live.usdgAdapter))), plan.adapterCapNew, "the adapter grew by the new caps");
        if (plan.raiseLiquidity) {
            emit log_named_decimal_uint("liquidity market (SPY) cap raised to", plan.liquidityCapNew, 6);
        }
        vm.prank(KEEPER);
        bUsdg.allocate(live.usdgAdapter, abi.encode(loan["AAPL"].market), 1_000e6);
        assertGe(morpho.market(Id.wrap(loan["AAPL"].marketId)).totalSupplyAssets, 1_000e6, "USDG is in the new market");
        // Running a setting twice fails: each submit is spent.
        vm.prank(KEEPER);
        vm.expectRevert();
        AddDesksLib.send(executes[0]);
    }

    // ------------------------------------------------------------------ the desks in use, through the live contracts

    function test_aapl_lend_borrow_short_pair_and_option_on_the_live_contracts() public onFork {
        _executeCaps();
        _fundUsdgMarket("AAPL", 50_000e6);
        BorroLib.Desk memory d = desk["AAPL"];
        BorroLib.Loan memory l = loan["AAPL"];
        bytes32 id = d.marketId;

        // Ann lends 10 AAPL through the router, which posts her vault shares on the new USDG market, and borrows.
        deal(d.token, ann, 10e18);
        vm.startPrank(ann);
        IERC20(d.token).approve(address(router), 10e18);
        uint256 posted = router.lendAndPost(l.market, d.token, 10e18, 0);
        uint256 borrowed = (_worth("AAPL", 10e18) * 50) / 100; // half the limit of 62.5%
        morpho.borrow(l.market, borrowed, 0, ann, ann);
        vm.stopPrank();
        assertGt(posted, 0, "vault shares posted");
        assertEq(morpho.position(Id.wrap(l.marketId), ann).collateral, posted);
        assertEq(usdg.balanceOf(ann), borrowed, "USDG borrowed against AAPL");
        emit log_named_decimal_uint("borrowed USDG against 10 AAPL", borrowed, 6);

        // Bob shorts it through the live BorroShort (the vault lends him Ann's AAPL), then closes.
        (, uint256 proceeds) = _short("AAPL");
        (uint256 shares, uint256 principal,,,) = short.tabOf(bob, id);
        assertGt(shares, 0, "short open");
        assertGt(proceeds, 0);
        assertEq(IERC20(d.token).balanceOf(bob), 0, "the stock was sold, not kept");
        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        (shares,,,,) = short.tabOf(bob, id);
        assertEq(shares, 0, "short closed");
        assertEq(usdg.balanceOf(bob) - before, paidOut);
        assertGt(paidOut, 900e6, "most of the deposit comes back (pool fees and spread)");
        emit log_named_decimal_uint("AAPL shorted", principal, 18);
        emit log_named_decimal_uint("paid out after the round trip", paidOut, 6);

        // The pair router buys AAPL through the same route and lends it to the new vault for bob.
        uint256 amount = (100e6 * 1e20) / _price("AAPL");
        uint256 maxCost = (_quote(id, amount, true) * 101) / 100;
        deal(address(usdg), bob, maxCost);
        vm.startPrank(bob);
        usdg.approve(address(pair), maxCost);
        (uint256 cost, uint256 vaultShares) = pair.buyAndLend(id, d.vault, amount, maxCost, 0, DL);
        vm.stopPrank();
        assertGt(vaultShares, 0);
        assertEq(IVaultV2(d.vault).balanceOf(bob), vaultShares, "bob owns the long leg");
        assertLt(cost, (_worth("AAPL", amount) * 105) / 100, "cost near the feed value");

        // Ann writes a covered call on the live options desk, paid in AAPL (lent into the new vault); bob buys it.
        uint64 expiry = options.expiryAfter(uint64(block.timestamp));
        if (expiry < block.timestamp + 2 hours) expiry = options.expiryAfter(expiry);
        uint128 strike = uint128((_price("AAPL") * 90 / 100) / TICK * TICK);
        deal(d.token, ann, 10e18);
        vm.startPrank(ann);
        IERC20(d.token).approve(address(options), 10e18);
        uint256 ask = options.postAskWithStock(stockOf["AAPL"].feed, expiry, strike, 10e18, PREM);
        vm.stopPrank();
        assertEq(options.orderOf(ask).maker, ann);
        assertGt(options.orderOf(ask).locked, 0, "bAAPL shares lock the call");
        deal(address(usdg), bob, 20e6);
        vm.startPrank(bob);
        usdg.approve(address(options), 20e6);
        options.fillAsk(ask, 10e18, 20e6);
        vm.stopPrank();
        bytes32 series = options.seriesIdOf(stockOf["AAPL"].feed, expiry, strike, true);
        assertEq(options.balanceOf(bob, uint256(series)), 10e18, "bob holds ten AAPL calls");
        assertEq(options.seriesOf(series).openUnits, 10e18);

        // Ann repays and takes her shares back on Morpho directly.
        uint256 owed = _owedUsdg("AAPL", ann);
        deal(address(usdg), ann, owed);
        vm.startPrank(ann);
        usdg.approve(address(morpho), owed);
        morpho.repay(l.market, 0, morpho.position(Id.wrap(l.marketId), ann).borrowShares, ann, "");
        morpho.withdrawCollateral(l.market, posted, ann, ann);
        vm.stopPrank();
        assertEq(IVaultV2(d.vault).balanceOf(ann), posted, "her bAAPL is back");
    }

    function test_crcl_on_its_v3_pool_shorts_pairs_and_posts() public onFork {
        BorroLib.Desk memory d = desk["CRCL"];
        bytes32 id = d.marketId;
        _lend("CRCL", ann, (5_000e6 * 1e20) / _price("CRCL"));
        (, uint256 proceeds) = _short("CRCL");
        assertGt(proceeds, 0);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        assertGt(paidOut, 900e6, "the CRCL round trip through v3 pays most of the deposit back");
        (uint256 shares,,,,) = short.tabOf(bob, id);
        assertEq(shares, 0);

        uint256 amount = (100e6 * 1e20) / _price("CRCL");
        uint256 maxCost = (_quote(id, amount, true) * 101) / 100;
        deal(address(usdg), bob, maxCost);
        vm.startPrank(bob);
        usdg.approve(address(pair), maxCost);
        (, uint256 vaultShares) = pair.buyAndLend(id, d.vault, amount, maxCost, 0, DL);
        vm.stopPrank();
        assertGt(vaultShares, 0, "the pair router lends CRCL to the new vault");

        deal(d.token, ann, 10e18);
        vm.startPrank(ann);
        IERC20(d.token).approve(address(router), 10e18);
        uint256 posted = router.lendAndPost(loan["CRCL"].market, d.token, 10e18, 0);
        vm.stopPrank();
        assertEq(morpho.position(Id.wrap(loan["CRCL"].marketId), ann).collateral, posted, "the router posts on the new USDG market");
    }

    // ------------------------------------------------------------------ the live liquidator

    function test_the_live_liquidator_liquidates_a_usdg_borrow_on_the_new_market() public onFork {
        _executeCaps();
        _fundUsdgMarket("AAPL", 50_000e6);
        BorroLib.Desk memory d = desk["AAPL"];
        BorroLib.Loan memory l = loan["AAPL"];
        deal(d.token, ann, 20e18);
        vm.startPrank(ann);
        IERC20(d.token).approve(address(router), 20e18);
        router.lendAndPost(l.market, d.token, 20e18, 0);
        uint256 price = _price("AAPL");
        morpho.borrow(l.market, (_worth("AAPL", 20e18) * 60) / 100, 0, ann, ann); // 60%, under the 62.5% limit
        vm.stopPrank();
        Position memory p = morpho.position(Id.wrap(l.marketId), ann);

        vm.prank(eve);
        vm.expectRevert(bytes("position is healthy"));
        liquidator.liquidate(l.market, ann, 0, p.borrowShares, d.marketId, 0);

        // AAPL falls 10% by its feed: owed 60, held 90. Over the limit.
        _setFeed("AAPL", (price * 90) / 100);
        uint256 before = usdg.balanceOf(eve);
        vm.prank(eve);
        uint256 profit = liquidator.liquidate(l.market, ann, 0, p.borrowShares, d.marketId, 1);
        assertGt(profit, 0);
        assertEq(usdg.balanceOf(eve) - before, profit, "the caller is paid");
        assertEq(morpho.position(Id.wrap(l.marketId), ann).borrowShares, 0, "the loan is repaid");
        assertGe(morpho.market(Id.wrap(l.marketId)).totalSupplyAssets, 50_000e6, "USDG lenders are whole");
        assertEq(usdg.balanceOf(address(liquidator)), 0);
        assertEq(IERC20(d.token).balanceOf(address(liquidator)), 0);
        assertEq(IERC20(d.vault).balanceOf(address(liquidator)), 0);
        emit log_named_decimal_uint("USDG liquidation on the new AAPL market paid the caller", profit, 6);
    }

    function test_the_live_liquidator_liquidates_a_short_on_the_new_desk() public onFork {
        BorroLib.Desk memory d = desk["CRCL"];
        _lend("CRCL", ann, (5_000e6 * 1e20) / _price("CRCL"));
        _short("CRCL");
        address acct = short.accountOf(bob);
        Position memory p = morpho.position(Id.wrap(d.marketId), acct);
        uint256 price = _price("CRCL");
        _setFeed("CRCL", (price * 120) / 100); // owed $1,800 against about $2,500 held: over 62.5%
        vm.prank(eve);
        uint256 profit = liquidator.liquidate(d.market, acct, 0, p.borrowShares, d.marketId, 0);
        assertGt(profit, 0);
        assertEq(morpho.position(Id.wrap(d.marketId), acct).borrowShares, 0, "the short is gone");
        assertEq(morpho.market(Id.wrap(d.marketId)).totalBorrowAssets, 0, "every share of CRCL came back");
        emit log_named_decimal_uint("CRCL short liquidation paid the caller", profit, 6);
    }
}
