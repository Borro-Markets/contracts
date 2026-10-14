// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GapPool, IHeldVault} from "../src/GapPool.sol";
import {MarketHours} from "../src/eth/MarketHours.sol";

contract Tok is ERC20 {
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

/// A USDG that can freeze an address, the way the real one can: a transfer to a frozen address either returns false
/// (mode 1) or reverts (mode 2).
contract FreezableTok is Tok {
    mapping(address => uint8) public mode;

    constructor() Tok("USDG", 6) {}

    function freeze(address who, uint8 m) external {
        mode[who] = m;
    }

    function transfer(address to, uint256 a) public override returns (bool) {
        if (mode[to] == 1) return false;
        if (mode[to] == 2) revert("frozen");
        return super.transfer(to, a);
    }
}

/// A Chainlink-shaped feed whose rounds the test sets. Round ids carry a phase in the top 16 bits, as the proxies do.
contract MockFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latest;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function set(uint80 id, int256 answer, uint256 updatedAt) external {
        rounds[id] = Round(answer, updatedAt);
        if (id > latest) latest = id;
    }

    function setLatest(uint80 id) external {
        latest = id;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latest];
        return (latest, r.answer, r.updatedAt, r.updatedAt, latest);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[id];
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}

/// A feed that reports no decimals: not a price feed.
contract NoDecimalsFeed {
    function decimals() external pure returns (uint8) {
        return 0;
    }
}

/// An ERC-4626-like vault over a 6-decimal asset with 18-decimal shares, Vault V2's virtual offset, and a way to
/// hand it interest or a loss.
contract MockVault is ERC20 {
    IERC20 public immutable asset;
    uint256 constant VS = 1e12;

    constructor(IERC20 a) ERC20("Mock Steakhouse USDG", "mSTEAK") {
        asset = a;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * (totalAssets() + 1) / (totalSupply() + VS);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return assets * (totalSupply() + VS) / (totalAssets() + 1);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return (assets * (totalSupply() + VS) + totalAssets()) / (totalAssets() + 1);
    }

    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares) {
        shares = previewDeposit(assets);
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

    /// Interest arrives: the vault is simply worth more.
    function accrue(uint256 amount) external {
        Tok(address(asset)).mint(address(this), amount);
    }

    /// A loss: the vault is simply worth less.
    function lose(uint256 amount) external {
        asset.transfer(address(0xdead), amount);
    }
}

/// Every rule of docs/WEEKEND.md's GapPool section, on a mock feed and a mock vault with a warped clock.
contract GapPoolTest is Test {
    uint80 constant PHASE = uint80(1) << 64;
    uint80 constant R_FRI = PHASE | 10; // the Friday print
    uint80 constant R_MON = PHASE | 11; // the first print after the reopen
    uint80 constant R_MON2 = PHASE | 12; // the one after that
    uint256 constant FRI = 1791568800; // 2026-10-09 18:00 UTC, open
    uint256 constant SAT = 1791644400; // 2026-10-10 15:00 UTC, closed
    uint256 constant REOPEN = 1791763200; // 2026-10-12 00:00 UTC (Sunday 20:00 New York)
    int256 constant REF = 180e8;

    Tok usdg;
    MockVault vault;
    MockFeed feed;
    MockFeed feed2; // a second listed stock
    GapPool pool;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address ann = makeAddr("ann"); // funds the pool
    address bob = makeAddr("bob"); // buys cover
    address eve = makeAddr("eve");

    function setUp() public {
        vm.warp(FRI);
        usdg = new Tok("USDG", 6);
        vault = new MockVault(usdg);
        feed = new MockFeed();
        feed.set(R_FRI, REF, FRI);
        feed2 = new MockFeed();
        feed2.set(R_FRI, 100e8, FRI);
        pool = new GapPool(usdg, IHeldVault(address(vault)), owner, _feeds(address(feed), address(feed2)));
        vm.startPrank(owner);
        pool.setQuoter(keeper);
        pool.setFee(1000, keeper);
        pool.setCapBps(1000);
        pool.setPremiumBounds(5, 2000);
        pool.setTotalExposure(5000);
        pool.setStock(address(feed), true, 2500);
        vm.stopPrank();
        usdg.mint(ann, 1_000_000e6);
        usdg.mint(bob, 1_000_000e6);
        vm.prank(ann);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(pool), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _feeds(address a, address b) internal pure returns (address[] memory f) {
        f = new address[](2);
        (f[0], f[1]) = (a, b);
    }

    function _one(address a) internal pure returns (address[] memory f) {
        f = new address[](1);
        f[0] = a;
    }

    function _fund(uint256 amount) internal returns (uint256 shares) {
        vm.prank(ann);
        shares = pool.deposit(amount, ann);
    }

    function _quoteFeed(address f) internal {
        uint16[] memory s = new uint16[](4);
        uint16[] memory p = new uint16[](4);
        (s[0], s[1], s[2], s[3]) = (100, 200, 300, 500);
        (p[0], p[1], p[2], p[3]) = (80, 50, 30, 10);
        vm.startPrank(keeper);
        pool.setQuotes(f, 0, s, p);
        pool.setQuotes(f, 1, s, p);
        vm.stopPrank();
    }

    function _quote() internal {
        _quoteFeed(address(feed));
    }

    /// The usual weekend: the pool is funded, it is Saturday afternoon, quotes are up.
    function _saturday() internal {
        _fund(100_000e6);
        vm.warp(SAT);
        _quote();
    }

    function _buy(uint8 side, uint96 notional, uint16 strike) internal returns (uint256 id) {
        vm.prank(bob);
        id = pool.buy(address(feed), side, notional, strike, type(uint256).max);
    }

    function _monday(int256 answer) internal {
        feed.set(R_MON, answer, REOPEN + 30);
        vm.warp(REOPEN + 60);
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_lists_the_feeds_switched_off_and_checks_them() public {
        vm.expectEmit(true, true, true, true);
        emit GapPool.StockSet(address(feed), false, 0);
        vm.expectEmit(true, true, true, true);
        emit GapPool.StockSet(address(feed2), false, 0);
        GapPool p = new GapPool(usdg, IHeldVault(address(vault)), owner, _feeds(address(feed), address(feed2)));
        (address f, bool allowed, uint16 exposure, uint256 reserved) = p.stocks(address(feed));
        assertEq(f, address(feed));
        assertFalse(allowed, "listed, not yet on");
        assertEq(exposure, 0);
        assertEq(reserved, 0);
        (f,,,) = p.stocks(address(feed2));
        assertEq(f, address(feed2));
        assertEq(p.owner(), owner);
        assertEq(p.maxTotalExposureBps(), 0, "nothing can be reserved until the owner sets the pool's exposure");
        assertEq(p.decimals(), 12);

        vm.expectRevert(GapPool.BadValue.selector);
        new GapPool(usdg, IHeldVault(address(vault)), owner, _one(address(0)));
        vm.expectRevert(GapPool.BadValue.selector);
        new GapPool(usdg, IHeldVault(address(vault)), owner, _feeds(address(feed), address(feed))); // twice
        vm.expectRevert(GapPool.BadFeed.selector);
        new GapPool(usdg, IHeldVault(address(vault)), owner, _one(address(new NoDecimalsFeed())));
        vm.expectRevert(GapPool.BadVault.selector);
        new GapPool(usdg, IHeldVault(address(new MockVault(new Tok("OTHER", 6)))), owner, _one(address(feed)));
    }

    // ------------------------------------------------------------------ owner

    function test_only_the_owner_sets_things_and_within_bounds() public {
        vm.startPrank(eve);
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve);
        vm.expectRevert(denied);
        pool.setStock(address(feed), false, 0);
        vm.expectRevert(denied);
        pool.setQuoter(eve);
        vm.expectRevert(denied);
        pool.setFee(1, eve);
        vm.expectRevert(denied);
        pool.setPremiumBounds(1, 2);
        vm.expectRevert(denied);
        pool.setCapBps(500);
        vm.expectRevert(denied);
        pool.setTotalExposure(100);
        vm.expectRevert(denied);
        pool.setPaused(true, true);
        vm.expectRevert(denied);
        pool.sweep(IERC20(address(0x1)), eve);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setFee(2001, keeper); // Borro's share never passes 20%
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setFee(100, address(0));
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setCapBps(2001);
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setCapBps(0);
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setPremiumBounds(0, 100);
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setPremiumBounds(200, 100);
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setPremiumBounds(1, 10_001);
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setStock(address(feed), true, 10_001);
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setTotalExposure(5001); // live covers never reserve more than half the pool
        pool.setFee(2000, keeper);
        pool.setCapBps(2000);
        pool.setTotalExposure(5000);
        vm.stopPrank();
        assertEq(pool.feeBps(), 2000);
        assertEq(pool.capBps(), 2000);
        assertEq(pool.maxTotalExposureBps(), 5000);
    }

    /// The feeds are fixed at deploy: the owner can switch a listed one on or off, and nothing else.
    function test_owner_cannot_add_a_feed() public {
        MockFeed other = new MockFeed();
        other.set(R_FRI, 100e8, FRI);
        vm.startPrank(owner);
        vm.expectRevert(GapPool.NotListed.selector);
        pool.setStock(address(other), true, 2500);
        vm.expectRevert(GapPool.NotListed.selector);
        pool.setStock(address(0), true, 100);
        vm.expectRevert(GapPool.NotListed.selector);
        pool.setStock(address(0xFEED), false, 0);
        // A listed feed switches on and off.
        vm.expectEmit(true, true, true, true);
        emit GapPool.StockSet(address(feed2), true, 1000);
        pool.setStock(address(feed2), true, 1000);
        (, bool allowed, uint16 exposure,) = pool.stocks(address(feed2));
        assertTrue(allowed);
        assertEq(exposure, 1000);
        pool.setStock(address(feed2), false, 0);
        (, allowed,,) = pool.stocks(address(feed2));
        assertFalse(allowed);
        vm.stopPrank();
        (address f,,,) = pool.stocks(address(other));
        assertEq(f, address(0), "never listed");
    }

    function test_sweep_never_reaches_usdg_or_the_vault_shares() public {
        _fund(1_000e6);
        usdg.mint(address(pool), 5e6);
        Tok other = new Tok("OTHER", 18);
        other.mint(address(pool), 7e18);
        vm.startPrank(owner);
        vm.expectRevert(GapPool.CannotSweep.selector);
        pool.sweep(usdg, owner);
        vm.expectRevert(GapPool.CannotSweep.selector);
        pool.sweep(IERC20(address(vault)), owner);
        pool.sweep(other, owner);
        vm.stopPrank();
        assertEq(other.balanceOf(owner), 7e18);
        assertEq(usdg.balanceOf(address(pool)), 5e6);
    }

    // ------------------------------------------------------------------ sellers

    function test_deposit_mints_shares_at_the_virtual_offset_and_withdraw_returns_usdg() public {
        uint256 shares = _fund(100_000e6);
        assertEq(shares, 100_000e6 * 1e6, "the first deposit gets VIRTUAL_SHARES per USDG wei");
        assertEq(pool.balanceOf(ann), shares);
        assertApproxEqAbs(pool.totalAssets(), 100_000e6, 2);
        assertEq(pool.freeAssets(), pool.totalAssets());
        assertEq(usdg.balanceOf(address(pool)), 0, "USDG never sits in the pool");
        assertGt(vault.balanceOf(address(pool)), 0, "it sits in the vault");

        vm.prank(ann);
        uint256 back = pool.withdraw(shares, ann);
        assertApproxEqAbs(back, 100_000e6, 2);
        assertEq(usdg.balanceOf(ann), 1_000_000e6 - 100_000e6 + back);
        assertEq(pool.balanceOf(ann), 0);
    }

    function test_deposit_guards() public {
        vm.prank(ann);
        vm.expectRevert(GapPool.Nothing.selector);
        pool.deposit(0, ann);
        vm.prank(owner);
        pool.setPaused(false, true);
        vm.prank(ann);
        vm.expectRevert(GapPool.Paused.selector);
        pool.deposit(1e6, ann);
        vm.prank(owner);
        pool.setPaused(false, false);
        _fund(1e6);
        vm.prank(ann);
        vm.expectRevert(GapPool.Nothing.selector);
        pool.withdraw(0, ann);
    }

    function test_shares_track_the_vaults_interest_and_kept_premiums() public {
        uint256 annShares = _fund(100_000e6);
        vault.accrue(10_000e6); // 10% interest on the vault's only deposit
        assertApproxEqAbs(pool.convertToAssets(annShares), 110_000e6, 2);
        usdg.mint(eve, 11_000e6);
        vm.startPrank(eve);
        usdg.approve(address(pool), type(uint256).max);
        uint256 eveShares = pool.deposit(11_000e6, eve);
        vm.stopPrank();
        assertApproxEqRel(eveShares, annShares / 10, 1e12, "a later deposit buys in at the higher price");
        // A weekend's premium raises the share price for every holder.
        vm.warp(SAT);
        _quote();
        _buy(0, 10_000e6, 200); // premium 50e6, fee 5e6, 45e6 kept
        assertApproxEqRel(pool.convertToAssets(annShares), uint256(110_000e6) + uint256(45e6) * 10 / 11, 1e12);
    }

    function test_inflation_attack_does_not_pay() public {
        // Eve deposits one wei, then donates vault shares worth 10,000 USDG to push the share price up.
        usdg.mint(eve, 10_000e6 + 1);
        vm.startPrank(eve);
        usdg.approve(address(pool), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        uint256 eveShares = pool.deposit(1, eve);
        uint256 donated = vault.deposit(10_000e6, eve);
        vault.transfer(address(pool), donated);
        vm.stopPrank();
        assertApproxEqAbs(pool.totalAssets(), 10_000e6 + 1, 2);
        // Ann's deposit still gets shares, and loses at most dust to rounding.
        uint256 annShares = _fund(1_000e6);
        assertGt(annShares, 0);
        assertGe(pool.convertToAssets(annShares), 1_000e6 - 0.01e6, "ann loses less than a cent");
        // Eve cannot take back what she donated: the virtual shares hold most of it.
        assertLt(pool.convertToAssets(eveShares), 6_000e6, "eve's shares are worth far less than she put in");
    }

    // ------------------------------------------------------------------ quotes

    function test_quotes_only_from_the_quoter_inside_the_bounds() public {
        uint16[] memory s = new uint16[](1);
        uint16[] memory p = new uint16[](1);
        (s[0], p[0]) = (200, 50);
        vm.prank(eve);
        vm.expectRevert(GapPool.OnlyQuoter.selector);
        pool.setQuotes(address(feed), 0, s, p);

        vm.startPrank(keeper);
        vm.expectRevert(GapPool.LengthMismatch.selector);
        pool.setQuotes(address(feed), 0, s, new uint16[](2));
        vm.expectRevert(GapPool.BadSide.selector);
        pool.setQuotes(address(feed), 2, s, p);
        vm.expectRevert(GapPool.NotAllowed.selector);
        pool.setQuotes(address(0xFEED), 0, s, p);
        vm.expectRevert(GapPool.NotAllowed.selector);
        pool.setQuotes(address(feed2), 0, s, p); // listed but switched off
        p[0] = 4; // under the floor
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setQuotes(address(feed), 0, s, p);
        p[0] = 2001; // over the ceiling
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setQuotes(address(feed), 0, s, p);
        p[0] = 50;
        s[0] = 49;
        vm.expectRevert(GapPool.BadStrike.selector);
        pool.setQuotes(address(feed), 0, s, p);
        s[0] = 1001;
        vm.expectRevert(GapPool.BadStrike.selector);
        pool.setQuotes(address(feed), 0, s, p);
        s[0] = 200;
        pool.setQuotes(address(feed), 0, s, p);
        (uint16 bps, bool fresh) = pool.quoteOf(address(feed), 0, 200);
        assertEq(bps, 50);
        assertTrue(fresh);
        (, fresh) = pool.quoteOf(address(feed), 1, 200);
        assertFalse(fresh, "the other side is not quoted");
        // Zero withdraws a quote: no buys, never a free one.
        p[0] = 0;
        pool.setQuotes(address(feed), 0, s, p);
        (bps, fresh) = pool.quoteOf(address(feed), 0, 200);
        assertEq(bps, 0);
        assertFalse(fresh);
        vm.stopPrank();
    }

    function test_quote_dies_after_the_ttl() public {
        _saturday();
        vm.warp(SAT + 6 hours);
        (, bool fresh) = pool.quoteOf(address(feed), 0, 200);
        assertTrue(fresh, "alive at exactly QUOTE_TTL");
        _buy(0, 1_000e6, 200);
        vm.warp(SAT + 6 hours + 1);
        (, fresh) = pool.quoteOf(address(feed), 0, 200);
        assertFalse(fresh);
        (uint256 premium, uint256 fee) = pool.premiumFor(address(feed), 0, 1_000e6, 200);
        assertEq(premium + fee, 0, "no premium to show without a live quote");
        vm.prank(bob);
        vm.expectRevert(GapPool.NoQuote.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
    }

    // ------------------------------------------------------------------ buying

    function test_buy_only_while_the_market_is_shut() public {
        _fund(100_000e6);
        _quote();
        (bool closed, uint256 reopenAt) = pool.marketClosed();
        assertFalse(closed);
        assertEq(reopenAt, FRI);
        vm.prank(bob);
        vm.expectRevert(GapPool.MarketOpen.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
        vm.warp(SAT);
        (closed, reopenAt) = pool.marketClosed();
        assertTrue(closed);
        assertEq(reopenAt, REOPEN);
        _quote(); // Friday's quote has died by now
        _buy(0, 1_000e6, 200);
    }

    function test_no_buys_in_the_last_hour() public {
        _saturday();
        vm.warp(REOPEN - 1 hours - 4 hours); // the quote must still be live
        _quote();
        vm.warp(REOPEN - 1 hours);
        _buy(0, 1_000e6, 200);
        vm.warp(REOPEN - 1 hours + 1);
        vm.prank(bob);
        vm.expectRevert(GapPool.TooLate.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
    }

    function test_buy_guards() public {
        _saturday();
        vm.startPrank(bob);
        vm.expectRevert(GapPool.BadSide.selector);
        pool.buy(address(feed), 2, 1_000e6, 200, type(uint256).max);
        vm.expectRevert(GapPool.Nothing.selector);
        pool.buy(address(feed), 0, 0, 200, type(uint256).max);
        vm.expectRevert(GapPool.NotAllowed.selector);
        pool.buy(address(0xFEED), 0, 1_000e6, 200, type(uint256).max);
        vm.expectRevert(GapPool.NotAllowed.selector);
        pool.buy(address(feed2), 0, 1_000e6, 200, type(uint256).max); // listed but switched off
        vm.expectRevert(GapPool.BadStrike.selector);
        pool.buy(address(feed), 0, 1_000e6, 49, type(uint256).max);
        vm.expectRevert(GapPool.BadStrike.selector);
        pool.buy(address(feed), 0, 1_000e6, 1001, type(uint256).max);
        vm.expectRevert(GapPool.BadStrike.selector);
        pool.buy(address(feed), 0, 1_000e6, 1000, type(uint256).max); // the strike must be under the cap
        vm.expectRevert(GapPool.NoQuote.selector);
        pool.buy(address(feed), 0, 1_000e6, 150, type(uint256).max); // not a quoted strike
        vm.expectRevert(abi.encodeWithSelector(GapPool.TooMuch.selector, 5e6, 5e6 - 1));
        pool.buy(address(feed), 0, 1_000e6, 200, 5e6 - 1);
        vm.expectRevert(GapPool.Nothing.selector);
        pool.buy(address(feed), 0, 1, 500, type(uint256).max); // would pay nothing and reserve nothing
        vm.stopPrank();
        vm.prank(owner);
        pool.setPaused(true, false);
        vm.prank(bob);
        vm.expectRevert(GapPool.Paused.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
        vm.prank(owner);
        pool.setStock(address(feed), false, 2500);
        vm.prank(bob);
        vm.expectRevert(GapPool.Paused.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
        vm.prank(owner);
        pool.setPaused(false, false);
        vm.prank(bob);
        vm.expectRevert(GapPool.NotAllowed.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
    }

    /// premium = notional * bps / BPS rounds to zero for a small notional while the reserve does not: no free cover.
    function test_buy_refuses_a_premium_that_rounds_to_zero() public {
        _saturday();
        uint16[] memory s = new uint16[](1);
        uint16[] memory p = new uint16[](1);
        (s[0], p[0]) = (50, 5);
        vm.prank(keeper);
        pool.setQuotes(address(feed), 0, s, p);
        assertEq(pool.reserveFor(1_999, 50), 189, "the reserve would be 189 wei");
        (uint256 premium,) = pool.premiumFor(address(feed), 0, 1_999, 50);
        assertEq(premium, 0, "for a premium of nothing");
        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(GapPool.Nothing.selector);
        pool.buy(address(feed), 0, 1_999, 50, type(uint256).max);
        assertEq(pool.totalReserved(), 0, "nothing reserved");
        assertEq(pool.nextId(), 1, "no cover");
        assertEq(usdg.balanceOf(bob), before);
        // One wei of premium is enough.
        vm.prank(bob);
        uint256 id = pool.buy(address(feed), 0, 2_000, 50, type(uint256).max);
        assertEq(usdg.balanceOf(bob), before - 1);
        assertEq(pool.coverOf(id).premium, 1, "the fee rounds to zero, the pool keeps the wei");
    }

    function test_buy_needs_a_recent_print_before_now() public {
        _saturday();
        feed.set(R_FRI, REF, SAT); // a print at this very second is not "before now"
        vm.prank(bob);
        vm.expectRevert(GapPool.BadFeed.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
        feed.set(R_FRI, REF, SAT - 5 days - 1); // silent too long: a broken feed
        vm.prank(bob);
        vm.expectRevert(GapPool.BadFeed.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
        feed.set(R_FRI, 0, SAT - 1 hours);
        vm.prank(bob);
        vm.expectRevert(GapPool.BadFeed.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
        feed.set(R_FRI, REF, SAT - 5 days);
        _buy(0, 1_000e6, 200);
    }

    function test_buy_reserves_at_the_cap_and_splits_the_premium() public {
        _saturday();
        (uint256 premium, uint256 fee) = pool.premiumFor(address(feed), 0, 10_000e6, 200);
        assertEq(premium, 50e6);
        assertEq(fee, 5e6);
        assertEq(pool.reserveFor(10_000e6, 200), 800e6);
        uint256 total = pool.totalAssets();
        vm.expectEmit(true, true, true, true);
        emit GapPool.Bought(1, bob, address(feed), 0, 10_000e6, 200, 1000, 50e6, 5e6, uint256(REF), uint64(REOPEN));
        uint256 id = _buy(0, 10_000e6, 200);
        assertEq(id, 1);
        assertEq(usdg.balanceOf(bob), 1_000_000e6 - 50e6);
        assertEq(usdg.balanceOf(keeper), 5e6, "the fee goes to the recipient at once");
        assertApproxEqAbs(pool.totalAssets(), total + 45e6, 2, "the rest is the sellers' now");
        assertEq(pool.totalReserved(), 800e6);
        (,,, uint256 reserved) = pool.stocks(address(feed));
        assertEq(reserved, 800e6);
        assertApproxEqAbs(pool.freeAssets(), total + 45e6 - 800e6, 2);
        GapPool.Cover memory c = pool.coverOf(id);
        assertEq(c.buyer, bob);
        assertEq(c.feed, address(feed));
        assertEq(c.side, 0);
        assertEq(c.strikeBps, 200);
        assertEq(c.capBps, 1000);
        assertEq(c.notional, 10_000e6);
        assertEq(c.premium, 45e6, "what the pool kept");
        assertEq(c.refPrice, uint256(REF));
        assertEq(c.reopenAt, REOPEN);
        assertEq(c.boughtAt, SAT);
        assertFalse(c.settled);
        uint256[] memory ids = pool.coversOf(bob);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertEq(pool.nextId(), 2);
    }

    function test_buy_is_held_to_free_capital_and_the_stocks_exposure_cap() public {
        _saturday();
        // 25% of 100,000 is 25,000: a cover reserving 32,000 is over the stock's cap.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GapPool.OverExposure.selector, 32_000e6, 25_000e6));
        pool.buy(address(feed), 0, 400_000e6, 200, type(uint256).max);
        _buy(0, 300_000e6, 200); // 24,000 reserved; the kept premium lifts the cap a little
        uint256 allowed = pool.totalAssets() * 2500 / 10_000;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GapPool.OverExposure.selector, 25_600e6, allowed));
        pool.buy(address(feed), 1, 20_000e6, 200, type(uint256).max); // both sides count against one cap
        // With the cap lifted, free capital is the limit.
        vm.prank(owner);
        pool.setStock(address(feed), true, 10_000);
        uint256 free = pool.freeAssets();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GapPool.NotEnoughCapital.selector, 160_000e6, free));
        pool.buy(address(feed), 0, 2_000_000e6, 200, type(uint256).max);
    }

    /// Live covers across every stock never reserve more than the pool's total exposure, which never passes half.
    function test_buy_is_held_to_the_pools_total_exposure() public {
        vm.startPrank(owner);
        pool.setTotalExposure(3000);
        pool.setStock(address(feed2), true, 2500);
        vm.stopPrank();
        _saturday();
        _quoteFeed(address(feed2));
        _buy(0, 300_000e6, 200); // 24,000 reserved on the first stock: under its 25%
        uint256 total = pool.totalAssets();
        uint256 allowedAll = total * 3000 / 10_000;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GapPool.OverExposure.selector, 32_000e6, allowedAll));
        pool.buy(address(feed2), 0, 100_000e6, 200, type(uint256).max); // 8,000 more: under the stock's cap, over the pool's
        vm.prank(bob);
        uint256 id = pool.buy(address(feed2), 0, 50_000e6, 200, type(uint256).max); // 4,000 more: 28% of the pool
        assertEq(pool.totalReserved(), 28_000e6);
        (,,, uint256 reserved2) = pool.stocks(address(feed2));
        assertEq(reserved2, 4_000e6);
        // With no total exposure set, nothing can be reserved at all.
        vm.prank(owner);
        pool.setTotalExposure(0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GapPool.OverExposure.selector, 28_000e6 + 80e6, 0));
        pool.buy(address(feed2), 0, 1_000e6, 200, type(uint256).max);
        // The hard cap: even at MAX_TOTAL_EXPOSURE_BPS, half the pool is the most.
        vm.startPrank(owner);
        pool.setTotalExposure(5000);
        pool.setStock(address(feed), true, 10_000);
        vm.stopPrank();
        total = pool.totalAssets();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GapPool.OverExposure.selector, 28_000e6 + 24_000e6, total / 2));
        pool.buy(address(feed), 0, 300_000e6, 200, type(uint256).max);
        assertEq(pool.coverOf(id).feed, address(feed2));
    }

    // ------------------------------------------------------------------ settling

    function test_settle_up_pays_the_move_beyond_the_strike() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        uint256 total = pool.totalAssets();
        _monday(189e8); // +5%: 3% beyond the strike
        vm.expectEmit(true, true, true, true);
        emit GapPool.Settled(id, R_MON, 189e8, 300e6);
        vm.prank(eve); // anyone
        uint256 payout = pool.settle(id, R_MON);
        assertEq(payout, 300e6);
        assertEq(usdg.balanceOf(bob), 1_000_000e6 - 50e6 + 300e6);
        assertApproxEqAbs(pool.totalAssets(), total - 300e6, 2);
        assertEq(pool.totalReserved(), 0, "the reserve is released");
        assertEq(pool.freeAssets(), pool.totalAssets());
        assertEq(usdg.balanceOf(address(pool)), 0, "nothing left behind in the pool");
        assertTrue(pool.coverOf(id).settled);
        vm.expectRevert(GapPool.AlreadySettled.selector);
        pool.settle(id, R_MON);
        vm.warp(REOPEN + 7 days);
        vm.expectRevert(GapPool.AlreadySettled.selector);
        pool.void(id, R_MON);
    }

    function test_settle_pays_no_more_than_the_cap() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        _monday(207e8); // +15%, the cap is 10%
        assertEq(pool.settle(id, R_MON), 800e6, "cap less strike, on the notional: the whole reserve");
        assertEq(pool.totalReserved(), 0);
    }

    function test_settle_down_side_and_the_wrong_side_pays_nothing() public {
        _saturday();
        uint256 down = _buy(1, 10_000e6, 200);
        uint256 up = _buy(0, 10_000e6, 200);
        _monday(1728e7); // -4%
        assertEq(pool.settle(down, R_MON), 200e6);
        assertEq(pool.settle(up, R_MON), 0);
        assertEq(pool.totalReserved(), 0, "both reserves released");
        assertTrue(pool.coverOf(up).settled);
    }

    function test_settle_inside_the_strike_pays_nothing() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        _monday(1818e7); // +1%
        assertEq(pool.settle(id, R_MON), 0);
        assertEq(pool.totalReserved(), 0);
        assertTrue(pool.coverOf(id).settled);
    }

    function test_cover_keeps_the_cap_it_was_bought_at() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        vm.prank(owner);
        pool.setCapBps(300);
        _monday(207e8);
        assertEq(pool.settle(id, R_MON), 800e6);
    }

    function test_settle_only_with_the_first_round_after_the_reopen() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        _monday(189e8);
        feed.set(R_MON2, 190e8, REOPEN + 600);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_FRI); // before the reopen
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON2); // the round before it already printed after the reopen
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, PHASE | 13); // no such round
        vm.expectRevert(GapPool.NoCover.selector);
        pool.settle(99, R_MON);
        feed.set(R_MON, 0, REOPEN + 30);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON); // no answer
        feed.set(R_MON, 189e8, REOPEN + 30);
        assertEq(pool.settle(id, R_MON), 300e6);
    }

    function test_settle_with_a_phases_first_round_skips_the_previous_round_check() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        uint80 first = (uint80(2) << 64) | 1;
        feed.set(first, 189e8, REOPEN + 30);
        // Its "previous" round, (2 << 64) | 0, does not exist; a new phase's first round is taken on its own.
        vm.warp(REOPEN + 60);
        assertEq(pool.settle(id, first), 300e6);
    }

    /// The first print after the reopen settles only if it landed within SETTLE_WINDOW of the reopen. Later, it is
    /// not a Monday gap but days of weekday risk, and the cover is void.
    function test_settle_only_within_the_window_after_the_reopen() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        uint256 late = _buy(0, 10_000e6, 200);
        feed.set(R_MON, 207e8, REOPEN + 2 hours); // exactly at the window's edge
        vm.warp(REOPEN + 2 hours + 1);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        assertEq(pool.settle(id, R_MON), 800e6);

        feed.set(R_MON, 207e8, REOPEN + 2 hours + 1); // a second too late
        vm.warp(REOPEN + 3 hours);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(late, R_MON);
        vm.warp(REOPEN + 30 days);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(late, R_MON); // never, however long one waits
        assertFalse(pool.coverOf(late).settled);
    }

    /// A first print further than MAX_MOVE_BPS from the reference is bad data, not a gap: it never settles.
    function test_settle_only_within_the_max_move() public {
        _saturday();
        uint256 up = _buy(0, 10_000e6, 200);
        uint256 down = _buy(1, 10_000e6, 200);
        uint256 up2 = _buy(0, 10_000e6, 200);
        uint256 down2 = _buy(1, 10_000e6, 200);
        uint256 up3 = _buy(0, 10_000e6, 200);
        _monday(270e8); // exactly +50%
        assertEq(pool.settle(up, R_MON), 800e6);
        assertEq(pool.settle(down, R_MON), 0);

        feed.set(R_MON, 270e8 + 2e6, REOPEN + 30); // a basis point past +50%
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(up2, R_MON);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(down2, R_MON);
        feed.set(R_MON, 90e8, REOPEN + 30); // exactly -50%
        assertEq(pool.settle(down2, R_MON), 800e6);
        assertEq(pool.settle(up2, R_MON), 0);

        feed.set(R_MON, 90e8 - 2e6, REOPEN + 30); // a basis point past -50%
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(up3, R_MON);
        assertFalse(pool.coverOf(up3).settled);
    }

    // ------------------------------------------------------------------ voiding

    /// Void, case one: the feed has not printed since the reopen and SETTLE_GRACE has passed. The round id is ignored.
    function test_void_a_feed_that_never_printed_after_the_grace() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        vm.warp(REOPEN + 7 days - 1);
        vm.expectRevert(GapPool.TooSoon.selector);
        pool.void(id, 0);
        vm.expectRevert(GapPool.TooSoon.selector);
        pool.void(id, R_MON);
        vm.expectRevert(GapPool.NoCover.selector);
        pool.void(99, 0);
        vm.warp(REOPEN + 7 days);
        uint256 total = pool.totalAssets();
        vm.expectEmit(true, true, true, true);
        emit GapPool.Voided(id, 45e6);
        vm.prank(eve);
        pool.void(id, 0);
        assertEq(usdg.balanceOf(bob), 1_000_000e6 - 50e6 + 45e6, "the premium less the fee");
        assertEq(usdg.balanceOf(keeper), 5e6, "the fee stays paid");
        assertApproxEqAbs(pool.totalAssets(), total - 45e6, 2);
        assertEq(pool.totalReserved(), 0);
        assertTrue(pool.coverOf(id).settled);
        vm.expectRevert(GapPool.AlreadySettled.selector);
        pool.void(id, 0);
        feed.set(R_MON, 207e8, REOPEN + 30);
        vm.expectRevert(GapPool.AlreadySettled.selector);
        pool.settle(id, R_MON);
    }

    /// Void, case two: the first round after the reopen landed after SETTLE_WINDOW. No grace to wait for, but the
    /// round must be the first one, proven as settle proves it.
    function test_void_a_first_round_that_landed_after_the_window() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        feed.set(R_MON, 207e8, REOPEN + 2 hours + 1);
        feed.set(R_MON2, 208e8, REOPEN + 3 hours);
        vm.warp(REOPEN + 3 hours + 1);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, R_FRI); // printed before the reopen
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, R_MON2); // not the first round after it
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, PHASE | 13); // no such round
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON);
        uint256 total = pool.totalAssets();
        vm.expectEmit(true, true, true, true);
        emit GapPool.Voided(id, 45e6);
        vm.prank(ann); // a seller may void it: the buyer loses nothing but the fee
        pool.void(id, R_MON);
        assertEq(usdg.balanceOf(bob), 1_000_000e6 - 50e6 + 45e6);
        assertApproxEqAbs(pool.totalAssets(), total - 45e6, 2);
        assertEq(pool.totalReserved(), 0);
        assertTrue(pool.coverOf(id).settled);
    }

    /// Void, case three: the first round after the reopen is further than MAX_MOVE_BPS from the reference.
    function test_void_a_first_round_beyond_the_max_move() public {
        _saturday();
        uint256 id = _buy(1, 10_000e6, 200);
        uint256 id2 = _buy(0, 10_000e6, 200);
        feed.set(R_MON, 1e8, REOPEN + 30); // the feed printed one dollar: -99%
        vm.warp(REOPEN + 60);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON);
        vm.expectEmit(true, true, true, true);
        emit GapPool.Voided(id, 45e6);
        pool.void(id, R_MON);
        assertEq(usdg.balanceOf(bob), 1_000_000e6 - 100e6 + 45e6);
        assertEq(pool.totalReserved(), 800e6, "the other cover's reserve");
        // The same for a wild print up, and for a zero answer (no answer is not a first round, so WrongRound).
        id = id2;
        feed.set(R_MON, 0, REOPEN + 30);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, R_MON);
        feed.set(R_MON, 1_000e8, REOPEN + 30);
        pool.void(id, R_MON);
        assertEq(pool.totalReserved(), 0);
    }

    /// A cover that can be settled can never be voided: not before the grace, not after it.
    function test_void_refuses_a_settleable_cover() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        feed.set(R_MON, 189e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        vm.warp(REOPEN + 7 days);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        vm.warp(REOPEN + 30 days);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        // Nor with a round that is not the first: that is not a proof of anything.
        feed.set(R_MON2, 300e8, REOPEN + 3 hours);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, R_MON2);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, R_FRI);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, 0);
        assertFalse(pool.coverOf(id).settled);
        assertEq(pool.settle(id, R_MON), 300e6, "settled, however late");
    }

    /// A cover whose first print lands inside the strike is worth nothing and still cannot be voided: the premium
    /// is the sellers'.
    function test_void_cannot_hand_a_losing_buyer_the_premium_back() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        feed.set(R_MON, 1818e7, REOPEN + 30); // +1%
        vm.warp(REOPEN + 8 days);
        vm.prank(bob);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        uint256 before = usdg.balanceOf(bob);
        assertEq(pool.settle(id, R_MON), 0);
        assertEq(usdg.balanceOf(bob), before);
    }

    function test_a_feed_that_printed_can_still_be_settled_after_the_grace() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        feed.set(R_MON, 189e8, REOPEN + 30);
        vm.warp(REOPEN + 30 days);
        assertEq(pool.settle(id, R_MON), 300e6);
    }

    // ------------------------------------------------------------------ payouts the buyer cannot receive

    function _frozenPool() internal returns (FreezableTok fusdg, GapPool p) {
        fusdg = new FreezableTok();
        MockVault v = new MockVault(fusdg);
        p = new GapPool(fusdg, IHeldVault(address(v)), owner, _one(address(feed)));
        vm.startPrank(owner);
        p.setQuoter(keeper);
        p.setFee(1000, keeper);
        p.setCapBps(1000);
        p.setPremiumBounds(5, 2000);
        p.setTotalExposure(5000);
        p.setStock(address(feed), true, 2500);
        vm.stopPrank();
        fusdg.mint(ann, 100_000e6);
        fusdg.mint(bob, 1_000e6);
        vm.startPrank(ann);
        fusdg.approve(address(p), type(uint256).max);
        p.deposit(100_000e6, ann);
        vm.stopPrank();
        vm.prank(bob);
        fusdg.approve(address(p), type(uint256).max);
        vm.warp(SAT);
        uint16[] memory s = new uint16[](1);
        uint16[] memory pr = new uint16[](1);
        (s[0], pr[0]) = (200, 50);
        vm.startPrank(keeper);
        p.setQuotes(address(feed), 0, s, pr);
        p.setQuotes(address(feed), 1, s, pr);
        vm.stopPrank();
    }

    /// USDG's transfer returns false for the buyer: the settlement goes through, the payout waits in `owed`, and the
    /// buyer claims it to any address once it can.
    function test_settlement_a_buyer_cannot_receive_is_held_for_claim() public {
        (FreezableTok fusdg, GapPool p) = _frozenPool();
        vm.prank(bob);
        uint256 id = p.buy(address(feed), 0, 10_000e6, 200, type(uint256).max);
        fusdg.freeze(bob, 1); // returns false
        _monday(189e8);
        uint256 total = p.totalAssets();
        vm.expectEmit(true, true, true, true);
        emit GapPool.Owed(bob, 300e6);
        vm.expectEmit(true, true, true, true);
        emit GapPool.Settled(id, R_MON, 189e8, 300e6);
        assertEq(p.settle(id, R_MON), 300e6);
        assertTrue(p.coverOf(id).settled, "settled all the same");
        assertEq(p.totalReserved(), 0);
        assertEq(p.owed(bob), 300e6);
        assertEq(fusdg.balanceOf(bob), 1_000e6 - 50e6, "nothing arrived");
        assertEq(fusdg.balanceOf(address(p)), 300e6, "the USDG waits in the pool, outside the vault");
        assertApproxEqAbs(p.totalAssets(), total - 300e6, 2, "and outside the sellers' capital");
        // Nobody else can take it, and the owner cannot sweep it.
        vm.prank(eve);
        vm.expectRevert(GapPool.Nothing.selector);
        p.claim(eve);
        vm.prank(owner);
        vm.expectRevert(GapPool.CannotSweep.selector);
        p.sweep(fusdg, owner);
        // While frozen, the claim fails (SafeERC20 refuses a false) and the credit stays.
        vm.prank(bob);
        vm.expectRevert();
        p.claim(bob);
        assertEq(p.owed(bob), 300e6);
        // Bob claims it to another address.
        vm.expectEmit(true, true, true, true);
        emit GapPool.Claimed(bob, eve, 300e6);
        vm.prank(bob);
        assertEq(p.claim(eve), 300e6);
        assertEq(fusdg.balanceOf(eve), 300e6);
        assertEq(p.owed(bob), 0);
        assertEq(fusdg.balanceOf(address(p)), 0);
        vm.prank(bob);
        vm.expectRevert(GapPool.Nothing.selector);
        p.claim(eve);
    }

    /// USDG's transfer reverts for the buyer: the same, and a void's refund is held the same way.
    function test_void_refund_a_buyer_cannot_receive_is_held_for_claim() public {
        (FreezableTok fusdg, GapPool p) = _frozenPool();
        vm.prank(bob);
        uint256 id = p.buy(address(feed), 0, 10_000e6, 200, type(uint256).max);
        vm.prank(bob);
        uint256 id2 = p.buy(address(feed), 1, 10_000e6, 200, type(uint256).max);
        fusdg.freeze(bob, 2); // reverts
        vm.warp(REOPEN + 7 days);
        vm.expectEmit(true, true, true, true);
        emit GapPool.Owed(bob, 45e6);
        vm.expectEmit(true, true, true, true);
        emit GapPool.Voided(id, 45e6);
        p.void(id, 0);
        assertEq(p.owed(bob), 45e6);
        assertTrue(p.coverOf(id).settled);
        // A second credit adds up.
        feed.set(R_MON, 1e8, REOPEN + 30); // a wild print: the second cover is void too
        p.void(id2, R_MON);
        assertEq(p.owed(bob), 90e6);
        assertEq(p.totalReserved(), 0);
        assertEq(fusdg.balanceOf(address(p)), 90e6);
        fusdg.freeze(bob, 0);
        vm.prank(bob);
        assertEq(p.claim(bob), 90e6);
        assertEq(fusdg.balanceOf(bob), 1_000e6 - 100e6 + 90e6);
    }

    /// A payout is clamped to what the pool holds: only short if the vault itself lost money.
    function test_payout_is_clamped_to_the_pools_assets() public {
        vm.prank(owner);
        pool.setStock(address(feed), true, 10_000);
        _fund(1_000e6);
        vm.warp(SAT);
        _quote();
        uint256 id = _buy(0, 5_000e6, 200); // 400 reserved of 1,022
        vault.lose(700e6);
        uint256 total = pool.totalAssets();
        assertLt(total, 400e6);
        _monday(207e8); // worth the whole 400
        vm.expectEmit(true, true, true, true);
        emit GapPool.Settled(id, R_MON, 207e8, total);
        uint256 before = usdg.balanceOf(bob);
        assertEq(pool.settle(id, R_MON), total);
        assertEq(usdg.balanceOf(bob) - before, total);
        assertLe(pool.totalAssets(), 1);
        assertEq(pool.totalReserved(), 0);
    }

    // ------------------------------------------------------------------ withdrawals and pauses

    /// Capital is locked from the first buy of a closure until the last cover of it has settled or been voided, so a
    /// seller cannot leave on Sunday night ahead of a loss that lands on Monday.
    function test_withdraw_is_locked_while_any_cover_is_live() public {
        _saturday();
        uint256 shares = pool.balanceOf(ann);
        vm.prank(ann);
        pool.withdraw(shares / 10, ann); // free before the first buy
        uint256 a = _buy(0, 10_000e6, 200);
        uint256 b = _buy(1, 10_000e6, 200);
        vm.startPrank(ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(1, ann); // not even a wei of what no cover reserves
        vm.warp(REOPEN - 1 hours); // Sunday evening, with the perp showing the gap
        uint256 all = pool.balanceOf(ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(all, ann);
        vm.stopPrank();
        _monday(207e8);
        assertEq(pool.settle(a, R_MON), 800e6);
        vm.prank(ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(1, ann); // one cover still live
        assertEq(pool.settle(b, R_MON), 0);
        assertEq(pool.totalReserved(), 0);
        uint256 rest = pool.balanceOf(ann);
        vm.prank(ann);
        uint256 got = pool.withdraw(rest, ann);
        assertApproxEqAbs(got, 90_000e6 + 90e6 - 800e6, 3, "the loss and the premiums, borne by the capital that stayed");
        assertEq(pool.balanceOf(ann), 0);
    }

    function test_withdraw_is_free_again_after_a_void() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        vm.warp(REOPEN + 7 days);
        vm.prank(ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(1, ann);
        pool.void(id, 0);
        uint256 shares = pool.balanceOf(ann);
        vm.prank(ann);
        uint256 got = pool.withdraw(shares, ann);
        assertApproxEqAbs(got, 100_000e6, 3, "the premium went back, the capital is whole");
    }

    function test_pauses_stop_only_buys_and_deposits() public {
        _saturday();
        uint256 id = _buy(0, 10_000e6, 200);
        vm.prank(owner);
        pool.setPaused(true, true);
        assertTrue(pool.buysPaused());
        assertTrue(pool.depositsPaused());
        vm.prank(ann);
        vm.expectRevert(GapPool.Paused.selector);
        pool.deposit(1e6, ann);
        vm.prank(bob);
        vm.expectRevert(GapPool.Paused.selector);
        pool.buy(address(feed), 0, 1_000e6, 200, type(uint256).max);
        _monday(189e8);
        assertEq(pool.settle(id, R_MON), 300e6, "settlement is never stopped");
        vm.prank(ann);
        assertGt(pool.withdraw(1e12, ann), 0, "nor a withdrawal");
    }

    function test_fee_can_be_zero_and_the_whole_premium_is_kept() public {
        vm.prank(owner);
        pool.setFee(0, keeper);
        _saturday();
        uint256 total = pool.totalAssets();
        uint256 id = _buy(0, 10_000e6, 200);
        assertEq(usdg.balanceOf(keeper), 0);
        assertApproxEqAbs(pool.totalAssets(), total + 50e6, 2);
        assertEq(pool.coverOf(id).premium, 50e6);
    }

    // ------------------------------------------------------------------ fuzz

    /// Whatever the print, the strike, the notional and the side: a buy that pays or reserves nothing is refused;
    /// a first print inside MAX_MOVE_BPS settles for at most the reserve, paid in full, and one outside it voids for
    /// exactly the kept premium; either way the reserve is released exactly once and the capital unlocks.
    function testFuzz_payout_within_reserve_and_released_once(uint256 answerSeed, uint16 strike, uint96 notional, uint8 side)
        public
    {
        strike = uint16(bound(strike, 50, 999));
        side = side % 2;
        notional = uint96(bound(notional, 1, 1e15));
        int256 answer = int256(bound(answerSeed, 1, 1_000e8)); // from a 100% fall to a fivefold rise
        vm.prank(owner);
        pool.setStock(address(feed), true, 10_000);
        usdg.mint(ann, 1e16);
        _fund(1e16);
        usdg.mint(bob, 1e16);
        vm.warp(SAT);
        uint16[] memory s = new uint16[](1);
        uint16[] memory p = new uint16[](1);
        (s[0], p[0]) = (strike, 100);
        vm.prank(keeper);
        pool.setQuotes(address(feed), side, s, p);

        uint256 reserve = pool.reserveFor(notional, strike);
        (uint256 premium,) = pool.premiumFor(address(feed), side, notional, strike);
        if (reserve == 0 || premium == 0) {
            vm.prank(bob);
            vm.expectRevert(GapPool.Nothing.selector);
            pool.buy(address(feed), side, notional, strike, type(uint256).max);
            assertEq(pool.totalReserved(), 0);
            return;
        }
        uint256 id = _buy(side, notional, strike);
        assertEq(pool.totalReserved(), reserve);
        assertLe(reserve, pool.totalAssets());
        vm.prank(ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(1, ann);

        _monday(answer);
        uint256 before = usdg.balanceOf(bob);
        int256 move = (answer - REF) * 10_000 / REF;
        if (uint256(move < 0 ? -move : move) > 5_000) {
            vm.expectRevert(GapPool.WrongRound.selector);
            pool.settle(id, R_MON);
            pool.void(id, R_MON);
            assertEq(usdg.balanceOf(bob) - before, pool.coverOf(id).premium, "the kept premium back, nothing more");
        } else {
            vm.expectRevert(GapPool.Settleable.selector);
            pool.void(id, R_MON);
            uint256 payout = pool.settle(id, R_MON);
            assertLe(payout, reserve, "never above the reserve");
            assertEq(usdg.balanceOf(bob) - before, payout, "paid in full");
        }
        assertEq(pool.totalReserved(), 0, "released");
        (,,, uint256 reserved) = pool.stocks(address(feed));
        assertEq(reserved, 0);
        assertEq(pool.freeAssets(), pool.totalAssets());
        assertEq(usdg.balanceOf(address(pool)), 0, "nothing stranded in the pool");
        vm.expectRevert(GapPool.AlreadySettled.selector);
        pool.settle(id, R_MON);
        vm.warp(REOPEN + 7 days);
        vm.expectRevert(GapPool.AlreadySettled.selector);
        pool.void(id, R_MON);
        vm.prank(ann);
        assertGt(pool.withdraw(1e12, ann), 0, "unlocked");
    }
}

/// MarketHours.nextOpen: the first open moment at or after a time.
contract MarketHoursNextOpenTest is Test {
    function test_saturday_reopens_sunday_evening() public pure {
        assertEq(MarketHours.nextOpen(1791644400), 1791763200); // Sat 2026-10-10 15:00 UTC -> Mon 2026-10-12 00:00 UTC
        assertEq(MarketHours.nextOpen(1791590400), 1791763200); // Fri 20:00 New York exactly, the first shut second
    }

    function test_sunday_evening_new_york() public pure {
        assertEq(MarketHours.nextOpen(1791763140), 1791763200); // Sunday 19:59 New York (EDT)
        assertEq(MarketHours.nextOpen(1791763200), 1791763200); // Sunday 20:00: open, itself
        assertEq(MarketHours.nextOpen(1791763260), 1791763260); // Sunday 20:01: open, itself
    }

    function test_open_time_is_itself() public pure {
        assertEq(MarketHours.nextOpen(1791568800), 1791568800); // Friday 2026-10-09 18:00 UTC
    }

    /// Thanksgiving 2026-11-26: shut from Wednesday 20:00 to Thursday 20:00 New York (EST), which opens Friday's session.
    function test_holiday() public pure {
        assertEq(MarketHours.nextOpen(1795658400), 1795741200); // Wed 21:00 EST -> Thu 20:00 EST = Fri 01:00 UTC
        assertEq(MarketHours.nextOpen(1795654800), 1795741200); // Wed 20:00 EST exactly
        assertTrue(MarketHours.isOpen(1795741200));
        assertFalse(MarketHours.isOpen(1795741199));
    }

    /// Christmas 2026 falls on a Friday: shut from Thursday 20:00 EST through the weekend to Sunday 20:00 EST.
    function test_holiday_into_a_weekend() public pure {
        assertEq(MarketHours.nextOpen(1798419600 - 3 days), 1798419600); // Fri 2026-12-25 01:00 UTC -> Mon 12-28 01:00 UTC
    }

    /// The weekend daylight saving ends (2026-11-01): Friday closes at 00:00 UTC, Sunday opens at 01:00 UTC.
    function test_dst_change_weekend_november_2026() public pure {
        assertFalse(MarketHours.isOpen(1793404800)); // Sat 2026-10-31 00:00 UTC = Fri 20:00 EDT
        assertEq(MarketHours.nextOpen(1793448000), 1793581200); // Sat 12:00 UTC -> Mon 2026-11-02 01:00 UTC = Sun 20:00 EST
        assertTrue(MarketHours.isOpen(1793581200));
        assertFalse(MarketHours.isOpen(1793581199));
        assertEq(MarketHours.nextOpen(1793581199), 1793581200);
    }

    /// Any moment 2026 to 2029: nextOpen is at or after it, is open, and the second before it (if later) is shut.
    function testFuzz_nextOpen_is_the_first_open_moment(uint256 t) public pure {
        t = bound(t, 1767225600, 1893456000);
        uint256 n = MarketHours.nextOpen(t);
        assertGe(n, t);
        assertTrue(MarketHours.isOpen(n));
        if (n > t) {
            assertFalse(MarketHours.isOpen(n - 1));
            assertFalse(MarketHours.isOpen(t));
            assertLe(n - t, 4 days, "no closure on the calendar is longer than a long weekend");
        }
    }
}
