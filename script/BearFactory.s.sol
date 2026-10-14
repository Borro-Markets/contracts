// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BearVault, IBearShort, IPonsFactory, IPonsFeeVault, IUniversalRouter, ISwapRouter02, IV3PoolOracle} from "../src/BearVault.sol";
import {BearFactory} from "../src/BearFactory.sol";

/// Deploys the BearFactory (docs/BEAR-COINS.md). Dry run by default.
///
///   forge script script/BearFactory.s.sol --rpc-url $RPC --sender <deployer>                      (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                              (for real)
///
/// The factory stores BearVault's creation code at deploy (vaultCodeHash is its hash). Every vault made with
/// createVault(deskId) is owned by whoever makes it and kept by KEEPER (default Borro's keeper); ADMIN (default the
/// Hoard Safe) may change that keeper for vaults made later, nothing else. Launchers make their own vaults from the
/// site; with DESK_ID set, the deployer also makes one (owned by the deployer) as a first check.
///
/// A real deploy writes script/out/bear-factory.json (or BEAR_OUT, inside script/out); a dry run writes only
/// script/out/bear-factory.dryrun.json.
contract BearFactoryScript is Script {
    address constant SHORT = 0xd2D686cEdf225c5C9815187A08812783904E62Eb;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant PONS_FEE_VAULT = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant WETH_USDG_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;

    function run() external returns (BearFactory factory, address vault) {
        BearVault.Env memory env = BearVault.Env({
            short: IBearShort(vm.envOr("SHORT", SHORT)),
            usdg: IERC20(USDG),
            pons: IPonsFactory(PONS_FACTORY),
            feeVault: IPonsFeeVault(PONS_FEE_VAULT),
            ponsHook: PONS_HOOK,
            universalRouter: IUniversalRouter(UNIVERSAL_ROUTER),
            swapRouter: ISwapRouter02(SWAP_ROUTER02),
            weth: WETH,
            wethUsdgPool: IV3PoolOracle(WETH_USDG_POOL)
        });
        bytes memory code = type(BearVault).creationCode;
        bytes32 desk = vm.envOr("DESK_ID", bytes32(0));

        vm.startBroadcast();
        factory = new BearFactory(env, code, vm.envOr("KEEPER", KEEPER), vm.envOr("ADMIN", HOARD_SAFE));
        if (desk != bytes32(0)) vault = factory.createVault(desk);
        vm.stopBroadcast();
        require(keccak256(factory.vaultCode()) == keccak256(code), "stored code differs");

        console2.log("factory  ", address(factory));
        console2.log("keeper   ", factory.keeper());
        console2.log("admin    ", factory.owner());
        console2.log("vault    ", vault);
        // A dry run's addresses are only predictions, so it never writes the real record.
        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory out = "bear";
        vm.serializeAddress(out, "factory", address(factory));
        vm.serializeBytes32(out, "vaultCodeHash", keccak256(code));
        vm.serializeUint(out, "block", block.number);
        string memory json = vm.serializeAddress(out, "vault", vault);
        string memory file = real ? vm.envOr("BEAR_OUT", string("bear-factory.json")) : "bear-factory.dryrun.json";
        vm.writeJson(json, string.concat("script/out/", file));
        console2.log(real ? "wrote script/out/" : "dry run: wrote script/out/", file);
    }
}
