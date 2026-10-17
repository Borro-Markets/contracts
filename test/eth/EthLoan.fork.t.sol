// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams, Id, Position, Authorization, Signature} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {AUTHORIZATION_TYPEHASH, DOMAIN_TYPEHASH} from "morpho-blue/libraries/ConstantsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {StockEthOracle, IShareVault, IChainlinkFeed, IEthUsd} from "../../src/eth/StockEthOracle.sol";
import {EthLoanLiquidator, IEthLoanDesks} from "../../src/eth/EthLoanLiquidator.sol";
import {EthLoanRouter, IEthLoanWeth} from "../../src/eth/EthLoanRouter.sol";

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external;
}

interface IVault4626 {
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// A desk registry that sends one stock's sales to a pool of the test's choosing.
contract RouteDesks is IEthLoanDesks {
    address public immutable stock;
    address public immutable pool;

    constructor(address s, address p) {
        stock = s;
        pool = p;
    }

    function deskOf(bytes32)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed)
    {
        market.loanToken = stock;
        route = new PoolKey[](0);
        v3Pool = pool;
        paused = false;
        feed = address(0);
    }
}

/// A "pool" on the liquidator's route that runs its owner's code during the sale, the way a v4 hook or a hostile pool
/// could: it tries to borrow on the very market being liquidated, reads the oracle, tries to arm it, tries to re-enter
/// the liquidator, records what it saw, and then trades honestly (stock in, USDG out at a fixed price).
contract HostilePool {
    address public immutable token0; // the stock
    address public immutable token1; // USDG
    IMorpho public immutable morpho;
    StockEthOracle public oracle;
    EthLoanLiquidator public liq;
    MarketParams public market;
    uint256 public usdgPerStock; // USDG wei per whole stock
    uint256 public borrowTry; // WETH it tries to borrow in its own name

    bool public swapped;
    bool public sawArmed;
    bool public priceReverted;
    uint256 public priceSeen;
    bool public borrowOk;
    bytes public borrowError;
    bool public armRefused;
    bool public reentryRefused;

    constructor(address stock_, address usdg_, IMorpho m) {
        token0 = stock_;
        token1 = usdg_;
        morpho = m;
    }

    function setUp(StockEthOracle o, EthLoanLiquidator l, MarketParams calldata mp, uint256 px, uint256 tryBorrow) external {
        oracle = o;
        liq = l;
        market = mp;
        usdgPerStock = px;
        borrowTry = tryBorrow;
    }

    /// Posts vault shares as its own collateral on the market, so it has something to borrow against.
    function post(uint256 shares) external {
        IERC20(market.collateralToken).approve(address(morpho), shares);
        morpho.supplyCollateral(market, shares, address(this), "");
    }

    function fee() external pure returns (uint24) {
        return 3000;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 a0, int256 a1)
    {
        require(zeroForOne && amountSpecified > 0, "only sells of the stock");
        swapped = true;
        sawArmed = oracle.armed();
        try oracle.price() returns (uint256 p) {
            priceSeen = p;
        } catch {
            priceReverted = true;
        }
        MarketParams memory mp = market;
        try morpho.borrow(mp, borrowTry, 0, address(this), address(this)) {
            borrowOk = true;
        } catch (bytes memory e) {
            borrowError = e;
        }
        try oracle.arm() {} catch {
            armRefused = true;
        }
        try liq.liquidate(mp, address(this), 1, 0, bytes32(0), 0) {} catch {
            reentryRefused = true;
        }
        uint256 amountIn = uint256(amountSpecified);
        uint256 out = amountIn * usdgPerStock / 1e18;
        uint256 before = IERC20(token0).balanceOf(address(this));
        IERC20(token1).transfer(recipient, out);
        ISwapCallback(msg.sender).uniswapV3SwapCallback(int256(amountIn), -int256(out), data);
        require(IERC20(token0).balanceOf(address(this)) >= before + amountIn, "not paid");
        return (int256(amountIn), -int256(out));
    }
}

/// A user that is a contract, so a test can measure what each call costs inside one transaction.
contract GasUser {
    receive() external payable {}

    function prepare(IMorpho morpho, address router, address stock, uint256 amount) external {
        IERC20(stock).approve(router, amount);
        morpho.setAuthorization(router, true);
    }

    function measure(address target, uint256 value, bytes calldata data) external returns (uint256 used) {
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        used = g - gasleft();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// EthLoanLiquidator and EthLoanRouter on a copy of Robinhood Chain: the real Morpho, the real Borro NVDA vault and
/// BorroShort's NVDA route, the real WETH/USDG pool, the real Chainlink feeds. Set BORRO_FORK_RPC to run. Pinned to
/// block 82,091,631 (Tuesday 2026-10-06 21:34 New York, the market open).
contract EthLoanForkTest is Test {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    uint256 constant FORK_BLOCK = 82_091_631;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant IRM = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant SHORT = 0xd2D686cEdf225c5C9815187A08812783904E62Eb; // BorroShort: the desks and their routes
    IChainlinkFeed constant ETH_FEED = IChainlinkFeed(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IEthUsd constant ETH_PRICE = IEthUsd(0x1d1B3096406279A93C955ED0d65fA2597B08CDef);
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant BNVDA = 0x508E23274C39C60c345e35B1f0188bE180717CB9;
    bytes32 constant NVDA_DESK = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;
    uint256 constant LLTV = 0.385e18;
    uint256 constant SAT_NOON = 1791648000; // Saturday 2026-10-10 12:00 New York

    EthLoanLiquidator liq;
    StockEthOracle oracle;
    EthLoanRouter router;
    MarketParams mp;
    Id id;
    // A fresh key: well-known test keys such as 0xA11CE carry EIP-7702 delegations on this chain that sweep ETH.
    uint256 alicePk = uint256(keccak256("borro borrow-eth test alice"));
    address alice;
    address keeper = makeAddr("keeper");
    bool forked;
    uint256 eth8; // Chainlink's ETH price at the fork
    uint256 nvda8; // Chainlink's NVDA price at the fork

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;
        alice = vm.addr(alicePk);
        require(alice.code.length == 0, "alice must be a plain account");
        liq = new EthLoanLiquidator(MORPHO, IPoolManager(POOL_MANAGER), IERC20(USDG), IERC20(WETH), ETH_POOL, IEthLoanDesks(SHORT), IRM);
        oracle = new StockEthOracle(NVDA, IShareVault(BNVDA), IChainlinkFeed(NVDA_FEED), ETH_FEED, ETH_PRICE, address(liq));
        mp = MarketParams({loanToken: WETH, collateralToken: BNVDA, oracle: address(oracle), irm: IRM, lltv: LLTV});
        MORPHO.createMarket(mp);
        id = mp.id();
        router = new EthLoanRouter(MORPHO, IEthLoanWeth(WETH), IRM, address(liq), address(this));
        router.list(mp);
        // An ETH lender.
        address lender = makeAddr("lender");
        deal(WETH, lender, 30 ether);
        vm.prank(lender);
        IERC20(WETH).approve(address(MORPHO), 30 ether);
        vm.prank(lender);
        MORPHO.supply(mp, 30 ether, 0, lender, "");
        (, int256 e,,,) = ETH_FEED.latestRoundData();
        (, int256 s,,,) = IChainlinkFeed(NVDA_FEED).latestRoundData();
        eth8 = uint256(e);
        nvda8 = uint256(s);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _post(address feed, uint256 usd8) internal {
        uint256 t = vm.getBlockTimestamp();
        vm.mockCall(feed, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), abi.encode(uint80(1), int256(usd8), t, t, uint80(1)));
    }

    function _toSaturday() internal {
        vm.warp(SAT_NOON);
        vm.roll(vm.getBlockNumber() + 1);
        _post(address(ETH_FEED), eth8); // ETH trades all weekend; NVDA's feed keeps Tuesday's price
    }

    /// Alice posts 50 NVDA through the router and borrows `bps` of the most a borrow may reach (75% of the LLTV).
    function _aliceOpens(uint256 bps) internal returns (uint256 borrowed) {
        deal(NVDA, alice, 50e18);
        vm.prank(alice);
        IERC20(NVDA).approve(address(router), 50e18);
        vm.prank(alice);
        MORPHO.setAuthorization(address(router), true);
        uint256 worth = IVault4626(BNVDA).convertToAssets(50e18) * oracle.borrowPrice() / 1e36; // shares 1:1 at the fork
        borrowed = worth * LLTV / 1e18 * 7_500 / 10_000 * bps / 10_000;
        vm.prank(alice);
        router.open(EthLoanRouter.Open({market: mp, stockIn: 50e18, sharesIn: 0, minShares: 0, borrow: borrowed, deadline: vm.getBlockTimestamp() + 600}));
    }

    function _debt(address who) internal view returns (uint256) {
        return MORPHO.expectedBorrowAssets(mp, who);
    }

    function _empty(address a) internal view {
        assertEq(IERC20(WETH).balanceOf(a), 0, "no WETH left");
        assertEq(IERC20(USDG).balanceOf(a), 0, "no USDG left");
        assertEq(IERC20(NVDA).balanceOf(a), 0, "no NVDA left");
        assertEq(IERC20(BNVDA).balanceOf(a), 0, "no bNVDA left");
        assertEq(a.balance, 0, "no ETH left");
    }

    /// The armed window, read from every account access the transaction made: between the oracle's arm() and its
    /// disarm(), nothing may run that can change state except Morpho, its IRM, WETH (and its implementation) and the
    /// collateral vault. Calls into anything else may only be static (the oracle's own reads). Returns how many times
    /// the oracle was armed, and how many calls ran after the last disarm (the sale and the buy back).
    function _checkWindow(VmSafe.AccountAccess[] memory acc, address o, address vault, address l)
        internal
        view
        returns (uint256 arms, uint256 afterDisarm)
    {
        address wethImpl = address(uint160(uint256(vm.load(WETH, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
        bool armed;
        // Everything deeper than an open static call ran inside it (a proxy's delegatecall under the oracle's reads,
        // say) and could change nothing.
        uint256 staticDepth = type(uint256).max;
        for (uint256 i; i < acc.length; i++) {
            VmSafe.AccountAccess memory a = acc[i];
            if (a.kind == VmSafe.AccountAccessKind.Resume) continue;
            if (a.depth > staticDepth) continue;
            staticDepth = type(uint256).max;
            if (a.kind == VmSafe.AccountAccessKind.StaticCall) {
                staticDepth = a.depth;
                continue;
            }
            bytes4 sel = a.data.length >= 4 ? bytes4(a.data) : bytes4(0);
            // Arming that counts is the liquidator's own (the hostile pool's attempt is refused by the oracle).
            // The recorder's `reverted` flag is not used: it also marks calls whose sibling reverted and was caught.
            bool byLiq = a.account == o && a.kind == VmSafe.AccountAccessKind.Call && a.accessor == l;
            if (byLiq && sel == StockEthOracle.arm.selector) {
                armed = true;
                arms++;
                continue;
            }
            if (byLiq && sel == StockEthOracle.disarm.selector) {
                armed = false;
                afterDisarm = 0;
                continue;
            }
            bool stateful = a.kind == VmSafe.AccountAccessKind.Call || a.kind == VmSafe.AccountAccessKind.DelegateCall
                || a.kind == VmSafe.AccountAccessKind.CallCode || a.kind == VmSafe.AccountAccessKind.Create
                || a.kind == VmSafe.AccountAccessKind.SelfDestruct;
            if (!armed) {
                if (a.kind == VmSafe.AccountAccessKind.Call) afterDisarm++;
                continue;
            }
            if (!stateful) continue; // static calls and reads cannot change anything
            bool ok = a.account == address(MORPHO) || a.account == IRM || a.account == WETH || a.account == vault;
            // WETH on this chain is a proxy: its transferFrom runs its implementation by delegatecall.
            if (!ok && a.kind == VmSafe.AccountAccessKind.DelegateCall) ok = a.account == wethImpl;
            require(
                ok,
                string.concat(
                    "ran while armed: ", vm.toString(a.account), " kind ", vm.toString(uint256(a.kind)), " from ", vm.toString(a.accessor)
                )
            );
        }
        require(!armed, "left armed");
    }

    // ------------------------------------------------------------------ the router

    function test_router_openRepayWithdraw() public onFork {
        uint256 borrowed = _aliceOpens(9_900);
        assertEq(alice.balance, borrowed, "the loan arrived as ETH");
        assertEq(MORPHO.position(id, alice).collateral, 50e18);
        assertApproxEqAbs(_debt(alice), borrowed, 1);
        _empty(address(router));

        // A little more than the open limit allows: refused.
        vm.prank(alice);
        vm.expectPartialRevert(EthLoanRouter.OverLimit.selector);
        router.open(EthLoanRouter.Open({market: mp, stockIn: 0, sharesIn: 0, minShares: 0, borrow: borrowed / 50, deadline: vm.getBlockTimestamp() + 600}));

        // Repay part with ETH.
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        router.repay{value: 0.1 ether}(mp);
        assertApproxEqAbs(_debt(alice), borrowed - 0.1 ether, 2);
        // Repay too much: everything is repaid and the rest comes back.
        uint256 debt = _debt(alice);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        router.repay{value: debt + 0.05 ether}(mp);
        assertEq(MORPHO.position(id, alice).borrowShares, 0);
        assertEq(alice.balance, balBefore - debt, "only the debt was kept");
        _empty(address(router));

        // Take half back as shares and half as the stock.
        vm.prank(alice);
        router.withdraw(mp, 25e18, false);
        assertEq(IERC20(BNVDA).balanceOf(alice), 25e18);
        vm.prank(alice);
        router.withdraw(mp, 25e18, true);
        assertApproxEqAbs(IERC20(NVDA).balanceOf(alice), 25e18, 1);
        assertEq(MORPHO.position(id, alice).collateral, 0);
        _empty(address(router));
    }

    function test_router_openWithSigAndClose() public onFork {
        deal(NVDA, alice, 10e18);
        vm.prank(alice);
        IERC20(NVDA).approve(address(router), 10e18);
        Authorization memory auth = Authorization({
            authorizer: alice, authorized: address(router), isAuthorized: true, nonce: MORPHO.nonce(alice), deadline: vm.getBlockTimestamp() + 600
        });
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(MORPHO)));
        bytes32 h = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, auth));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, keccak256(bytes.concat("\x19\x01", domain, h)));
        vm.prank(alice);
        router.openWithSig(
            EthLoanRouter.Open({market: mp, stockIn: 10e18, sharesIn: 0, minShares: 9e18, borrow: 0.1 ether, deadline: vm.getBlockTimestamp() + 600}),
            auth,
            Signature({v: v, r: r, s: s})
        );
        assertEq(alice.balance, 0.1 ether);
        // Close: repay all with ETH, take the stock back.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.close{value: 0.2 ether}(mp, true);
        assertEq(MORPHO.position(id, alice).borrowShares, 0);
        assertEq(MORPHO.position(id, alice).collateral, 0);
        assertApproxEqAbs(IERC20(NVDA).balanceOf(alice), 10e18, 1);
        assertApproxEqAbs(alice.balance, 1 ether - 0.1 ether, 0.0001 ether);
        _empty(address(router));
    }

    function test_router_onlyEverForTheCaller() public onFork {
        _aliceOpens(5_000);
        // Alice authorized the router; Bob calling it can only ever touch Bob's position.
        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert(EthLoanRouter.NotAuthorized.selector);
        router.withdraw(mp, 1e18, false);
        vm.prank(bob);
        MORPHO.setAuthorization(address(router), true);
        vm.prank(bob);
        vm.expectRevert(); // Bob has nothing posted; Alice's is not his to take
        router.withdraw(mp, 1e18, false);
        assertEq(MORPHO.position(id, alice).collateral, 50e18);
        // Pausing stops opens only.
        router.setOpensPaused(true);
        deal(NVDA, alice, 1e18);
        vm.prank(alice);
        IERC20(NVDA).approve(address(router), 1e18);
        vm.prank(alice);
        vm.expectRevert(EthLoanRouter.Paused.selector);
        router.open(EthLoanRouter.Open({market: mp, stockIn: 1e18, sharesIn: 0, minShares: 0, borrow: 0, deadline: vm.getBlockTimestamp() + 600}));
        vm.deal(alice, 0.01 ether);
        vm.prank(alice);
        router.repay{value: 0.01 ether}(mp);
        // Only the owner lists, and only a market whose oracle names Borro's liquidator.
        vm.prank(bob);
        vm.expectRevert();
        router.list(mp);
        StockEthOracle foreign = new StockEthOracle(NVDA, IShareVault(BNVDA), IChainlinkFeed(NVDA_FEED), ETH_FEED, ETH_PRICE, bob);
        MarketParams memory other = MarketParams({loanToken: WETH, collateralToken: BNVDA, oracle: address(foreign), irm: IRM, lltv: LLTV});
        MORPHO.createMarket(other);
        vm.expectRevert(EthLoanRouter.BadMarket.selector);
        router.list(other);
    }

    function test_router_weekend() public onFork {
        uint256 borrowed = _aliceOpens(5_000);
        _toSaturday();
        (, uint256 at) = _nvdaAt();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, at));
        router.open(EthLoanRouter.Open({market: mp, stockIn: 0, sharesIn: 0, minShares: 0, borrow: 0.01 ether, deadline: vm.getBlockTimestamp() + 600}));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, at));
        router.withdraw(mp, 1e18, false);
        // Posting more stock needs no price: it works on a Saturday.
        deal(NVDA, alice, 2e18);
        vm.prank(alice);
        IERC20(NVDA).approve(address(router), 2e18);
        vm.prank(alice);
        router.open(EthLoanRouter.Open({market: mp, stockIn: 2e18, sharesIn: 0, minShares: 0, borrow: 0, deadline: vm.getBlockTimestamp() + 600}));
        assertEq(MORPHO.position(id, alice).collateral, 52e18);
        // Repaying everything works on a Saturday, and then so does taking it all back.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.close{value: borrowed + 0.01 ether}(mp, false);
        assertEq(IERC20(BNVDA).balanceOf(alice), 52e18);
        _empty(address(router));
    }

    function _nvdaAt() internal view returns (uint256 a, uint256 t) {
        (, int256 x,, uint256 u,) = IChainlinkFeed(NVDA_FEED).latestRoundData();
        return (uint256(x), u);
    }

    // ------------------------------------------------------------------ the liquidator, on the real route

    /// NVDA's feed drops 40% on a weekday: anyone can liquidate, through the liquidator with no money of their own.
    /// The sale runs through BorroShort's real NVDA route and WETH is bought back on the real pool, all after the
    /// oracle is disarmed.
    function test_liquidate_weekday_realRoute() public onFork {
        _aliceOpens(9_900);
        _post(NVDA_FEED, nvda8 * 60 / 100);
        Position memory p = MORPHO.position(id, alice);
        vm.startStateDiffRecording();
        vm.prank(keeper);
        uint256 profit = liq.liquidate(mp, alice, 0, p.borrowShares, NVDA_DESK, 0);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        (uint256 arms, uint256 after_) = _checkWindow(acc, address(oracle), BNVDA, address(liq));
        assertEq(arms, 1);
        assertGt(after_, 5, "the redeem, the sale and the buy back all ran after the disarm");
        assertFalse(oracle.armed());
        assertEq(MORPHO.position(id, alice).borrowShares, 0, "the whole debt was repaid");
        assertGt(MORPHO.position(id, alice).collateral, 0, "the rest of the collateral stays Alice's");
        assertEq(IERC20(USDG).balanceOf(keeper), profit);
        console2.log("weekday liquidation of the whole debt: USDG profit", profit);
        _empty(address(liq));
    }

    /// Saturday, ETH +60% against Tuesday's NVDA: past the limit even with NVDA counted 5% above its close. Morpho directly cannot, the
    /// liquidator can, and the window holds nothing but Morpho.
    function test_liquidate_weekend() public onFork {
        _aliceOpens(9_900);
        _toSaturday();
        _post(address(ETH_FEED), eth8 * 160 / 100);
        Position memory p = MORPHO.position(id, alice);
        (, uint256 at) = _nvdaAt();
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, at));
        MORPHO.liquidate(mp, alice, 0, p.borrowShares / 2, "");
        vm.startStateDiffRecording();
        vm.prank(keeper);
        uint256 profit = liq.liquidate(mp, alice, 0, p.borrowShares / 2, NVDA_DESK, 0);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        (uint256 arms,) = _checkWindow(acc, address(oracle), BNVDA, address(liq));
        assertEq(arms, 1);
        assertGt(profit, 0);
        console2.log("weekend liquidation (half the debt): USDG profit", profit);
        _empty(address(liq));
    }

    /// The vault has lent out its stock (its redeem fails): the capital-free path says so; the keeper pays the WETH
    /// itself and takes the shares. Weekend included.
    function test_liquidateForShares() public onFork {
        _aliceOpens(9_900);
        _toSaturday();
        _post(address(ETH_FEED), eth8 * 160 / 100);
        vm.mockCallRevert(BNVDA, abi.encodeWithSelector(IVault4626.redeem.selector), "lent out");
        Position memory p = MORPHO.position(id, alice);
        vm.prank(keeper);
        vm.expectPartialRevert(EthLoanLiquidator.CannotRedeem.selector);
        liq.liquidate(mp, alice, 0, p.borrowShares / 2, NVDA_DESK, 0);
        uint256 owed = liq.repaidFor(mp, 0, p.borrowShares / 2);
        deal(WETH, keeper, owed);
        vm.prank(keeper);
        IERC20(WETH).approve(address(liq), owed);
        vm.startStateDiffRecording();
        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = liq.liquidateForShares(mp, alice, 0, p.borrowShares / 2, owed);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        (uint256 arms,) = _checkWindow(acc, address(oracle), BNVDA, address(liq));
        assertEq(arms, 1);
        assertEq(repaid, owed, "repaidFor is exact");
        assertEq(IERC20(BNVDA).balanceOf(keeper), seized);
        assertEq(IERC20(WETH).balanceOf(keeper), 0);
        _empty(address(liq));
    }

    function test_liquidator_refusals() public onFork {
        _aliceOpens(9_900);
        _post(NVDA_FEED, nvda8 * 60 / 100);
        // An oracle that does not name this liquidator.
        StockEthOracle foreign = new StockEthOracle(NVDA, IShareVault(BNVDA), IChainlinkFeed(NVDA_FEED), ETH_FEED, ETH_PRICE, keeper);
        MarketParams memory other = MarketParams({loanToken: WETH, collateralToken: BNVDA, oracle: address(foreign), irm: IRM, lltv: LLTV});
        vm.expectRevert(EthLoanLiquidator.BadMarket.selector);
        liq.liquidate(other, alice, 0, 1, NVDA_DESK, 0);
        // A route for another stock.
        bytes32 spyDesk = 0x1cd22321a4d27054a8cd029c73c53432e8a231f8df1a3981b1ae1c274175d381;
        vm.expectRevert(EthLoanLiquidator.NoRoute.selector);
        liq.liquidate(mp, alice, 0, 1, spyDesk, 0);
        // Both or neither of seized and repaid.
        vm.expectRevert(EthLoanLiquidator.Nothing.selector);
        liq.liquidate(mp, alice, 1, 1, NVDA_DESK, 0);
        // The callback only from Morpho, and only inside the liquidator's own flash loan.
        vm.expectRevert(EthLoanLiquidator.OnlyMorpho.selector);
        liq.onMorphoFlashLoan(1, "");
        vm.prank(address(MORPHO));
        vm.expectRevert(EthLoanLiquidator.NotInFlight.selector);
        liq.onMorphoFlashLoan(1, "");
        // A profit floor it cannot reach reverts.
        Position memory p = MORPHO.position(id, alice);
        vm.expectPartialRevert(EthLoanLiquidator.TooLittle.selector);
        liq.liquidate(mp, alice, 0, p.borrowShares, NVDA_DESK, type(uint128).max);
        // Nobody else can arm the oracle.
        vm.expectRevert(StockEthOracle.NotLiquidator.selector);
        oracle.arm();
    }

    /// The other choice for the owner: oracles that name no liquidator. Nothing is ever armed: the liquidator still works
    /// on weekdays at the strict price, and nothing can liquidate at a weekend.
    function test_noWeekendLiquidations() public onFork {
        StockEthOracle plain = new StockEthOracle(NVDA, IShareVault(BNVDA), IChainlinkFeed(NVDA_FEED), ETH_FEED, ETH_PRICE, address(0));
        MarketParams memory m = MarketParams({loanToken: WETH, collateralToken: BNVDA, oracle: address(plain), irm: IRM, lltv: LLTV});
        MORPHO.createMarket(m);
        address lender = makeAddr("lender3");
        deal(WETH, lender, 30 ether);
        vm.startPrank(lender);
        IERC20(WETH).approve(address(MORPHO), 30 ether);
        MORPHO.supply(m, 30 ether, 0, lender, "");
        vm.stopPrank();
        deal(NVDA, alice, 50e18);
        vm.startPrank(alice);
        IERC20(NVDA).approve(BNVDA, 50e18);
        uint256 shares = IVault4626(BNVDA).deposit(50e18, alice);
        IERC20(BNVDA).approve(address(MORPHO), shares);
        MORPHO.supplyCollateral(m, shares, alice, "");
        MORPHO.borrow(m, shares * plain.borrowPrice() / 1e36 * LLTV / 1e18 * 99 / 100, 0, alice, alice);
        vm.stopPrank();
        uint256 snap = vm.snapshotState();
        // Saturday, ETH +60%: no price, no liquidation, through the liquidator or not.
        _toSaturday();
        _post(address(ETH_FEED), eth8 * 160 / 100);
        Position memory p = MORPHO.position(m.id(), alice);
        (, uint256 at) = _nvdaAt();
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, at));
        liq.liquidate(m, alice, 0, p.borrowShares / 2, NVDA_DESK, 0);
        // A weekday, NVDA -40%: the liquidator does it, never arming anything.
        vm.revertToState(snap);
        vm.clearMockedCalls(); // mocks outlive a state revert; back to the real feeds
        _post(NVDA_FEED, nvda8 * 60 / 100);
        vm.startStateDiffRecording();
        vm.prank(keeper);
        uint256 profit = liq.liquidate(m, alice, 0, p.borrowShares, NVDA_DESK, 0);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        (uint256 arms,) = _checkWindow(acc, address(plain), BNVDA, address(liq));
        assertEq(arms, 0);
        assertGt(profit, 0);
        assertEq(MORPHO.position(m.id(), alice).borrowShares, 0);
        _empty(address(liq));
    }

    // ------------------------------------------------------------------ a hostile route

    function _hostileSetup() internal returns (HostilePool pool, EthLoanLiquidator l2, StockEthOracle o2, MarketParams memory m2) {
        pool = new HostilePool(NVDA, USDG, MORPHO);
        l2 = new EthLoanLiquidator(MORPHO, IPoolManager(POOL_MANAGER), IERC20(USDG), IERC20(WETH), ETH_POOL, new RouteDesks(NVDA, address(pool)), IRM);
        o2 = new StockEthOracle(NVDA, IShareVault(BNVDA), IChainlinkFeed(NVDA_FEED), ETH_FEED, ETH_PRICE, address(l2));
        m2 = MarketParams({loanToken: WETH, collateralToken: BNVDA, oracle: address(o2), irm: IRM, lltv: LLTV});
        MORPHO.createMarket(m2);
        address lender = makeAddr("lender2");
        deal(WETH, lender, 30 ether);
        vm.prank(lender);
        IERC20(WETH).approve(address(MORPHO), 30 ether);
        vm.prank(lender);
        MORPHO.supply(m2, 30 ether, 0, lender, "");
        // Alice borrows near the limit in this market (straight on Morpho).
        deal(NVDA, alice, 50e18);
        vm.startPrank(alice);
        IERC20(NVDA).approve(BNVDA, 50e18);
        uint256 shares = IVault4626(BNVDA).deposit(50e18, alice);
        IERC20(BNVDA).approve(address(MORPHO), shares);
        MORPHO.supplyCollateral(m2, shares, alice, "");
        MORPHO.borrow(m2, shares * o2.borrowPrice() / 1e36 * LLTV / 1e18 * 99 / 100, 0, alice, alice);
        vm.stopPrank();
        // The hostile pool's owner posts 20 NVDA of its own in the same market, to try to borrow against during a
        // liquidation, and holds USDG to pay for what it buys.
        deal(NVDA, address(this), 20e18);
        IERC20(NVDA).approve(BNVDA, 20e18);
        uint256 s2 = IVault4626(BNVDA).deposit(20e18, address(pool));
        uint256 px = nvda8 * 1e6 / 1e8; // USDG per NVDA at the feed price
        uint256 ask = s2 * o2.borrowPrice() / 1e36 * 30 / 100; // 30% of its worth now; reset for the weekend test
        pool.setUp(o2, l2, m2, px, ask);
        pool.post(s2);
        deal(USDG, address(pool), 1_000_000e6);
    }

    /// Saturday: the hostile route's borrow during the liquidation is refused (the oracle is strict again), it cannot
    /// arm the oracle or re-enter, and the liquidation still completes.
    function test_hostileRoute_weekend() public onFork {
        (HostilePool pool, EthLoanLiquidator l2, StockEthOracle o2, MarketParams memory m2) = _hostileSetup();
        _toSaturday();
        _post(address(ETH_FEED), eth8 * 160 / 100);
        // It asks for 30% of its collateral's worth at the liquidation price: inside the 38.5% limit, so an armed
        // oracle would let it through.
        Position memory pp = MORPHO.position(m2.id(), address(pool));
        pool.setUp(o2, l2, m2, pool.usdgPerStock(), pp.collateral * o2.liquidationPrice() / 1e36 * 30 / 100);
        assertLt(pool.borrowTry(), pp.collateral * o2.liquidationPrice() / 1e36 * LLTV / 1e18, "an armed oracle would allow it");
        Position memory p = MORPHO.position(m2.id(), alice);
        vm.startStateDiffRecording();
        vm.prank(keeper);
        l2.liquidate(m2, alice, 0, p.borrowShares / 2, bytes32(0), 0);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        (uint256 arms,) = _checkWindow(acc, address(o2), BNVDA, address(l2));
        assertEq(arms, 1);
        assertTrue(pool.swapped(), "the hostile pool ran");
        assertFalse(pool.sawArmed(), "the oracle was off while the pool ran");
        assertTrue(pool.priceReverted(), "strict on a Saturday: no price");
        assertFalse(pool.borrowOk(), "its borrow was refused");
        (, uint256 at) = _nvdaAt();
        assertEq(pool.borrowError(), abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, at));
        assertTrue(pool.armRefused());
        assertTrue(pool.reentryRefused());
        assertEq(MORPHO.position(m2.id(), address(pool)).borrowShares, 0);
        _empty(address(l2));
    }

    /// A weekday: the hostile route's borrow sees the strict price, the same any borrower sees.
    function test_hostileRoute_weekday() public onFork {
        (HostilePool pool, EthLoanLiquidator l2, StockEthOracle o2, MarketParams memory m2) = _hostileSetup();
        _post(NVDA_FEED, nvda8 * 60 / 100);
        Position memory p = MORPHO.position(m2.id(), alice);
        vm.prank(keeper);
        l2.liquidate(m2, alice, 0, p.borrowShares, bytes32(0), 0);
        assertTrue(pool.swapped());
        assertFalse(pool.sawArmed());
        assertFalse(pool.priceReverted());
        assertEq(pool.priceSeen(), o2.borrowPrice(), "the strict price");
        assertTrue(pool.armRefused());
        assertTrue(pool.reentryRefused());
        _empty(address(l2));
    }

    // ------------------------------------------------------------------ gas

    function test_gas() public onFork {
        GasUser u = new GasUser();
        deal(NVDA, address(u), 50e18);
        u.prepare(MORPHO, address(router), NVDA, 50e18);
        uint256 worth = 50e18 * oracle.borrowPrice() / 1e36;
        uint256 borrowAmt = worth * LLTV / 1e18 * 7_400 / 10_000;
        EthLoanRouter.Open memory o =
            EthLoanRouter.Open({market: mp, stockIn: 50e18, sharesIn: 0, minShares: 0, borrow: borrowAmt, deadline: vm.getBlockTimestamp() + 600});
        uint256 gOpen = u.measure(address(router), 0, abi.encodeCall(EthLoanRouter.open, (o)));
        vm.deal(address(u), 0.05 ether);
        uint256 gRepay = u.measure(address(router), 0.05 ether, abi.encodeCall(EthLoanRouter.repay, (mp)));
        uint256 gWithdraw = u.measure(address(router), 0, abi.encodeCall(EthLoanRouter.withdraw, (mp, 1e18, true)));
        console2.log("router gas: open (deposit, post, borrow, send ETH), repay, take back as stock:", gOpen, gRepay, gWithdraw);
        _post(NVDA_FEED, nvda8 * 60 / 100);
        Position memory p = MORPHO.position(id, address(u));
        GasUser k = new GasUser();
        uint256 gLiq = k.measure(address(liq), 0, abi.encodeCall(EthLoanLiquidator.liquidate, (mp, address(u), 0, p.borrowShares, NVDA_DESK, 0)));
        console2.log("liquidation gas (flash, arm, liquidate, disarm, redeem, sell on the v4 route, buy WETH):", gLiq);
    }
}
