// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";

interface IPonsFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

/// Deploys the BorroDistributor that pays out the $BORRO coin launched on Pons (Roy, 2026-10-05: rewards are
/// that coin, bought with its creator fees and paid daily). It is the same contract as the old emitter's
/// distributor, made for another token: the keeper's fund job sends it the $BORRO it buys, and the rewards job
/// proposes a root of running totals once a day.
///
///   BORRO_TOKEN=<the coin> forge script script/PonsDistributor.s.sol --rpc-url $RPC --sender <deployer>   (dry run)
///   ... --broadcast --private-key $(cat ~/.config/borro/deployer_key)                                   (for real)
///
/// Owner: the Hoard Safe, directly (no transfer to accept). Updater: the keeper. Guardian: the guardian wallet.
/// OWNER, UPDATER and GUARDIAN override them. The token must be a coin the Pons factory launched (checked).
///
/// maxIncreasePerSecond bounds how fast a root's promised total may grow, so a stolen updater key can promise
/// little before the guardian (two hours to throw a root out) steps in; the distributor also never promises more
/// than it holds plus what was claimed. Here it is PER_DAY_BPS of the coin's supply a day (default 1000: 10% of
/// supply, 100 million of a billion). Not lower, because the limit must not hold back honest days: on a fresh Pons
/// curve (1.68 ETH phantom) 0.3 ETH buys about 15% of supply (measured on a fork), so early creator fees can buy
/// several percent a day. Once the coin trades at any real size, a day of fees buys a small fraction of that. If a
/// day's purchase is ever larger, the excess is not lost: it waits, unpromised, for the next proposals (the keeper
/// stays under the limit). The real guard is the guardian's two hours to throw a root out, and the distributor
/// never promising more than it holds. The Safe can change it (setMaxIncreasePerSecond).
///
/// Writes script/out/pons-distributor.json (or PONS_OUT, inside script/out).
contract PonsDistributor is Script {
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant GUARDIAN = 0x81E1b17D1f036303C6147c90b259852E80b767Bc;

    function run() external returns (BorroDistributor dist) {
        address token = vm.envAddress("BORRO_TOKEN");
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        address updater = vm.envOr("UPDATER", KEEPER);
        address guardian = vm.envOr("GUARDIAN", GUARDIAN);
        uint256 perDayBps = vm.envOr("PER_DAY_BPS", uint256(1000));
        require(perDayBps > 0 && perDayBps <= 10_000, "PER_DAY_BPS");

        IPonsFactory.LaunchedToken memory launch = IPonsFactory(PONS_FACTORY).getLaunchedToken(token);
        require(launch.exists && launch.token == token, "not a coin the Pons factory launched");
        require(launch.pairToken == address(0), "the coin is not paired with ETH");
        uint256 supply = IERC20Metadata(token).totalSupply();
        require(supply > 0, "no supply");
        uint256 perSecond = supply * perDayBps / 10_000 / 1 days;

        vm.startBroadcast();
        dist = new BorroDistributor(IERC20Metadata(token), owner, updater, guardian, perSecond);
        vm.stopBroadcast();

        require(address(dist.token()) == token && dist.owner() == owner, "links");
        require(dist.updater() == updater && dist.guardian() == guardian, "roles");
        require(dist.maxIncreasePerSecond() == perSecond, "limit");

        string memory out = string.concat(
            "{\"distributor\":\"", vm.toString(address(dist)), "\",\"token\":\"", vm.toString(token),
            "\",\"symbol\":\"", IERC20Metadata(token).symbol(), "\",\"owner\":\"", vm.toString(owner),
            "\",\"updater\":\"", vm.toString(updater), "\",\"guardian\":\"", vm.toString(guardian),
            "\",\"maxIncreasePerSecond\":\"", vm.toString(perSecond), "\",\"perDayBps\":", vm.toString(perDayBps),
            ",\"block\":", vm.toString(block.number), "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/", vm.envOr("PONS_OUT", string("script/out/pons-distributor.json"))), out);
        console2.log("distributor    ", address(dist));
        console2.log("token          ", token, IERC20Metadata(token).symbol());
        console2.log("owner          ", owner);
        console2.log("updater        ", updater);
        console2.log("guardian       ", guardian);
        console2.log("max per second ", perSecond);
    }
}
