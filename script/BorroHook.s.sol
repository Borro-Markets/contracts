// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BorroHook} from "../src/hooks/BorroHook.sol";
import {IVault, IDesks, IFeed} from "../src/hooks/BorroHookDeps.sol";

/// Deploys BorroHook (docs/HOOKS.md) at an address mined for its four hook permissions, lists every Borro desk's
/// USDG/stock pool on it, starts each pool in Uniswap v4, then hands ownership to the Hoard Safe (which accepts it
/// with acceptOwnership from the Safe). Dry run by default; real runs go through script/deploy-borro-hook.sh.
///
///   forge script script/BorroHook.s.sol --rpc-url $RPC --sender <deployer>                         (dry run)
///   ... --broadcast --slow --private-key $(cat ~/.config/borro/deployer_key)                        (for real)
///
/// Writes script/out/borro-hook.json on a real run (script/out/borro-hook.dryrun.json on a dry run). Its "block"
/// is filled in by the wrapper from the receipt: block.number in a script on this chain reads the parent chain's.
contract DeployBorroHook is Script {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant BORRO = 0x89B76DCDDa801f2e456765742C64950eB2A0c93C; // $BORRO on Pons
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    /// desks.json's desk entries (fields in alphabetical order, as parseJson needs).
    struct Desk {
        address adapter;
        bytes32 marketId;
        address oracle;
        string symbol;
        bytes32 usdgMarketId;
        address usdgOracle;
        address vault;
    }

    function run() external returns (BorroHook hook) {
        string memory json = vm.readFile("script/out/desks.json");
        IDesks short = IDesks(vm.parseJsonAddress(json, ".short"));
        IVault usdgVault = IVault(vm.parseJsonAddress(json, ".usdgVault"));
        Desk[] memory desks = abi.decode(vm.parseJson(json, ".desks"), (Desk[]));
        address safe = vm.envOr("SAFE", HOARD_SAFE);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        bytes memory args = abi.encode(POOL_MANAGER, short, usdgVault, IERC20(BORRO), deployer);
        bytes32 salt = _mine(keccak256(abi.encodePacked(type(BorroHook).creationCode, args)));
        hook = new BorroHook{salt: salt}(POOL_MANAGER, short, usdgVault, IERC20(BORRO), deployer);
        PoolId[] memory ids = new PoolId[](desks.length);
        for (uint256 i; i < desks.length; i++) {
            ids[i] = hook.register(desks[i].marketId, IVault(desks[i].vault));
            BorroHook.Pool memory p = hook.poolOf(ids[i]);
            POOL_MANAGER.initialize(hook.keyFor(p.stock), _sqrtPrice(p));
        }
        // No pool can be listed after this, by the deployer or the Safe: every pool lends to a vault in desks.json.
        hook.closeRegistry();
        if (safe != deployer) hook.transferOwnership(safe);
        vm.stopBroadcast();

        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == FLAGS, "hook address has the wrong flags");
        console2.log("hook     ", address(hook));
        console2.log("owner    ", hook.owner());
        console2.log("pending  ", hook.pendingOwner());

        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory out = vm.envOr("HOOK_OUT", string("borro-hook")); // a test names its own record
        string memory list = "[";
        for (uint256 i; i < desks.length; i++) {
            BorroHook.Pool memory p = hook.poolOf(ids[i]);
            console2.log(desks[i].symbol, vm.toString(PoolId.unwrap(ids[i])), address(p.share));
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                '{"symbol":"', desks[i].symbol, '","id":"', vm.toString(PoolId.unwrap(ids[i])), '","share":"',
                vm.toString(address(p.share)), '","stock":"', vm.toString(p.stock), '","vault":"', vm.toString(address(p.stockVault)),
                '","marketId":"', vm.toString(p.marketId), '"}'
            );
        }
        list = string.concat(list, "]");
        string memory doc = string.concat(
            '{"hook":"', vm.toString(address(hook)), '","owner":"', vm.toString(hook.owner()), '","pendingOwner":"',
            vm.toString(hook.pendingOwner()), '","short":"', vm.toString(address(short)), '","usdgVault":"',
            vm.toString(address(usdgVault)), '","pools":', list, ',"note":"block is the chain block from the receipt, filled in by deploy-borro-hook.sh"}'
        );
        vm.writeFile(string.concat("script/out/", out, real ? ".json" : ".dryrun.json"), doc);
    }

    /// A salt whose CREATE2 address (through the deterministic deployer forge uses) carries exactly the four flags.
    function _mine(bytes32 initHash) internal pure returns (bytes32) {
        for (uint256 i; i < 2_000_000; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, bytes32(i), initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == FLAGS) return bytes32(i);
        }
        revert("no salt found");
    }

    /// The pool's starting v4 price, from the feed. Swaps never move it (the hook's curve does the pricing); it only
    /// makes the pool read sensibly in tools that look at it.
    function _sqrtPrice(BorroHook.Pool memory p) internal view returns (uint160) {
        (, int256 a,,,) = IFeed(p.feed).latestRoundData();
        uint256 feedE8 = uint256(a) * 1e8 / p.feedScale;
        // raw stock per raw USDG, or the other way round, as currency1 per currency0, in Q192
        uint256 priceX192 = p.usdgIs0
            ? Math.mulDiv(10 ** p.stockDecimals * 1e8, 1 << 192, feedE8 * 1e6)
            : Math.mulDiv(feedE8 * 1e6, 1 << 192, 10 ** p.stockDecimals * 1e8);
        return uint160(Math.sqrt(priceX192));
    }
}
