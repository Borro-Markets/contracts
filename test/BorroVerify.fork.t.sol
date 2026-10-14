// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {BorroLib} from "../script/BorroLib.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Verify} from "../script/Verify.s.sol";
import {BorroEmitter} from "../src/BorroEmitter.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";
import {BorroSetup} from "./BorroSetup.sol";

/// The deploy script's checks on its roles, run without deploying anything.
contract DeployChecks is Deploy {
    function check(Roles memory r) external view {
        _checkRoles(r);
    }
}

/// Runs against a fork of Robinhood Chain: BORRO_FORK_RPC=<rpc> forge test
/// The checks before a deploy (Deploy.s.sol) and after it (Verify.s.sol).
contract BorroVerifyForkTest is BorroSetup {
    // A real Safe on the chain (Safe 1.4.1, 3 of 7: the Steakhouse USDG vault's curator), standing in for ours.
    address constant SAFE = 0x9023FBD6A08C666491A2d1648737E400cF42D2Fb;
    // Safe 1.4.1's master copy: a contract with a threshold of one and no owners. Nobody can sign for it.
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;

    function setUp() public override {
        // Every role change from the very first one, for counting allocators and sentinels.
        vm.recordLogs();
        super.setUp();
    }

    // ------------------------------------------------------------------ before the deploy

    function test_deploy_refuses_no_wait_on_robinhood_chain_and_an_owner_that_is_not_a_safe() public onFork {
        DeployChecks d = new DeployChecks();
        assertEq(block.chainid, 4663);
        Deploy.Roles memory r =
            Deploy.Roles({deployer: owner, owner: SAFE, keeper: keeper, treasury: sink, guardian: eve, lockDays: 3});
        d.check(r);

        r.lockDays = 0;
        vm.expectRevert(bytes("LOCK_DAYS is 0 on Robinhood Chain: set LOCK_DAYS=3"));
        d.check(r);
        r.lockDays = 3;

        bytes memory notSafe = bytes("OWNER must be a Safe that is set up (getThreshold() >= 1 and getOwners()), or the deployer itself");
        address[3] memory wrong = [SAFE_SINGLETON, carl, address(short)]; // the master copy, a wallet, another contract
        for (uint256 i; i < wrong.length; i++) {
            r.owner = wrong[i];
            vm.expectRevert(notSafe);
            d.check(r);
        }
        r.owner = owner; // the deployer itself: a private test chain
        d.check(r);

        r.guardian = keeper;
        vm.expectRevert(bytes("GUARDIAN must not be KEEPER"));
        d.check(r);
        r.guardian = eve;

        // Elsewhere, a deploy may leave settings unlocked.
        vm.chainId(31337);
        r.lockDays = 0;
        d.check(r);
    }

    // ------------------------------------------------------------------ after the deploy

    /// Everything handed to the Safe the way Deploy.s.sol does it: every vault locked and handed over,
    /// BorroShort in two steps, the token engine made with the Safe as owner.
    function _deployed() internal returns (Verify.Expect memory e, Verify.Deployed memory a) {
        a.vaults = new address[](stocks.length);
        a.adapters = new address[](stocks.length);
        a.marketIds = new bytes32[](stocks.length);
        a.usdgMarketIds = new bytes32[](stocks.length);
        vm.startPrank(owner);
        for (uint256 i; i <= stocks.length; i++) {
            address v = i < stocks.length ? desk[stocks[i].symbol].vault : address(bUsdg);
            BorroLib.lock(v, 3 days);
            BorroLib.handOver(v, owner, SAFE);
        }
        short.transferOwnership(SAFE);
        rewards.transferOwnership(SAFE);
        router.transferOwnership(SAFE);
        vm.stopPrank();
        vm.startPrank(SAFE);
        rewards.acceptOwnership();
        router.acceptOwnership();
        vm.stopPrank();

        uint256 rate = 100_000e18 / uint256(365 days);
        address emitterAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address tokenAt = vm.computeCreateAddress(emitterAt, 1);
        BorroDistributor dist = new BorroDistributor(IERC20(tokenAt), SAFE, keeper, eve, (rate * 8_800) / 10_000);
        BorroEmitter emitter = new BorroEmitter(SAFE, address(dist), carl, block.timestamp, rate);

        for (uint256 i; i < stocks.length; i++) {
            a.vaults[i] = desk[stocks[i].symbol].vault;
            a.adapters[i] = desk[stocks[i].symbol].adapter;
            a.marketIds[i] = desk[stocks[i].symbol].marketId;
            a.usdgMarketIds[i] = loan[stocks[i].symbol].marketId;
        }
        a.short = address(short);
        a.rewards = address(rewards);
        a.usdgVault = address(bUsdg);
        a.usdgAdapter = lender.adapter;
        a.router = address(router);
        a.token = tokenAt;
        a.emitter = address(emitter);
        a.distributor = address(dist);
        a.liquidator = address(liquidator);
        e = Verify.Expect({
            owner: SAFE,
            deployer: owner,
            keeper: keeper,
            guardian: eve,
            treasury: carl,
            feeRecipient: sink,
            wait: 3 days,
            performanceFee: FEE
        });
    }

    function test_verify_waits_for_the_safe_to_accept_then_passes_and_names_what_is_wrong() public onFork {
        (Verify.Expect memory e, Verify.Deployed memory a) = _deployed();
        Verify verify = new Verify();

        vm.expectRevert(bytes("Verify: BorroShort: the Safe has not called acceptOwnership() yet"));
        verify.check(e, a);
        vm.prank(SAFE);
        short.acceptOwnership();
        verify.check(e, a);

        // Allocators and sentinels, counted from every role change since the first vault was made.
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        address[] memory safeOnly = new address[](1);
        safeOnly[0] = SAFE;
        address[] memory safeAndKeeper = new address[](2);
        safeAndKeeper[0] = keeper;
        safeAndKeeper[1] = SAFE;
        bytes32 allocators = keccak256("SetIsAllocator(address,bool)");
        bytes32 sentinels = keccak256("SetIsSentinel(address,bool)");
        verify.sameSet(verify.holders(logs, address(bUsdg), allocators), safeAndKeeper, "bUSDG allocators");
        verify.sameSet(verify.holders(logs, address(bUsdg), sentinels), safeOnly, "bUSDG sentinels");
        for (uint256 i; i < a.vaults.length; i++) {
            verify.sameSet(verify.holders(logs, a.vaults[i], allocators), safeOnly, "stock vault allocators");
            verify.sameSet(verify.holders(logs, a.vaults[i], sentinels), safeOnly, "stock vault sentinels");
        }

        // The Safe adds an allocator nobody expected: the count catches it.
        IVaultV2 v = IVaultV2(a.vaults[0]);
        bytes memory add = abi.encodeCall(IVaultV2.setIsAllocator, (carl, true));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IVaultV2.submit, (add));
        calls[1] = add;
        vm.prank(SAFE);
        v.multicall(calls);
        VmSafe.Log[] memory more = vm.getRecordedLogs();
        VmSafe.Log[] memory all = new VmSafe.Log[](logs.length + more.length);
        for (uint256 i; i < logs.length; i++) all[i] = logs[i];
        for (uint256 i; i < more.length; i++) all[logs.length + i] = more[i];
        address[] memory got = verify.holders(all, a.vaults[0], allocators);
        vm.expectRevert(bytes("Verify: SPY allocators: not exactly the expected accounts"));
        verify.sameSet(got, safeOnly, "SPY allocators");

        // Giving the deployer a role back is caught by the direct checks too.
        add = abi.encodeCall(IVaultV2.setIsAllocator, (owner, true));
        calls[0] = abi.encodeCall(IVaultV2.submit, (add));
        calls[1] = add;
        vm.prank(SAFE);
        v.multicall(calls);
        vm.expectRevert(bytes("Verify: bSPY: the deployer still has a role"));
        verify.check(e, a);
    }

    function test_verify_refuses_a_vault_whose_settings_do_not_wait() public onFork {
        (Verify.Expect memory e, Verify.Deployed memory a) = _deployed();
        vm.prank(SAFE);
        short.acceptOwnership();
        Verify verify = new Verify();
        verify.check(e, a);

        // A deploy run with a shorter wait than promised fails.
        e.wait = 7 days;
        vm.expectRevert(bytes("Verify: bSPY: a locked setting does not wait LOCK_DAYS"));
        verify.check(e, a);
        e.wait = 3 days;

        // A gate set after the wait is caught.
        bytes memory gate = abi.encodeCall(IVaultV2.setSendAssetsGate, (eve));
        vm.prank(SAFE);
        bUsdg.submit(gate);
        vm.warp(block.timestamp + 3 days);
        (bool ok,) = address(bUsdg).call(gate);
        assertTrue(ok);
        vm.expectRevert(bytes("Verify: bUSDG: a gate or adapter registry is set"));
        verify.check(e, a);

        // And an owner that is not a Safe is refused before anything else.
        e.owner = carl;
        vm.expectRevert(bytes("Verify: OWNER does not answer like a Safe that is set up (getThreshold, getOwners)"));
        verify.check(e, a);
    }
}
