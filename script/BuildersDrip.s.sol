// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";
import {TeamReserve} from "../src/TeamReserve.sol";

/// Deploys the Builders Drip's own BorroDistributor (docs/BUILDERS.md, docs/OPS.md "Builders"): one more instance of
/// the contract the depositor drip claims from, for builders. 2026-10-16: "lets include the builders drip on
/// top": 20,000,000 $BORRO from the team reserve over 365 days, split each day across builder codes by the value of
/// the deposits they referred. The keeper's builders job proposes the cumulative Merkle roots; payees claim.
///
///   forge script script/BuildersDrip.s.sol --rpc-url robinhood --sender <deployer>          (dry run)
///   DEPLOYER_PRIVATE_KEY=... forge script ... --broadcast --slow                            (for real)
///
/// The owner runs contracts/script/deploy-builders-drip.sh, which does both and asks in between, records the receipt's
/// chain block, checks the contract on chain and writes the Safe file that funds it.
///
/// Roles: owner BD_OWNER (default the Hoard Safe: it names the updater and the guardian, can pause, and can reclaim at
/// once whatever no root promises), updater BD_UPDATER (default the keeper, which proposes the roots), guardian
/// BD_GUARDIAN (default the guardian wallet, which can throw out a waiting root). The old generic names (OWNER,
/// DIST_OWNER, UPDATER, GUARDIAN) are refused if set.
///
/// Token: $BORRO as the team reserve holds it (script/out/team-reserve.json "token", read back from the reserve on
/// chain), which must also be the depositor drip's token (script/out/borro-drip.json). The reserve must have at least
/// BD_TOTAL unallocated, or there is nothing to fund it with.
///
/// Growth limit: BD_GROWTH_X100/100 (default 2) times the Drip's daily rate, BD_TOTAL (whole $BORRO, default
/// 20,000,000) over BD_DAYS (default 365) days, so the keeper can promise every day's amount with room for its timing,
/// and a stolen updater key can promise little more before the guardian steps in. The Safe can change it later
/// (setMaxIncreasePerSecond).
///
/// Nothing is funded here. Funding is the Safe's queueWithdraw(distributor, total) on the team reserve, executable by
/// anyone 30 to 44 days later (deploy-builders-drip.sh writes the Transaction Builder file).
///
/// Writes script/out/builders-drip.json (a real deploy) or script/out/builders-drip.dryrun.json (a dry run).
contract BuildersDripScript is Script {
    using stdJson for string;

    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant GUARDIAN = 0x81E1b17D1f036303C6147c90b259852E80b767Bc;

    struct Plan {
        address owner;
        address updater;
        address guardian;
        IERC20 token;
        TeamReserve reserve;
        uint256 total;
        uint256 daysCount;
        uint256 perDay;
        uint256 growthX100;
        uint256 maxIncreasePerSecond;
    }

    function run() external returns (BorroDistributor dist) {
        Plan memory p = plan();
        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address sender = vm.envOr("DEPLOYER_ADDRESS", address(0));
        // A key that is not the deployer's would send from another wallet: refuse before anything is sent.
        if (key != 0 && sender != address(0)) require(vm.addr(key) == sender, "DEPLOYER_PRIVATE_KEY is not DEPLOYER_ADDRESS's key");
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        dist = new BorroDistributor(p.token, p.owner, p.updater, p.guardian, p.maxIncreasePerSecond);
        vm.stopBroadcast();

        check(p, dist);
        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        write(p, dist, real);
        summary(p, dist, real);
    }

    function plan() internal view returns (Plan memory p) {
        require(
            !vm.envExists("OWNER") && !vm.envExists("DIST_OWNER") && !vm.envExists("UPDATER") && !vm.envExists("GUARDIAN"),
            "OWNER, DIST_OWNER, UPDATER or GUARDIAN is set in this shell: this script's settings are BD_OWNER, BD_UPDATER, BD_GUARDIAN; unset the old name"
        );
        p.owner = vm.envOr("BD_OWNER", HOARD_SAFE);
        p.updater = vm.envOr("BD_UPDATER", KEEPER);
        p.guardian = vm.envOr("BD_GUARDIAN", GUARDIAN);
        require(p.owner != address(0) && p.updater != address(0) && p.guardian != address(0), "BD_OWNER, BD_UPDATER and BD_GUARDIAN must not be zero");
        // The keeper and the guardian hold hot keys: neither may own what holds the Drip's tokens.
        require(p.owner != p.updater && p.owner != p.guardian, "BD_OWNER must not be the updater or the guardian");
        require(p.updater != p.guardian, "BD_UPDATER and BD_GUARDIAN must differ");

        string memory root = vm.projectRoot();
        string memory res = vm.readFile(string.concat(root, "/script/out/team-reserve.json"));
        string memory drip = vm.readFile(string.concat(root, "/script/out/borro-drip.json"));
        p.reserve = TeamReserve(res.readAddress(".reserve"));
        address token = res.readAddress(".token");
        require(address(p.reserve).code.length > 0, "no team reserve at script/out/team-reserve.json's address");
        require(address(p.reserve.token()) == token, "the team reserve on chain holds another token than its record says");
        require(drip.readAddress(".token") == token, "the team reserve's token is not the depositor drip's $BORRO");
        require(token.code.length > 0, "no $BORRO contract at the token address");
        require(IERC20Metadata(token).decimals() == 18, "$BORRO has 18 decimals");
        p.token = IERC20(token);
        require(p.reserve.owner() == HOARD_SAFE, "the team reserve is not owned by the Hoard Safe");

        p.total = toWei(vm.envOr("BD_TOTAL", string("20000000")));
        p.daysCount = vm.envOr("BD_DAYS", uint256(365));
        require(p.total > 0, "BD_TOTAL is zero");
        require(p.daysCount >= 1 && p.daysCount <= 3650, "BD_DAYS must be 1 to 3650");
        require(p.total <= p.token.totalSupply(), "BD_TOTAL is more than $BORRO's whole supply");
        uint256 free = p.reserve.unallocated();
        require(
            p.total <= free,
            string.concat("the team reserve has only ", units(free), " $BORRO unallocated, under BD_TOTAL ", units(p.total))
        );
        p.perDay = p.total / p.daysCount;
        p.growthX100 = vm.envOr("BD_GROWTH_X100", uint256(200));
        require(p.growthX100 >= 100 && p.growthX100 <= 1000, "BD_GROWTH_X100 must be 100 to 1000");
        p.maxIncreasePerSecond = (p.total * p.growthX100) / (100 * p.daysCount * 1 days);
        require(p.maxIncreasePerSecond > 0, "the growth limit rounds to zero");
    }

    /// Reads back everything the deploy set, from the contract itself.
    function check(Plan memory p, BorroDistributor dist) internal view {
        require(address(dist).code.length > 0, "code");
        require(address(dist.token()) == address(p.token), "distributor token");
        require(dist.owner() == p.owner && dist.pendingOwner() == address(0), "distributor owner");
        require(dist.updater() == p.updater && dist.guardian() == p.guardian, "distributor roles");
        require(dist.maxIncreasePerSecond() == p.maxIncreasePerSecond, "distributor growth limit");
        require(!dist.paused() && dist.root() == bytes32(0) && dist.pendingAt() == 0 && dist.total() == 0, "distributor is fresh");
        require(dist.totalClaimed() == 0 && dist.reclaimable() == 0, "distributor holds nothing");
    }

    function write(Plan memory p, BorroDistributor dist, bool real) internal {
        string memory out = string.concat(
            "{\"distributor\":\"", vm.toString(address(dist)), "\",\"token\":\"", vm.toString(address(p.token)),
            "\",\"owner\":\"", vm.toString(p.owner), "\",\"updater\":\"", vm.toString(p.updater), "\",\"guardian\":\"",
            vm.toString(p.guardian), "\",\"reserve\":\"", vm.toString(address(p.reserve))
        );
        out = string.concat(
            out, "\",\"total\":\"", vm.toString(p.total), "\",\"days\":", vm.toString(p.daysCount), ",\"perDay\":\"",
            vm.toString(p.perDay), "\",\"growthX100\":", vm.toString(p.growthX100), ",\"maxIncreasePerSecond\":\"",
            vm.toString(p.maxIncreasePerSecond), "\",\"codehash\":\"", vm.toString(address(dist).codehash)
        );
        out = string.concat(out, "\",\"dryRun\":", real ? "false" : "true", ",\"time\":", vm.toString(block.timestamp), "}\n");
        vm.writeFile(
            string.concat(vm.projectRoot(), real ? "/script/out/builders-drip.json" : "/script/out/builders-drip.dryrun.json"), out
        );
    }

    function summary(Plan memory p, BorroDistributor dist, bool real) internal view {
        console2.log("BorroDistributor (the Builders Drip's own)", address(dist));
        console2.log("  owner (BD_OWNER)                ", p.owner, p.owner == HOARD_SAFE ? "(the Hoard Safe)" : "(NOT the Hoard Safe)");
        console2.log("  updater (BD_UPDATER)            ", p.updater, p.updater == KEEPER ? "(the keeper)" : "");
        console2.log("  guardian (BD_GUARDIAN)          ", p.guardian, p.guardian == GUARDIAN ? "(the guardian wallet)" : "");
        console2.log("  token ($BORRO)                  ", address(p.token));
        console2.log(string.concat(
            "  the Drip                         ", units(p.total), " $BORRO over ", vm.toString(p.daysCount), " days, ",
            units(p.perDay), " a day"
        ));
        console2.log(string.concat(
            "  growth limit                     ", units(p.maxIncreasePerSecond * 1 days), " $BORRO a day (",
            vm.toString(p.maxIncreasePerSecond), " wei a second): ", fixed2(p.growthX100), "x the daily rate"
        ));
        console2.log("team reserve (funds it)           ", address(p.reserve));
        console2.log(string.concat("  unallocated now                  ", units(p.reserve.unallocated()), " $BORRO"));
        console2.log(real ? "wrote script/out/builders-drip.json" : "dry run: wrote script/out/builders-drip.dryrun.json");
    }

    // ------------------------------------------------------------------ text (as script/BorroDrip.s.sol)

    /// Whole tokens, with decimals allowed ("20000000", "1234.5"), into wei.
    function toWei(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        require(b.length > 0 && b.length <= 40, "BD_TOTAL: a number of whole $BORRO");
        uint256 whole;
        uint256 frac;
        uint256 fracDigits;
        bool dot;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch == ".") {
                require(!dot, "BD_TOTAL: one dot at most");
                dot = true;
                continue;
            }
            require(ch >= "0" && ch <= "9", "BD_TOTAL: digits and one dot only");
            uint256 d = uint8(ch) - 48;
            if (dot) {
                require(fracDigits < 18, "BD_TOTAL: at most 18 decimals");
                frac = frac * 10 + d;
                ++fracDigits;
            } else {
                whole = whole * 10 + d;
            }
        }
        return whole * 1e18 + frac * 10 ** (18 - fracDigits);
    }

    /// Wei as whole tokens with thousands separators and two decimals, rounded.
    function units(uint256 x) internal pure returns (string memory) {
        uint256 c = (x + 5e15) / 1e16; // in hundredths
        uint256 cents = c % 100;
        return string.concat(group(c / 100), ".", cents < 10 ? "0" : "", vm.toString(cents));
    }

    function group(uint256 n) internal pure returns (string memory) {
        if (n < 1000) return vm.toString(n);
        uint256 r = n % 1000;
        return string.concat(group(n / 1000), ",", r < 10 ? "00" : r < 100 ? "0" : "", vm.toString(r));
    }

    function fixed2(uint256 x100) internal pure returns (string memory) {
        uint256 r = x100 % 100;
        return string.concat(vm.toString(x100 / 100), ".", r < 10 ? "0" : "", vm.toString(r));
    }
}
