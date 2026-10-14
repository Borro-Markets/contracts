// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IMorphoVaultV1Adapter} from "vault-v2/adapters/interfaces/IMorphoVaultV1Adapter.sol";
import {IMorphoVaultV1AdapterFactory} from "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";
import {BorroLib} from "./BorroLib.sol";

/// Deploys the adapter that lets the Borro USDG vault (bUSDG) lend into the Steakhouse USDG vault, so USDG no
/// borrower is using earns Steakhouse's yield. It only deploys the adapter: adding it to bUSDG, its caps and the
/// liquidity switch are the Safe's (tools/safe-steakhouse.py writes those batches).
///
///   forge script script/SteakhouseAdapter.s.sol --rpc-url $RPC --sender <deployer>                 (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                             (for real)
///
/// The adapter is Morpho's own MorphoVaultV1Adapter, made by Morpho's MorphoVaultV1AdapterFactory on Robinhood
/// Chain. The factory's code was checked byte for byte against Morpho's vault-v2 source (commit 2ac0971, built
/// with Morpho's settings), and this script refuses a factory whose code has changed. The adapter only uses the
/// ERC-4626 calls (deposit, withdraw, previewRedeem, balanceOf, asset), which Steakhouse, a Morpho Vault V2,
/// answers the same way. Morpho audited it for Vault V1 targets; what differs for a V2 target is written up in
/// docs/PLAN.md.
///
/// The factory makes the adapter with CREATE2 and a fixed salt, so its address depends only on bUSDG and
/// Steakhouse, and anyone who deploys it gets the same contract. If it already exists this script only checks it.
/// Writes the result to script/out/steakhouse.json (or STEAK_OUT, inside script/out). Optional: DESKS (default
/// script/out/desks.json).
contract SteakhouseAdapter is Script {
    using stdJson for string;

    address constant FACTORY = 0x7a91222F3f7B927bB8fb624593Ca86e111C2F85e;
    bytes32 constant FACTORY_CODEHASH = 0x4e1024d5bfd17914a3ca6ad49905eabdfd60122ccd5a577406e7a4a765bd49ad;

    function run() external returns (address adapter) {
        string memory desks =
            vm.readFile(string.concat(vm.projectRoot(), "/", vm.envOr("DESKS", string("script/out/desks.json"))));
        address busdg = desks.readAddress(".usdgVault");
        address steak = BorroLib.HELD;
        require(FACTORY.codehash == FACTORY_CODEHASH, "the factory's code is not Morpho's MorphoVaultV1AdapterFactory");
        require(IVaultV2(busdg).asset() == BorroLib.USDG && IVaultV2(steak).asset() == BorroLib.USDG, "assets");

        IMorphoVaultV1AdapterFactory factory = IMorphoVaultV1AdapterFactory(FACTORY);
        adapter = factory.morphoVaultV1Adapter(busdg, steak);
        if (adapter == address(0)) {
            vm.startBroadcast();
            adapter = factory.createMorphoVaultV1Adapter(busdg, steak);
            vm.stopBroadcast();
            console2.log("deployed the Steakhouse adapter", adapter);
        } else {
            console2.log("the Steakhouse adapter already exists", adapter);
        }

        IMorphoVaultV1Adapter a = IMorphoVaultV1Adapter(adapter);
        bytes memory idData = abi.encode("this", adapter);
        require(factory.isMorphoVaultV1Adapter(adapter), "not made by the factory");
        require(a.factory() == FACTORY && a.parentVault() == busdg && a.morphoVaultV1() == steak, "adapter links");
        require(a.adapterId() == keccak256(idData), "adapter id");

        string memory out = string.concat(
            "{\"adapter\":\"", vm.toString(adapter), "\",\"factory\":\"", vm.toString(FACTORY), "\",\"parentVault\":\"",
            vm.toString(busdg), "\",\"steakhouse\":\"", vm.toString(steak), "\",\"id\":\"", vm.toString(keccak256(idData)),
            "\",\"idData\":\"", vm.toString(idData), "\"}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/", vm.envOr("STEAK_OUT", string("script/out/steakhouse.json"))), out);
        console2.log("bUSDG          ", busdg);
        console2.log("Steakhouse     ", steak);
        console2.log("cap id         ", vm.toString(keccak256(idData)));
    }
}
