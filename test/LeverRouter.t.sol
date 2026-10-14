// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams, Id, Authorization, Signature} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {LeverRouter, ILeverDesks, ILeverMarkets} from "../src/LeverRouter.sol";

contract Tok is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// Just enough of Morpho for the router's guards: authorizations (direct and by signature), and a flash loan that
/// calls back the caller.
contract MiniMorpho {
    mapping(address => mapping(address => bool)) public isAuthorized;
    bool public sigWorks = true;

    function setAuthorization(address who, bool on) external {
        isAuthorized[msg.sender][who] = on;
    }

    function setAuthorizationWithSig(Authorization calldata a, Signature calldata) external {
        require(sigWorks, "bad sig");
        isAuthorized[a.authorizer][a.authorized] = a.isAuthorized;
    }

    function setSigWorks(bool w) external {
        sigWorks = w;
    }

    function flashLoan(address, uint256 assets, bytes calldata data) external {
        LeverRouter(msg.sender).onMorphoFlashLoan(assets, data);
    }
}

contract MiniDesks is ILeverDesks {
    address stock;

    constructor(address s) {
        stock = s;
    }

    function deskOf(bytes32) external view returns (MarketParams memory m, PoolKey[] memory route, address v3Pool, bool, address) {
        m.loanToken = stock;
        route = new PoolKey[](0);
        v3Pool = address(0xBEEF);
        return (m, route, v3Pool, false, address(0));
    }
}

contract MiniMarkets is ILeverMarkets {
    mapping(bytes32 => bool) public listed;

    function list(bytes32 id) external {
        listed[id] = true;
    }
}

contract MiniVault {
    address public asset;

    constructor(address a) {
        asset = a;
    }
}

/// The router's guards without a fork. The money paths (flash loan, swap, vault, Morpho) are tested on a fork of
/// the live chain in LeverRouter.fork.t.sol and LeverRouterLive.fork.t.sol.
contract LeverRouterTest is Test {
    using MarketParamsLib for MarketParams;

    MiniMorpho morpho;
    MiniMarkets markets;
    LeverRouter lever;
    Tok usdg;
    Tok stock;
    MarketParams market;
    address owner = makeAddr("owner");
    address ann = makeAddr("ann");
    address eve = makeAddr("eve");

    function setUp() public {
        morpho = new MiniMorpho();
        usdg = new Tok("USDG");
        stock = new Tok("NVDA");
        markets = new MiniMarkets();
        MiniVault vault = new MiniVault(address(stock));
        market = MarketParams({loanToken: address(usdg), collateralToken: address(vault), oracle: address(1), irm: address(2), lltv: 0.625e18});
        markets.list(Id.unwrap(market.id()));
        lever = new LeverRouter(IMorpho(address(morpho)), IPoolManager(address(0x4)), IERC20(address(usdg)), new MiniDesks(address(stock)), markets, owner);
    }

    function _open() internal view returns (LeverRouter.Open memory) {
        return LeverRouter.Open({desk: bytes32(uint256(1)), market: market, margin: 100e6, stockAmount: 1e18, maxCost: 150e6, debt: 50e6, minShares: 0, deadline: block.timestamp + 60});
    }

    function _close(uint256 bps) internal view returns (LeverRouter.Close memory) {
        return LeverRouter.Close({desk: bytes32(uint256(1)), market: market, shareBps: bps, minOut: 0, deadline: block.timestamp + 60});
    }

    function test_open_needs_the_callers_own_authorization() public {
        vm.prank(ann);
        vm.expectRevert(LeverRouter.NotAuthorized.selector);
        lever.open(_open());
    }

    function test_open_with_sig_only_for_the_signer_and_never_a_revoke() public {
        Authorization memory a = Authorization({authorizer: ann, authorized: address(lever), isAuthorized: true, nonce: 0, deadline: type(uint256).max});
        Signature memory s;
        vm.prank(eve);
        vm.expectRevert(LeverRouter.BadSignature.selector);
        lever.openWithSig(_open(), a, s);
        a.authorized = eve;
        vm.prank(ann);
        vm.expectRevert(LeverRouter.BadSignature.selector);
        lever.openWithSig(_open(), a, s);
        a.authorized = address(lever);
        a.isAuthorized = false;
        vm.prank(ann);
        vm.expectRevert(LeverRouter.BadSignature.selector);
        lever.openWithSig(_open(), a, s);
        // A signature Morpho refuses leaves no authorization: the open stops there.
        a.isAuthorized = true;
        morpho.setSigWorks(false);
        vm.prank(ann);
        vm.expectRevert(LeverRouter.NotAuthorized.selector);
        lever.openWithSig(_open(), a, s);
    }

    function test_open_guards() public {
        vm.prank(ann);
        morpho.setAuthorization(address(lever), true);
        LeverRouter.Open memory o = _open();
        o.deadline = block.timestamp - 1;
        vm.prank(ann);
        vm.expectRevert(LeverRouter.Expired.selector);
        lever.open(o);
        for (uint256 i; i < 3; i++) {
            o = _open();
            if (i == 0) o.margin = 0;
            if (i == 1) o.stockAmount = 0;
            if (i == 2) o.debt = 0;
            vm.prank(ann);
            vm.expectRevert(LeverRouter.Nothing.selector);
            lever.open(o);
        }
        o = _open();
        o.market.lltv = 0.77e18; // not on the list
        vm.prank(ann);
        vm.expectRevert(LeverRouter.BadMarket.selector);
        lever.open(o);
        o = _open();
        o.market.loanToken = address(stock); // not a USDG market
        vm.prank(ann);
        vm.expectRevert(LeverRouter.BadMarket.selector);
        lever.open(o);
    }

    function test_only_the_owner_pauses_and_only_opens() public {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        lever.setOpensPaused(true);
        vm.prank(owner);
        lever.setOpensPaused(true);
        vm.prank(ann);
        morpho.setAuthorization(address(lever), true);
        vm.prank(ann);
        vm.expectRevert(LeverRouter.Paused.selector);
        lever.open(_open());
        // A close is not stopped by the pause: here it stops only because ann has no position.
        vm.prank(ann);
        vm.expectRevert();
        lever.close(_close(10_000));
    }

    function test_close_guards() public {
        vm.prank(ann);
        vm.expectRevert(LeverRouter.Nothing.selector);
        lever.close(_close(0));
        vm.prank(ann);
        vm.expectRevert(LeverRouter.Nothing.selector);
        lever.close(_close(10_001));
        LeverRouter.Close memory c = _close(10_000);
        c.deadline = block.timestamp - 1;
        vm.prank(ann);
        vm.expectRevert(LeverRouter.Expired.selector);
        lever.close(c);
        vm.prank(ann);
        vm.expectRevert(LeverRouter.NotAuthorized.selector);
        lever.close(_close(10_000));
    }

    function test_the_callback_runs_only_inside_the_routers_own_call() public {
        vm.prank(eve);
        vm.expectRevert(LeverRouter.OnlyMorpho.selector);
        lever.onMorphoFlashLoan(1, "");
        // Morpho calling back while nothing is in flight: refused.
        vm.prank(address(morpho));
        vm.expectRevert(LeverRouter.NotInFlight.selector);
        lever.onMorphoFlashLoan(1, "");
    }

    function test_nothing_sends_out_tokens_left_here() public {
        // There is no sweep: a token sent here by mistake stays, and no owner call can move anyone's money.
        usdg.mint(address(lever), 5e6);
        assertEq(usdg.balanceOf(address(lever)), 5e6);
        bytes4[3] memory none = [bytes4(keccak256("sweep(address,address)")), bytes4(keccak256("rescue(address,address,uint256)")), bytes4(keccak256("withdraw(address,uint256)"))];
        for (uint256 i; i < none.length; i++) {
            (bool ok,) = address(lever).call(abi.encodeWithSelector(none[i], address(usdg), owner));
            assertFalse(ok);
        }
    }

    function testFuzz_close_share_bounds(uint256 bps) public {
        vm.assume(bps == 0 || bps > 10_000);
        vm.prank(ann);
        vm.expectRevert(LeverRouter.Nothing.selector);
        lever.close(_close(bps));
    }
}
