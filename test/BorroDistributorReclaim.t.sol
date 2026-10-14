// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BorroDistributor} from "../src/BorroDistributor.sol";

contract Coin is ERC20 {
    constructor() ERC20("BORRO", "BORRO") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// The owner's reclaim (Roy, 2026-10-06): it takes back what no root promises, at once, and never a token an
/// account is owed under the root in force or a waiting one.
contract BorroDistributorReclaimTest is Test {
    Coin coin;
    BorroDistributor dist;
    address safe = makeAddr("safe");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address roy = makeAddr("roy");

    function setUp() public {
        vm.warp(1_800_000_000);
        coin = new Coin();
        dist = new BorroDistributor(IERC20(address(coin)), safe, keeper, guardian, 1e30);
        coin.mint(address(dist), 1_000e18);
    }

    function leaf(address a, uint256 cum) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, cum))));
    }

    /// One account in the tree: the root is its leaf and the proof is empty.
    function promiseTo(address a, uint256 cum) internal {
        vm.prank(keeper);
        dist.proposeRoot(leaf(a, cum), cum);
    }

    function test_nothing_promised_all_comes_back_at_once() public {
        assertEq(dist.reclaimable(), 1_000e18);
        vm.prank(safe);
        dist.reclaim(roy, 1_000e18);
        assertEq(coin.balanceOf(roy), 1_000e18);
        assertEq(coin.balanceOf(address(dist)), 0);
    }

    function test_a_waiting_root_is_already_owed() public {
        promiseTo(alice, 300e18);
        assertEq(dist.reclaimable(), 700e18);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.OverReclaimable.selector, 701e18, 700e18));
        dist.reclaim(roy, 701e18);
        vm.prank(safe);
        dist.reclaim(roy, 700e18);
        // Alice is still paid in full once the root takes effect.
        vm.warp(block.timestamp + dist.ROOT_DELAY());
        dist.claim(alice, 300e18, new bytes32[](0));
        assertEq(coin.balanceOf(alice), 300e18);
        assertEq(dist.reclaimable(), 0);
    }

    function test_after_claims_only_the_unpromised_rest() public {
        promiseTo(alice, 400e18);
        vm.warp(block.timestamp + dist.ROOT_DELAY());
        dist.claim(alice, 400e18, new bytes32[](0));
        // 400 promised and claimed: the other 600 are free.
        assertEq(dist.reclaimable(), 600e18);
        // A bigger root for Alice waits: its extra 100 is owed too.
        vm.warp(block.timestamp + 1 days);
        promiseTo(alice, 500e18);
        assertEq(dist.reclaimable(), 500e18);
    }

    function test_only_the_owner() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        dist.reclaim(keeper, 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        dist.reclaim(guardian, 1);
    }

    function test_new_roots_still_bounded_by_what_is_left() public {
        vm.prank(safe);
        dist.reclaim(roy, 900e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BorroDistributor.TotalNotHeld.selector, 101e18, 100e18));
        dist.proposeRoot(leaf(alice, 101e18), 101e18);
    }

    /// Whatever is promised and reclaimed, every account can still be paid what the roots owe it.
    function testFuzz_reclaim_never_touches_what_is_owed(uint96 promisedA, uint96 extra, uint96 take) public {
        uint256 p = bound(promisedA, 0, 1_000e18);
        promiseTo(alice, p);
        uint256 free = dist.reclaimable();
        assertEq(free, 1_000e18 - p);
        uint256 t = bound(take, 0, free);
        vm.prank(safe);
        dist.reclaim(roy, t);
        assertGe(coin.balanceOf(address(dist)), p);
        if (p > 0) {
            vm.warp(block.timestamp + dist.ROOT_DELAY());
            dist.claim(alice, p, new bytes32[](0));
            assertEq(coin.balanceOf(alice), p);
        }
        uint256 more = bound(extra, 1, type(uint96).max);
        uint256 over = dist.reclaimable() + more;
        vm.prank(safe);
        vm.expectRevert();
        dist.reclaim(roy, over);
    }
}
