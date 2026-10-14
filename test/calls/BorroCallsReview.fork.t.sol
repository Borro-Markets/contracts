// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {CallsCalendar} from "../../src/calls/CallsCalendar.sol";
import {MarketHours} from "../../src/eth/MarketHours.sol";
import {IRoundFeed} from "../../src/calls/CallsDeps.sol";
import {BorroCalls} from "../../src/calls/BorroCalls.sol";
import {DeployBorroCalls} from "../../script/BorroCalls.s.sol";

interface IReviewCalls {
    function stock() external view returns (address);
    function bVault() external view returns (address);
    function feed() external view returns (address);
}

interface IReviewDesks {
    struct M {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct K {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function deskOf(bytes32 id) external view returns (M memory market, K[] memory route, address v3Pool, bool paused, address feed);
}

/// Independent review (2026-10-09): read-only probes of the live feeds the calls vaults would use. Nothing is sent.
///   forktest.sh --match-contract BorroCallsReviewForkTest -vv
contract BorroCallsReviewForkTest is Test {
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    bool forked;

    struct Desk {
        address adapter;
        bytes32 marketId;
        address oracle;
        string symbol;
        bytes32 usdgMarketId;
        address usdgOracle;
        address vault;
    }

    modifier onFork() {
        if (!forked) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _try(address to, string memory sig) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = to.staticcall(abi.encodeWithSignature(sig));
    }

    function _feedOf(string memory symbol) internal view returns (address) {
        string memory json = vm.readFile("script/out/desks.json");
        IReviewDesks short = IReviewDesks(vm.parseJsonAddress(json, ".short"));
        Desk[] memory desks = abi.decode(vm.parseJson(json, ".desks"), (Desk[]));
        for (uint256 i; i < desks.length; i++) {
            if (keccak256(bytes(desks[i].symbol)) == keccak256(bytes(symbol))) {
                (,,,, address f) = short.deskOf(desks[i].marketId);
                return f;
            }
        }
        revert("no desk");
    }

    /// The proxy, its aggregator and whether the proxy's latest lags the aggregator's own (a DualAggregator's secondary
    /// proxy sees new rounds only after a cutoff).
    function test_review_fork_probe_the_feed_proxies() public onFork {
        string[9] memory syms = ["SPY", "QQQ", "NVDA", "TSLA", "MSTR", "COIN", "PLTR", "SPCX", "GME"];
        for (uint256 s; s < syms.length; s++) {
            address feed = _feedOf(syms[s]);
            (, bytes memory a) = _try(feed, "aggregator()");
            address agg = abi.decode(a, (address));
            (bool tvOk, bytes memory tv) = _try(agg, "typeAndVersion()");
            (uint80 rid,,, uint256 upd,) = IRoundFeed(feed).latestRoundData();
            address eoa = makeAddr("review eoa");
            vm.prank(eoa, eoa);
            (bool aOk, bytes memory aRet) = agg.staticcall(abi.encodeWithSignature("latestRoundData()"));
            uint256 aggRound;
            if (aOk) (aggRound,,,,) = abi.decode(aRet, (uint80, int256, uint256, uint256, uint80));
            console2.log(syms[s], feed, agg);
            console2.log("  type", tvOk ? abi.decode(tv, (string)) : "?");
            console2.log("  proxy latest round (aggregator part), updatedAt", uint256(uint64(rid)), upd);
            console2.log("  aggregator's own latest round", aggRound, "phase", uint256(rid) >> 64);
            console2.log("  age now (s)", block.timestamp - upd, "fresh now", CallsCalendar.fresh(upd, block.timestamp, 25 hours));
            string[6] memory getters = ["getSecondaryProxy()", "secondaryProxy()", "getCutoffTime()", "getMaxSyncIterations()", "s_secondaryProxy()", "latestRound()"];
            for (uint256 g; g < getters.length; g++) {
                vm.prank(eoa, eoa);
                (bool ok, bytes memory r) = agg.staticcall(abi.encodeWithSignature(getters[g]));
                if (ok && r.length >= 32) console2.log("   ", getters[g], abi.decode(r, (uint256)));
            }
            (, int256 nextA,, uint256 nextU,) = IRoundFeed(feed).getRoundData(rid + 1);
            console2.log("  proxy getRoundData(latest + 1) answer, updatedAt", uint256(nextA), nextU);
        }
    }

    /// The deploy script on all nine desks (simulated on the fork, nothing sent): each vault's stock is its Borro vault's
    /// asset and its desk's loan token, its feed is the desk's feed and describes that stock, the stock answers
    /// oraclePaused, and the Borro vault has no gates set.
    function test_review_fork_the_deploy_script_wires_all_nine_desks() public onFork {
        BorroCalls[] memory made = new DeployBorroCalls().deploy("SPY,QQQ,NVDA,TSLA,MSTR,COIN,PLTR,SPCX,GME", "calls-reviewtest");
        if (vm.exists("script/out/calls-reviewtest.dryrun.json")) vm.removeFile("script/out/calls-reviewtest.dryrun.json");
        string[9] memory syms = ["SPY", "QQQ", "NVDA", "TSLA", "MSTR", "COIN", "PLTR", "SPCX", "GME"];
        assertEq(made.length, 9);
        for (uint256 i; i < made.length; i++) {
            IReviewCalls c = IReviewCalls(address(made[i]));
            address stock = c.stock();
            address bv = c.bVault();
            address feed = c.feed();
            assertEq(feed, _feedOf(syms[i]), "the desk's feed");
            (, bytes memory asset) = _try(bv, "asset()");
            assertEq(abi.decode(asset, (address)), stock, "the vault lends the stock");
            (, bytes memory desc) = _try(feed, "description()");
            (, bytes memory sym) = _try(stock, "symbol()");
            (bool pOk,) = _try(stock, "oraclePaused()");
            (bool mOk, bytes memory mult) = _try(stock, "uiMultiplier()");
            console2.log(syms[i], abi.decode(desc, (string)), abi.decode(sym, (string)));
            console2.log("  oraclePaused answers", pOk, "uiMultiplier", mOk ? abi.decode(mult, (uint256)) : 0);
            string[6] memory g = ["receiveSharesGate()", "sendSharesGate()", "receiveAssetsGate()", "sendAssetsGate()", "owner()", "curator()"];
            for (uint256 k; k < g.length; k++) {
                (bool ok, bytes memory r) = _try(bv, g[k]);
                if (ok && r.length >= 32) console2.log("   ", g[k], abi.decode(r, (address)));
            }
        }
    }

    /// A DualAggregator shows its "secondary proxy" a new round only after a cutoff. Warp to one second after each feed's
    /// latest post and compare the proxy's latest with what an outside account reads from the aggregator.
    function test_review_fork_does_the_proxy_lag_the_aggregator() public onFork {
        string[9] memory syms = ["SPY", "QQQ", "NVDA", "TSLA", "MSTR", "COIN", "PLTR", "SPCX", "GME"];
        address eoa = makeAddr("review eoa");
        for (uint256 s; s < syms.length; s++) {
            address feed = _feedOf(syms[s]);
            (, bytes memory a) = _try(feed, "aggregator()");
            address agg = abi.decode(a, (address));
            (,,, uint256 upd,) = IRoundFeed(feed).latestRoundData();
            uint256 snap = vm.snapshotState();
            vm.warp(upd + 1);
            (uint80 viaProxy,,, uint256 pu,) = IRoundFeed(feed).latestRoundData();
            vm.prank(eoa, eoa);
            (, bytes memory r) = agg.staticcall(abi.encodeWithSignature("latestRoundData()"));
            (uint80 direct,,, uint256 du,) = abi.decode(r, (uint80, int256, uint256, uint256, uint80));
            console2.log(syms[s], "proxy sees round / at", uint256(uint64(viaProxy)), pu);
            console2.log("   aggregator to an outsider", uint256(uint64(direct)), du);
            vm.revertToState(snap);
        }
    }

    /// Walks back the NVDA and SPY feeds' history and logs, for every weekend close in range: the last post before Friday
    /// 20:00 New York, its age, the first post after, and any post at exactly the close. Also the smallest moves between
    /// posts under 20 hours apart (the deviation band).
    function test_review_fork_feed_history_around_the_close() public onFork {
        _history(_feedOf("NVDA"), "NVDA", 450);
        _history(_feedOf("SPY"), "SPY", 250);
    }

    function _history(address feed, string memory name, uint256 back) internal view {
        (uint80 rid,,,,) = IRoundFeed(feed).latestRoundData();
        uint256 n = uint64(rid);
        uint256 lo = n > back ? n - back : 1;
        uint256 len = n - lo + 1;
        uint256[] memory us = new uint256[](len);
        int256[] memory as_ = new int256[](len);
        for (uint256 i; i < len; i++) {
            (, int256 a,, uint256 u,) = IRoundFeed(feed).getRoundData(uint80((uint256(rid) >> 64) << 64 | (lo + i)));
            us[i] = u;
            as_[i] = a;
        }
        console2.log("==", name, "rounds", len);
        console2.log("  from", us[0], "to", us[len - 1]);
        uint256 exact;
        uint256 lastMinute;
        uint256 smallMoves; // under 0.45%, under 20 h apart
        uint256 pairs;
        uint256 minMoveE6 = type(uint256).max;
        uint256 maxGap;
        for (uint256 i = 1; i < len; i++) {
            uint256 gap = us[i] - us[i - 1];
            if (MarketHours.tradingDate(us[i]) == MarketHours.tradingDate(us[i - 1]) || gap < 20 hours) {
                if (gap > maxGap && MarketHours.isOpen(us[i - 1]) && MarketHours.isOpen(us[i])) maxGap = gap;
            }
            if (gap < 20 hours) {
                pairs++;
                uint256 mv = as_[i] > as_[i - 1]
                    ? uint256(as_[i] - as_[i - 1]) * 1e6 / uint256(as_[i - 1])
                    : uint256(as_[i - 1] - as_[i]) * 1e6 / uint256(as_[i - 1]);
                if (mv < minMoveE6) minMoveE6 = mv;
                if (mv < 4500) smallMoves++;
            }
            // a close between the two posts: the Friday (or holiday-eve) 20:00 New York
            if (MarketHours.isOpen(us[i - 1])) {
                uint256 x = CallsCalendar.expiryOf(us[i - 1]);
                if (us[i] >= x && us[i - 1] <= x) {
                    if (us[i] == x) exact++;
                    if (x - us[i - 1] <= 60) lastMinute++;
                    uint256 age = x - us[i - 1];
                    int256 movE4 = (as_[i] - as_[i - 1]) * 10_000 / as_[i - 1];
                    console2.log("  close", x);
                    console2.log("    last post age (min), first after delay (s)", age / 60, us[i] - x);
                    console2.log("    stale at expiry", !CallsCalendar.fresh(us[i - 1], x - 1, 25 hours));
                    console2.log("    move over the weekend (bps, signed)");
                    console2.logInt(movE4);
                }
            }
        }
        console2.log("  posts at exactly the close", exact, "within a minute before it", lastMinute);
        console2.log("  pairs under 20h apart, of them under 0.45% move", pairs, smallMoves);
        console2.log("  smallest move between them (ppm)", minMoveE6);
        console2.log("  longest gap inside a trading week (min)", maxGap / 60);
    }
}
