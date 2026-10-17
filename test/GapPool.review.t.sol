// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GapPool, IHeldVault, IPriceFeed} from "../src/GapPool.sol";
import {MarketHours} from "../src/eth/MarketHours.sol";
import {Tok, MockFeed, MockVault} from "./GapPool.t.sol";
import {BorroLib} from "../script/BorroLib.sol";

/// A vault whose withdrawals can be switched off, the way Vault V2's exit reverts when the liquidity adapter's market
/// has nothing to deallocate.
contract IlliquidVault is ERC20 {
    IERC20 public immutable asset;
    uint256 constant VS = 1e12;
    bool public illiquid;

    constructor(IERC20 a) ERC20("Illiquid", "ILL") {
        asset = a;
    }

    function setIlliquid(bool v) external {
        illiquid = v;
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

    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares) {
        shares = previewDeposit(assets);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(onBehalf, shares);
    }

    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares) {
        require(!illiquid, "no liquidity");
        shares = (assets * (totalSupply() + VS) + totalAssets()) / (totalAssets() + 1);
        _burn(onBehalf, shares);
        asset.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets) {
        require(!illiquid, "no liquidity");
        assets = convertToAssets(shares);
        _burn(onBehalf, shares);
        asset.transfer(receiver, assets);
    }
}

/// Adversarial review of GapPool. Each test began as a reproduction of a way money was lost, stuck or taken; each
/// now asserts that the contract blocks it.
contract GapPoolReviewTest is Test {
    uint80 constant PHASE = uint80(1) << 64;
    uint80 constant R_FRI = PHASE | 10;
    uint80 constant R_MON = PHASE | 11;
    uint80 constant R_MON2 = PHASE | 12;
    uint256 constant FRI = 1791568800; // 2026-10-09 18:00 UTC, open
    uint256 constant SAT = 1791644400; // 2026-10-10 15:00 UTC, closed
    uint256 constant REOPEN = 1791763200; // 2026-10-12 00:00 UTC
    int256 constant REF = 180e8;

    Tok usdg;
    MockVault vault;
    MockFeed feed;
    GapPool pool;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address ann = makeAddr("ann");
    address carl = makeAddr("carl");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function setUp() public {
        vm.warp(FRI);
        usdg = new Tok("USDG", 6);
        vault = new MockVault(usdg);
        feed = new MockFeed();
        feed.set(R_FRI, REF, FRI);
        pool = new GapPool(usdg, IHeldVault(address(vault)), owner, _one(address(feed)));
        _setup(pool, address(feed));
        for (uint256 i; i < 4; i++) {
            address who = [ann, carl, bob, eve][i];
            usdg.mint(who, 1_000_000e6);
            vm.prank(who);
            usdg.approve(address(pool), type(uint256).max);
        }
    }

    function _one(address a) internal pure returns (address[] memory f) {
        f = new address[](1);
        f[0] = a;
    }

    function _setup(GapPool p, address f) internal {
        vm.startPrank(owner);
        p.setQuoter(keeper);
        p.setFee(1000, keeper);
        p.setCapBps(1000);
        p.setPremiumBounds(5, 2000);
        p.setTotalExposure(5000); // the hard cap, so the per-stock cap is what each test sets
        p.setStock(f, true, 2500);
        vm.stopPrank();
    }

    function _quote(GapPool p, address f) internal {
        uint16[] memory s = new uint16[](4);
        uint16[] memory pr = new uint16[](4);
        (s[0], s[1], s[2], s[3]) = (100, 200, 300, 500);
        (pr[0], pr[1], pr[2], pr[3]) = (80, 50, 30, 10);
        vm.startPrank(keeper);
        p.setQuotes(f, 0, s, pr);
        p.setQuotes(f, 1, s, pr);
        vm.stopPrank();
    }

    function _buy(address who, uint8 side, uint96 notional, uint16 strike) internal returns (uint256 id) {
        vm.prank(who);
        id = pool.buy(address(feed), side, notional, strike, type(uint256).max);
    }

    // ------------------------------------------------------------------ 1. a run on the pool

    /// Two sellers fund the pool equally. A cover is sold that reserves 20% of it. On Sunday evening the perp shows the
    /// cover will pay in full. The fast seller tries to withdraw everything they hold: the capital is locked while a
    /// cover is live, so both sellers bear the loss alike.
    function test_run_on_the_pool_fast_seller_cannot_escape_the_loss() public {
        vm.prank(ann);
        uint256 annShares = pool.deposit(50_000e6, ann);
        vm.prank(carl);
        uint256 carlShares = pool.deposit(50_000e6, carl);
        vm.warp(SAT);
        _quote(pool, address(feed));
        vm.prank(owner);
        pool.setStock(address(feed), true, 10_000);
        // 250,000 notional at strike 200, cap 1000: reserves 20,000 (20% of the pool). Premium 1,250, fee 125.
        uint256 id = _buy(bob, 0, 250_000e6, 200);
        assertEq(pool.totalReserved(), 20_000e6);

        // Sunday 19:00 New York: the perp says NVDA is +12%. Ann tries to leave with every cent she holds, then with
        // only what no cover reserves.
        vm.warp(REOPEN - 1 hours);
        uint256 halfTheFree = pool.convertToShares(pool.freeAssets()) / 2;
        vm.startPrank(ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(annShares, ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(halfTheFree, ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(1, ann);
        vm.stopPrank();

        feed.set(R_MON, 2016e7, REOPEN + 30); // +12%: the full 8% room past the strike
        vm.warp(REOPEN + 60);
        assertEq(pool.settle(id, R_MON), 20_000e6);
        uint256 annOut = pool.convertToAssets(annShares);
        uint256 carlOut = pool.convertToAssets(carlShares);
        assertEq(annOut, carlOut, "the loss falls on every seller alike");
        assertApproxEqAbs(annOut, 50_000e6 + 1_125e6 / 2 - 10_000e6, 10, "half the premium, half the loss");
        vm.prank(ann);
        assertEq(pool.withdraw(annShares, ann), annOut, "free to leave once the cover has settled");
    }

    // ------------------------------------------------------------------ 2. void cannot race settle

    /// The feed printed on Monday; nobody settled for seven days (a keeper down, a buyer not watching). After the
    /// grace, void is still refused: a cover that can be settled can never be voided, so the losing buyer cannot take
    /// the premium back and the winning buyer cannot be stripped of the payout.
    function test_void_after_grace_cannot_hand_a_losing_buyer_the_premium_back() public {
        vm.prank(ann);
        pool.deposit(100_000e6, ann);
        vm.warp(SAT);
        _quote(pool, address(feed));
        uint256 id = _buy(bob, 0, 10_000e6, 200);
        feed.set(R_MON, 1818e7, REOPEN + 30); // +1%: inside the strike, the cover is worth nothing
        vm.warp(REOPEN + 7 days);
        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        vm.prank(bob);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, R_FRI); // nor with a round that proves nothing
        vm.warp(REOPEN + 60 days);
        vm.prank(bob);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        assertFalse(pool.coverOf(id).settled);
        assertEq(pool.settle(id, R_MON), 0);
        assertEq(usdg.balanceOf(bob), before, "the premium is the sellers'");
        assertEq(pool.totalReserved(), 0);
    }

    function test_void_after_grace_cannot_strip_a_winning_buyer_of_the_payout() public {
        vm.prank(ann);
        pool.deposit(100_000e6, ann);
        vm.warp(SAT);
        _quote(pool, address(feed));
        uint256 id = _buy(bob, 0, 10_000e6, 200);
        feed.set(R_MON, 207e8, REOPEN + 30); // +15%: the cover is worth the whole 800 reserve
        vm.warp(REOPEN + 7 days);
        uint256 before = usdg.balanceOf(bob);
        vm.prank(ann); // the seller
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        vm.prank(ann);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, 0);
        assertEq(pool.settle(id, R_MON), 800e6);
        assertEq(usdg.balanceOf(bob) - before, 800e6, "bob got his 800");
    }

    // ------------------------------------------------------------------ 3. an illiquid vault cannot strand the settlement

    /// Vault V2's withdraw deallocates from the liquidity adapter's Morpho market; at full utilization that reverts.
    /// While it reverts, settle reverts, and so does void: the cover stays live until liquidity returns, and then it
    /// settles for the full payout. The reserve is never turned into a premium refund.
    function test_vault_illiquidity_delays_a_winning_cover_but_cannot_void_it() public {
        IlliquidVault ill = new IlliquidVault(usdg);
        GapPool p = new GapPool(usdg, IHeldVault(address(ill)), owner, _one(address(feed)));
        _setup(p, address(feed));
        vm.startPrank(ann);
        usdg.approve(address(p), type(uint256).max);
        p.deposit(100_000e6, ann);
        vm.stopPrank();
        vm.warp(SAT);
        _quote(p, address(feed));
        vm.startPrank(bob);
        usdg.approve(address(p), type(uint256).max);
        uint256 id = p.buy(address(feed), 0, 10_000e6, 200, type(uint256).max);
        vm.stopPrank();
        feed.set(R_MON, 207e8, REOPEN + 30);
        vm.warp(REOPEN + 60);
        ill.setIlliquid(true);
        vm.expectRevert("no liquidity");
        p.settle(id, R_MON);
        vm.warp(REOPEN + 7 days);
        vm.expectRevert("no liquidity");
        p.settle(id, R_MON);
        vm.prank(ann);
        vm.expectRevert(GapPool.Settleable.selector);
        p.void(id, R_MON); // the seller cannot void it while the vault is stuck
        vm.prank(ann);
        vm.expectRevert(GapPool.Locked.selector);
        p.withdraw(1, ann); // nor leave
        assertFalse(p.coverOf(id).settled);
        // Liquidity returns: the cover settles in full.
        ill.setIlliquid(false);
        vm.prank(ann);
        vm.expectRevert(GapPool.Settleable.selector);
        p.void(id, R_MON);
        uint256 before = usdg.balanceOf(bob);
        assertEq(p.settle(id, R_MON), 800e6);
        assertEq(usdg.balanceOf(bob) - before, 800e6);
        assertEq(p.totalReserved(), 0);
    }

    // ------------------------------------------------------------------ 4. The owner cannot reach capital

    /// The owner tries to list a feed it controls, to name itself quoter, post the floor premium and settle against
    /// its own rounds. The feeds are fixed at deploy: it cannot add one. On the real feed it is bound like any buyer,
    /// and it cannot reserve more than the pool's total exposure, which never passes half.
    function test_owner_cannot_add_a_feed_or_reserve_more_than_the_total_exposure() public {
        vm.prank(ann);
        pool.deposit(100_000e6, ann);
        MockFeed fake = new MockFeed();
        fake.set(PHASE | 1, 100e8, FRI);
        vm.startPrank(owner);
        vm.expectRevert(GapPool.NotListed.selector);
        pool.setStock(address(fake), true, 10_000);
        (address listed,,,) = pool.stocks(address(fake));
        assertEq(listed, address(0));
        // Without a listing there are no quotes and no buys on it either.
        pool.setQuoter(owner);
        uint16[] memory s = new uint16[](1);
        uint16[] memory pr = new uint16[](1);
        (s[0], pr[0]) = (50, 1);
        pool.setPremiumBounds(1, 2000);
        pool.setCapBps(2000);
        vm.expectRevert(GapPool.NotAllowed.selector);
        pool.setQuotes(address(fake), 0, s, pr);
        // The exposure: 50% of the pool is the most the owner can allow, per stock or in all.
        vm.expectRevert(GapPool.BadValue.selector);
        pool.setTotalExposure(5001);
        pool.setTotalExposure(5000);
        pool.setStock(address(feed), true, 10_000);
        vm.stopPrank();
        vm.warp(SAT);
        vm.prank(owner);
        pool.setQuotes(address(feed), 0, s, pr);
        vm.warp(SAT);
        vm.prank(bob);
        vm.expectRevert(GapPool.NotAllowed.selector);
        pool.buy(address(fake), 0, 1_000e6, 50, type(uint256).max);
        // Reserve = notional * 1950 / 10000 = everything free: over the total exposure.
        uint96 notional = uint96(pool.freeAssets() * 10_000 / 1950);
        uint256 reserve = uint256(notional) * 1950 / 10_000;
        uint256 allowedAll = pool.totalAssets() * 5000 / 10_000;
        usdg.mint(owner, 1_000e6);
        vm.startPrank(owner);
        usdg.approve(address(pool), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GapPool.OverExposure.selector, reserve, allowedAll));
        pool.buy(address(feed), 0, notional, 50, type(uint256).max);
        // Half the pool, on the real feed, is the most any buyer can hold against the sellers.
        notional = uint96(allowedAll * 10_000 / 1950);
        uint256 id = pool.buy(address(feed), 0, notional, 50, type(uint256).max);
        vm.stopPrank();
        assertLe(pool.totalReserved(), allowedAll);
        assertGe(pool.freeAssets(), pool.totalAssets() / 2);
        // And the real feed decides what it pays: a print that is not a gap but a wild number settles nothing.
        feed.set(R_MON, 360e8 + 2e6, REOPEN + 30); // past +100%: beyond MAX_MOVE_BPS
        vm.warp(REOPEN + 60);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON);
        uint256 before = usdg.balanceOf(owner);
        pool.void(id, R_MON);
        uint256 premium = uint256(notional) / 10_000;
        assertEq(usdg.balanceOf(owner) - before, premium - premium * 1000 / 10_000, "its own premium back, less the fee");
    }

    // ------------------------------------------------------------------ 5. no free covers

    /// premium = notional * bps / 10_000 rounds to zero for a small notional; the reserve does not. The buy is refused.
    function test_premium_that_rounds_to_zero_is_refused() public {
        vm.prank(ann);
        pool.deposit(100_000e6, ann);
        vm.warp(SAT);
        uint16[] memory s = new uint16[](1);
        uint16[] memory pr = new uint16[](1);
        (s[0], pr[0]) = (50, 5);
        vm.prank(keeper);
        pool.setQuotes(address(feed), 0, s, pr);
        assertEq(pool.reserveFor(1_999, 50), 189, "would have reserved 189 wei");
        vm.prank(bob);
        vm.expectRevert(GapPool.Nothing.selector);
        pool.buy(address(feed), 0, 1_999, 50, type(uint256).max); // 1,999 wei notional: premium 0
        assertEq(pool.totalReserved(), 0);
        assertEq(pool.nextId(), 1, "no cover");
        assertEq(pool.coversOf(bob).length, 0);
    }

    // ------------------------------------------------------------------ 6. a phase change hours later gives no choice

    /// After an aggregator upgrade the proxy serves both phases. Phase 2's round 1 is checked on its own (nothing
    /// before it), but it must still land within SETTLE_WINDOW of the reopen: a new phase hours later cannot settle.
    /// (A phase change inside the two-hour window would still leave the settler a choice: a Chainlink operational
    /// event the window cannot rule out.)
    function test_phase_change_hours_after_the_reopen_cannot_settle() public {
        vm.prank(ann);
        pool.deposit(100_000e6, ann);
        vm.warp(SAT);
        _quote(pool, address(feed));
        uint256 a = _buy(bob, 0, 10_000e6, 200);
        uint256 b = _buy(bob, 0, 10_000e6, 200);
        feed.set(R_MON, 1818e7, REOPEN + 30); // the true first print: +1%, worth nothing
        uint80 p2first = (uint80(2) << 64) | 1;
        feed.set(p2first, 189e8, REOPEN + 6 hours); // the new aggregator's first round, hours later: +5%
        vm.warp(REOPEN + 7 hours);
        assertEq(pool.settle(a, R_MON), 0);
        vm.prank(bob);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(b, p2first);
        assertEq(pool.settle(b, R_MON), 0, "the same answer for the same terms");
    }

    // ------------------------------------------------------------------ 7. a late print cannot settle days of weekday risk

    /// The feed may stay silent after the reopen (a corporate-action pause). A first print six days later is not a
    /// Monday gap: it cannot settle the cover, and anyone can void it for the kept premium.
    function test_a_print_six_days_after_the_reopen_cannot_settle_and_voids() public {
        vm.prank(ann);
        pool.deposit(100_000e6, ann);
        vm.warp(SAT);
        _quote(pool, address(feed));
        uint256 id = _buy(bob, 0, 10_000e6, 200);
        feed.set(R_MON, 207e8, REOPEN + 6 days); // the stock ran 15% over the week
        vm.warp(REOPEN + 6 days + 1);
        vm.prank(bob);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON);
        vm.warp(REOPEN + 30 days);
        vm.prank(bob);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON);
        uint256 before = usdg.balanceOf(bob);
        vm.prank(ann);
        pool.void(id, R_MON);
        assertEq(usdg.balanceOf(bob) - before, 45e6, "the kept premium back, not 800");
        assertEq(pool.totalReserved(), 0);
    }

    // ------------------------------------------------------------------ 8. settle at exactly reopenAt, prints in one second

    function test_round_at_exactly_reopen_settles_and_a_same_second_pair_is_unambiguous() public {
        vm.prank(ann);
        pool.deposit(100_000e6, ann);
        vm.warp(SAT);
        _quote(pool, address(feed));
        uint256 id = _buy(bob, 0, 10_000e6, 200);
        feed.set(R_MON, 189e8, REOPEN);
        feed.set(R_MON2, 190e8, REOPEN);
        vm.warp(REOPEN + 1);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, R_MON2);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.void(id, R_MON2);
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, R_MON);
        assertEq(pool.settle(id, R_MON), 300e6);
    }

    // ------------------------------------------------------------------ 9. a leaked quoter key, within the bounds

    /// With 25% per stock across several stocks, a quoter posting the floor could once sell the whole pool's capital
    /// as cover at 0.05% while the perp already showed the gap. The pool's total exposure now stops it at half, and
    /// MAX_TOTAL_EXPOSURE_BPS keeps the owner from lifting that. What a leaked key can still do inside the bounds is
    /// the trust the sellers place in the owner's bounds (docs/WEEKEND.md).
    function test_quoter_at_the_floor_sells_at_most_half_the_pool() public {
        MockFeed[] memory feeds = new MockFeed[](4);
        address[] memory addrs = new address[](4);
        for (uint256 i; i < 4; i++) {
            feeds[i] = new MockFeed();
            feeds[i].set(PHASE | 1, 100e8, FRI);
            addrs[i] = address(feeds[i]);
        }
        GapPool p = new GapPool(usdg, IHeldVault(address(vault)), owner, addrs);
        _setup(p, addrs[0]);
        vm.startPrank(owner);
        for (uint256 i = 1; i < 4; i++) {
            p.setStock(addrs[i], true, 2500);
        }
        vm.stopPrank();
        vm.startPrank(ann);
        usdg.approve(address(p), type(uint256).max);
        p.deposit(100_000e6, ann);
        vm.stopPrank();
        vm.prank(eve);
        usdg.approve(address(p), type(uint256).max);
        vm.warp(SAT);
        uint16[] memory s = new uint16[](1);
        uint16[] memory pr = new uint16[](1);
        (s[0], pr[0]) = (100, 5);
        uint256 premiums;
        // 25% of the pool reserved per stock: notional * 900 / 10000 = 25,000 -> notional 277,777
        uint96 n = uint96(uint256(25_000e6) * 10_000 / 900 - 1e6);
        for (uint256 i; i < 4; i++) {
            vm.prank(keeper);
            p.setQuotes(addrs[i], 0, s, pr);
            uint256 before = usdg.balanceOf(eve);
            if (i < 2) {
                vm.prank(eve);
                p.buy(addrs[i], 0, n, 100, type(uint256).max);
            } else {
                uint256 reserve = uint256(n) * 900 / 10_000;
                uint256 allowedAll = p.totalAssets() / 2;
                vm.prank(eve);
                vm.expectRevert(
                    abi.encodeWithSelector(GapPool.OverExposure.selector, p.totalReserved() + reserve, allowedAll)
                );
                p.buy(addrs[i], 0, n, 100, type(uint256).max);
            }
            premiums += before - usdg.balanceOf(eve);
        }
        assertLe(p.totalReserved(), p.totalAssets() / 2, "half the pool at most");
        assertGe(p.freeAssets(), p.totalAssets() / 2);
        assertLt(premiums, 300e6);
        // The owner cannot lift the total exposure past half.
        vm.prank(owner);
        vm.expectRevert(GapPool.BadValue.selector);
        p.setTotalExposure(5001);
        emit log_named_uint("reserved", p.totalReserved());
        emit log_named_uint("premiums paid", premiums);
    }
}

/// The real RHNVDA / USD feed across the last eight closures: is the first print after each reopen a fresh price, and
/// how long after the reopen does it land. BORRO_FORK_RPC=<rpc> forge test --match-contract GapPoolReviewForkTest -vv
contract GapPoolReviewForkTest is Test {
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    /// Every one of the last eight first prints lands inside SETTLE_WINDOW and inside MAX_MOVE_BPS: the settle rule
    /// fits the feed as it really behaves.
    function test_first_print_after_each_reopen() public {
        if (!forked) return;
        (uint80 id,,, uint256 at,) = IPriceFeed(NVDA_FEED).latestRoundData();
        // Walk back through eight closures.
        uint256 t = block.timestamp;
        for (uint256 k; k < 8; k++) {
            // The reopen that ended the closure before t.
            uint256 closedAt = t;
            while (MarketHours.isOpen(closedAt)) closedAt -= 1 hours;
            uint256 reopen = MarketHours.nextOpen(closedAt);
            // Walk the feed back to the first round at or after reopen.
            uint80 cur = id;
            uint256 curAt = at;
            int256 curAns;
            (, curAns,, curAt,) = IPriceFeed(NVDA_FEED).getRoundData(cur);
            uint256 prevAt;
            int256 prevAns;
            while (true) {
                (, prevAns,, prevAt,) = IPriceFeed(NVDA_FEED).getRoundData(cur - 1);
                if (prevAt < reopen && curAt >= reopen) break;
                cur -= 1;
                curAt = prevAt;
                curAns = prevAns;
            }
            int256 gapBps = (curAns - prevAns) * 10_000 / prevAns;
            emit log_named_uint("reopen", reopen);
            emit log_named_uint("  first print, seconds after reopen", curAt - reopen);
            emit log_named_uint("  last print, seconds before reopen", reopen - prevAt);
            emit log_named_int("  gap bps", gapBps);
            emit log_named_int("  first answer", curAns);
            emit log_named_int("  last answer", prevAns);
            assertLe(curAt - reopen, 2 hours, "inside SETTLE_WINDOW");
            assertLt(uint256(gapBps < 0 ? -gapBps : gapBps), 5_000, "inside MAX_MOVE_BPS");
            // Any print strictly inside the closure? (the round before prev)
            (,,, uint256 pp,) = IPriceFeed(NVDA_FEED).getRoundData(cur - 2);
            emit log_named_uint("  round before that, seconds before reopen", reopen - pp);
            t = prevAt;
            id = cur - 1;
            at = prevAt;
        }
    }
}
