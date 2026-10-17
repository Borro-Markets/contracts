// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";
import {BorroDrip} from "../src/BorroDrip.sol";
import {BorroLock} from "../src/BorroLock.sol";

/// Deploys Borro's depositor drip (docs/OPS.md, "Depositor drip"): its own BorroDistributor, the BorroDrip that feeds
/// it, and BorroLock, where holders lock $BORRO for a boost on the drip. Three contracts, nothing funded or started.
///
///   forge script script/BorroDrip.s.sol --rpc-url robinhood --sender <deployer>            (dry run)
///   DEPLOYER_PRIVATE_KEY=... forge script ... --broadcast --slow                           (for real)
///
/// The owner runs contracts/script/deploy-borro-drip.sh, which does both and asks in between.
///
/// The distributor pays $BORRO by cumulative Merkle claims. Owner DRIP_DIST_OWNER (default the Hoard Safe: the owner
/// names the updater and the guardian, so a single hot key there could redirect every promised, unclaimed token),
/// updater DRIP_UPDATER (default the keeper), guardian DRIP_GUARDIAN (default the guardian wallet). Its growth limit is
/// set now, before
/// the drip's total is known (the total is whatever the drip holds when the owner calls start()): GROWTH_X100/100 (default 2)
/// times the first period's rate for EXPECTED_TOTAL (whole $BORRO, decimals allowed, default 50,000,000), so the
/// keeper can promise everything the drip lets out for any total up to GROWTH_X100/100 times the expected one, and a
/// stolen updater key can promise little more before the guardian steps in. The Safe can change it later
/// (setMaxIncreasePerSecond).
///
/// The drip: owner DRIP_OWNER (default the launch wallet), the only one who can start and stop it. Any other owner is
/// refused unless CONFIRM_OWNER names the same address. BorroLock has no owner; $BORRO sent to it outside lock() can
/// be skimmed by anyone to DRIP_STRAYS (default the Hoard Safe), fixed at deploy.
///
/// The role settings all start with DRIP_, and the old generic names (OWNER, DIST_OWNER, UPDATER, GUARDIAN) are
/// refused if set: a variable left in a shell for something else must never quietly change who can stop the drip.
///
/// After the deploy (the owner's own steps): send the $BORRO to the drip with a plain transfer, then call start() from the
/// owner wallet; start() fixes the total to what the drip holds at that moment and starts the schedule then.
///
/// Writes script/out/borro-drip.json (or DRIP_OUT, inside script/out). Its "block" is block.number, which on Robinhood
/// Chain is the PARENT chain's block: deploy-borro-drip.sh replaces it with the receipts' blocks.
contract BorroDripDeploy is Script {
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant GUARDIAN = 0x81E1b17D1f036303C6147c90b259852E80b767Bc;
    address constant LAUNCH_WALLET = 0x912CFC9C5D8dC393F5c9949A0912b790529f549E; // the launch wallet
    uint256 constant PERIOD = 26 weeks;

    struct Plan {
        address owner;
        address distOwner;
        address updater;
        address guardian;
        address strays;
        uint256 expected;
        uint256 growthX100;
        uint256 maxIncreasePerSecond;
        string outFile;
    }

    function run() external returns (BorroDistributor dist, BorroDrip drip, BorroLock lock) {
        Plan memory p = plan();
        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address sender = vm.envOr("DEPLOYER_ADDRESS", address(0));
        // A key that is not the deployer's would send from another wallet: refuse before anything is sent.
        if (key != 0 && sender != address(0)) require(vm.addr(key) == sender, "DEPLOYER_PRIVATE_KEY is not DEPLOYER_ADDRESS's key");
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        dist = new BorroDistributor(BORRO, p.distOwner, p.updater, p.guardian, p.maxIncreasePerSecond);
        drip = new BorroDrip(BORRO, address(dist), p.owner);
        lock = new BorroLock(BORRO, p.strays);
        vm.stopBroadcast();

        check(p, dist, drip, lock);
        write(p, dist, drip, lock);
        summary(p, dist, drip, lock);
    }

    function plan() internal view returns (Plan memory p) {
        require(
            !vm.envExists("OWNER") && !vm.envExists("DIST_OWNER") && !vm.envExists("UPDATER") && !vm.envExists("GUARDIAN"),
            "OWNER, DIST_OWNER, UPDATER or GUARDIAN is set in this shell: the drip's settings are DRIP_OWNER, DRIP_DIST_OWNER, DRIP_UPDATER, DRIP_GUARDIAN; unset the old name"
        );
        p.owner = vm.envOr("DRIP_OWNER", LAUNCH_WALLET);
        p.distOwner = vm.envOr("DRIP_DIST_OWNER", HOARD_SAFE);
        p.updater = vm.envOr("DRIP_UPDATER", KEEPER);
        p.guardian = vm.envOr("DRIP_GUARDIAN", GUARDIAN);
        p.strays = vm.envOr("DRIP_STRAYS", HOARD_SAFE);
        require(p.owner != address(0) && p.distOwner != address(0), "DRIP_OWNER and DRIP_DIST_OWNER must not be zero");
        require(p.updater != address(0) && p.guardian != address(0), "DRIP_UPDATER and DRIP_GUARDIAN must not be zero");
        require(p.strays != address(0), "DRIP_STRAYS must not be zero");
        // Whoever owns the drip can take back everything not yet let out: anyone but the launch wallet must be named
        // twice.
        if (p.owner != LAUNCH_WALLET) {
            require(
                vm.envOr("CONFIRM_OWNER", address(0)) == p.owner,
                "DRIP_OWNER is not the launch wallet: set CONFIRM_OWNER to the same address to deploy with it"
            );
        }
        // The keeper and the guardian hold hot keys: neither may own anything that holds the drip's tokens.
        require(p.owner != p.updater && p.owner != p.guardian, "DRIP_OWNER must not be the updater or the guardian");
        require(
            p.distOwner != p.updater && p.distOwner != p.guardian, "DRIP_DIST_OWNER must not be the updater or the guardian"
        );
        require(!vm.envExists("TOTAL") && !vm.envExists("TOTAL_WEI") && !vm.envExists("START"),
            "TOTAL and START are gone: the total is what the drip holds when its owner calls start()");
        p.expected = toWei(vm.envOr("EXPECTED_TOTAL", string("50000000")));
        require(p.expected > 0, "EXPECTED_TOTAL is zero");
        require(address(BORRO).code.length > 0, "no $BORRO contract at the token address");
        require(IERC20Metadata(address(BORRO)).decimals() == 18, "$BORRO has 18 decimals");
        require(p.expected <= BORRO.totalSupply(), "EXPECTED_TOTAL is more than $BORRO's whole supply");
        p.growthX100 = vm.envOr("GROWTH_X100", uint256(200));
        require(p.growthX100 >= 100 && p.growthX100 <= 1000, "GROWTH_X100 must be 100 to 1000");
        p.maxIncreasePerSecond = (((p.expected * 8) / 15) * p.growthX100) / (100 * PERIOD);
        require(p.maxIncreasePerSecond > 0, "the growth limit rounds to zero");
        p.outFile = vm.envOr("DRIP_OUT", string("script/out/borro-drip.json"));
        require(startsWith(p.outFile, "script/out/") && !contains(p.outFile, ".."), "DRIP_OUT must be inside script/out");
    }

    /// Reads back everything the deploy set, from the contracts themselves.
    function check(Plan memory p, BorroDistributor dist, BorroDrip drip, BorroLock lock) internal view {
        require(address(dist.token()) == address(BORRO), "distributor token");
        require(dist.owner() == p.distOwner && dist.pendingOwner() == address(0), "distributor owner");
        require(dist.updater() == p.updater && dist.guardian() == p.guardian, "distributor roles");
        require(dist.maxIncreasePerSecond() == p.maxIncreasePerSecond, "distributor growth limit");
        require(!dist.paused() && dist.root() == bytes32(0) && dist.pendingAt() == 0 && dist.total() == 0, "distributor is fresh");
        require(address(drip.token()) == address(BORRO) && drip.distributor() == address(dist), "drip links");
        require(drip.owner() == p.owner && drip.pendingOwner() == address(0), "drip owner");
        require(drip.PERIOD() == PERIOD && drip.DURATION() == 4 * PERIOD, "drip period");
        require(drip.total() == 0 && drip.startedAt() == 0 && drip.sent() == 0 && drip.stoppedAt() == 0, "drip not started");
        require(address(lock.token()) == address(BORRO) && lock.totalLocked() == 0, "lock token");
        require(lock.strays() == p.strays, "lock strays");
        require(lock.durationOf(0) == 30 days && lock.durationOf(3) == 365 days, "lock lengths");
        require(address(dist).code.length > 0 && address(drip).code.length > 0 && address(lock).code.length > 0, "code");
    }

    /// The four periods for `total`, with the drip's own integer math: 8/15, 4/15, 2/15 and the rest.
    function periods(uint256 total) internal pure returns (uint256[4] memory a) {
        a[0] = (total * 8) / 15;
        a[1] = (total * 4) / 15;
        a[2] = (total * 2) / 15;
        a[3] = total - a[0] - a[1] - a[2];
    }

    function write(Plan memory p, BorroDistributor dist, BorroDrip drip, BorroLock lock) internal {
        uint256[4] memory a = periods(p.expected);
        string memory list = "[";
        for (uint256 i; i < 4; ++i) {
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                "{\"period\":",
                vm.toString(i + 1),
                ",\"amount\":\"",
                vm.toString(a[i]),
                "\",\"perDay\":\"",
                vm.toString((a[i] * 1 days) / PERIOD),
                "\"}"
            );
        }
        string memory out = string.concat(
            "{\"distributor\":\"", vm.toString(address(dist)), "\",\"drip\":\"", vm.toString(address(drip)),
            "\",\"lock\":\"", vm.toString(address(lock)), "\",\"token\":\"", vm.toString(address(BORRO)),
            "\",\"owner\":\"", vm.toString(p.owner), "\",\"distributorOwner\":\"", vm.toString(p.distOwner)
        );
        out = string.concat(
            out, "\",\"updater\":\"", vm.toString(p.updater), "\",\"guardian\":\"", vm.toString(p.guardian),
            "\",\"strays\":\"", vm.toString(p.strays), "\",\"expectedTotal\":\"", vm.toString(p.expected), "\",\"growthX100\":", vm.toString(p.growthX100),
            ",\"maxIncreasePerSecond\":\"", vm.toString(p.maxIncreasePerSecond), "\",\"period\":", vm.toString(PERIOD)
        );
        out = string.concat(
            out, ",\"expectedPeriods\":", list, "],\"distributorCodehash\":\"", vm.toString(address(dist).codehash),
            "\",\"dripCodehash\":\"", vm.toString(address(drip).codehash), "\",\"lockCodehash\":\"",
            vm.toString(address(lock).codehash), "\",\"block\":", vm.toString(block.number), ",\"time\":",
            vm.toString(block.timestamp), "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/", p.outFile), out);
    }

    function summary(Plan memory p, BorroDistributor dist, BorroDrip drip, BorroLock lock) internal view {
        console2.log("==================================================================================");
        console2.log("DRIP OWNER  ", p.owner, p.owner == LAUNCH_WALLET ? "(the launch wallet)" : "(NOT the launch wallet: confirmed by CONFIRM_OWNER)");
        console2.log("  the only address that can start the drip, and stop it to take back everything not yet let out");
        console2.log("==================================================================================");
        console2.log("BorroDistributor (the drip's own)  ", address(dist));
        console2.log("  owner (DRIP_DIST_OWNER)          ", p.distOwner);
        console2.log("  updater (keeper)                 ", p.updater);
        console2.log("  guardian                         ", p.guardian);
        console2.log(string.concat(
            "  growth limit                      ", units(p.maxIncreasePerSecond * 1 days), " BORRO a day (",
            vm.toString(p.maxIncreasePerSecond), " wei a second): ", fixed2(p.growthX100), "x the first period's rate for ",
            units(p.expected)
        ));
        console2.log("BorroDrip                          ", address(drip));
        console2.log("  owner (starts and stops it)      ", p.owner);
        console2.log("  pays into                        ", drip.distributor());
        console2.log("BorroLock (no owner)               ", address(lock));
        console2.log("  strays (skim() sends here)       ", p.strays);
        console2.log("token ($BORRO)                     ", address(BORRO));
        console2.log(string.concat(
            "The total is set by start(): what the drip holds then. For ", units(p.expected),
            " BORRO, over four periods of 26 weeks:"
        ));
        uint256[4] memory a = periods(p.expected);
        for (uint256 i; i < 4; ++i) {
            console2.log(string.concat(
                "  period ", vm.toString(i + 1), "  ", units(a[i]), " BORRO, ", units((a[i] * 1 days) / PERIOD), " a day"
            ));
        }
    }

    // ------------------------------------------------------------------ text

    /// Whole tokens, with decimals allowed ("50000000", "1234.5"), into wei.
    function toWei(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        require(b.length > 0 && b.length <= 40, "EXPECTED_TOTAL: a number of whole $BORRO");
        uint256 whole;
        uint256 frac;
        uint256 fracDigits;
        bool dot;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch == ".") {
                require(!dot, "EXPECTED_TOTAL: one dot at most");
                dot = true;
                continue;
            }
            require(ch >= "0" && ch <= "9", "EXPECTED_TOTAL: digits and one dot only");
            uint256 d = uint8(ch) - 48;
            if (dot) {
                require(fracDigits < 18, "EXPECTED_TOTAL: at most 18 decimals");
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

    function startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) if (a[i] != b[i]) return false;
        return true;
    }

    function contains(string memory s, string memory part) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(part);
        if (a.length < b.length) return false;
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool same = true;
            for (uint256 j; j < b.length && same; ++j) same = a[i + j] == b[j];
            if (same) return true;
        }
        return false;
    }
}
