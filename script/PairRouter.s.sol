// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {PairRouter, IShortDesks, IPairVault} from "../src/PairRouter.sol";
import {BorroLib} from "./BorroLib.sol";

/// Deploys PairRouter: the long leg of a pair trade (buy a stock through the route Borro's short desk uses, lend it
/// to the stock's Borro vault in the caller's name). It is wired to the live system from script/out/desks.json: the
/// live BorroShort for the routes, and the nine stock vaults listed from the start. The Hoard Safe owns it directly.
/// It holds no one's money between transactions, so deploying it changes nothing for anyone until the site uses it.
///
///   forge script script/PairRouter.s.sol --rpc-url $RPC --sender <deployer>                (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                      (for real)
///
/// A real deploy writes script/out/pair-router.json; a dry run writes script/out/pair-router.dryrun.json. OWNER
/// overrides the owner.
contract PairRouterScript is Script {
    using stdJson for string;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    function run() external returns (PairRouter pair) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        address short = json.readAddress(".short");
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".desks[", vm.toString(n), "]"))) n++;
        address[] memory vaults = new address[](n);
        for (uint256 i; i < n; i++) {
            string memory at = string.concat(".desks[", vm.toString(i), "]");
            address vault = json.readAddress(string.concat(at, ".vault"));
            bytes32 id = json.readBytes32(string.concat(at, ".marketId"));
            // Each vault lends the stock its desk shorts, and the desk is live with a route.
            (MarketParams memory m, PoolKey[] memory route, address v3Pool,,) = IShortDesks(short).deskOf(id);
            require(m.loanToken != address(0) && IPairVault(vault).asset() == m.loanToken, "vault holds the desk's stock");
            require(route.length != 0 || v3Pool != address(0), "desk route");
            vaults[i] = vault;
        }

        vm.startBroadcast();
        pair = new PairRouter(IPoolManager(POOL_MANAGER), IERC20(BorroLib.USDG), IShortDesks(short), owner, vaults);
        vm.stopBroadcast();

        require(address(pair.desks()) == short && pair.owner() == owner && address(pair.usdg()) == BorroLib.USDG, "links");
        for (uint256 i; i < n; i++) require(pair.vaults(vaults[i]), "vault listed");

        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory list;
        for (uint256 i; i < n; i++) list = string.concat(list, i == 0 ? "" : ",", "\"", vm.toString(vaults[i]), "\"");
        string memory out = string.concat(
            "{\"pairRouter\":\"", vm.toString(address(pair)), "\",\"short\":\"", vm.toString(short),
            "\",\"owner\":\"", vm.toString(owner), "\",\"vaults\":[", list, "],\"dryRun\":", real ? "false" : "true", "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), real ? "/script/out/pair-router.json" : "/script/out/pair-router.dryrun.json"), out);
        console2.log("pair router ", address(pair));
        console2.log("short desks ", short);
        console2.log("owner       ", owner);
        console2.log("vaults      ", n);
        console2.log(real ? "wrote script/out/pair-router.json" : "dry run: wrote script/out/pair-router.dryrun.json");
    }
}
