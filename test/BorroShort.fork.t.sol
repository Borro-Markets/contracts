// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {BorroLib, IERC20Min} from "../script/BorroLib.sol";
import {StockList} from "../script/StockList.sol";
import {BorroShort, BorroAccount, IUniswapV3Factory, IUniswapV3Pool, IHeldVault, IBorroRewards} from "../src/BorroShort.sol";
import {BorroRewards} from "../src/BorroRewards.sol";
import {BorroSwap} from "../src/BorroSwap.sol";

/// Runs against a fork of Robinhood Chain: BORRO_FORK_RPC=<rpc> forge test
/// Morpho, the pools, the price feeds and the tokens are the real ones.
contract BorroShortForkTest is Test, StockList {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    uint256 constant OPEN_FEE_BPS = 10;
    uint256 constant DL = type(uint256).max; // no deadline in tests unless a test sets one
    IMorpho constant morpho = IMorpho(BorroLib.MORPHO);
    IERC20 constant usdg = IERC20(BorroLib.USDG);

    address owner = makeAddr("owner");
    address sink = makeAddr("sink");
    address ann = makeAddr("ann"); // lends stock
    address bob = makeAddr("bob"); // shorts
    address eve = makeAddr("eve");

    BorroShort short;
    BorroRewards rewards;
    IVaultV2 constant held = IVaultV2(BorroLib.HELD); // the USDG lending vault whose shares are the collateral
    BorroLib.Stock[] stocks;
    mapping(string => BorroLib.Desk) desk;
    mapping(string => BorroLib.Stock) stockOf;
    mapping(string => bool) hasRoute;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        short = new BorroShort(
            morpho, IPoolManager(POOL_MANAGER), IUniswapV3Factory(V3_FACTORY), usdg, IHeldVault(BorroLib.HELD), BorroLib.IRM, owner
        );
        rewards = new BorroRewards(usdg, address(short), owner);
        vm.prank(owner);
        short.setRewards(IBorroRewards(address(rewards)));
        vm.prank(owner);
        short.setFee(OPEN_FEE_BPS, sink);
        BorroLib.Stock[] memory list = loadStocks();
        BorroLib.Terms memory t =
            BorroLib.Terms({owner: owner, feeRecipient: sink, performanceFee: 0.1e18, salt: bytes32("test")});
        for (uint256 i; i < list.length; i++) {
            deal(list[i].token, owner, list[i].seed);
            vm.startPrank(owner);
            BorroLib.Desk memory d = BorroLib.open(list[i], t);
            bool routed = loadRoute(i).length != 0 || loadV3Pool(i) != address(0);
            if (routed) short.list(d.market, loadRoute(i), loadV3Pool(i));
            hasRoute[list[i].symbol] = routed;
            vm.stopPrank();
            stocks.push(list[i]);
            desk[list[i].symbol] = d;
            stockOf[list[i].symbol] = list[i];
        }

        deal(address(usdg), bob, 100_000e6);
        vm.startPrank(bob);
        usdg.approve(address(short), type(uint256).max);
        vm.stopPrank();
    }

    modifier onFork() {
        if (!forked) return;
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _lend(string memory sym, uint256 amount) internal {
        BorroLib.Desk memory d = desk[sym];
        deal(d.token, ann, amount);
        vm.startPrank(ann);
        IERC20Min(d.token).approve(d.vault, amount);
        IVaultV2(d.vault).deposit(amount, ann);
        vm.stopPrank();
    }

    function _price(string memory sym) internal view returns (uint256) {
        (, int256 a,,,) = AggregatorV3Interface(stockOf[sym].feed).latestRoundData();
        return uint256(a);
    }

    /// Dollar value (USDG wei) of `amount` stock wei at the feed price.
    function _worth(string memory sym, uint256 amount) internal view returns (uint256) {
        return (amount * _price(sym)) / 1e20;
    }

    function _quote(bytes32 id, uint256 amount, bool buying) internal returns (uint256 out) {
        bytes memory call_ = buying
            ? abi.encodeCall(BorroShort.quoteBuy, (id, amount))
            : abi.encodeCall(BorroShort.quoteSell, (id, amount));
        (bool ok, bytes memory err) = address(short).call(call_);
        require(!ok, "quote did not revert");
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        require(sel == BorroSwap.QuoteResult.selector, "unexpected revert");
        assembly { out := mload(add(err, 36)) }
    }

    /// Opens a short for bob the way the site does: quote first, then allow half a percent of slip.
    function _open(string memory sym, uint256 deposit, uint256 amount) internal returns (uint256 proceeds) {
        bytes32 id = desk[sym].marketId;
        uint256 quote = _quote(id, amount, false);
        uint256 net = quote - (quote * OPEN_FEE_BPS) / 10_000;
        vm.prank(bob);
        proceeds = short.open(id, deposit, amount, (net * 995) / 1000, DL);
    }

    function _setFeed(string memory sym, uint256 price) internal {
        vm.mockCall(
            stockOf[sym].feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// Stock owed right now, interest included.
    function _owed(string memory sym, address who) internal returns (uint256) {
        morpho.accrueInterest(desk[sym].market);
        Position memory p = _pos(sym, who);
        Market memory m = morpho.market(Id.wrap(desk[sym].marketId));
        return (uint256(p.borrowShares) * (uint256(m.totalBorrowAssets) + 1)) / (uint256(m.totalBorrowShares) + 1e6) + 1;
    }

    function _pos(string memory sym, address who) internal view returns (Position memory) {
        return morpho.position(Id.wrap(desk[sym].marketId), short.accountOf(who));
    }

    /// The market falls: stock is sold into the desk's Uniswap v3 pool until selling one share brings
    /// `percent` less than it did, and the feed is set to the new price. Only for stocks that trade on v3.
    function _fall(string memory sym, uint256 percent) internal {
        bytes32 id = desk[sym].marketId;
        (,, address pool,,) = short.deskOf(id);
        require(pool != address(0), "not a v3 stock");
        address token = desk[sym].token;
        uint256 target = (_quote(id, 1e18, false) * (100 - percent)) / 100;
        bool zeroForOne = IUniswapV3Pool(pool).token0() == token;
        for (uint256 i; i < 200 && _quote(id, 1e18, false) > target; i++) {
            deal(token, address(this), 100e18);
            IUniswapV3Pool(pool).swap(
                address(this), zeroForOne, int256(100e18), zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341), abi.encode(token)
            );
        }
        // One share's price in the pool, as the feed would report it (8 decimals against USDG's 6).
        _setFeed(sym, ((_quote(id, 1e18, false) + _quote(id, 1e18, true)) / 2) * 100);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        IERC20(abi.decode(data, (address))).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    // ------------------------------------------------------------------ quotes

    function test_every_stock_sells_and_buys_near_the_feed_price() public onFork {
        for (uint256 i; i < stocks.length; i++) {
            string memory sym = stocks[i].symbol;
            if (!hasRoute[sym]) continue;
            bytes32 id = desk[sym].marketId;
            uint256 amount = 2e18;
            uint256 fair = _worth(sym, amount);
            uint256 sell = _quote(id, amount, false);
            uint256 buy = _quote(id, amount, true);
            assertGt(buy, sell, "buying costs more than selling brings");
            assertApproxEqRel(sell, fair, 0.03e18, string.concat(sym, " sale within 3% of the feed"));
            assertApproxEqRel(buy, fair, 0.03e18, string.concat(sym, " purchase within 3% of the feed"));
            emit log_named_decimal_uint(string.concat(sym, " sell 2"), sell, 6);
            emit log_named_decimal_uint(string.concat(sym, " buy 2"), buy, 6);
        }
    }

    // ------------------------------------------------------------------ open

    function test_open_borrows_sells_and_banks_the_money() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        uint256 quote = _quote(id, 10e18, false);

        vm.prank(bob);
        uint256 proceeds = short.open(id, 2_000e6, 10e18, (quote * 995) / 1000, DL);

        assertEq(proceeds, quote - (quote * OPEN_FEE_BPS) / 10_000, "sold at the quoted price, less the fee");
        assertEq(usdg.balanceOf(sink), (quote * OPEN_FEE_BPS) / 10_000, "the fee reached the recipient");
        Position memory p = _pos("NVDA", bob);
        assertApproxEqAbs(held.previewRedeem(p.collateral), 2_000e6 + proceeds, 3, "deposit and sale money are both held, in the vault");
        assertEq(held.balanceOf(address(short)), 0, "no vault shares stay in the contract");
        assertGt(p.borrowShares, 0);
        assertEq(usdg.balanceOf(bob), 98_000e6, "only the deposit left the wallet");
        assertEq(IERC20(desk["NVDA"].token).balanceOf(bob), 0, "the stock was sold, not kept");
        assertEq(usdg.balanceOf(address(short)), 0, "nothing stays in the contract");
        assertEq(IERC20(desk["NVDA"].token).balanceOf(address(short)), 0);
    }

    function test_open_sizes_past_a_plain_borrow() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        // $1,000 deposit. A plain borrow tops out at 62.5% of it. With the sale money banked, more fits.
        uint256 amount = (1_000e6 * 1e20 * 120) / (_price("NVDA") * 100); // stock worth $1,200
        _open("NVDA", 1_000e6, amount);
        assertGt(_worth("NVDA", amount), 625e6);
    }

    function test_open_refuses_a_short_past_the_limit() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        uint256 amount = (1_000e6 * 1e20 * 180) / (_price("NVDA") * 100); // worth $1,800 on a $1,000 deposit
        uint256 quote = _quote(id, amount, false);
        vm.prank(bob);
        vm.expectRevert(bytes("insufficient collateral"));
        short.open(id, 1_000e6, amount, (quote * 995) / 1000, DL);
    }

    function test_open_refuses_a_bad_price() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        uint256 quote = _quote(id, 10e18, false);
        uint256 net = quote - (quote * OPEN_FEE_BPS) / 10_000;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BorroShort.TooLittle.selector, net, net + 1));
        short.open(id, 2_000e6, 10e18, net + 1, DL);
        assertEq(usdg.balanceOf(bob), 100_000e6, "nothing moved");
    }

    function test_each_shorter_gets_an_account_only_they_can_empty() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        address predicted = short.accountOf(bob);
        assertEq(predicted.code.length, 0, "no account before the first use");
        _open("NVDA", 2_000e6, 5e18);
        BorroAccount acct = BorroAccount(short.accountOf(bob));
        assertEq(address(acct), predicted, "the address was known in advance");
        assertEq(acct.owner(), bob);
        assertEq(acct.short(), address(short));
        assertTrue(morpho.isAuthorized(address(acct), address(short)));
        assertTrue(short.accountOf(eve) != address(acct));

        // Nobody else can take the held money, and the owner cannot take what the short still needs.
        Position memory p = _pos("NVDA", bob);
        vm.prank(eve);
        vm.expectRevert(BorroAccount.OnlyOwner.selector);
        acct.withdrawHeld(desk["NVDA"].market, 1, eve);
        vm.prank(bob);
        vm.expectRevert(bytes("insufficient collateral"));
        acct.withdrawHeld(desk["NVDA"].market, p.collateral, bob);

        // The way out without Borro: return the stock on Morpho, then take the held money.
        deal(desk["NVDA"].token, bob, 6e18);
        vm.startPrank(bob);
        IERC20(desk["NVDA"].token).approve(address(morpho), 6e18);
        morpho.repay(desk["NVDA"].market, 0, p.borrowShares, address(acct), "");
        acct.withdrawHeld(desk["NVDA"].market, p.collateral, bob);
        uint256 back = held.redeem(p.collateral, bob, bob);
        vm.stopPrank();
        assertGt(back, 2_000e6, "deposit and sale money, as USDG");
        id;
    }

    function test_borrowing_to_the_wallet_works_and_is_not_a_short() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        vm.startPrank(bob);
        short.addDeposit(id, 3_000e6);
        short.borrow(id, 5e18);
        vm.expectRevert(bytes("insufficient collateral"));
        short.borrow(id, 5e18);
        vm.stopPrank();
        assertEq(IERC20(desk["NVDA"].token).balanceOf(bob), 5e18, "the shares are in the wallet");
        (uint256 tracked,,,,) = short.tabOf(bob, id);
        assertEq(tracked, 0, "nothing on the record");
        // Eve has no money held, so she cannot borrow.
        vm.prank(eve);
        vm.expectRevert(bytes("insufficient collateral"));
        short.borrow(id, 1e18);
    }

    // ------------------------------------------------------------------ close

    function test_round_trip_costs_fees_and_rent_only() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        uint256 proceeds = _open("NVDA", 2_000e6, 10e18);

        vm.warp(block.timestamp + 7 days);
        vm.mockCall(
            stockOf["NVDA"].feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(_price("NVDA")), block.timestamp, block.timestamp, uint80(1))
        );

        uint256 cost = _quote(id, 10.02e18, true); // a little over what is owed after a week
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, cost, DL);

        Position memory p = _pos("NVDA", bob);
        assertEq(p.borrowShares, 0, "nothing owed");
        assertEq(p.collateral, 0, "no collateral left behind");
        assertEq(usdg.balanceOf(bob), 98_000e6 + paidOut);
        uint256 lost = 2_000e6 - paidOut;
        // Price did not move: the loss is two pool fees of 0.3%, the price impact and a week of rent.
        assertLt(lost, (proceeds * 15) / 1000, "under 1.5% of the position");
        assertGt(lost, 0);
        emit log_named_decimal_uint("short of USD", proceeds, 6);
        emit log_named_decimal_uint("round trip cost USD", lost, 6);
        assertEq(usdg.balanceOf(address(short)), 0);
        assertEq(IERC20(desk["NVDA"].token).balanceOf(address(short)), 0);
    }

    function test_two_hop_stock_round_trips() public onFork {
        _lend("QQQ", 20e18);
        bytes32 id = desk["QQQ"].marketId;
        vm.startPrank(bob);
        uint256 proceeds = short.open(id, 3_000e6, 3e18, 0, DL);
        assertApproxEqRel(proceeds, _worth("QQQ", 3e18), 0.02e18);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        vm.stopPrank();
        assertApproxEqRel(paidOut, 3_000e6, 0.02e18);
        assertEq(_pos("QQQ", bob).borrowShares, 0);
    }

    function test_partial_close_keeps_the_rest_open() public onFork {
        _lend("TSLA", 50e18);
        bytes32 id = desk["TSLA"].marketId;
        _open("TSLA", 3_000e6, 6e18);
        vm.startPrank(bob);
        Position memory before = _pos("TSLA", bob);
        short.close(id, before.borrowShares / 2, before.collateral / 2, 0, type(uint256).max, DL);
        vm.stopPrank();
        Position memory p = _pos("TSLA", bob);
        assertApproxEqAbs(p.borrowShares, before.borrowShares / 2, 1);
        assertApproxEqAbs(p.collateral, before.collateral - before.collateral / 2, 1);
    }

    function test_close_refuses_a_bad_price() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 2_000e6, 10e18);
        vm.startPrank(bob);
        vm.expectRevert();
        short.close(id, type(uint256).max, type(uint256).max, 0, 100e6, DL);
        vm.stopPrank();
        assertGt(_pos("NVDA", bob).borrowShares, 0, "still open");
    }

    function test_close_cannot_strip_collateral_from_an_open_short() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 1_000e6, 5e18);
        vm.startPrank(bob);
        Position memory p = _pos("NVDA", bob);
        vm.expectRevert(bytes("insufficient collateral"));
        short.close(id, p.borrowShares / 10, p.collateral, 0, type(uint256).max, DL);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ who can do what

    function test_nobody_can_act_on_someone_elses_short() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 2_000e6, 10e18);
        Position memory before = _pos("NVDA", bob);
        address acct = short.accountOf(bob);

        // Eve and the owner can only ever reach their own, empty, positions.
        vm.prank(eve);
        vm.expectRevert(BorroShort.NothingOwed.selector);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        vm.prank(owner);
        vm.expectRevert(BorroShort.NothingOwed.selector);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);

        // The callbacks answer to Morpho and the pool manager alone.
        vm.prank(eve);
        vm.expectRevert(BorroShort.OnlyMorpho.selector);
        short.onMorphoRepay(1e18, abi.encode(acct, id, before.collateral, type(uint256).max));
        vm.prank(eve);
        vm.expectRevert(BorroShort.OnlyMorpho.selector);
        short.onMorphoSupplyCollateral(0, abi.encode(acct, id, 1e18, 0, 0));
        vm.prank(eve);
        vm.expectRevert(BorroSwap.OnlyPoolManager.selector);
        short.unlockCallback("");

        Position memory p = _pos("NVDA", bob);
        assertEq(p.collateral, before.collateral);
        assertEq(p.borrowShares, before.borrowShares);
    }

    function test_owner_lists_only_honest_routes() public onFork {
        BorroLib.Desk memory d = desk["NVDA"];
        PoolKey[] memory hooked = new PoolKey[](1);
        hooked[0] = PoolKey(Currency.wrap(address(usdg)), Currency.wrap(d.token), 3000, 60, IHooks(address(0xBEEF)));
        PoolKey[] memory wrongEnd = new PoolKey[](1);
        wrongEnd[0] = PoolKey(Currency.wrap(desk["SPY"].token), Currency.wrap(address(usdg)), 3000, 60, IHooks(address(0)));

        bytes32 id = d.marketId;
        vm.startPrank(owner);
        vm.expectRevert(BorroShort.BadRoute.selector);
        short.queueRoute(id, hooked, address(0));
        vm.expectRevert(BorroShort.BadRoute.selector);
        short.queueRoute(id, wrongEnd, address(0));
        MarketParams memory fake = d.market;
        fake.lltv = 0.98e18;
        vm.expectRevert(BorroShort.BadMarket.selector);
        short.list(fake, loadRoute(2), address(0)); // no such market on Morpho
        MarketParams memory otherIrm = d.market;
        otherIrm.irm = address(0xBEEF);
        vm.expectRevert(BorroShort.BadMarket.selector);
        short.list(otherIrm, loadRoute(2), address(0));
        // A v3 pool of the wrong pair, or a route and a pool together, are refused too.
        vm.expectRevert(BorroShort.BadRoute.selector);
        short.queueRoute(id, new PoolKey[](0), loadV3Pool(8)); // GME's pool for NVDA's market
        vm.expectRevert(BorroShort.BadRoute.selector);
        short.queueRoute(desk["GME"].marketId, loadRoute(2), loadV3Pool(8));
        vm.expectRevert();
        short.queueRoute(desk["GME"].marketId, new PoolKey[](0), address(0xBEEF)); // not a pool at all
        vm.stopPrank();

        vm.prank(eve);
        vm.expectRevert();
        short.list(d.market, loadRoute(2), address(0));
    }

    function test_new_stocks_round_trip() public onFork {
        string[3] memory syms = ["PLTR", "SPCX", "GME"];
        for (uint256 i; i < 3; i++) {
            _lend(syms[i], 40e18);
            bytes32 id = desk[syms[i]].marketId;
            uint256 proceeds = _open(syms[i], 3_000e6, 10e18);
            assertApproxEqRel(proceeds, _worth(syms[i], 10e18), 0.03e18);
            vm.prank(bob);
            uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
            assertApproxEqRel(paidOut, 3_000e6, 0.03e18);
            emit log_named_decimal_uint(string.concat(syms[i], " round trip cost USD"), 3_000e6 - paidOut, 6);
        }
    }

    function test_v3_stock_sells_and_buys_back_through_its_pool() public onFork {
        _lend("GME", 500e18);
        bytes32 id = desk["GME"].marketId;
        (,, address pool,,) = short.deskOf(id);
        assertTrue(pool != address(0), "GME trades on v3");
        uint256 proceeds = _open("GME", 1_000e6, 40e18);
        assertApproxEqRel(proceeds, _worth("GME", 40e18), 0.03e18);
        assertEq(IERC20(desk["GME"].token).balanceOf(address(short)), 0);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        assertApproxEqRel(paidOut, 1_000e6, 0.03e18);
        assertEq(_pos("GME", bob).borrowShares, 0);
        assertEq(usdg.balanceOf(address(short)), 0);
    }

    function test_v3_callback_answers_only_to_the_live_pool() public onFork {
        vm.prank(eve);
        vm.expectRevert(BorroSwap.OnlyPool.selector);
        short.uniswapV3SwapCallback(1, -1, abi.encode(true, 1, false, false));
    }

    function test_fee_is_capped_and_owner_only() public onFork {
        vm.prank(eve);
        vm.expectRevert();
        short.setFee(5, eve);
        vm.startPrank(owner);
        vm.expectRevert(BorroShort.FeeTooHigh.selector);
        short.setFee(31, sink);
        vm.expectRevert(BorroShort.FeeTooHigh.selector);
        short.setFee(5, address(0));
        short.setFee(0, sink);
        vm.stopPrank();
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        uint256 quote = _quote(id, 10e18, false);
        vm.prank(bob);
        uint256 proceeds = short.open(id, 2_000e6, 10e18, (quote * 995) / 1000, DL);
        assertEq(proceeds, quote, "no fee when the fee is zero");
    }

    function test_route_changes_wait_two_days_and_pause_only_stops_opening() public onFork {
        _lend("SPCX", 40e18);
        bytes32 id = desk["SPCX"].marketId;
        _open("SPCX", 1_000e6, 5e18);

        // Listing twice is refused; a change must be queued.
        vm.startPrank(owner);
        vm.expectRevert(BorroShort.AlreadyListed.selector);
        short.list(desk["SPCX"].market, new PoolKey[](0), loadV3Pool(7));
        PoolKey[] memory v4 = new PoolKey[](1); // SPCX's 1% v4 pool, a real alternative to its v3 pool
        v4[0] = PoolKey(Currency.wrap(desk["SPCX"].token), Currency.wrap(address(usdg)), 10000, 200, IHooks(address(0)));
        short.queueRoute(id, v4, address(0));
        vm.stopPrank();
        (,, uint256 readyAt) = short.pendingOf(id);
        assertEq(readyAt, block.timestamp + 2 days);
        vm.expectRevert(BorroShort.NotReady.selector);
        short.applyRoute(id);

        // Pause: no new shorts and no new borrows, closing still works.
        vm.prank(owner);
        short.pause(id, true);
        vm.prank(bob);
        vm.expectRevert(BorroShort.IsPaused.selector);
        short.open(id, 100e6, 1e18, 0, DL);
        vm.prank(bob);
        vm.expectRevert(BorroShort.IsPaused.selector);
        short.borrow(id, 1e18);
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        assertEq(_pos("SPCX", bob).borrowShares, 0);

        // After the wait, anyone can apply the change, and the desk trades on v4 from then on.
        vm.warp(block.timestamp + 2 days);
        vm.prank(eve);
        short.applyRoute(id);
        (, PoolKey[] memory route, address pool,,) = short.deskOf(id);
        assertEq(route.length, 1);
        assertEq(pool, address(0));
        vm.prank(owner);
        short.pause(id, false);
        _lend("SPCX", 40e18);
        _open("SPCX", 1_000e6, 2e18);
    }

    function test_route_change_shape_is_checked_when_queued() public onFork {
        bytes32 id = desk["SPCX"].marketId;
        vm.prank(owner);
        vm.expectRevert(BorroShort.BadRoute.selector);
        short.queueRoute(id, loadRoute(0), address(0)); // SPY's route does not end at SPCX
    }

    function test_deadline_is_honoured() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        vm.prank(bob);
        vm.expectRevert(BorroShort.Expired.selector);
        short.open(id, 1_000e6, 1e18, 0, block.timestamp - 1);
    }

    function test_close_with_nothing_owed_hands_back_the_collateral() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 2_000e6, 5e18);
        // Someone else repays bob's debt (Morpho lets anyone repay).
        Position memory p = _pos("NVDA", bob);
        deal(desk["NVDA"].token, eve, 10e18);
        vm.startPrank(eve);
        IERC20(desk["NVDA"].token).approve(address(morpho), 10e18);
        morpho.repay(desk["NVDA"].market, 0, p.borrowShares, short.accountOf(bob), "");
        vm.stopPrank();
        uint256 before = usdg.balanceOf(bob);
        uint256 worth = held.previewRedeem(p.collateral);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, 0, DL);
        assertEq(paidOut, worth, "all of the held money, as USDG");
        assertEq(usdg.balanceOf(bob), before + worth);
    }

    function test_underwater_close_takes_a_top_up() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 1_000e6, 4e18);
        // The stock jumps 40% on the pool: buying back now costs more than the collateral held.
        // Simulate by taking most of the collateral out of reach: close with only a slice of it.
        Position memory p = _pos("NVDA", bob);
        uint256 slice = p.collateral / 4;
        uint256 cost = _quote(id, 4.01e18, true);
        assertGt(cost, held.previewRedeem(slice), "the slice alone cannot pay");
        vm.prank(bob);
        vm.expectRevert();
        short.close(id, type(uint256).max, slice, 0, type(uint256).max, DL);
        uint256 topUp = cost;
        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, slice, topUp, type(uint256).max, DL);
        assertEq(_pos("NVDA", bob).borrowShares, 0);
        assertEq(usdg.balanceOf(bob), before - topUp + paidOut, "the unused top-up came back");
        assertEq(usdg.balanceOf(address(short)), 0);
    }

    function test_stray_usdg_is_not_paid_to_a_closer() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 2_000e6, 5e18);
        deal(address(usdg), address(short), 500e6); // someone sends USDG here by mistake
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        assertEq(usdg.balanceOf(address(short)), 500e6, "the stray money stayed put");
        vm.prank(owner);
        short.sweep(usdg, sink);
        assertEq(usdg.balanceOf(address(short)), 0);
    }

    // ------------------------------------------------------------------ held money earns interest

    function test_held_money_earns_while_the_short_is_open() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 2_000e6, 8e18);
        uint256 heldShares = _pos("NVDA", bob).collateral;
        uint256 before = held.previewRedeem(heldShares);

        uint256 price = _price("NVDA");
        vm.warp(block.timestamp + 30 days);
        _setFeed("NVDA", price);

        uint256 later = held.previewRedeem(heldShares);
        assertGt(later, before, "the same shares redeem for more USDG");
        emit log_named_decimal_uint("held USDG", before, 6);
        emit log_named_decimal_uint("interest on it in 30 days", later - before, 6);
        // At an unchanged stock price the interest more than pays for the rent at this shelf's rate.
        uint256 owed = _owed("NVDA", bob);
        uint256 rent = _worth("NVDA", owed - 8e18);
        emit log_named_decimal_uint("rent on the short in 30 days, USD", rent, 6);
        assertGt(later - before, rent, "holding the short paid more than it cost");
    }

    function test_add_and_take_deposit_move_usdg_through_the_vault() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        uint256 start = usdg.balanceOf(bob);
        vm.startPrank(bob);
        uint256 shares = short.addDeposit(id, 1_000e6);
        assertEq(_pos("NVDA", bob).collateral, shares);
        assertEq(usdg.balanceOf(bob), start - 1_000e6);
        uint256 back = short.takeDeposit(id, type(uint256).max);
        vm.stopPrank();
        assertApproxEqAbs(back, 1_000e6, 3, "it comes back as USDG");
        assertEq(_pos("NVDA", bob).collateral, 0);
        assertEq(held.balanceOf(address(short)), 0);
        assertEq(usdg.balanceOf(address(short)), 0);

        // With a short open, only what the position can spare comes out.
        _open("NVDA", 1_000e6, 5e18);
        vm.prank(bob);
        vm.expectRevert(bytes("insufficient collateral"));
        short.takeDeposit(id, type(uint256).max);
    }

    // ------------------------------------------------------------------ rent refunds

    function _fund(uint256 amount) internal {
        deal(address(usdg), eve, amount);
        vm.startPrank(eve);
        usdg.approve(address(rewards), amount);
        rewards.fund(amount);
        vm.stopPrank();
    }

    function test_funding_splits_between_rent_and_the_weeks_prize() public onFork {
        _fund(1_000e6);
        assertEq(rewards.rentPot(), 700e6);
        assertEq(rewards.prizePot(rewards.week()), 300e6);
        assertEq(usdg.balanceOf(address(rewards)), 1_000e6);
    }

    function test_rent_is_refunded_at_close_from_the_pot() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _fund(10_000e6);
        _open("NVDA", 2_000e6, 8e18);
        uint256 price = _price("NVDA");
        vm.warp(block.timestamp + 30 days);
        _setFeed("NVDA", price);

        uint256 rent = _worth("NVDA", _owed("NVDA", bob) - 8e18);
        uint256 potBefore = rewards.rentPot();
        uint256 balBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        uint256 refund = usdg.balanceOf(bob) - balBefore - paidOut;

        assertGt(refund, 0, "rent came back");
        assertApproxEqRel(refund, rent, 0.02e18, "about all of the rent, at the price it was bought back");
        assertEq(rewards.rentPot(), potBefore - refund);
        emit log_named_decimal_uint("rent paid USD", rent, 6);
        emit log_named_decimal_uint("rent refunded USD", refund, 6);
        (uint256 shares,,,,) = short.tabOf(bob, id);
        assertEq(shares, 0, "the record is cleared");
    }

    function test_rent_refund_stops_at_the_yearly_cap_and_at_an_empty_pot() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        // Cap the refund at 0.1% a year: under the rent this shelf charges. New terms start next week.
        vm.prank(owner);
        rewards.setTerms(3_000, 10, 500, 500e6);
        assertEq(rewards.terms().rentCapBps, 500, "not yet");
        vm.warp(rewards.weekEnds() + 1);
        assertEq(rewards.terms().rentCapBps, 500, "still not the week after");
        vm.warp(rewards.weekEnds() + 1);
        assertEq(rewards.terms().rentCapBps, 10, "in force from the week after next");
        _fund(10_000e6);
        uint256 proceeds = _open("NVDA", 2_000e6, 8e18);
        uint256 price = _price("NVDA");
        vm.warp(block.timestamp + 30 days);
        _setFeed("NVDA", price);
        uint256 rent = _worth("NVDA", _owed("NVDA", bob) - 8e18);

        uint256 balBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        uint256 refund = usdg.balanceOf(bob) - balBefore - paidOut;
        uint256 cap = (_worth("NVDA", 8e18) * 10 * 30 days) / (10_000 * 365 days);
        assertApproxEqRel(refund, cap, 0.001e18, "refund is the cap");
        assertLt(refund, rent);
        proceeds;

        // One close never takes more than a twentieth of the pot, however much rent was paid.
        vm.prank(owner);
        rewards.setTerms(3_000, 2_000, 500, 500e6);
        vm.warp(rewards.weekEnds() + 7 days + 1);
        _setFeed("NVDA", price);
        BorroRewards thin = new BorroRewards(usdg, address(short), owner);
        vm.prank(owner);
        short.setRewards(IBorroRewards(address(thin)));
        deal(address(usdg), eve, 1e6);
        vm.startPrank(eve);
        usdg.approve(address(thin), 1e6);
        thin.fund(1e6); // 0.70 USDG in the rent pot
        vm.stopPrank();
        _open("NVDA", 2_000e6, 8e18);
        vm.warp(block.timestamp + 60 days);
        _setFeed("NVDA", price);
        balBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        assertEq(usdg.balanceOf(bob) - balBefore - paidOut, 0.035e6, "5% of a 0.70 USDG pot");

        // An empty pot refunds nothing, and the close still goes through.
        BorroRewards empty = new BorroRewards(usdg, address(short), owner);
        vm.prank(owner);
        short.setRewards(IBorroRewards(address(empty)));
        _open("NVDA", 2_000e6, 8e18);
        vm.warp(block.timestamp + 10 days);
        _setFeed("NVDA", price);
        balBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        assertEq(usdg.balanceOf(bob) - balBefore, paidOut, "nothing beyond the close itself");
    }

    function test_stock_borrowed_to_the_wallet_is_not_mistaken_for_rent() public onFork {
        _lend("NVDA", 80e18);
        bytes32 id = desk["NVDA"].marketId;
        _fund(10_000e6);
        // Bob opens a small short here, then borrows a lot more to his wallet.
        _open("NVDA", 2_000e6, 1e18);
        vm.startPrank(bob);
        short.addDeposit(id, 20_000e6);
        short.borrow(id, 30e18);
        vm.stopPrank();

        uint256 balBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 paidOut = short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        uint256 refund = usdg.balanceOf(bob) - balBefore - paidOut;
        assertLt(refund, 1e6, "the 30 borrowed to the wallet are not counted as rent");
    }

    /// The trick: open a short, repay it on Morpho straight away, wait for the price to fall, borrow again,
    /// and close, hoping to be paid rent and a prize score for time the short was never open.
    function test_repaying_behind_the_record_earns_nothing() public onFork {
        _lend("GME", 800e18);
        bytes32 id = desk["GME"].marketId;
        _fund(10_000e6);
        uint256 w = rewards.week();
        _open("GME", 2_000e6, 40e18);

        Position memory p = _pos("GME", bob);
        deal(desk["GME"].token, bob, 41e18);
        vm.startPrank(bob);
        IERC20(desk["GME"].token).approve(address(morpho), 41e18);
        morpho.repay(desk["GME"].market, 0, p.borrowShares, short.accountOf(bob), "");
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        _fall("GME", 10);

        uint256 potBefore = rewards.rentPot();
        vm.startPrank(bob);
        short.borrow(id, 41e18); // the only way to borrow again goes through the contract, which wipes the record
        (uint256 tracked,,,,) = short.tabOf(bob, id);
        assertEq(tracked, 0, "the record is gone");
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        vm.stopPrank();
        assertEq(rewards.rentPot(), potBefore, "no refund");
        (address who,,,) = rewards.best(w);
        assertEq(who, address(0), "no score");
    }

    function test_a_partial_repay_behind_the_record_shrinks_it() public onFork {
        _lend("NVDA", 50e18);
        bytes32 id = desk["NVDA"].marketId;
        _open("NVDA", 3_000e6, 8e18);
        Position memory p = _pos("NVDA", bob);
        deal(desk["NVDA"].token, eve, 5e18);
        vm.startPrank(eve);
        IERC20(desk["NVDA"].token).approve(address(morpho), 5e18);
        morpho.repay(desk["NVDA"].market, 0, p.borrowShares / 2, short.accountOf(bob), "");
        vm.stopPrank();
        _open("NVDA", 0, 1e18); // any open brings the record in line first
        (uint256 tracked, uint256 principal,,,) = short.tabOf(bob, id);
        assertEq(tracked, _pos("NVDA", bob).borrowShares);
        assertApproxEqAbs(principal, 4e18 + 1e18, 2, "half of the first short, plus the new one");
    }

    // ------------------------------------------------------------------ the weekly prize

    function test_best_short_of_the_week_leads_and_is_paid() public onFork {
        _lend("GME", 1_000e18);
        _fund(1_000e6);
        uint256 w = rewards.week();
        bytes32 id = desk["GME"].marketId;
        address carl = makeAddr("carl");
        deal(address(usdg), carl, 50_000e6);
        vm.prank(carl);
        usdg.approve(address(short), type(uint256).max);

        // Bob shorts GME, it falls 5%, Carl shorts it, it falls 5% more. Both close.
        _open("GME", 2_000e6, 40e18);
        _fall("GME", 5);
        uint256 q = _quote(id, 40e18, false);
        vm.prank(carl);
        short.open(id, 2_000e6, 40e18, (q * 99) / 100, DL);
        _fall("GME", 5);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(carl);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        (address who, uint32 bps,,) = rewards.best(w);
        assertEq(who, carl);
        assertGt(bps, 300, "about the 5% fall, less the cost of trading");
        assertLt(bps, 900);

        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        uint32 bobBps;
        (who, bobBps,,) = rewards.best(w);
        assertEq(who, bob, "the bigger fall takes the lead");
        assertGt(bobBps, bps + 300);
        assertLt(bobBps, 1800);
        emit log_named_uint("carl's score, hundredths of a percent", bps);
        emit log_named_uint("bob's score, hundredths of a percent", bobBps);

        // Not before the week is over.
        vm.expectRevert(BorroRewards.NotOver.selector);
        rewards.settle(w);
        vm.warp(rewards.weekEnds() + 1);
        uint256 before = usdg.balanceOf(bob);
        vm.prank(eve); // anyone can settle
        rewards.settle(w);
        assertEq(usdg.balanceOf(bob) - before, 300e6, "the week's pot goes to the winner");
        assertEq(rewards.prizeTotal(), 0);
        vm.expectRevert(BorroRewards.AlreadySettled.selector);
        rewards.settle(w);
    }

    function test_a_stale_feed_or_a_pushed_pool_alone_cannot_win() public onFork {
        _lend("GME", 1_000e18);
        _fund(1_000e6);
        uint256 w = rewards.week();
        bytes32 id = desk["GME"].marketId;
        uint256 price = _price("GME");

        // The feed says GME fell 20% but the market did not move (a feed left behind over a weekend).
        _open("GME", 2_000e6, 40e18);
        vm.warp(block.timestamp + 2 hours);
        _setFeed("GME", (price * 80) / 100);
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        (address who,,,) = rewards.best(w);
        assertEq(who, address(0), "the trade itself made nothing");

        // The pool is pushed down 10% but the feed did not move.
        _setFeed("GME", price);
        _open("GME", 2_000e6, 40e18);
        _fall("GME", 10);
        vm.warp(block.timestamp + 2 hours);
        _setFeed("GME", price);
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        (who,,,) = rewards.best(w);
        assertEq(who, address(0), "the feed price did not fall");
    }

    function test_a_short_held_under_an_hour_cannot_win_and_a_dead_feed_cannot_stop_a_close() public onFork {
        _lend("GME", 1_000e18);
        _fund(1_000e6);
        uint256 w = rewards.week();
        bytes32 id = desk["GME"].marketId;

        _open("GME", 2_000e6, 40e18);
        _fall("GME", 6);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        (address who,,,) = rewards.best(w);
        assertEq(who, address(0), "held for half an hour");

        // The feed breaks while a short is open. Rewards are skipped; the close goes through.
        _open("GME", 2_000e6, 40e18);
        vm.warp(block.timestamp + 2 hours);
        vm.mockCallRevert(stockOf["GME"].feed, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), "dead");
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        assertEq(_pos("GME", bob).borrowShares, 0, "closed all the same");
        (who,,,) = rewards.best(w);
        assertEq(who, address(0));
    }

    function test_small_or_losing_shorts_cannot_win_and_an_unwon_pot_rolls_over() public onFork {
        _lend("GME", 1_000e18);
        _fund(1_000e6);
        uint256 w = rewards.week();
        bytes32 id = desk["GME"].marketId;

        // A $240 short that catches a 6% fall: too small to win.
        _open("GME", 300e6, 10e18);
        _fall("GME", 6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        (address who,,,) = rewards.best(w);
        assertEq(who, address(0), "under the minimum size");

        // A big short closed after the price rose: no return, no lead.
        _open("GME", 2_000e6, 40e18);
        _setFeed("GME", (_price("GME") * 103) / 100);
        vm.prank(bob);
        short.close(id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL);
        (who,,,) = rewards.best(w);
        assertEq(who, address(0), "a losing short does not lead");

        vm.warp(rewards.weekEnds() + 1);
        rewards.settle(w);
        assertEq(rewards.prizePot(w), 0);
        assertEq(rewards.prizePot(rewards.week()), 300e6, "nobody won, so it rolls into this week");
        assertEq(rewards.prizeTotal(), 300e6);
    }

    function test_only_the_shorting_contract_reports_and_the_owner_cannot_take_the_pots() public onFork {
        _fund(1_000e6);
        vm.prank(eve);
        vm.expectRevert(BorroRewards.OnlyShort.selector);
        rewards.onClose(eve, bytes32(0), 1_000_000e6, 1_000e6, 365 days, 9_000);
        vm.prank(owner);
        vm.expectRevert(BorroRewards.OnlyShort.selector);
        rewards.onClose(owner, bytes32(0), 1_000_000e6, 1_000e6, 365 days, 9_000);

        vm.startPrank(owner);
        vm.expectRevert(BorroRewards.BadTerms.selector);
        rewards.setTerms(10_001, 500, 500, 500e6);
        vm.expectRevert(BorroRewards.BadTerms.selector);
        rewards.setTerms(3_000, 2_001, 500, 500e6); // past the hard cap on the refund rate
        vm.expectRevert(BorroRewards.BadTerms.selector);
        rewards.setTerms(3_000, 500, 1_001, 500e6); // past the hard cap on one close's share of the pot
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert();
        rewards.setTerms(0, 0, 0, 0);
        assertEq(usdg.balanceOf(address(rewards)), 1_000e6, "the money is still there");

        // USDG sent without `fund` is swept into the rent pot, not lost.
        deal(address(usdg), eve, 250e6);
        vm.prank(eve);
        usdg.transfer(address(rewards), 250e6);
        assertEq(rewards.absorb(), 250e6);
        assertEq(rewards.rentPot(), 950e6);
        assertEq(rewards.absorb(), 0);
    }

    // ------------------------------------------------------------------ baskets

    /// One open() per leg, each sized from a fresh quote with half a percent of slip.
    function _basket(address who, string[3] memory syms, uint256[3] memory amounts, uint256 deposit)
        internal
        returns (bytes[] memory calls)
    {
        calls = new bytes[](3);
        for (uint256 i; i < 3; i++) {
            _lend(syms[i], amounts[i] * 4);
            bytes32 id = desk[syms[i]].marketId;
            uint256 quote = _quote(id, amounts[i], false);
            uint256 net = quote - (quote * OPEN_FEE_BPS) / 10_000;
            calls[i] = abi.encodeCall(BorroShort.open, (id, deposit, amounts[i], (net * 995) / 1000, DL));
        }
        deal(address(usdg), who, 3 * deposit);
    }

    function test_basket_opens_and_closes_in_one_call() public onFork {
        address carl = makeAddr("carl");
        string[3] memory syms = ["NVDA", "TSLA", "GME"];
        uint256[3] memory amounts = [uint256(5e18), 3e18, 40e18];
        bytes[] memory calls = _basket(carl, syms, amounts, 1_000e6);

        vm.startPrank(carl);
        usdg.approve(address(short), 3_000e6); // one approval for the whole basket
        bytes[] memory results = short.multicall(calls);
        vm.stopPrank();
        assertEq(usdg.balanceOf(carl), 0, "three deposits paid");
        assertEq(usdg.allowance(carl, address(short)), 0, "the one approval covered exactly the basket");
        for (uint256 i; i < 3; i++) {
            bytes32 id = desk[syms[i]].marketId;
            uint256 proceeds = abi.decode(results[i], (uint256));
            assertApproxEqRel(proceeds, _worth(syms[i], amounts[i]), 0.03e18, string.concat(syms[i], " sold near the feed"));
            assertGt(morpho.position(Id.wrap(id), short.accountOf(carl)).borrowShares, 0);
            (uint256 tracked,,,,) = short.tabOf(carl, id);
            assertGt(tracked, 0, "each leg is on the record, for rent and the prize");
            calls[i] = abi.encodeCall(BorroShort.close, (id, type(uint256).max, type(uint256).max, 0, type(uint256).max, DL));
        }

        vm.prank(carl);
        results = short.multicall(calls);
        uint256 paidOut;
        for (uint256 i; i < 3; i++) {
            Position memory p = morpho.position(Id.wrap(desk[syms[i]].marketId), short.accountOf(carl));
            assertEq(p.borrowShares, 0, "every leg closed");
            assertEq(p.collateral, 0);
            paidOut += abi.decode(results[i], (uint256));
        }
        assertEq(usdg.balanceOf(carl), paidOut);
        assertApproxEqRel(paidOut, 3_000e6, 0.03e18, "a round trip costs fees only");
        emit log_named_decimal_uint("basket round trip cost USD", 3_000e6 - paidOut, 6);
        assertEq(usdg.balanceOf(address(short)), 0, "nothing stays in the contract");
        assertEq(held.balanceOf(address(short)), 0);
    }

    function test_one_failing_leg_fails_the_whole_basket() public onFork {
        address carl = makeAddr("carl");
        string[3] memory syms = ["NVDA", "TSLA", "GME"];
        uint256[3] memory amounts = [uint256(5e18), 3e18, 40e18];
        bytes[] memory calls = _basket(carl, syms, amounts, 1_000e6);
        // The last leg asks for twice what the sale can bring.
        bytes32 id = desk["GME"].marketId;
        uint256 quote = _quote(id, amounts[2], false);
        uint256 net = quote - (quote * OPEN_FEE_BPS) / 10_000;
        calls[2] = abi.encodeCall(BorroShort.open, (id, 1_000e6, amounts[2], quote * 2, DL));

        vm.startPrank(carl);
        usdg.approve(address(short), 3_000e6);
        vm.expectRevert(abi.encodeWithSelector(BorroShort.TooLittle.selector, net, quote * 2));
        short.multicall(calls);
        vm.stopPrank();
        assertEq(usdg.balanceOf(carl), 3_000e6, "nothing moved");
        assertEq(short.accountOf(carl).code.length, 0, "not even the account was made");
        assertEq(morpho.position(Id.wrap(desk["NVDA"].marketId), short.accountOf(carl)).borrowShares, 0);

        // A basket runs as its sender, so it cannot reach what the sender alone could not.
        bytes[] memory sneaky = new bytes[](1);
        sneaky[0] = abi.encodeCall(BorroShort.onMorphoSupplyCollateral, (0, abi.encode(short.accountOf(bob), id, 1e18, 0, 0)));
        vm.prank(eve);
        vm.expectRevert(BorroShort.OnlyMorpho.selector);
        short.multicall(sneaky);
    }

    function test_unlisted_market_cannot_be_shorted() public onFork {
        vm.prank(bob);
        vm.expectRevert(BorroShort.NotListed.selector);
        short.open(bytes32(uint256(1)), 1_000e6, 1e18, 0, DL);
    }
}
