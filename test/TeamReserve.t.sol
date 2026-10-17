// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TeamReserve} from "../src/TeamReserve.sol";
import {WatchedCoin} from "./WatchedCoin.sol";

contract OtherCoin is ERC20 {
    constructor() ERC20("OTHER", "OTHER") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// A token with two entry points (one balance behind two addresses), to show sweep() cannot be used to move it.
contract DualCoin is ERC20 {
    address public alias_;

    constructor() ERC20("DUAL", "DUAL") {
        alias_ = address(new DualAlias(this));
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function aliasTransfer(address from, address to, uint256 a) external {
        require(msg.sender == alias_, "alias only");
        _transfer(from, to, a);
    }
}

contract DualAlias {
    DualCoin immutable coin;

    constructor(DualCoin c) {
        coin = c;
    }

    function balanceOf(address a) external view returns (uint256) {
        return coin.balanceOf(a);
    }

    function transfer(address to, uint256 a) external returns (bool) {
        coin.aliasTransfer(msg.sender, to, a);
        return true;
    }
}

/// Times are read with vm.getBlockTimestamp(): under via_ir the compiler may treat block.timestamp as fixed for the
/// whole test and read it after a later vm.warp.
contract TeamReserveBase is Test {
    uint256 constant T0 = 1_800_000_000; // 2027-01-15 08:00 UTC
    uint256 constant FUND = 34_100_000e18; // what the owner plans to move in
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant MONTH = 2_628_000; // 365 days / 12
    uint256 constant YEAR = 365 days;

    WatchedCoin coin;
    TeamReserve r;
    address safe = makeAddr("safe"); // the Hoard Safe: owns the reserve
    address holder = makeAddr("holder"); // the wallet that holds the owner's $BORRO
    address alice = makeAddr("alice"); // a hire
    address bob = makeAddr("bob"); // another hire
    address eve = makeAddr("eve"); // nobody
    address ownerCold = makeAddr("ownerCold"); // where a withdrawal goes

    function setUp() public virtual {
        vm.warp(T0);
        coin = new WatchedCoin();
        coin.mint(holder, SUPPLY);
        r = new TeamReserve(IERC20(address(coin)), safe);
        coin.watch(address(r));
        fund(FUND);
    }

    function fund(uint256 amount) internal {
        vm.prank(holder);
        coin.transfer(address(r), amount);
    }

    function now_() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function grantAs(address b, uint256 amount, uint256 start) internal returns (uint256 id) {
        vm.prank(safe);
        id = r.grant(b, amount, start);
    }

    function queueAs(address to, uint256 amount) internal returns (uint256 id) {
        vm.prank(safe);
        id = r.queueWithdraw(to, amount);
    }

    function claimAs(address who, uint256 id) internal returns (uint256) {
        vm.prank(who);
        return r.claim(id);
    }

    function held() internal view returns (uint256) {
        return coin.balanceOf(address(r));
    }

    function notOwner(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);
    }
}

contract TeamReserveTest is TeamReserveBase {
    // ------------------------------------------------------------------ deploy

    function test_deploy() public view {
        assertEq(r.owner(), safe);
        assertEq(r.pendingOwner(), address(0));
        assertEq(address(r.token()), address(coin));
        assertEq(r.unallocated(), FUND);
        assertEq(r.totalGranted(), 0);
        assertEq(r.totalQueued(), 0);
        assertEq(r.grantCount(), 0);
        assertEq(r.withdrawalCount(), 0);
        assertEq(r.MONTH(), MONTH);
        assertEq(r.CLIFF(), YEAR);
        assertEq(r.DURATION(), 4 * YEAR);
        assertEq(r.WITHDRAW_DELAY(), 30 days);
    }

    function test_deploy_refuses_zero() public {
        vm.expectRevert(TeamReserve.ZeroAddress.selector);
        new TeamReserve(IERC20(address(0)), safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new TeamReserve(IERC20(address(coin)), address(0));
    }

    function test_no_renounce() public {
        vm.prank(safe);
        vm.expectRevert(TeamReserve.NoRenounce.selector);
        r.renounceOwnership();
        assertEq(r.owner(), safe);
    }

    function test_ownership_moves_in_two_steps() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(eve);
        vm.expectRevert(notOwner(eve));
        r.transferOwnership(eve);
        vm.prank(safe);
        r.transferOwnership(newSafe);
        assertEq(r.owner(), safe, "still the old owner until accepted");
        // The pending owner has no power yet.
        vm.prank(newSafe);
        vm.expectRevert(notOwner(newSafe));
        r.grant(alice, 1e18, now_());
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        r.acceptOwnership();
        vm.prank(newSafe);
        r.acceptOwnership();
        assertEq(r.owner(), newSafe);
        vm.prank(safe);
        vm.expectRevert(notOwner(safe));
        r.grant(alice, 1e18, now_());
        grantAs2(newSafe);
    }

    function grantAs2(address o) internal {
        vm.prank(o);
        r.grant(alice, 1e18, now_());
        assertEq(r.grantCount(), 1);
    }

    // ------------------------------------------------------------------ the schedule

    function test_schedule_points() public view {
        uint256 a = 4_800_000e18;
        uint256 s = T0;
        assertEq(r.vestedAt(a, s, s), 0);
        assertEq(r.vestedAt(a, s, s + YEAR - 1), 0, "nothing a second before the cliff");
        assertEq(r.vestedAt(a, s, s + YEAR), a / 4, "a quarter at the cliff");
        assertEq(r.vestedAt(a, s, s + YEAR + MONTH - 1), a / 4, "nothing more until a full month after");
        assertEq(r.vestedAt(a, s, s + YEAR + MONTH), (a * 13) / 48, "13/48 one month after the cliff");
        assertEq(r.vestedAt(a, s, s + 2 * YEAR), a / 2, "half at two years");
        assertEq(r.vestedAt(a, s, s + 3 * YEAR), (a * 3) / 4, "three quarters at three years");
        assertEq(r.vestedAt(a, s, s + 4 * YEAR - 1), (a * 47) / 48, "47/48 a second before the end");
        assertEq(r.vestedAt(a, s, s + 4 * YEAR), a, "all of it at four years");
        assertEq(r.vestedAt(a, s, s + 40 * YEAR), a, "and never more");
        // A start in the future: nothing before it, nor before its own cliff.
        assertEq(r.vestedAt(a, s + 30 days, s + 30 days + YEAR - 1), 0);
        assertEq(r.vestedAt(a, s + 30 days, s), 0);
        // Odd amounts round down until the end.
        assertEq(r.vestedAt(47, s, s + YEAR), 11);
        assertEq(r.vestedAt(47, s, s + 4 * YEAR - 1), 46);
        assertEq(r.vestedAt(47, s, s + 4 * YEAR), 47);
        assertEq(r.vestedAt(1, s, s + 4 * YEAR - 1), 0);
        assertEq(r.vestedAt(1, s, s + 4 * YEAR), 1);
    }

    function test_every_month_step() public view {
        uint256 a = 48_000e18;
        for (uint256 m; m <= 50; ++m) {
            uint256 want = m < 12 ? 0 : m >= 48 ? a : (a * m) / 48;
            assertEq(r.vestedAt(a, T0, T0 + m * MONTH), want);
            if (m > 0) assertEq(r.vestedAt(a, T0, T0 + m * MONTH - 1), m <= 12 ? 0 : m > 48 ? a : (a * (m - 1)) / 48);
        }
    }

    // ------------------------------------------------------------------ grants

    function test_grant() public {
        vm.expectEmit(address(r));
        emit TeamReserve.Granted(0, alice, 1_000_000e18, T0, T0 + YEAR, T0 + 4 * YEAR);
        uint256 id = grantAs(alice, 1_000_000e18, T0);
        assertEq(id, 0);
        assertEq(r.totalGranted(), 1_000_000e18);
        assertEq(r.unallocated(), FUND - 1_000_000e18);
        assertEq(held(), FUND, "a grant moves nothing");
        TeamReserve.GrantView memory g = r.grantInfo(0);
        assertEq(g.beneficiary, alice);
        assertEq(g.amount, 1_000_000e18);
        assertEq(g.start, T0);
        assertEq(g.cliffAt, T0 + YEAR);
        assertEq(g.endAt, T0 + 4 * YEAR);
        assertEq(g.revokedAt, 0);
        assertEq(g.vested, 0);
        assertEq(g.claimable, 0);
        assertEq(g.unvested, 1_000_000e18);
        assertEq(g.remaining, 1_000_000e18);
    }

    function test_grant_only_owner() public {
        vm.prank(eve);
        vm.expectRevert(notOwner(eve));
        r.grant(eve, 1e18, T0);
        vm.prank(alice);
        vm.expectRevert(notOwner(alice));
        r.grant(alice, 1e18, T0);
    }

    function test_grant_refusals() public {
        vm.startPrank(safe);
        vm.expectRevert(TeamReserve.ZeroAddress.selector);
        r.grant(address(0), 1e18, T0);
        vm.expectRevert(TeamReserve.BadAddress.selector);
        r.grant(address(r), 1e18, T0);
        vm.expectRevert(TeamReserve.ZeroAmount.selector);
        r.grant(alice, 0, T0);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, FUND + 1, FUND));
        r.grant(alice, FUND + 1, T0);
        // Start: at most 90 days back, at most 365 days ahead.
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.BadStart.selector, T0 - 90 days - 1, T0 - 90 days, T0 + YEAR));
        r.grant(alice, 1e18, T0 - 90 days - 1);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.BadStart.selector, T0 + YEAR + 1, T0 - 90 days, T0 + YEAR));
        r.grant(alice, 1e18, T0 + YEAR + 1);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.BadStart.selector, type(uint256).max, T0 - 90 days, T0 + YEAR));
        r.grant(alice, 1e18, type(uint256).max);
        // A typo'd millisecond timestamp is refused, not a grant that never vests.
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.BadStart.selector, T0 * 1000, T0 - 90 days, T0 + YEAR));
        r.grant(alice, 1e18, T0 * 1000);
        // The edges are fine.
        r.grant(alice, 1e18, T0 - 90 days);
        r.grant(alice, 1e18, T0 + YEAR);
        vm.stopPrank();
        assertEq(r.grantCount(), 2);
    }

    function test_grant_uses_everything_then_nothing_more() public {
        grantAs(alice, FUND, T0);
        assertEq(r.unallocated(), 0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, 1, 0));
        r.grant(bob, 1, T0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, 1, 0));
        r.queueWithdraw(ownerCold, 1);
        // More $BORRO arriving is unallocated again.
        fund(5e18);
        assertEq(r.unallocated(), 5e18);
        grantAs(bob, 5e18, T0);
    }

    function test_several_grants_per_beneficiary() public {
        uint256 a = grantAs(alice, 1_000e18, T0);
        uint256 b = grantAs(bob, 2_000e18, T0);
        uint256 c = grantAs(alice, 3_000e18, T0 + 100 days);
        assertEq(a, 0);
        assertEq(b, 1);
        assertEq(c, 2);
        uint256[] memory ids = r.grantsOf(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 2);
        assertEq(r.grantsOf(bob).length, 1);
        assertEq(r.grantsOf(eve).length, 0);
        assertEq(r.totalGranted(), 6_000e18);
        vm.warp(T0 + YEAR);
        assertEq(claimAs(alice, a), 250e18);
        vm.prank(alice);
        vm.expectRevert(TeamReserve.NothingToClaim.selector);
        r.claim(c); // its cliff is 100 days later
        vm.warp(T0 + 100 days + YEAR);
        assertEq(claimAs(alice, c), 750e18);
        assertEq(coin.balanceOf(alice), 1_000e18);
    }

    function test_no_such_grant() public {
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NoSuchGrant.selector, 0));
        r.vested(0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NoSuchGrant.selector, 0));
        r.revoke(0);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NoSuchGrant.selector, 0));
        r.claim(0);
    }

    // ------------------------------------------------------------------ claims

    function test_claim_over_four_years() public {
        uint256 amount = 4_800_000e18;
        uint256 id = grantAs(alice, amount, T0);
        vm.prank(alice);
        vm.expectRevert(TeamReserve.NothingToClaim.selector);
        r.claim(id);
        vm.warp(T0 + YEAR - 1);
        assertEq(r.claimable(id), 0);
        vm.prank(alice);
        vm.expectRevert(TeamReserve.NothingToClaim.selector);
        r.claim(id);

        vm.warp(T0 + YEAR);
        vm.expectEmit(address(r));
        emit TeamReserve.Claimed(id, alice, amount / 4, amount / 4);
        assertEq(claimAs(alice, id), amount / 4);
        vm.prank(alice);
        vm.expectRevert(TeamReserve.NothingToClaim.selector);
        r.claim(id);

        // Monthly after that; a missed month is paid with the next.
        vm.warp(T0 + YEAR + MONTH);
        assertEq(claimAs(alice, id), amount / 48);
        vm.warp(T0 + YEAR + 3 * MONTH + 5 days);
        assertEq(claimAs(alice, id), (2 * amount) / 48);
        assertEq(r.totalGranted(), amount - (15 * amount) / 48);

        vm.warp(T0 + 4 * YEAR + 1);
        assertEq(claimAs(alice, id), amount - (15 * amount) / 48);
        assertEq(coin.balanceOf(alice), amount);
        assertEq(r.totalGranted(), 0);
        assertEq(r.remaining(id), 0);
        assertEq(held(), FUND - amount);
        assertEq(r.unallocated(), FUND - amount);
        vm.warp(T0 + 10 * YEAR);
        vm.prank(alice);
        vm.expectRevert(TeamReserve.NothingToClaim.selector);
        r.claim(id);
    }

    function test_only_the_beneficiary_claims() public {
        uint256 id = grantAs(alice, 1_000e18, T0);
        vm.warp(T0 + 2 * YEAR);
        address[3] memory others = [safe, eve, bob];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(TeamReserve.NotBeneficiary.selector);
            r.claim(id);
        }
        assertEq(claimAs(alice, id), 500e18);
        assertEq(coin.balanceOf(alice), 500e18);
    }

    function test_owner_cannot_take_vested() public {
        uint256 id = grantAs(alice, FUND, T0);
        vm.warp(T0 + 2 * YEAR);
        assertEq(r.claimable(id), FUND / 2);
        vm.startPrank(safe);
        // No withdrawal: nothing is unallocated.
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, 1, 0));
        r.queueWithdraw(safe, 1);
        // No sweep of $BORRO.
        vm.expectRevert(TeamReserve.NotOtherToken.selector);
        r.sweep(IERC20(address(coin)));
        // No claim.
        vm.expectRevert(TeamReserve.NotBeneficiary.selector);
        r.claim(id);
        // No move of the grant.
        vm.expectRevert(TeamReserve.NotBeneficiary.selector);
        r.moveGrant(id, safe);
        // A revoke returns only the unvested half; the vested half stays alice's.
        r.revoke(id);
        uint256 half = r.unallocated();
        assertEq(half, FUND - FUND / 2);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, half + 1, half));
        r.queueWithdraw(safe, half + 1);
        r.queueWithdraw(safe, half);
        vm.stopPrank();
        vm.warp(T0 + 2 * YEAR + 30 days);
        r.executeWithdraw(0);
        assertEq(coin.balanceOf(safe), half);
        assertEq(claimAs(alice, id), FUND / 2);
        assertEq(held(), 0);
    }

    // ------------------------------------------------------------------ revoke

    function test_revoke_before_the_cliff_returns_everything() public {
        uint256 id = grantAs(alice, 1_000_000e18, T0);
        vm.warp(T0 + YEAR - 1);
        vm.expectEmit(address(r));
        emit TeamReserve.Revoked(id, alice, 0, 1_000_000e18);
        vm.prank(safe);
        assertEq(r.revoke(id), 1_000_000e18);
        assertEq(r.totalGranted(), 0);
        assertEq(r.unallocated(), FUND);
        vm.warp(T0 + 4 * YEAR);
        assertEq(r.vested(id), 0, "a revoked grant stops vesting");
        vm.prank(alice);
        vm.expectRevert(TeamReserve.NothingToClaim.selector);
        r.claim(id);
        TeamReserve.GrantView memory g = r.grantInfo(id);
        assertEq(g.revokedAt, T0 + YEAR - 1);
        assertEq(g.unvested, 0);
        assertEq(g.remaining, 0);
    }

    function test_revoke_keeps_what_vested() public {
        uint256 amount = 4_800_000e18;
        uint256 id = grantAs(alice, amount, T0);
        vm.warp(T0 + YEAR);
        assertEq(claimAs(alice, id), amount / 4); // claims at the cliff, then leaves at 18 months:
        vm.warp(T0 + YEAR + 6 * MONTH + 3 days);
        uint256 v = (amount * 18) / 48;
        assertEq(r.vested(id), v);
        uint256 before = r.unallocated();
        vm.prank(safe);
        uint256 back = r.revoke(id);
        assertEq(back, amount - v);
        assertEq(r.unallocated(), before + back);
        assertEq(r.vested(id), v);
        assertEq(r.claimable(id), v - amount / 4);
        assertEq(r.remaining(id), v - amount / 4);
        assertEq(r.totalGranted(), v - amount / 4);
        // Years later nothing more vests, and the vested rest is still alice's.
        vm.warp(T0 + 6 * YEAR);
        assertEq(r.claimable(id), v - amount / 4);
        assertEq(claimAs(alice, id), v - amount / 4);
        assertEq(coin.balanceOf(alice), v);
        assertEq(r.totalGranted(), 0);
        assertEq(r.unallocated(), FUND - v);
        vm.prank(safe);
        vm.expectRevert(TeamReserve.AlreadyRevoked.selector);
        r.revoke(id);
    }

    function test_revoke_after_the_end_returns_nothing() public {
        uint256 id = grantAs(alice, 1_000e18, T0);
        vm.warp(T0 + 5 * YEAR);
        vm.prank(safe);
        assertEq(r.revoke(id), 0);
        assertEq(claimAs(alice, id), 1_000e18);
    }

    function test_revoke_only_owner() public {
        uint256 id = grantAs(alice, 1_000e18, T0);
        vm.prank(alice);
        vm.expectRevert(notOwner(alice));
        r.revoke(id);
        vm.prank(eve);
        vm.expectRevert(notOwner(eve));
        r.revoke(id);
    }

    // ------------------------------------------------------------------ moving a grant

    function test_beneficiary_moves_the_grant() public {
        address aliceCold = makeAddr("aliceCold");
        uint256 id = grantAs(alice, 1_000e18, T0);
        vm.prank(safe);
        vm.expectRevert(TeamReserve.NotBeneficiary.selector);
        r.moveGrant(id, safe);
        vm.prank(eve);
        vm.expectRevert(TeamReserve.NotBeneficiary.selector);
        r.moveGrant(id, eve);
        vm.startPrank(alice);
        vm.expectRevert(TeamReserve.ZeroAddress.selector);
        r.moveGrant(id, address(0));
        vm.expectRevert(TeamReserve.BadAddress.selector);
        r.moveGrant(id, address(r));
        vm.expectEmit(address(r));
        emit TeamReserve.GrantMoved(id, alice, aliceCold);
        r.moveGrant(id, aliceCold);
        vm.stopPrank();
        vm.warp(T0 + YEAR);
        vm.prank(alice);
        vm.expectRevert(TeamReserve.NotBeneficiary.selector);
        r.claim(id);
        assertEq(claimAs(aliceCold, id), 250e18);
        assertEq(r.grantsOf(alice).length, 0);
        assertEq(r.grantsOf(aliceCold).length, 1);
    }

    // ------------------------------------------------------------------ withdrawals

    function test_withdraw_waits_thirty_days() public {
        vm.expectEmit(address(r));
        emit TeamReserve.WithdrawQueued(0, ownerCold, 1_000_000e18, T0 + 30 days, T0 + 44 days);
        uint256 id = queueAs(ownerCold, 1_000_000e18);
        assertEq(r.totalQueued(), 1_000_000e18);
        assertEq(r.unallocated(), FUND - 1_000_000e18);
        (address to, uint256 amount, uint256 queuedAt, uint256 readyAt, uint256 expiresAt, TeamReserve.Status st) =
            r.withdrawalInfo(id);
        assertEq(to, ownerCold);
        assertEq(amount, 1_000_000e18);
        assertEq(queuedAt, T0);
        assertEq(readyAt, T0 + 30 days);
        assertEq(expiresAt, T0 + 44 days);
        assertEq(uint8(st), uint8(TeamReserve.Status.Queued));
        (uint256[] memory ids, address[] memory tos, uint256[] memory amounts, uint256[] memory ready) = r.pendingWithdrawals();
        assertEq(ids.length, 1);
        assertEq(tos[0], ownerCold);
        assertEq(amounts[0], 1_000_000e18);
        assertEq(ready[0], T0 + 30 days);

        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotReady.selector, T0 + 30 days));
        r.executeWithdraw(id);
        vm.warp(T0 + 30 days - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotReady.selector, T0 + 30 days));
        r.executeWithdraw(id);

        vm.warp(T0 + 30 days);
        vm.expectEmit(address(r));
        emit TeamReserve.WithdrawExecuted(id, ownerCold, 1_000_000e18, eve);
        vm.prank(eve); // anyone, and it still goes to `to`
        r.executeWithdraw(id);
        assertEq(coin.balanceOf(ownerCold), 1_000_000e18);
        assertEq(coin.balanceOf(eve), 0);
        assertEq(r.totalQueued(), 0);
        assertEq(r.unallocated(), FUND - 1_000_000e18);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotQueued.selector, TeamReserve.Status.Executed));
        r.executeWithdraw(id);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotQueued.selector, TeamReserve.Status.Executed));
        r.cancelWithdraw(id);
        (ids,,,) = r.pendingWithdrawals();
        assertEq(ids.length, 0);
    }

    function test_withdraw_expires_after_its_window() public {
        uint256 id = queueAs(ownerCold, 7e18);
        vm.warp(T0 + 44 days - 1);
        uint256 snap = vm.snapshotState();
        r.executeWithdraw(id); // the last second of the window
        assertEq(coin.balanceOf(ownerCold), 7e18);
        vm.revertToState(snap);
        vm.warp(T0 + 44 days);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.Expired.selector, T0 + 44 days));
        r.executeWithdraw(id);
        vm.warp(T0 + 400 days);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.Expired.selector, T0 + 44 days));
        r.executeWithdraw(id);
        // Still held back until the owner cancels it; then free again, and a fresh one waits its own 30 days.
        assertEq(r.unallocated(), FUND - 7e18);
        (uint256[] memory ids,,,) = r.pendingWithdrawals();
        assertEq(ids.length, 1);
        vm.prank(safe);
        r.cancelWithdraw(id);
        assertEq(r.unallocated(), FUND);
        uint256 again = queueAs(ownerCold, 7e18);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotReady.selector, T0 + 430 days));
        r.executeWithdraw(again);
        assertEq(coin.balanceOf(ownerCold), 0);
    }

    function test_withdraw_cancel() public {
        uint256 id = queueAs(ownerCold, 5e18);
        vm.prank(eve);
        vm.expectRevert(notOwner(eve));
        r.cancelWithdraw(id);
        vm.expectEmit(address(r));
        emit TeamReserve.WithdrawCancelled(id, ownerCold, 5e18);
        vm.prank(safe);
        r.cancelWithdraw(id);
        assertEq(r.totalQueued(), 0);
        assertEq(r.unallocated(), FUND);
        vm.warp(T0 + 31 days);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotQueued.selector, TeamReserve.Status.Cancelled));
        r.executeWithdraw(id);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotQueued.selector, TeamReserve.Status.Cancelled));
        r.cancelWithdraw(id);
        assertEq(coin.balanceOf(ownerCold), 0);
    }

    function test_withdraw_refusals() public {
        vm.prank(eve);
        vm.expectRevert(notOwner(eve));
        r.queueWithdraw(eve, 1);
        vm.startPrank(safe);
        vm.expectRevert(TeamReserve.ZeroAddress.selector);
        r.queueWithdraw(address(0), 1);
        vm.expectRevert(TeamReserve.BadAddress.selector);
        r.queueWithdraw(address(r), 1);
        vm.expectRevert(TeamReserve.ZeroAmount.selector);
        r.queueWithdraw(ownerCold, 0);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, FUND + 1, FUND));
        r.queueWithdraw(ownerCold, FUND + 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NoSuchWithdrawal.selector, 0));
        r.executeWithdraw(0);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NoSuchWithdrawal.selector, 0));
        r.withdrawalInfo(0);
    }

    function test_queued_amount_is_held_back_from_grants() public {
        queueAs(ownerCold, FUND - 10e18);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, 11e18, 10e18));
        r.grant(alice, 11e18, T0);
        grantAs(alice, 10e18, T0);
        assertEq(r.unallocated(), 0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, 1, 0));
        r.queueWithdraw(ownerCold, 1);
        // Cancelling frees it again.
        vm.prank(safe);
        r.cancelWithdraw(0);
        assertEq(r.unallocated(), FUND - 10e18);
    }

    function test_several_pending_withdrawals() public {
        queueAs(ownerCold, 1e18);
        vm.warp(T0 + 1 days);
        queueAs(bob, 2e18);
        vm.warp(T0 + 2 days);
        queueAs(ownerCold, 3e18);
        vm.prank(safe);
        r.cancelWithdraw(1);
        (uint256[] memory ids, address[] memory tos, uint256[] memory amounts, uint256[] memory ready) = r.pendingWithdrawals();
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 2);
        assertEq(tos[1], ownerCold);
        assertEq(amounts[1], 3e18);
        assertEq(ready[0], T0 + 30 days);
        assertEq(ready[1], T0 + 32 days);
        assertEq(r.totalQueued(), 4e18);
        vm.warp(T0 + 31 days);
        r.executeWithdraw(0);
        vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotReady.selector, T0 + 32 days));
        r.executeWithdraw(2);
    }

    // ------------------------------------------------------------------ sweep

    function test_sweep_other_tokens_only() public {
        OtherCoin other = new OtherCoin();
        other.mint(address(r), 7e18);
        vm.prank(eve);
        vm.expectRevert(notOwner(eve));
        r.sweep(IERC20(address(other)));
        vm.prank(safe);
        vm.expectRevert(TeamReserve.NotOtherToken.selector);
        r.sweep(IERC20(address(coin)));
        vm.expectEmit(address(r));
        emit TeamReserve.Swept(address(other), safe, 7e18);
        vm.prank(safe);
        assertEq(r.sweep(IERC20(address(other))), 7e18);
        assertEq(other.balanceOf(safe), 7e18);
        assertEq(held(), FUND);
    }

    function test_sweep_cannot_reach_a_second_entry_point() public {
        DualCoin dual = new DualCoin();
        TeamReserve d = new TeamReserve(IERC20(address(dual)), safe);
        dual.mint(address(d), 100e18);
        vm.prank(safe);
        vm.expectRevert(TeamReserve.NotOtherToken.selector);
        d.sweep(IERC20(address(dual)));
        IERC20 twin = IERC20(dual.alias_());
        assertEq(twin.balanceOf(address(d)), 100e18);
        vm.prank(safe);
        vm.expectRevert(TeamReserve.SweepMovedToken.selector);
        d.sweep(twin);
        assertEq(dual.balanceOf(address(d)), 100e18);
        assertEq(dual.balanceOf(safe), 0);
    }

    // ------------------------------------------------------------------ the whole story

    /// The owner's plan end to end: fund, two hires, one leaves after 18 months, a withdrawal waits 30 days, everyone is
    /// paid exactly, and only the beneficiaries and the chosen withdrawal address ever received.
    function test_story() public {
        uint256 a = grantAs(alice, 2_400_000e18, T0 + 14 days); // starts in two weeks
        uint256 b = grantAs(bob, 1_200_000e18, T0 - 30 days); // backdated to bob's first day
        assertEq(r.unallocated(), FUND - 3_600_000e18);
        vm.warp(T0 - 30 days + YEAR);
        assertEq(claimAs(bob, b), 300_000e18);
        vm.warp(T0 + 14 days + YEAR + 6 * MONTH); // alice leaves at 18 months
        vm.prank(safe);
        uint256 back = r.revoke(a);
        assertEq(back, 2_400_000e18 - (2_400_000e18 * 18) / 48);
        uint256 id = queueAs(ownerCold, 1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        r.executeWithdraw(id);
        vm.warp(T0 + 10 * YEAR);
        claimAs(alice, a);
        claimAs(bob, b);
        assertEq(coin.balanceOf(alice), (2_400_000e18 * 18) / 48);
        assertEq(coin.balanceOf(bob), 1_200_000e18);
        assertEq(coin.balanceOf(ownerCold), 1_000_000e18);
        assertEq(r.totalGranted(), 0);
        assertEq(r.totalQueued(), 0);
        assertEq(held(), FUND - coin.balanceOf(alice) - 1_200_000e18 - 1_000_000e18);
        assertEq(r.unallocated(), held());
        assertEq(coin.paidToCount(), 3);
        assertEq(coin.paidOutTotal(), FUND - held());
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_schedule(uint256 amount, uint256 start, uint256 t, uint256 dt) public view {
        amount = bound(amount, 0, SUPPLY);
        start = bound(start, 0, 1e11);
        t = bound(t, 0, 1e11 + 100 * YEAR);
        dt = bound(dt, 0, 10 * YEAR);
        uint256 v = r.vestedAt(amount, start, t);
        assertLe(v, amount);
        assertLe(v, r.vestedAt(amount, start, t + dt), "never down as time goes on");
        if (t < start + YEAR) assertEq(v, 0);
        else if (t >= start + 4 * YEAR) assertEq(v, amount);
        else assertEq(v, (amount * ((t - start) / MONTH)) / 48);
        if (t >= start + YEAR) assertGe(v, amount / 4);
    }

    function testFuzz_revoke_never_touches_vested(uint256 amount, uint256 elapsed, uint256 claimAt, uint256 later)
        public
    {
        amount = bound(amount, 1, FUND);
        elapsed = bound(elapsed, 0, 5 * YEAR);
        claimAt = bound(claimAt, 0, elapsed);
        later = bound(later, 0, 10 * YEAR);
        uint256 id = grantAs(alice, amount, T0);
        vm.warp(T0 + claimAt);
        uint256 paid;
        if (r.claimable(id) > 0) paid = claimAs(alice, id);
        vm.warp(T0 + elapsed);
        uint256 v = r.vested(id);
        uint256 c = r.claimable(id);
        uint256 freeBefore = r.unallocated();
        vm.prank(safe);
        uint256 back = r.revoke(id);
        assertEq(back, amount - v);
        assertEq(r.vested(id), v);
        assertEq(r.claimable(id), c);
        assertEq(r.unallocated(), freeBefore + back);
        vm.warp(T0 + elapsed + later);
        assertEq(r.vested(id), v, "frozen");
        assertEq(r.claimable(id), c);
        if (c > 0) assertEq(claimAs(alice, id), c);
        assertEq(coin.balanceOf(alice), paid + c);
        assertEq(paid + c, v);
        assertEq(r.totalGranted(), 0);
        assertEq(held(), FUND - v);
        assertEq(r.unallocated(), FUND - v);
    }

    function testFuzz_withdraw_only_in_its_window(uint256 amount, uint256 dt, address caller) public {
        amount = bound(amount, 1, FUND);
        dt = bound(dt, 0, 90 days);
        vm.assume(caller != address(0));
        uint256 id = queueAs(ownerCold, amount);
        vm.warp(T0 + dt);
        vm.prank(caller);
        if (dt < 30 days) {
            vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotReady.selector, T0 + 30 days));
            r.executeWithdraw(id);
            assertEq(coin.balanceOf(ownerCold), 0);
        } else if (dt >= 44 days) {
            vm.expectRevert(abi.encodeWithSelector(TeamReserve.Expired.selector, T0 + 44 days));
            r.executeWithdraw(id);
            assertEq(coin.balanceOf(ownerCold), 0);
        } else {
            r.executeWithdraw(id);
            assertEq(coin.balanceOf(ownerCold), amount);
        }
    }

    function testFuzz_only_the_beneficiary_claims(address caller, uint256 elapsed) public {
        vm.assume(caller != alice);
        elapsed = bound(elapsed, YEAR, 5 * YEAR);
        uint256 id = grantAs(alice, 1_000_000e18, T0);
        vm.warp(T0 + elapsed);
        vm.prank(caller);
        vm.expectRevert(TeamReserve.NotBeneficiary.selector);
        r.claim(id);
        assertEq(held(), FUND);
    }

    function testFuzz_grants_and_withdrawals_fit_the_balance(uint256 g1, uint256 q, uint256 g2) public {
        g1 = bound(g1, 1, FUND);
        grantAs(alice, g1, T0);
        q = bound(q, 0, FUND);
        vm.prank(safe);
        if (q == 0) {
            vm.expectRevert(TeamReserve.ZeroAmount.selector);
            r.queueWithdraw(ownerCold, q);
        } else if (q > FUND - g1) {
            vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, q, FUND - g1));
            r.queueWithdraw(ownerCold, q);
            q = 0;
        } else {
            r.queueWithdraw(ownerCold, q);
        }
        g2 = bound(g2, 1, FUND);
        uint256 free = FUND - g1 - q;
        assertEq(r.unallocated(), free);
        vm.prank(safe);
        if (g2 > free) {
            vm.expectRevert(abi.encodeWithSelector(TeamReserve.NotEnoughUnallocated.selector, g2, free));
            r.grant(bob, g2, T0);
        } else {
            r.grant(bob, g2, T0);
        }
        assertLe(r.totalGranted() + r.totalQueued(), held());
    }

    function testFuzz_non_owner_has_no_owner_powers(address caller) public {
        vm.assume(caller != safe);
        grantAs(alice, 1e18, T0);
        queueAs(ownerCold, 1e18);
        OtherCoin other = new OtherCoin();
        vm.startPrank(caller);
        vm.expectRevert(notOwner(caller));
        r.grant(caller, 1, T0);
        vm.expectRevert(notOwner(caller));
        r.revoke(0);
        vm.expectRevert(notOwner(caller));
        r.queueWithdraw(caller, 1);
        vm.expectRevert(notOwner(caller));
        r.cancelWithdraw(0);
        vm.expectRevert(notOwner(caller));
        r.sweep(IERC20(address(other)));
        vm.expectRevert(notOwner(caller));
        r.transferOwnership(caller);
        vm.stopPrank();
    }
}

/// Random actions by the owner, the beneficiaries, withdrawal recipients and strangers, with time passing. Every call
/// that must fail is tried too, and counted if it ever goes through.
contract ReserveHandler is Test {
    TeamReserve public r;
    WatchedCoin public coin;
    OtherCoin public other;
    address public safe;
    address public holder;
    address[] public people; // hires
    address[] public sinks; // withdrawal recipients
    address[] public strangers;

    uint256 public inflow;
    uint256 public claimedOut;
    uint256 public executedOut;
    uint256 public sneaks; // a call that must fail went through
    uint256 public earlyExecutions; // a withdrawal executed before its 30 days, or after its window
    uint256 public vestedChanges; // a revoke changed what had vested or what could be claimed
    uint256 public vestedDrops; // a grant's vested amount went down
    uint256 public missedClaims; // a claim of something claimable failed
    uint256 public missedRevokes; // The owner could not revoke a live grant
    uint256 public missedExecutions; // a ready withdrawal could not be executed
    mapping(uint256 => uint256) public lastVested;
    mapping(address => uint256) public paidToPerson;
    mapping(address => uint256) public paidToSink;
    mapping(address => bool) public isPerson;
    mapping(address => bool) public isSink;

    constructor(TeamReserve r_, WatchedCoin coin_, address safe_, address holder_) {
        r = r_;
        coin = coin_;
        safe = safe_;
        holder = holder_;
        other = new OtherCoin();
        for (uint256 i; i < 4; ++i) {
            address p = makeAddr(string.concat("hire", vm.toString(i)));
            people.push(p);
            isPerson[p] = true;
        }
        for (uint256 i; i < 2; ++i) {
            address s = makeAddr(string.concat("sink", vm.toString(i)));
            sinks.push(s);
            isSink[s] = true;
        }
        strangers.push(makeAddr("stranger"));
        strangers.push(safe); // The owner, as a caller of what only beneficiaries may do
        inflow = coin.balanceOf(address(r));
    }

    function personCount() external view returns (uint256) {
        return people.length;
    }

    function sinkCount() external view returns (uint256) {
        return sinks.length;
    }

    function now_() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _after() internal {
        uint256 n = r.grantCount();
        for (uint256 i; i < n; ++i) {
            uint256 v = r.vested(i);
            if (v < lastVested[i]) vestedDrops++;
            lastVested[i] = v;
        }
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1, 200 days);
        vm.warp(now_() + dt);
        _after();
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(holder);
        coin.transfer(address(r), amount);
        inflow += amount;
        _after();
    }

    function grant(uint256 who, uint256 amount, uint256 off, bool back) external {
        uint256 free = r.unallocated();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        uint256 start = back ? now_() - bound(off, 0, 90 days) : now_() + bound(off, 0, 365 days);
        vm.prank(safe);
        r.grant(people[who % people.length], amount, start);
        _after();
    }

    function claim(uint256 id, uint256 callerSeed) external {
        uint256 n = r.grantCount();
        if (n == 0) return;
        id = id % n;
        TeamReserve.GrantView memory g = r.grantInfo(id);
        address bad = callerSeed % 2 == 0 ? strangers[callerSeed % strangers.length] : people[callerSeed % people.length];
        if (bad != g.beneficiary) {
            vm.prank(bad);
            try r.claim(id) {
                sneaks++;
            } catch {}
        }
        if (g.claimable == 0) return;
        vm.prank(g.beneficiary);
        try r.claim(id) returns (uint256 got) {
            if (got != g.claimable) missedClaims++;
            claimedOut += got;
            paidToPerson[g.beneficiary] += got;
        } catch {
            missedClaims++;
        }
        _after();
    }

    function revoke(uint256 id) external {
        uint256 n = r.grantCount();
        if (n == 0) return;
        id = id % n;
        TeamReserve.GrantView memory g = r.grantInfo(id);
        vm.prank(safe);
        try r.revoke(id) returns (uint256 back) {
            if (g.revokedAt != 0) sneaks++;
            TeamReserve.GrantView memory h = r.grantInfo(id);
            if (h.vested != g.vested || h.claimable != g.claimable) vestedChanges++;
            if (back != g.unvested) vestedChanges++;
        } catch {
            if (g.revokedAt == 0) missedRevokes++;
        }
        _after();
    }

    function move(uint256 id, uint256 who) external {
        uint256 n = r.grantCount();
        if (n == 0) return;
        id = id % n;
        address b = r.grantInfo(id).beneficiary;
        address to = people[who % people.length];
        // The owner and strangers cannot move it.
        vm.prank(safe);
        try r.moveGrant(id, safe) {
            sneaks++;
        } catch {}
        vm.prank(b);
        r.moveGrant(id, to);
        _after();
    }

    function queue(uint256 to, uint256 amount) external {
        uint256 free = r.unallocated();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(safe);
        r.queueWithdraw(sinks[to % sinks.length], amount);
        _after();
    }

    function cancel(uint256 id) external {
        uint256 n = r.withdrawalCount();
        if (n == 0) return;
        id = id % n;
        (,,,,, TeamReserve.Status st) = r.withdrawalInfo(id);
        vm.prank(safe);
        try r.cancelWithdraw(id) {
            if (st != TeamReserve.Status.Queued) sneaks++;
        } catch {}
        _after();
    }

    function execute(uint256 id, uint256 callerSeed) external {
        uint256 n = r.withdrawalCount();
        if (n == 0) return;
        id = id % n;
        (address to, uint256 amount, uint256 queuedAt, uint256 readyAt, uint256 expiresAt, TeamReserve.Status st) =
            r.withdrawalInfo(id);
        address caller = callerSeed % 3 == 0 ? safe : callerSeed % 3 == 1 ? strangers[0] : people[callerSeed % people.length];
        vm.prank(caller);
        try r.executeWithdraw(id) {
            if (now_() < queuedAt + 30 days || now_() >= queuedAt + 44 days) earlyExecutions++;
            if (st != TeamReserve.Status.Queued) sneaks++;
            executedOut += amount;
            paidToSink[to] += amount;
        } catch {
            if (st == TeamReserve.Status.Queued && now_() >= readyAt && now_() < expiresAt) missedExecutions++;
        }
        _after();
    }

    /// The owner tries to move $BORRO it has no claim to: more than unallocated as a withdrawal or a grant, a sweep of
    /// $BORRO, a claim. Everything must fail. A sweep of another token is fine.
    function ownerGrab(uint256 extra) external {
        uint256 free = r.unallocated();
        extra = bound(extra, 1, 1e30);
        vm.startPrank(safe);
        try r.queueWithdraw(safe, free + extra) {
            sneaks++;
        } catch {}
        try r.grant(safe, free + extra, now_()) {
            sneaks++;
        } catch {}
        try r.sweep(IERC20(address(coin))) {
            sneaks++;
        } catch {}
        uint256 n = r.grantCount();
        for (uint256 i; i < n && i < 8; ++i) {
            try r.claim(i) {
                sneaks++;
            } catch {}
        }
        vm.stopPrank();
        other.mint(address(r), 1e18);
        vm.prank(safe);
        r.sweep(IERC20(address(other)));
        _after();
    }

    /// Strangers and hires try the owner's calls.
    function strangerTries(uint256 seed) external {
        address s = seed % 2 == 0 ? strangers[0] : people[seed % people.length];
        vm.startPrank(s);
        try r.grant(s, 1, now_()) {
            sneaks++;
        } catch {}
        try r.revoke(0) {
            sneaks++;
        } catch {}
        try r.queueWithdraw(s, 1) {
            sneaks++;
        } catch {}
        try r.cancelWithdraw(0) {
            sneaks++;
        } catch {}
        try r.transferOwnership(s) {
            sneaks++;
        } catch {}
        try r.renounceOwnership() {
            sneaks++;
        } catch {}
        vm.stopPrank();
        _after();
    }
}

contract TeamReserveInvariantTest is StdInvariant, TeamReserveBase {
    ReserveHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new ReserveHandler(r, coin, safe, holder);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = ReserveHandler.warp.selector;
        sel[1] = ReserveHandler.fund.selector;
        sel[2] = ReserveHandler.grant.selector;
        sel[3] = ReserveHandler.claim.selector;
        sel[4] = ReserveHandler.revoke.selector;
        sel[5] = ReserveHandler.move.selector;
        sel[6] = ReserveHandler.queue.selector;
        sel[7] = ReserveHandler.cancel.selector;
        sel[8] = ReserveHandler.execute.selector;
        sel[9] = ReserveHandler.ownerGrab.selector;
        sel[10] = ReserveHandler.strangerTries.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_grants_plus_queued_never_exceed_the_balance() public view {
        assertLe(r.totalGranted() + r.totalQueued(), held());
        assertEq(r.unallocated(), held() - r.totalGranted() - r.totalQueued());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totals_match_the_grants_and_withdrawals() public view {
        uint256 n = r.grantCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            TeamReserve.GrantView memory g = r.grantInfo(i);
            sum += g.remaining;
            assertLe(g.claimable, g.remaining);
            assertLe(g.vested, g.amount);
            assertEq(g.claimed + g.remaining, g.revokedAt == 0 ? g.amount : g.vested);
        }
        assertEq(r.totalGranted(), sum);
        (,, uint256[] memory amounts,) = r.pendingWithdrawals();
        uint256 q;
        for (uint256 i; i < amounts.length; ++i) q += amounts[i];
        assertEq(r.totalQueued(), q);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_withdrawals_execute_only_in_their_window() public view {
        assertEq(handler.earlyExecutions(), 0);
        assertEq(handler.missedExecutions(), 0);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_revoke_never_touches_vested() public view {
        assertEq(handler.vestedChanges(), 0);
        assertEq(handler.vestedDrops(), 0);
        assertEq(handler.missedClaims(), 0);
        assertEq(handler.missedRevokes(), 0);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_only_beneficiaries_and_chosen_recipients_receive() public view {
        assertEq(handler.sneaks(), 0);
        uint256 n = coin.paidToCount();
        for (uint256 i; i < n; ++i) {
            address a = coin.paidTo(i);
            assertTrue(handler.isPerson(a) || handler.isSink(a), "someone else received from the reserve");
            if (handler.isPerson(a)) assertEq(coin.paidFromWatched(a), handler.paidToPerson(a));
            else assertEq(coin.paidFromWatched(a), handler.paidToSink(a));
        }
        assertEq(coin.balanceOf(safe), 0, "The owner never received $BORRO it did not queue for itself");
        assertEq(coin.paidOutTotal(), handler.claimedOut() + handler.executedOut());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_every_token_is_accounted_for() public view {
        assertEq(held() + handler.claimedOut() + handler.executedOut(), handler.inflow());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_the_owner_never_changes() public view {
        assertEq(r.owner(), safe);
        assertEq(r.pendingOwner(), address(0));
    }

    /// Whatever happened: years later every grant pays out exactly its final size to its beneficiary, every queued
    /// withdrawal has expired and only cancels, and what is left is all unallocated.
    function afterInvariant() external {
        vm.warp(vm.getBlockTimestamp() + 6 * YEAR);
        uint256 n = r.grantCount();
        for (uint256 i; i < n; ++i) {
            TeamReserve.GrantView memory g = r.grantInfo(i);
            if (g.claimable == 0) continue;
            uint256 before = coin.balanceOf(g.beneficiary);
            vm.prank(g.beneficiary);
            assertEq(r.claim(i), g.remaining);
            assertEq(coin.balanceOf(g.beneficiary), before + g.remaining);
        }
        (uint256[] memory ids,,,) = r.pendingWithdrawals();
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert();
            r.executeWithdraw(ids[i]);
            vm.prank(safe);
            r.cancelWithdraw(ids[i]);
        }
        assertEq(r.totalGranted(), 0);
        assertEq(r.totalQueued(), 0);
        assertEq(r.unallocated(), held());
    }
}
