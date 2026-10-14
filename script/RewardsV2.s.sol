// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BorroRewards} from "../src/BorroRewards.sol";
import {BorroRewardsV2} from "../src/BorroRewardsV2.sol";

/// Deploys BorroRewardsV2: the prize and rent pots with a way back for money the team puts in (Roy, 2026-10-05:
/// "yes build the replacement contract with a reclaim"). Everything else is copied from the live first version so
/// nothing changes for users: the same USDG, the same shorting contract (the only one that can report a close), and
/// the terms in force now. The Hoard Safe owns it directly (no transfer to accept). Switching to it is one Safe
/// transaction, BorroShort.setRewards (tools/safe-rewards-v2.py writes it).
///
///   forge script script/RewardsV2.s.sol --rpc-url $RPC --sender <deployer>                  (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                       (for real)
///
/// A real deploy writes script/out/rewards-v2.json; a dry run writes script/out/rewards-v2.dryrun.json, so a
/// simulation is never mistaken for a contract on chain. OWNER and V1 override the defaults.
contract RewardsV2 is Script {
    address constant V1 = 0x06F37Eb4e37fE6e49d2CD8464B40aEcE0a6f2454;
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    function run() external returns (BorroRewardsV2 v2) {
        BorroRewards v1 = BorroRewards(vm.envOr("V1", V1));
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        IERC20 usdg = v1.usdg();
        address short = v1.short();
        BorroRewards.Terms memory t = v1.terms();
        // Terms queued on the first version would not carry over; copy them by hand if this ever fires.
        require(v1.nextFromWeek() == 0, "v1 has a terms change waiting");

        vm.startBroadcast();
        v2 = new BorroRewardsV2(
            usdg,
            short,
            owner,
            BorroRewardsV2.Terms({prizeShareBps: t.prizeShareBps, rentCapBps: t.rentCapBps, refundShareBps: t.refundShareBps, minNotional: t.minNotional})
        );
        vm.stopBroadcast();

        BorroRewardsV2.Terms memory n = v2.terms();
        require(address(v2.usdg()) == address(usdg) && v2.short() == short && v2.owner() == owner, "links");
        require(n.prizeShareBps == t.prizeShareBps && n.rentCapBps == t.rentCapBps, "terms");
        require(n.refundShareBps == t.refundShareBps && n.minNotional == t.minNotional, "terms");

        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory out = string.concat(
            "{\"rewardsV2\":\"", vm.toString(address(v2)), "\",\"v1\":\"", vm.toString(address(v1)),
            "\",\"usdg\":\"", vm.toString(address(usdg)), "\",\"short\":\"", vm.toString(short),
            "\",\"owner\":\"", vm.toString(owner), "\",\"prizeShareBps\":", vm.toString(uint256(t.prizeShareBps)),
            ",\"rentCapBps\":", vm.toString(uint256(t.rentCapBps)), ",\"refundShareBps\":", vm.toString(uint256(t.refundShareBps)),
            ",\"minNotional\":\"", vm.toString(uint256(t.minNotional)), "\",\"reclaimDelay\":", vm.toString(v2.RECLAIM_DELAY()),
            ",\"dryRun\":", real ? "false" : "true", "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), real ? "/script/out/rewards-v2.json" : "/script/out/rewards-v2.dryrun.json"), out);
        console2.log("rewards v2     ", address(v2));
        console2.log("copied from v1 ", address(v1));
        console2.log("usdg           ", address(usdg));
        console2.log("short          ", short);
        console2.log("owner          ", owner);
        console2.log("terms          ", t.prizeShareBps, t.rentCapBps, t.refundShareBps);
        console2.log("min notional   ", t.minNotional);
        console2.log(real ? "wrote script/out/rewards-v2.json" : "dry run: wrote script/out/rewards-v2.dryrun.json");
    }
}
