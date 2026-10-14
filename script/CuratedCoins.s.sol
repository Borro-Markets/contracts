// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroLib} from "./BorroLib.sol";
import {EthPrice} from "../src/coins/EthPrice.sol";
import {IUniV3PoolOracle} from "../src/coins/CoinFeed.sol";
import {IWETH} from "../src/coins/CoinDeps.sol";
import {IHeld} from "../src/coins/CoinShort.sol";
import {IHeldRedeem} from "../src/coins/CoinLiquidator.sol";
import {CoinLens} from "../src/coins/v2/CoinLens.sol";
import {CuratedFeeds} from "../src/coins/v2/CuratedFeeds.sol";
import {CuratedListing} from "../src/coins/v2/CuratedListing.sol";
import {CoinRouter} from "../src/coins/v2/CoinRouter.sol";
import {CuratedShort} from "../src/coins/v2/CuratedShort.sol";
import {CuratedLiquidator} from "../src/coins/v2/CuratedLiquidator.sol";
import {CuratedLoans} from "../src/coins/v2/CuratedLoans.sol";
import {CuratedLoanLiquidator} from "../src/coins/v2/CuratedLoanLiquidator.sol";
import {ICuratedListing, IV3Pool, IV3Factory, IStockDesks} from "../src/coins/v2/VenueDeps.sol";

/// Deploys curated coins (docs/COIN-SHORTS.md, phase 2), an add-on beside the Pons coin shorts that never touches
/// them: EthPrice and CoinLens (reading), CuratedFeeds (making feeds), CuratedListing, CoinRouter, CuratedShort (which
/// makes its own cUSDG), CuratedLiquidator, CuratedLoans and CuratedLoanLiquidator. Dry run by default; real runs go
/// through script/deploy-curated-coins.sh.
///
/// The Hoard Safe owns CuratedListing, CuratedShort and CuratedLoans from the start; its powers there are allowing a
/// coin that is not listed yet (CuratedListing.allow) and pausing. The rest have no owner. Nothing is allowed or
/// listed: the Safe allows coins from the vetting report, then anyone lists them.
/// Writes script/out/curated-coins.json (a dry run: curated-coins.dryrun.json). The wrapper replaces "block" with the
/// chain's own block from the receipts (block.number in a forge script on this chain is the parent chain's).
contract CuratedCoinsScript is Script {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant BORRO_SHORT = 0xd2D686cEdf225c5C9815187A08812783904E62Eb; // the stock desks: routes and feeds
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    struct Out {
        EthPrice ethPrice;
        CoinLens lens;
        CuratedFeeds feeds;
        CuratedListing listing;
        CoinRouter router;
        CuratedShort short;
        CuratedLiquidator liquidator;
        CuratedLoans loans;
        CuratedLoanLiquidator loanLiquidator;
    }

    function run() external returns (Out memory o) {
        require(block.chainid == 4663, "Robinhood Chain only");
        address safe = vm.envOr("OWNER", HOARD_SAFE);
        require(BorroLib.looksLikeSafe(safe), "OWNER is not a Safe that is set up");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        o.ethPrice = new EthPrice(IUniV3PoolOracle(ETH_POOL), WETH, BorroLib.USDG, 1800);
        o.lens = new CoinLens(PM, IV3Factory(V3_FACTORY), WETH, BorroLib.USDG, o.ethPrice, IStockDesks(BORRO_SHORT));
        o.feeds = new CuratedFeeds(o.lens);
        // CuratedListing names CuratedShort, which is made two deploys later.
        address shortAt = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        o.listing = new CuratedListing(o.lens, o.feeds, BorroLib.USDG, safe, shortAt);
        o.router = new CoinRouter(PM, IV3Pool(ETH_POOL), IWETH(WETH), IERC20(BorroLib.USDG), ICuratedListing(address(o.listing)), IStockDesks(BORRO_SHORT));
        o.short = new CuratedShort(IMorpho(BorroLib.MORPHO), IERC20(BorroLib.USDG), IHeld(BorroLib.HELD), ICuratedListing(address(o.listing)), o.router, safe);
        require(address(o.short) == shortAt, "CuratedShort not where CuratedListing expects it");
        o.liquidator = new CuratedLiquidator(IMorpho(BorroLib.MORPHO), IERC20(BorroLib.USDG), IHeldRedeem(BorroLib.HELD), ICuratedListing(address(o.listing)), o.router);
        o.loans = new CuratedLoans(IMorpho(BorroLib.MORPHO), ICuratedListing(address(o.listing)), IERC20(BorroLib.USDG), safe);
        o.loanLiquidator = new CuratedLoanLiquidator(IMorpho(BorroLib.MORPHO), IERC20(BorroLib.USDG), o.loans, o.router);
        vm.stopBroadcast();

        require(o.listing.owner() == safe && o.short.owner() == safe && o.loans.owner() == safe, "owners");
        console2.log("ethPrice      ", address(o.ethPrice));
        console2.log("lens          ", address(o.lens));
        console2.log("feeds         ", address(o.feeds));
        console2.log("listing       ", address(o.listing));
        console2.log("router        ", address(o.router));
        console2.log("short         ", address(o.short));
        console2.log("collateral    ", address(o.short.collateral()));
        console2.log("liquidator    ", address(o.liquidator));
        console2.log("loans         ", address(o.loans));
        console2.log("loanLiquidator", address(o.loanLiquidator));
        console2.log("owner         ", safe);

        string memory j = "out";
        vm.serializeAddress(j, "ethPrice", address(o.ethPrice));
        vm.serializeAddress(j, "lens", address(o.lens));
        vm.serializeAddress(j, "feeds", address(o.feeds));
        vm.serializeAddress(j, "listing", address(o.listing));
        vm.serializeAddress(j, "router", address(o.router));
        vm.serializeAddress(j, "short", address(o.short));
        vm.serializeAddress(j, "collateral", address(o.short.collateral()));
        vm.serializeAddress(j, "liquidator", address(o.liquidator));
        vm.serializeAddress(j, "loans", address(o.loans));
        vm.serializeAddress(j, "loanLiquidator", address(o.loanLiquidator));
        vm.serializeAddress(j, "owner", safe);
        string memory out = vm.serializeUint(j, "block", block.number);
        bool real = vm.envOr("BROADCASTING", false);
        string memory file = real ? "script/out/curated-coins.json" : "script/out/curated-coins.dryrun.json";
        vm.writeJson(out, string.concat(vm.projectRoot(), "/", file));
        console2.log(real ? "wrote script/out/curated-coins.json" : "dry run: wrote script/out/curated-coins.dryrun.json");
    }
}
