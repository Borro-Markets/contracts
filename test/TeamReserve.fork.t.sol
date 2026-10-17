// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TeamReserve} from "../src/TeamReserve.sol";

/// TeamReserve on a copy of the live chain, with the real $BORRO and the real Hoard Safe as owner. Funded by
/// impersonating a live $BORRO holder (the Uniswap v4 PoolManager, which holds the coin's pool side), with the
/// 34.1M the owner plans to move in.
///   BORRO_FORK_RPC=<rpc> forge test --match-contract TeamReserveForkTest
/// Times are read with vm.getBlockTimestamp() (under via_ir block.timestamp may be read once for the whole test).
contract TeamReserveForkTest is Test {
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C; // the Hoard Safe
    address constant HOLDER = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // Uniswap v4 PoolManager: holds $BORRO
    address constant LAUNCH_WALLET = 0x912CFC9C5D8dC393F5c9949A0912b790529f549E; // the launch wallet: where the withdrawal goes
    uint256 constant PLAN = 34_100_000e18;
    uint256 constant MONTH = 2_628_000;

    TeamReserve reserve;
    address hire = makeAddr("hire");
    address stranger = makeAddr("stranger");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        reserve = new TeamReserve(BORRO, SAFE);
    }

    function test_live_fund_grant_claim_revoke_and_withdraw() public {
        if (!forked) return;
        // The live coin and the live Safe.
        assertEq(IERC20Metadata(address(BORRO)).decimals(), 18);
        assertEq(IERC20Metadata(address(BORRO)).symbol(), "BORRO");
        assertGt(SAFE.code.length, 0, "the Hoard Safe is a contract");
        assertEq(reserve.owner(), SAFE);

        // Fund: a plain transfer from a live holder. The coin takes no cut on transfers.
        uint256 amount = BORRO.balanceOf(HOLDER);
        if (amount > PLAN) amount = PLAN;
        assertGt(amount, 2_000_000e18, "the holder has enough to fund the test");
        vm.prank(HOLDER);
        BORRO.transfer(address(reserve), amount);
        assertEq(BORRO.balanceOf(address(reserve)), amount);
        assertEq(reserve.unallocated(), amount);

        // A hire's grant, signed by the Safe, starting now.
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reserve.grant(stranger, 1e18, t0);
        vm.prank(SAFE);
        uint256 id = reserve.grant(hire, 1_000_000e18, t0);
        assertEq(reserve.unallocated(), amount - 1_000_000e18);
        assertEq(reserve.totalGranted(), 1_000_000e18);

        // Nothing before the cliff; a quarter at it.
        vm.warp(t0 + 365 days - 1);
        vm.prank(hire);
        vm.expectRevert(TeamReserve.NothingToClaim.selector);
        reserve.claim(id);
        vm.warp(t0 + 365 days);
        vm.prank(SAFE);
        vm.expectRevert(TeamReserve.NotBeneficiary.selector);
        reserve.claim(id);
        vm.prank(hire);
        assertEq(reserve.claim(id), 250_000e18);
        assertEq(BORRO.balanceOf(hire), 250_000e18);

        // Three months later the hire leaves: the Safe revokes. What vested stays the hire's, the rest is unallocated.
        vm.warp(t0 + 365 days + 3 * MONTH);
        assertEq(reserve.claimable(id), 62_500e18);
        vm.prank(SAFE);
        assertEq(reserve.revoke(id), 1_000_000e18 - 312_500e18);
        assertEq(reserve.unallocated(), amount - 312_500e18); // the balance less the hire's vested 62,500
        vm.prank(SAFE);
        vm.expectRevert(
            abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, amount - 250_000e18, amount - 312_500e18)
        );
        reserve.queueWithdraw(SAFE, amount - 250_000e18); // the whole balance: it cannot reach the hire's 62,500
        vm.warp(t0 + 6 * 365 days);
        vm.prank(hire);
        assertEq(reserve.claim(id), 62_500e18, "the vested rest is still the hire's, frozen at the revoke");
        assertEq(BORRO.balanceOf(hire), 312_500e18);
        assertEq(reserve.totalGranted(), 0);

        // Any other withdrawal: queued in public, executable by anyone only 30 days later, sent to its `to`.
        uint256 ownerBefore = BORRO.balanceOf(LAUNCH_WALLET);
        uint256 q = vm.getBlockTimestamp();
        vm.prank(SAFE);
        uint256 w = reserve.queueWithdraw(LAUNCH_WALLET, 1_000_000e18);
        (uint256[] memory ids,,, uint256[] memory readyAt) = reserve.pendingWithdrawals();
        assertEq(ids.length, 1);
        assertEq(ids[0], w);
        assertEq(readyAt[0], q + 30 days);
        vm.warp(q + 30 days - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotReady.selector, q + 30 days));
        reserve.executeWithdraw(w);
        vm.warp(q + 30 days);
        vm.prank(stranger);
        reserve.executeWithdraw(w);
        assertEq(BORRO.balanceOf(LAUNCH_WALLET), ownerBefore + 1_000_000e18);
        assertEq(BORRO.balanceOf(stranger), 0);
        assertEq(reserve.totalQueued(), 0);

        // What is left is all unallocated, and the books close.
        uint256 left = amount - 312_500e18 - 1_000_000e18;
        assertEq(BORRO.balanceOf(address(reserve)), left);
        assertEq(reserve.unallocated(), left);
    }
}
