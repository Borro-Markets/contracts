// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TeamReserve} from "../src/TeamReserve.sol";

/// Deploys the team reserve (docs/OPS.md, "Team reserve"): one TeamReserve for $BORRO, owned by the Hoard Safe.
/// Nothing is funded here.
///
///   forge script script/TeamReserve.s.sol --rpc-url robinhood --sender <deployer>          (dry run)
///   DEPLOYER_PRIVATE_KEY=... forge script ... --broadcast --slow                           (for real)
///
/// Roy runs contracts/script/deploy-team-reserve.sh, which does both and asks in between.
///
/// Owner OWNER (default the Hoard Safe): the only address that can grant, revoke, queue and cancel withdrawals. It
/// must not be the deployer, the keeper or the guardian (hot keys), and it must be a contract (a Safe) unless
/// ALLOW_EOA_OWNER=1. EXPECTED_AMOUNT (whole $BORRO, default 34,100,000) is only printed and recorded: what goes in
/// is whatever Roy transfers afterwards.
///
/// Writes script/out/team-reserve.json (or RESERVE_OUT, inside script/out). Its "block" is block.number, which on
/// Robinhood Chain is the PARENT chain's block: deploy-team-reserve.sh replaces it with the receipt's block.
contract TeamReserveDeploy is Script {
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant DEPLOYER = 0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant GUARDIAN = 0x81E1b17D1f036303C6147c90b259852E80b767Bc;

    function run() external returns (TeamReserve reserve) {
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        require(owner != address(0), "OWNER is zero");
        require(owner != DEPLOYER && owner != KEEPER && owner != GUARDIAN, "OWNER must not be a hot key (deployer, keeper, guardian)");
        if (!vm.envOr("ALLOW_EOA_OWNER", false)) require(owner.code.length > 0, "OWNER has no code: expected the Hoard Safe");
        require(address(BORRO).code.length > 0, "no $BORRO contract at the token address");
        require(IERC20Metadata(address(BORRO)).decimals() == 18, "$BORRO has 18 decimals");
        require(keccak256(bytes(IERC20Metadata(address(BORRO)).symbol())) == keccak256("BORRO"), "the token is not BORRO");
        uint256 expected = vm.envOr("EXPECTED_AMOUNT", uint256(34_100_000)) * 1e18;
        require(expected <= BORRO.totalSupply(), "EXPECTED_AMOUNT is more than the whole supply");
        string memory outFile = vm.envOr("RESERVE_OUT", string("script/out/team-reserve.json"));
        require(startsWith(outFile, "script/out/") && !contains(outFile, ".."), "RESERVE_OUT must be inside script/out");

        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address sender = vm.envOr("DEPLOYER_ADDRESS", address(0));
        // A key that is not the deployer's would send from another wallet: refuse before anything is sent.
        if (key != 0 && sender != address(0)) require(vm.addr(key) == sender, "DEPLOYER_PRIVATE_KEY is not DEPLOYER_ADDRESS's key");
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        reserve = new TeamReserve(BORRO, owner);
        vm.stopBroadcast();

        // Read back everything from the contract itself.
        require(address(reserve.token()) == address(BORRO), "token");
        require(reserve.owner() == owner && reserve.pendingOwner() == address(0), "owner");
        require(reserve.totalGranted() == 0 && reserve.totalQueued() == 0, "fresh totals");
        require(reserve.grantCount() == 0 && reserve.withdrawalCount() == 0, "no grants or withdrawals");
        require(reserve.CLIFF() == 365 days && reserve.DURATION() == 4 * 365 days, "schedule");
        require(reserve.WITHDRAW_DELAY() == 30 days && reserve.EXECUTE_WINDOW() == 14 days, "withdrawal timing");

        string memory out = string.concat(
            "{\"reserve\":\"", vm.toString(address(reserve)), "\",\"token\":\"", vm.toString(address(BORRO)),
            "\",\"owner\":\"", vm.toString(owner), "\",\"expectedAmount\":\"", vm.toString(expected),
            "\",\"reserveCodehash\":\"", vm.toString(address(reserve).codehash)
        );
        out = string.concat(
            out, "\",\"cliffSeconds\":", vm.toString(reserve.CLIFF()), ",\"durationSeconds\":", vm.toString(reserve.DURATION()),
            ",\"monthSeconds\":", vm.toString(reserve.MONTH()), ",\"withdrawDelaySeconds\":", vm.toString(reserve.WITHDRAW_DELAY()),
            ",\"executeWindowSeconds\":", vm.toString(reserve.EXECUTE_WINDOW()),
            ",\"block\":", vm.toString(block.number), ",\"time\":", vm.toString(block.timestamp), "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/", outFile), out);

        console2.log("TeamReserve                    ", address(reserve));
        console2.log("  owner (grants, revokes, queues)", owner);
        console2.log("  token ($BORRO)               ", address(BORRO));
        console2.log("  vesting                       1 year cliff (25%), then 1/48 a month, whole at 4 years");
        console2.log("  any other withdrawal          queued in public, executable by anyone 30 to 44 days later");
        console2.log("  planned funding (BORRO)      ", expected / 1e18);
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
