// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {BorroSetup} from "./BorroSetup.sol";
import {BorroBuilders} from "../src/BorroBuilders.sol";

/// The referral program on a fork of Robinhood Chain: register a code, deposit a stock and USDG to Borro's vaults
/// through BorroBuilders with that code, end with the caller owning the vault shares, the deposit announced, and the
/// contract holding nothing.
/// Runs against a fork: BORRO_FORK_RPC=<rpc> forge test --match-contract BorroBuildersForkTest
contract BorroBuildersForkTest is BorroSetup {
    BorroBuilders builders;
    bytes32 constant ROUTE = bytes32("route");
    bytes32 constant GREENWOOD = bytes32("greenwood");

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        address[] memory list = new address[](stocks.length + 1);
        for (uint256 i; i < stocks.length; i++) list[i] = desk[stocks[i].symbol].vault;
        list[stocks.length] = address(bUsdg);
        builders = new BorroBuilders(owner, list);
        vm.prank(ann);
        builders.register(ROUTE);
    }

    /// Deposits `amount` of `vault`'s asset for `who` through the program with `code`, as the site would.
    function _deposit(address vault, address who, uint256 amount, bytes32 code, uint256 minShares)
        internal
        returns (uint256 shares)
    {
        address asset = IVaultV2(vault).asset();
        deal(asset, who, IERC20(asset).balanceOf(who) + amount);
        vm.startPrank(who);
        IERC20(asset).approve(address(builders), amount);
        shares = builders.deposit(vault, amount, code, minShares);
        vm.stopPrank();
    }

    function _holdsNothing(address vault) internal view {
        assertEq(IERC20(IVaultV2(vault).asset()).balanceOf(address(builders)), 0, "holds none of the asset");
        assertEq(IERC20(vault).balanceOf(address(builders)), 0, "holds no vault shares");
    }

    function test_register_is_first_come_and_only_the_payee_moves_a_code() public onFork {
        assertEq(builders.builders(ROUTE), ann, "ann holds route");
        vm.expectEmit(true, true, true, true);
        emit BorroBuilders.Registered(GREENWOOD, bob);
        vm.prank(bob);
        builders.register(GREENWOOD);
        assertEq(builders.builders(GREENWOOD), bob);

        // Taken: by someone else, and by the holder again.
        vm.prank(eve);
        vm.expectRevert(BorroBuilders.Taken.selector);
        builders.register(ROUTE);
        vm.prank(ann);
        vm.expectRevert(BorroBuilders.Taken.selector);
        builders.register(ROUTE);
        // Code 0 is not a code.
        vm.prank(eve);
        vm.expectRevert(BorroBuilders.BadCode.selector);
        builders.register(bytes32(0));

        // Only the payee moves a code, and never to nobody.
        vm.prank(eve);
        vm.expectRevert(BorroBuilders.NotPayee.selector);
        builders.setPayee(ROUTE, eve);
        vm.prank(ann);
        vm.expectRevert(BorroBuilders.BadPayee.selector);
        builders.setPayee(ROUTE, address(0));
        vm.expectEmit(true, true, true, true);
        emit BorroBuilders.Registered(ROUTE, carl);
        vm.prank(ann);
        builders.setPayee(ROUTE, carl);
        assertEq(builders.builders(ROUTE), carl, "route is carl's now");
        vm.prank(ann);
        vm.expectRevert(BorroBuilders.NotPayee.selector);
        builders.setPayee(ROUTE, ann); // ann no longer holds it
    }

    function test_deposit_stock_in_the_callers_name() public onFork {
        address vault = desk["NVDA"].vault;
        uint256 amount = (100e6 * 1e20) / _price("NVDA"); // about $100 of NVDA
        uint256 expected = IVaultV2(vault).previewDeposit(amount);
        deal(desk["NVDA"].token, bob, amount);
        vm.startPrank(bob);
        IERC20(desk["NVDA"].token).approve(address(builders), amount);
        vm.expectEmit(true, true, true, true);
        emit BorroBuilders.Referred(ROUTE, bob, vault, amount, expected);
        uint256 shares = builders.deposit(vault, amount, ROUTE, expected);
        vm.stopPrank();

        assertEq(shares, expected, "the shares previewed");
        assertGt(shares, 0, "bob owns vault shares");
        assertEq(IVaultV2(vault).balanceOf(bob), shares, "the shares are bob's");
        assertApproxEqRel(IVaultV2(vault).previewRedeem(shares), amount, 1e15, "worth the stock lent");
        assertEq(IERC20(desk["NVDA"].token).balanceOf(bob), 0, "all of it was lent");
        _holdsNothing(vault);
    }

    function test_deposit_every_stock() public onFork {
        for (uint256 i; i < stocks.length; i++) {
            string memory sym = stocks[i].symbol;
            uint256 amount = (50e6 * 1e20) / _price(sym); // about $50
            uint256 shares = _deposit(desk[sym].vault, carl, amount, ROUTE, 0);
            assertGt(shares, 0, sym);
            assertEq(IVaultV2(desk[sym].vault).balanceOf(carl), shares, string.concat(sym, ": the shares are carl's"));
            _holdsNothing(desk[sym].vault);
        }
    }

    function test_deposit_usdg_in_the_callers_name() public onFork {
        uint256 amount = 250e6;
        uint256 expected = bUsdg.previewDeposit(amount);
        deal(address(usdg), carl, amount);
        vm.startPrank(carl);
        usdg.approve(address(builders), amount);
        vm.expectEmit(true, true, true, true);
        emit BorroBuilders.Referred(ROUTE, carl, address(bUsdg), amount, expected);
        uint256 shares = builders.deposit(address(bUsdg), amount, ROUTE, expected);
        vm.stopPrank();

        assertEq(shares, expected, "the shares previewed");
        assertEq(bUsdg.balanceOf(carl), shares, "the shares are carl's");
        assertApproxEqAbs(bUsdg.previewRedeem(shares), amount, 1, "worth the USDG lent");
        assertEq(usdg.balanceOf(carl), 0, "all of it was lent");
        _holdsNothing(address(bUsdg));
    }

    function test_min_shares_is_enforced() public onFork {
        address vault = desk["QQQ"].vault;
        uint256 amount = (100e6 * 1e20) / _price("QQQ");
        uint256 expected = IVaultV2(vault).previewDeposit(amount);
        deal(desk["QQQ"].token, bob, amount);
        vm.startPrank(bob);
        IERC20(desk["QQQ"].token).approve(address(builders), amount);
        vm.expectRevert(abi.encodeWithSelector(BorroBuilders.TooFewShares.selector, expected, expected + 1));
        builders.deposit(vault, amount, ROUTE, expected + 1);
        vm.stopPrank();
        assertEq(IERC20(desk["QQQ"].token).balanceOf(bob), amount, "nothing was taken");
        _holdsNothing(vault);
    }

    function test_refuses_unlisted_vaults_unregistered_codes_and_nothing() public onFork {
        uint256 amount = 1e15;
        deal(desk["NVDA"].token, bob, amount);
        vm.startPrank(bob);
        IERC20(desk["NVDA"].token).approve(address(builders), amount);
        vm.expectRevert(BorroBuilders.BadVault.selector);
        builders.deposit(eve, amount, ROUTE, 0); // not a vault
        vm.expectRevert(BorroBuilders.BadVault.selector);
        builders.deposit(address(held), amount, ROUTE, 0); // a real vault, not one of Borro's
        vm.expectRevert(BorroBuilders.NotRegistered.selector);
        builders.deposit(desk["NVDA"].vault, amount, GREENWOOD, 0); // nobody registered it
        vm.expectRevert(BorroBuilders.NotRegistered.selector);
        builders.deposit(desk["NVDA"].vault, amount, bytes32(0), 0);
        vm.expectRevert(BorroBuilders.Nothing.selector);
        builders.deposit(desk["NVDA"].vault, 0, ROUTE, 0);
        vm.stopPrank();
        assertEq(IERC20(desk["NVDA"].token).balanceOf(bob), amount, "nothing was taken");
    }

    function test_only_the_owner_lists_vaults_and_sweeps() public onFork {
        address vault = desk["NVDA"].vault;
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        builders.setVault(vault, false);
        vm.prank(owner);
        builders.setVault(vault, false);
        assertFalse(builders.vaults(vault));
        deal(desk["NVDA"].token, bob, 1e15);
        vm.startPrank(bob);
        IERC20(desk["NVDA"].token).approve(address(builders), 1e15);
        vm.expectRevert(BorroBuilders.BadVault.selector);
        builders.deposit(vault, 1e15, ROUTE, 0);
        vm.stopPrank();
        vm.prank(owner);
        builders.setVault(vault, true);
        assertTrue(builders.vaults(vault));
        vm.prank(owner);
        vm.expectRevert(); // a token, not a vault: it has no asset() to answer
        builders.setVault(address(usdg), true);

        // A mistake sent here is the owner's to sweep out, and nobody else's.
        deal(address(usdg), address(builders), 1_000e6);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        builders.sweep(usdg, eve);
        vm.prank(owner);
        builders.sweep(usdg, owner);
        assertEq(usdg.balanceOf(address(builders)), 0);
        assertEq(usdg.balanceOf(owner), 1_000e6);
    }
}
