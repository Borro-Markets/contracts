// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GapPool, IHeldVault, IPriceFeed} from "../src/GapPool.sol";
import {MarketHours} from "../src/eth/MarketHours.sol";
import {BorroLib} from "../script/BorroLib.sol";
import {MockVault} from "./GapPool.t.sol";

/// GapPool on a fork of Robinhood Chain: real USDG, the real Steakhouse USDG vault, the real RHNVDA / USD feed.
/// BORRO_FORK_RPC=<rpc> forge test --match-contract GapPoolForkTest
///
/// The chain's future rounds do not exist yet, so the Monday round that settles a cover bought after the fork block
/// is supplied by vm.mockCall; the round before it (the real latest print) is real. The second test walks the real
/// feed history to the first print after a past reopen and settles a cover against that real round.
contract GapPoolForkTest is Test {
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    uint256 constant PAST_REOPEN = 1791158400; // 2026-10-05 00:00:00 UTC, Sunday 20:00 New York
    IERC20 constant usdg = IERC20(BorroLib.USDG);
    IHeldVault constant held = IHeldVault(BorroLib.HELD);

    GapPool pool;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address ann = makeAddr("ann");
    address bob = makeAddr("bob");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        pool = new GapPool(usdg, held, owner, _feeds());
        _setup(pool);
        deal(address(usdg), ann, 1_000_000e6);
        deal(address(usdg), bob, 1_000_000e6);
        vm.prank(ann);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _feeds() internal pure returns (address[] memory f) {
        f = new address[](1);
        f[0] = NVDA_FEED;
    }

    function _setup(GapPool p) internal {
        vm.startPrank(owner);
        p.setQuoter(keeper);
        p.setFee(1000, keeper);
        p.setCapBps(1000);
        p.setPremiumBounds(5, 2000);
        p.setTotalExposure(3000);
        p.setStock(NVDA_FEED, true, 2500);
        vm.stopPrank();
        (address feed, bool allowed,,) = p.stocks(NVDA_FEED);
        assertEq(feed, NVDA_FEED);
        assertTrue(allowed);
    }

    function _quote(GapPool p) internal {
        uint16[] memory s = new uint16[](4);
        uint16[] memory prem = new uint16[](4);
        (s[0], s[1], s[2], s[3]) = (100, 200, 300, 500);
        (prem[0], prem[1], prem[2], prem[3]) = (80, 50, 30, 10);
        vm.startPrank(keeper);
        p.setQuotes(NVDA_FEED, 0, s, prem);
        p.setQuotes(NVDA_FEED, 1, s, prem);
        vm.stopPrank();
    }

    /// The first round whose print is at or after `reopen`, walking back from the latest, and the round before it.
    function _firstRoundAfter(uint256 reopen) internal view returns (uint80 id, int256 answer, uint256 at, uint256 prevAt) {
        (uint80 latest,,, uint256 latestAt,) = IPriceFeed(NVDA_FEED).latestRoundData();
        require(latestAt >= reopen, "the fork is before the reopen");
        id = latest;
        while (true) {
            require(uint64(id) > 1, "walked off the phase");
            (, int256 pa,, uint256 pat,) = IPriceFeed(NVDA_FEED).getRoundData(id - 1);
            if (pat < reopen) {
                (, answer,, at,) = IPriceFeed(NVDA_FEED).getRoundData(id);
                prevAt = pat;
                require(pa > 0, "previous round answer");
                return (id, answer, at, prevAt);
            }
            id -= 1;
        }
    }

    function _mockRound(uint80 id, int256 answer, uint256 at) internal {
        vm.mockCall(
            NVDA_FEED, abi.encodeWithSelector(IPriceFeed.getRoundData.selector, id), abi.encode(id, answer, at, at, id)
        );
    }

    /// Deposit into the real vault, buy at the first closed hours after the fork, settle on a mocked Monday round with
    /// the real Friday print as the round before it, withdraw.
    function test_deposit_buy_settle_withdraw_on_the_real_vault() public {
        if (!forked) return;
        vm.prank(ann);
        uint256 shares = pool.deposit(50_000e6, ann);
        assertGt(shares, 0);
        assertApproxEqAbs(pool.totalAssets(), 50_000e6, 2, "the vault holds it");
        assertEq(usdg.balanceOf(address(pool)), 0);
        assertGt(IERC20(BorroLib.HELD).balanceOf(address(pool)), 0);

        // The next closed time after the fork block, a few hours in.
        uint256 t = block.timestamp;
        while (MarketHours.isOpen(t)) t += 1 hours;
        vm.warp(t + 3 hours);
        (bool closed, uint256 reopenAt) = pool.marketClosed();
        assertTrue(closed);
        assertEq(reopenAt, MarketHours.nextOpen(block.timestamp));
        assertGe(reopenAt - block.timestamp, 1 hours);
        _quote(pool);

        (uint80 latest, int256 ref,, uint256 refAt,) = IPriceFeed(NVDA_FEED).latestRoundData();
        assertGt(ref, 0);
        assertLt(refAt, block.timestamp);
        uint256 keeperBefore = usdg.balanceOf(keeper);
        vm.prank(bob);
        uint256 id = pool.buy(NVDA_FEED, 0, 10_000e6, 200, type(uint256).max);
        GapPool.Cover memory c = pool.coverOf(id);
        assertEq(c.refPrice, uint256(ref), "the paused feed is the reference");
        assertEq(c.reopenAt, reopenAt);
        assertEq(pool.totalReserved(), 800e6);
        assertEq(usdg.balanceOf(keeper) - keeperBefore, 5e6, "the fee");
        vm.prank(ann);
        vm.expectRevert(GapPool.Locked.selector);
        pool.withdraw(shares, ann); // the capital is locked while the cover is live
        assertGe(pool.totalAssets(), 50_045e6 - 3, "the kept premium joined the vault");
        assertLt(pool.totalAssets(), 50_045e6 + 50e6, "plus a few hours of the vault's interest");

        // The Monday print: the next aggregator round, 5% up, half a minute after the reopen. The real latest round is
        // the one before it and printed before the reopen, which is the rule's other half.
        uint80 monday = latest + 1;
        int256 answer = ref * 105 / 100;
        _mockRound(monday, answer, reopenAt + 30);
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(monday, answer, reopenAt + 30, reopenAt + 30, monday)
        );
        vm.warp(reopenAt + 60);
        vm.expectRevert(GapPool.WrongRound.selector);
        pool.settle(id, latest); // the Friday print is not after the reopen
        vm.expectRevert(GapPool.Settleable.selector);
        pool.void(id, monday); // a cover that can be settled cannot be voided
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 payout = pool.settle(id, monday);
        assertEq(payout, pool.payoutFor(c, answer));
        assertApproxEqAbs(payout, 300e6, 1e6, "about 3% beyond the strike on 10,000");
        assertEq(usdg.balanceOf(bob) - bobBefore, payout, "paid in USDG out of the vault");
        assertEq(usdg.balanceOf(address(pool)), 0, "none of it stuck in the pool");
        assertEq(pool.owed(bob), 0);
        assertEq(pool.totalReserved(), 0);
        vm.clearMockedCalls();

        // Ann takes everything out: her deposit, the kept premium, less the payout, plus two days of vault interest.
        vm.prank(ann);
        uint256 back = pool.withdraw(shares, ann);
        assertGe(back, 50_000e6 + 45e6 - payout - 3);
        assertLt(back, 50_000e6 + 45e6 - payout + 100e6, "interest for two days is small");
        assertEq(pool.balanceOf(ann), 0);
    }

    /// The real feed history: the first print after 2026-10-05 00:00 UTC and the print before it bracket the reopen,
    /// and a cover over that weekend settles against that real round. (The pool here sits on the test's mock vault
    /// with real USDG, because the real vault's interest math cannot run at a clock warped behind the fork block.)
    function test_settle_rule_matches_the_real_monday_round() public {
        if (!forked) return;
        (uint80 monday, int256 answer, uint256 at, uint256 prevAt) = _firstRoundAfter(PAST_REOPEN);
        assertGe(at, PAST_REOPEN, "printed at or after the reopen");
        assertLt(at, PAST_REOPEN + 1 hours, "and within the hour: the heartbeat was overdue the moment it reopened");
        assertLe(at, PAST_REOPEN + 2 hours, "inside SETTLE_WINDOW");
        assertLt(prevAt, PAST_REOPEN, "the round before printed before the reopen");
        assertGt(prevAt, PAST_REOPEN - 80 hours, "on the Friday");
        assertLt(prevAt, PAST_REOPEN - 48 hours, "before Friday's close, 00:00 UTC Saturday");
        assertEq(MarketHours.nextOpen(PAST_REOPEN - 48 hours), PAST_REOPEN);
        assertEq(MarketHours.nextOpen(PAST_REOPEN - 33 hours), PAST_REOPEN);
        (, int256 prevAnswer,,,) = IPriceFeed(NVDA_FEED).getRoundData(monday - 1);
        emit log_named_uint("monday round", monday);
        emit log_named_uint("printed at", at);
        emit log_named_int("answer", answer);
        emit log_named_uint("previous printed at", prevAt);
        emit log_named_int("previous answer", prevAnswer);

        MockVault mock = new MockVault(usdg);
        GapPool p = new GapPool(usdg, IHeldVault(address(mock)), owner, _feeds());
        _setup(p);
        vm.startPrank(ann);
        usdg.approve(address(p), type(uint256).max);
        p.deposit(50_000e6, ann);
        vm.stopPrank();

        // Saturday 2026-10-03 15:00 UTC. The feed's latest print at that time was the previous round: say so.
        vm.warp(PAST_REOPEN - 33 hours);
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(monday - 1, prevAnswer, prevAt, prevAt, monday - 1)
        );
        _quote(p);
        vm.startPrank(bob);
        usdg.approve(address(p), type(uint256).max);
        uint256 up = p.buy(NVDA_FEED, 0, 10_000e6, 100, type(uint256).max);
        uint256 down = p.buy(NVDA_FEED, 1, 10_000e6, 100, type(uint256).max);
        vm.stopPrank();
        vm.clearMockedCalls();
        GapPool.Cover memory c = p.coverOf(up);
        assertEq(c.reopenAt, PAST_REOPEN);
        assertEq(c.refPrice, uint256(prevAnswer));

        // The real Monday move is a gap, not bad data: far inside MAX_MOVE_BPS.
        int256 moveBps = (answer - prevAnswer) * 10_000 / prevAnswer;
        assertLt(uint256(moveBps < 0 ? -moveBps : moveBps), 5_000, "inside MAX_MOVE_BPS");

        vm.warp(at + 60);
        vm.expectRevert(GapPool.WrongRound.selector);
        p.settle(up, monday - 1);
        vm.expectRevert(GapPool.WrongRound.selector);
        p.settle(up, monday + 1); // the round after: the one before it already printed after the reopen
        vm.expectRevert(GapPool.Settleable.selector);
        p.void(up, monday); // the real round settles, so nothing voids
        vm.expectRevert(GapPool.WrongRound.selector);
        p.void(up, monday + 1);
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 paidUp = p.settle(up, monday);
        uint256 paidDown = p.settle(down, monday);
        assertEq(paidUp, p.payoutFor(c, answer));
        assertEq(paidDown, p.payoutFor(p.coverOf(down), answer));
        assertTrue(paidUp == 0 || paidDown == 0, "a gap goes one way");
        assertEq(usdg.balanceOf(bob) - bobBefore, paidUp + paidDown);
        assertEq(p.totalReserved(), 0);
        uint256 annShares = p.balanceOf(ann);
        vm.prank(ann);
        assertGt(p.withdraw(annShares, ann), 0, "unlocked once the last cover settled");
        emit log_named_uint("up paid", paidUp);
        emit log_named_uint("down paid", paidDown);
    }
}
