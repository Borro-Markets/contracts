// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMorpho, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {BorroSwap} from "../src/BorroSwap.sol";
import {LeverRouter, ILeverDesks, ILeverMarkets} from "../src/LeverRouter.sol";

interface IQuote {
    function quoteBuy(bytes32 id, uint256 amount) external;
}

/// LeverRouter against the LIVE Borro on a fork: the live BorroShort's routes, the live BorroRouter's list, the live
/// stock vaults and USDG markets (which today hold the Hoard Safe's seed, about 571 USDG each).
/// BORRO_FORK_RPC=<rpc> forge test --match-contract LeverRouterLiveForkTest
contract LeverRouterLiveForkTest is Test {
    using stdJson for string;

    IMorpho constant morpho = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    IERC20 constant usdg = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    LeverRouter lever;
    address short;
    bytes32 desk;
    MarketParams market;
    address ann = makeAddr("ann");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        short = json.readAddress(".short");
        address markets = json.readAddress(".router");
        lever = new LeverRouter(morpho, IPoolManager(POOL_MANAGER), usdg, ILeverDesks(short), ILeverMarkets(markets), makeAddr("safe"));
        desk = json.readBytes32(".desks[2].marketId"); // NVDA
        market = morpho.idToMarketParams(Id.wrap(json.readBytes32(".desks[2].usdgMarketId")));
    }

    function _quoteBuy(uint256 amount) internal returns (uint256 out) {
        (bool ok, bytes memory err) = short.call(abi.encodeCall(IQuote.quoteBuy, (desk, amount)));
        require(!ok, "quote did not revert");
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        require(sel == BorroSwap.QuoteResult.selector, "unexpected revert");
        assembly { out := mload(add(err, 36)) }
    }

    function test_live_open_1_5x_nvda_and_close() public {
        if (!forked) return;
        (, int256 price,,,) = IFeed(NVDA_FEED).latestRoundData();
        uint256 margin = 400e6;
        uint256 debt = 200e6; // 1.5x, within the ~571 USDG the live NVDA USDG market can lend today
        uint256 spend = margin + debt;
        uint256 a0 = (spend * 1e20) / uint256(price);
        uint256 amount = (((a0 * spend) / _quoteBuy(a0)) * 995) / 1000;
        deal(address(usdg), ann, margin);
        vm.startPrank(ann);
        morpho.setAuthorization(address(lever), true);
        usdg.approve(address(lever), margin);
        uint256 g0 = gasleft();
        lever.open(LeverRouter.Open({desk: desk, market: market, margin: margin, stockAmount: amount, maxCost: spend, debt: debt, minShares: 0, deadline: block.timestamp + 600}));
        emit log_named_uint("gas: open", g0 - gasleft());
        vm.stopPrank();
        Position memory p = morpho.position(Id.wrap(keccak256(abi.encode(market))), ann);
        uint256 worth = (uint256(p.collateral) * IOracle(market.oracle).price()) / 1e36;
        assertGt(worth, (spend * 97) / 100, "about 600 USDG of NVDA vault shares posted");
        assertGt(p.borrowShares, 0, "200 USDG borrowed in ann's name");
        assertEq(usdg.balanceOf(address(lever)), 0);

        vm.prank(ann);
        uint256 g1 = gasleft();
        uint256 back = lever.close(LeverRouter.Close({desk: desk, market: market, shareBps: 10_000, minOut: 0, deadline: block.timestamp + 600}));
        emit log_named_uint("gas: close", g1 - gasleft());
        assertGt(back, (margin * 97) / 100, "the margin less the round trip's cost came back");
        p = morpho.position(Id.wrap(keccak256(abi.encode(market))), ann);
        assertEq(p.collateral, 0);
        assertEq(p.borrowShares, 0);
        assertEq(usdg.balanceOf(address(lever)), 0);
    }
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
