// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsDesk, IShareVault, IPriceFeed} from "../src/OptionsDesk.sol";
import {IStockOracle} from "../src/BorroShort.sol";
import {ILeverDesks} from "../src/LeverRouter.sol";
import {BorroLib} from "./BorroLib.sol";

/// Deploys OptionsDesk, the Options desk (docs/OPTIONS.md): weekly calls and puts on every stock in
/// script/out/desks.json, each listed by the feed its desk's oracle prices it with (the one BorroShort records) and
/// its stock vault (bNVDA and the rest), with puts collateralized in the Steakhouse USDG vault. The deployer owns
/// the desk for the length of the script to do that setup, then hands it to the Hoard Safe, which can never reach
/// a lock, an order or a settlement. Fee 10% of every premium, to the keeper wallet.
///
///   forge script script/OptionsDesk.s.sol --rpc-url $RPC --sender <deployer>             (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                   (for real)
///
/// Real runs go through script/deploy-options-desk.sh, which also records the deploy's chain block from the
/// receipt. A real deploy writes script/out/options-desk.json; a dry run writes script/out/options-desk.dryrun.json.
contract OptionsDeskScript is Script {
    using stdJson for string;

    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    uint16 constant FEE_BPS = 1000;

    function run() external returns (OptionsDesk desk) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        address short = json.readAddress(".short");
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", KEEPER);
        require(IShareVault(BorroLib.HELD).asset() == BorroLib.USDG, "the vault holds USDG");

        // Each desk's feed and stock vault: the feed its market's oracle prices the stock with, checked against what
        // BorroShort recorded; the vault whose asset is the stock.
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".desks[", vm.toString(n), "]"))) n++;
        require(n != 0, "no desks");
        string[] memory symbols = new string[](n);
        address[] memory feeds = new address[](n);
        address[] memory vaults = new address[](n);
        for (uint256 i; i < n; i++) {
            string memory at = string.concat(".desks[", vm.toString(i), "]");
            symbols[i] = json.readString(string.concat(at, ".symbol"));
            address feed = IStockOracle(json.readAddress(string.concat(at, ".oracle"))).QUOTE_FEED_1();
            (,,,, address recorded) = ILeverDesks(short).deskOf(json.readBytes32(string.concat(at, ".marketId")));
            require(feed != address(0) && feed == recorded, string.concat(symbols[i], ": feed"));
            require(IPriceFeed(feed).decimals() == 8, string.concat(symbols[i], ": feed decimals"));
            (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
            require(answer > 0 && updatedAt != 0, string.concat(symbols[i], ": feed prints"));
            address vault = json.readAddress(string.concat(at, ".vault"));
            address stock = IShareVault(vault).asset();
            require(stock != address(0) && stock != BorroLib.USDG, string.concat(symbols[i], ": vault asset"));
            require(IShareVault(vault).convertToShares(1e18) != 0, string.concat(symbols[i], ": vault rate"));
            for (uint256 j; j < i; j++) {
                require(feeds[j] != feed && vaults[j] != vault, string.concat(symbols[i], ": listed twice"));
            }
            feeds[i] = feed;
            vaults[i] = vault;
        }

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        desk = new OptionsDesk(IERC20(BorroLib.USDG), IShareVault(BorroLib.HELD), deployer);
        desk.setFee(FEE_BPS, feeRecipient);
        for (uint256 i; i < n; i++) {
            desk.setStock(feeds[i], IShareVault(vaults[i]), true);
        }
        desk.transferOwnership(owner);
        vm.stopBroadcast();

        require(desk.owner() == owner && desk.feeRecipient() == feeRecipient && desk.feeBps() == FEE_BPS, "roles");
        require(!desk.paused() && desk.nextId() == 1, "fresh");
        require(address(desk.usdg()) == BorroLib.USDG && address(desk.usdgVault()) == BorroLib.HELD, "links");
        string memory list;
        for (uint256 i; i < n; i++) {
            (address feed, IShareVault vault, bool allowed) = desk.stocks(feeds[i]);
            require(feed == feeds[i] && address(vault) == vaults[i] && allowed, string.concat(symbols[i], ": listed"));
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                "{\"symbol\":\"",
                symbols[i],
                "\",\"feed\":\"",
                vm.toString(feeds[i]),
                "\",\"vault\":\"",
                vm.toString(vaults[i]),
                "\",\"stock\":\"",
                vm.toString(IShareVault(vaults[i]).asset()),
                "\"}"
            );
        }

        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory out = string.concat(
            "{\"optionsDesk\":\"", vm.toString(address(desk)), "\",\"owner\":\"", vm.toString(owner),
            "\",\"feeRecipient\":\"", vm.toString(feeRecipient), "\",\"feeBps\":", vm.toString(uint256(FEE_BPS)),
            ",\"usdg\":\"", vm.toString(BorroLib.USDG), "\",\"usdgVault\":\"", vm.toString(BorroLib.HELD),
            "\",\"stocks\":[", list, "],\"dryRun\":", real ? "false" : "true", "}\n"
        );
        vm.writeFile(
            string.concat(vm.projectRoot(), real ? "/script/out/options-desk.json" : "/script/out/options-desk.dryrun.json"), out
        );
        console2.log("optionsDesk", address(desk));
        console2.log("owner      ", owner);
        console2.log("fee to     ", feeRecipient);
        console2.log("stocks     ", n);
    }
}
