// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BorroToken} from "../src/BorroToken.sol";
import {BorroEmitter} from "../src/BorroEmitter.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";

/// The BORRO token, its emitter and its distributor. No fork needed: nothing here talks to another contract.
contract BorroTokenTest is Test {
    address owner = makeAddr("owner"); // a Safe in production
    address keeper = makeAddr("keeper"); // proposes roots
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address ann = makeAddr("ann");
    address bob = makeAddr("bob");
    address carl = makeAddr("carl");
    address dee = makeAddr("dee");
    address eve = makeAddr("eve");

    BorroEmitter emitter;
    BorroToken token;
    BorroDistributor dist;
    uint256 start;
    uint256 rate;

    function setUp() public {
        vm.warp(1_800_000_000);
        start = block.timestamp + 1 days;
        // The distributor needs the token's address and the emitter needs the distributor's, so the token's
        // address is worked out first: the emitter is the next contract made here, the token its first.
        address emitterAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address tokenAt = vm.computeCreateAddress(emitterAt, 1);
        uint256 r = 100_000e18 / uint256(365 days);
        dist = new BorroDistributor(IERC20(tokenAt), owner, keeper, guardian, (r * 8_800) / 10_000);
        emitter = new BorroEmitter(owner, address(dist), treasury, start, r);
        token = emitter.token();
        assertEq(address(token), tokenAt);
        rate = emitter.rate();
    }

    /// Moves time on. Reads the clock through the cheatcode, because a compiled test may reuse an earlier
    /// block.timestamp after a warp.
    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    // ------------------------------------------------------------------ token

    function test_token_is_borro_capped_and_minted_only_by_the_emitter() public {
        assertEq(token.name(), "Borro");
        assertEq(token.symbol(), "BORRO");
        assertEq(token.decimals(), 18);
        assertEq(token.cap(), 100_000e18);
        assertEq(token.totalSupply(), 0, "no premine");
        assertEq(token.minter(), address(emitter));
        assertEq(rate, emitter.DEFAULT_RATE(), "the whole cap over a year");
        vm.prank(owner);
        vm.expectRevert(BorroToken.OnlyMinter.selector);
        token.mint(owner, 1);
        vm.prank(eve);
        vm.expectRevert(BorroToken.OnlyMinter.selector);
        token.mint(eve, 1);
    }

    function test_permit_sets_an_allowance_by_signature() public {
        (address signer, uint256 key) = makeAddrAndKey("signer");
        vm.warp(start + 1 days);
        emitter.drip();
        vm.prank(treasury);
        token.transfer(signer, 1e18);

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                bob,
                1e18,
                token.nonces(signer),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
        token.permit(signer, bob, 1e18, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 1e18);
        vm.prank(bob);
        token.transferFrom(signer, bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    // ------------------------------------------------------------------ emitter

    function test_nothing_before_the_start_then_88_to_the_distributor_and_12_to_the_treasury() public {
        assertEq(emitter.due(), 0);
        assertEq(emitter.drip(), 0, "nothing before the start");
        vm.warp(start + 1_000);
        assertEq(emitter.due(), 1_000 * rate);
        vm.prank(eve); // anyone can drip
        uint256 made = emitter.drip();
        assertEq(made, 1_000 * rate);
        assertEq(token.balanceOf(address(dist)), (made * 8_800) / 10_000);
        assertEq(token.balanceOf(treasury), made - (made * 8_800) / 10_000);
        assertEq(emitter.drip(), 0, "nothing twice for the same second");
        _wait(10);
        assertEq(emitter.drip(), 10 * rate);
    }

    function test_the_emitter_starts_no_faster_than_the_default_rate() public {
        uint256 most = emitter.DEFAULT_RATE();
        vm.expectRevert(BorroEmitter.RateUp.selector);
        new BorroEmitter(owner, address(dist), treasury, start, most + 1);
        BorroEmitter slow = new BorroEmitter(owner, address(dist), treasury, start, most / 2);
        assertEq(slow.rate(), most / 2);
    }

    function test_a_start_in_the_past_owes_nothing_for_time_before_deployment() public {
        BorroEmitter late = new BorroEmitter(owner, address(dist), treasury, block.timestamp - 30 days, rate);
        assertEq(late.start(), block.timestamp);
        assertEq(late.due(), 0);
    }

    function test_emission_stops_at_the_cap_and_a_burn_makes_no_room() public {
        vm.warp(start + 400 days);
        emitter.drip();
        assertEq(token.totalSupply(), 100_000e18, "the whole cap, and not a wei more");
        assertEq(token.minted(), 100_000e18);
        _wait(30 days);
        assertEq(emitter.drip(), 0);

        vm.prank(treasury);
        token.burn(1_000e18);
        assertEq(token.totalSupply(), 99_000e18);
        _wait(30 days);
        assertEq(emitter.due(), 0, "burnt is gone for good");
        assertEq(emitter.drip(), 0);
    }

    function test_the_rate_can_only_be_lowered_by_the_owner() public {
        vm.prank(owner);
        vm.expectRevert(BorroEmitter.RateUp.selector);
        emitter.lowerRate(rate + 1);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        emitter.lowerRate(0);

        // What was due at the old rate is paid at the old rate.
        vm.warp(start + 100);
        vm.prank(owner);
        emitter.lowerRate(rate / 2);
        assertEq(token.totalSupply(), 100 * rate);
        _wait(100);
        assertEq(emitter.due(), 100 * (rate / 2));

        vm.prank(owner);
        emitter.lowerRate(0);
        _wait(365 days);
        assertEq(emitter.due(), 0, "zero stops emission for good");
        vm.prank(owner);
        vm.expectRevert(BorroEmitter.RateUp.selector);
        emitter.lowerRate(1);
    }

    function test_a_new_distributor_waits_two_days_in_public() public {
        address next = makeAddr("next");
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        emitter.queueDistributor(eve);

        vm.warp(start);
        vm.prank(owner);
        emitter.queueDistributor(next);
        assertEq(emitter.nextDistributorAt(), vm.getBlockTimestamp() + 2 days);
        _wait(2 days - 1);
        vm.expectRevert(BorroEmitter.NotReady.selector);
        emitter.applyDistributor();
        assertEq(emitter.distributor(), address(dist));

        _wait(1);
        vm.prank(eve); // anyone can apply it once the wait is over
        emitter.applyDistributor();
        assertEq(emitter.distributor(), next);
        assertEq(token.balanceOf(address(dist)), (2 days * rate * 8_800) / 10_000, "the old one got everything up to the switch");
        _wait(10);
        emitter.drip();
        assertEq(token.balanceOf(next), (10 * rate * 8_800) / 10_000);

        // A waiting change can be dropped.
        vm.startPrank(owner);
        emitter.queueDistributor(eve);
        emitter.cancelDistributor();
        vm.stopPrank();
        _wait(3 days);
        vm.expectRevert(BorroEmitter.NotReady.selector);
        emitter.applyDistributor();
    }

    // ------------------------------------------------------------------ distributor

    function _leaf(address account, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// A four-leaf tree, built here the way the keeper builds it. Returns the root and each leaf's proof.
    function _tree(address[4] memory who, uint256[4] memory amounts)
        internal
        pure
        returns (bytes32 root, bytes32[][] memory proofs)
    {
        bytes32[4] memory l;
        for (uint256 i; i < 4; i++) l[i] = _leaf(who[i], amounts[i]);
        bytes32 n01 = _pair(l[0], l[1]);
        bytes32 n23 = _pair(l[2], l[3]);
        root = _pair(n01, n23);
        proofs = new bytes32[][](4);
        for (uint256 i; i < 4; i++) {
            proofs[i] = new bytes32[](2);
            proofs[i][0] = l[i ^ 1];
            proofs[i][1] = i < 2 ? n23 : n01;
        }
    }

    function _fund() internal {
        vm.warp(start + 30 days);
        emitter.drip();
        assertGt(token.balanceOf(address(dist)), 1_000e18);
    }

    function test_claims_follow_the_tree_after_the_wait() public {
        _fund();
        address[4] memory who = [ann, bob, carl, dee];
        (bytes32 root, bytes32[][] memory proofs) = _tree(who, [uint256(100e18), 200e18, 300e18, 400e18]);

        vm.prank(eve);
        vm.expectRevert(BorroDistributor.OnlyUpdater.selector);
        dist.proposeRoot(root, 1_000e18);
        vm.prank(keeper);
        dist.proposeRoot(root, 1_000e18);
        assertEq(dist.root(), bytes32(0), "not yet");
        vm.expectRevert(BorroDistributor.BadProof.selector);
        dist.claim(ann, 100e18, proofs[0]);

        _wait(2 hours);
        assertEq(dist.root(), root);
        vm.prank(eve); // anyone can claim for anyone; the tokens go to the account
        assertEq(dist.claim(ann, 100e18, proofs[0]), 100e18);
        assertEq(token.balanceOf(ann), 100e18);
        assertEq(token.balanceOf(eve), 0);
        assertEq(dist.claimed(ann), 100e18);
        vm.expectRevert(BorroDistributor.NothingToClaim.selector);
        dist.claim(ann, 100e18, proofs[0]);
        vm.expectRevert(BorroDistributor.BadProof.selector);
        dist.claim(ann, 101e18, proofs[0]);
        vm.expectRevert(BorroDistributor.BadProof.selector);
        dist.claim(eve, 200e18, proofs[1]);
        dist.claim(dee, 400e18, proofs[3]);
        assertEq(token.balanceOf(dee), 400e18);

        // The next root, a day later, carries running totals: Ann has earned 150 in all, so she gets the 50 she
        // is owed.
        (bytes32 root2, bytes32[][] memory proofs2) = _tree(who, [uint256(150e18), 260e18, 300e18, 400e18]);
        _wait(1 days);
        vm.prank(keeper);
        dist.proposeRoot(root2, 1_110e18);
        _wait(2 hours);
        assertEq(dist.claim(ann, 150e18, proofs2[0]), 50e18);
        assertEq(token.balanceOf(ann), 150e18);
        assertEq(dist.claim(bob, 260e18, proofs2[1]), 260e18, "bob never claimed, so he gets the whole total");
        vm.expectRevert(BorroDistributor.NothingToClaim.selector);
        dist.claim(dee, 400e18, proofs2[3]);
    }

    function test_the_guardian_can_revoke_a_waiting_root_only() public {
        _fund();
        address[4] memory who = [ann, bob, carl, dee];
        (bytes32 good, bytes32[][] memory proofs) = _tree(who, [uint256(100e18), 200e18, 300e18, 400e18]);
        (bytes32 bad,) = _tree([eve, bob, carl, dee], [uint256(1_000e18), 200e18, 300e18, 400e18]);

        vm.prank(keeper);
        dist.proposeRoot(bad, 1_900e18);
        vm.prank(eve);
        vm.expectRevert(BorroDistributor.OnlyGuardian.selector);
        dist.revokeRoot();
        vm.prank(owner);
        vm.expectRevert(BorroDistributor.OnlyGuardian.selector);
        dist.revokeRoot();
        vm.prank(guardian);
        dist.revokeRoot();
        _wait(3 hours);
        assertEq(dist.root(), bytes32(0), "the bad root never took effect");

        vm.prank(keeper);
        dist.proposeRoot(good, 1_000e18);
        _wait(2 hours);
        vm.prank(guardian);
        vm.expectRevert(BorroDistributor.NothingPending.selector);
        dist.revokeRoot();
        dist.claim(carl, 300e18, proofs[2]);
        assertEq(token.balanceOf(carl), 300e18);

        // The owner names the updater and the guardian, and can do nothing else with the tokens.
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        dist.setUpdater(eve);
        vm.startPrank(owner);
        dist.setUpdater(eve);
        dist.setGuardian(dee);
        vm.stopPrank();
        assertEq(dist.updater(), eve);
        assertEq(dist.guardian(), dee);
    }

    // ------------------------------------------------------------------ distributor bounds

    function test_a_root_total_never_goes_down_and_never_passes_what_is_held() public {
        _fund();
        address[4] memory who = [ann, bob, carl, dee];
        (bytes32 root, bytes32[][] memory proofs) = _tree(who, [uint256(100e18), 200e18, 300e18, 400e18]);
        uint256 held = token.balanceOf(address(dist));
        vm.prank(owner);
        dist.setMaxIncreasePerSecond(type(uint128).max); // so only the rules under test can bite

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TotalNotHeld.selector, held + 1, held));
        dist.proposeRoot(root, held + 1);
        dist.proposeRoot(root, 1_000e18);
        vm.stopPrank();
        _wait(2 hours);
        assertEq(dist.total(), 1_000e18);
        dist.claim(ann, 100e18, proofs[0]);
        assertEq(dist.totalClaimed(), 100e18);

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TotalDown.selector, 999e18, 1_000e18));
        dist.proposeRoot(bytes32("next"), 999e18);
        // What has been claimed still counts: the balance plus the claims is the most a root can promise.
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TotalNotHeld.selector, held + 1, held));
        dist.proposeRoot(bytes32("next"), held + 1);
        dist.proposeRoot(bytes32("next"), held);
        vm.stopPrank();
        assertEq(dist.pendingTotal(), held);
    }

    function test_a_root_total_grows_no_faster_than_the_distributors_share_of_emissions() public {
        _fund();
        uint256 perSecond = dist.maxIncreasePerSecond();
        assertEq(perSecond, (emitter.rate() * 8_800) / 10_000, "by default the distributor's share of the rate");
        vm.prank(keeper);
        dist.proposeRoot(bytes32("a"), 1_000e18);
        uint256 proposedAt = vm.getBlockTimestamp();
        _wait(4 hours);

        // Four hours on: at most four hours of growth, plus the hour of margin.
        uint256 allowed = perSecond * (vm.getBlockTimestamp() - proposedAt + dist.MARGIN());
        assertEq(dist.totalAt(), proposedAt);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TotalTooFast.selector, allowed + 1, allowed));
        dist.proposeRoot(bytes32("b"), 1_000e18 + allowed + 1);
        dist.proposeRoot(bytes32("b"), 1_000e18 + allowed);
        vm.stopPrank();

        // Only the owner can change the limit.
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        dist.setMaxIncreasePerSecond(perSecond * 10);
        vm.prank(owner);
        dist.setMaxIncreasePerSecond(perSecond / 2);
        assertEq(dist.maxIncreasePerSecond(), perSecond / 2);
    }

    function test_proposals_are_thirty_minutes_apart_and_a_new_one_restarts_the_wait() public {
        _fund();
        vm.startPrank(keeper);
        dist.proposeRoot(bytes32("a"), 100e18);
        uint256 readyAt = vm.getBlockTimestamp() + 30 minutes;
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TooSoon.selector, readyAt));
        dist.proposeRoot(bytes32("b"), 100e18);
        _wait(30 minutes);
        dist.proposeRoot(bytes32("b"), 100e18);
        vm.stopPrank();
        assertEq(dist.pendingRoot(), bytes32("b"), "the waiting root is replaced");
        assertEq(dist.pendingAt(), vm.getBlockTimestamp() + 2 hours);
        assertEq(dist.lastProposal(), vm.getBlockTimestamp());
    }

    function test_the_guardian_pauses_claims_and_proposals_and_can_then_revoke_a_late_root() public {
        _fund();
        address[4] memory who = [ann, bob, carl, dee];
        (bytes32 root, bytes32[][] memory proofs) = _tree(who, [uint256(100e18), 200e18, 300e18, 400e18]);
        vm.prank(keeper);
        dist.proposeRoot(root, 1_000e18);
        _wait(2 hours);

        vm.prank(eve);
        vm.expectRevert(BorroDistributor.OnlyGuardian.selector);
        dist.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(BorroDistributor.OnlyGuardian.selector);
        dist.setPaused(true);
        vm.prank(guardian);
        dist.setPaused(true);
        vm.expectRevert(BorroDistributor.IsPaused.selector);
        dist.claim(ann, 100e18, proofs[0]);
        vm.prank(keeper);
        vm.expectRevert(BorroDistributor.IsPaused.selector);
        dist.proposeRoot(bytes32("next"), 1_000e18);
        vm.prank(guardian);
        dist.setPaused(false);
        assertEq(dist.claim(ann, 100e18, proofs[0]), 100e18);

        // A bad root nobody caught in time: paused, it can still be thrown out after its wait, because
        // nothing could be claimed against it.
        (bytes32 bad,) = _tree([eve, bob, carl, dee], [uint256(1_000e18), 200e18, 300e18, 400e18]);
        vm.prank(keeper);
        dist.proposeRoot(bad, 1_010e18);
        vm.prank(guardian);
        dist.setPaused(true);
        _wait(3 hours);
        vm.prank(guardian);
        dist.revokeRoot();
        vm.prank(owner); // the owner can lift a pause too
        dist.setPaused(false);
        assertEq(dist.root(), root, "the good root is still the one in force");
        assertEq(dist.total(), 1_000e18);
        assertEq(dist.claim(bob, 200e18, proofs[1]), 200e18);
    }

    function test_the_guardian_is_never_the_updater_and_only_the_owner_names_either() public {
        vm.expectRevert(BorroDistributor.GuardianIsUpdater.selector);
        new BorroDistributor(IERC20(address(token)), owner, keeper, keeper, 1);
        vm.startPrank(owner);
        vm.expectRevert(BorroDistributor.GuardianIsUpdater.selector);
        dist.setUpdater(guardian);
        vm.expectRevert(BorroDistributor.GuardianIsUpdater.selector);
        dist.setGuardian(keeper);
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        dist.setUpdater(carl);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        dist.setGuardian(carl);
    }

    function test_claims_never_pay_out_more_than_the_root_promises() public {
        _fund();
        address[4] memory who = [ann, bob, carl, dee];
        // Leaves that add up to 1,000 under a root that promises 600.
        (bytes32 root, bytes32[][] memory proofs) = _tree(who, [uint256(100e18), 200e18, 300e18, 400e18]);
        vm.prank(keeper);
        dist.proposeRoot(root, 600e18);
        _wait(2 hours);
        dist.claim(dee, 400e18, proofs[3]);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.OverTotal.selector, 300e18, 200e18));
        dist.claim(carl, 300e18, proofs[2]);
        dist.claim(bob, 200e18, proofs[1]);
        assertEq(dist.totalClaimed(), 600e18);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.OverTotal.selector, 100e18, 0));
        dist.claim(ann, 100e18, proofs[0]);
    }
}
