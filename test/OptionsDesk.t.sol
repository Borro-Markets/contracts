// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OptionsDesk, IShareVault} from "../src/OptionsDesk.sol";
import {MarketHours} from "../src/eth/MarketHours.sol";

contract OptTok is ERC20 {
    uint8 immutable dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        dec = d;
    }

    function decimals() public view override returns (uint8) {
        return dec;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// A Chainlink-shaped feed whose rounds the test sets. Round ids carry a phase in the top 16 bits, as the proxies do.
/// A round that was never set answers zero with no time; a round marked broken reverts, as the proxies do for a round
/// outside their history.
contract RoundFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;
    mapping(uint80 => bool) public broken;
    mapping(uint16 => address) public phaseAggregators;
    uint80 public latest;
    uint8 immutable dec;

    constructor(uint8 d) {
        dec = d;
    }

    function decimals() external view returns (uint8) {
        return dec;
    }

    function set(uint80 id, int256 answer, uint256 updatedAt) external {
        rounds[id] = Round(answer, updatedAt);
        if (id > latest) latest = id;
    }

    function setLatest(uint80 id) external {
        latest = id;
    }

    function setBroken(uint80 id, bool b) external {
        broken[id] = b;
    }

    function setPhaseAggregator(uint16 phase, address a) external {
        phaseAggregators[phase] = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latest];
        return (latest, r.answer, r.updatedAt, r.updatedAt, latest);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (broken[id]) revert("No data present");
        Round memory r = rounds[id];
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}

/// A phase's aggregator, as the proxy names it: only its last round number matters here.
contract MockAggregator {
    uint256 public latestRound;

    function set(uint256 r) external {
        latestRound = r;
    }
}

/// An ERC-4626-like vault with 18-decimal shares, Vault V2's virtual offset (`vs` virtual shares over one virtual
/// asset), and a way to hand it interest or a loss. With vs = 1 over an 18-decimal asset a share starts worth one
/// asset; with vs = 1e12 over 6-decimal USDG a share starts worth 1e-12 USDG, as Steakhouse's do.
contract RateVault is ERC20 {
    IERC20 public immutable asset;
    uint256 immutable vs;

    constructor(IERC20 a, uint256 vs_, string memory n) ERC20(n, n) {
        asset = a;
        vs = vs_;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets * (totalSupply() + vs) / (totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * (totalAssets() + 1) / (totalSupply() + vs);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return (assets * (totalSupply() + vs) + totalAssets()) / (totalAssets() + 1);
    }

    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(onBehalf, shares);
    }

    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares) {
        require(onBehalf == msg.sender, "not yours");
        shares = previewWithdraw(assets);
        _burn(onBehalf, shares);
        asset.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets) {
        require(onBehalf == msg.sender, "not yours");
        assets = convertToAssets(shares);
        _burn(onBehalf, shares);
        asset.transfer(receiver, assets);
    }

    /// Interest or rent arrives: the vault is simply worth more.
    function accrue(uint256 amount) external {
        OptTok(address(asset)).mint(address(this), amount);
    }

    /// A loss: the vault is simply worth less.
    function lose(uint256 amount) external {
        asset.transfer(address(0xdead), amount);
    }
}

/// A listed stock vault whose share transfers call back into the desk: the one way left to re-enter it, since longs
/// are minted without the receiver hook and nothing else here calls an untrusted contract.
contract ReenteringVault is RateVault {
    OptionsDesk public desk;
    bytes32 public series;
    uint256 public orderId;
    uint8 public mode; // 0 off, 1 release, 2 claim, 3 cancel
    bytes4 public seen;

    constructor(IERC20 a) RateVault(a, 1, "bEVIL") {}

    function arm(OptionsDesk d, bytes32 id, uint256 order, uint8 m) external {
        desk = d;
        series = id;
        orderId = order;
        mode = m;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 1) {
            try desk.release(series) {} catch (bytes memory err) { seen = bytes4(err); }
        } else if (mode == 2) {
            try desk.claim(series, 1, false) {} catch (bytes memory err) { seen = bytes4(err); }
        } else if (mode == 3) {
            try desk.cancel(orderId) {} catch (bytes memory err) { seen = bytes4(err); }
        }
        return super.transfer(to, amount);
    }
}

/// A buyer that is a plain contract: no ERC-1155 receiver hook, no fallback.
contract PlainBuyer {
    OptionsDesk immutable desk;

    constructor(OptionsDesk d, IERC20 usdg) {
        desk = d;
        usdg.approve(address(d), type(uint256).max);
    }

    function buy(uint256 orderId, uint128 units) external {
        desk.fillAsk(orderId, units, type(uint128).max);
    }

    function claim(bytes32 id, uint256 units) external returns (uint256) {
        return desk.claim(id, units, false);
    }
}

/// Every rule of docs/OPTIONS.md's OptionsDesk section, on mock feeds and mock vaults with a warped clock.
contract OptionsDeskTest is Test {
    uint256 constant NOW = 1791817200; // Monday 2026-10-12 11:00 New York (15:00 UTC)
    uint64 constant EXP = 1792195200; // Friday 2026-10-16 20:00 EDT = 2026-10-17 00:00:00 UTC
    uint64 constant EXP_W = 1797037200; // Friday 2026-12-11 20:00 EST = 2026-12-12 01:00:00 UTC
    uint64 constant XMAS = 1798246800; // Friday 2026-12-25 20:00 EST, Christmas: a holiday, still an expiry
    uint256 constant REOPEN = 1792368000; // Sunday 2026-10-18 20:00 EDT, when the feed prints again
    uint80 constant PHASE = uint80(1) << 64;
    uint80 constant R_OLD = PHASE | 9; // an earlier print
    uint80 constant R_LAST = PHASE | 10; // the last print before the close
    uint80 constant R_NEXT = PHASE | 11; // the Monday reopen print
    int256 constant REF = 180e8;
    uint128 constant K = 185e8; // 740 ticks
    uint128 constant PREM = 2e6; // 2 USDG per unit
    uint128 constant MIN = 1e15;

    OptTok usdg;
    OptTok stock;
    RateVault usdgVault;
    RateVault vault; // the stock's vault
    RoundFeed feed;
    OptionsDesk desk;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address ann = makeAddr("ann"); // writes covered calls from vault shares she holds
    address bob = makeAddr("bob"); // buys
    address carl = makeAddr("carl"); // writes puts from USDG vault shares he holds
    address dan = makeAddr("dan"); // writes from raw stock or raw USDG
    address eve = makeAddr("eve");

    function setUp() public {
        vm.warp(NOW);
        usdg = new OptTok("USDG", 6);
        stock = new OptTok("NVDA", 18);
        usdgVault = new RateVault(usdg, 1e12, "Steakhouse USDG");
        vault = new RateVault(stock, 1, "bNVDA");
        feed = new RoundFeed(8);
        feed.set(R_OLD, REF, NOW - 1 days);
        desk = new OptionsDesk(usdg, IShareVault(address(usdgVault)), owner);
        vm.startPrank(owner);
        desk.setStock(address(feed), IShareVault(address(vault)), true);
        desk.setFee(1000, keeper);
        vm.stopPrank();

        stock.mint(ann, 1_000e18);
        vm.startPrank(ann);
        stock.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18, ann);
        vault.approve(address(desk), type(uint256).max);
        vm.stopPrank();

        usdg.mint(carl, 10_000_000e6);
        vm.startPrank(carl);
        usdg.approve(address(usdgVault), type(uint256).max);
        usdgVault.deposit(10_000_000e6, carl);
        usdgVault.approve(address(desk), type(uint256).max);
        vm.stopPrank();

        usdg.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdg.approve(address(desk), type(uint256).max);

        stock.mint(dan, 1_000e18);
        usdg.mint(dan, 10_000_000e6);
        vm.startPrank(dan);
        stock.approve(address(desk), type(uint256).max);
        usdg.approve(address(desk), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _id(uint128 strike, bool isCall) internal view returns (bytes32) {
        return desk.seriesIdOf(address(feed), EXP, strike, isCall);
    }

    function _ask(address who, bool isCall, uint128 units, uint128 premium) internal returns (uint256 id) {
        vm.prank(who);
        id = desk.postAsk(address(feed), EXP, K, isCall, units, premium);
    }

    function _bid(address who, bool isCall, uint128 units, uint128 premium) internal returns (uint256 id) {
        vm.prank(who);
        id = desk.postBid(address(feed), EXP, K, isCall, units, premium);
    }

    function _fillAsk(address who, uint256 id, uint128 units) internal {
        vm.prank(who);
        desk.fillAsk(id, units, type(uint128).max);
    }

    /// The feed's last print before the close and the Monday reopen print, both at `price`; the clock on Monday.
    function _monday(int256 price) internal {
        feed.set(R_LAST, price, EXP - 2 hours);
        feed.set(R_NEXT, price, REOPEN + 30);
        vm.warp(REOPEN + 60);
    }

    function _settle(bytes32 id, int256 price) internal {
        _monday(price);
        desk.settle(id, R_LAST);
    }

    function _sharesUp(RateVault v, uint256 assets) internal view returns (uint256 s) {
        s = v.convertToShares(assets);
        if (v.convertToAssets(s) < assets) s += 1;
    }

    function _usdgFor(uint128 strike, uint128 units) internal pure returns (uint256) {
        return (uint256(units) * strike + 1e20 - 1) / 1e20;
    }

    // ------------------------------------------------------------------ construction and owner

    function test_constructor_checks_the_vault_and_sets_the_owner() public {
        assertEq(desk.owner(), owner);
        assertEq(address(desk.usdg()), address(usdg));
        assertEq(address(desk.usdgVault()), address(usdgVault));
        assertEq(desk.nextId(), 1);
        vm.expectRevert(OptionsDesk.BadVault.selector);
        new OptionsDesk(usdg, IShareVault(address(vault)), owner); // a vault of the stock, not of USDG
    }

    function test_only_the_owner_sets_things_and_within_bounds() public {
        vm.startPrank(eve);
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve);
        vm.expectRevert(denied);
        desk.setStock(address(feed), IShareVault(address(vault)), false);
        vm.expectRevert(denied);
        desk.setFee(1, eve);
        vm.expectRevert(denied);
        desk.setPaused(true);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(OptionsDesk.BadValue.selector);
        desk.setFee(2001, keeper); // Borro's share never passes 20%
        vm.expectRevert(OptionsDesk.BadValue.selector);
        desk.setFee(100, address(0));
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.FeeSet(2000, eve);
        desk.setFee(2000, eve);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.PausedSet(true);
        desk.setPaused(true);
        vm.stopPrank();
        assertEq(desk.feeBps(), 2000);
        assertEq(desk.feeRecipient(), eve);
        assertTrue(desk.paused());
    }

    function test_setStock_fixes_the_vault_and_checks_the_feed() public {
        RoundFeed other = new RoundFeed(8);
        RoundFeed notStock = new RoundFeed(18);
        RateVault otherVault = new RateVault(new OptTok("TSLA", 18), 1, "bTSLA");
        vm.startPrank(owner);
        vm.expectRevert(OptionsDesk.BadFeed.selector);
        desk.setStock(address(0), IShareVault(address(otherVault)), true);
        vm.expectRevert(OptionsDesk.BadFeed.selector);
        desk.setStock(address(notStock), IShareVault(address(otherVault)), true); // not a stock feed
        vm.expectRevert(OptionsDesk.BadVault.selector);
        desk.setStock(address(other), IShareVault(address(0)), true);
        vm.expectRevert(OptionsDesk.BadVault.selector);
        desk.setStock(address(other), IShareVault(address(usdgVault)), true); // the USDG vault is not a stock's
        vm.expectRevert(); // not a vault at all: asset() does not answer
        desk.setStock(address(other), IShareVault(address(0xBEEF)), true);
        // A feed's vault is fixed the first time: the owner can never point it elsewhere.
        vm.expectRevert(OptionsDesk.BadVault.selector);
        desk.setStock(address(feed), IShareVault(address(otherVault)), true);
        vm.expectRevert(OptionsDesk.BadVault.selector);
        desk.setStock(address(feed), IShareVault(address(0)), true);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.StockSet(address(other), address(otherVault), true);
        desk.setStock(address(other), IShareVault(address(otherVault)), true);
        (address f, IShareVault v, bool allowed) = desk.stocks(address(other));
        assertEq(f, address(other));
        assertEq(address(v), address(otherVault));
        assertTrue(allowed);
        desk.setStock(address(other), IShareVault(address(otherVault)), false);
        (,, allowed) = desk.stocks(address(other));
        assertFalse(allowed);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ expiries

    function test_expiry_is_friday_eight_pm_new_york_in_both_regimes_and_on_a_holiday() public view {
        assertTrue(desk.isExpiry(EXP), "summer: 00:00 UTC Saturday");
        assertFalse(desk.isExpiry(EXP - 1));
        assertFalse(desk.isExpiry(EXP + 1));
        assertFalse(desk.isExpiry(EXP + 1 hours), "01:00 UTC is 21:00 EDT");
        assertFalse(desk.isExpiry(EXP - 1 days), "Thursday 20:00");
        assertFalse(desk.isExpiry(EXP + 1 days), "Saturday 20:00");
        assertFalse(desk.isExpiry(uint64(REOPEN)), "Sunday 20:00");
        assertTrue(desk.isExpiry(EXP_W), "winter: 01:00 UTC Saturday");
        assertFalse(desk.isExpiry(EXP_W - 1 hours), "00:00 UTC is 19:00 EST");
        assertTrue(desk.isExpiry(XMAS), "a holiday Friday still expires at the Saturday boundary");
        assertTrue(MarketHours.isHoliday(MarketHours.tradingDate(XMAS - 1)));
        assertTrue(desk.isExpiry(1794013200), "the first winter Friday, 2026-11-06");
        assertFalse(desk.isExpiry(1794013200 - 1 hours));
        assertEq(desk.expiryAfter(uint64(NOW)), EXP);
        assertEq(desk.expiryAfter(EXP - 1), EXP);
        assertEq(desk.expiryAfter(EXP), EXP + 7 days, "an expiry's next is a week on");
        assertEq(desk.expiryAfter(EXP + 1), EXP + 7 days);
        assertEq(desk.expiryAfter(1796432400 + 3 days), EXP_W, "into December, winter");
        assertEq(desk.expiryAfter(1804899600), 1805500800, "across the March 2027 switch: 01:00 UTC then 00:00 UTC");
    }

    function test_orders_name_a_valid_expiry_in_the_window() public {
        vm.startPrank(ann);
        vm.expectRevert(OptionsDesk.BadExpiry.selector);
        desk.postAsk(address(feed), EXP + 1, K, true, 1e18, PREM);
        vm.expectRevert(OptionsDesk.BadExpiry.selector);
        desk.postAsk(address(feed), EXP - 1 days, K, true, 1e18, PREM); // a Thursday
        vm.expectRevert(OptionsDesk.BadExpiry.selector);
        desk.postAsk(address(feed), EXP + 7 weeks, K, true, 1e18, PREM); // 00:00 UTC in December is 19:00 New York
        vm.expectRevert(OptionsDesk.BadExpiry.selector);
        desk.postAsk(address(feed), EXP_W, K, true, 1e18, PREM); // past MAX_WEEKS
        vm.expectRevert(OptionsDesk.TooLate.selector);
        desk.postAsk(address(feed), EXP - 7 days, K, true, 1e18, PREM); // last Friday
        desk.postAsk(address(feed), EXP + 2 weeks, K, true, 1e18, PREM); // still summer
        desk.postAsk(address(feed), 1796432400, K, true, 1e18, PREM); // 2026-12-04 20:00 EST, the eighth Friday out
        vm.stopPrank();
        // Winter.
        vm.warp(EXP_W - 2 weeks);
        vm.startPrank(ann);
        vm.expectRevert(OptionsDesk.BadExpiry.selector);
        desk.postAsk(address(feed), EXP_W - 1 hours, K, true, 1e18, PREM);
        desk.postAsk(address(feed), EXP_W, K, true, 1e18, PREM);
        vm.stopPrank();
        // Christmas is a holiday Friday: it is still an expiry.
        vm.warp(XMAS - 3 weeks);
        vm.prank(ann);
        desk.postAsk(address(feed), XMAS, K, true, 1e18, PREM);
        // The last hour before expiry belongs to settlement.
        vm.warp(XMAS - 1 hours);
        vm.prank(ann);
        desk.postAsk(address(feed), XMAS, K, true, 1e18, PREM);
        vm.warp(XMAS - 1 hours + 1);
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.TooLate.selector);
        desk.postAsk(address(feed), XMAS, K, true, 1e18, PREM);
    }

    // ------------------------------------------------------------------ posting

    function test_postAsk_call_locks_stock_vault_shares_rounded_up() public {
        bytes32 id = _id(K, true);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.SeriesOpened(id, address(feed), EXP, K, true);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Posted(1, ann, id, true, 10e18, PREM, 10e18);
        uint256 orderId = _ask(ann, true, 10e18, PREM);
        assertEq(orderId, 1);
        assertEq(vault.balanceOf(address(desk)), 10e18, "one share per unit at a 1:1 rate");
        assertEq(vault.balanceOf(ann), 990e18);
        OptionsDesk.Order memory o = desk.orderOf(orderId);
        assertEq(o.maker, ann);
        assertEq(o.series, id);
        assertTrue(o.isAsk);
        assertEq(o.units, 10e18);
        assertEq(o.premium, PREM);
        assertEq(o.locked, 10e18);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        assertEq(sr.feed, address(feed));
        assertEq(sr.expiry, EXP);
        assertEq(sr.strike, K);
        assertTrue(sr.isCall);
        assertEq(sr.openUnits, 0, "nothing written until a fill");

        // Rent arrives: a share is worth more, so fewer shares cover a unit, rounded up.
        vault.accrue(100e18); // the vault's 1000 stock become 1100
        uint256 want = _sharesUp(vault, 7e18);
        assertLt(want, 7e18);
        assertGe(vault.convertToAssets(want), 7e18, "the lock covers the units");
        assertEq(desk.collateralFor(address(feed), K, true, 7e18), want);
        uint256 before = vault.balanceOf(address(desk));
        _ask(ann, true, 7e18, PREM);
        assertEq(vault.balanceOf(address(desk)) - before, want);
    }

    function test_postAsk_put_locks_usdg_vault_shares_worth_the_strike() public {
        uint256 want = _sharesUp(usdgVault, _usdgFor(K, 3e18)); // 555 USDG
        assertEq(_usdgFor(K, 3e18), 555e6);
        assertEq(desk.collateralFor(address(feed), K, false, 3e18), want);
        uint256 orderId = _ask(carl, false, 3e18, PREM);
        assertEq(usdgVault.balanceOf(address(desk)), want);
        assertGe(usdgVault.convertToAssets(want), 555e6);
        OptionsDesk.Order memory o = desk.orderOf(orderId);
        assertEq(o.locked, want);
        assertFalse(desk.seriesOf(_id(K, false)).isCall);
    }

    function test_postAskWithUsdg_deposits_for_the_writer() public {
        uint256 before = usdg.balanceOf(dan);
        vm.prank(dan);
        uint256 orderId = desk.postAskWithUsdg(address(feed), EXP, K, 3e18, PREM);
        assertEq(before - usdg.balanceOf(dan), 555e6, "the strike's worth in USDG");
        uint256 shares = desk.orderOf(orderId).locked;
        assertEq(usdgVault.balanceOf(address(desk)), shares, "the deposit's shares are the lock");
        assertApproxEqAbs(usdgVault.convertToAssets(shares), 555e6, 1);
        assertEq(usdg.balanceOf(address(desk)), 0, "no USDG stays in the desk");
        assertFalse(desk.seriesOf(desk.orderOf(orderId).series).isCall);
    }

    function test_postAskWithStock_lends_for_the_writer() public {
        vm.prank(dan);
        uint256 orderId = desk.postAskWithStock(address(feed), EXP, K, 4e18, PREM);
        assertEq(stock.balanceOf(dan), 996e18);
        assertEq(stock.balanceOf(address(vault)), 1_004e18, "lent into the vault");
        assertEq(stock.balanceOf(address(desk)), 0);
        uint256 shares = desk.orderOf(orderId).locked;
        assertEq(vault.balanceOf(address(desk)), shares);
        assertEq(shares, 4e18);
        assertTrue(desk.seriesOf(desk.orderOf(orderId).series).isCall);
    }

    function test_postBid_locks_the_premium() public {
        bytes32 id = _id(K, true);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Posted(1, bob, id, false, 5e18, PREM, 10e6);
        uint256 orderId = _bid(bob, true, 5e18, PREM);
        assertEq(usdg.balanceOf(address(desk)), 10e6, "5 units at 2 USDG");
        OptionsDesk.Order memory o = desk.orderOf(orderId);
        assertFalse(o.isAsk);
        assertEq(o.locked, 10e6);
        // A premium that rounds to nothing locks nothing: refused.
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.Nothing.selector);
        desk.postBid(address(feed), EXP, K, true, MIN, 1);
    }

    function test_order_guards() public {
        vm.startPrank(ann);
        vm.expectRevert(OptionsDesk.NotAllowed.selector);
        desk.postAsk(address(0xFEED), EXP, K, true, 1e18, PREM); // never listed
        vm.expectRevert(OptionsDesk.BadStrike.selector);
        desk.postAsk(address(feed), EXP, 0, true, 1e18, PREM);
        vm.expectRevert(OptionsDesk.BadStrike.selector);
        desk.postAsk(address(feed), EXP, K + 1, true, 1e18, PREM); // off the $0.25 tick
        vm.expectRevert(OptionsDesk.TooSmall.selector);
        desk.postAsk(address(feed), EXP, K, true, MIN - 1, PREM);
        vm.expectRevert(OptionsDesk.BadValue.selector);
        desk.postAsk(address(feed), EXP, K, true, 1e18, 0);
        vm.stopPrank();
        vm.prank(owner);
        desk.setStock(address(feed), IShareVault(address(vault)), false);
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.NotAllowed.selector);
        desk.postAsk(address(feed), EXP, K, true, 1e18, PREM);
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.NotAllowed.selector);
        desk.postBid(address(feed), EXP, K, true, 1e18, PREM);
        vm.prank(owner);
        desk.setStock(address(feed), IShareVault(address(vault)), true);
        vm.prank(owner);
        desk.setPaused(true);
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.Paused.selector);
        desk.postAsk(address(feed), EXP, K, true, 1e18, PREM);
        vm.prank(dan);
        vm.expectRevert(OptionsDesk.Paused.selector);
        desk.postAskWithStock(address(feed), EXP, K, 1e18, PREM);
        vm.prank(dan);
        vm.expectRevert(OptionsDesk.Paused.selector);
        desk.postAskWithUsdg(address(feed), EXP, K, 1e18, PREM);
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.Paused.selector);
        desk.postBid(address(feed), EXP, K, true, 1e18, PREM);
    }

    // ------------------------------------------------------------------ fills

    function test_fillAsk_pays_the_writer_less_the_fee_and_mints_the_long() public {
        bytes32 id = _id(K, true);
        uint256 orderId = _ask(ann, true, 10e18, PREM);
        uint256 annBefore = usdg.balanceOf(ann);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Filled(orderId, id, ann, bob, 10e18, 20e6, 2e6, 10e18);
        vm.prank(bob);
        desk.fillAsk(orderId, 10e18, 20e6);
        assertEq(usdg.balanceOf(ann) - annBefore, 18e6, "the premium less 10%");
        assertEq(usdg.balanceOf(keeper), 2e6, "the fee");
        assertEq(usdg.balanceOf(bob), 1_000_000e6 - 20e6);
        assertEq(desk.balanceOf(bob, uint256(id)), 10e18, "the long is an ERC-1155 balance");
        assertEq(desk.orderOf(orderId).maker, address(0), "the order is gone");
        OptionsDesk.Written memory w = desk.writtenOf(ann, id);
        assertEq(w.units, 10e18);
        assertEq(w.lockedShares, 10e18);
        assertFalse(w.released);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        assertEq(sr.openUnits, 10e18);
        assertEq(sr.lockedShares, 10e18);
        assertEq(sr.minLockPerUnit, 1e18);
        assertFalse(sr.settled);
    }

    function test_fillAsk_partial_fills_move_the_lock_pro_rata() public {
        bytes32 id = _id(K, true);
        vault.accrue(37e18); // an uneven rate, so the lock is not a round number
        uint256 orderId = _ask(ann, true, 10e18, PREM);
        uint256 lock = desk.orderOf(orderId).locked;
        _fillAsk(bob, orderId, 3e18);
        OptionsDesk.Order memory o = desk.orderOf(orderId);
        assertEq(o.units, 7e18);
        assertEq(o.locked, lock - lock * 3 / 10);
        assertEq(desk.writtenOf(ann, id).lockedShares, lock * 3 / 10);
        _fillAsk(bob, orderId, 2e18);
        _fillAsk(bob, orderId, 5e18); // the rest: whatever is left moves, nothing is stranded
        assertEq(desk.orderOf(orderId).maker, address(0));
        assertEq(desk.writtenOf(ann, id).units, 10e18);
        assertEq(desk.writtenOf(ann, id).lockedShares, lock, "the whole lock is now written");
        assertEq(desk.seriesOf(id).lockedShares, lock);
        assertEq(desk.seriesOf(id).openUnits, 10e18);
        assertEq(desk.balanceOf(bob, uint256(id)), 10e18);
        assertEq(usdg.balanceOf(keeper), 2e6);
    }

    function test_fill_guards() public {
        uint256 askId = _ask(ann, true, 10e18, PREM);
        uint256 bidId = _bid(bob, true, 10e18, PREM);
        vm.startPrank(bob);
        vm.expectRevert(OptionsDesk.NoOrder.selector);
        desk.fillAsk(99, 1e18, type(uint128).max);
        vm.expectRevert(OptionsDesk.WrongSide.selector);
        desk.fillAsk(bidId, 1e18, type(uint128).max);
        vm.expectRevert(OptionsDesk.BadValue.selector);
        desk.fillAsk(askId, 0, type(uint128).max);
        vm.expectRevert(OptionsDesk.BadValue.selector);
        desk.fillAsk(askId, 10e18 + 1, type(uint128).max);
        vm.expectRevert(OptionsDesk.TooSmall.selector);
        desk.fillAsk(askId, MIN - 1, type(uint128).max);
        vm.expectRevert(OptionsDesk.TooSmall.selector);
        desk.fillAsk(askId, 10e18 - MIN + 1, type(uint128).max); // would leave less than MIN_UNITS
        vm.expectRevert(abi.encodeWithSelector(OptionsDesk.TooMuch.selector, 2e6, 2e6 - 1));
        desk.fillAsk(askId, 1e18, 2e6 - 1);
        vm.stopPrank();
        vm.startPrank(ann);
        vm.expectRevert(OptionsDesk.WrongSide.selector);
        desk.fillBid(askId, 1e18, 0);
        vm.expectRevert(abi.encodeWithSelector(OptionsDesk.TooLittle.selector, 1.8e6, 1.8e6 + 1));
        desk.fillBid(bidId, 1e18, 1.8e6 + 1); // the floor is on what the writer nets
        vm.expectRevert(OptionsDesk.WrongSide.selector);
        desk.fillBidWithUsdg(bidId, 1e18, 0); // a call is not paid for in USDG
        vm.stopPrank();
        uint256 putBid = _bid(bob, false, 1e18, PREM);
        vm.prank(dan);
        vm.expectRevert(OptionsDesk.WrongSide.selector);
        desk.fillBidWithStock(putBid, 1e18, 0); // a put is not paid for in stock

        vm.prank(owner);
        desk.setPaused(true);
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.Paused.selector);
        desk.fillAsk(askId, 1e18, type(uint128).max);
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.Paused.selector);
        desk.fillBid(bidId, 1e18, 0);
        vm.prank(owner);
        desk.setPaused(false);

        // The last hour before expiry belongs to settlement.
        vm.warp(EXP - 1 hours);
        _fillAsk(bob, askId, 1e18);
        vm.warp(EXP - 1 hours + 1);
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.TooLate.selector);
        desk.fillAsk(askId, 1e18, type(uint128).max);
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.TooLate.selector);
        desk.fillBid(bidId, 1e18, 0);
    }

    function test_fillBid_locks_the_writers_collateral_and_pays_the_bids_premium() public {
        bytes32 id = _id(K, true);
        uint256 bidId = _bid(bob, true, 10e18, PREM); // 20 USDG locked
        uint256 annBefore = usdg.balanceOf(ann);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Filled(bidId, id, ann, bob, 4e18, 8e6, 0.8e6, 4e18);
        vm.prank(ann);
        desk.fillBid(bidId, 4e18, 7.2e6);
        assertEq(usdg.balanceOf(ann) - annBefore, 7.2e6);
        assertEq(usdg.balanceOf(keeper), 0.8e6);
        assertEq(usdg.balanceOf(address(desk)), 12e6, "the rest of the bid stays locked");
        assertEq(vault.balanceOf(address(desk)), 4e18, "the writer's lock");
        assertEq(desk.balanceOf(bob, uint256(id)), 4e18);
        assertEq(desk.orderOf(bidId).units, 6e18);
        assertEq(desk.orderOf(bidId).locked, 12e6);
        assertEq(desk.writtenOf(ann, id).lockedShares, 4e18);
        // A put bid, filled from USDG vault shares.
        bytes32 pid = _id(K, false);
        uint256 putBid = _bid(bob, false, 2e18, PREM);
        uint256 want = _sharesUp(usdgVault, 370e6);
        vm.prank(carl);
        desk.fillBid(putBid, 2e18, 0);
        assertEq(usdgVault.balanceOf(address(desk)), want);
        assertEq(desk.writtenOf(carl, pid).lockedShares, want);
        assertEq(desk.balanceOf(bob, uint256(pid)), 2e18);
        assertEq(desk.orderOf(putBid).maker, address(0));
    }

    function test_fillBidWithUsdg_and_fillBidWithStock_deposit_for_the_writer() public {
        uint256 putBid = _bid(bob, false, 2e18, PREM);
        uint256 danUsdg = usdg.balanceOf(dan);
        vm.prank(dan);
        desk.fillBidWithUsdg(putBid, 2e18, 0);
        // 370 USDG in as collateral, 3.6 USDG back as premium.
        assertEq(danUsdg - usdg.balanceOf(dan), 370e6 - 3.6e6);
        uint256 shares = desk.writtenOf(dan, _id(K, false)).lockedShares;
        assertEq(usdgVault.balanceOf(address(desk)), shares);
        assertApproxEqAbs(usdgVault.convertToAssets(shares), 370e6, 1);
        assertEq(usdg.balanceOf(address(desk)), 0);

        uint256 callBid = _bid(bob, true, 5e18, PREM);
        vm.prank(dan);
        desk.fillBidWithStock(callBid, 5e18, 0);
        assertEq(stock.balanceOf(dan), 995e18);
        assertEq(vault.balanceOf(address(desk)), 5e18);
        assertEq(desk.writtenOf(dan, _id(K, true)).lockedShares, 5e18);
        assertEq(desk.balanceOf(bob, uint256(_id(K, true))), 5e18);
    }

    function test_fee_can_be_zero_or_twenty_percent() public {
        vm.prank(owner);
        desk.setFee(0, keeper);
        uint256 a = _ask(ann, true, 1e18, PREM);
        uint256 annBefore = usdg.balanceOf(ann);
        _fillAsk(bob, a, 1e18);
        assertEq(usdg.balanceOf(ann) - annBefore, 2e6, "the whole premium");
        assertEq(usdg.balanceOf(keeper), 0);
        vm.prank(owner);
        desk.setFee(2000, keeper);
        uint256 b = _ask(ann, true, 1e18, PREM);
        annBefore = usdg.balanceOf(ann);
        _fillAsk(bob, b, 1e18);
        assertEq(usdg.balanceOf(ann) - annBefore, 1.6e6);
        assertEq(usdg.balanceOf(keeper), 0.4e6);
    }

    function test_switching_a_stock_off_stops_new_orders_only() public {
        uint256 askId = _ask(ann, true, 2e18, PREM);
        uint256 bidId = _bid(bob, true, 2e18, PREM);
        vm.prank(owner);
        desk.setStock(address(feed), IShareVault(address(vault)), false);
        _fillAsk(bob, askId, 2e18);
        vm.prank(ann);
        desk.fillBid(bidId, 2e18, 0);
        assertEq(desk.seriesOf(_id(K, true)).openUnits, 4e18);
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.NotAllowed.selector);
        desk.postAsk(address(feed), EXP, K, true, 1e18, PREM);
    }

    // ------------------------------------------------------------------ cancels

    function test_cancel_returns_the_lock_to_the_maker() public {
        uint256 askId = _ask(ann, true, 10e18, PREM);
        uint256 bidId = _bid(bob, true, 10e18, PREM);
        _fillAsk(bob, askId, 3e18); // part of each is taken first
        vm.prank(ann);
        desk.fillBid(bidId, 4e18, 0);
        uint256 annShares = vault.balanceOf(ann);
        uint256 bobUsdg = usdg.balanceOf(bob);
        vm.startPrank(eve);
        vm.expectRevert(OptionsDesk.NotMaker.selector);
        desk.cancel(askId);
        vm.expectRevert(OptionsDesk.NotMaker.selector);
        desk.cancel(bidId);
        vm.expectRevert(OptionsDesk.NoOrder.selector);
        desk.cancel(99);
        vm.stopPrank();
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Cancelled(askId, ann, ann, 7e18);
        vm.prank(ann);
        desk.cancel(askId);
        assertEq(vault.balanceOf(ann) - annShares, 7e18, "the unfilled part's shares");
        vm.prank(bob);
        desk.cancel(bidId);
        assertEq(usdg.balanceOf(bob) - bobUsdg, 12e6, "the unfilled part's premium");
        assertEq(desk.orderOf(askId).maker, address(0));
        assertEq(desk.orderOf(bidId).maker, address(0));
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.NoOrder.selector);
        desk.cancel(askId);
        // What was written stays written.
        assertEq(desk.seriesOf(_id(K, true)).openUnits, 7e18);
        assertEq(vault.balanceOf(address(desk)), 7e18);
        assertEq(usdg.balanceOf(address(desk)), 0);
        // Cancels work while paused.
        uint256 again = _ask(ann, true, 1e18, PREM);
        vm.prank(owner);
        desk.setPaused(true);
        vm.prank(ann);
        desk.cancel(again);
    }

    function test_anyone_cancels_an_order_of_an_expired_series() public {
        uint256 askId = _ask(carl, false, 2e18, PREM);
        uint256 bidId = _bid(bob, false, 2e18, PREM);
        vm.warp(EXP - 1);
        vm.prank(eve);
        vm.expectRevert(OptionsDesk.NotMaker.selector);
        desk.cancel(askId);
        vm.warp(EXP + 1);
        uint256 carlShares = usdgVault.balanceOf(carl);
        uint256 bobUsdg = usdg.balanceOf(bob);
        vm.startPrank(eve);
        desk.cancel(askId);
        desk.cancel(bidId);
        vm.stopPrank();
        assertEq(usdgVault.balanceOf(carl) - carlShares, _sharesUp(usdgVault, 370e6), "back to the maker, not the caller");
        assertEq(usdg.balanceOf(bob) - bobUsdg, 4e6);
        assertEq(usdgVault.balanceOf(eve), 0);
        assertEq(usdg.balanceOf(eve), 0);
    }

    // ------------------------------------------------------------------ settlement

    function test_settle_call_pays_the_move_above_the_strike_in_shares() public {
        bytes32 id = _id(K, true);
        uint256 askId = _ask(ann, true, 10e18, PREM);
        _fillAsk(bob, askId, 10e18);
        vault.accrue(50e18); // rent while the call is live: 1010 stock in the vault is now 1060
        vm.warp(EXP - 1);
        vm.expectRevert(OptionsDesk.NotExpired.selector);
        desk.settle(id, R_LAST);
        _monday(200e8); // 15 above the strike
        uint256 intrinsic = uint256(15e8) * 1e18 / 200e8; // 0.075 of a unit per unit
        uint256 perUnit = vault.convertToShares(intrinsic);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Settled(id, R_LAST, 200e8, perUnit, 0);
        desk.settle(id, R_LAST);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        assertTrue(sr.settled);
        assertEq(sr.settlePrice, 200e8);
        assertEq(sr.payoutSharesPerUnit, perUnit);
        assertEq(sr.payoutUsdgPerUnit, 0);
        assertLt(perUnit, 0.075e18, "fewer shares than units, since a share is now worth more");
        (uint256 shares, uint256 usdgOut) = desk.payoutOf(id, 10e18);
        assertEq(shares, 10 * perUnit);
        assertEq(usdgOut, 0);
        vm.expectRevert(OptionsDesk.AlreadySettled.selector);
        desk.settle(id, R_LAST);

        // The buyer claims in vault shares worth the move; the writer takes back the rest, and the desk is empty.
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Claimed(id, bob, 10e18, 10 * perUnit, 0);
        vm.prank(bob);
        uint256 paid = desk.claim(id, 10e18, false);
        assertEq(paid, 10 * perUnit);
        assertEq(vault.balanceOf(bob), 10 * perUnit);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)), 0.75e18, 20, "0.075 stock per unit on ten units");
        assertEq(desk.balanceOf(bob, uint256(id)), 0, "burned");
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Released(id, ann, 10e18 - 10 * perUnit);
        vm.prank(ann);
        uint256 back = desk.release(id);
        assertEq(back, 10e18 - 10 * perUnit);
        assertEq(vault.balanceOf(address(desk)), 0, "nothing left");
        assertTrue(desk.writtenOf(ann, id).released);
    }

    function test_settle_put_pays_the_move_below_the_strike_in_usdg() public {
        bytes32 id = _id(K, false);
        uint256 askId = _ask(carl, false, 10e18, PREM);
        _fillAsk(bob, askId, 10e18);
        uint256 lock = desk.seriesOf(id).lockedShares;
        usdgVault.accrue(100_000e6); // interest while the put is live
        _monday(170e8); // 15 below the strike
        uint256 perUnitUsdg = 15e6;
        uint256 perUnit = _sharesUp(usdgVault, perUnitUsdg);
        desk.settle(id, R_LAST);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        assertEq(sr.settlePrice, 170e8);
        assertEq(sr.payoutUsdgPerUnit, perUnitUsdg);
        assertEq(sr.payoutSharesPerUnit, perUnit);
        (uint256 shares, uint256 usdgOut) = desk.payoutOf(id, 10e18);
        assertEq(shares, 10 * perUnit);
        assertEq(usdgOut, 150e6);

        // Half claimed in USDG, redeemed out of the vault; half as the vault's shares.
        uint256 bobUsdg = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = desk.claim(id, 5e18, false);
        assertEq(usdg.balanceOf(bob) - bobUsdg, paid);
        assertApproxEqAbs(paid, 75e6, 1, "75 USDG");
        usdgVault.accrue(100_000e6); // more interest before the second claim: the shares are worth more
        vm.prank(bob);
        paid = desk.claim(id, 5e18, true);
        assertEq(paid, 5 * perUnit);
        assertEq(usdgVault.balanceOf(bob), 5 * perUnit);
        assertGt(usdgVault.convertToAssets(5 * perUnit), 75e6, "the payout plus what it earned since settlement");
        assertEq(desk.balanceOf(bob, uint256(id)), 0);
        vm.prank(carl);
        uint256 back = desk.release(id);
        assertEq(back, lock - 10 * perUnit);
        assertEq(usdgVault.balanceOf(address(desk)), 0);
        assertEq(usdg.balanceOf(address(desk)), 0);
    }

    function test_settle_out_of_the_money_pays_nothing_and_releases_the_whole_lock() public {
        bytes32 cid = _id(K, true);
        bytes32 pid = _id(K, false);
        _fillAsk(bob, _ask(ann, true, 3e18, PREM), 3e18);
        _fillAsk(bob, _ask(carl, false, 3e18, PREM), 3e18);
        uint256 putLock = desk.seriesOf(pid).lockedShares;
        _monday(K == 185e8 ? int256(185e8) : int256(0)); // exactly at the strike: neither side is in the money
        desk.settle(cid, R_LAST);
        desk.settle(pid, R_LAST);
        assertEq(desk.seriesOf(cid).payoutSharesPerUnit, 0);
        assertEq(desk.seriesOf(pid).payoutSharesPerUnit, 0);
        assertEq(desk.seriesOf(pid).payoutUsdgPerUnit, 0);
        vm.startPrank(bob);
        assertEq(desk.claim(cid, 3e18, false), 0);
        assertEq(desk.claim(pid, 3e18, false), 0);
        vm.stopPrank();
        vm.prank(ann);
        assertEq(desk.release(cid), 3e18);
        vm.prank(carl);
        assertEq(desk.release(pid), putLock);
        assertEq(vault.balanceOf(address(desk)), 0);
        assertEq(usdgVault.balanceOf(address(desk)), 0);
    }

    function test_settle_an_unwritten_series_records_the_price() public {
        bytes32 id = _id(K, true);
        vm.expectRevert(OptionsDesk.NoSeries.selector);
        desk.settle(id, R_LAST); // never opened
        uint256 askId = _ask(ann, true, 1e18, PREM);
        vm.prank(ann);
        desk.cancel(askId);
        _settle(id, 500e8);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        assertTrue(sr.settled);
        assertEq(sr.settlePrice, 500e8);
        assertEq(sr.openUnits, 0);
        assertEq(sr.payoutSharesPerUnit, vault.convertToShares(uint256(315e8) * 1e18 / 500e8), "no fill, no cap");
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.Nothing.selector);
        desk.release(id);
    }

    function test_settle_only_with_the_last_round_at_or_before_expiry() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        feed.set(R_LAST, 190e8, EXP - 2 hours);
        feed.set(R_NEXT, 200e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_NEXT); // printed after expiry
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_OLD); // the round after it printed before expiry too
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, PHASE | 7); // never printed: no answer
        // A print on expiry itself is the last print, and the one before it is not.
        feed.set(PHASE | 12, 195e8, EXP);
        feed.set(PHASE | 13, 205e8, REOPEN + 40);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_NEXT);
        desk.settle(id, PHASE | 12);
        assertEq(desk.seriesOf(id).settlePrice, 195e8);
    }

    function test_settle_refuses_a_stale_or_broken_price() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        feed.set(R_LAST, 190e8, EXP - 2 days);
        feed.set(R_NEXT, 200e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_LAST); // two days before expiry is not the close
        feed.set(R_LAST, 0, EXP - 2 hours);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_LAST); // no answer
        feed.set(R_LAST, -1, EXP - 2 hours);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_LAST);
        feed.set(R_LAST, 190e8, EXP - 2 days + 1);
        desk.settle(id, R_LAST); // just inside FEED_MAX_AGE
        assertEq(desk.seriesOf(id).settlePrice, 190e8);
    }

    function test_settle_with_the_latest_round_while_no_round_follows_it() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        feed.set(R_LAST, 190e8, EXP - 2 hours); // nothing after it: the weekend
        vm.warp(EXP);
        vm.expectRevert(OptionsDesk.NotExpired.selector);
        desk.settle(id, R_LAST); // the expiry second itself is too soon: a print could still land in it
        vm.warp(EXP + 1);
        feed.setLatest(R_OLD); // the feed says another round is its latest: not proven
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_LAST);
        feed.setLatest(R_LAST);
        vm.warp(EXP + 10 days); // any time after expiry, as long as nothing has printed since
        desk.settle(id, R_LAST);
        assertEq(desk.seriesOf(id).settlePrice, 190e8);
    }

    function test_settle_treats_a_next_round_that_reverts_as_missing() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        feed.set(R_LAST, 190e8, EXP - 2 hours);
        feed.setBroken(R_NEXT, true); // the proxy reverts for a round outside its history
        vm.warp(EXP + 1);
        feed.setLatest(R_OLD);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_LAST);
        feed.setLatest(R_LAST);
        desk.settle(id, R_LAST);
        assertEq(desk.seriesOf(id).settlePrice, 190e8);
    }

    function test_settle_across_a_phase_boundary() public {
        bytes32 id = _id(K, true);
        bytes32 id2 = desk.seriesIdOf(address(feed), EXP, K + 25_000_000, true);
        bytes32 id3 = desk.seriesIdOf(address(feed), EXP, K + 50_000_000, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        _fillAsk(bob, _ask2(K + 25_000_000), 1e18);
        _fillAsk(bob, _ask2(K + 50_000_000), 1e18);
        // The last round of phase 1 (its aggregator's round number at the top of uint64) printed before expiry;
        // phase 2's first round is the Monday print.
        uint80 last = PHASE | type(uint64).max;
        uint80 first2 = (uint80(2) << 64) | 1;
        feed.set(last, 190e8, EXP - 2 hours);
        feed.set(first2, 200e8, REOPEN + 30);
        MockAggregator agg = new MockAggregator();
        feed.setPhaseAggregator(1, address(agg));
        agg.set(type(uint64).max); // phase 1's last round, which the fallback finds printed inside the window
        vm.warp(REOPEN + 60);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, first2);
        desk.settle(id, last);
        assertEq(desk.seriesOf(id).settlePrice, 190e8);

        // Phase 2 began before expiry: phase 1's last round is not the last print.
        feed.set(first2, 200e8, EXP - 1 hours);
        feed.set(first2 + 1, 210e8, REOPEN + 30);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id2, last);
        desk.settle(id2, first2);
        assertEq(desk.seriesOf(id2).settlePrice, 200e8);

        // A phase's last round with no next phase yet: the latest-round proof.
        feed.setBroken(first2, true); // phase 2 does not exist
        feed.setLatest(R_OLD);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id3, last);
        feed.setLatest(last);
        desk.settle(id3, last);
        assertEq(desk.seriesOf(id3).settlePrice, 190e8);
    }

    function _ask2(uint128 strike) internal returns (uint256 id) {
        vm.prank(ann);
        id = desk.postAsk(address(feed), EXP, strike, true, 1e18, PREM);
    }

    function test_call_payout_is_capped_by_the_lock_after_a_vault_loss() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 10e18, PREM), 10e18); // 10 shares locked at 1:1
        vault.lose(500e18); // the vault loses half: a share is worth half a stock
        _monday(1_000e8); // deep in the money: 0.815 stock per unit, 1.63 shares per unit at the new rate
        uint256 wanted = vault.convertToShares(uint256(815e8) * 1e18 / 1_000e8);
        assertGt(wanted, 1e18);
        desk.settle(id, R_LAST);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        assertEq(sr.payoutSharesPerUnit, 1e18, "capped at the lock per unit");
        assertEq(sr.minLockPerUnit, 1e18);
        assertLe(uint256(sr.payoutSharesPerUnit) * sr.openUnits / 1e18, sr.lockedShares);
        vm.prank(bob);
        assertEq(desk.claim(id, 10e18, false), 10e18, "the whole lock");
        vm.prank(ann);
        assertEq(desk.release(id), 0, "nothing left for the writer, and no revert");
        assertEq(vault.balanceOf(address(desk)), 0);
    }

    function test_put_payout_is_capped_through_the_usdg_vaults_rate() public {
        bytes32 id = _id(K, false);
        _fillAsk(bob, _ask(carl, false, 4e18, PREM), 4e18);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        usdgVault.lose(5_000_000e6); // half the vault
        _monday(25_000_000); // the stock is worth $0.25: the put owes 184.75 USDG per unit on a lock worth 92.5
        desk.settle(id, R_LAST);
        OptionsDesk.Series memory after_ = desk.seriesOf(id);
        assertEq(after_.payoutSharesPerUnit, sr.minLockPerUnit, "capped at the lock per unit");
        assertEq(after_.payoutUsdgPerUnit, usdgVault.convertToAssets(sr.minLockPerUnit), "what the lock is worth now");
        assertLt(after_.payoutUsdgPerUnit, 184.75e6);
        assertApproxEqAbs(after_.payoutUsdgPerUnit, 92.5e6, 1);
        vm.prank(bob);
        uint256 paid = desk.claim(id, 4e18, false);
        assertApproxEqAbs(paid, 370e6, 4);
        vm.prank(carl);
        assertEq(desk.release(id), 0);
        assertEq(usdgVault.balanceOf(address(desk)), 0);
    }

    function test_claim_and_release_guards() public {
        bytes32 id = _id(K, true);
        bytes32 pid = _id(K, false);
        _fillAsk(bob, _ask(ann, true, 2e18, PREM), 2e18);
        _fillAsk(bob, _ask(carl, false, 1e18, PREM), 1e18);
        vm.prank(bob);
        vm.expectRevert(OptionsDesk.NotSettled.selector);
        desk.claim(id, 1e18, false);
        vm.prank(ann);
        vm.expectRevert(OptionsDesk.NotSettled.selector);
        desk.release(id);
        _settle(id, 200e8);
        vm.startPrank(bob);
        vm.expectRevert(OptionsDesk.Nothing.selector);
        desk.claim(id, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 2e18, 3e18, uint256(id))
        );
        desk.claim(id, 3e18, false);
        desk.claim(id, 2e18, false);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 0, 1, uint256(id))
        );
        desk.claim(id, 1, false);
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert(OptionsDesk.Nothing.selector);
        desk.release(id); // wrote nothing
        vm.startPrank(ann);
        desk.release(id);
        vm.expectRevert(OptionsDesk.AlreadyReleased.selector);
        desk.release(id);
        vm.stopPrank();
        // Settlement, claims and releases are never paused.
        vm.prank(owner);
        desk.setPaused(true);
        desk.settle(pid, R_LAST);
        vm.prank(bob);
        desk.claim(pid, 1e18, false);
        vm.prank(carl);
        desk.release(pid);
    }

    function test_longs_move_as_erc1155_tokens_and_the_holder_claims() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 2e18, PREM), 2e18);
        vm.prank(bob);
        desk.safeTransferFrom(bob, eve, uint256(id), 1.5e18, "");
        assertEq(desk.balanceOf(eve, uint256(id)), 1.5e18);
        _settle(id, 200e8);
        uint256 perUnit = desk.seriesOf(id).payoutSharesPerUnit;
        vm.prank(eve);
        assertEq(desk.claim(id, 1.5e18, false), 1.5e18 * perUnit / 1e18);
        vm.prank(bob);
        assertEq(desk.claim(id, 0.5e18, false), 0.5e18 * perUnit / 1e18);
        vm.prank(ann);
        desk.release(id);
        assertLt(vault.balanceOf(address(desk)), 2, "rounding dust at most");
    }

    function test_two_writers_share_a_series_and_the_thinnest_lock_caps_the_payout() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 4e18, PREM), 4e18); // 4 shares at 1:1
        vault.accrue(1_000e18); // a share is now worth about two stock
        vm.prank(dan);
        uint256 askId = desk.postAskWithStock(address(feed), EXP, K, 4e18, PREM);
        uint256 danLock = desk.orderOf(askId).locked;
        assertLt(danLock, 2.1e18, "about two shares for four units");
        _fillAsk(bob, askId, 4e18);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        assertEq(sr.openUnits, 8e18);
        assertEq(sr.lockedShares, 4e18 + danLock);
        assertEq(sr.minLockPerUnit, danLock * 1e18 / 4e18, "the later, thinner lock");
        vault.lose(1_500e18); // then the vault loses three quarters
        _monday(2_000e8); // deep in the money
        desk.settle(id, R_LAST);
        sr = desk.seriesOf(id);
        assertEq(sr.payoutSharesPerUnit, sr.minLockPerUnit, "capped so dan's lock covers his units");
        vm.prank(bob);
        uint256 paid = desk.claim(id, 8e18, false);
        assertEq(paid, 8 * uint256(sr.payoutSharesPerUnit));
        vm.prank(dan);
        uint256 danBack = desk.release(id);
        assertLe(danBack, 1, "dan's lock is all owed");
        vm.prank(ann);
        uint256 annBack = desk.release(id);
        assertEq(annBack, 4e18 - 4 * uint256(sr.payoutSharesPerUnit), "ann's thicker lock has something left");
        assertLt(vault.balanceOf(address(desk)), 4, "dust only");
    }

    function test_reentrancy_is_refused() public {
        ReenteringVault evil = new ReenteringVault(stock);
        RoundFeed feed2 = new RoundFeed(8);
        vm.prank(owner);
        desk.setStock(address(feed2), IShareVault(address(evil)), true);
        stock.mint(ann, 10e18);
        vm.startPrank(ann);
        stock.approve(address(evil), type(uint256).max);
        evil.deposit(10e18, ann);
        evil.approve(address(desk), type(uint256).max);
        uint256 askId = desk.postAsk(address(feed2), EXP, K, true, 4e18, PREM);
        uint256 spare = desk.postAsk(address(feed2), EXP, K, true, 1e18, PREM);
        vm.stopPrank();
        bytes32 id = desk.seriesIdOf(address(feed2), EXP, K, true);
        _fillAsk(bob, askId, 4e18);
        bytes4 guard = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        // A cancel's share transfer tries to cancel again.
        evil.arm(desk, id, spare, 3);
        vm.prank(ann);
        desk.cancel(spare);
        assertEq(evil.seen(), guard);
        feed2.set(R_LAST, 200e8, EXP - 2 hours);
        feed2.set(R_NEXT, 200e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        desk.settle(id, R_LAST);
        // A claim's share transfer tries to release; a release's tries to claim.
        evil.arm(desk, id, 0, 1);
        vm.prank(bob);
        desk.claim(id, 4e18, false);
        assertEq(evil.seen(), guard);
        evil.arm(desk, id, 0, 2);
        vm.prank(ann);
        desk.release(id);
        assertEq(evil.seen(), guard);
        assertLt(evil.balanceOf(address(desk)), 2, "and the accounting came out whole");
    }

    function test_a_delegated_wallet_can_buy_and_claim() public {
        // An EIP-7702 delegated account: code 0xef0100 plus the delegate's address, and no receiver hook.
        address wallet = makeAddr("delegated");
        vm.etch(wallet, abi.encodePacked(hex"ef0100", address(0xdE1e9A7eD0000000000000000000000000000001)));
        assertGt(wallet.code.length, 0);
        usdg.mint(wallet, 1_000e6);
        vm.prank(wallet);
        usdg.approve(address(desk), type(uint256).max);
        bytes32 id = _id(K, true);
        uint256 askId = _ask(ann, true, 3e18, PREM);
        vm.prank(wallet);
        desk.fillAsk(askId, 3e18, type(uint128).max);
        assertEq(desk.balanceOf(wallet, uint256(id)), 3e18);
        assertEq(usdg.balanceOf(wallet), 1_000e6 - 6e6);
        _settle(id, 200e8);
        uint256 perUnit = desk.seriesOf(id).payoutSharesPerUnit;
        vm.prank(wallet);
        assertEq(desk.claim(id, 3e18, false), 3 * perUnit);
        assertEq(vault.balanceOf(wallet), 3 * perUnit);
        assertEq(desk.balanceOf(wallet, uint256(id)), 0);
    }

    function test_a_plain_contract_can_buy_and_claim() public {
        PlainBuyer buyer = new PlainBuyer(desk, usdg);
        usdg.mint(address(buyer), 1_000e6);
        bytes32 id = _id(K, false);
        uint256 askId = _ask(carl, false, 2e18, PREM);
        buyer.buy(askId, 2e18);
        assertEq(desk.balanceOf(address(buyer), uint256(id)), 2e18);
        _settle(id, 170e8);
        uint256 paid = buyer.claim(id, 2e18);
        assertApproxEqAbs(paid, 30e6, 1, "15 USDG a unit");
        assertEq(usdg.balanceOf(address(buyer)), 1_000e6 - 4e6 + paid);
        assertEq(desk.balanceOf(address(buyer), uint256(id)), 0);
    }

    // ------------------------------------------------------------------ fallback, void, phases, fills under stress

    function test_settle_falls_back_to_the_first_round_after_expiry() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        feed.set(R_LAST, 200e8, EXP + 7 days); // the feed's first print after a long silence
        feed.set(R_NEXT, 210e8, EXP + 8 days);
        vm.warp(EXP + 8 days + 1);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_OLD); // the last print before expiry, days too old to be the close
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_NEXT); // the second print after expiry
        desk.settle(id, R_LAST);
        assertEq(desk.seriesOf(id).settlePrice, 200e8);
        assertEq(desk.seriesOf(id).payoutSharesPerUnit, vault.convertToShares(uint256(15e8) * 1e18 / 200e8));
    }

    function test_settle_fallback_needs_the_round_before_to_be_missing_or_stale() public {
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        feed.set(R_OLD, REF, EXP - 1 days);
        feed.set(R_LAST, 200e8, EXP + 7 days);
        vm.warp(EXP + 7 days + 1);
        // R_OLD printed a day before expiry: it is the close, so the print after expiry is no proof.
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_LAST);
        desk.settle(id, R_OLD); // and R_OLD proves the usual way: its next round printed after expiry
        assertEq(desk.seriesOf(id).settlePrice, uint256(REF));

        // A feed with no history at all before the print after expiry.
        bytes32 id2 = desk.seriesIdOf(address(feed), EXP, K + 25_000_000, true);
        feed.set(R_OLD, 0, 0);
        feed.set(PHASE | 8, 0, 0);
        vm.warp(NOW);
        _fillAsk(bob, _ask2(K + 25_000_000), 1e18);
        vm.warp(EXP + 7 days + 1);
        desk.settle(id2, R_LAST);
        assertEq(desk.seriesOf(id2).settlePrice, 200e8);
    }

    function test_settle_fallback_at_a_phases_first_round_looks_up_the_prior_phase() public {
        uint80 first2 = (uint80(2) << 64) | 1;
        bytes32 id = _id(K, true);
        bytes32 id2 = desk.seriesIdOf(address(feed), EXP, K + 25_000_000, true);
        bytes32 id3 = desk.seriesIdOf(address(feed), EXP, K + 50_000_000, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        _fillAsk(bob, _ask2(K + 25_000_000), 1e18);
        _fillAsk(bob, _ask2(K + 50_000_000), 1e18);
        MockAggregator agg = new MockAggregator();
        feed.setPhaseAggregator(1, address(agg));
        agg.set(9); // phase 1 ended at R_OLD, printed a day before expiry: it is the close
        feed.set(R_OLD, REF, EXP - 1 days);
        feed.set(first2, 200e8, EXP + 1 hours); // phase 2 began after expiry
        feed.setLatest(first2);
        vm.warp(EXP + 2 hours);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, first2);
        desk.settle(id, R_OLD); // the previous phase's last round proves, since the new phase began after expiry
        assertEq(desk.seriesOf(id).settlePrice, uint256(REF));
        // Phase 1 ended three days before expiry: the new phase's first print is the price.
        feed.set(R_OLD, REF, EXP - 3 days);
        desk.settle(id2, first2);
        assertEq(desk.seriesOf(id2).settlePrice, 200e8);
        // A proxy that cannot name the prior phase's aggregator: the proof fails, nothing is read as "no round
        // before", and the series waits for the void.
        feed.set(R_OLD, REF, NOW - 1 days);
        feed.setPhaseAggregator(1, address(0));
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id3, first2);
        assertFalse(desk.seriesOf(id3).settled);
    }

    function test_an_old_aggregator_cannot_offer_a_second_price() public {
        uint80 P2 = uint80(2) << 64;
        feed.set(R_LAST, 180e8, EXP - 2 hours); // the old aggregator, still printing after the switch
        feed.set(R_NEXT, 180e8, REOPEN + 30);
        feed.set(P2 | 1, 181e8, EXP - 1 days); // the proxy's current aggregator since Thursday
        feed.set(P2 | 2, 190e8, EXP - 1 hours);
        feed.set(P2 | 3, 190e8, REOPEN + 30);
        feed.setLatest(P2 | 3);
        bytes32 id = _id(K, true);
        _fillAsk(bob, _ask(ann, true, 1e18, PREM), 1e18);
        vm.warp(REOPEN + 60);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, R_LAST); // not the latest phase, and the latest phase began before expiry
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(id, P2 | 1);
        desk.settle(id, P2 | 2);
        assertEq(desk.seriesOf(id).settlePrice, 190e8);
    }

    function test_void_closes_a_series_the_feed_never_priced() public {
        bytes32 cid = _id(K, true);
        bytes32 pid = _id(K, false);
        _fillAsk(bob, _ask(ann, true, 2e18, PREM), 2e18);
        _fillAsk(bob, _ask(carl, false, 2e18, PREM), 2e18);
        uint256 putLock = desk.seriesOf(pid).lockedShares;
        vm.expectRevert(OptionsDesk.NoSeries.selector);
        desk.void(bytes32(uint256(1)));
        vm.expectRevert(OptionsDesk.NotExpired.selector);
        desk.void(cid);
        vm.warp(EXP + 14 days - 1);
        vm.expectRevert(OptionsDesk.NotExpired.selector);
        desk.void(cid);
        vm.warp(EXP + 14 days);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Voided(cid);
        vm.prank(eve);
        desk.void(cid);
        OptionsDesk.Series memory sr = desk.seriesOf(cid);
        assertTrue(sr.settled);
        assertEq(sr.settlePrice, 0);
        assertEq(sr.payoutSharesPerUnit, 0);
        assertEq(sr.payoutUsdgPerUnit, 0);
        vm.expectRevert(OptionsDesk.AlreadySettled.selector);
        desk.void(cid);
        feed.set(R_LAST, 200e8, EXP - 1 hours);
        vm.expectRevert(OptionsDesk.AlreadySettled.selector);
        desk.settle(cid, R_LAST); // a void is final
        vm.prank(bob);
        assertEq(desk.claim(cid, 2e18, false), 0, "longs get nothing");
        assertEq(desk.balanceOf(bob, uint256(cid)), 0);
        vm.prank(ann);
        assertEq(desk.release(cid), 2e18, "the writer takes the whole lock");
        // A settled series cannot be voided.
        desk.settle(pid, R_LAST);
        vm.expectRevert(OptionsDesk.AlreadySettled.selector);
        desk.void(pid);
        vm.prank(carl);
        assertEq(desk.release(pid), putLock);
        assertEq(vault.balanceOf(address(desk)), 0);
        assertEq(usdgVault.balanceOf(address(desk)), 0);
    }

    function test_fillAsk_refuses_a_lock_a_vault_loss_left_short() public {
        uint256 putAsk = _ask(carl, false, 1e18, PREM);
        uint256 callAsk = _ask(ann, true, 1e18, PREM);
        usdgVault.lose(5_000_000e6); // half the USDG vault
        vault.lose(10e18); // one percent of the stock vault
        vm.startPrank(bob);
        vm.expectRevert(OptionsDesk.LockShort.selector);
        desk.fillAsk(putAsk, 1e18, type(uint128).max);
        vm.expectRevert(OptionsDesk.LockShort.selector);
        desk.fillAsk(callAsk, 1e18, type(uint128).max);
        vm.expectRevert(OptionsDesk.LockShort.selector);
        desk.fillAsk(callAsk, 0.5e18, type(uint128).max);
        vm.stopPrank();
        // The writers cancel and post again at today's rate; those fill.
        vm.prank(carl);
        desk.cancel(putAsk);
        vm.prank(ann);
        desk.cancel(callAsk);
        putAsk = _ask(carl, false, 1e18, PREM);
        callAsk = _ask(ann, true, 1e18, PREM);
        _fillAsk(bob, putAsk, 1e18);
        _fillAsk(bob, callAsk, 0.5e18);
        assertEq(desk.seriesOf(_id(K, false)).openUnits, 1e18);
        // Rent only makes a lock worth more: fills keep going, partial or whole.
        vault.accrue(100e18);
        _fillAsk(bob, callAsk, 0.5e18);
        assertEq(desk.seriesOf(_id(K, true)).openUnits, 1e18);
    }

    function test_fee_is_fixed_when_the_order_is_posted() public {
        bytes32 id = _id(K, true);
        uint256 askId = _ask(ann, true, 1e18, PREM); // posted at 10%
        vm.prank(owner);
        desk.setFee(2000, keeper);
        assertEq(desk.orderOf(askId).feeBps, 1000);
        uint256 annBefore = usdg.balanceOf(ann);
        vm.expectEmit(true, true, true, true);
        emit OptionsDesk.Filled(askId, id, ann, bob, 1e18, 2e6, 0.2e6, 1e18);
        _fillAsk(bob, askId, 1e18);
        assertEq(usdg.balanceOf(ann) - annBefore, 1.8e6, "the fee at the post, not the fill");
        assertEq(usdg.balanceOf(keeper), 0.2e6);
        uint256 bidId = _bid(bob, true, 1e18, PREM); // posted at 20%
        vm.prank(owner);
        desk.setFee(500, keeper);
        assertEq(desk.orderOf(bidId).feeBps, 2000);
        vm.prank(ann);
        vm.expectRevert(abi.encodeWithSelector(OptionsDesk.TooLittle.selector, 1.6e6, 1.6e6 + 1));
        desk.fillBid(bidId, 1e18, 1.6e6 + 1);
        annBefore = usdg.balanceOf(ann);
        vm.prank(ann);
        desk.fillBid(bidId, 1e18, 1.6e6);
        assertEq(usdg.balanceOf(ann) - annBefore, 1.6e6);
        assertEq(usdg.balanceOf(keeper), 0.6e6);
    }

    // ------------------------------------------------------------------ fuzz

    /// Any strike, any settlement price, any two sizes, with the rate moving between the two writes and a loss of
    /// up to half before settlement: the payout never exceeds the thinnest lock, every lock comes back exactly once
    /// between the claims and the releases, and the desk holds nothing afterwards but rounding dust.
    function testFuzz_payout_within_the_lock_and_every_lock_returned_once(
        uint256 ticks,
        uint256 priceSeed,
        uint256 unitsA,
        uint256 unitsB,
        uint256 lossBps,
        bool isCall
    ) public {
        uint128 strike = uint128(bound(ticks, 1, 40_000) * 25_000_000); // $0.25 to $10,000
        int256 price = int256(bound(priceSeed, 1e6, 20_000e8)); // $0.01 to $20,000
        uint128 a = uint128(bound(unitsA, MIN, 50e18));
        uint128 b = uint128(bound(unitsB, MIN, 50e18));
        lossBps = bound(lossBps, 0, 5_000);
        bytes32 id = desk.seriesIdOf(address(feed), EXP, strike, isCall);
        RateVault v = isCall ? vault : usdgVault;
        address writerA = isCall ? ann : carl;

        vm.prank(writerA);
        uint256 askId = desk.postAsk(address(feed), EXP, strike, isCall, a, PREM);
        _fillAsk(bob, askId, a);
        v.accrue(isCall ? 333e18 : 3_333_333e6); // the rate moves before the second write
        vm.prank(bob);
        uint256 bidId = desk.postBid(address(feed), EXP, strike, isCall, b, PREM);
        vm.prank(dan);
        if (isCall) desk.fillBidWithStock(bidId, b, 0);
        else desk.fillBidWithUsdg(bidId, b, 0);
        OptionsDesk.Series memory sr = desk.seriesOf(id);
        uint256 lockA = desk.writtenOf(writerA, id).lockedShares;
        uint256 lockB = desk.writtenOf(dan, id).lockedShares;
        assertEq(sr.lockedShares, lockA + lockB);
        assertEq(v.balanceOf(address(desk)), lockA + lockB);
        assertEq(usdg.balanceOf(address(desk)), 0);

        if (lossBps != 0) v.lose(v.totalAssets() * lossBps / 10_000);
        feed.set(R_LAST, price, EXP - 2 hours);
        feed.set(R_NEXT, price, REOPEN + 30);
        vm.warp(REOPEN + 60);
        desk.settle(id, R_LAST);
        sr = desk.seriesOf(id);
        uint256 perUnit = sr.payoutSharesPerUnit;
        assertLe(perUnit, sr.minLockPerUnit, "never above the thinnest lock");
        assertLe(perUnit * sr.openUnits / 1e18, sr.lockedShares, "never above the lock in all");
        assertLe(uint256(a) * perUnit / 1e18, lockA);
        assertLe(uint256(b) * perUnit / 1e18, lockB);
        if (lossBps == 0) {
            // Without a loss the cap never binds: the payout is the intrinsic value at today's rate.
            uint256 want;
            if (isCall && uint256(price) > strike) want = v.convertToShares((uint256(price) - strike) * 1e18 / uint256(price));
            if (!isCall && strike > uint256(price)) want = _sharesUp(v, (strike - uint256(price)) / 100);
            assertEq(perUnit, want);
        }

        // Claims in both forms, then the releases: everything comes back, once.
        vm.startPrank(bob);
        uint256 paid1 = desk.claim(id, uint256(a), false);
        uint256 paid2 = desk.claim(id, uint256(b), true);
        vm.stopPrank();
        assertEq(desk.balanceOf(bob, uint256(id)), 0);
        if (isCall) {
            assertEq(paid1 + paid2, v.balanceOf(bob));
        } else {
            assertEq(paid2, v.balanceOf(bob));
            assertEq(paid1, usdg.balanceOf(bob) - (1_000_000e6 - uint256(a) * PREM / 1e18 - uint256(b) * PREM / 1e18));
        }
        vm.prank(writerA);
        uint256 backA = desk.release(id);
        vm.prank(dan);
        uint256 backB = desk.release(id);
        assertLe(backA, lockA);
        assertLe(backB, lockB);
        assertLt(v.balanceOf(address(desk)), 1e6, "dust only");
        assertEq(usdg.balanceOf(address(desk)), 0);
        assertEq(stock.balanceOf(address(desk)), 0);
        vm.prank(writerA);
        vm.expectRevert(OptionsDesk.AlreadyReleased.selector);
        desk.release(id);
    }
}
