// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {BorroLib, IERC20Min} from "./BorroLib.sol";
import {StockList} from "./StockList.sol";
import {BorroShort, IUniswapV3Factory, IHeldVault, IBorroRewards} from "../src/BorroShort.sol";
import {BorroRewards} from "../src/BorroRewards.sol";
import {BorroRouter} from "../src/BorroRouter.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";
import {BorroEmitter} from "../src/BorroEmitter.sol";
import {BorroLiquidator, IBorroDesks, IBorroMarkets} from "../src/BorroLiquidator.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys all of Borro: one desk per stock in stocks.json (oracle, market, vault: lend the stock, short it), its
/// USDG market (post the stock vault's shares, borrow USDG), the Borro USDG vault, the shorting contract and the
/// rewards pots, the router, the BORRO token with its emitter and distributor, and the liquidator.
///
///   OWNER=<safe> FEE_RECIPIENT=<wallet> KEEPER=<wallet> TREASURY=<wallet> GUARDIAN=<wallet> \
///   EMISSION_START=<unix time> LOCK_DAYS=3 forge script script/Deploy.s.sol --rpc-url $RPC --sender <deployer>   (dry run)
///   ... --broadcast --account <keystore name>                                                                  (for real)
///   then: script/Verify.s.sol, once the Safe has called `acceptOwnership` on BorroShort.
///
/// The wallet that signs (the deployer) sets everything up, then hands every vault to OWNER (owner, curator,
/// allocator and sentinel) and keeps no role. OWNER must be a Safe that is set up (it answers getThreshold() of
/// at least one and getOwners()), or the deployer itself for a private test chain. BorroShort changes owner in
/// two steps: the Safe must call `acceptOwnership` on it. Everything else is made with OWNER as its owner from
/// the start. KEEPER allocates the USDG vault and proposes reward roots; GUARDIAN can revoke a proposed root and
/// pause claims (it must not be KEEPER); TREASURY receives 12% of emissions.
/// The deployer must hold the seed amount of every stock token, and USDG_SEED plus USDG_MARKET_SEED per stock
/// of USDG (1.9 USDG for nine stocks).
/// LOCK_DAYS: the wait on every risky vault setting. Required on Robinhood Chain (the site promises 3 days);
/// elsewhere it defaults to 0 (settings left unlocked).
/// Optional: FEE_BPS (default 1000 = 10% of interest), OPEN_FEE_BPS (default 10 = 0.10%), EMISSION_RATE (BORRO
/// wei per second, default and most the whole cap over 365 days), ONLY (one symbol, to open a single desk),
/// SALT, DESKS_OUT (where the addresses are written, default script/out/desks.json; must be in script/out).
contract Deploy is Script, StockList {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    uint256 constant ROBINHOOD_CHAIN = 4663;

    struct Roles {
        address deployer;
        address owner;
        address keeper;
        address treasury;
        address guardian;
        uint256 lockDays;
    }

    function run() external {
        Roles memory r = Roles({
            deployer: msg.sender,
            owner: vm.envAddress("OWNER"),
            keeper: vm.envAddress("KEEPER"),
            treasury: vm.envAddress("TREASURY"),
            guardian: vm.envAddress("GUARDIAN"),
            lockDays: vm.envOr("LOCK_DAYS", uint256(0))
        });
        _checkRoles(r);
        uint256 startBlock = BorroLib.rpcBlock(vm);
        // Every setup call is made by the deployer; `handOver` moves the vaults to OWNER at the end.
        BorroLib.Terms memory t = BorroLib.Terms({
            owner: r.deployer,
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            performanceFee: vm.envOr("FEE_BPS", uint256(1000)) * 1e14,
            salt: vm.envOr("SALT", bytes32("borro-1"))
        });
        BorroLib.Stock[] memory list = _pick(loadStocks(), vm.envOr("ONLY", string("")));
        _checkSeeds(list, r.deployer);

        vm.startBroadcast(r.deployer);
        BorroShort short = new BorroShort(
            IMorpho(BorroLib.MORPHO),
            IPoolManager(POOL_MANAGER),
            IUniswapV3Factory(V3_FACTORY),
            IERC20(BorroLib.USDG),
            IHeldVault(BorroLib.HELD),
            BorroLib.IRM,
            r.deployer
        );
        // The pots that refund rent and pay the weekly prize. The shorting contract is the only reporter.
        BorroRewards rewards = new BorroRewards(IERC20(BorroLib.USDG), address(short), r.owner);
        short.setRewards(IBorroRewards(address(rewards)));
        // OPEN_FEE_BPS: fee on the sale money when a short opens. Default 10 = 0.10%. Hard cap 30.
        short.setFee(vm.envOr("OPEN_FEE_BPS", uint256(10)), t.feeRecipient);
        vm.stopBroadcast();
        console2.log("rewards       ", address(rewards));
        console2.log("short contract", address(short));

        (BorroLib.Desk[] memory desks, BorroLib.Loan[] memory loans) = _desks(list, t, short);

        vm.startBroadcast(r.deployer);
        BorroLib.Lender memory lender = BorroLib.openLender(list, loans, t, r.keeper);
        // Lock every vault, then hand it to OWNER. The deployer keeps nothing.
        for (uint256 i; i <= desks.length; i++) {
            address v = i < desks.length ? desks[i].vault : lender.vault;
            if (r.lockDays != 0) BorroLib.lock(v, r.lockDays * 1 days);
            BorroLib.handOver(v, r.deployer, r.owner);
        }
        if (r.owner != r.deployer) short.transferOwnership(r.owner);
        // The router's list of Borro's USDG markets is also the liquidator's.
        MarketParams[] memory usdgMarkets = new MarketParams[](loans.length);
        for (uint256 i; i < loans.length; i++) usdgMarkets[i] = loans[i].market;
        BorroRouter router = new BorroRouter(IMorpho(BorroLib.MORPHO), BorroLib.USDG, r.owner, usdgMarkets);
        BorroLiquidator liquidator = new BorroLiquidator(
            IMorpho(BorroLib.MORPHO),
            IPoolManager(POOL_MANAGER),
            IERC20(BorroLib.USDG),
            IBorroDesks(address(short)),
            BorroLib.HELD,
            IBorroMarkets(address(router))
        );
        vm.stopBroadcast();
        console2.log("USDG vault    ", lender.vault);
        console2.log("router        ", address(router));
        console2.log("liquidator    ", address(liquidator));

        (BorroEmitter emitter, BorroDistributor dist) = _token(r);

        // `block`: the deploy starts at or after this block. Verify.s.sol reads role changes from there on.
        string memory out = string.concat(
            "{\"block\":", vm.toString(startBlock), ",\"short\":\"", vm.toString(address(short)), "\",\"rewards\":\"",
            vm.toString(address(rewards)), "\",\"usdgVault\":\"", vm.toString(lender.vault), "\",\"usdgAdapter\":\"",
            vm.toString(lender.adapter)
        );
        out = string.concat(
            out, "\",\"router\":\"", vm.toString(address(router)), "\",\"token\":\"", vm.toString(address(emitter.token())),
            "\",\"emitter\":\"", vm.toString(address(emitter)), "\",\"distributor\":\"", vm.toString(address(dist))
        );
        out = string.concat(out, "\",\"liquidator\":\"", vm.toString(address(liquidator)), "\",\"desks\":[");
        for (uint256 i; i < desks.length; i++) {
            out = string.concat(
                out, i == 0 ? "" : ",", "\n  {\"symbol\":\"", list[i].symbol, "\",\"vault\":\"", vm.toString(desks[i].vault),
                "\",\"adapter\":\"", vm.toString(desks[i].adapter)
            );
            out = string.concat(
                out, "\",\"oracle\":\"", vm.toString(desks[i].oracle), "\",\"marketId\":\"", vm.toString(desks[i].marketId)
            );
            out = string.concat(
                out, "\",\"usdgOracle\":\"", vm.toString(loans[i].oracle), "\",\"usdgMarketId\":\"", vm.toString(loans[i].marketId), "\"}"
            );
        }
        // tools/desks.py turns this file into site/desks.js.
        vm.writeFile(
            string.concat(vm.projectRoot(), "/", vm.envOr("DESKS_OUT", string("script/out/desks.json"))),
            string.concat(out, "\n]}\n")
        );
    }

    /// Refuses a deploy whose roles or waits are wrong, before anything is sent.
    function _checkRoles(Roles memory r) internal view {
        // On the real chain every risky vault setting must wait (the site promises 3 days).
        require(block.chainid != ROBINHOOD_CHAIN || r.lockDays != 0, "LOCK_DAYS is 0 on Robinhood Chain: set LOCK_DAYS=3");
        require(r.guardian != r.keeper, "GUARDIAN must not be KEEPER");
        // The vaults are handed over in one step (no accept), so OWNER must be a Safe someone can sign for.
        require(
            r.owner == r.deployer || BorroLib.looksLikeSafe(r.owner),
            "OWNER must be a Safe that is set up (getThreshold() >= 1 and getOwners()), or the deployer itself"
        );
    }

    /// Opens each stock's desk and its USDG market, and lists the desk on the shorting contract.
    function _desks(BorroLib.Stock[] memory list, BorroLib.Terms memory t, BorroShort short)
        internal
        returns (BorroLib.Desk[] memory desks, BorroLib.Loan[] memory loans)
    {
        desks = new BorroLib.Desk[](list.length);
        loans = new BorroLib.Loan[](list.length);
        for (uint256 i; i < list.length; i++) {
            uint256 at = _indexOf(list[i].symbol);
            vm.startBroadcast(t.owner);
            desks[i] = BorroLib.open(list[i], t);
            loans[i] = BorroLib.openUsdg(list[i], desks[i], t.salt);
            // A stock with neither a route nor a v3 pool can be lent and borrowed, not shorted in one step.
            if (loadRoute(at).length != 0 || loadV3Pool(at) != address(0)) short.list(desks[i].market, loadRoute(at), loadV3Pool(at));
            vm.stopBroadcast();

            console2.log(list[i].symbol);
            console2.log("  vault       ", desks[i].vault);
            console2.log("  adapter     ", desks[i].adapter);
            console2.log("  oracle      ", desks[i].oracle);
            console2.log("  market      ", vm.toString(desks[i].marketId));
            console2.log("  USDG oracle ", loans[i].oracle);
            console2.log("  USDG market ", vm.toString(loans[i].marketId));
        }
    }

    /// The distributor needs the token's address and the emitter, which makes the token, needs the
    /// distributor's. So the token's address is worked out first: the emitter is the deployer's next contract
    /// after the distributor, and the token is the emitter's first.
    function _token(Roles memory r) internal returns (BorroEmitter emitter, BorroDistributor dist) {
        uint256 rate = vm.envOr("EMISSION_RATE", 100_000e18 / uint256(365 days));
        uint256 start = vm.envUint("EMISSION_START");
        vm.startBroadcast(r.deployer);
        address emitterAt = vm.computeCreateAddress(r.deployer, vm.getNonce(r.deployer) + 1);
        address tokenAt = vm.computeCreateAddress(emitterAt, 1);
        // A reward root may promise no faster than the distributor's share of emissions (88%, checked below).
        dist = new BorroDistributor(IERC20(tokenAt), r.owner, r.keeper, r.guardian, (rate * 8_800) / 10_000);
        emitter = new BorroEmitter(r.owner, address(dist), r.treasury, start, rate);
        vm.stopBroadcast();
        require(address(emitter) == emitterAt && address(emitter.token()) == tokenAt, "token address");
        require(
            dist.maxIncreasePerSecond() == (rate * emitter.DISTRIBUTOR_BPS()) / emitter.BPS(), "distributor growth limit"
        );
        console2.log("BORRO token   ", tokenAt);
        console2.log("emitter       ", address(emitter));
        console2.log("distributor   ", address(dist));
    }

    /// Every stock, or only the one named by ONLY.
    function _pick(BorroLib.Stock[] memory all, string memory only) internal pure returns (BorroLib.Stock[] memory list) {
        if (bytes(only).length == 0) return all;
        list = new BorroLib.Stock[](1);
        for (uint256 i; i < all.length; i++) {
            if (keccak256(bytes(only)) == keccak256(bytes(all[i].symbol))) {
                list[0] = all[i];
                return list;
            }
        }
        revert(string.concat("no such stock: ", only));
    }

    /// Where a symbol sits in stocks.json, for its route.
    function _indexOf(string memory symbol) internal view returns (uint256) {
        BorroLib.Stock[] memory all = loadStocks();
        for (uint256 i; i < all.length; i++) {
            if (keccak256(bytes(symbol)) == keccak256(bytes(all[i].symbol))) return i;
        }
        revert(string.concat("no such stock: ", symbol));
    }

    function _checkSeeds(BorroLib.Stock[] memory list, address deployer) internal view {
        for (uint256 i; i < list.length; i++) {
            require(IERC20Min(list[i].token).balanceOf(deployer) >= list[i].seed, string.concat("deployer lacks seed: ", list[i].symbol));
        }
        uint256 usdg = BorroLib.USDG_SEED + list.length * BorroLib.USDG_MARKET_SEED;
        require(IERC20Min(BorroLib.USDG).balanceOf(deployer) >= usdg, "deployer lacks the USDG seed");
    }
}
