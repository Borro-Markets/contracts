// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StockEthOracle, IShareVault, IChainlinkFeed, IEthUsd} from "../../src/eth/StockEthOracle.sol";

contract EthMockFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract EthMockStock {
    uint8 public decimals = 18;
    bool public paused;
    bool public broken;

    function setPaused(bool p) external {
        paused = p;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function oraclePaused() external view returns (bool) {
        require(!broken, "gone");
        return paused;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }
}

contract EthMockVault {
    address public asset;
    uint8 public decimals = 18;
    uint256 public rate = 1e18; // stock wei per 1e18 share wei

    constructor(address a) {
        asset = a;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * rate / 1e18;
    }
}

contract EthMockPool {
    uint256 public value;
    bool public broken;

    function set(uint256 v) external {
        value = v;
    }

    function breakIt() external {
        broken = true;
    }

    function ethUsd() external view returns (uint256) {
        require(!broken, "no history");
        return value;
    }
}

/// Reads an oracle's price() from its own address: a stand-in for Morpho, which calls price() during a borrow.
contract Reader {
    function read(StockEthOracle o) external view returns (uint256) {
        return o.price();
    }
}

/// Stands in for the liquidator: arms, reads (itself or through someone else), disarms, all inside one call, the way
/// the liquidator arms around its own call to Morpho.
contract ArmingLiquidator {
    Reader public immutable reader = new Reader();

    function armedPrice(StockEthOracle o) external returns (uint256 p) {
        o.arm();
        p = o.price();
        o.disarm();
    }

    /// Armed, a different caller (a borrow, say) gets the liquidation price too.
    function armedPriceForSomeoneElse(StockEthOracle o) external returns (uint256 p) {
        o.arm();
        p = reader.read(o);
        o.disarm();
    }

    /// Disarmed again, the same caller gets the strict answer.
    function priceAfterDisarm(StockEthOracle o) external returns (uint256) {
        o.arm();
        o.disarm();
        return reader.read(o);
    }

    /// Arms one oracle and reads another.
    function armOneReadOther(StockEthOracle armed, StockEthOracle other) external returns (uint256 p) {
        armed.arm();
        p = other.price();
        armed.disarm();
    }

    /// Arms and leaves it armed: the transaction ends, and so does the flag.
    function armAndLeave(StockEthOracle o) external {
        o.arm();
    }
}

/// Unit tests of StockEthOracle with stand-in feeds, token, vault and pool.
contract StockEthOracleTest is Test {
    // Wednesday 2026-10-07 12:00 New York (16:00 UTC): the market is open.
    uint256 constant WED_NOON = 1791388800;
    // Saturday 2026-10-10 12:00 New York.
    uint256 constant SAT_NOON = 1791648000;
    // Thanksgiving, Thursday 2026-11-26 12:00 New York (EST).
    uint256 constant THANKSGIVING_NOON = 1795712400;

    EthMockFeed stockFeed;
    EthMockFeed ethFeed;
    EthMockStock stock;
    EthMockVault vault;
    EthMockPool pool;
    StockEthOracle oracle;
    ArmingLiquidator liquidator;
    address liq;

    function setUp() public {
        vm.warp(WED_NOON);
        stockFeed = new EthMockFeed();
        ethFeed = new EthMockFeed();
        stock = new EthMockStock();
        vault = new EthMockVault(address(stock));
        pool = new EthMockPool();
        stockFeed.set(180e8, WED_NOON - 1 hours); // $180
        ethFeed.set(2700e8, WED_NOON - 10 minutes); // $2,700
        pool.set(2690e18);
        vault.setRate(1.02e18);
        liquidator = new ArmingLiquidator();
        liq = address(liquidator);
        oracle = _make(liq);
    }

    function _make(address liquidator_) internal returns (StockEthOracle) {
        return new StockEthOracle(
            address(stock), IShareVault(address(vault)), IChainlinkFeed(address(stockFeed)), IChainlinkFeed(address(ethFeed)),
            IEthUsd(address(pool)), liquidator_
        );
    }

    function _expected(uint256 stockUsd8, uint256 ethUsd8, uint256 rate) internal pure returns (uint256) {
        return rate * 1e18 * stockUsd8 / ethUsd8;
    }

    // ------------------------------------------------------------------ setup checks

    function test_setupChecks() public {
        stock.setDecimals(6);
        vm.expectRevert(StockEthOracle.BadSetup.selector);
        _make(liq);
        stock.setDecimals(18);

        EthMockVault other = new EthMockVault(address(0xBEEF));
        vm.expectRevert(StockEthOracle.BadSetup.selector);
        new StockEthOracle(
            address(stock), IShareVault(address(other)), IChainlinkFeed(address(stockFeed)), IChainlinkFeed(address(ethFeed)),
            IEthUsd(address(pool)), liq
        );

        ethFeed.setDecimals(18);
        vm.expectRevert(StockEthOracle.BadSetup.selector);
        _make(liq);
        ethFeed.setDecimals(8);

        pool.set(0);
        vm.expectRevert(StockEthOracle.BadSetup.selector);
        _make(liq);
    }

    // ------------------------------------------------------------------ the price

    function test_priceOnAnOpenWeekday() public view {
        uint256 want = _expected(180e8, 2700e8, 1.02e18);
        assertEq(oracle.price(), want);
        assertEq(oracle.borrowPrice(), want);
        assertEq(oracle.liquidationPrice(), want);
        // 1.02 stock per share x $180 / $2,700 = 0.068 WETH per share, scaled by 1e36.
        assertEq(want, 0.068e36);
        assertEq(oracle.collateral(), address(vault));
        assertTrue(oracle.marketOpen());
    }

    function test_rawStockCollateral() public {
        StockEthOracle raw = new StockEthOracle(
            address(stock), IShareVault(address(0)), IChainlinkFeed(address(stockFeed)), IChainlinkFeed(address(ethFeed)),
            IEthUsd(address(pool)), liq
        );
        assertEq(raw.price(), uint256(180e8) * 1e36 / 2700e8);
        assertEq(raw.collateral(), address(stock));
    }

    function testFuzz_priceFormula(uint64 stockUsd, uint64 ethUsd, uint64 rateBps) public {
        stockUsd = uint64(bound(stockUsd, 1e6, 1e14)); // $0.01 to $1M
        ethUsd = uint64(bound(ethUsd, 1e8, 1e13)); // $1 to $100k
        rateBps = uint64(bound(rateBps, 5_000, 30_000)); // 0.5 to 3 stock per share
        stockFeed.set(int256(uint256(stockUsd)), block.timestamp);
        ethFeed.set(int256(uint256(ethUsd)), block.timestamp);
        pool.set(uint256(ethUsd) * 1e10);
        vault.setRate(uint256(rateBps) * 1e14);
        assertEq(oracle.borrowPrice(), _expected(stockUsd, ethUsd, uint256(rateBps) * 1e14));
        assertEq(oracle.liquidationPrice(), oracle.borrowPrice());
    }

    // ------------------------------------------------------------------ weekends, holidays, silent feeds

    function test_weekend() public {
        vm.warp(SAT_NOON);
        ethFeed.set(2700e8, SAT_NOON - 1 hours); // ETH trades all weekend
        stockFeed.set(180e8, SAT_NOON - 16 hours); // Friday's last price
        assertFalse(oracle.marketOpen());
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, SAT_NOON - 16 hours));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, SAT_NOON - 16 hours));
        oracle.borrowPrice();
        // A liquidation through the liquidator prices the stock 5% above Friday's close.
        uint256 cushioned = _expected(189e8, 2700e8, 1.02e18);
        assertEq(oracle.liquidationPrice(), cushioned);
        assertEq(liquidator.armedPrice(oracle), cushioned);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, SAT_NOON - 16 hours));
        oracle.price();
    }

    function test_holiday() public {
        vm.warp(THANKSGIVING_NOON);
        ethFeed.set(2700e8, THANKSGIVING_NOON);
        stockFeed.set(180e8, THANKSGIVING_NOON - 2 hours); // fresh, yet the market is shut
        assertFalse(oracle.marketOpen());
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, THANKSGIVING_NOON - 2 hours));
        oracle.borrowPrice();
        assertEq(oracle.liquidationPrice(), _expected(189e8, 2700e8, 1.02e18));
    }

    function test_silentFeedOnAWeekday() public {
        stockFeed.set(180e8, WED_NOON - 25 hours);
        assertEq(oracle.borrowPrice(), _expected(180e8, 2700e8, 1.02e18), "25 hours is still fresh");
        stockFeed.set(180e8, WED_NOON - 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, WED_NOON - 25 hours - 1));
        oracle.borrowPrice();
        assertEq(oracle.liquidationPrice(), _expected(189e8, 2700e8, 1.02e18));
    }

    function test_liquidationRefusesAPriceOlderThanFiveDays() public {
        vm.warp(SAT_NOON);
        ethFeed.set(2700e8, SAT_NOON);
        stockFeed.set(180e8, SAT_NOON - 5 days);
        assertEq(oracle.liquidationPrice(), _expected(189e8, 2700e8, 1.02e18));
        stockFeed.set(180e8, SAT_NOON - 5 days - 1);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.StockTooOld.selector, SAT_NOON - 5 days - 1));
        oracle.liquidationPrice();
    }

    /// Sunday 20:00 New York: the market opens, but until the feed posts its first price of the week the price is
    /// Friday's (over 25 hours old), so borrowing waits for that post (about a minute, measured).
    function test_sundayReopen() public {
        uint256 reopen = 1791763200; // Sunday 2026-10-11 20:00 EDT
        vm.warp(reopen + 30);
        ethFeed.set(2700e8, reopen);
        stockFeed.set(180e8, reopen - 48 hours);
        assertTrue(oracle.marketOpen());
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, reopen - 48 hours));
        oracle.borrowPrice();
        stockFeed.set(181e8, reopen + 20);
        assertEq(oracle.borrowPrice(), _expected(181e8, 2700e8, 1.02e18));
    }

    // ------------------------------------------------------------------ bad answers

    function test_pausedTokenStopsEverything() public {
        stock.setPaused(true);
        vm.expectRevert(StockEthOracle.StockPaused.selector);
        oracle.borrowPrice();
        vm.expectRevert(StockEthOracle.StockPaused.selector);
        oracle.liquidationPrice();
    }

    /// A token that stops answering oraclePaused() (an upgrade that drops it) counts as not paused, so it cannot
    /// freeze liquidations. At setup it must answer.
    function test_tokenThatStopsAnswering() public {
        stock.setBroken(true);
        assertEq(oracle.borrowPrice(), _expected(180e8, 2700e8, 1.02e18));
        assertEq(oracle.liquidationPrice(), _expected(180e8, 2700e8, 1.02e18));
        vm.expectRevert(bytes("gone"));
        _make(liq);
    }

    function test_badStockAnswers() public {
        stockFeed.set(0, WED_NOON);
        vm.expectRevert(StockEthOracle.BadStockPrice.selector);
        oracle.liquidationPrice();
        stockFeed.set(-1, WED_NOON);
        vm.expectRevert(StockEthOracle.BadStockPrice.selector);
        oracle.liquidationPrice();
        stockFeed.set(180e8, WED_NOON + 1); // from the future
        vm.expectRevert(StockEthOracle.BadStockPrice.selector);
        oracle.borrowPrice();
    }

    function test_ethFeed() public {
        ethFeed.set(2700e8, WED_NOON - 25 hours);
        assertGt(oracle.borrowPrice(), 0);
        ethFeed.set(2700e8, WED_NOON - 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.EthTooOld.selector, WED_NOON - 25 hours - 1));
        oracle.borrowPrice();
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.EthTooOld.selector, WED_NOON - 25 hours - 1));
        oracle.liquidationPrice();
        ethFeed.set(0, WED_NOON);
        vm.expectRevert(StockEthOracle.BadEthPrice.selector);
        oracle.liquidationPrice();
    }

    // ------------------------------------------------------------------ the pool band

    function test_band() public {
        // Chainlink $2,700. A pool average 5% either way still passes; past that, only borrowing stops.
        uint256 cl = 2700e18;
        pool.set(cl * 10_000 / 10_500 + 1);
        assertGt(oracle.borrowPrice(), 0);
        pool.set(cl * 10_000 / 9_500);
        assertGt(oracle.borrowPrice(), 0);
        pool.set(2570e18);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.EthPricesDisagree.selector, 2700e18, 2570e18));
        oracle.borrowPrice();
        assertEq(oracle.liquidationPrice(), _expected(180e8, 2700e8, 1.02e18), "liquidations never read the pool");
        pool.set(2850e18);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.EthPricesDisagree.selector, 2700e18, 2850e18));
        oracle.borrowPrice();
        pool.breakIt();
        vm.expectRevert(bytes("no history"));
        oracle.borrowPrice();
        assertEq(oracle.liquidationPrice(), _expected(180e8, 2700e8, 1.02e18));
    }

    // ------------------------------------------------------------------ arming

    function test_onlyTheLiquidatorArms() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(StockEthOracle.NotLiquidator.selector);
        oracle.arm();
        vm.expectRevert(StockEthOracle.NotLiquidator.selector);
        oracle.arm(); // the test contract is not the liquidator either
        vm.prank(address(0xBAD));
        vm.expectRevert(StockEthOracle.NotLiquidator.selector);
        oracle.disarm();

        StockEthOracle noLiq = _make(address(0));
        vm.expectRevert(StockEthOracle.NotLiquidator.selector);
        liquidator.armedPrice(noLiq);
        vm.warp(SAT_NOON);
        ethFeed.set(2700e8, SAT_NOON);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, WED_NOON - 1 hours));
        noLiq.price();
    }

    /// While armed, price() answers every caller as a liquidation, a borrow included. That is why the liquidator
    /// must disarm before any code outside Morpho runs, and arm only for this oracle's own markets.
    function test_armedWindowPricesEveryCaller() public {
        vm.warp(SAT_NOON);
        ethFeed.set(2700e8, SAT_NOON);
        assertEq(liquidator.armedPriceForSomeoneElse(oracle), oracle.liquidationPrice());
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, WED_NOON - 1 hours));
        liquidator.priceAfterDisarm(oracle);
    }

    /// Arming one oracle arms only that one.
    function test_armIsPerOracle() public {
        StockEthOracle other = _make(liq);
        vm.warp(SAT_NOON);
        ethFeed.set(2700e8, SAT_NOON);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, WED_NOON - 1 hours));
        liquidator.armOneReadOther(oracle, other);
    }

    /// The armed flag never outlives its transaction: armed and left armed in one transaction, the next is strict.
    /// This repo's Foundry config runs every top-level call of a test as its own transaction (isolate = true, see
    /// `forge config`), which is what makes this a real check.
    function test_armEndsWithTheTransaction() public {
        vm.warp(SAT_NOON);
        ethFeed.set(2700e8, SAT_NOON);
        liquidator.armAndLeave(oracle);
        vm.expectRevert(abi.encodeWithSelector(StockEthOracle.MarketClosed.selector, WED_NOON - 1 hours));
        oracle.price();
    }

    /// Whenever the strict price exists it equals the liquidation price, and the liquidation price is never below
    /// what the stock's last price gives.
    function testFuzz_modesAgree(uint32 dt, uint32 stockAge, uint16 poolGapBps, bool poolHigh) public {
        uint256 t = WED_NOON + bound(dt, 0, 21 days);
        vm.warp(t);
        stockAge = uint32(bound(stockAge, 0, 6 days));
        poolGapBps = uint16(bound(poolGapBps, 0, 1_000));
        stockFeed.set(180e8, t - stockAge);
        ethFeed.set(2700e8, t);
        uint256 cl = 2700e18;
        pool.set(poolHigh ? cl * (10_000 + poolGapBps) / 10_000 : cl * (10_000 - poolGapBps) / 10_000);
        uint256 base = _expected(180e8, 2700e8, 1.02e18);
        bool strictOk;
        try oracle.borrowPrice() returns (uint256 p) {
            strictOk = true;
            assertEq(p, base);
        } catch {}
        try oracle.liquidationPrice() returns (uint256 lp) {
            assertGe(lp, base);
            if (strictOk) assertEq(lp, base);
            else assertTrue(lp == base || lp == _expected(189e8, 2700e8, 1.02e18));
        } catch {
            assertGt(stockAge, 5 days);
        }
    }
}
