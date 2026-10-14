// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {BorroHook} from "../../src/hooks/BorroHook.sol";
import {IVault, IDesks} from "../../src/hooks/BorroHookDeps.sol";
import {BorroHookShare} from "../../src/hooks/BorroHookShare.sol";
import "./BorroHookMocks.sol";

/// BorroHook against a real Uniswap v4 PoolManager (Uniswap's own build, from test/fixtures) and mock Borro parts:
/// a stock at $100, a vault for each token, a feed, Morpho's market totals, the pots.
abstract contract BorroHookBase is Test {
    using MarketParamsLib for MarketParams;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    IPoolManager pm;
    MockToken usdg;
    MockToken stock;
    MockToken borro;
    MockVault uVault;
    MockVault sVault;
    MockFeed feed;
    MockMorpho morpho;
    MockDesks desks;
    MockPots pots;
    BorroHook hook;
    TestRouter router;
    PoolKey key;
    PoolId id;
    bytes32 deskId;
    BorroHookShare share;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address shorter = makeAddr("shorter");

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        pm = IPoolManager(deployCode("test/fixtures/PoolManager.json", abi.encode(address(this))));
        usdg = new MockToken("USDG", 6);
        stock = new MockToken("NVDA", 18);
        borro = new MockToken("BORRO", 18);
        uVault = new MockVault(usdg, 6);
        sVault = new MockVault(stock, 18);
        feed = new MockFeed();
        feed.set(100e8, block.timestamp);
        morpho = new MockMorpho();
        desks = new MockDesks(IMorpho(address(morpho)));
        pots = new MockPots(usdg);
        desks.setRewards(address(pots));
        MarketParams memory m = MarketParams({loanToken: address(stock), collateralToken: address(0xC0), oracle: address(0x0C), irm: address(0x1), lltv: 0.625e18});
        deskId = Id.unwrap(m.id());
        desks.setDesk(deskId, m, address(feed));
        morpho.setUse(Id.wrap(deskId), 1000e18, 0);

        hook = _deployHook();
        vm.prank(owner);
        id = hook.register(deskId, IVault(address(sVault)));
        key = hook.keyFor(address(stock));
        pm.initialize(key, SQRT_1_1);
        share = BorroHookShare(address(hook.poolOf(id).share));
        router = new TestRouter(pm);

        // the first LP: $100,000 and 1,000 stock at $100
        _deposit(alice, 100_000e6, 1_000e18);
    }

    function _deployHook() internal returns (BorroHook h) {
        bytes memory args = abi.encode(pm, IDesks(address(desks)), IVault(address(uVault)), IERC20(address(borro)), owner);
        bytes32 initHash = keccak256(abi.encodePacked(type(BorroHook).creationCode, args));
        bytes32 salt;
        for (uint256 i; i < 400_000; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == FLAGS) {
                salt = bytes32(i);
                break;
            }
        }
        h = new BorroHook{salt: salt}(pm, IDesks(address(desks)), IVault(address(uVault)), IERC20(address(borro)), owner);
    }

    function _deposit(address who, uint256 u, uint256 s) internal returns (uint256 shares) {
        usdg.mint(who, u);
        stock.mint(who, s);
        vm.startPrank(who);
        usdg.approve(address(hook), u);
        stock.approve(address(hook), s);
        (shares,,) = hook.deposit(id, u, s, 0, who);
        vm.stopPrank();
    }

    function _withdraw(address who, uint256 shares)
        internal
        returns (uint256 u, uint256 s, uint256 uShares, uint256 sShares)
    {
        vm.prank(who);
        return hook.withdraw(id, shares, 0, 0, who);
    }

    /// A swap from `who` through the router. Returns (paid, got).
    function _swap(address who, bool usdgIn, bool exactIn, uint256 amount) internal returns (uint256 paid, uint256 got) {
        bool usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        bool zeroForOne = usdgIn == usdgIs0;
        MockToken tIn = usdgIn ? usdg : stock;
        MockToken tOut = usdgIn ? stock : usdg;
        uint256 budget = exactIn ? amount : amount * 1000; // generous for exact out
        if (!exactIn && usdgIn) budget = amount * 200e6 / 1e18 + 1e6;
        if (!exactIn && !usdgIn) budget = amount * 1e18 / 50e6 + 1e18;
        tIn.mint(who, budget);
        uint256 inBefore = tIn.balanceOf(who);
        uint256 outBefore = tOut.balanceOf(who);
        vm.startPrank(who, who);
        tIn.approve(address(router), budget);
        router.swap(key, zeroForOne, exactIn ? -int256(amount) : int256(amount));
        vm.stopPrank();
        paid = inBefore - tIn.balanceOf(who);
        got = tOut.balanceOf(who) - outBefore;
    }

    function _pool() internal view returns (BorroHook.Pool memory) {
        return hook.poolOf(id);
    }

    /// Tokens plus ERC-6909 claims the hook holds, of `t`.
    function _held(IERC20 t) internal view returns (uint256) {
        return t.balanceOf(address(hook)) + pm.balanceOf(address(hook), uint256(uint160(address(t))));
    }

    /// The hook's tokens and claims cover every pool's buffer and its held surcharge.
    function _assertSolvent() internal view {
        BorroHook.Pool memory p = _pool();
        assertGe(_held(usdg), uint256(p.bufUsdg) + p.squeezeHeld, "USDG covers the buffer and the surcharge");
        assertGe(_held(stock), p.bufStock, "stock covers the buffer");
        assertEq(uVault.balanceOf(address(hook)), p.lentUsdg, "bUSDG shares match the books");
        assertEq(sVault.balanceOf(address(hook)), p.lentStock, "stock vault shares match the books");
    }

    function _price() internal view returns (uint256) {
        BorroHook.Pool memory p = _pool();
        return uint256(p.resUsdg) * 1e8 * 1e18 / (uint256(p.resStock) * 1e6);
    }
}
