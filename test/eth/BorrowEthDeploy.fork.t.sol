// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {StockEthOracle} from "../../src/eth/StockEthOracle.sol";
import {EthLoanLiquidator} from "../../src/eth/EthLoanLiquidator.sol";
import {EthLoanRouter} from "../../src/eth/EthLoanRouter.sol";
import {BorrowEthScript} from "../../script/BorrowEth.s.sol";

/// The deploy script, run on a copy of the live chain with its default settings, and then the whole thing used: a
/// lender deposits WETH into bETH, the keeper (an allocator) moves it to NVDA's market within the caps, a borrower
/// opens through the router, and the liquidator closes the loan out when NVDA falls. Set BORRO_FORK_RPC to run.
contract BorrowEthDeployForkTest is Test {
    using MarketParamsLib for MarketParams;

    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    bytes32 constant NVDA_DESK = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;

    bool forked;
    BorrowEthScript.Out o;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, 82_091_631);
        forked = true;
        o = new BorrowEthScript().run();
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _market(StockEthOracle oracle, address vault) internal view returns (MarketParams memory m) {
        m = MarketParams({loanToken: WETH, collateralToken: vault, oracle: address(oracle), irm: o.liq.irm(), lltv: 0.385e18});
    }

    function test_deployThenUse() public onFork {
        IVaultV2 v = IVaultV2(o.vault);
        // Handed over: the Safe owns, curates and guards bETH; the keeper allocates; the deployer keeps nothing.
        assertEq(v.owner(), SAFE);
        assertEq(v.curator(), SAFE);
        assertTrue(v.isSentinel(SAFE));
        assertTrue(v.isAllocator(SAFE));
        assertTrue(v.isAllocator(KEEPER));
        assertFalse(v.isAllocator(address(this)));
        assertEq(v.timelock(IVaultV2.increaseAbsoluteCap.selector), 259_200);
        assertEq(v.performanceFee(), 0.1e18);
        assertEq(v.performanceFeeRecipient(), SAFE);
        assertEq(o.router.pendingOwner(), SAFE, "the Safe accepts the router");
        assertEq(IERC20(WETH).balanceOf(o.vault), 0, "no dead deposit without the owner's yes");
        assertEq(v.absoluteCap(keccak256(abi.encode("this", o.adapter))), 10 ether);

        // NVDA's market, from the oracle the script made for it.
        address bnvda = 0x508E23274C39C60c345e35B1f0188bE180717CB9;
        StockEthOracle nvdaOracle = _findOracle(bnvda);
        MarketParams memory m = _market(nvdaOracle, bnvda);
        assertTrue(o.router.listed(Id.unwrap(m.id())));
        assertEq(v.absoluteCap(keccak256(abi.encode("this/marketParams", o.adapter, m))), 2 ether);

        // A lender deposits 5 WETH; it lands in SPY's market, and the keeper moves 2 to NVDA's (its cap) but not 2.1.
        address lender = makeAddr("lender");
        deal(WETH, lender, 5 ether);
        vm.startPrank(lender);
        IERC20(WETH).approve(o.vault, 5 ether);
        v.deposit(5 ether, lender);
        vm.stopPrank();
        bytes memory spyData = abi.encode(_market(_findOracle(0xC3ED4a5A7dB4102F4Ed37Af26ef0d3f21e2360c1), 0xC3ED4a5A7dB4102F4Ed37Af26ef0d3f21e2360c1));
        vm.startPrank(KEEPER);
        v.deallocate(o.adapter, spyData, 5 ether);
        vm.expectRevert();
        v.allocate(o.adapter, abi.encode(m), 2.1 ether);
        v.allocate(o.adapter, abi.encode(m), 2 ether);
        vm.stopPrank();

        // A borrower opens through the router: 20 NVDA in, ETH out.
        address bob = makeAddr("bob-the-borrower");
        deal(NVDA, bob, 20e18);
        vm.startPrank(bob);
        IERC20(NVDA).approve(address(o.router), 20e18);
        MORPHO.setAuthorization(address(o.router), true);
        uint256 worth = 20e18 * nvdaOracle.borrowPrice() / 1e36;
        uint256 ask = worth * 0.385e18 / 1e18 * 7_400 / 10_000;
        o.router.open(EthLoanRouter.Open({market: m, stockIn: 20e18, sharesIn: 0, minShares: 0, borrow: ask, deadline: vm.getBlockTimestamp() + 600}));
        vm.stopPrank();
        assertEq(bob.balance, ask);

        // NVDA falls 40%: the keeper liquidates through the deployed liquidator, with no money of its own.
        (, int256 s,,,) = StockEthOracle(nvdaOracle).stockFeed().latestRoundData();
        uint256 t = vm.getBlockTimestamp();
        vm.mockCall(NVDA_FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), s * 60 / 100, t, t, uint80(1)));
        Position memory p = MORPHO.position(m.id(), bob);
        vm.prank(KEEPER);
        uint256 profit = o.liq.liquidate(m, bob, 0, p.borrowShares, NVDA_DESK, 0);
        assertGt(profit, 0);
        assertEq(MORPHO.position(m.id(), bob).borrowShares, 0);
        assertEq(IERC20(USDG).balanceOf(KEEPER) >= profit, true);
        console2.log("deployed system: lent, allocated, borrowed, liquidated; keeper profit (USDG wei):", profit);
        // The lender can still leave with what is idle (here, nothing is lent in SPY's market any more; NVDA's loan
        // is repaid, so the keeper can bring it back).
        vm.prank(KEEPER);
        v.deallocate(o.adapter, abi.encode(m), 2 ether);
        vm.prank(lender);
        v.withdraw(1 ether, lender, lender);
        assertEq(IERC20(WETH).balanceOf(lender), 1 ether);
    }

    function _findOracle(address vault) internal view returns (StockEthOracle) {
        for (uint256 i; i < o.oracles.length; i++) {
            if (o.oracles[i].collateral() == vault) return o.oracles[i];
        }
        revert("no oracle for the vault");
    }

    /// The deployed oracles price nothing for borrowing on a Saturday, and name the deployed liquidator.
    function test_noWeekendBorrowingOnTheDeployedMarkets() public onFork {
        StockEthOracle nvdaOracle = _findOracle(0x508E23274C39C60c345e35B1f0188bE180717CB9);
        vm.warp(1791648000); // Saturday
        vm.mockCall(
            address(nvdaOracle.ethFeed()),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(2700e8), uint256(1791648000), uint256(1791648000), uint80(1))
        );
        vm.expectPartialRevert(StockEthOracle.MarketClosed.selector);
        nvdaOracle.borrowPrice();
        assertEq(nvdaOracle.liquidator(), address(o.liq));
    }
}
