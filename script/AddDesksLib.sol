// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BorroLib} from "./BorroLib.sol";
import {BorroShort} from "../src/BorroShort.sol";
import {BorroRouter} from "../src/BorroRouter.sol";
import {PairRouter} from "../src/PairRouter.sol";
import {OptionsDesk, IShareVault} from "../src/OptionsDesk.sol";

/// What the Safe has to do once the deployer has opened new desks (docs/ADD-DESKS.md): list each short market
/// on BorroShort, each USDG market on BorroRouter, each stock vault on PairRouter and OptionsDesk, and, as the
/// Borro USDG vault's curator, submit the caps that let bUSDG lend into the new USDG markets. The caps wait
/// `lock`'s three days; after that anyone may run them (Vault V2 only checks the wait, not the sender).
/// Shared by script/AddDesks.s.sol (writes the Safe batches and simulates them) and test/AddDesks.fork.t.sol.
library AddDesksLib {
    /// The live contracts the batch talks to.
    struct Live {
        address safe;
        address keeper;
        address short;
        address router;
        address pair;
        address options; // zero: not deployed yet, no setStock calls
        address usdgVault;
        address usdgAdapter;
        address liquidator;
    }

    /// One new desk, as the deployer opened it.
    struct Added {
        BorroLib.Stock stock;
        BorroLib.Desk desk;
        BorroLib.Loan loan;
        PoolKey[] route;
        address v3Pool;
        string name;
    }

    /// One transaction of a Safe batch.
    struct Call {
        address to;
        bytes data;
        string what;
    }

    /// How the USDG vault's caps change: each new market gets its `capUsdg`, the adapter as a whole grows by
    /// their sum, and the liquidity market (SPY), whose cap is kept at the sum of every other market's so a
    /// deposit never stops there while there is room elsewhere, is raised to the new sum if it is lower.
    struct CapPlan {
        uint256 sumNew;
        uint256 adapterCapNow;
        uint256 adapterCapNew;
        bool liquidityIsMarket; // the liquidity adapter is still the market adapter (not Steakhouse)
        bool raiseLiquidity;
        MarketParams liquidityMarket;
        uint256 liquidityCapNow;
        uint256 liquidityCapNew;
    }

    // ------------------------------------------------------------------ the batch

    /// The listings, in order: BorroShort.list, BorroRouter.list, PairRouter.setVault, OptionsDesk.setStock.
    function listings(Live memory live, Added[] memory a) internal pure returns (Call[] memory calls) {
        uint256 n = a.length;
        calls = new Call[](n * (live.options == address(0) ? 3 : 4));
        uint256 k;
        for (uint256 i; i < n; i++) {
            calls[k++] = Call(
                live.short,
                abi.encodeCall(BorroShort.list, (a[i].desk.market, a[i].route, a[i].v3Pool)),
                string.concat("BorroShort.list ", a[i].stock.symbol)
            );
        }
        for (uint256 i; i < n; i++) {
            calls[k++] = Call(
                live.router, abi.encodeCall(BorroRouter.list, (a[i].loan.market)), string.concat("BorroRouter.list ", a[i].stock.symbol)
            );
        }
        for (uint256 i; i < n; i++) {
            calls[k++] = Call(
                live.pair,
                abi.encodeCall(PairRouter.setVault, (a[i].desk.vault, true)),
                string.concat("PairRouter.setVault ", a[i].stock.symbol)
            );
        }
        if (live.options != address(0)) {
            for (uint256 i; i < n; i++) {
                calls[k++] = Call(
                    live.options,
                    abi.encodeCall(OptionsDesk.setStock, (a[i].stock.feed, IShareVault(a[i].desk.vault), true)),
                    string.concat("OptionsDesk.setStock ", a[i].stock.symbol)
                );
            }
        }
    }

    /// Reads the USDG vault's caps as they are and works out the new ones.
    function capPlan(Live memory live, Added[] memory a) internal view returns (CapPlan memory p) {
        IVaultV2 v = IVaultV2(live.usdgVault);
        for (uint256 i; i < a.length; i++) p.sumNew += a[i].stock.capUsdg;
        p.adapterCapNow = v.absoluteCap(keccak256(abi.encode("this", live.usdgAdapter)));
        p.liquidityIsMarket = v.liquidityAdapter() == live.usdgAdapter;
        if (p.liquidityIsMarket) {
            p.liquidityMarket = abi.decode(v.liquidityData(), (MarketParams));
            BorroLib.Loan memory l;
            l.market = p.liquidityMarket;
            bytes[2] memory ids = BorroLib.loanIdData(live.usdgAdapter, l);
            p.liquidityCapNow = v.absoluteCap(keccak256(ids[1]));
            uint256 others = (p.adapterCapNow > p.liquidityCapNow ? p.adapterCapNow - p.liquidityCapNow : 0) + p.sumNew;
            p.raiseLiquidity = p.liquidityCapNow < others;
            p.liquidityCapNew = p.raiseLiquidity ? others : p.liquidityCapNow;
            p.adapterCapNew = others + p.liquidityCapNew;
        } else {
            p.liquidityCapNew = p.liquidityCapNow;
            p.adapterCapNew = p.adapterCapNow + p.sumNew;
        }
    }

    /// The curator's submits (now) and the same settings to run once the wait is over, in the same order:
    /// per market its two ids (the collateral, the market) with the absolute cap `capUsdg` and the relative cap
    /// 100%, exactly as `BorroLib.openLender` set the launch markets; then the adapter's own cap; then the
    /// liquidity market's two ids, when it has to grow.
    function capSubmits(Live memory live, Added[] memory a, CapPlan memory p)
        internal
        pure
        returns (Call[] memory submits, Call[] memory executes)
    {
        uint256 n = a.length * 4 + 1 + (p.raiseLiquidity ? 2 : 0);
        submits = new Call[](n);
        executes = new Call[](n);
        uint256 k;
        for (uint256 i; i < a.length; i++) {
            bytes[2] memory ids = BorroLib.loanIdData(live.usdgAdapter, a[i].loan);
            string[2] memory names = ["collateral", "market"];
            for (uint256 j; j < 2; j++) {
                k = _cap(submits, executes, k, live.usdgVault, true, ids[j], a[i].stock.capUsdg, string.concat("bUSDG absolute cap ", a[i].stock.symbol, " ", names[j]));
                k = _cap(submits, executes, k, live.usdgVault, false, ids[j], BorroLib.WAD, string.concat("bUSDG relative cap ", a[i].stock.symbol, " ", names[j]));
            }
        }
        k = _cap(submits, executes, k, live.usdgVault, true, abi.encode("this", live.usdgAdapter), p.adapterCapNew, "bUSDG absolute cap, the adapter as a whole");
        if (p.raiseLiquidity) {
            BorroLib.Loan memory l;
            l.market = p.liquidityMarket;
            bytes[2] memory ids = BorroLib.loanIdData(live.usdgAdapter, l);
            k = _cap(submits, executes, k, live.usdgVault, true, ids[0], p.liquidityCapNew, "bUSDG absolute cap, liquidity market collateral (SPY)");
            k = _cap(submits, executes, k, live.usdgVault, true, ids[1], p.liquidityCapNew, "bUSDG absolute cap, liquidity market (SPY)");
        }
        require(k == n, "cap count");
    }

    function _cap(Call[] memory submits, Call[] memory executes, uint256 k, address vault, bool absolute, bytes memory id, uint256 cap, string memory what)
        private
        pure
        returns (uint256)
    {
        bytes memory data = absolute
            ? abi.encodeCall(IVaultV2.increaseAbsoluteCap, (id, cap))
            : abi.encodeCall(IVaultV2.increaseRelativeCap, (id, cap));
        submits[k] = Call(vault, abi.encodeCall(IVaultV2.submit, (data)), string.concat("submit ", what));
        executes[k] = Call(vault, data, what);
        return k + 1;
    }

    /// Sends one call from whoever is calling (the test or script pranks the Safe first). Bubbles the revert.
    function send(Call memory c) internal {
        (bool ok, bytes memory err) = c.to.call(c.data);
        if (!ok) {
            if (err.length == 0) revert(string.concat("reverted: ", c.what));
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    // ------------------------------------------------------------------ checks

    /// Every listing took.
    function checkListed(Live memory live, Added[] memory a) internal view {
        for (uint256 i; i < a.length; i++) {
            (MarketParams memory m, PoolKey[] memory route, address v3Pool, bool paused, address feed) =
                BorroShort(live.short).deskOf(a[i].desk.marketId);
            require(m.loanToken == a[i].stock.token && m.oracle == a[i].desk.oracle, string.concat(a[i].stock.symbol, ": not listed on BorroShort"));
            require(route.length == a[i].route.length && v3Pool == a[i].v3Pool && !paused, string.concat(a[i].stock.symbol, ": route"));
            require(feed == a[i].stock.feed, string.concat(a[i].stock.symbol, ": feed"));
            require(BorroRouter(live.router).listed(a[i].loan.marketId), string.concat(a[i].stock.symbol, ": not listed on BorroRouter"));
            require(PairRouter(live.pair).vaults(a[i].desk.vault), string.concat(a[i].stock.symbol, ": not listed on PairRouter"));
            if (live.options != address(0)) {
                (address f, IShareVault vault, bool allowed) = OptionsDesk(live.options).stocks(a[i].stock.feed);
                require(f == a[i].stock.feed && address(vault) == a[i].desk.vault && allowed, string.concat(a[i].stock.symbol, ": not on OptionsDesk"));
            }
        }
    }

    /// Every cap setting is waiting (submitted, not yet runnable before the wait, or already run).
    function checkSubmitted(Live memory live, Call[] memory executes) internal view {
        IVaultV2 v = IVaultV2(live.usdgVault);
        for (uint256 i; i < executes.length; i++) {
            require(v.executableAt(executes[i].data) != 0, string.concat("not submitted: ", executes[i].what));
        }
    }

    /// Every cap is in force.
    function checkCaps(Live memory live, Added[] memory a, CapPlan memory p) internal view {
        IVaultV2 v = IVaultV2(live.usdgVault);
        for (uint256 i; i < a.length; i++) {
            bytes[2] memory ids = BorroLib.loanIdData(live.usdgAdapter, a[i].loan);
            for (uint256 j; j < 2; j++) {
                require(v.absoluteCap(keccak256(ids[j])) == a[i].stock.capUsdg, string.concat(a[i].stock.symbol, ": absolute cap"));
                require(v.relativeCap(keccak256(ids[j])) == BorroLib.WAD, string.concat(a[i].stock.symbol, ": relative cap"));
            }
        }
        require(v.absoluteCap(keccak256(abi.encode("this", live.usdgAdapter))) == p.adapterCapNew, "adapter cap");
        if (p.raiseLiquidity) {
            BorroLib.Loan memory l;
            l.market = p.liquidityMarket;
            bytes[2] memory ids = BorroLib.loanIdData(live.usdgAdapter, l);
            require(v.absoluteCap(keccak256(ids[1])) == p.liquidityCapNew, "liquidity market cap");
        }
    }
}
