// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {BorroSetup} from "./BorroSetup.sol";
import {BorroSwap} from "../src/BorroSwap.sol";
import {PairRouter, IShortDesks} from "../src/PairRouter.sol";

/// The pair trade on a fork of Robinhood Chain: buy and lend the long leg through PairRouter, open the short leg on
/// BorroShort, end with the caller owning vault shares and an open short, and the router holding nothing.
/// Runs against a fork: BORRO_FORK_RPC=<rpc> forge test --match-contract PairRouterForkTest
contract PairRouterForkTest is BorroSetup {
    PairRouter pair;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        address[] memory list = new address[](stocks.length);
        for (uint256 i; i < stocks.length; i++) list[i] = desk[stocks[i].symbol].vault;
        pair = new PairRouter(IPoolManager(POOL_MANAGER), usdg, IShortDesks(address(short)), owner, list);
    }

    /// Buys `amount` of `sym` for `who` through the router at the quoted cost plus 1%, as the site would.
    function _buyAndLend(string memory sym, address who, uint256 amount)
        internal
        returns (uint256 cost, uint256 vaultShares, uint256 maxCost)
    {
        bytes32 id = desk[sym].marketId;
        uint256 quote = _quote(id, amount, true);
        maxCost = (quote * 101) / 100;
        deal(address(usdg), who, usdg.balanceOf(who) + maxCost);
        vm.startPrank(who);
        usdg.approve(address(pair), maxCost);
        (cost, vaultShares) = pair.buyAndLend(id, desk[sym].vault, amount, maxCost, 0, DL);
        vm.stopPrank();
    }

    function _routerIsEmpty(string memory sym) internal view {
        assertEq(usdg.balanceOf(address(pair)), 0, "router holds no USDG");
        assertEq(IERC20(desk[sym].token).balanceOf(address(pair)), 0, "router holds no stock");
        assertEq(IERC20(desk[sym].vault).balanceOf(address(pair)), 0, "router holds no vault shares");
    }

    function test_long_nvda_short_tsla() public onFork {
        uint256 amount = (100e6 * 1e20) / _price("NVDA"); // about $100 of NVDA
        uint256 before = usdg.balanceOf(bob);
        (uint256 cost, uint256 vaultShares, uint256 maxCost) = _buyAndLend("NVDA", bob, amount);
        assertGt(vaultShares, 0, "bob owns vault shares");
        assertEq(IVaultV2(desk["NVDA"].vault).balanceOf(bob), vaultShares, "the shares are bob's");
        assertApproxEqRel(IVaultV2(desk["NVDA"].vault).previewRedeem(vaultShares), amount, 1e15, "worth the stock bought");
        assertEq(usdg.balanceOf(bob), before + maxCost - cost, "bob paid exactly the cost; the rest came back");
        _routerIsEmpty("NVDA");

        // The short leg: bob's own open on BorroShort.
        bytes32 tsla = desk["TSLA"].marketId;
        uint256 shortAmount = (60e6 * 1e20) / _price("TSLA"); // about $60 of TSLA on a $100 deposit
        _lend("TSLA", ann, shortAmount * 3); // someone has to have lent the TSLA bob borrows
        uint256 q = _quote(tsla, shortAmount, false);
        deal(address(usdg), bob, usdg.balanceOf(bob) + 100e6);
        vm.startPrank(bob);
        usdg.approve(address(short), 100e6);
        short.open(tsla, 100e6, shortAmount, ((q - (q * OPEN_FEE_BPS) / 10_000) * 995) / 1000, DL);
        vm.stopPrank();
        (uint256 shares,,,,) = short.tabOf(bob, tsla);
        assertGt(shares, 0, "bob has an open TSLA short");
        assertEq(IVaultV2(desk["NVDA"].vault).balanceOf(bob), vaultShares, "and still owns the NVDA leg");
    }

    function test_two_hop_and_v3_stocks_buy_and_lend() public onFork {
        for (uint256 i; i < stocks.length; i++) {
            string memory sym = stocks[i].symbol;
            uint256 amount = (50e6 * 1e20) / _price(sym); // about $50
            (uint256 cost, uint256 vaultShares,) = _buyAndLend(sym, carl, amount);
            assertGt(vaultShares, 0, sym);
            // The cost sits near the feed value of what was bought: within 5% (pool fees and depth).
            uint256 fair = _worth(sym, amount);
            assertLt(cost, (fair * 105) / 100, string.concat(sym, ": cost near the feed value"));
            _routerIsEmpty(sym);
        }
    }

    function test_max_cost_is_enforced() public onFork {
        bytes32 id = desk["SPY"].marketId;
        uint256 amount = (100e6 * 1e20) / _price("SPY");
        uint256 quote = _quote(id, amount, true);
        deal(address(usdg), bob, quote);
        vm.startPrank(bob);
        usdg.approve(address(pair), quote - 1);
        vm.expectRevert(); // BorroSwap.TooMuch: the purchase costs more than bob allowed
        pair.buyAndLend(id, desk["SPY"].vault, amount, quote - 1, 0, DL);
        vm.stopPrank();
        assertEq(usdg.balanceOf(bob), quote, "nothing was taken");
    }

    function test_donated_usdg_is_never_spent_for_a_caller() public onFork {
        bytes32 id = desk["SPY"].marketId;
        uint256 amount = (100e6 * 1e20) / _price("SPY");
        uint256 quote = _quote(id, amount, true);
        deal(address(usdg), address(pair), 1_000e6); // sent here by mistake
        deal(address(usdg), bob, quote);
        vm.startPrank(bob);
        usdg.approve(address(pair), quote / 2);
        vm.expectRevert(abi.encodeWithSelector(BorroSwap.TooMuch.selector, quote, quote / 2));
        pair.buyAndLend(id, desk["SPY"].vault, amount, quote / 2, 0, DL);
        vm.stopPrank();
        // The owner sweeps the mistake out.
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        pair.sweep(usdg, eve);
        vm.prank(owner);
        pair.sweep(usdg, owner);
        assertEq(usdg.balanceOf(address(pair)), 0);
        assertEq(usdg.balanceOf(owner), 1_000e6);
    }

    function test_min_vault_shares_is_enforced() public onFork {
        bytes32 id = desk["QQQ"].marketId;
        uint256 amount = (100e6 * 1e20) / _price("QQQ");
        uint256 maxCost = (_quote(id, amount, true) * 101) / 100;
        deal(address(usdg), bob, maxCost);
        vm.startPrank(bob);
        usdg.approve(address(pair), maxCost);
        vm.expectRevert(); // TooFewShares
        pair.buyAndLend(id, desk["QQQ"].vault, amount, maxCost, type(uint256).max, DL);
        vm.stopPrank();
    }

    function test_refuses_unlisted_or_mismatched_vaults_and_late_calls() public onFork {
        bytes32 nvda = desk["NVDA"].marketId;
        uint256 amount = 1e15;
        vm.startPrank(bob);
        vm.expectRevert(PairRouter.BadVault.selector);
        pair.buyAndLend(nvda, eve, amount, 1e6, 0, DL); // not a listed vault
        vm.expectRevert(PairRouter.BadVault.selector);
        pair.buyAndLend(nvda, desk["TSLA"].vault, amount, 1e6, 0, DL); // a listed vault, for another stock
        vm.expectRevert(PairRouter.Expired.selector);
        pair.buyAndLend(nvda, desk["NVDA"].vault, amount, 1e6, 0, block.timestamp - 1);
        vm.expectRevert(PairRouter.Nothing.selector);
        pair.buyAndLend(nvda, desk["NVDA"].vault, 0, 1e6, 0, DL);
        vm.expectRevert(PairRouter.NotListed.selector);
        pair.buyAndLend(bytes32(uint256(1)), desk["NVDA"].vault, amount, 1e6, 0, DL); // no such desk
        vm.stopPrank();
    }

    function test_only_the_owner_lists_vaults() public onFork {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        pair.setVault(desk["NVDA"].vault, false);
        vm.prank(owner);
        pair.setVault(desk["NVDA"].vault, false);
        assertFalse(pair.vaults(desk["NVDA"].vault));
        vm.prank(bob);
        vm.expectRevert(PairRouter.BadVault.selector);
        pair.buyAndLend(desk["NVDA"].marketId, desk["NVDA"].vault, 1e15, 1e6, 0, DL);
    }
}
