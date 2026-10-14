// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StockDistributor} from "../src/StockDistributor.sol";

/// A stand-in stock token. Like the Robinhood stock tokens it can be paused and can refuse a blocked address.
contract Stock is ERC20 {
    bool public paused;
    mapping(address => bool) public blocked;

    constructor(string memory s) ERC20(s, s) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function block_(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "paused");
        require(!blocked[from] && !blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// Builds Merkle trees the way OpenZeppelin's MerkleProof checks them (pairs hashed sorted). The last node of an odd
/// layer moves up as it is.
library Tree {
    function leaf(address account, address token, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulative))));
    }

    function hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function up(bytes32[] memory layer) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((layer.length + 1) / 2);
        for (uint256 i; i < next.length; ++i) {
            next[i] = 2 * i + 1 < layer.length ? hashPair(layer[2 * i], layer[2 * i + 1]) : layer[2 * i];
        }
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty");
        bytes32[] memory layer = leaves;
        while (layer.length > 1) layer = up(layer);
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        bytes32[] memory tmp = new bytes32[](64);
        uint256 n;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 sib = index ^ 1;
            if (sib < layer.length) tmp[n++] = layer[sib];
            layer = up(layer);
            index /= 2;
        }
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) out[i] = tmp[i];
    }
}

contract StockDistributorBase is Test {
    Stock nvda;
    Stock tsla;
    Stock spy;
    StockDistributor dist;
    address safe = makeAddr("safe");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address roy = makeAddr("roy");
    address eve = makeAddr("eve");
    uint256 constant RATE = 1e30; // effectively no growth limit, unless a test sets one

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        nvda = new Stock("NVDA");
        tsla = new Stock("TSLA");
        spy = new Stock("SPY");
        address[] memory t = new address[](3);
        t[0] = address(nvda);
        t[1] = address(tsla);
        t[2] = address(spy);
        uint256[] memory r = new uint256[](3);
        r[0] = RATE;
        r[1] = RATE;
        r[2] = RATE;
        dist = new StockDistributor(safe, keeper, guardian, t, r);
        nvda.mint(address(dist), 100e18);
        tsla.mint(address(dist), 50e18);
        spy.mint(address(dist), 10e18);
    }

    function totals(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory t) {
        t = new uint256[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }

    // A small tree: alice and bob earn NVDA and TSLA, carol SPY.
    function leaves(uint256 aN, uint256 aT, uint256 bN, uint256 bT, uint256 cS) internal view returns (bytes32[] memory l) {
        l = new bytes32[](5);
        l[0] = Tree.leaf(alice, address(nvda), aN);
        l[1] = Tree.leaf(alice, address(tsla), aT);
        l[2] = Tree.leaf(bob, address(nvda), bN);
        l[3] = Tree.leaf(bob, address(tsla), bT);
        l[4] = Tree.leaf(carol, address(spy), cS);
    }

    function proposeLive(bytes32[] memory l, uint256[] memory t) internal {
        vm.prank(keeper);
        dist.proposeRoot(Tree.root(l), t);
        vm.warp(block.timestamp + dist.ROOT_DELAY());
    }
}

contract StockDistributorTest is StockDistributorBase {
    // ------------------------------------------------------------------ set up

    function test_constructor_lists_the_basket_and_roles() public view {
        address[] memory t = dist.tokens();
        assertEq(t.length, 3);
        assertEq(t[0], address(nvda));
        assertEq(dist.owner(), safe);
        assertEq(dist.updater(), keeper);
        assertEq(dist.guardian(), guardian);
        (bool listed, uint256 rate,,,) = dist.tokenState(address(spy));
        assertTrue(listed);
        assertEq(rate, RATE);
        assertEq(dist.root(), bytes32(0));
    }

    function test_constructor_refuses_bad_roles_and_lists() public {
        address[] memory t = new address[](2);
        t[0] = address(nvda);
        t[1] = address(nvda);
        uint256[] memory r = new uint256[](2);
        vm.expectRevert(StockDistributor.GuardianIsUpdater.selector);
        new StockDistributor(safe, keeper, keeper, t, r);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.AlreadyListed.selector, address(nvda)));
        new StockDistributor(safe, keeper, guardian, t, r);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.WrongLength.selector, 1, 2));
        new StockDistributor(safe, keeper, guardian, t, new uint256[](1));
        t[1] = address(0);
        vm.expectRevert(StockDistributor.ZeroAddress.selector);
        new StockDistributor(safe, keeper, guardian, t, r);
        vm.expectRevert(StockDistributor.ZeroAddress.selector);
        new StockDistributor(safe, address(0), guardian, new address[](0), new uint256[](0));
    }

    // ------------------------------------------------------------------ claims

    function test_claims_pay_each_account_its_own_tokens() public {
        bytes32[] memory l = leaves(10e18, 5e18, 20e18, 7e18, 3e18);
        proposeLive(l, totals(30e18, 12e18, 3e18));
        // Bob pushes alice's NVDA: it lands with alice, bob gets nothing.
        vm.prank(bob);
        uint256 paid = dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        assertEq(paid, 10e18);
        assertEq(nvda.balanceOf(alice), 10e18);
        assertEq(nvda.balanceOf(bob), 0);
        assertEq(dist.claimed(alice, address(nvda)), 10e18);
        assertEq(dist.totalClaimed(address(nvda)), 10e18);
        // The same leaf again: nothing to claim.
        vm.expectRevert(StockDistributor.NothingToClaim.selector);
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        // A leaf for alice cannot pay bob, nor another token.
        vm.expectRevert(StockDistributor.BadProof.selector);
        dist.claim(bob, address(nvda), 10e18, Tree.proof(l, 0));
        vm.expectRevert(StockDistributor.BadProof.selector);
        dist.claim(alice, address(tsla), 10e18, Tree.proof(l, 0));
        vm.expectRevert(StockDistributor.BadProof.selector);
        dist.claim(alice, address(nvda), 11e18, Tree.proof(l, 0));
    }

    function test_claimMany_pushes_a_batch_and_passes_over_what_is_paid() public {
        bytes32[] memory l = leaves(10e18, 5e18, 20e18, 7e18, 3e18);
        proposeLive(l, totals(30e18, 12e18, 3e18));
        vm.prank(alice);
        dist.claim(alice, address(tsla), 5e18, Tree.proof(l, 1)); // alice took her TSLA herself
        StockDistributor.Claim[] memory cs = new StockDistributor.Claim[](5);
        cs[0] = StockDistributor.Claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        cs[1] = StockDistributor.Claim(alice, address(tsla), 5e18, Tree.proof(l, 1));
        cs[2] = StockDistributor.Claim(bob, address(nvda), 20e18, Tree.proof(l, 2));
        cs[3] = StockDistributor.Claim(bob, address(tsla), 7e18, Tree.proof(l, 3));
        cs[4] = StockDistributor.Claim(carol, address(spy), 3e18, Tree.proof(l, 4));
        vm.prank(eve);
        uint256 paid = dist.claimMany(cs);
        assertEq(paid, 4);
        assertEq(nvda.balanceOf(alice), 10e18);
        assertEq(tsla.balanceOf(alice), 5e18);
        assertEq(nvda.balanceOf(bob), 20e18);
        assertEq(tsla.balanceOf(bob), 7e18);
        assertEq(spy.balanceOf(carol), 3e18);
        assertEq(nvda.balanceOf(eve) + tsla.balanceOf(eve) + spy.balanceOf(eve), 0);
    }

    function test_claimMany_undoes_the_batch_on_a_bad_proof_or_refused_transfer() public {
        bytes32[] memory l = leaves(10e18, 5e18, 20e18, 7e18, 3e18);
        proposeLive(l, totals(30e18, 12e18, 3e18));
        StockDistributor.Claim[] memory cs = new StockDistributor.Claim[](2);
        cs[0] = StockDistributor.Claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        cs[1] = StockDistributor.Claim(eve, address(nvda), 20e18, Tree.proof(l, 2));
        vm.expectRevert(StockDistributor.BadProof.selector);
        dist.claimMany(cs);
        assertEq(nvda.balanceOf(alice), 0);
        // The token refuses a blocked account: the batch is undone, the other leaves stay claimable.
        cs[1] = StockDistributor.Claim(bob, address(nvda), 20e18, Tree.proof(l, 2));
        nvda.block_(bob, true);
        vm.expectRevert(bytes("blocked"));
        dist.claimMany(cs);
        assertEq(dist.claimed(alice, address(nvda)), 0);
        nvda.block_(bob, false);
        dist.claimMany(cs);
        assertEq(nvda.balanceOf(bob), 20e18);
    }

    function test_cumulative_claims_pay_only_the_difference() public {
        bytes32[] memory l = leaves(10e18, 0, 0, 0, 0);
        proposeLive(l, totals(10e18, 0, 0));
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        vm.warp(block.timestamp + 1 days);
        l = leaves(25e18, 0, 0, 0, 0);
        proposeLive(l, totals(25e18, 0, 0));
        assertEq(dist.claim(alice, address(nvda), 25e18, Tree.proof(l, 0)), 15e18);
        assertEq(nvda.balanceOf(alice), 25e18);
    }

    function test_claims_never_pay_more_than_the_total_in_force() public {
        // A root whose leaves add up to more than its total: the last claims fail instead of overpaying.
        bytes32[] memory l = leaves(10e18, 0, 20e18, 0, 0);
        proposeLive(l, totals(25e18, 0, 0));
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.OverTotal.selector, address(nvda), 20e18, 15e18));
        dist.claim(bob, address(nvda), 20e18, Tree.proof(l, 2));
    }

    function test_a_waiting_root_pays_nothing_until_its_wait_is_over() public {
        bytes32[] memory l = leaves(10e18, 0, 0, 0, 0);
        vm.prank(keeper);
        dist.proposeRoot(Tree.root(l), totals(10e18, 0, 0));
        vm.expectRevert(StockDistributor.BadProof.selector);
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        vm.warp(block.timestamp + dist.ROOT_DELAY() - 1);
        vm.expectRevert(StockDistributor.BadProof.selector);
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        vm.warp(block.timestamp + 1);
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    // ------------------------------------------------------------------ proposals

    function test_proposals_are_bounded_per_token() public {
        vm.expectRevert(StockDistributor.OnlyUpdater.selector);
        dist.proposeRoot(bytes32(uint256(1)), totals(0, 0, 0));
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.WrongLength.selector, 2, 3));
        dist.proposeRoot(bytes32(uint256(1)), new uint256[](2));
        // Never more than held plus claimed, for each token.
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.TotalNotHeld.selector, address(tsla), 51e18, 50e18));
        dist.proposeRoot(bytes32(uint256(1)), totals(100e18, 51e18, 0));
        dist.proposeRoot(bytes32(uint256(1)), totals(100e18, 50e18, 10e18));
        // Not again within MIN_GAP.
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.TooSoon.selector, block.timestamp + 30 minutes));
        dist.proposeRoot(bytes32(uint256(2)), totals(100e18, 50e18, 10e18));
        vm.warp(block.timestamp + 3 hours);
        // Never down, once in force.
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.TotalDown.selector, address(spy), 9e18, 10e18));
        dist.proposeRoot(bytes32(uint256(2)), totals(100e18, 50e18, 9e18));
        vm.stopPrank();
    }

    function test_growth_limit_per_token() public {
        vm.prank(safe);
        dist.setMaxIncreasePerSecond(address(nvda), 1e15); // 3.6 NVDA an hour
        // MARGIN gives an hour of growth at once.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.TotalTooFast.selector, address(nvda), 3.6e18 + 1, 3.6e18));
        dist.proposeRoot(bytes32(uint256(1)), totals(3.6e18 + 1, 50e18, 0));
        vm.prank(keeper);
        dist.proposeRoot(bytes32(uint256(1)), totals(3.6e18, 50e18, 0));
        // Measured from when the root in force was proposed: after it takes over, 10 hours later, 11 hours' worth.
        vm.warp(block.timestamp + 10 hours);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.TotalTooFast.selector, address(nvda), 39.6e18 + 1, 39.6e18));
        dist.proposeRoot(bytes32(uint256(2)), totals(3.6e18 + 39.6e18 + 1, 50e18, 0));
        vm.prank(keeper);
        dist.proposeRoot(bytes32(uint256(2)), totals(3.6e18 + 39.6e18, 50e18, 0));
    }

    function test_a_new_proposal_replaces_a_waiting_one() public {
        vm.prank(keeper);
        dist.proposeRoot(bytes32(uint256(1)), totals(50e18, 0, 0));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        dist.proposeRoot(bytes32(uint256(2)), totals(40e18, 0, 0)); // measured against the root in force, not the waiting one
        assertEq(dist.pendingRoot(), bytes32(uint256(2)));
        assertEq(dist.pendingTotal(address(nvda)), 40e18);
        assertEq(dist.pendingAt(), block.timestamp + 2 hours);
    }

    // ------------------------------------------------------------------ guardian and pause

    function test_guardian_revokes_a_waiting_root() public {
        vm.prank(keeper);
        dist.proposeRoot(bytes32(uint256(1)), totals(50e18, 0, 0));
        vm.expectRevert(StockDistributor.OnlyGuardian.selector);
        vm.prank(keeper);
        dist.revokeRoot();
        vm.prank(guardian);
        dist.revokeRoot();
        assertEq(dist.pendingAt(), 0);
        assertEq(dist.pendingTotal(address(nvda)), 0);
        assertEq(dist.reclaimable(address(nvda)), 100e18);
        vm.warp(block.timestamp + 3 hours);
        assertEq(dist.root(), bytes32(0));
    }

    function test_a_root_whose_wait_is_over_can_be_revoked_only_while_paused() public {
        bytes32[] memory l = leaves(10e18, 0, 0, 0, 0);
        proposeLive(l, totals(10e18, 0, 0));
        vm.prank(guardian);
        vm.expectRevert(StockDistributor.NothingPending.selector);
        dist.revokeRoot();
        vm.prank(guardian);
        dist.setPaused(true);
        vm.expectRevert(StockDistributor.IsPaused.selector);
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        vm.prank(keeper);
        vm.expectRevert(StockDistributor.IsPaused.selector);
        dist.proposeRoot(bytes32(uint256(9)), totals(10e18, 0, 0));
        vm.prank(guardian);
        dist.revokeRoot();
        vm.prank(safe);
        dist.setPaused(false);
        vm.expectRevert(StockDistributor.BadProof.selector);
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        assertEq(dist.reclaimable(address(nvda)), 100e18);
    }

    function test_only_guardian_or_owner_pause() public {
        vm.prank(keeper);
        vm.expectRevert(StockDistributor.OnlyGuardian.selector);
        dist.setPaused(true);
        vm.prank(safe);
        dist.setPaused(true);
        assertTrue(dist.paused());
    }

    // ------------------------------------------------------------------ the owner's reclaim

    function test_reclaim_takes_only_what_no_root_promises() public {
        assertEq(dist.reclaimable(address(nvda)), 100e18);
        bytes32[] memory l = leaves(10e18, 5e18, 20e18, 7e18, 3e18);
        vm.prank(keeper);
        dist.proposeRoot(Tree.root(l), totals(30e18, 12e18, 3e18));
        // The waiting root's totals are already owed.
        assertEq(dist.reclaimable(address(nvda)), 70e18);
        assertEq(dist.reclaimable(address(tsla)), 38e18);
        assertEq(dist.reclaimable(address(spy)), 7e18);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.OverReclaimable.selector, address(nvda), 70e18 + 1, 70e18));
        dist.reclaim(address(nvda), roy, 70e18 + 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        dist.reclaim(address(nvda), keeper, 1);
        vm.startPrank(safe);
        dist.reclaim(address(nvda), roy, 70e18);
        dist.reclaim(address(tsla), roy, 38e18);
        dist.reclaim(address(spy), roy, 7e18);
        vm.stopPrank();
        // Every account is still paid in full.
        vm.warp(block.timestamp + 2 hours);
        StockDistributor.Claim[] memory cs = new StockDistributor.Claim[](5);
        cs[0] = StockDistributor.Claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        cs[1] = StockDistributor.Claim(alice, address(tsla), 5e18, Tree.proof(l, 1));
        cs[2] = StockDistributor.Claim(bob, address(nvda), 20e18, Tree.proof(l, 2));
        cs[3] = StockDistributor.Claim(bob, address(tsla), 7e18, Tree.proof(l, 3));
        cs[4] = StockDistributor.Claim(carol, address(spy), 3e18, Tree.proof(l, 4));
        dist.claimMany(cs);
        assertEq(nvda.balanceOf(address(dist)), 0);
        assertEq(tsla.balanceOf(address(dist)), 0);
        assertEq(spy.balanceOf(address(dist)), 0);
        // And nothing more could be proposed: it is no longer held.
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.TotalNotHeld.selector, address(nvda), 30e18 + 1, 30e18));
        dist.proposeRoot(bytes32(uint256(5)), totals(30e18 + 1, 12e18, 3e18));
    }

    function test_reclaim_after_claims_and_of_an_unlisted_token() public {
        bytes32[] memory l = leaves(10e18, 0, 0, 0, 0);
        proposeLive(l, totals(10e18, 0, 0));
        dist.claim(alice, address(nvda), 10e18, Tree.proof(l, 0));
        assertEq(dist.reclaimable(address(nvda)), 90e18);
        Stock usdg = new Stock("USDG");
        usdg.mint(address(dist), 5e6);
        assertEq(dist.reclaimable(address(usdg)), 5e6);
        vm.startPrank(safe);
        dist.reclaim(address(usdg), roy, 5e6);
        dist.reclaim(address(nvda), roy, 90e18);
        vm.stopPrank();
        assertEq(usdg.balanceOf(roy), 5e6);
        assertEq(nvda.balanceOf(roy), 90e18);
    }

    function test_owner_lists_more_tokens_and_sets_roles() public {
        Stock pltr = new Stock("PLTR");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        dist.listToken(address(pltr), 1);
        vm.startPrank(safe);
        dist.listToken(address(pltr), 1e30);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.AlreadyListed.selector, address(pltr)));
        dist.listToken(address(pltr), 1);
        vm.expectRevert(StockDistributor.GuardianIsUpdater.selector);
        dist.setUpdater(guardian);
        vm.expectRevert(StockDistributor.GuardianIsUpdater.selector);
        dist.setGuardian(keeper);
        dist.setUpdater(bob);
        dist.setGuardian(carol);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.NotListed.selector, address(0xBEEF)));
        dist.setMaxIncreasePerSecond(address(0xBEEF), 1);
        vm.stopPrank();
        assertEq(dist.tokenCount(), 4);
        // Proposals now carry four totals.
        pltr.mint(address(dist), 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StockDistributor.WrongLength.selector, 3, 4));
        dist.proposeRoot(bytes32(uint256(1)), totals(1, 1, 1));
        uint256[] memory t = new uint256[](4);
        t[3] = 1e18;
        vm.prank(bob);
        dist.proposeRoot(bytes32(uint256(1)), t);
    }

    function test_ownership_moves_in_two_steps() public {
        vm.prank(safe);
        dist.transferOwnership(roy);
        assertEq(dist.owner(), safe);
        vm.prank(roy);
        dist.acceptOwnership();
        assertEq(dist.owner(), roy);
    }

    function test_too_many_tokens() public {
        vm.startPrank(safe);
        for (uint256 i = 3; i < 16; ++i) dist.listToken(address(uint160(0x1000 + i)), 1);
        vm.expectRevert(StockDistributor.TooManyTokens.selector);
        dist.listToken(address(0x2000), 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ fuzz

    /// Any proposal either reverts or keeps every bound, per token.
    function testFuzz_proposal_bounds(uint256 a, uint256 b, uint256 c, uint32 wait, uint256 rate) public {
        rate = bound(rate, 0, 1e18);
        vm.startPrank(safe);
        dist.setMaxIncreasePerSecond(address(nvda), rate);
        dist.setMaxIncreasePerSecond(address(tsla), rate);
        dist.setMaxIncreasePerSecond(address(spy), rate);
        vm.stopPrank();
        vm.warp(block.timestamp + wait);
        a = bound(a, 0, 200e18);
        b = bound(b, 0, 200e18);
        c = bound(c, 0, 200e18);
        uint256 allowed = rate * (uint256(wait) + 1 hours);
        bool ok = a <= 100e18 && b <= 50e18 && c <= 10e18 && a <= allowed && b <= allowed && c <= allowed;
        vm.prank(keeper);
        if (!ok) vm.expectRevert();
        dist.proposeRoot(bytes32(uint256(7)), totals(a, b, c));
        if (ok) {
            assertEq(dist.pendingTotal(address(nvda)), a);
            assertEq(dist.reclaimable(address(nvda)), 100e18 - a);
            assertEq(dist.reclaimable(address(tsla)), 50e18 - b);
            assertEq(dist.reclaimable(address(spy)), 10e18 - c);
        }
    }

    /// Whoever sends a claim, the account in the leaf gets exactly what it is owed, and the sender gets nothing.
    function testFuzz_claim_for_anyone_lands_with_the_account(address sender, uint256 owedA, uint256 owedB, uint256 first) public {
        vm.assume(sender != alice && sender != bob && sender != address(dist));
        owedA = bound(owedA, 1, 60e18);
        owedB = bound(owedB, 1, 40e18);
        first = bound(first, 0, owedA - 1);
        // A first root pays alice part of it, then a later one the rest.
        if (first > 0) {
            bytes32[] memory l1 = leaves(first, 0, 0, 0, 0);
            proposeLive(l1, totals(first, 0, 0));
            vm.prank(sender);
            dist.claim(alice, address(nvda), first, Tree.proof(l1, 0));
            vm.warp(block.timestamp + 1 hours);
        }
        bytes32[] memory l = leaves(owedA, 0, owedB, 0, 0);
        proposeLive(l, totals(owedA + owedB, 0, 0));
        uint256 senderBefore = nvda.balanceOf(sender);
        vm.prank(sender);
        uint256 got = dist.claim(alice, address(nvda), owedA, Tree.proof(l, 0));
        assertEq(got, owedA - first);
        assertEq(nvda.balanceOf(alice), owedA);
        vm.prank(sender);
        dist.claim(bob, address(nvda), owedB, Tree.proof(l, 2));
        assertEq(nvda.balanceOf(bob), owedB);
        assertEq(nvda.balanceOf(sender), senderBefore);
        assertEq(nvda.balanceOf(address(dist)), 100e18 - owedA - owedB);
    }

    /// The owner can never take what is owed, however much it asks for.
    function testFuzz_reclaim_never_touches_what_is_owed(uint256 promised, uint256 claimNow, uint256 ask, bool waiting) public {
        promised = bound(promised, 1, 100e18);
        claimNow = bound(claimNow, 0, 1);
        bytes32[] memory l = leaves(promised, 0, 0, 0, 0);
        vm.prank(keeper);
        dist.proposeRoot(Tree.root(l), totals(promised, 0, 0));
        if (!waiting) {
            vm.warp(block.timestamp + 2 hours);
            if (claimNow == 1) dist.claim(alice, address(nvda), promised, Tree.proof(l, 0));
        }
        uint256 owed = promised - dist.claimed(alice, address(nvda));
        uint256 free = nvda.balanceOf(address(dist)) - owed;
        assertEq(dist.reclaimable(address(nvda)), free);
        ask = bound(ask, 0, 200e18);
        vm.prank(safe);
        if (ask > free) vm.expectRevert();
        dist.reclaim(address(nvda), roy, ask);
        assertGe(nvda.balanceOf(address(dist)), owed);
        // Alice can still take all of it.
        if (owed > 0) {
            vm.warp(block.timestamp + 2 hours);
            dist.claim(alice, address(nvda), promised, Tree.proof(l, 0));
            assertEq(nvda.balanceOf(alice), promised);
        }
    }

    // ------------------------------------------------------------------ gas, for the report

    function test_gas_push_batches() public {
        // 40 accounts x 3 tokens, the shape of a real push.
        uint256 n = 40;
        bytes32[] memory l = new bytes32[](n * 3);
        address[3] memory tok = [address(nvda), address(tsla), address(spy)];
        for (uint256 i; i < n; ++i) {
            for (uint256 k; k < 3; ++k) l[i * 3 + k] = Tree.leaf(address(uint160(0x10000 + i)), tok[k], 1e16 + i);
        }
        uint256 sum = n * 1e16 + (n * (n - 1)) / 2;
        bytes32 r = Tree.root(l);
        uint256[] memory t = totals(sum, sum, sum);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        dist.proposeRoot(r, t);
        emit log_named_uint("gas proposeRoot (3 tokens)", g0 - gasleft());
        vm.warp(block.timestamp + 2 hours);
        StockDistributor.Claim[] memory cs = new StockDistributor.Claim[](n * 3);
        for (uint256 i; i < n * 3; ++i) {
            cs[i] = StockDistributor.Claim(address(uint160(0x10000 + i / 3)), tok[i % 3], 1e16 + i / 3, Tree.proof(l, i));
        }
        g0 = gasleft();
        dist.claimMany(cs);
        uint256 used = g0 - gasleft();
        emit log_named_uint("gas claimMany, 120 leaves", used);
        emit log_named_uint("gas per leaf", used / (n * 3));
    }
}

/// Drives the distributor with random proposals (an honest keeper's and a stolen key's), time, claims from anyone,
/// pauses, revokes, reclaims and stray deposits. Ghost state tracks which accounts were ever in a root that took
/// effect.
contract StockHandler is Test {
    StockDistributor dist;
    Stock[] stocks;
    address safe;
    address keeper;
    address guardian;
    address roy;
    address[] public accounts; // may appear in trees
    address[] public outsiders; // send claims, never in a tree
    mapping(bytes32 root => bytes32[] leaves) treeLeaves;
    mapping(bytes32 root => mapping(uint256 => address)) leafAccount;
    mapping(bytes32 root => mapping(uint256 => address)) leafToken;
    mapping(bytes32 root => mapping(uint256 => uint256)) leafCum;
    mapping(address => mapping(address => uint256)) public cum; // the honest running totals
    mapping(address => bool) public everLive; // paid by a claim against the root in force at that moment
    mapping(address => mapping(address => uint256)) public maxLiveCum; // highest cumulative so paid
    bytes32[] rootsSeen; // every tree built, proposed or not, revoked or replaced or live
    mapping(bytes32 root => mapping(bytes32 leaf => bool)) inTree;
    mapping(address => uint256) public lastTotal;
    bytes32 lastPending;
    uint256 nonce;
    uint256 public claims;
    uint256 public reclaims;
    uint256 public proposals;

    constructor(StockDistributor d, Stock[] memory s, address safe_, address keeper_, address guardian_, address roy_) {
        dist = d;
        stocks = s;
        safe = safe_;
        keeper = keeper_;
        guardian = guardian_;
        roy = roy_;
        for (uint256 i; i < 4; ++i) accounts.push(makeAddr(string.concat("acct", vm.toString(i))));
        for (uint256 i; i < 3; ++i) outsiders.push(makeAddr(string.concat("outsider", vm.toString(i))));
    }

    function stockCount() external view returns (uint256) {
        return stocks.length;
    }

    function stock(uint256 i) external view returns (Stock) {
        return stocks[i];
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    function outsiderCount() external view returns (uint256) {
        return outsiders.length;
    }

    /// A claim of (a, t, c) just paid: the leaf must be in the root in force, and the account is marked as paid.
    function _paid(address a, address t, uint256 c) internal {
        assertTrue(inTree[dist.root()][Tree.leaf(a, t, c)], "only a leaf of the root in force pays");
        everLive[a] = true;
        if (c > maxLiveCum[a][t]) maxLiveCum[a][t] = c;
    }

    /// The keeper shares out part of what no root promises yet, within the growth limit.
    function proposeHonest(uint256 seed, uint256 pct) external {
        pct = bound(pct, 1, 100);
        if (dist.paused() || block.timestamp < dist.lastProposal() + dist.MIN_GAP()) return;
        uint256 n = stocks.length;
        uint256[] memory totals = new uint256[](n);
        uint256 since = block.timestamp - dist.totalAt() + dist.MARGIN();
        for (uint256 k; k < n; ++k) {
            address t = address(stocks[k]);
            uint256 inForce = dist.total(t);
            uint256 held = stocks[k].balanceOf(address(dist)) + dist.totalClaimed(t);
            uint256 limit = inForce + dist.maxIncreasePerSecond(t) * since; // the most the new total may be
            uint256 maxTotal = held < limit ? held : limit;
            // The running totals may be ahead of the root in force (a waiting root was replaced) or behind it (a
            // stolen key's root took effect); the new total is never under either.
            uint256 sumCum;
            for (uint256 i; i < accounts.length; ++i) sumCum += cum[accounts[i]][t];
            uint256 base = sumCum < inForce ? inForce : sumCum;
            uint256 add = maxTotal > base ? ((maxTotal - base) * pct) / 100 : 0;
            uint256 given;
            for (uint256 i; i < accounts.length; ++i) {
                uint256 share = i == accounts.length - 1 ? add - given : (add * (uint256(keccak256(abi.encode(seed, i, k))) % 40)) / 100;
                if (given + share > add) share = add - given;
                cum[accounts[i]][t] += share;
                given += share;
            }
            totals[k] = base + given;
        }
        _propose(accounts, totals);
    }

    /// A stolen updater key: any leaves (outsiders included) and any totals. Only bounded roots get through.
    function proposeAttack(uint256 seed, uint256 t0, uint256 t1, uint256 t2) external {
        uint256[] memory totals = new uint256[](stocks.length);
        totals[0] = bound(t0, 0, 1_000e18);
        if (totals.length > 1) totals[1] = bound(t1, 0, 1_000e18);
        if (totals.length > 2) totals[2] = bound(t2, 0, 1_000e18);
        address[] memory who = new address[](2);
        who[0] = outsiders[seed % outsiders.length];
        who[1] = accounts[seed % accounts.length];
        // Leaves for the attacker as big as the totals.
        bytes32 r = _build(who, totals, true, seed);
        vm.prank(keeper);
        try dist.proposeRoot(r, totals) {
            proposals++;
            lastPending = r;
        } catch {}
    }

    function _propose(address[] memory who, uint256[] memory totals) internal {
        bytes32 r = _build(who, totals, false, 0);
        vm.prank(keeper);
        try dist.proposeRoot(r, totals) {
            proposals++;
            lastPending = r;
        } catch {}
    }

    function _build(address[] memory who, uint256[] memory totals, bool attack, uint256 seed) internal returns (bytes32 r) {
        uint256 n = stocks.length;
        bytes32[] memory l = new bytes32[](who.length * n);
        address[] memory la = new address[](l.length);
        address[] memory lt = new address[](l.length);
        uint256[] memory lc = new uint256[](l.length);
        for (uint256 i; i < who.length; ++i) {
            for (uint256 k; k < n; ++k) {
                uint256 j = i * n + k;
                la[j] = who[i];
                lt[j] = address(stocks[k]);
                lc[j] = attack ? (i == 0 ? totals[k] : uint256(keccak256(abi.encode(seed, j))) % (totals[k] + 1)) : cum[who[i]][lt[j]];
                l[j] = Tree.leaf(la[j], lt[j], lc[j]);
            }
        }
        // A nonce leaf so two trees never share a root by accident.
        bytes32[] memory l2 = new bytes32[](l.length + 1);
        for (uint256 j; j < l.length; ++j) l2[j] = l[j];
        l2[l.length] = keccak256(abi.encode("nonce", nonce++));
        r = Tree.root(l2);
        rootsSeen.push(r);
        for (uint256 j; j < l2.length; ++j) inTree[r][l2[j]] = true;
        delete treeLeaves[r];
        for (uint256 j; j < l2.length; ++j) {
            treeLeaves[r].push(l2[j]);
            if (j < l.length) {
                leafAccount[r][j] = la[j];
                leafToken[r][j] = lt[j];
                leafCum[r][j] = lc[j];
            }
        }
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 3 hours);
        vm.warp(block.timestamp + secs);
    }

    /// Anyone claims a random leaf of the root in force for its account.
    function claimOne(uint256 who, uint256 which) external {
        bytes32 r = dist.root();
        uint256 len = treeLeaves[r].length;
        if (len < 2) return;
        uint256 i = which % (len - 1);
        address sender = who % 2 == 0 ? outsiders[who % outsiders.length] : accounts[who % accounts.length];
        address account = leafAccount[r][i];
        Stock t = Stock(leafToken[r][i]);
        uint256 beforeA = t.balanceOf(account);
        uint256 beforeS = t.balanceOf(sender);
        vm.prank(sender);
        try dist.claim(account, address(t), leafCum[r][i], Tree.proof(treeLeaves[r], i)) returns (uint256 paid) {
            claims++;
            assertEq(t.balanceOf(account), beforeA + paid, "a claim lands with the account");
            if (sender != account) assertEq(t.balanceOf(sender), beforeS, "the sender gets nothing");
            _paid(account, address(t), leafCum[r][i]);
        } catch {}
    }

    /// Anyone tries a leaf of any tree ever built: a waiting root, a revoked or replaced one, one never proposed. It
    /// can only pay if the very same leaf is in the root in force.
    function claimOld(uint256 who, uint256 pick, uint256 which) external {
        if (rootsSeen.length == 0) return;
        bytes32 r = rootsSeen[pick % rootsSeen.length];
        uint256 len = treeLeaves[r].length;
        if (len < 2) return;
        uint256 i = which % (len - 1);
        address account = leafAccount[r][i];
        Stock t = Stock(leafToken[r][i]);
        uint256 before = t.balanceOf(account);
        vm.prank(outsiders[who % outsiders.length]);
        try dist.claim(account, address(t), leafCum[r][i], Tree.proof(treeLeaves[r], i)) returns (uint256 paid) {
            claims++;
            assertEq(t.balanceOf(account), before + paid);
            _paid(account, address(t), leafCum[r][i]);
        } catch {}
    }

    /// Anyone pushes the whole root in force in one batch.
    function claimAll(uint256 who) external {
        bytes32 r = dist.root();
        uint256 len = treeLeaves[r].length;
        if (len < 2) return;
        StockDistributor.Claim[] memory cs = new StockDistributor.Claim[](len - 1);
        for (uint256 i; i + 1 < len; ++i) {
            cs[i] = StockDistributor.Claim(leafAccount[r][i], leafToken[r][i], leafCum[r][i], Tree.proof(treeLeaves[r], i));
        }
        address sender = outsiders[who % outsiders.length];
        vm.prank(sender);
        try dist.claimMany(cs) returns (uint256 paid) {
            claims += paid;
            for (uint256 i; i < cs.length; ++i) _paid(cs[i].account, cs[i].token, cs[i].cumulative);
        } catch {}
    }

    function reclaim(uint256 k, uint256 amount, bool tooMuch) external {
        Stock t = stocks[k % stocks.length];
        uint256 free = dist.reclaimable(address(t));
        amount = tooMuch ? free + bound(amount, 1, 1e18) : bound(amount, 0, free);
        vm.prank(safe);
        try dist.reclaim(address(t), roy, amount) {
            reclaims++;
            assertLe(amount, free, "never more than reclaimable");
        } catch {
            assertGt(amount, free, "a reclaim within reclaimable always goes through");
        }
    }

    function deposit(uint256 k, uint256 amount) external {
        stocks[k % stocks.length].mint(address(dist), bound(amount, 0, 50e18));
    }

    function revoke() external {
        vm.prank(guardian);
        try dist.revokeRoot() {} catch {}
    }

    function pause(bool on) external {
        vm.prank(guardian);
        dist.setPaused(on);
    }
}

contract StockDistributorInvariantTest is StdInvariant, StockDistributorBase {
    StockHandler handler;

    function setUp() public override {
        super.setUp();
        vm.startPrank(safe);
        dist.setMaxIncreasePerSecond(address(nvda), 1e15);
        dist.setMaxIncreasePerSecond(address(tsla), 5e14);
        vm.stopPrank();
        Stock[] memory s = new Stock[](3);
        s[0] = nvda;
        s[1] = tsla;
        s[2] = spy;
        handler = new StockHandler(dist, s, safe, keeper, guardian, roy);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = StockHandler.proposeHonest.selector;
        sel[1] = StockHandler.proposeAttack.selector;
        sel[2] = StockHandler.warp.selector;
        sel[3] = StockHandler.claimOne.selector;
        sel[4] = StockHandler.claimAll.selector;
        sel[5] = StockHandler.reclaim.selector;
        sel[6] = StockHandler.deposit.selector;
        sel[7] = StockHandler.revoke.selector;
        sel[8] = StockHandler.pause.selector;
        sel[9] = StockHandler.claimOld.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// No one but accounts in a root that took effect (and the owner's reclaim address) ever holds a stock, and no
    /// account holds more of a token than the highest cumulative amount a live root gave it.
    function invariant_only_live_accounts_receive() public view {
        for (uint256 k; k < handler.stockCount(); ++k) {
            Stock t = handler.stock(k);
            for (uint256 i; i < handler.outsiderCount(); ++i) {
                address o = handler.outsiders(i);
                if (!handler.everLive(o)) assertEq(t.balanceOf(o), 0, "an outsider never in a live root got tokens");
                assertLe(t.balanceOf(o), handler.maxLiveCum(o, address(t)), "outsider over its live cumulative");
            }
            for (uint256 i; i < handler.accountCount(); ++i) {
                address a = handler.accounts(i);
                if (!handler.everLive(a)) assertEq(t.balanceOf(a), 0, "an account never in a live root got tokens");
                assertLe(t.balanceOf(a), handler.maxLiveCum(a, address(t)), "account over its live cumulative");
            }
            assertEq(t.balanceOf(keeper), 0, "the keeper never receives");
            assertEq(t.balanceOf(guardian), 0, "the guardian never receives");
        }
    }

    /// What is owed is always held: the owner's reclaim never touches it, and every total is backed.
    function invariant_owed_is_always_held() public view {
        for (uint256 k; k < handler.stockCount(); ++k) {
            address t = address(handler.stock(k));
            (,, uint256 total, uint256 pending, uint256 claimedAll) = dist.tokenState(t);
            uint256 promised = pending > total ? pending : total;
            assertLe(claimedAll, total, "claims within the total in force");
            assertGe(Stock(t).balanceOf(address(dist)) + claimedAll, promised, "every promise is held");
            assertEq(dist.reclaimable(t) + promised - claimedAll, Stock(t).balanceOf(address(dist)), "reclaimable is exactly the unpromised rest");
        }
    }

    /// Every token that left by a claim sits with an account (sum of balances of everyone who could receive equals
    /// what was claimed, plus what the owner reclaimed to roy).
    function invariant_claims_add_up() public view {
        for (uint256 k; k < handler.stockCount(); ++k) {
            Stock t = handler.stock(k);
            uint256 sum;
            for (uint256 i; i < handler.accountCount(); ++i) sum += t.balanceOf(handler.accounts(i));
            for (uint256 i; i < handler.outsiderCount(); ++i) sum += t.balanceOf(handler.outsiders(i));
            assertEq(sum, dist.totalClaimed(address(t)), "claimed equals what accounts hold");
        }
    }

    /// However the keeper (or a stolen key) proposes, no stock's promised total outgrows its limit: the rate times
    /// the time since the deploy, plus MARGIN for every root that went through.
    function invariant_growth_is_bounded() public view {
        uint256 start = 1_800_000_000; // setUp's time, when the distributor was made
        for (uint256 k; k < 2; ++k) {
            address t = address(handler.stock(k));
            (,, uint256 total, uint256 pending,) = dist.tokenState(t);
            uint256 promised = pending > total ? pending : total;
            uint256 bound_ = dist.maxIncreasePerSecond(t) * (block.timestamp - start + handler.proposals() * dist.MARGIN());
            assertLe(promised, bound_, "a total outgrew its limit");
        }
    }

    function invariant_summary() public view {
        // Not an assertion: shows the runs did real work (forge prints nothing for view-only summaries unless -vv).
        handler.claims();
        handler.proposals();
        handler.reclaims();
    }
}
