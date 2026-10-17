// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {BorroLib, IERC20Min} from "./BorroLib.sol";
import {StockList} from "./StockList.sol";
import {AddDesksLib} from "./AddDesksLib.sol";
import {IUniswapV3Factory} from "../src/BorroShort.sol";
import {IUniswapV3Pool} from "../src/BorroSwap.sol";

interface IOwned {
    function owner() external view returns (address);
}

interface IFeedDescription {
    function description() external view returns (string memory);
}

/// Adds stock desks to the live Borro (docs/ADD-DESKS.md). For each stock in script/stocks-add.json (or the one
/// named by ONLY) the deployer opens the desk the way the launch did: the oracle, the short market, the stock
/// vault and its adapter (BorroLib.open), the USDG oracle and market (BorroLib.openUsdg), the dead seeds, then
/// `lock` (every risky vault setting waits LOCK_DAYS) and `handOver` (the vault goes to the Hoard Safe; the
/// deployer keeps no role). The listings on BorroShort, BorroRouter, PairRouter and OptionsDesk, and the Borro
/// USDG vault's caps for the new markets, are the Safe's: this script writes them as Safe Transaction Builder
/// batches and simulates them on the fork with the Safe as the sender before it finishes.
///
///   forge script script/AddDesks.s.sol --rpc-url $RPC --sender <deployer>                        (dry run)
///   ... --broadcast --slow --private-key $(cat ~/.config/borro/deployer_key)                    (for real)
///   script/deploy-add-desks.sh does both, and `script/deploy-add-desks.sh --fork` rehearses on a local anvil fork.
///
/// Before anything is sent it checks every stock on chain (token, feed, limits, pool) and prints what the
/// deployer must hold (ETH, the seed of each stock, USDG); if the deployer is short it stops.
/// Writes script/out/desks-add.json (the new desks, in desks.json's per-desk shape plus the route),
/// script/out/safe-add-desks.json (batch 1: the listings and the cap submits, for the Safe now) and
/// script/out/safe-add-desks-2-execute.json (batch 2: the caps, once the 3 days are over; anyone may send it).
/// A dry run writes the same files with `.dryrun` in the name; OUT_TAG=<tag> names them otherwise.
/// Optional: ONLY (one symbol), STOCKS_ADD (the file, default stocks-add.json), LOCK_DAYS (default 3; must be 3
/// on Robinhood Chain), FEE_BPS and FEE_RECIPIENT (default: what the SPY vault has), SALT (default
/// "borro-add-1"; change it if a stock's vault or oracle already exists from an earlier attempt).
contract AddDesks is Script, StockList {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;

    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    uint256 constant ROBINHOOD_CHAIN = 4663;
    // Gas one desk took at launch (open about 9.97M, openUsdg 0.98M, lock and handOver 1.14M), rounded up.
    uint256 constant GAS_PER_DESK = 12_500_000;
    bytes32 constant POOLS_SLOT = bytes32(uint256(6)); // PoolManager's pools mapping (StateLibrary)

    function run() external {
        string memory file = vm.envOr("STOCKS_ADD", string("stocks-add.json"));
        address deployer = msg.sender;
        AddDesksLib.Live memory live = _live();
        uint256 lockDays = vm.envOr("LOCK_DAYS", uint256(3));
        require(block.chainid != ROBINHOOD_CHAIN || lockDays == 3, "LOCK_DAYS must be 3 on Robinhood Chain");
        _checkLive(live);

        (BorroLib.Stock[] memory list, uint256[] memory at) = _pick(loadStocksFrom(file), vm.envOr("ONLY", string("")));
        BorroLib.Terms memory t = _terms(deployer);
        _checkStocks(list, at, file, live);
        _needs(list, deployer);
        uint256 startBlock = BorroLib.rpcBlock(vm);

        AddDesksLib.Added[] memory a = new AddDesksLib.Added[](list.length);
        for (uint256 i; i < list.length; i++) {
            vm.startBroadcast(deployer);
            a[i].stock = list[i];
            a[i].desk = BorroLib.open(list[i], t);
            a[i].loan = BorroLib.openUsdg(list[i], a[i].desk, t.salt);
            if (lockDays != 0) BorroLib.lock(a[i].desk.vault, lockDays * 1 days);
            BorroLib.handOver(a[i].desk.vault, deployer, live.safe);
            vm.stopBroadcast();
            a[i].route = loadRouteFrom(file, at[i]);
            a[i].v3Pool = loadV3PoolFrom(file, at[i]);
            a[i].name = loadNameFrom(file, at[i]);
            console2.log(list[i].symbol);
            console2.log("  vault       ", a[i].desk.vault);
            console2.log("  adapter     ", a[i].desk.adapter);
            console2.log("  oracle      ", a[i].desk.oracle);
            console2.log("  market      ", vm.toString(a[i].desk.marketId));
            console2.log("  USDG oracle ", a[i].loan.oracle);
            console2.log("  USDG market ", vm.toString(a[i].loan.marketId));
        }

        AddDesksLib.CapPlan memory p = AddDesksLib.capPlan(live, a);
        AddDesksLib.Call[] memory listings = AddDesksLib.listings(live, a);
        (AddDesksLib.Call[] memory submits, AddDesksLib.Call[] memory executes) = AddDesksLib.capSubmits(live, a, p);
        console2.log("bUSDG caps: new markets together", p.sumNew / 1e6);
        console2.log("  adapter cap now / after", p.adapterCapNow / 1e6, p.adapterCapNew / 1e6);
        if (p.liquidityIsMarket) console2.log("  liquidity market (SPY) cap now / after", p.liquidityCapNow / 1e6, p.liquidityCapNew / 1e6);
        else console2.log("  the liquidity adapter is not the market adapter: no liquidity market cap change");

        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory tag = vm.envOr("OUT_TAG", string(real ? "" : "dryrun"));
        string memory only = vm.envOr("ONLY", string(""));
        string memory suffix = string.concat(bytes(only).length == 0 ? "" : string.concat("-", only), bytes(tag).length == 0 ? "" : string.concat(".", tag), ".json");
        _writeDesks(string.concat("desks-add", suffix), live, a, startBlock, real);
        _writeBatch(
            string.concat("safe-add-desks", suffix),
            "Borro: add desks, 1 of 2 (list and submit caps)",
            string.concat(
                "The Safe lists each new short market on BorroShort, each USDG market on BorroRouter, each stock vault on PairRouter",
                live.options == address(0) ? "" : " and OptionsDesk",
                ", then as bUSDG's curator submits the caps for the new USDG markets (each waits 3 days; batch 2 runs them). "
            ),
            _join(listings, submits)
        );
        _writeBatch(
            string.concat("safe-add-desks-2-execute", suffix),
            "Borro: add desks, 2 of 2 (caps, after 3 days)",
            "Runs the cap settings batch 1 submitted, once their 3-day wait is over. Vault V2 lets anyone send these; the Safe batch is the tidy way. ",
            executes
        );
        _simulate(live, a, p, listings, submits, executes);
        console2.log("new desks", list.length);
        console2.log("Safe batch 1 transactions", listings.length + submits.length);
        console2.log("Safe batch 2 transactions", executes.length);
    }

    // ------------------------------------------------------------------ the live system

    function _live() internal view returns (AddDesksLib.Live memory live) {
        string memory desks = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        live.safe = vm.envOr("OWNER", HOARD_SAFE);
        live.keeper = vm.envOr("KEEPER", KEEPER);
        live.short = desks.readAddress(".short");
        live.router = desks.readAddress(".router");
        live.usdgVault = desks.readAddress(".usdgVault");
        live.usdgAdapter = desks.readAddress(".usdgAdapter");
        live.liquidator = desks.readAddress(".liquidator");
        live.pair = vm.readFile(string.concat(vm.projectRoot(), "/script/out/pair-router.json")).readAddress(".pairRouter");
        string memory optionsFile = string.concat(vm.projectRoot(), "/script/out/options-desk.json");
        if (vm.isFile(optionsFile)) live.options = vm.readFile(optionsFile).readAddress(".optionsDesk");
    }

    /// The Safe owns everything the batch touches, and bUSDG waits as `lock` left it.
    function _checkLive(AddDesksLib.Live memory live) internal view {
        require(live.safe == msg.sender || BorroLib.looksLikeSafe(live.safe), "OWNER must be a Safe that is set up, or the sender");
        require(IOwned(live.short).owner() == live.safe, "BorroShort is not the Safe's");
        require(IOwned(live.router).owner() == live.safe, "BorroRouter is not the Safe's");
        require(IOwned(live.pair).owner() == live.safe, "PairRouter is not the Safe's");
        if (live.options != address(0)) require(IOwned(live.options).owner() == live.safe, "OptionsDesk is not the Safe's");
        else console2.log("NOTE: script/out/options-desk.json is missing: no OptionsDesk.setStock in the batch");
        IVaultV2 v = IVaultV2(live.usdgVault);
        require(v.owner() == live.safe && v.curator() == live.safe, "bUSDG is not the Safe's");
        require(v.isAdapter(live.usdgAdapter), "bUSDG adapter");
        require(v.isAllocator(live.keeper), "the keeper does not allocate bUSDG");
        console2.log("bUSDG cap wait (seconds)", v.timelock(IVaultV2.increaseAbsoluteCap.selector));
    }

    /// The new vaults take the live SPY vault's fee and fee recipient unless told otherwise.
    function _terms(address deployer) internal view returns (BorroLib.Terms memory t) {
        string memory desks = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        IVaultV2 spy = IVaultV2(desks.readAddress(".desks[0].vault"));
        t.owner = deployer;
        t.feeRecipient = vm.envOr("FEE_RECIPIENT", spy.performanceFeeRecipient());
        t.performanceFee = vm.envOr("FEE_BPS", uint256(spy.performanceFee()) / 1e14) * 1e14;
        t.salt = vm.envOr("SALT", bytes32("borro-add-1"));
        if (t.performanceFee != 0) require(t.feeRecipient != address(0), "FEE_RECIPIENT");
    }

    // ------------------------------------------------------------------ checks before sending

    function _checkStocks(BorroLib.Stock[] memory list, uint256[] memory at, string memory file, AddDesksLib.Live memory live)
        internal
        view
    {
        string memory desks = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        uint256 n;
        while (vm.keyExistsJson(desks, string.concat(".desks[", vm.toString(n), "]"))) n++;
        for (uint256 i; i < list.length; i++) {
            BorroLib.Stock memory s = list[i];
            string memory sym = s.symbol;
            require(IERC20Min(s.token).decimals() == 18, string.concat(sym, ": token decimals"));
            require(keccak256(bytes(IERC20Min(s.token).symbol())) == keccak256(bytes(sym)), string.concat(sym, ": token symbol"));
            require(AggregatorV3Interface(s.feed).decimals() == 8, string.concat(sym, ": feed decimals"));
            require(_contains(IFeedDescription(s.feed).description(), sym), string.concat(sym, ": the feed does not name it"));
            (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(s.feed).latestRoundData();
            require(answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp, string.concat(sym, ": feed answer"));
            require(block.timestamp - updatedAt < 5 days, string.concat(sym, ": feed is stale"));
            require(IMorpho(BorroLib.MORPHO).isLltvEnabled(s.lltv), string.concat(sym, ": lltv not enabled"));
            require(IMorpho(BorroLib.MORPHO).isLltvEnabled(s.lltvUsdg), string.concat(sym, ": lltvUsdg not enabled"));
            require(s.cap != 0 && s.seed != 0 && s.capUsdg != 0, string.concat(sym, ": cap, seed, capUsdg"));
            for (uint256 j; j < n; j++) {
                address vault = desks.readAddress(string.concat(".desks[", vm.toString(j), "].vault"));
                require(IVaultV2(vault).asset() != s.token, string.concat(sym, ": already has a live desk"));
            }
            for (uint256 j; j < i; j++) require(list[j].token != s.token, string.concat(sym, ": listed twice"));
            _checkWhere(loadRouteFrom(file, at[i]), loadV3PoolFrom(file, at[i]), s);
            console2.log(string.concat(sym, " checks out, feed price (8 decimals)"), uint256(answer));
        }
        live;
    }

    /// The pool a stock trades through is real: a v3 pool of USDG and the stock from the chain's factory, or a
    /// hookless v4 route from USDG to the stock whose every pool the PoolManager has initialized.
    function _checkWhere(PoolKey[] memory route, address v3Pool, BorroLib.Stock memory s) internal view {
        if (v3Pool != address(0)) {
            require(route.length == 0, string.concat(s.symbol, ": a route and a v3 pool"));
            address t0 = IUniswapV3Pool(v3Pool).token0();
            address t1 = IUniswapV3Pool(v3Pool).token1();
            require(
                (t0 == s.token && t1 == BorroLib.USDG) || (t0 == BorroLib.USDG && t1 == s.token), string.concat(s.symbol, ": v3 pool tokens")
            );
            require(IUniswapV3Factory(V3_FACTORY).getPool(t0, t1, IUniswapV3Pool(v3Pool).fee()) == v3Pool, string.concat(s.symbol, ": v3 pool factory"));
            return;
        }
        require(route.length != 0 && route.length <= 3, string.concat(s.symbol, ": no route and no v3 pool"));
        address here = BorroLib.USDG;
        for (uint256 i; i < route.length; i++) {
            PoolKey memory key = route[i];
            require(address(key.hooks) == address(0), string.concat(s.symbol, ": hooked pool"));
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            require(c0 != address(0) && c0 < c1, string.concat(s.symbol, ": pool key order"));
            if (here == c0) here = c1;
            else if (here == c1) here = c0;
            else revert(string.concat(s.symbol, ": route breaks"));
            bytes32 slot0 = IExtsload(POOL_MANAGER).extsload(keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), POOLS_SLOT)));
            require(uint160(uint256(slot0)) != 0, string.concat(s.symbol, ": v4 pool not initialized"));
        }
        require(here == s.token, string.concat(s.symbol, ": route does not end at the stock"));
    }

    /// Prints what the deployer must hold and stops if it does not.
    function _needs(BorroLib.Stock[] memory list, address deployer) internal {
        bool short_;
        console2.log("deployer", deployer);
        for (uint256 i; i < list.length; i++) {
            uint256 have = IERC20Min(list[i].token).balanceOf(deployer);
            console2.log(string.concat("  needs ", list[i].symbol, " (wei)"), list[i].seed, "has", have);
            if (have < list[i].seed) short_ = true;
        }
        uint256 usdg = list.length * BorroLib.USDG_MARKET_SEED;
        uint256 haveUsdg = IERC20Min(BorroLib.USDG).balanceOf(deployer);
        console2.log("  needs USDG (6 decimals)", usdg, "has", haveUsdg);
        if (haveUsdg < usdg) short_ = true;
        uint256 gasPrice = _rpcUint("eth_gasPrice");
        uint256 eth = (list.length * GAS_PER_DESK * gasPrice * 3) / 2; // half again for a dearer block
        console2.log("  gas price (wei)", gasPrice);
        console2.log("  needs ETH (wei, with a 50% margin)", eth, "has", deployer.balance);
        if (deployer.balance < eth) short_ = true;
        require(!short_, "the deployer is short: fund it as printed above, then run again");
    }

    // ------------------------------------------------------------------ the Safe's batch, simulated

    /// Runs batch 1 as the Safe, then batch 2 after the wait as the keeper, and checks everything took. State
    /// is put back afterwards: nothing of this is sent.
    function _simulate(
        AddDesksLib.Live memory live,
        AddDesksLib.Added[] memory a,
        AddDesksLib.CapPlan memory p,
        AddDesksLib.Call[] memory listings,
        AddDesksLib.Call[] memory submits,
        AddDesksLib.Call[] memory executes
    ) internal {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < listings.length; i++) {
            vm.prank(live.safe);
            AddDesksLib.send(listings[i]);
        }
        for (uint256 i; i < submits.length; i++) {
            vm.prank(live.safe);
            AddDesksLib.send(submits[i]);
        }
        AddDesksLib.checkListed(live, a);
        AddDesksLib.checkSubmitted(live, executes);
        uint256 wait = IVaultV2(live.usdgVault).timelock(IVaultV2.increaseAbsoluteCap.selector);
        vm.warp(block.timestamp + wait);
        for (uint256 i; i < executes.length; i++) {
            vm.prank(live.keeper);
            AddDesksLib.send(executes[i]);
        }
        AddDesksLib.checkCaps(live, a, p);
        vm.revertToState(snap);
        console2.log("simulated both Safe batches from the Safe: every listing and cap took");
    }

    // ------------------------------------------------------------------ files

    function _writeDesks(string memory name, AddDesksLib.Live memory live, AddDesksLib.Added[] memory a, uint256 startBlock, bool real) internal {
        string memory out = string.concat(
            "{\"block\":", vm.toString(startBlock), ",\"dryRun\":", real ? "false" : "true", ",\"safe\":\"", vm.toString(live.safe),
            "\",\"short\":\"", vm.toString(live.short), "\",\"router\":\"", vm.toString(live.router), "\",\"pairRouter\":\"", vm.toString(live.pair),
            "\",\"optionsDesk\":\"", vm.toString(live.options), "\",\"usdgVault\":\"", vm.toString(live.usdgVault), "\",\"usdgAdapter\":\"",
            vm.toString(live.usdgAdapter), "\",\"liquidator\":\"", vm.toString(live.liquidator), "\",\"desks\":["
        );
        for (uint256 i; i < a.length; i++) {
            out = string.concat(
                out, i == 0 ? "" : ",", "\n  {\"symbol\":\"", a[i].stock.symbol, "\",\"name\":\"", a[i].name, "\",\"token\":\"", vm.toString(a[i].stock.token),
                "\",\"feed\":\"", vm.toString(a[i].stock.feed), "\",\"vault\":\"", vm.toString(a[i].desk.vault), "\",\"adapter\":\"", vm.toString(a[i].desk.adapter)
            );
            out = string.concat(
                out, "\",\"oracle\":\"", vm.toString(a[i].desk.oracle), "\",\"marketId\":\"", vm.toString(a[i].desk.marketId), "\",\"usdgOracle\":\"",
                vm.toString(a[i].loan.oracle), "\",\"usdgMarketId\":\"", vm.toString(a[i].loan.marketId), "\",\"lltv\":\"", vm.toString(a[i].stock.lltv),
                "\",\"lltvUsdg\":\"", vm.toString(a[i].stock.lltvUsdg), "\",\"cap\":", vm.toString(a[i].stock.cap / 1e18), ",\"capUsdg\":",
                vm.toString(a[i].stock.capUsdg / 1e6), ",\"seed\":\"", vm.toString(a[i].stock.seed), "\",\"route\":["
            );
            for (uint256 j; j < a[i].route.length; j++) {
                out = string.concat(
                    out, j == 0 ? "" : ",", "{\"currency0\":\"", vm.toString(Currency.unwrap(a[i].route[j].currency0)), "\",\"currency1\":\"",
                    vm.toString(Currency.unwrap(a[i].route[j].currency1)), "\",\"fee\":", vm.toString(uint256(a[i].route[j].fee)), ",\"tickSpacing\":",
                    vm.toString(uint256(int256(a[i].route[j].tickSpacing))), "}"
                );
            }
            out = string.concat(out, "],\"v3Pool\":\"", vm.toString(a[i].v3Pool), "\"}");
        }
        vm.writeFile(string.concat(vm.projectRoot(), "/script/out/", name), string.concat(out, "\n]}\n"));
        console2.log("wrote", string.concat("script/out/", name));
    }

    /// A Safe Transaction Builder batch, the shape the owner has signed before (raw data, no ABI: the description
    /// says what each transaction is, in order).
    function _writeBatch(string memory name, string memory title, string memory description, AddDesksLib.Call[] memory calls) internal {
        string memory what;
        for (uint256 i; i < calls.length; i++) {
            what = string.concat(what, i == 0 ? "" : "; ", vm.toString(i + 1), ". ", calls[i].what);
        }
        string memory out = string.concat(
            "{\n  \"version\": \"1.0\",\n  \"chainId\": \"", vm.toString(block.chainid), "\",\n  \"createdAt\": 0,\n  \"meta\": {\n    \"name\": \"", title,
            "\",\n    \"description\": \"", description, what, "\",\n    \"createdFromSafeAddress\": \"", vm.toString(HOARD_SAFE),
            "\"\n  },\n  \"transactions\": ["
        );
        for (uint256 i; i < calls.length; i++) {
            out = string.concat(
                out, i == 0 ? "" : ",", "\n    {\"to\": \"", vm.toString(calls[i].to), "\", \"value\": \"0\", \"data\": \"", vm.toString(calls[i].data),
                "\", \"contractMethod\": null, \"contractInputsValues\": null}"
            );
        }
        vm.writeFile(string.concat(vm.projectRoot(), "/script/out/", name), string.concat(out, "\n  ]\n}\n"));
        console2.log("wrote", string.concat("script/out/", name), "transactions", calls.length);
    }

    // ------------------------------------------------------------------ helpers

    function _join(AddDesksLib.Call[] memory x, AddDesksLib.Call[] memory y) internal pure returns (AddDesksLib.Call[] memory z) {
        z = new AddDesksLib.Call[](x.length + y.length);
        for (uint256 i; i < x.length; i++) z[i] = x[i];
        for (uint256 i; i < y.length; i++) z[x.length + i] = y[i];
    }

    /// Every stock in the file, or only the one named by ONLY, with each one's index in the file (for its route).
    function _pick(BorroLib.Stock[] memory all, string memory only) internal pure returns (BorroLib.Stock[] memory list, uint256[] memory at) {
        if (bytes(only).length == 0) {
            at = new uint256[](all.length);
            for (uint256 i; i < all.length; i++) at[i] = i;
            return (all, at);
        }
        list = new BorroLib.Stock[](1);
        at = new uint256[](1);
        for (uint256 i; i < all.length; i++) {
            if (keccak256(bytes(only)) == keccak256(bytes(all[i].symbol))) {
                list[0] = all[i];
                at[0] = i;
                return (list, at);
            }
        }
        revert(string.concat("no such stock: ", only));
    }

    function _rpcUint(string memory method) internal returns (uint256 n) {
        bytes memory raw = vm.rpc(method, "[]");
        for (uint256 i; i < raw.length; i++) n = (n << 8) | uint8(raw[i]);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory nd = bytes(needle);
        if (nd.length == 0 || nd.length > h.length) return false;
        for (uint256 i; i + nd.length <= h.length; i++) {
            bool same = true;
            for (uint256 j; j < nd.length; j++) {
                if (h[i + j] != nd[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }
}
