// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {CallsCalendar} from "../../src/calls/CallsCalendar.sol";
import {IStockVault, IRoundFeed} from "../../src/calls/CallsDeps.sol";
import {MarketHours} from "../../src/eth/MarketHours.sol";
import {DeployBorroCalls} from "../../script/BorroCalls.s.sol";

interface IShortLite {
    function addDeposit(bytes32 id, uint256 amount) external returns (uint256 held);
    function borrow(bytes32 id, uint256 amount) external;
    function accountOf(address shorter) external view returns (address);
    function open(bytes32 id, uint256 deposit, uint256 borrowAmount, uint256 minProceeds, uint256 deadline)
        external
        returns (uint256 proceeds);
    function quoteSell(bytes32 id, uint256 amount) external;
}

interface IVaultV2Lite {
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// Covered calls on the LIVE chain at its latest block: the NVDA vault deployed by its own deploy script
/// (script/BorroCalls.s.sol, owned by the Hoard Safe from the start), against the real NVDA token, the real bNVDA vault
/// (Morpho Vault V2, lending into Borro's NVDA market) and the real NVDA Chainlink feed. The feed's history up to the
/// fork block is real; posts after it (the test moves the clock forward by weeks) are laid over the real proxy with
/// vm.mockCall, round by round, so getRoundData answers the real way for every other round.
///   BORRO_FORK_RPC=<rpc> forge test --match-contract BorroCallsForkTest -vv
contract BorroCallsForkTest is Test {
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IERC20 constant NVDA = IERC20(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    address constant BNVDA = 0x508E23274C39C60c345e35B1f0188bE180717CB9;
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // holds every token: the faucet
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    IShortLite constant SHORT = IShortLite(0xd2D686cEdf225c5C9815187A08812783904E62Eb);
    bytes32 constant NVDA_MARKET = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;

    bool forked;
    BorroCalls calls;
    uint80 lastId;
    int256 lastPrice;
    uint256 mon; // next Monday 00:00 UTC
    uint256 open; // its 09:45 New York (the vaults' start)
    uint256 expiry; // that week's Friday 20:00 New York

    address alice = makeAddr("fork alice");
    address bob = makeAddr("fork bob");
    address buyer = makeAddr("fork buyer");
    address buyer2 = makeAddr("fork buyer2");
    address shorter = makeAddr("fork shorter");
    address attacker = makeAddr("fork attacker");
    address keeper = makeAddr("fork keeper");

    modifier onFork() {
        if (!forked) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        BorroCalls[] memory made = new DeployBorroCalls().deploy("NVDA", "calls-forktest");
        if (vm.exists("script/out/calls-forktest.dryrun.json")) vm.removeFile("script/out/calls-forktest.dryrun.json");
        calls = made[0];
        (lastId, lastPrice,,,) = IRoundFeed(FEED).latestRoundData();
        mon = 4 days + ((block.timestamp - 4 days) / 7 days + 1) * 7 days;
        open = mon + (MarketHours.isDaylightSaving(mon + 12 hours) ? 13.75 hours : 14.75 hours); // 09:45 New York
        expiry = CallsCalendar.expiryOf(open);
    }

    // ---------------------------------------------------------------- helpers

    function _give(IERC20 token, address to, uint256 amount) internal {
        vm.prank(PM);
        token.transfer(to, amount);
    }

    /// A post on the real feed at `at` (the clock moves there): the next round id, answered by getRoundData and as the
    /// latest. Rounds after it still read as zeros, as the real proxy answers.
    function _post(int256 price, uint256 at) internal returns (uint80 id) {
        if (at > block.timestamp) vm.warp(at);
        id = lastId + 1;
        lastId = id;
        lastPrice = price;
        vm.mockCall(FEED, abi.encodeWithSelector(IRoundFeed.getRoundData.selector, id), abi.encode(id, price, at, at, id));
        vm.mockCall(FEED, abi.encodeWithSelector(IRoundFeed.latestRoundData.selector), abi.encode(id, price, at, at, id));
    }

    /// The week's first post (Sunday 20:00 New York + 42 s, as measured), then a post at 09:45 and the round start.
    function _startWeek(int256 price) internal returns (uint256 id) {
        _post(price, mon + (MarketHours.isDaylightSaving(mon + 12 hours) ? 0 : 1 hours) + 42);
        _post(price, open);
        vm.prank(keeper);
        id = calls.startRound();
    }

    function _depositStock(address who, uint256 amount) internal returns (uint256 shares) {
        _give(NVDA, who, amount);
        vm.startPrank(who);
        NVDA.approve(address(calls), amount);
        shares = calls.deposit(amount, who);
        vm.stopPrank();
    }

    function _bnvda(address who, uint256 amount) internal returns (uint256 got) {
        _give(NVDA, who, amount);
        vm.startPrank(who);
        NVDA.approve(BNVDA, amount);
        got = IStockVault(BNVDA).deposit(amount, who);
        vm.stopPrank();
    }

    function _buy(address who, uint256 amount) internal returns (uint256 filled, uint256 cost) {
        (, uint256 quoted) = calls.quote(amount);
        _give(USDG, who, quoted);
        vm.startPrank(who);
        USDG.approve(address(calls), quoted);
        (filled, cost) = calls.buy(amount, quoted, who);
        vm.stopPrank();
    }

    /// The feed's last post of the week at 19:00 New York at `price`, and the settlement just after expiry.
    function _expire(int256 price) internal returns (uint80 hint) {
        hint = _post(price, expiry - 1 hours);
        vm.warp(expiry + 1);
        vm.prank(keeper);
        calls.settle(hint);
    }

    function _market() internal view returns (MarketParams memory) {
        return MORPHO.idToMarketParams(Id.wrap(NVDA_MARKET));
    }

    function _free() internal returns (uint256) {
        MORPHO.accrueInterest(_market());
        Market memory m = MORPHO.market(Id.wrap(NVDA_MARKET));
        return m.totalSupplyAssets - m.totalBorrowAssets;
    }

    /// Borrows every free NVDA in Borro's NVDA market (BorroShort's borrow to the wallet, against held USDG): bNVDA is then
    /// fully lent and cannot pay out stock.
    function _lendItAllOut() internal returns (uint256 borrowed) {
        borrowed = _free();
        _give(USDG, shorter, 50_000e6);
        vm.startPrank(shorter);
        USDG.approve(address(SHORT), 50_000e6);
        SHORT.addDeposit(NVDA_MARKET, 50_000e6);
        SHORT.borrow(NVDA_MARKET, borrowed);
        vm.stopPrank();
        assertEq(_free(), 0, "every NVDA in the market is out with the shorter");
    }

    function _repayAll() internal {
        address acct = SHORT.accountOf(shorter);
        MarketParams memory mp = _market();
        MORPHO.accrueInterest(mp);
        uint256 shares = MORPHO.position(Id.wrap(NVDA_MARKET), acct).borrowShares;
        _give(NVDA, shorter, 100e18);
        vm.startPrank(shorter);
        NVDA.approve(address(MORPHO), type(uint256).max);
        MORPHO.repay(mp, 0, shares, acct, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- deploy and the live clock

    function test_fork_the_deploy_script_wires_the_live_nvda_desk() public onFork {
        assertEq(address(calls.stock()), address(NVDA));
        assertEq(address(calls.bVault()), BNVDA);
        assertEq(address(calls.feed()), FEED);
        assertEq(address(calls.usdg()), address(USDG));
        assertEq(calls.owner(), SAFE, "the Hoard Safe from the start");
        assertEq(calls.pendingOwner(), address(0));
        (uint16 step, uint16 start, uint16 floor, uint16 move, uint16 write, uint32 auction, uint32 offset) = calls.params();
        assertEq(step, 500);
        assertEq(start, 120);
        assertEq(floor, 13);
        assertEq(move, 125);
        assertEq(write, 10_000);
        assertEq(auction, 6 hours);
        assertEq(offset, 13.75 hours);
        assertEq(calls.symbol(), "ccNVDA");
    }

    /// With the real feed and the real clock (whenever this runs): startRound does exactly what the calendar and the
    /// feed's last post say.
    function test_fork_starting_now_follows_the_calendar_and_the_real_feed() public onFork {
        _depositStock(alice, 2e18);
        (, int256 a,, uint256 u,) = IRoundFeed(FEED).latestRoundData();
        uint256 t = block.timestamp;
        bytes4 want;
        if (!MarketHours.isOpen(t)) want = BorroCalls.MarketClosed.selector;
        else if (CallsCalendar.secondsIntoDate(t) < 13.75 hours) want = BorroCalls.TooEarly.selector;
        else if (a <= 0 || !CallsCalendar.fresh(u, t, 25 hours)) want = BorroCalls.NoPrice.selector;
        else if (t + 6 hours + 1 days > CallsCalendar.expiryOf(t)) want = BorroCalls.TooLate.selector;
        console2.log("fork time", t, "feed posted", u);
        if (want == bytes4(0)) {
            assertEq(calls.startRound(), 1);
            assertEq(calls.roundOf(1).spot, uint256(a), "the real feed's price");
        } else {
            vm.expectRevert(want);
            calls.startRound();
        }
    }

    // ---------------------------------------------------------------- depositing

    function test_fork_deposits_go_into_bnvda_and_stay_lent() public onFork {
        uint256 supplyBefore = MORPHO.market(Id.wrap(NVDA_MARKET)).totalSupplyAssets;
        uint256 a = _depositStock(alice, 10e18);
        uint256 got = _bnvda(bob, 5e18);
        vm.startPrank(bob);
        IVaultV2Lite(BNVDA).approve(address(calls), got);
        uint256 b = calls.depositShares(got, bob);
        vm.stopPrank();
        assertGt(a, 0);
        assertApproxEqRel(b, a / 2, 1e15, "the same price for stock and for bNVDA");
        assertEq(NVDA.balanceOf(address(calls)), 0, "the vault never holds the stock");
        assertEq(IStockVault(BNVDA).balanceOf(address(calls)), calls.active());
        uint256 supplyAfter = MORPHO.market(Id.wrap(NVDA_MARKET)).totalSupplyAssets;
        assertApproxEqAbs(supplyAfter - supplyBefore, 15e18, 1e12, "all 15 NVDA went straight into Borro's NVDA market");
    }

    // ---------------------------------------------------------------- full rounds

    function test_fork_a_full_round_expires_out_of_the_money() public onFork {
        _depositStock(alice, 6e18);
        _depositStock(bob, 4e18);
        uint256 id = _startWeek(lastPrice);
        BorroCalls.Round memory r = calls.roundOf(id);
        assertEq(r.expiry, expiry, "friday 20:00 new york");
        assertApproxEqAbs(r.capacity, 10e18, 1e12);
        assertEq(r.strike, Math.mulDiv(uint256(lastPrice), 10_500, 1e4 * 1e6, Math.Rounding.Ceil) * 1e6);
        // Two buyers, one at the open, one an hour later and cheaper.
        (, uint256 c1) = _buy(buyer, 5e18);
        vm.warp(open + 1 hours);
        (, uint256 c2) = _buy(buyer2, 5e18);
        assertLt(c2, c1, "the price falls");
        console2.log("premium for 10 NVDA calls, USDG wei", c1 + c2);
        // The week: the stock drifts up, stays under the strike.
        _post(lastPrice * 102 / 100, open + 2 days);
        _expire(int256(r.strike) - 1e6);
        assertEq(calls.roundOf(id).owedShares, 0);
        uint256 pa = calls.premiumOf(alice);
        assertApproxEqAbs(pa, (c1 + c2) * 6 / 10, 2);
        // The weekend window: Alice leaves with her stock, redeemed from bNVDA, and her premium.
        vm.prank(alice);
        (uint256 v, uint256 u) = calls.withdraw(type(uint256).max, alice, true);
        assertEq(u, pa);
        assertGe(NVDA.balanceOf(alice), 6e18 - 1e12, "every NVDA back, rent on top");
        assertEq(USDG.balanceOf(alice), pa);
        assertGt(v, 0);
        // Buyers: worthless, closed.
        vm.prank(buyer);
        (uint256 vs, uint256 refund) = calls.exercise(id, buyer, false);
        assertEq(vs + refund, 0);
    }

    function test_fork_an_itm_round_pays_bnvda_while_every_nvda_is_lent_out() public onFork {
        _depositStock(alice, 10e18);
        uint256 borrowed = _lendItAllOut();
        uint256 pricePerShareStart = IStockVault(BNVDA).convertToAssets(1e18);
        uint256 id = _startWeek(lastPrice);
        _buy(buyer, 6e18);
        _buy(buyer2, 4e18);
        BorroCalls.Round memory r = calls.roundOf(id);
        // Friday: the stock is 12% up.
        int256 fin = lastPrice * 112 / 100;
        _expire(fin);
        r = calls.roundOf(id);
        uint256 owedStock = Math.mulDiv(r.sold, uint256(fin) - r.strike, uint256(fin));
        assertGt(r.owedShares, 0);
        assertApproxEqRel(IStockVault(BNVDA).convertToAssets(r.owedShares), owedStock, 1e15, "worth (price - strike) / price a call");
        // A week of rent at full use lifted bNVDA's share price.
        assertGt(IStockVault(BNVDA).convertToAssets(1e18), pricePerShareStart, "lenders earned rent while writing calls");
        // Holder 1 takes bNVDA: no stock needs to leave the market.
        vm.prank(buyer);
        (uint256 got,) = calls.exercise(id, buyer, false);
        assertEq(IStockVault(BNVDA).balanceOf(buyer), got);
        // Holder 2 wants the stock itself: not while every NVDA is out with the shorter.
        vm.prank(buyer2);
        vm.expectRevert();
        calls.exercise(id, buyer2, true);
        // Once the shorter repays, it redeems.
        _repayAll();
        vm.prank(buyer2);
        (uint256 got2,) = calls.exercise(id, buyer2, true);
        assertGt(NVDA.balanceOf(buyer2), 0);
        assertApproxEqRel(got2 * 6, got * 4, 1e12, "pro rata");
        // Alice kept the rest: her stock less the payout, plus rent, plus the premium.
        vm.prank(alice);
        (uint256 left, uint256 prem) = calls.withdraw(type(uint256).max, alice, false);
        assertApproxEqAbs(left + r.owedShares, 10e18, 1e12);
        assertGt(prem, 0);
        console2.log("borrowed by the shorter, NVDA wei", borrowed);
    }

    function test_fork_withdrawals_queue_until_the_round_settles() public onFork {
        _depositStock(alice, 5e18);
        _depositStock(bob, 5e18);
        uint256 id = _startWeek(lastPrice);
        vm.prank(alice);
        calls.requestWithdraw(type(uint256).max);
        // Carol's deposit mid-week waits too.
        address carol = makeAddr("fork carol");
        _depositStock(carol, 3e18);
        (, uint256 cost) = _buy(buyer, 10e18);
        _expire(lastPrice * 110 / 100);
        uint256 owed = calls.roundOf(id).owedShares;
        vm.prank(alice);
        (uint256 v, uint256 u) = calls.collect(alice, false);
        assertApproxEqAbs(v, (10e18 - owed) / 2, 2e12, "half of what is left after the payout");
        assertApproxEqAbs(u, cost / 2, 2, "half the premium");
        vm.prank(carol);
        calls.collect(carol, false);
        (, uint256 cs) = calls.previewWithdraw(calls.balanceOf(carol));
        assertApproxEqRel(cs, 3e18, 1e15, "carol joined after the payout: her 3 NVDA are whole");
        assertEq(calls.premiumOf(carol), 0);
    }

    // ---------------------------------------------------------------- stale feeds

    function test_fork_a_stale_feed_at_expiry_settles_on_mondays_first_post() public onFork {
        _depositStock(alice, 10e18);
        uint256 id = _startWeek(lastPrice);
        _buy(buyer, 10e18);
        int256 p0 = lastPrice;
        // The feed goes quiet from Thursday 06:00 New York: 38 hours before expiry.
        uint80 quiet = _post(p0, expiry - 38 hours);
        vm.warp(expiry + 1);
        vm.expectRevert(BorroCalls.StaleAtExpiry.selector);
        calls.settle(quiet);
        // Nothing until the reopen; Monday's first post settles it, not a later one.
        uint80 first = _post(p0 * 107 / 100, expiry + 2 days + 42);
        uint80 later = _post(p0 * 120 / 100, expiry + 2 days + 3 hours);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(later);
        vm.prank(keeper);
        calls.settle(first);
        assertEq(int256(calls.roundOf(id).settlePrice), p0 * 107 / 100);
        assertGt(calls.roundOf(id).owedShares, 0, "7% up is over the 5% strike");
    }

    function test_fork_a_feed_dead_for_a_week_calls_the_round_off() public onFork {
        _depositStock(alice, 10e18);
        uint256 id = _startWeek(lastPrice);
        (, uint256 c1) = _buy(buyer, 4e18);
        uint80 quiet = _post(lastPrice, expiry - 40 hours);
        vm.warp(expiry + 7 days);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.voidRound(quiet);
        vm.warp(expiry + 7 days + 1);
        vm.prank(buyer);
        calls.voidRound(quiet);
        vm.prank(buyer);
        (, uint256 refund) = calls.exercise(id, buyer, false);
        assertEq(refund, c1, "the buyer's money back");
        assertEq(calls.premiumOf(alice), 0);
        vm.prank(alice);
        (uint256 v,) = calls.withdraw(type(uint256).max, alice, false);
        assertApproxEqAbs(IStockVault(BNVDA).convertToAssets(v), 10e18, 1e12, "alice's stock, whole");
    }

    // ---------------------------------------------------------------- attacks

    /// Pushing NVDA's own Uniswap pool (a short opened through BorroShort sells borrowed NVDA into it) moves neither the
    /// sale's price nor the settlement: only the Chainlink feed and the clock do.
    function test_fork_attack_a_pushed_pool_does_not_move_the_sale() public onFork {
        _depositStock(alice, 20e18);
        _startWeek(lastPrice);
        (, uint256 before) = calls.quote(1e18);
        _give(USDG, attacker, 20_000e6);
        vm.startPrank(attacker);
        USDG.approve(address(SHORT), 20_000e6);
        SHORT.open(NVDA_MARKET, 20_000e6, 15e18, 0, block.timestamp);
        vm.stopPrank();
        (, uint256 afterPush) = calls.quote(1e18);
        assertEq(afterPush, before, "same price after dumping 15 NVDA into the pool");
        uint256 expected = Math.mulDiv(1e18, uint256(lastPrice) * 120e18, 1e42, Math.Rounding.Ceil);
        assertEq(before, expected, "the price is the feed's price x 1.20%, nothing else");
    }

    /// Whoever calls settle and with whatever round, only the feed's answer at expiry settles; once settled, nothing else
    /// can.
    function test_fork_attack_settlement_front_running_has_one_answer() public onFork {
        _depositStock(alice, 10e18);
        uint256 id = _startWeek(lastPrice);
        _buy(buyer, 10e18);
        int256 p0 = lastPrice;
        uint80 a = _post(p0 * 103 / 100, expiry - 3 hours);
        uint80 b = _post(p0 * 104 / 100, expiry - 1 hours);
        vm.warp(expiry + 2 days);
        uint80 c = _post(p0 * 130 / 100, expiry + 2 days + 42);
        vm.startPrank(attacker);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(a);
        vm.expectRevert(BorroCalls.FreshAtExpiry.selector);
        calls.settle(c);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(c + 1);
        vm.expectRevert(BorroCalls.BadHint.selector);
        calls.settle(a - 1);
        calls.settle(b);
        vm.expectRevert(BorroCalls.NoRound.selector);
        calls.settle(c);
        vm.stopPrank();
        assertEq(int256(calls.roundOf(id).settlePrice), p0 * 104 / 100, "the answer in force at expiry, and only it");
    }

    /// Tokens sent straight to the vault (before the first deposit, or later) move no share price and no premium, and
    /// are exactly what the owner can take back.
    function test_fork_attack_donations_buy_nothing() public onFork {
        uint256 gift = _bnvda(attacker, 3e18);
        vm.startPrank(attacker);
        IVaultV2Lite(BNVDA).transfer(address(calls), gift);
        vm.stopPrank();
        _give(USDG, address(calls), 1_000e6);
        _give(NVDA, address(calls), 1e18);
        // The attacker deposits 1 wei of bNVDA first, then the victim.
        uint256 one = _bnvda(attacker, 1e9);
        vm.startPrank(attacker);
        IVaultV2Lite(BNVDA).approve(address(calls), one);
        uint256 sa = calls.depositShares(one, attacker);
        vm.stopPrank();
        assertEq(sa, one, "one for one: the donation is in no book");
        uint256 v = _depositStock(alice, 10e18);
        (uint256 aliceOut,) = calls.previewWithdraw(v);
        assertApproxEqAbs(IStockVault(BNVDA).convertToAssets(aliceOut), 10e18, 1e12, "the victim keeps all of it");
        assertEq(calls.reclaimable(BNVDA), gift);
        assertEq(calls.reclaimable(address(USDG)), 1_000e6);
        assertEq(calls.reclaimable(address(NVDA)), 1e18);
        vm.startPrank(SAFE);
        calls.reclaim(BNVDA, SAFE, gift);
        calls.reclaim(address(USDG), SAFE, 1_000e6);
        calls.reclaim(address(NVDA), SAFE, 1e18);
        vm.expectRevert();
        calls.reclaim(BNVDA, SAFE, 1);
        vm.stopPrank();
    }

    /// Many tiny deposits and withdrawals never take out more than went in.
    function test_fork_attack_rounding_loops_lose_money() public onFork {
        _depositStock(alice, 10e18);
        uint256 aliceB = calls.active();
        uint256 got = _bnvda(attacker, 1e15);
        vm.startPrank(attacker);
        IVaultV2Lite(BNVDA).approve(address(calls), type(uint256).max);
        uint256 spent;
        uint256 back;
        for (uint256 i = 1; i <= 40; i++) {
            uint256 amt = i * 997 + 1;
            calls.depositShares(amt, attacker);
            spent += amt;
            (uint256 v,) = calls.withdraw(type(uint256).max, attacker, false);
            back += v;
        }
        vm.stopPrank();
        assertLe(back, spent, "rounding never pays the attacker");
        assertEq(IStockVault(BNVDA).balanceOf(attacker), got - spent + back);
        (uint256 aliceOut,) = calls.previewWithdraw(calls.balanceOf(alice));
        assertGe(aliceOut, aliceB, "alice keeps everything she put in");
    }

    /// A keeper that misbehaves can only be early (refused), wrong (refused) or absent (anyone does it instead).
    function test_fork_attack_a_bad_or_dead_keeper_only_delays() public onFork {
        _depositStock(alice, 10e18);
        _post(lastPrice, mon + 42);
        _post(lastPrice, open - 1);
        vm.prank(keeper);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.startRound();
        _post(lastPrice, open);
        vm.prank(attacker); // anyone can start it
        uint256 id = calls.startRound();
        _buy(buyer, 5e18);
        int256 p0 = lastPrice;
        uint80 last = _post(p0 * 90 / 100, expiry - 1 hours);
        vm.warp(expiry);
        vm.prank(keeper);
        vm.expectRevert(BorroCalls.TooEarly.selector);
        calls.settle(last);
        // The keeper never comes back; three days later a stranger settles at the same price.
        vm.warp(expiry + 3 days);
        _post(p0 * 150 / 100, expiry + 2 days + 42);
        vm.prank(makeAddr("stranger"));
        calls.settle(last);
        assertEq(int256(calls.roundOf(id).settlePrice), p0 * 90 / 100);
        // The keeper can buy only at the price anyone pays: it has no role here at all.
        assertEq(calls.owner(), SAFE);
    }

    /// The Safe at every extreme of its powers: pause, the widest settings, reclaim. Nobody's money moves.
    function test_fork_the_safe_at_every_extreme_takes_nothing() public onFork {
        uint256 safeB = IStockVault(BNVDA).balanceOf(SAFE); // Roy's seed, lent on Borro
        uint256 safeU = USDG.balanceOf(SAFE);
        _depositStock(alice, 10e18);
        uint256 id = _startWeek(lastPrice);
        (, uint256 cost) = _buy(buyer, 10e18);
        vm.startPrank(SAFE);
        calls.setPaused(true);
        calls.queueParams(BorroCalls.Params(250, 60, 7, 25, 100, 1 hours, 13.5 hours)); // as far as one change goes
        assertEq(calls.reclaimable(BNVDA), 0);
        assertEq(calls.reclaimable(address(USDG)), 0);
        vm.expectRevert();
        calls.reclaim(BNVDA, SAFE, 1);
        vm.expectRevert();
        calls.reclaim(address(USDG), SAFE, 1);
        vm.stopPrank();
        _expire(lastPrice * 115 / 100);
        vm.prank(buyer);
        (uint256 o,) = calls.exercise(id, buyer, false);
        vm.prank(alice);
        (uint256 v, uint256 u) = calls.withdraw(type(uint256).max, alice, false);
        assertApproxEqAbs(o + v, 10e18, 1e12, "holder and depositor split the stock between them");
        assertApproxEqAbs(u, cost, 1, "the premium");
        assertEq(IStockVault(BNVDA).balanceOf(SAFE), safeB, "the Safe gained no bNVDA");
        assertEq(USDG.balanceOf(SAFE), safeU, "and no USDG");
    }

    // ---------------------------------------------------------------- gas

    function test_fork_gas() public onFork {
        _give(NVDA, alice, 10e18);
        vm.startPrank(alice);
        NVDA.approve(address(calls), 10e18);
        uint256 g = gasleft();
        calls.deposit(10e18, alice);
        console2.log("deposit (stock into bNVDA)", g - gasleft());
        vm.stopPrank();
        uint256 got = _bnvda(bob, 2e18);
        vm.startPrank(bob);
        IVaultV2Lite(BNVDA).approve(address(calls), got);
        g = gasleft();
        calls.depositShares(got, bob);
        console2.log("depositShares", g - gasleft());
        vm.stopPrank();
        _post(lastPrice, mon + 42);
        _post(lastPrice, open);
        g = gasleft();
        uint256 id = calls.startRound();
        console2.log("startRound", g - gasleft());
        _give(USDG, buyer, 1_000e6);
        vm.startPrank(buyer);
        USDG.approve(address(calls), 1_000e6);
        g = gasleft();
        calls.buy(5e18, 1_000e6, buyer);
        console2.log("buy", g - gasleft());
        vm.stopPrank();
        vm.prank(bob);
        g = gasleft();
        calls.requestWithdraw(1e18);
        console2.log("requestWithdraw", g - gasleft());
        uint80 hint = _post(lastPrice * 110 / 100, expiry - 1 hours);
        vm.warp(expiry + 1);
        g = gasleft();
        calls.settle(hint);
        console2.log("settle (in the money)", g - gasleft());
        vm.prank(buyer);
        g = gasleft();
        calls.exercise(id, buyer, false);
        console2.log("exercise (bNVDA)", g - gasleft());
        vm.prank(bob);
        g = gasleft();
        calls.collect(bob, false);
        console2.log("collect", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        calls.withdraw(type(uint256).max, alice, true);
        console2.log("withdraw (as stock)", g - gasleft());
    }
}
