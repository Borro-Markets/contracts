// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsDesk, IShareVault, IPriceFeed} from "../src/OptionsDesk.sol";
import {MarketHours} from "../src/eth/MarketHours.sol";
import {BorroLib} from "../script/BorroLib.sol";
import {OptTok, RateVault} from "./OptionsDesk.t.sol";

/// OptionsDesk on a fork of Robinhood Chain: real USDG, the real Steakhouse USDG vault, the real bNVDA vault and
/// NVDA token, the real RHNVDA / USD feed.
/// BORRO_FORK_RPC=<rpc> forge test --match-contract OptionsDeskForkTest
///
/// The real vaults accrue interest from their last update, so the clock cannot be warped behind the fork block
/// without breaking them, and the bNVDA vault did not exist before the last past expiry the feed covers (it was
/// deployed 2026-10-05). So the first test writes on the real vaults against the next Friday and settles on
/// mocked rounds, and the second test writes on mock vaults at a warped-back clock and settles against the real
/// round history: the feed's last print before Friday 2026-10-02 20:00 New York, found by walking the feed, with
/// the real Monday reopen print as the round after it.
contract OptionsDeskForkTest is Test {
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    IShareVault constant NVDA_VAULT = IShareVault(0x508E23274C39C60c345e35B1f0188bE180717CB9);
    uint256 constant PAST_EXPIRY = 1790985600; // Friday 2026-10-02 20:00 EDT = 2026-10-03 00:00:00 UTC
    uint256 constant PAST_REOPEN = 1791158400; // Sunday 2026-10-04 20:00 EDT = 2026-10-05 00:00:00 UTC
    uint256 constant TICK = 25_000_000;
    uint128 constant PREM = 2e6;
    IERC20 constant usdg = IERC20(BorroLib.USDG);
    IShareVault constant held = IShareVault(BorroLib.HELD);

    OptionsDesk desk;
    IERC20 nvda;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address ann = makeAddr("ann"); // writes a covered call from NVDA she lends
    address bob = makeAddr("bob"); // buys
    address carl = makeAddr("carl"); // writes a cash-secured put from USDG
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        desk = new OptionsDesk(usdg, held, owner);
        vm.startPrank(owner);
        desk.setStock(NVDA_FEED, NVDA_VAULT, true);
        desk.setFee(1000, keeper);
        vm.stopPrank();
        nvda = IERC20(NVDA_VAULT.asset());
        deal(address(nvda), ann, 100e18);
        deal(address(usdg), bob, 1_000_000e6);
        deal(address(usdg), carl, 1_000_000e6);
        vm.prank(ann);
        nvda.approve(address(desk), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(desk), type(uint256).max);
        vm.prank(carl);
        usdg.approve(address(desk), type(uint256).max);
    }

    function _tickDown(uint256 price) internal pure returns (uint128) {
        return uint128(price / TICK * TICK);
    }

    function _tickUp(uint256 price) internal pure returns (uint128) {
        return uint128((price + TICK - 1) / TICK * TICK);
    }

    function _mockRound(uint80 id, int256 answer, uint256 at) internal {
        vm.mockCall(
            NVDA_FEED, abi.encodeWithSelector(IPriceFeed.getRoundData.selector, id), abi.encode(id, answer, at, at, id)
        );
    }

    /// The feed's last round whose print is at or before `t`, walking back from the latest.
    function _lastRoundAtOrBefore(uint256 t) internal view returns (uint80 id, int256 answer, uint256 at) {
        (uint80 latest,,,,) = IPriceFeed(NVDA_FEED).latestRoundData();
        id = latest;
        while (true) {
            require(uint64(id) > 1, "walked off the phase");
            (, answer,, at,) = IPriceFeed(NVDA_FEED).getRoundData(id);
            if (at <= t) return (id, answer, at);
            id -= 1;
        }
    }

    /// Lend NVDA into the real bNVDA vault through a call ask, put USDG into the real Steakhouse vault through a put
    /// ask, fill both, warp past the next Friday, settle on mocked rounds (the chain's future rounds do not exist
    /// yet), claim in bNVDA shares and in USDG redeemed from Steakhouse, release, and leave the desk empty.
    function test_covered_call_and_cash_secured_put_on_the_real_vaults() public {
        if (!forked) return;
        uint64 expiry = desk.expiryAfter(uint64(block.timestamp));
        if (expiry < block.timestamp + 2 hours) expiry = desk.expiryAfter(expiry);
        assertTrue(desk.isExpiry(expiry));
        (uint80 latest, int256 answer,, uint256 latestAt,) = IPriceFeed(NVDA_FEED).latestRoundData();
        uint256 price = uint256(answer);
        assertGt(price, 0);
        assertLt(latestAt, block.timestamp);
        uint128 callStrike = _tickDown(price * 90 / 100); // both in the money by about 10% at today's price
        uint128 putStrike = _tickUp(price * 110 / 100);
        bytes32 cid = desk.seriesIdOf(NVDA_FEED, expiry, callStrike, true);
        bytes32 pid = desk.seriesIdOf(NVDA_FEED, expiry, putStrike, false);

        // Ann lends 10 NVDA into the vault through the ask; the shares are her lock.
        uint256 wantShares = NVDA_VAULT.convertToShares(10e18);
        vm.prank(ann);
        uint256 callAsk = desk.postAskWithStock(NVDA_FEED, expiry, callStrike, 10e18, PREM);
        assertEq(nvda.balanceOf(ann), 90e18);
        assertEq(nvda.balanceOf(address(desk)), 0, "lent, not held");
        uint256 callLock = desk.orderOf(callAsk).locked;
        assertApproxEqAbs(callLock, wantShares, 1);
        assertEq(IERC20(address(NVDA_VAULT)).balanceOf(address(desk)), callLock);
        assertGe(NVDA_VAULT.convertToAssets(callLock) + 1, 10e18, "the lock covers ten units");

        // Carl puts the strike's worth of USDG into Steakhouse through the ask.
        uint256 putUsdg = (uint256(5e18) * putStrike + 1e20 - 1) / 1e20;
        uint256 carlBefore = usdg.balanceOf(carl);
        vm.prank(carl);
        uint256 putAsk = desk.postAskWithUsdg(NVDA_FEED, expiry, putStrike, 5e18, PREM);
        assertEq(carlBefore - usdg.balanceOf(carl), putUsdg);
        uint256 putLock = desk.orderOf(putAsk).locked;
        assertEq(IERC20(address(held)).balanceOf(address(desk)), putLock);
        assertApproxEqAbs(held.convertToAssets(putLock), putUsdg, 1);
        assertEq(usdg.balanceOf(address(desk)), 0);

        // Bob buys both.
        uint256 annBefore = usdg.balanceOf(ann);
        vm.startPrank(bob);
        desk.fillAsk(callAsk, 10e18, 20e6);
        desk.fillAsk(putAsk, 5e18, 10e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(ann) - annBefore, 18e6, "the premium less the fee");
        assertEq(usdg.balanceOf(keeper), 3e6);
        assertEq(desk.balanceOf(bob, uint256(cid)), 10e18);
        assertEq(desk.balanceOf(bob, uint256(pid)), 5e18);
        assertEq(desk.seriesOf(cid).lockedShares, callLock);
        assertEq(desk.seriesOf(pid).lockedShares, putLock);

        // Friday comes. The chain's rounds after the fork do not exist: the Friday print and the Monday print are
        // mocked as the next two aggregator rounds, at today's price. The real latest round is the one before them.
        uint80 friday = latest + 1;
        uint80 monday = latest + 2;
        _mockRound(friday, answer, expiry - 30 minutes);
        _mockRound(monday, answer, expiry + 2 days + 30);
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(monday, answer, expiry + 2 days + 30, expiry + 2 days + 30, monday)
        );
        vm.warp(expiry + 2 days + 60);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(cid, latest); // the round after it printed before expiry
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        desk.settle(cid, monday); // printed after expiry
        desk.settle(cid, friday);
        desk.settle(pid, friday);
        OptionsDesk.Series memory call_ = desk.seriesOf(cid);
        OptionsDesk.Series memory put_ = desk.seriesOf(pid);
        assertEq(call_.settlePrice, price);
        assertEq(put_.settlePrice, price);
        uint256 intrinsic = (price - callStrike) * 1e18 / price;
        assertEq(call_.payoutSharesPerUnit, NVDA_VAULT.convertToShares(intrinsic));
        assertEq(put_.payoutUsdgPerUnit, (putStrike - price) / 100);
        assertGe(held.convertToAssets(put_.payoutSharesPerUnit) + 1, put_.payoutUsdgPerUnit);
        vm.clearMockedCalls();

        // Bob claims: bNVDA shares worth the call's move, USDG out of Steakhouse for the put.
        vm.startPrank(bob);
        uint256 callPaid = desk.claim(cid, 10e18, false);
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 putPaid = desk.claim(pid, 5e18, false);
        vm.stopPrank();
        assertEq(IERC20(address(NVDA_VAULT)).balanceOf(bob), callPaid);
        assertApproxEqRel(NVDA_VAULT.convertToAssets(callPaid), 10 * intrinsic, 1e12, "ten units' move, in stock");
        assertEq(usdg.balanceOf(bob) - bobUsdg, putPaid);
        assertGe(putPaid, 5 * put_.payoutUsdgPerUnit - 5, "at least the payout fixed at settlement");
        assertLt(putPaid, 5 * put_.payoutUsdgPerUnit + 1e6, "plus two days of the vault's interest");

        // The writers take back the rest.
        vm.prank(ann);
        uint256 annBack = desk.release(cid);
        vm.prank(carl);
        uint256 carlBack = desk.release(pid);
        assertEq(annBack, callLock - 10 * uint256(call_.payoutSharesPerUnit), "ten units' worth owed");
        assertEq(carlBack, putLock - 5 * uint256(put_.payoutSharesPerUnit), "five units' worth owed");
        assertEq(IERC20(address(NVDA_VAULT)).balanceOf(ann), annBack);
        assertEq(IERC20(address(held)).balanceOf(carl), carlBack);
        assertLt(IERC20(address(NVDA_VAULT)).balanceOf(address(desk)), 1e6, "dust only");
        assertLt(IERC20(address(held)).balanceOf(address(desk)), 1e6, "dust only");
        assertEq(usdg.balanceOf(address(desk)), 0);
        assertEq(nvda.balanceOf(address(desk)), 0);
    }

    /// The real feed history: the last print at or before Friday 2026-10-02 20:00 New York and the Monday reopen
    /// print after it. A call and a put written over that week (on mock vaults, since the real ones cannot run at a
    /// clock warped behind the fork block) settle against that real round, and no other round proves.
    function test_settle_rule_matches_the_real_friday_close_round() public {
        if (!forked) return;
        (uint80 last, int256 answer, uint256 at) = _lastRoundAtOrBefore(PAST_EXPIRY);
        (, int256 nextAnswer,, uint256 nextAt,) = IPriceFeed(NVDA_FEED).getRoundData(last + 1);
        (, int256 prevAnswer,, uint256 prevAt,) = IPriceFeed(NVDA_FEED).getRoundData(last - 1);
        assertLe(at, PAST_EXPIRY, "printed at or before the close");
        assertGt(at, PAST_EXPIRY - 1 days, "on the Friday");
        assertGe(nextAt, PAST_REOPEN, "the round after it is the Monday reopen print");
        assertLt(nextAt, PAST_REOPEN + 1 hours);
        assertLt(prevAt, at);
        assertGt(answer, 0);
        assertGt(nextAnswer, 0);
        assertGt(prevAnswer, 0);
        assertTrue(MarketHours.isWeekClose(PAST_EXPIRY));
        assertEq(MarketHours.nextOpen(PAST_EXPIRY), PAST_REOPEN);
        emit log_named_uint("last round before the close", last);
        emit log_named_uint("printed at", at);
        emit log_named_int("answer", answer);
        emit log_named_uint("next printed at", nextAt);
        emit log_named_int("next answer", nextAnswer);

        // A desk on mock vaults over real USDG and a stand-in stock, at a clock two hours before that close.
        OptTok stock = new OptTok("NVDA", 18);
        RateVault vault = new RateVault(stock, 1, "bNVDA");
        RateVault usdgVault = new RateVault(usdg, 1e12, "Steakhouse USDG");
        OptionsDesk d = new OptionsDesk(usdg, IShareVault(address(usdgVault)), owner);
        vm.startPrank(owner);
        d.setStock(NVDA_FEED, IShareVault(address(vault)), true);
        d.setFee(1000, keeper);
        vm.stopPrank();
        stock.mint(ann, 100e18);
        vm.startPrank(ann);
        stock.approve(address(d), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(carl);
        usdg.approve(address(d), type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        usdg.approve(address(d), type(uint256).max);

        vm.warp(PAST_EXPIRY - 2 hours);
        uint256 s = uint256(answer);
        uint128 callStrike = _tickDown(s * 98 / 100); // in the money by about 2% at the real close
        uint128 putStrike = _tickUp(s * 102 / 100);
        bytes32 cid = d.seriesIdOf(NVDA_FEED, uint64(PAST_EXPIRY), callStrike, true);
        bytes32 pid = d.seriesIdOf(NVDA_FEED, uint64(PAST_EXPIRY), putStrike, false);
        vm.prank(ann);
        uint256 callAsk = d.postAskWithStock(NVDA_FEED, uint64(PAST_EXPIRY), callStrike, 10e18, PREM);
        vm.prank(carl);
        uint256 putAsk = d.postAskWithUsdg(NVDA_FEED, uint64(PAST_EXPIRY), putStrike, 5e18, PREM);
        vm.startPrank(bob);
        d.fillAsk(callAsk, 10e18, 20e6);
        d.fillAsk(putAsk, 5e18, 10e6);
        vm.stopPrank();
        uint256 callLock = d.seriesOf(cid).lockedShares;
        uint256 putLock = d.seriesOf(pid).lockedShares;

        // Saturday: the round has no successor yet and is the feed's latest, so it already proves.
        vm.warp(PAST_EXPIRY + 15 hours);
        vm.mockCall(
            NVDA_FEED, abi.encodeWithSelector(IPriceFeed.getRoundData.selector, last + 1), abi.encode(last + 1, 0, 0, 0, last + 1)
        );
        vm.mockCall(
            NVDA_FEED, abi.encodeWithSelector(IPriceFeed.latestRoundData.selector), abi.encode(last, answer, at, at, last)
        );
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        d.settle(cid, last - 1); // its next round printed before the close
        d.settle(cid, last);
        vm.clearMockedCalls();

        // Monday: the real Monday print is the round after, and it proves the same round; nothing else does.
        vm.warp(nextAt + 60);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        d.settle(pid, last + 1); // printed after the close
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        d.settle(pid, last - 1);
        vm.expectRevert(OptionsDesk.WrongRound.selector);
        d.settle(pid, last + 2);
        d.settle(pid, last);
        OptionsDesk.Series memory call_ = d.seriesOf(cid);
        OptionsDesk.Series memory put_ = d.seriesOf(pid);
        assertEq(call_.settlePrice, s);
        assertEq(put_.settlePrice, s);
        assertEq(call_.payoutSharesPerUnit, vault.convertToShares((s - callStrike) * 1e18 / s));
        assertEq(put_.payoutUsdgPerUnit, (putStrike - s) / 100);

        vm.startPrank(bob);
        uint256 callPaid = d.claim(cid, 10e18, false);
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 putPaid = d.claim(pid, 5e18, false);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), callPaid);
        assertApproxEqAbs(vault.convertToAssets(callPaid), 10 * ((s - callStrike) * 1e18 / s), 20, "the move, in stock");
        assertEq(usdg.balanceOf(bob) - bobUsdg, putPaid);
        assertApproxEqAbs(putPaid, 5 * ((putStrike - s) / 100), 5, "the move, in USDG");
        vm.prank(ann);
        uint256 annBack = d.release(cid);
        vm.prank(carl);
        uint256 carlBack = d.release(pid);
        assertEq(annBack + callPaid + vault.balanceOf(address(d)), callLock, "the call lock, split once");
        assertLt(vault.balanceOf(address(d)), 1e6);
        assertEq(carlBack + 5 * uint256(put_.payoutSharesPerUnit) + usdgVault.balanceOf(address(d)), putLock, "the put lock, split once");
        assertLt(usdgVault.balanceOf(address(d)), 1e6);
        assertEq(usdg.balanceOf(address(d)), 0);
        emit log_named_uint("call paid (bNVDA shares)", callPaid);
        emit log_named_uint("put paid (USDG)", putPaid);
    }
}
