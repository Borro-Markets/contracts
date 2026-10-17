// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {BorroBuilders, IBuilderVault} from "../src/BorroBuilders.sol";
import {BorroLib} from "./BorroLib.sol";

/// Deploys BorroBuilders: the referral program's contract (register a code, deposit to a Borro vault in the caller's
/// name with that code). Wired to the live system from script/out/desks.json: the nine stock vaults and the Borro
/// USDG vault, listed from the start. The Hoard Safe owns it directly; all it can do is list vaults and sweep
/// mistakes. It holds no one's money between transactions, so deploying it changes nothing for anyone until the site
/// uses it.
///
///   forge script script/BorroBuilders.s.sol --rpc-url $RPC --sender <deployer>               (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                      (for real)
///
/// Real runs go through script/deploy-builders.sh, which also records the deploy's chain block from the receipt (the
/// keeper scans the contract's events from there). A real deploy writes script/out/builders.json; a dry run writes
/// script/out/builders.dryrun.json. OWNER overrides the owner.
contract BorroBuildersScript is Script {
    using stdJson for string;

    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    function run() external returns (BorroBuilders builders) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".desks[", vm.toString(n), "]"))) n++;
        address[] memory vaults = new address[](n + 1);
        for (uint256 i; i < n; i++) {
            string memory at = string.concat(".desks[", vm.toString(i), "]");
            address vault = json.readAddress(string.concat(at, ".vault"));
            // Each stock vault holds a stock, never USDG.
            address stock = IBuilderVault(vault).asset();
            require(stock != address(0) && stock != BorroLib.USDG, "a stock vault");
            vaults[i] = vault;
        }
        vaults[n] = json.readAddress(".usdgVault");
        require(IBuilderVault(vaults[n]).asset() == BorroLib.USDG, "the USDG vault holds USDG");

        vm.startBroadcast();
        builders = new BorroBuilders(owner, vaults);
        vm.stopBroadcast();

        require(builders.owner() == owner, "links");
        for (uint256 i; i < vaults.length; i++) require(builders.vaults(vaults[i]), "vault listed");

        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory list;
        for (uint256 i; i < vaults.length; i++) list = string.concat(list, i == 0 ? "" : ",", "\"", vm.toString(vaults[i]), "\"");
        string memory out = string.concat(
            "{\"builders\":\"", vm.toString(address(builders)), "\",\"owner\":\"", vm.toString(owner),
            "\",\"vaults\":[", list, "],\"dryRun\":", real ? "false" : "true", "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), real ? "/script/out/builders.json" : "/script/out/builders.dryrun.json"), out);
        console2.log("builders ", address(builders));
        console2.log("owner    ", owner);
        console2.log("vaults   ", vaults.length);
        console2.log(real ? "wrote script/out/builders.json" : "dry run: wrote script/out/builders.dryrun.json");
    }
}
