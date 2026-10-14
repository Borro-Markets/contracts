// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {CoinListing, IPositionManager} from "../../src/coins/CoinListing.sol";
import {CoinCollateral} from "../../src/coins/CoinCollateral.sol";
import {CoinFeed, IUniV3PoolOracle} from "../../src/coins/CoinFeed.sol";
import {PonsLaunch, IPonsFactory, IPonsLocker} from "../../src/coins/CoinDeps.sol";
import {FeedToken, FakeManager, FakeV3} from "./CoinFeed.t.sol";

contract MockPons {
    mapping(address => PonsLaunch) public launch;
    address public memeHook;
    address public locker;

    constructor(address hook, address locker_) {
        (memeHook, locker) = (hook, locker_);
    }

    function set(address coin, PonsLaunch memory l) external {
        launch[coin] = l;
    }

    function getLaunchedToken(address coin) external view returns (PonsLaunch memory) {
        return launch[coin];
    }
}

contract MockCurve {
    uint256 public launchedAt;

    function set(uint256 t) external {
        launchedAt = t;
    }
}

contract MockHook {
    uint256 public hookFeeBps = 100;

    function set(uint256 b) external {
        hookFeeBps = b;
    }
}

contract MockLocker {
    mapping(address => uint256) public lockedPositions;
    mapping(address => bool) public isLocked;

    function set(address coin, uint256 id, bool locked) external {
        lockedPositions[coin] = id;
        isLocked[coin] = locked;
    }
}

contract MockPosm {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => PoolKey) internal _key;
    mapping(uint256 => PositionInfo) internal _info;
    mapping(uint256 => uint128) public getPositionLiquidity;

    function set(uint256 id, address owner, PoolKey memory key, int24 lo, int24 hi, uint128 liq) external {
        ownerOf[id] = owner;
        _key[id] = key;
        _info[id] = PositionInfoLibrary.initialize(key, lo, hi);
        getPositionLiquidity[id] = liq;
    }

    function getPoolAndPositionInfo(uint256 id) external view returns (PoolKey memory, PositionInfo) {
        return (_key[id], _info[id]);
    }
}

/// Exposes the depth math for fuzzing.
contract ListingHarness is CoinListing {
    constructor(IPoolManager pm, IPositionManager posm, IPonsFactory p, IPonsLocker l, IUniV3PoolOracle e, address w, address u, address s, address c)
        CoinListing(pm, posm, p, l, e, w, u, s, c)
    {}

    function depth(uint256 id, uint256 coinUsd, uint256 ethUsd) external view returns (uint256, uint256) {
        return _depth(id, coinUsd, ethUsd);
    }
}

/// CoinListing's checks against stand-ins for Pons, its locker and the PositionManager: each one refused on its own.
contract CoinListingTest is Test {
    using PositionInfoLibrary for PositionInfo;

    FeedToken weth = new FeedToken(18);
    FeedToken usdg = new FeedToken(6);
    FeedToken coin = new FeedToken(18);
    FakeManager pm = new FakeManager();
    FakeV3 v3;
    MockHook hook = new MockHook();
    MockLocker locker = new MockLocker();
    MockPosm posm = new MockPosm();
    MockCurve curve = new MockCurve();
    MockPons pons;
    ListingHarness listing;
    address safe = makeAddr("safe");
    uint256 constant ID = 3616551;

    function setUp() public {
        vm.warp(1_800_000_000);
        v3 = new FakeV3(address(weth), address(usdg), -200_311);
        pons = new MockPons(address(hook), address(locker));
        listing = new ListingHarness(
            IPoolManager(address(pm)), IPositionManager(address(posm)), IPonsFactory(address(pons)), IPonsLocker(address(locker)),
            IUniV3PoolOracle(address(v3)), address(weth), address(usdg), safe, makeAddr("short")
        );
        pm.set(uint160(Math.sqrt(1e9) * 2 ** 96));
        pons.set(address(coin), _good());
        locker.set(address(coin), ID, true);
        PoolKey memory k = listing.keyOf(address(coin));
        posm.set(ID, address(locker), k, TickMath.minUsableTick(200), TickMath.maxUsableTick(200), 1e23);
        curve.set(block.timestamp - 4 days);
        coin.setSupply(6e30); // six trillion coins at $0.000002: about $12M
    }

    function _good() internal view returns (PonsLaunch memory l) {
        l.token = address(coin);
        l.exists = true;
        l.phase = 2;
        l.poolFee = 0;
        l.tickSpacing = 200;
        l.creatorTaxBps = 100;
        l.curve = address(curve);
    }

    function _refused(string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(CoinListing.CheckFailed.selector, what));
        listing.list(address(coin));
    }

    function test_a_good_coin_passes_every_check() public view {
        CoinListing.Checks memory c = listing.checks(address(coin));
        assertTrue(c.launchedByPons && c.pairedWithEth && c.graduated && c.decimals18 && c.taxOk && c.hookFeeOk && c.poolLive && c.liquidityLocked);
        assertTrue(c.oldEnough && c.deepEnough && c.notListed && c.open);
        assertEq(c.launchedAt, block.timestamp - 4 days);
        assertEq(c.readyAt, block.timestamp - 1 days);
        // 1e23 of liquidity at a billion coins an ETH: 1e23 / 31,622.78 = 3.16 ETH on the ETH side.
        assertApproxEqRel(c.ethDepth, 3.1623e18, 1e15);
        // ETH at about $2,000 by the WETH/USDG pool's 30-minute average; a coin at a billionth of that.
        assertApproxEqRel(listing.ethUsd(), 2_000e18, 0.01e18);
        assertTrue(c.mcapOk);
        assertApproxEqRel(c.mcapUsd, 6e12 * listing.ethUsd() / 999_950_884, 1e12, "supply times the pool's price");
    }

    /// Exactly $10M lists; a wei of supply less is refused.
    function test_refused_under_ten_million_dollars() public {
        coin.setSupply(1e30);
        uint256 m1 = listing.checks(address(coin)).mcapUsd; // a trillion coins
        uint256 s = Math.mulDiv(1e30, listing.MIN_MCAP_USD(), m1, Math.Rounding.Ceil);
        coin.setSupply(s - 1);
        assertFalse(listing.checks(address(coin)).mcapOk);
        assertLt(listing.checks(address(coin)).mcapUsd, 10_000_000e18);
        _refused("market cap");
        coin.setSupply(s);
        CoinListing.Checks memory c = listing.checks(address(coin));
        assertTrue(c.mcapOk);
        assertGe(c.mcapUsd, 10_000_000e18);
        // A coin that will not say its supply, or a pool that cannot price ETH, is worth nothing here.
        FakeV3 dead = new FakeV3(address(weth), address(usdg), 0);
        vm.mockCallRevert(address(dead), abi.encodeWithSelector(FakeV3.observe.selector), "");
        ListingHarness blind = new ListingHarness(
            IPoolManager(address(pm)), IPositionManager(address(posm)), IPonsFactory(address(pons)), IPonsLocker(address(locker)),
            IUniV3PoolOracle(address(dead)), address(weth), address(usdg), safe, makeAddr("short")
        );
        assertEq(blind.ethUsd(), 0);
        assertFalse(blind.checks(address(coin)).mcapOk);
    }

    function test_refused_too_young_by_launch_time() public {
        curve.set(block.timestamp - 3 days + 1);
        _refused("3 days since launch");
        curve.set(0); // no launch time read
        _refused("3 days since launch");
        curve.set(block.timestamp - 3 days);
        assertTrue(listing.checks(address(coin)).oldEnough, "exactly three days is old enough");
    }

    function test_refused_too_shallow() public {
        PoolKey memory k = listing.keyOf(address(coin));
        posm.set(ID, address(locker), k, TickMath.minUsableTick(200), TickMath.maxUsableTick(200), 6e22); // 1.9 ETH
        _refused("locked depth");
    }

    function test_refused_not_launched_by_pons() public {
        PonsLaunch memory l = _good();
        l.exists = false;
        pons.set(address(coin), l);
        _refused("launched by Pons");
        l = _good();
        l.token = address(usdg); // a record for another token
        pons.set(address(coin), l);
        _refused("launched by Pons");
    }

    function test_refused_not_paired_with_eth() public {
        PonsLaunch memory l = _good();
        l.pairToken = address(usdg);
        pons.set(address(coin), l);
        _refused("paired with ETH");
    }

    function test_refused_unless_graduated() public {
        uint8[3] memory phases = [uint8(0), 1, 3];
        for (uint256 i; i < 3; i++) {
            PonsLaunch memory l = _good();
            l.phase = phases[i];
            pons.set(address(coin), l);
            _refused("graduated");
        }
    }

    function test_refused_other_decimals() public {
        FeedToken six = new FeedToken(6);
        PonsLaunch memory l = _good();
        l.token = address(six);
        pons.set(address(six), l);
        vm.expectRevert(abi.encodeWithSelector(CoinListing.CheckFailed.selector, "18 decimals"));
        listing.list(address(six));
    }

    function test_refused_creator_tax_or_hook_fee_too_high() public {
        PonsLaunch memory l = _good();
        l.creatorTaxBps = 301;
        pons.set(address(coin), l);
        _refused("creator tax");
        pons.set(address(coin), _good());
        hook.set(201);
        _refused("Pons hook fee");
    }

    function test_refused_pool_not_live() public {
        pm.set(0);
        _refused("pool live");
    }

    function test_refused_unless_the_liquidity_is_locked() public {
        PoolKey memory k = listing.keyOf(address(coin));
        int24 lo = TickMath.minUsableTick(200);
        int24 hi = TickMath.maxUsableTick(200);
        // No position recorded.
        locker.set(address(coin), 0, true);
        _refused("liquidity locked");
        // Recorded but not locked.
        locker.set(address(coin), ID, false);
        _refused("liquidity locked");
        locker.set(address(coin), ID, true);
        // The NFT is someone else's.
        posm.set(ID, makeAddr("someone"), k, lo, hi, 1e23);
        _refused("liquidity locked");
        // A position in another pool.
        PoolKey memory other = k;
        other.fee = 3000;
        posm.set(ID, address(locker), other, lo, hi, 1e23);
        _refused("liquidity locked");
        // Not full range.
        posm.set(ID, address(locker), k, lo + 200, hi, 1e23);
        _refused("liquidity locked");
        // Empty.
        posm.set(ID, address(locker), k, lo, hi, 0);
        _refused("liquidity locked");
    }

    function test_only_the_safe_pauses_and_a_pause_stops_listing() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        listing.setPaused(true);
        vm.prank(safe);
        listing.setPaused(true);
        vm.expectRevert(CoinListing.IsPaused.selector);
        listing.list(address(coin));
    }

    /// The locked position's two sides at any price: x * y = L^2 and y / x = P (coin per ETH).
    function testFuzz_depth_is_the_full_range_position_at_the_price(uint128 liq, uint256 coinUsd, uint256 ethUsd) public {
        liq = uint128(bound(liq, 1e15, 1e30));
        coinUsd = bound(coinUsd, 1e6, 1e24); // a millionth of a cent to a million dollars
        ethUsd = bound(ethUsd, 100e18, 100_000e18);
        PoolKey memory k = listing.keyOf(address(coin));
        posm.set(ID, address(locker), k, TickMath.minUsableTick(200), TickMath.maxUsableTick(200), liq);
        (uint256 x, uint256 y) = listing.depth(ID, coinUsd, ethUsd);
        assertApproxEqRel(Math.mulDiv(x, y, 1), uint256(liq) * liq, 1e12, "x * y = L^2");
        // Both sides are worth the same in dollars.
        assertApproxEqRel(Math.mulDiv(x, ethUsd, 1e18), Math.mulDiv(y, coinUsd, 1e18), 1e12, "equal value");
    }
}

/// cUSDG: only CoinShort makes it or sends it to Morpho; anyone holding it turns it back one for one.
contract CoinCollateralTest is Test {
    ERC20Mint held = new ERC20Mint();
    address morpho = makeAddr("morpho");
    CoinCollateral c;
    address alice = makeAddr("alice");

    function setUp() public {
        c = new CoinCollateral(IERC20(address(held)), morpho); // this test is "CoinShort"
        held.mint(address(this), 1_000e18);
        held.approve(address(c), type(uint256).max);
    }

    function test_gate() public {
        c.wrap(100e18, address(this));
        c.transfer(morpho, 10e18); // CoinShort to Morpho: allowed
        c.transfer(alice, 50e18);
        vm.startPrank(alice);
        vm.expectRevert(CoinCollateral.OnlyShortToMorpho.selector);
        c.transfer(morpho, 1);
        c.approve(morpho, 1);
        vm.stopPrank();
        vm.prank(morpho);
        vm.expectRevert(CoinCollateral.OnlyShortToMorpho.selector);
        c.transferFrom(alice, morpho, 1);
        vm.prank(alice);
        vm.expectRevert(CoinCollateral.OnlyShort.selector);
        c.wrap(1, alice);
        vm.prank(morpho);
        c.transfer(alice, 10e18); // out of Morpho to anyone: allowed
        vm.prank(alice);
        c.unwrap(60e18, alice);
        assertEq(held.balanceOf(alice), 60e18);
    }

    function testFuzz_always_backed_one_for_one(uint96[6] memory amounts, uint8 seed) public {
        for (uint256 i; i < 6; i++) {
            uint256 a = bound(amounts[i], 0, 100e18);
            uint256 op = (uint256(seed) + i) % 3;
            if (op == 0 && held.balanceOf(address(this)) >= a) c.wrap(a, i % 2 == 0 ? address(this) : alice);
            else if (op == 1 && c.balanceOf(address(this)) >= a) c.unwrap(a, address(this));
            else if (op == 2 && c.balanceOf(alice) >= a) {
                vm.prank(alice);
                c.unwrap(a, alice);
            }
            assertEq(held.balanceOf(address(c)), c.totalSupply());
        }
    }
}

contract ERC20Mint is ERC20 {
    constructor() ERC20("held", "held") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}
