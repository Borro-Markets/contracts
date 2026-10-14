// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMorpho, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IMorphoLiquidateCallback} from "morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {StockEthOracle, IShareVault, IChainlinkFeed, IEthUsd} from "../../src/eth/StockEthOracle.sol";

interface IVaultDeposit {
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IMorphoOracle {
    function price() external view returns (uint256);
}

interface IWethUsdgPool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// Stands in for the stage 2 liquidator: pays with its own WETH, arms around its own Morpho call, disarms first thing in
/// the callback, and records what the oracle said once disarmed.
contract TestLiquidator is IMorphoLiquidateCallback {
    IMorpho public immutable morpho;
    IERC20 public immutable weth;
    StockEthOracle public oracle;
    bool public strictAfterDisarm; // inside the callback, after disarming: did price() refuse, as strict?
    uint256 public lastGas; // gas of the Morpho liquidate call

    constructor(IMorpho m, IERC20 w) {
        morpho = m;
        weth = w;
    }

    function setOracle(StockEthOracle o) external {
        require(address(oracle) == address(0));
        oracle = o;
    }

    function liquidate(MarketParams calldata mp, address borrower, uint256 seized) external returns (uint256 s, uint256 r) {
        oracle.arm();
        uint256 g = gasleft();
        (s, r) = morpho.liquidate(mp, borrower, seized, 0, hex"00");
        lastGas = g - gasleft();
        oracle.disarm();
    }

    function onMorphoLiquidate(uint256 repaid, bytes calldata) external {
        require(msg.sender == address(morpho));
        oracle.disarm();
        try oracle.price() returns (uint256) {
            strictAfterDisarm = false;
        } catch {
            strictAfterDisarm = true;
        }
        weth.approve(address(morpho), repaid);
    }
}

/// A borrower that is a contract, so a test can measure what Morpho's calls cost inside one transaction.
contract BorrowerAccount {
    IMorpho public immutable morpho;

    constructor(IMorpho m) {
        morpho = m;
    }

    function post(MarketParams calldata mp, IERC20 stock, IVaultDeposit vault, uint256 amount) external returns (uint256 shares) {
        stock.approve(address(vault), amount);
        shares = vault.deposit(amount, address(this));
        IERC20(mp.collateralToken).approve(address(morpho), shares);
        morpho.supplyCollateral(mp, shares, address(this), "");
    }

    function borrow(MarketParams calldata mp, uint256 assets) external returns (uint256 gasUsed) {
        uint256 g = gasleft();
        morpho.borrow(mp, assets, 0, address(this), address(this));
        gasUsed = g - gasleft();
    }

    function withdraw(MarketParams calldata mp, uint256 shares) external {
        morpho.withdrawCollateral(mp, shares, address(this), address(this));
    }

    function addMore(MarketParams calldata mp, uint256 shares) external {
        IERC20(mp.collateralToken).approve(address(morpho), shares);
        morpho.supplyCollateral(mp, shares, address(this), "");
    }

    function repay(MarketParams calldata mp, uint256 assets) external {
        IERC20(mp.loanToken).approve(address(morpho), assets);
        morpho.repay(mp, assets, 0, address(this), "");
    }

    /// Repays every borrow share and takes all the collateral back.
    function closeOut(MarketParams calldata mp, bytes32 id) external returns (uint256 collateral) {
        Position memory p = morpho.position(Id.wrap(id), address(this));
        IERC20(mp.loanToken).approve(address(morpho), type(uint256).max);
        morpho.repay(mp, 0, p.borrowShares, address(this), "");
        morpho.withdrawCollateral(mp, p.collateral, address(this), address(this));
        collateral = p.collateral;
    }
}

/// Pushes the WETH/USDG pool's price with its own tokens, like an attacker would.
contract Spiker {
    IWethUsdgPool public immutable pool;
    IERC20 public immutable weth; // token0
    IERC20 public immutable usdg; // token1

    constructor(IWethUsdgPool p, IERC20 w, IERC20 u) {
        pool = p;
        weth = w;
        usdg = u;
    }

    /// Moves the pool to `limit`. Up: pays USDG for WETH. Down: pays WETH for USDG. Returns what went in and out.
    function moveTo(uint160 limit) external returns (int256 a0, int256 a1) {
        (uint160 now_,,,,,,) = pool.slot0();
        bool down = limit < now_;
        (a0, a1) = pool.swap(address(this), down, type(int128).max, limit, "");
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        require(msg.sender == address(pool));
        if (d0 > 0) weth.transfer(msg.sender, uint256(d0));
        if (d1 > 0) usdg.transfer(msg.sender, uint256(d1));
    }
}

/// Measures gas inside one transaction: the first read is cold, the second warm.
contract GasMeter {
    function measure(address target, bytes calldata data) external view returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        (bool ok,) = target.staticcall(data);
        cold = g - gasleft();
        require(ok, "cold read failed");
        g = gasleft();
        (ok,) = target.staticcall(data);
        warm = g - gasleft();
        require(ok, "warm read failed");
    }
}

/// StockEthOracle on a copy of Robinhood Chain: the real Chainlink feeds, the real Borro stock vaults, the real
/// WETH/USDG pool and its EthPrice average, and the real Morpho. Set BORRO_FORK_RPC to run. Pinned to block
/// 82,091,631 (Tuesday 2026-10-06 21:34 New York, the market open), so the numbers repeat.
contract StockEthOracleForkTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 constant FORK_BLOCK = 82_091_631;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant IRM = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1;
    IERC20 constant WETH = IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IChainlinkFeed constant ETH_FEED = IChainlinkFeed(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
    IChainlinkFeed constant USDG_FEED = IChainlinkFeed(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2);
    IEthUsd constant ETH_PRICE = IEthUsd(0x1d1B3096406279A93C955ED0d65fA2597B08CDef); // CoinListing's EthPrice, 1800 s
    IWethUsdgPool constant ETH_POOL = IWethUsdgPool(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    uint256 constant LLTV = 0.385e18;

    // Saturday 2026-10-10 12:00 New York, and Sunday 2026-10-11 20:00 New York (the reopen).
    uint256 constant SAT_NOON = 1791648000;
    uint256 constant SUN_REOPEN = 1791763200;

    struct Desk {
        string symbol;
        address token;
        address feed;
        address vault;
        address usdgOracle;
    }

    Desk[] desks;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;
        _add("SPY", 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 0x319724394D3A0e3669269846abE664Cd621f9f6A, 0xC3ED4a5A7dB4102F4Ed37Af26ef0d3f21e2360c1, 0xac6E0472981877dcebb1527E417b5CB6133721b3);
        _add("QQQ", 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, 0x80901d846d5D7B030F26B480776EE3b29374C2ae, 0xbAD8A97dA1050092d6a14194D53E72D407D6cc17, 0x667b8FC52939a08940C13B03effc6F072547ccdc);
        _add("NVDA", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15, 0x508E23274C39C60c345e35B1f0188bE180717CB9, 0x62c20e5AfCFCB1A2Bbe30891aB77334C31c956d2);
        _add("TSLA", 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 0x4A1166a659A55625345e9515b32adECea5547C38, 0x60b3d353E7e5bD12ED4Ea2589C11B5603dd4c988, 0x14896c69b0b53292f51ab11C69d46C2f4518ecde);
        _add("MSTR", 0xec262a75e413fAfD0dF80480274532C79D42da09, 0x396118bdFB181e6240E74D243F266B061c0edc3D, 0x2B74f8F2b76cd4e97265BC37FB2578a04B8437e9, 0xeFf12C9bE9bd34DC25E5586EbBC4904df2b0416b);
        _add("COIN", 0x6330D8C3178a418788dF01a47479c0ce7CCF450b, 0xA3a468A452940B7D6b69991207B508c609a98Ef2, 0x7BA71BCCeCb12860aE7E141B6b6F1f8B96d31257, 0xb7470ad30d6aBD81E9a3Cb7893Af1bcbFb1795c5);
        _add("PLTR", 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c, 0xFE9419E70e5481F7a2dDddc18f856b09b3687B27, 0xFc4AfF549eea3A64992fC6410ea0fea52bD1f543);
        _add("SPCX", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb, 0x1261210E19052157fCe2064D9aa9A2140Bd89791, 0xCA61a812B8793a3AA891CDCD0f1323c2FBdCea83);
        _add("GME", 0x1b0E319c6A659F002271B69dB8A7df2F911c153E, 0x27C71df6A64fB476468EdF256CF72c038baB5B67, 0x328461fB01F54C2Ab73909EA947c583d0dC24C3d, 0xA7f17C3E654Ba4E7E5ACe9F81878C347c6785C7F);
    }

    function _add(string memory s, address t, address f, address v, address u) internal {
        desks.push(Desk(s, t, f, v, u));
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _oracle(Desk memory d, address liquidator) internal returns (StockEthOracle) {
        return new StockEthOracle(d.token, IShareVault(d.vault), IChainlinkFeed(d.feed), ETH_FEED, ETH_PRICE, liquidator);
    }

    function _answer(IChainlinkFeed f) internal view returns (uint256 a, uint256 t) {
        (, int256 x,, uint256 u,) = f.latestRoundData();
        return (uint256(x), u);
    }

    /// Chainlink posts ETH at `usd8` now (a stand-in for the feed updating while time moves on in the test).
    function _ethPosts(uint256 usd8) internal {
        vm.mockCall(
            address(ETH_FEED),
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(usd8), vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
    }

    function _stockPosts(address feed, uint256 usd8) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(usd8), vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
    }

    function _relDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 d = a > b ? a - b : b - a;
        return d * 1e18 / b;
    }

    // ------------------------------------------------------------------ 1. the price, all nine stocks

    /// For every stock: the oracle equals a direct calculation from the same feeds and vault, and agrees with the
    /// route through Morpho's own deployed oracle for the stock's USDG market (Morpho's code, Morpho's factory)
    /// converted to ETH, to within rounding.
    function test_nineStocks_priceMatches() public onFork {
        (uint256 eth, uint256 ethAt) = _answer(ETH_FEED);
        (uint256 usdgUsd,) = _answer(USDG_FEED);
        console2.log("ETH/USD (Chainlink, 8 dp) and its age in seconds:", eth, vm.getBlockTimestamp() - ethAt);
        console2.log("ETH in USDG by the pool's 30-minute average (18 dp):", ETH_PRICE.ethUsd());
        for (uint256 i; i < desks.length; i++) {
            Desk memory d = desks[i];
            StockEthOracle o = _oracle(d, address(0));
            (uint256 s, uint256 sAt) = _answer(IChainlinkFeed(d.feed));
            uint256 perShare = IVaultDeposit(d.vault).convertToAssets(1e18);
            uint256 direct = FullMath.mulDiv(perShare * 1e18, s, eth);
            uint256 p = o.borrowPrice();
            assertEq(p, direct, d.symbol);
            assertEq(o.price(), p);
            assertEq(o.liquidationPrice(), p);

            uint256 viaMorpho = FullMath.mulDiv(IMorphoOracle(d.usdgOracle).price() * 1e12, usdgUsd, eth);
            assertLt(_relDiff(p, viaMorpho), 1e9, "within one part in a billion of Morpho's own oracle"); // 1e-9

            // The raw-stock version: the same without the vault's rate.
            StockEthOracle raw =
                new StockEthOracle(d.token, IShareVault(address(0)), IChainlinkFeed(d.feed), ETH_FEED, ETH_PRICE, address(0));
            assertEq(raw.borrowPrice(), FullMath.mulDiv(1e36, s, eth));

            console2.log(d.symbol);
            console2.log("  stock USD (8 dp), feed age s:", s, vm.getBlockTimestamp() - sAt);
            console2.log("  stock per share (18 dp):", perShare);
            console2.log("  WETH per share (18 dp):", p / 1e18);
        }
    }

    // ------------------------------------------------------------------ 2. a real Morpho market, weekday to weekend

    function test_morphoMarket_weekdayThenWeekend() public onFork {
        Desk memory d = desks[2]; // NVDA
        TestLiquidator liq = new TestLiquidator(MORPHO, WETH);
        StockEthOracle o = _oracle(d, address(liq));
        liq.setOracle(o);
        MarketParams memory mp =
            MarketParams({loanToken: address(WETH), collateralToken: d.vault, oracle: address(o), irm: IRM, lltv: LLTV});
        MORPHO.createMarket(mp);
        Id id = mp.id();

        // An ETH lender and a borrower who posts 50 NVDA (about $9,000) as bNVDA.
        address lender = makeAddr("lender");
        deal(address(WETH), lender, 20 ether);
        vm.prank(lender);
        WETH.approve(address(MORPHO), 20 ether);
        vm.prank(lender);
        MORPHO.supply(mp, 20 ether, 0, lender, "");
        BorrowerAccount acct = new BorrowerAccount(MORPHO);
        deal(d.token, address(acct), 50e18);
        uint256 shares = acct.post(mp, IERC20(d.token), IVaultDeposit(d.vault), 50e18);

        // Weekday: Morpho's limit is exactly the oracle's price times the LLTV.
        uint256 p = o.borrowPrice();
        uint256 limit = shares * p / 1e36 * LLTV / 1e18;
        console2.log("bNVDA posted, WETH borrow limit at 38.5%:", shares, limit);
        uint256 gasBorrow = acct.borrow(mp, limit * 99 / 100);
        console2.log("gas of a Morpho borrow that reads this oracle (strict, cold):", gasBorrow);
        vm.expectRevert(bytes("insufficient collateral"));
        acct.borrow(mp, limit * 2 / 100);

        // Saturday. ETH keeps trading: Chainlink posts the same price. The stock feed holds Friday's.
        vm.warp(SAT_NOON);
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 eth,) = _answer(ETH_FEED);
        _ethPosts(eth);
        (, uint256 stockAt) = _answer(IChainlinkFeed(d.feed));
        bytes memory closed = abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, stockAt);
        vm.expectRevert(closed);
        acct.borrow(mp, 1);
        vm.expectRevert(closed);
        acct.withdraw(mp, 1);

        // ETH +3%: past the limit at Friday's close, but not with NVDA 5% above it. No liquidation, either way.
        _ethPosts(eth * 103 / 100);
        deal(address(WETH), address(liq), 100 ether);
        vm.expectRevert(closed);
        MORPHO.liquidate(mp, address(acct), 1e18, 0, ""); // straight on Morpho: no price on a weekend
        vm.expectRevert(bytes("position is healthy"));
        liq.liquidate(mp, address(acct), 1e18);

        // ETH +8%: past the limit even with the cushion. Borro's liquidator can close it out; Morpho directly cannot.
        _ethPosts(eth * 108 / 100);
        vm.expectRevert(closed);
        MORPHO.liquidate(mp, address(acct), 1e18, 0, "");
        uint256 lp = o.liquidationPrice();
        Position memory before = MORPHO.position(id, address(acct));
        (uint256 seized, uint256 repaid) = liq.liquidate(mp, address(acct), before.collateral / 4);
        console2.log("weekend liquidation: bNVDA seized, WETH repaid, gas:", seized, repaid, liq.lastGas());
        // Morpho: repaid = seized x price / 1e36 / 1.15 (the bonus at 38.5%), rounded up.
        uint256 want = FullMath.mulDiv(FullMath.mulDiv(seized, lp, 1e36), 1e18, 1.15e18);
        assertApproxEqAbs(repaid, want, 5);
        assertTrue(liq.strictAfterDisarm(), "the window closed before the callback went on");
        // The cushion: the liquidation price is Friday's NVDA plus 5%.
        (uint256 s,) = _answer(IChainlinkFeed(d.feed));
        assertEq(lp, FullMath.mulDiv(IVaultDeposit(d.vault).convertToAssets(1e18) * 1e18, s * 10_500 / 10_000, eth * 108 / 100));

        // Still Saturday: adding collateral and repaying need no price, so they work.
        deal(d.token, address(acct), 1e18);
        assertGt(acct.post(mp, IERC20(d.token), IVaultDeposit(d.vault), 1e18), 0);
        deal(address(WETH), address(acct), 0.01 ether);
        acct.repay(mp, 0.01 ether);
        // And a loan repaid in full lets its collateral go, weekend or not: Morpho asks no price of a position that
        // owes nothing. Then it is posted again for Sunday.
        deal(address(WETH), address(acct), 10 ether);
        uint256 back = acct.closeOut(mp, Id.unwrap(id));
        assertEq(IERC20(d.vault).balanceOf(address(acct)), back);
        assertEq(MORPHO.position(id, address(acct)).collateral, 0);
        acct.addMore(mp, back);

        // Sunday 20:00 New York: the market opens; Friday's price is over 25 hours old until the feed posts.
        vm.warp(SUN_REOPEN + 30);
        vm.roll(vm.getBlockNumber() + 1);
        _ethPosts(eth); // back where the pool's average is
        vm.expectRevert(closed);
        o.borrowPrice();
        _stockPosts(d.feed, s);
        assertGt(o.borrowPrice(), 0);
        acct.borrow(mp, 1);
    }

    // ------------------------------------------------------------------ 3. silent feeds and corporate actions

    function test_silentStockFeedOnAWeekday() public onFork {
        Desk memory d = desks[2];
        StockEthOracle o = _oracle(d, address(0));
        (uint256 s, uint256 sAt) = _answer(IChainlinkFeed(d.feed));
        (uint256 eth,) = _answer(ETH_FEED);
        uint256 perShare = IVaultDeposit(d.vault).convertToAssets(1e18);
        // A weekday, the market open, and the feed has not posted for 25 hours and a second.
        vm.warp(sAt + 25 hours + 1);
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(o.marketOpen());
        _ethPosts(eth);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, sAt));
        o.borrowPrice();
        assertEq(o.liquidationPrice(), FullMath.mulDiv(IVaultDeposit(d.vault).convertToAssets(1e18) * 1e18, s * 10_500 / 10_000, eth));
        assertApproxEqRel(IVaultDeposit(d.vault).convertToAssets(1e18), perShare, 1e15);
        // Silent for more than five days: no price at all, not even for a liquidation.
        vm.warp(sAt + 5 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        _ethPosts(eth);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.StockTooOld.selector, sAt));
        o.liquidationPrice();
    }

    function test_corporateActionPause() public onFork {
        Desk memory d = desks[0];
        StockEthOracle o = _oracle(d, address(0));
        vm.mockCall(d.token, abi.encodeWithSignature("oraclePaused()"), abi.encode(true));
        vm.expectRevert(StockEthOracle.StockPaused.selector);
        o.borrowPrice();
        vm.expectRevert(StockEthOracle.StockPaused.selector);
        o.liquidationPrice();
    }

    function test_staleEthFeed() public onFork {
        StockEthOracle o = _oracle(desks[0], address(0));
        (, uint256 ethAt) = _answer(ETH_FEED);
        vm.warp(ethAt + 25 hours + 1);
        vm.roll(vm.getBlockNumber() + 1);
        _stockPosts(desks[0].feed, 600e8);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.EthTooOld.selector, ethAt));
        o.liquidationPrice();
    }

    // ------------------------------------------------------------------ 4. pushing the pool

    function _sqrtTimes(uint160 sq, uint256 bps, bool up) internal pure returns (uint160) {
        uint256 r = Math.sqrt((up ? 10_000 + bps : 10_000 - bps) * 1e32); // sqrt(ratio) x 1e18
        return uint160(FullMath.mulDiv(sq, r, 1e18));
    }

    /// What it takes to move the WETH/USDG pool, and what a move held for one block does to the 30-minute average and
    /// to the oracle. Pool fee 0.01%; no arbitrage on a fork, so a held price costs nothing here but in life is
    /// traded back against every block.
    function test_ethSpike_costAndOneBlockEffect() public onFork {
        Spiker sp = new Spiker(ETH_POOL, WETH, USDG);
        deal(address(USDG), address(sp), 2_000_000_000e6);
        deal(address(WETH), address(sp), 1_000_000 ether);
        StockEthOracle o = _oracle(desks[2], address(0));
        uint256 p0 = o.borrowPrice();
        uint256 avg0 = ETH_PRICE.ethUsd();
        (uint160 sq0,,,,,,) = ETH_POOL.slot0();
        uint256 spot0 = FullMath.mulDiv(FullMath.mulDiv(1e30, sq0, 2 ** 96), sq0, 2 ** 96); // USDG per ETH, 18 dp

        uint16[5] memory steps = [uint16(100), 500, 1_000, 2_500, 5_000];
        for (uint256 i; i < steps.length; i++) {
            (int256 a0, int256 a1) = sp.moveTo(_sqrtTimes(sq0, steps[i], true));
            uint256 usdgIn = uint256(a1);
            uint256 wethOut = uint256(-a0);
            // Bought above the starting price: what that premium costs once the price is back where it was.
            uint256 premium = usdgIn - FullMath.mulDiv(wethOut, spot0, 1e30);
            (int256 b0, int256 b1) = sp.moveTo(sq0); // straight back
            uint256 roundTrip = usdgIn - uint256(-b1);
            console2.log("push ETH up, bps:", steps[i]);
            console2.log("  USDG in, WETH out (wei):", usdgIn, wethOut);
            console2.log("  premium over the starting price (USDG wei), round trip with no arbitrage (USDG wei):", premium, roundTrip);
            assertGt(uint256(b0), 0);
        }

        // A one-block spike of +50%: pushed, held for one second (a block), pushed back.
        sp.moveTo(_sqrtTimes(sq0, 5_000, true));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        sp.moveTo(sq0);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 avg1 = ETH_PRICE.ethUsd();
        console2.log("30-minute average before, after a one-second +50% spike (18 dp):", avg0, avg1);
        assertLt(_relDiff(avg1, avg0), 0.0005e18, "under 0.05%");
        // The oracle's price comes from Chainlink: unmoved, and the band nowhere near.
        assertApproxEqRel(o.borrowPrice(), p0, 1e9);
    }

    /// How long the pool must be held away to trip the 5% band (which only stops borrowing).
    function test_ethSpike_holdToTripTheBand() public onFork {
        Spiker sp = new Spiker(ETH_POOL, WETH, USDG);
        deal(address(USDG), address(sp), 2_000_000_000e6);
        deal(address(WETH), address(sp), 1_000_000 ether);
        StockEthOracle o = _oracle(desks[2], address(0));
        (uint256 eth,) = _answer(ETH_FEED);
        uint256 lp0 = o.liquidationPrice();
        (uint160 sq0,,,,,,) = ETH_POOL.slot0();
        uint16[3] memory steps = [uint16(1_000), 2_500, 10_000];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < steps.length; i++) {
            vm.revertToState(snap);
            (, int256 a1) = sp.moveTo(_sqrtTimes(sq0, steps[i], true));
            uint256 held;
            while (true) {
                vm.warp(vm.getBlockTimestamp() + 15);
                vm.roll(vm.getBlockNumber() + 1);
                held += 15;
                _ethPosts(eth); // Chainlink stays where ETH really is
                try o.borrowPrice() returns (uint256) {}
                catch {
                    break;
                }
                require(held < 3_600, "never tripped");
            }
            console2.log("held up by bps, USDG put in (wei):", steps[i], uint256(a1));
            console2.log("  seconds held before borrowing stopped:", held);
            // Liquidations never read the pool.
            assertApproxEqRel(o.liquidationPrice(), lp0, 1e12);
        }
    }

    // ------------------------------------------------------------------ 5. gas

    function test_gas() public onFork {
        GasMeter m = new GasMeter();
        TestLiquidator liq = new TestLiquidator(MORPHO, WETH);
        StockEthOracle o = _oracle(desks[2], address(liq));
        (uint256 cold, uint256 warm) = m.measure(address(o), abi.encodeCall(StockEthOracle.borrowPrice, ()));
        console2.log("strict price(), cold and warm:", cold, warm);
        (cold, warm) = m.measure(address(o), abi.encodeCall(StockEthOracle.liquidationPrice, ()));
        console2.log("liquidation price, cold and warm:", cold, warm);
        StockEthOracle raw =
            new StockEthOracle(desks[2].token, IShareVault(address(0)), IChainlinkFeed(desks[2].feed), ETH_FEED, ETH_PRICE, address(0));
        (cold, warm) = m.measure(address(raw), abi.encodeCall(StockEthOracle.borrowPrice, ()));
        console2.log("strict price(), raw stock collateral, cold and warm:", cold, warm);
        (cold, warm) = m.measure(desks[2].usdgOracle, abi.encodeCall(IMorphoOracle.price, ()));
        console2.log("for scale, the live NVDA USDG market's oracle, cold and warm:", cold, warm);
    }
}
