// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GatedCoin} from "../../src/coins/GatedCoin.sol";

contract PlainCoin is ERC20 {
    constructor() ERC20("PLAIN", "PLAIN") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// A coin that keeps 1% of every transfer: it cannot back GatedCoin one for one, so wrapping refuses it.
contract TaxedCoin is PlainCoin {
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            super._update(from, address(0xdead), value / 100);
            value -= value / 100;
        }
        super._update(from, to, value);
    }
}

/// GatedCoin, and the loan cap's working: at the cap, a liquidation's sale moves the locked pool by about 2%.
contract CoinLoansUnitTest is Test {
    PlainCoin coin = new PlainCoin();
    address morpho = makeAddr("morpho");
    GatedCoin g;
    address alice = makeAddr("alice");

    function setUp() public {
        g = new GatedCoin(IERC20(address(coin)), morpho, "Borro loan collateral PLAIN", "lPLAIN"); // this test is the gate
        coin.mint(address(this), 1_000e18);
        coin.approve(address(g), type(uint256).max);
    }

    function test_gate() public {
        g.wrap(100e18, address(this));
        g.transfer(morpho, 10e18); // the gate to Morpho: allowed
        g.transfer(alice, 50e18);
        vm.prank(alice);
        vm.expectRevert(GatedCoin.OnlyGateToMorpho.selector);
        g.transfer(morpho, 1);
        vm.prank(alice);
        g.approve(morpho, 1);
        vm.prank(morpho);
        vm.expectRevert(GatedCoin.OnlyGateToMorpho.selector);
        g.transferFrom(alice, morpho, 1);
        vm.prank(alice);
        vm.expectRevert(GatedCoin.OnlyGate.selector);
        g.wrap(1, alice);
        vm.prank(morpho);
        g.transfer(alice, 10e18); // out of Morpho to anyone: allowed
        vm.prank(alice);
        g.unwrap(60e18, alice);
        assertEq(coin.balanceOf(alice), 60e18);
        assertEq(g.name(), "Borro loan collateral PLAIN");
    }

    function test_a_coin_that_takes_a_cut_on_transfer_cannot_be_wrapped() public {
        TaxedCoin t = new TaxedCoin();
        GatedCoin tg = new GatedCoin(IERC20(address(t)), morpho, "x", "x");
        t.mint(address(this), 100e18);
        t.approve(address(tg), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GatedCoin.NotReceived.selector, 99e18, 100e18));
        tg.wrap(100e18, address(this));
    }

    function testFuzz_always_backed_one_for_one(uint96[6] memory amounts, uint8 seed) public {
        for (uint256 i; i < 6; i++) {
            uint256 a = bound(amounts[i], 0, 100e18);
            uint256 op = (uint256(seed) + i) % 3;
            if (op == 0 && coin.balanceOf(address(this)) >= a) g.wrap(a, i % 2 == 0 ? address(this) : alice);
            else if (op == 1 && g.balanceOf(address(this)) >= a) g.unwrap(a, address(this));
            else if (op == 2 && g.balanceOf(alice) >= a) {
                vm.prank(alice);
                g.unwrap(a, alice);
            }
            assertEq(coin.balanceOf(address(g)), g.totalSupply());
        }
    }

    /// The cap's working, on a full-range constant-product pool (the locked Pons position). A loan opened at half the
    /// LLTV is liquidated when the price has halved; there the pool's coin side is sqrt(2) times larger, and Morpho
    /// hands the liquidator collateral worth 1.15 times the debt. With all loans at the cap (1.2% of the coin side in
    /// dollars at the opening price) liquidated at once, the coins sold are at most 2% of the pool's coin side: the
    /// sale moves the price about 4% and costs about 2% on average, well inside the 15% bonus after Pons's tax.
    function testFuzz_at_the_cap_a_liquidation_sells_at_most_2pct_of_the_coin_side(uint128 coinSide, uint64 priceE18) public pure {
        uint256 y = bound(coinSide, 1e24, 1e30); // coins in the locked position's coin side, at the opening price
        uint256 p = bound(priceE18, 1e6, 1e24); // dollars a coin, 18 decimals
        uint256 debt = (y * p / 1e18) * 120 / 10_000; // dollars (18 decimals): the cap
        uint256 pLiq = p / 2; // liquidation price for a loan opened at half the LLTV
        uint256 seized = Math.mulDiv(debt * 115 / 100, 1e18, pLiq); // coins handed to the liquidator
        uint256 yLiq = y * 14_142 / 10_000; // the coin side after the price halved: times sqrt(2)
        assertLe(seized * 10_000, yLiq * 200 + 1e18, "at most 2% of the coin side");
        // Selling s into a constant-product side y moves the price by (y / (y + s))^2.
        uint256 after_ = Math.mulDiv(Math.mulDiv(yLiq, 1e18, yLiq + seized), Math.mulDiv(yLiq, 1e18, yLiq + seized), 1e18);
        assertGe(after_, 0.96e18, "the sale moves the price at most about 4%");
    }
}
