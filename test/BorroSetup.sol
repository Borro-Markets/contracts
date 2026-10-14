// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMorpho, MarketParams, Id, Market, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {BorroLib} from "../script/BorroLib.sol";
import {StockList} from "../script/StockList.sol";
import {BorroShort, IUniswapV3Factory, IHeldVault, IBorroRewards} from "../src/BorroShort.sol";
import {BorroRewards} from "../src/BorroRewards.sol";
import {BorroRouter} from "../src/BorroRouter.sol";
import {BorroLiquidator, IBorroDesks, IBorroMarkets} from "../src/BorroLiquidator.sol";
import {BorroSwap} from "../src/BorroSwap.sol";

/// The whole system on a fork of Robinhood Chain, set up the way the deploy script does it: every stock's desk
/// (lend the stock, short it), its USDG market (post the stock vault's shares, borrow USDG), the Borro USDG
/// vault, the shorting contract, the router and the liquidator. Morpho, the pools, the feeds and the tokens are
/// the real ones. Only the people are made up.
abstract contract BorroSetup is Test, StockList {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    uint256 constant OPEN_FEE_BPS = 10;
    uint256 constant FEE = 0.1e18;
    uint256 constant DL = type(uint256).max;
    IMorpho constant morpho = IMorpho(BorroLib.MORPHO);
    IERC20 constant usdg = IERC20(BorroLib.USDG);
    IVaultV2 constant held = IVaultV2(BorroLib.HELD); // the USDG lending vault whose shares are the collateral of shorts

    address owner = makeAddr("owner");
    address sink = makeAddr("sink");
    address keeper = makeAddr("keeper");
    address ann = makeAddr("ann"); // lends stock, borrows USDG against it
    address bob = makeAddr("bob"); // shorts
    address carl = makeAddr("carl"); // lends USDG
    address eve = makeAddr("eve"); // liquidates, or tries what she should not

    BorroShort short;
    BorroRewards rewards;
    BorroRouter router;
    BorroLiquidator liquidator;
    BorroLib.Lender lender;
    IVaultV2 bUsdg;
    BorroLib.Stock[] stocks;
    mapping(string => BorroLib.Desk) desk;
    mapping(string => BorroLib.Loan) loan;
    mapping(string => BorroLib.Stock) stockOf;
    bool forked;

    function setUp() public virtual {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        short = new BorroShort(
            morpho, IPoolManager(POOL_MANAGER), IUniswapV3Factory(V3_FACTORY), usdg, IHeldVault(BorroLib.HELD), BorroLib.IRM, owner
        );
        rewards = new BorroRewards(usdg, address(short), owner);
        vm.startPrank(owner);
        short.setRewards(IBorroRewards(address(rewards)));
        short.setFee(OPEN_FEE_BPS, sink);
        vm.stopPrank();

        BorroLib.Stock[] memory list = loadStocks();
        BorroLib.Terms memory t = BorroLib.Terms({owner: owner, feeRecipient: sink, performanceFee: FEE, salt: bytes32("test")});
        BorroLib.Loan[] memory loans = new BorroLib.Loan[](list.length);
        deal(address(usdg), owner, BorroLib.USDG_SEED + list.length * BorroLib.USDG_MARKET_SEED);
        for (uint256 i; i < list.length; i++) {
            deal(list[i].token, owner, list[i].seed);
            vm.startPrank(owner);
            BorroLib.Desk memory d = BorroLib.open(list[i], t);
            loans[i] = BorroLib.openUsdg(list[i], d, t.salt);
            if (loadRoute(i).length != 0 || loadV3Pool(i) != address(0)) short.list(d.market, loadRoute(i), loadV3Pool(i));
            vm.stopPrank();
            stocks.push(list[i]);
            desk[list[i].symbol] = d;
            loan[list[i].symbol] = loans[i];
            stockOf[list[i].symbol] = list[i];
        }
        vm.startPrank(owner);
        lender = BorroLib.openLender(list, loans, t, keeper);
        vm.stopPrank();
        bUsdg = IVaultV2(lender.vault);

        // The router lists Borro's USDG markets, and the liquidator takes its list.
        MarketParams[] memory usdgMarkets = new MarketParams[](loans.length);
        for (uint256 i; i < loans.length; i++) usdgMarkets[i] = loans[i].market;
        router = new BorroRouter(morpho, address(usdg), owner, usdgMarkets);
        liquidator = new BorroLiquidator(
            morpho, IPoolManager(POOL_MANAGER), usdg, IBorroDesks(address(short)), BorroLib.HELD, IBorroMarkets(address(router))
        );
    }

    modifier onFork() {
        if (!forked) return;
        _;
    }

    // ------------------------------------------------------------------ helpers

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
        assembly { sel := mload(add(err, 32)) }
        require(sel == BorroSwap.QuoteResult.selector, "unexpected revert");
        assembly { out := mload(add(err, 36)) }
    }

    /// Lends `amount` of the stock straight to its vault, as a plain lender who posts nothing.
    function _lend(string memory sym, address who, uint256 amount) internal {
        BorroLib.Desk memory d = desk[sym];
        deal(d.token, who, amount);
        vm.startPrank(who);
        IERC20(d.token).approve(d.vault, amount);
        IVaultV2(d.vault).deposit(amount, who);
        vm.stopPrank();
    }

    /// Lends `amount` of the stock and posts the shares on its USDG market, through the router.
    function _lendAndPost(string memory sym, address who, uint256 amount) internal returns (uint256 shares) {
        BorroLib.Desk memory d = desk[sym];
        deal(d.token, who, amount);
        vm.startPrank(who);
        IERC20(d.token).approve(address(router), amount);
        shares = router.lendAndPost(loan[sym].market, d.token, amount, 0);
        vm.stopPrank();
    }

    /// Deposits USDG into the Borro USDG vault.
    function _lendUsdg(address who, uint256 amount) internal returns (uint256 shares) {
        deal(address(usdg), who, amount);
        vm.startPrank(who);
        usdg.approve(address(bUsdg), amount);
        shares = bUsdg.deposit(amount, who);
        vm.stopPrank();
    }

    /// The keeper moves `amount` of the USDG vault's money from the SPY market into `sym`'s USDG market.
    function _allocate(string memory sym, uint256 amount) internal {
        vm.startPrank(keeper);
        bUsdg.deallocate(lender.adapter, bUsdg.liquidityData(), amount);
        bUsdg.allocate(lender.adapter, abi.encode(loan[sym].market), amount);
        vm.stopPrank();
    }

    /// USDG owed on `sym`'s USDG market right now, interest included.
    function _owedUsdg(string memory sym, address who) internal returns (uint256) {
        MarketParams memory m = loan[sym].market;
        morpho.accrueInterest(m);
        Position memory p = morpho.position(Id.wrap(loan[sym].marketId), who);
        Market memory mk = morpho.market(Id.wrap(loan[sym].marketId));
        return (uint256(p.borrowShares) * (uint256(mk.totalBorrowAssets) + 1)) / (uint256(mk.totalBorrowShares) + 1e6) + 1;
    }
}
