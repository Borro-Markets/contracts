// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {LeverRouter, ILeverDesks, ILeverMarkets, ILeverVault} from "../src/LeverRouter.sol";
import {BorroLib} from "./BorroLib.sol";

/// Deploys LeverRouter: one-click leveraged longs (and their closes) on Borro's USDG markets. Wired to the live
/// system from script/out/desks.json: the live BorroShort for the stock routes and the live BorroRouter for its list
/// of Borro's USDG markets. The Hoard Safe owns it directly; all it can do is stop new opens. It holds no one's money
/// between transactions, so deploying it changes nothing for anyone until the site uses it.
///
///   forge script script/LeverRouter.s.sol --rpc-url $RPC --sender <deployer>                (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                       (for real)
///
/// Real runs go through script/deploy-lever-router.sh, which also records the deploy's chain block from the receipt.
/// A real deploy writes script/out/lever-router.json; a dry run writes script/out/lever-router.dryrun.json.
contract LeverRouterScript is Script {
    using stdJson for string;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    function run() external returns (LeverRouter lever) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        address short = json.readAddress(".short");
        address markets = json.readAddress(".router");
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        IMorpho morpho = IMorpho(BorroLib.MORPHO);

        // Every desk's USDG market must be on BorroRouter's list and lend against the desk stock's vault.
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".desks[", vm.toString(n), "]"))) n++;
        for (uint256 i; i < n; i++) {
            string memory at = string.concat(".desks[", vm.toString(i), "]");
            bytes32 id = json.readBytes32(string.concat(at, ".marketId"));
            bytes32 usdgId = json.readBytes32(string.concat(at, ".usdgMarketId"));
            (MarketParams memory shortMarket, PoolKey[] memory route, address v3Pool,,) = ILeverDesks(short).deskOf(id);
            MarketParams memory m = morpho.idToMarketParams(Id.wrap(usdgId));
            require(route.length != 0 || v3Pool != address(0), "desk route");
            require(m.loanToken == BorroLib.USDG && ILeverMarkets(markets).listed(usdgId), "a listed USDG market");
            require(ILeverVault(m.collateralToken).asset() == shortMarket.loanToken, "lends against the desk stock's vault");
        }

        vm.startBroadcast();
        lever = new LeverRouter(morpho, IPoolManager(POOL_MANAGER), IERC20(BorroLib.USDG), ILeverDesks(short), ILeverMarkets(markets), owner);
        vm.stopBroadcast();

        require(
            address(lever.desks()) == short && address(lever.markets()) == markets && lever.owner() == owner
                && address(lever.morpho()) == BorroLib.MORPHO && !lever.opensPaused(),
            "links"
        );
        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory out = string.concat(
            "{\"leverRouter\":\"", vm.toString(address(lever)), "\",\"short\":\"", vm.toString(short), "\",\"markets\":\"",
            vm.toString(markets), "\",\"owner\":\"", vm.toString(owner), "\",\"dryRun\":", real ? "false" : "true", "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), real ? "/script/out/lever-router.json" : "/script/out/lever-router.dryrun.json"), out);
        console2.log("leverRouter", address(lever));
        console2.log("owner      ", owner);
    }
}
