// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {IStockVault, IRoundFeed} from "../../src/calls/CallsDeps.sol";
import {MockStock, MockUsdg, MockStockVault, MockRoundFeed} from "./CallsMocks.sol";

/// Shared setup for the calls vault's unit, fuzz and invariant tests: mock stock, USDG, Borro vault and feed, and one
/// calls vault owned by "the Safe". Time starts on Monday 2026-10-12 (a normal summer week: New York is UTC-4).
abstract contract CallsBase is Test {
    uint256 constant MON = 1791763200; // Monday 2026-10-12 00:00 UTC = Sunday 20:00 New York: the week's first trading date opens
    uint256 constant OPEN = MON + 13.5 hours; // Monday 09:30 New York
    uint256 constant EXPIRY = MON + 5 days; // Saturday 00:00 UTC = Friday 20:00 New York
    int256 constant P0 = 230e8; // $230.00

    MockStock stock;
    MockUsdg usdg;
    MockStockVault bv;
    MockRoundFeed feed;
    BorroCalls calls;

    address safe = makeAddr("safe");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");

    function _params() internal pure virtual returns (BorroCalls.Params memory) {
        // NVDA-like: strike 5% up, sale from 1.20% to 0.13% of the price over 6 hours from 09:30 New York.
        return BorroCalls.Params({
            stepBps: 500,
            startBps: 120,
            floorBps: 13,
            maxMoveBps: 125,
            writeBps: 10_000,
            auctionSeconds: 6 hours,
            startOffset: 13.5 hours
        });
    }

    function setUp() public virtual {
        vm.warp(MON + 1 hours);
        stock = new MockStock();
        usdg = new MockUsdg();
        bv = new MockStockVault(stock);
        feed = new MockRoundFeed();
        calls = _deploy(_params());
        feed.post(P0);
    }

    function _deploy(BorroCalls.Params memory p) internal returns (BorroCalls) {
        return new BorroCalls(stock, IStockVault(address(bv)), usdg, IRoundFeed(address(feed)), safe, p, "Borro NVDA Calls", "ccNVDA");
    }

    // ---------------------------------------------------------------- helpers

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        stock.mint(who, amount);
        vm.startPrank(who);
        stock.approve(address(calls), amount);
        shares = calls.deposit(amount, who);
        vm.stopPrank();
    }

    /// Borro vault shares straight from the mock vault, for depositShares.
    function _vaultShares(address who, uint256 amount) internal returns (uint256 got) {
        stock.mint(who, amount);
        vm.startPrank(who);
        stock.approve(address(bv), amount);
        got = bv.deposit(amount, who);
        vm.stopPrank();
    }

    function _start() internal returns (uint256 id) {
        vm.warp(OPEN);
        feed.post(P0);
        id = calls.startRound();
    }

    function _buy(address who, uint256 amount) internal returns (uint256 filled, uint256 cost) {
        (, uint256 quoted) = calls.quote(amount);
        usdg.mint(who, quoted);
        vm.startPrank(who);
        usdg.approve(address(calls), quoted);
        (filled, cost) = calls.buy(amount, quoted, who);
        vm.stopPrank();
    }

    /// Posts `price` on the feed at `at` (warping there first).
    function _postAt(int256 price, uint256 at) internal returns (uint80 id) {
        vm.warp(at);
        id = feed.post(price);
    }

    /// The usual end of a week: the feed's last post Friday at 19:00 New York at `price`, then settle just after expiry.
    function _expireAt(int256 price) internal returns (uint80 hint) {
        hint = _postAt(price, EXPIRY - 1 hours);
        vm.warp(EXPIRY + 1);
        calls.settle(hint);
    }

    function _round(uint256 id) internal view returns (BorroCalls.Round memory) {
        return calls.roundOf(id);
    }
}
