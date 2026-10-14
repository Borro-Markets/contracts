// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroLib} from "./BorroLib.sol";
import {CoinListing, IPositionManager} from "../src/coins/CoinListing.sol";
import {CoinShort, IHeld} from "../src/coins/CoinShort.sol";
import {CoinLiquidator, IHeldRedeem} from "../src/coins/CoinLiquidator.sol";
import {IUniV3PoolOracle} from "../src/coins/CoinFeed.sol";
import {IPonsFactory, IPonsLocker, IWETH, IUniswapV3PoolSwap, ICoinListing} from "../src/coins/CoinDeps.sol";

/// Deploys coin shorts (docs/COIN-SHORTS.md): CoinListing, CoinShort (which makes cUSDG) and CoinLiquidator.
/// Dry run by default; real runs go through script/deploy-coin-shorts.sh.
///
/// The Hoard Safe owns CoinListing and CoinShort from the start (no transfer to accept); its only powers there are
/// pausing new listings and new shorts. CoinLiquidator has no owner. Nothing is listed: anyone lists a coin with
/// prepare and, three days later, list.
/// Writes script/out/coin-shorts.json (a dry run: coin-shorts.dryrun.json). The wrapper replaces "block" with the
/// chain's own block from the receipts (block.number in a forge script on this chain is the parent chain's).
contract CoinShortsScript is Script {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant LOCKER = 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    function run() external returns (CoinListing listing, CoinShort short, CoinLiquidator liq) {
        require(block.chainid == 4663, "Robinhood Chain only");
        address safe = vm.envOr("OWNER", HOARD_SAFE);
        require(BorroLib.looksLikeSafe(safe), "OWNER is not a Safe that is set up");
        require(IPonsFactory(PONS).locker() == LOCKER && IPonsFactory(PONS).memeHook() == PONS_HOOK, "Pons moved its locker or hook");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        listing = new CoinListing(
            PM, IPositionManager(POSM), IPonsFactory(PONS), IPonsLocker(LOCKER), IUniV3PoolOracle(ETH_POOL), WETH, BorroLib.USDG, safe, predicted
        );
        short = new CoinShort(
            IMorpho(BorroLib.MORPHO), PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), IERC20(BorroLib.USDG), IHeld(BorroLib.HELD),
            ICoinListing(address(listing)), PONS_HOOK, safe
        );
        require(address(short) == predicted, "CoinShort not where CoinListing expects it");
        liq = new CoinLiquidator(
            IMorpho(BorroLib.MORPHO), PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), IERC20(BorroLib.USDG), IHeldRedeem(BorroLib.HELD),
            ICoinListing(address(listing))
        );
        vm.stopBroadcast();

        require(listing.owner() == safe && short.owner() == safe, "owners");
        console2.log("listing   ", address(listing));
        console2.log("short     ", address(short));
        console2.log("collateral", address(short.collateral()));
        console2.log("liquidator", address(liq));
        console2.log("owner     ", safe);

        string memory j = "out";
        vm.serializeAddress(j, "listing", address(listing));
        vm.serializeAddress(j, "short", address(short));
        vm.serializeAddress(j, "collateral", address(short.collateral()));
        vm.serializeAddress(j, "liquidator", address(liq));
        vm.serializeAddress(j, "owner", safe);
        string memory out = vm.serializeUint(j, "block", block.number);
        bool real = vm.envOr("BROADCASTING", false);
        string memory file = real ? "script/out/coin-shorts.json" : "script/out/coin-shorts.dryrun.json";
        vm.writeJson(out, string.concat(vm.projectRoot(), "/", file));
        console2.log(real ? "wrote script/out/coin-shorts.json" : "dry run: wrote script/out/coin-shorts.dryrun.json");
    }
}
