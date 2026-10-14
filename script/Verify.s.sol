// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroLib, IAdapterTimelocks} from "./BorroLib.sol";
import {BorroShort} from "../src/BorroShort.sol";
import {BorroRewards} from "../src/BorroRewards.sol";
import {BorroRouter} from "../src/BorroRouter.sol";
import {BorroLiquidator} from "../src/BorroLiquidator.sol";
import {BorroToken} from "../src/BorroToken.sol";
import {BorroEmitter} from "../src/BorroEmitter.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";

interface IOwned {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/// Read-only check of a finished deploy, run against the real chain after Deploy.s.sol, once the Safe has called
/// `acceptOwnership` on BorroShort:
///
///   OWNER=<safe> DEPLOYER=<the wallet that deployed> KEEPER=<wallet> GUARDIAN=<wallet> TREASURY=<wallet> \
///   FEE_RECIPIENT=<wallet> LOCK_DAYS=3 forge script script/Verify.s.sol --rpc-url $RPC
///
/// Reads every address from script/out/desks.json, sends nothing, and stops at the first thing that is not as
/// it should be, saying what. It checks: OWNER answers like a Safe that is set up; every vault's owner and
/// curator is the Safe; every locked setting waits LOCK_DAYS, and removing an allocator does not wait; every
/// adapter waits LOCK_DAYS to write off loans; no gates, no adapter registry; the allocators are exactly the
/// Safe (and the keeper on the USDG vault) and the sentinels exactly the Safe, counted from every role change
/// since the deploy began; the deployer holds no role anywhere; BorroShort's owner is the Safe (not still
/// waiting for `acceptOwnership`); every other Borro contract's owner, roles and links are as deployed.
/// Optional: FEE_BPS (default 1000), DESKS (default script/out/desks.json), FROM_BLOCK (instead of the block
/// desks.json gives), LOG_CHUNK (blocks per log request; default 0, all at once).
contract Verify is Script {
    using stdJson for string;

    bytes32 constant ALLOCATOR_SET = keccak256("SetIsAllocator(address,bool)");
    bytes32 constant SENTINEL_SET = keccak256("SetIsSentinel(address,bool)");

    struct Expect {
        address owner; // the Safe
        address deployer;
        address keeper;
        address guardian;
        address treasury;
        address feeRecipient;
        uint256 wait; // seconds
        uint256 performanceFee; // WAD
    }

    struct Deployed {
        address short;
        address rewards;
        address usdgVault;
        address usdgAdapter;
        address router;
        address token;
        address emitter;
        address distributor;
        address liquidator;
        address[] vaults; // the stock vaults
        address[] adapters; // their adapters, in the same order
        bytes32[] marketIds; // the short markets
        bytes32[] usdgMarketIds; // the USDG markets
    }

    function run() external {
        Expect memory e = Expect({
            owner: vm.envAddress("OWNER"),
            deployer: vm.envAddress("DEPLOYER"),
            keeper: vm.envAddress("KEEPER"),
            guardian: vm.envAddress("GUARDIAN"),
            treasury: vm.envAddress("TREASURY"),
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            wait: vm.envOr("LOCK_DAYS", uint256(3)) * 1 days,
            performanceFee: vm.envOr("FEE_BPS", uint256(1000)) * 1e14
        });
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/", vm.envOr("DESKS", string("script/out/desks.json"))));
        Deployed memory a = load(json);
        uint256 from = vm.envOr("FROM_BLOCK", vm.keyExistsJson(json, ".block") ? json.readUint(".block") : 0);
        require(from != 0, "Verify: no start block. Set FROM_BLOCK to the deploy's first block");

        check(e, a);

        // Allocators and sentinels cannot be listed from a vault, so every change since the deploy began is
        // replayed: what is left switched on must be exactly the expected set.
        address[] memory safeOnly = new address[](1);
        safeOnly[0] = e.owner;
        address[] memory safeAndKeeper = new address[](2);
        safeAndKeeper[0] = e.owner;
        safeAndKeeper[1] = e.keeper;
        uint256 chunk = vm.envOr("LOG_CHUNK", uint256(0));
        for (uint256 i; i <= a.vaults.length; i++) {
            address v = i < a.vaults.length ? a.vaults[i] : a.usdgVault;
            string memory name = i < a.vaults.length ? IVaultV2(v).symbol() : "bUSDG";
            sameSet(
                holders(_logs(v, ALLOCATOR_SET, from, chunk), v, ALLOCATOR_SET),
                i < a.vaults.length ? safeOnly : safeAndKeeper,
                string.concat(name, " allocators")
            );
            sameSet(holders(_logs(v, SENTINEL_SET, from, chunk), v, SENTINEL_SET), safeOnly, string.concat(name, " sentinels"));
        }
        console2.log("Verify: every check passed.", a.vaults.length + 1, "vaults");
    }

    /// Every check that reads state directly. Reverts with what is wrong.
    function check(Expect memory e, Deployed memory a) public view {
        _need(e.owner != e.deployer, "OWNER is the deployer: Verify checks a real deploy");
        _need(BorroLib.looksLikeSafe(e.owner), "OWNER does not answer like a Safe that is set up (getThreshold, getOwners)");
        _need(e.deployer != e.keeper && e.deployer != e.guardian, "the deployer is the keeper or the guardian");
        _need(a.vaults.length == a.adapters.length && a.vaults.length != 0, "desks");

        for (uint256 i; i <= a.vaults.length; i++) {
            bool usdgSide = i == a.vaults.length;
            _vault(e, usdgSide ? a.usdgVault : a.vaults[i], usdgSide ? a.usdgAdapter : a.adapters[i], usdgSide);
        }

        // BorroShort: the one contract handed over in two steps.
        IOwned s = IOwned(a.short);
        _need(s.pendingOwner() != e.owner, "BorroShort: the Safe has not called acceptOwnership() yet");
        _owned(a.short, e, "BorroShort");
        BorroShort short = BorroShort(a.short);
        _need(address(short.rewards()) == a.rewards, "BorroShort: rewards");
        _need(short.feeRecipient() == e.feeRecipient, "BorroShort: fee recipient");
        for (uint256 i; i < a.marketIds.length; i++) {
            (MarketParams memory m,,,,) = short.deskOf(a.marketIds[i]);
            _need(
                keccak256(abi.encode(m)) == a.marketIds[i] && m.collateralToken == BorroLib.HELD
                    && m.loanToken == IVaultV2(a.vaults[i]).asset(),
                "BorroShort: a desk is not listed as deployed"
            );
        }

        _owned(a.rewards, e, "BorroRewards");
        _need(BorroRewards(a.rewards).short() == a.short, "BorroRewards: shorting contract");

        _owned(a.router, e, "BorroRouter");
        for (uint256 i; i < a.usdgMarketIds.length; i++) {
            _need(BorroRouter(a.router).listed(a.usdgMarketIds[i]), "BorroRouter: a USDG market is not listed");
        }

        BorroLiquidator liq = BorroLiquidator(a.liquidator);
        _need(address(liq.short()) == a.short, "BorroLiquidator: shorting contract");
        _need(address(liq.router()) == a.router, "BorroLiquidator: router");
        _need(liq.held() == BorroLib.HELD, "BorroLiquidator: held vault");

        BorroEmitter emitter = BorroEmitter(a.emitter);
        _owned(a.emitter, e, "BorroEmitter");
        _need(address(emitter.token()) == a.token && BorroToken(a.token).minter() == a.emitter, "BorroEmitter: token");
        _need(emitter.distributor() == a.distributor && emitter.nextDistributorAt() == 0, "BorroEmitter: distributor");
        _need(emitter.treasury() == e.treasury, "BorroEmitter: treasury");

        BorroDistributor dist = BorroDistributor(a.distributor);
        _owned(a.distributor, e, "BorroDistributor");
        _need(address(dist.token()) == a.token, "BorroDistributor: token");
        _need(dist.updater() == e.keeper, "BorroDistributor: updater is not KEEPER");
        _need(dist.guardian() == e.guardian, "BorroDistributor: guardian is not GUARDIAN");
        _need(!dist.paused(), "BorroDistributor: paused");
        _need(
            dist.maxIncreasePerSecond() == (emitter.rate() * emitter.DISTRIBUTOR_BPS()) / emitter.BPS(),
            "BorroDistributor: max increase is not the distributor's share of emissions"
        );
    }

    /// One vault and its adapter: owner, curator, roles that can be read directly, waits, gates and fees.
    function _vault(Expect memory e, address vault, address adapter, bool usdgSide) internal view {
        IVaultV2 v = IVaultV2(vault);
        string memory name = v.symbol();
        _need(v.owner() == e.owner, string.concat(name, ": owner is not the Safe"));
        _need(v.curator() == e.owner, string.concat(name, ": curator is not the Safe"));
        _need(v.isAllocator(e.owner) && v.isSentinel(e.owner), string.concat(name, ": the Safe is not allocator and sentinel"));
        _need(v.isAllocator(e.keeper) == usdgSide, string.concat(name, ": keeper allocator"));
        _need(!v.isAllocator(e.deployer) && !v.isSentinel(e.deployer), string.concat(name, ": the deployer still has a role"));

        bytes4[15] memory sel = BorroLib.lockedSelectors();
        for (uint256 i; i < sel.length; i++) {
            _need(v.timelock(sel[i]) == e.wait, string.concat(name, ": a locked setting does not wait LOCK_DAYS"));
        }
        _need(v.timelock(IVaultV2.setIsAllocator.selector) == 0, string.concat(name, ": removing an allocator waits"));
        _need(v.adaptersLength() == 1 && v.adapters(0) == adapter, string.concat(name, ": adapters"));
        _need(
            IAdapterTimelocks(adapter).timelock(IAdapterTimelocks.burnShares.selector) == e.wait,
            string.concat(name, ": the adapter can write off loans without the wait")
        );
        _need(
            v.receiveSharesGate() == address(0) && v.sendSharesGate() == address(0) && v.receiveAssetsGate() == address(0)
                && v.sendAssetsGate() == address(0) && v.adapterRegistry() == address(0),
            string.concat(name, ": a gate or adapter registry is set")
        );
        _need(v.performanceFee() == e.performanceFee && v.managementFee() == 0, string.concat(name, ": fees"));
        _need(e.performanceFee == 0 || v.performanceFeeRecipient() == e.feeRecipient, string.concat(name, ": fee recipient"));
        _need(
            v.maxRate() == (usdgSide ? BorroLib.MAX_MAX_RATE : BorroLib.STOCK_MAX_RATE), string.concat(name, ": max rate")
        );
    }

    function _owned(address c, Expect memory e, string memory name) internal view {
        _need(IOwned(c).owner() == e.owner, string.concat(name, ": owner is not the Safe"));
        _need(IOwned(c).pendingOwner() == address(0), string.concat(name, ": an ownership change is pending"));
    }

    /// The accounts a vault's role events leave switched on, replaying `logs` in order.
    function holders(VmSafe.Log[] memory logs, address vault, bytes32 topic) public pure returns (address[] memory set) {
        address[] memory seen = new address[](logs.length);
        bool[] memory on = new bool[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != vault || logs[i].topics.length < 2 || logs[i].topics[0] != topic) continue;
            address who = address(uint160(uint256(logs[i].topics[1])));
            bool state = abi.decode(logs[i].data, (bool));
            uint256 j;
            while (j < n && seen[j] != who) j++;
            if (j == n) seen[n++] = who;
            on[j] = state;
        }
        uint256 count;
        for (uint256 j; j < n; j++) if (on[j]) count++;
        set = new address[](count);
        count = 0;
        for (uint256 j; j < n; j++) if (on[j]) set[count++] = seen[j];
    }

    /// Fails unless `got` and `want` hold the same accounts.
    function sameSet(address[] memory got, address[] memory want, string memory what) public pure {
        _need(got.length == want.length, string.concat(what, ": not exactly the expected accounts"));
        for (uint256 i; i < want.length; i++) {
            bool found;
            for (uint256 j; j < got.length; j++) if (got[j] == want[i]) found = true;
            _need(found, string.concat(what, ": not exactly the expected accounts"));
        }
    }

    /// The addresses Deploy.s.sol wrote.
    function load(string memory json) public view returns (Deployed memory a) {
        a.short = json.readAddress(".short");
        a.rewards = json.readAddress(".rewards");
        a.usdgVault = json.readAddress(".usdgVault");
        a.usdgAdapter = json.readAddress(".usdgAdapter");
        a.router = json.readAddress(".router");
        a.token = json.readAddress(".token");
        a.emitter = json.readAddress(".emitter");
        a.distributor = json.readAddress(".distributor");
        a.liquidator = json.readAddress(".liquidator");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".desks[", vm.toString(n), "]"))) n++;
        a.vaults = new address[](n);
        a.adapters = new address[](n);
        a.marketIds = new bytes32[](n);
        a.usdgMarketIds = new bytes32[](n);
        for (uint256 i; i < n; i++) {
            string memory k = string.concat(".desks[", vm.toString(i), "]");
            a.vaults[i] = json.readAddress(string.concat(k, ".vault"));
            a.adapters[i] = json.readAddress(string.concat(k, ".adapter"));
            a.marketIds[i] = json.readBytes32(string.concat(k, ".marketId"));
            a.usdgMarketIds[i] = json.readBytes32(string.concat(k, ".usdgMarketId"));
        }
    }

    /// One role event of one vault, from `from` to the latest block, from the chain itself.
    function _logs(address vault, bytes32 topic, uint256 from, uint256 chunk) internal returns (VmSafe.Log[] memory out) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topic;
        uint256 last = BorroLib.rpcBlock(vm);
        if (chunk == 0) chunk = last - from + 1;
        VmSafe.Log[] memory all = new VmSafe.Log[](0);
        for (uint256 at = from; at <= last; at += chunk) {
            uint256 to = at + chunk - 1 > last ? last : at + chunk - 1;
            VmSafe.EthGetLogs[] memory got = vm.eth_getLogs(at, to, vault, topics);
            VmSafe.Log[] memory merged = new VmSafe.Log[](all.length + got.length);
            for (uint256 i; i < all.length; i++) merged[i] = all[i];
            for (uint256 i; i < got.length; i++) {
                merged[all.length + i] = VmSafe.Log({topics: got[i].topics, data: got[i].data, emitter: got[i].emitter});
            }
            all = merged;
        }
        out = all;
    }

    function _need(bool ok, string memory what) internal pure {
        if (!ok) revert(string.concat("Verify: ", what));
    }
}
