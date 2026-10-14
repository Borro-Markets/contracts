// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GapPool, IHeldVault, IPriceFeed} from "../src/GapPool.sol";
import {IStockOracle} from "../src/BorroShort.sol";
import {ILeverDesks} from "../src/LeverRouter.sol";
import {BorroLib} from "./BorroLib.sol";

/// Deploys GapPool, the Weekend Desk's Monday-gap cover (docs/WEEKEND.md). Its capital sits in the Steakhouse USDG
/// vault, the same vault BorroShort's held money sits in. Every stock in script/out/desks.json is allowed at 25%
/// exposure, by the feed its desk's oracle prices it with (the one BorroShort records). The deployer owns the pool
/// for the length of the script to do that setup, then hands it to the Hoard Safe, which can never reach capital or
/// a cover. Quoter and fee recipient: the keeper wallet. Fee 10%, cap 10%, premiums from 5 to 2,000 bps.
///
///   forge script script/GapPool.s.sol --rpc-url $RPC --sender <deployer>                (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                   (for real)
///
/// Real runs go through script/deploy-gap-pool.sh, which also records the deploy's chain block from the receipt.
/// A real deploy writes script/out/gap-pool.json; a dry run writes script/out/gap-pool.dryrun.json.
contract GapPoolScript is Script {
    using stdJson for string;

    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    uint16 constant FEE_BPS = 1000;
    uint16 constant CAP_BPS = 1000;
    uint16 constant MIN_PREMIUM_BPS = 5; // a floor against a mispriced side; the model prices each side (docs/WEEKEND.md)
    uint16 constant MAX_PREMIUM_BPS = 2000;
    uint16 constant EXPOSURE_BPS = 2500;
    uint16 constant TOTAL_EXPOSURE_BPS = 3000; // all live covers together, at most 30% of the pool

    function run() external returns (GapPool pool) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        address short = json.readAddress(".short");
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        address quoter = vm.envOr("QUOTER", KEEPER);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", KEEPER);
        require(IHeldVault(BorroLib.HELD).asset() == BorroLib.USDG, "the vault holds USDG");

        // Each desk's feed: what its market's oracle prices the stock with, and what BorroShort recorded for it.
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".desks[", vm.toString(n), "]"))) n++;
        require(n != 0, "no desks");
        string[] memory symbols = new string[](n);
        address[] memory feeds = new address[](n);
        for (uint256 i; i < n; i++) {
            string memory at = string.concat(".desks[", vm.toString(i), "]");
            symbols[i] = json.readString(string.concat(at, ".symbol"));
            address feed = IStockOracle(json.readAddress(string.concat(at, ".oracle"))).QUOTE_FEED_1();
            (,,,, address recorded) = ILeverDesks(short).deskOf(json.readBytes32(string.concat(at, ".marketId")));
            require(feed != address(0) && feed == recorded, string.concat(symbols[i], ": feed"));
            require(IPriceFeed(feed).decimals() == 8, string.concat(symbols[i], ": feed decimals"));
            (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
            require(answer > 0 && updatedAt != 0, string.concat(symbols[i], ": feed prints"));
            for (uint256 j; j < i; j++) {
                require(feeds[j] != feed, string.concat(symbols[i], ": feed twice"));
            }
            feeds[i] = feed;
        }

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        pool = new GapPool(IERC20(BorroLib.USDG), IHeldVault(BorroLib.HELD), deployer, feeds);
        pool.setQuoter(quoter);
        pool.setTotalExposure(TOTAL_EXPOSURE_BPS);
        pool.setFee(FEE_BPS, feeRecipient);
        pool.setCapBps(CAP_BPS);
        pool.setPremiumBounds(MIN_PREMIUM_BPS, MAX_PREMIUM_BPS);
        for (uint256 i; i < n; i++) {
            pool.setStock(feeds[i], true, EXPOSURE_BPS);
        }
        pool.transferOwnership(owner);
        vm.stopBroadcast();

        require(pool.owner() == owner && pool.quoter() == quoter && pool.feeRecipient() == feeRecipient, "roles");
        require(
            pool.feeBps() == FEE_BPS && pool.capBps() == CAP_BPS && pool.minPremiumBps() == MIN_PREMIUM_BPS
                && pool.maxPremiumBps() == MAX_PREMIUM_BPS && pool.maxTotalExposureBps() == TOTAL_EXPOSURE_BPS
                && !pool.buysPaused() && !pool.depositsPaused(),
            "settings"
        );
        require(address(pool.usdg()) == BorroLib.USDG && address(pool.vault()) == BorroLib.HELD, "links");
        require(pool.totalAssets() == 0 && pool.totalSupply() == 0 && pool.nextId() == 1, "empty");
        string memory feedList;
        for (uint256 i; i < n; i++) {
            (address feed, bool allowed, uint16 exposure,) = pool.stocks(feeds[i]);
            require(feed == feeds[i] && allowed && exposure == EXPOSURE_BPS, string.concat(symbols[i], ": allowed"));
            feedList = string.concat(
                feedList, i == 0 ? "" : ",", "{\"symbol\":\"", symbols[i], "\",\"feed\":\"", vm.toString(feeds[i]), "\"}"
            );
        }

        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory out = string.concat(
            "{\"gapPool\":\"", vm.toString(address(pool)), "\",\"owner\":\"", vm.toString(owner), "\",\"quoter\":\"",
            vm.toString(quoter), "\",\"feeRecipient\":\"", vm.toString(feeRecipient), "\",\"feeBps\":",
            vm.toString(uint256(FEE_BPS)), ",\"capBps\":", vm.toString(uint256(CAP_BPS)), ",\"premiumMinBps\":",
            vm.toString(uint256(MIN_PREMIUM_BPS)), ",\"premiumMaxBps\":", vm.toString(uint256(MAX_PREMIUM_BPS)),
            ",\"exposureBps\":", vm.toString(uint256(EXPOSURE_BPS)), ",\"usdg\":\"", vm.toString(BorroLib.USDG),
            "\",\"vault\":\"", vm.toString(BorroLib.HELD), "\",\"feeds\":[", feedList, "],\"dryRun\":",
            real ? "false" : "true", "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), real ? "/script/out/gap-pool.json" : "/script/out/gap-pool.dryrun.json"), out);
        console2.log("gapPool", address(pool));
        console2.log("owner  ", owner);
        console2.log("quoter ", quoter);
        console2.log("feeds  ", n);
    }
}
