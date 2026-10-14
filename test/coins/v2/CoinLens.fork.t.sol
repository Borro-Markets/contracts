// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {EthPrice} from "../../../src/coins/EthPrice.sol";
import {IUniV3PoolOracle} from "../../../src/coins/CoinFeed.sol";
import {CoinLens} from "../../../src/coins/v2/CoinLens.sol";
import {Venue, VENUE_V3, VENUE_V4, PAIR_ETH, PAIR_USDG, IV3Pool, IV3Factory, IStockDesks} from "../../../src/coins/v2/VenueDeps.sol";

/// Moves a pool's price to a limit, as a liquidator's trade would, and reports what crossed. Pays with tokens the
/// test deals it.
contract PriceMover is IUnlockCallback, Test {
    IPoolManager immutable pm;
    address private _pool;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    /// Swaps until the raw price reaches `limit` (or the input runs out); returns token0 and token1 deltas from the
    /// pool's side (positive: the pool took it in).
    function v3(address pool, uint160 limit) external returns (int256 a0, int256 a1) {
        (uint160 s,,,,,,) = IV3Pool(pool).slot0();
        bool zeroForOne = limit < s;
        _pool = pool;
        (a0, a1) = IV3Pool(pool).swap(address(this), zeroForOne, type(int128).max, limit, "");
        _pool = address(0);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == _pool);
        address t = a0 > 0 ? IV3Pool(msg.sender).token0() : IV3Pool(msg.sender).token1();
        uint256 owed = uint256(a0 > 0 ? a0 : a1);
        deal(t, address(this), owed);
        IERC20(t).transfer(msg.sender, owed);
    }

    function v4(PoolKey memory key, uint160 limit, bool zeroForOne) external returns (int256 a0, int256 a1) {
        BalanceDelta d = abi.decode(pm.unlock(abi.encode(key, limit, zeroForOne)), (BalanceDelta));
        // From the pool's side: what the swapper paid in is positive.
        a0 = -int256(d.amount0());
        a1 = -int256(d.amount1());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint160 limit, bool zeroForOne) = abi.decode(data, (PoolKey, uint160, bool));
        BalanceDelta d = pm.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(uint256(type(uint120).max)), sqrtPriceLimitX96: limit}), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, int128 delta) internal {
        if (delta < 0) {
            uint256 owed = uint256(uint128(-delta));
            if (Currency.unwrap(c) == address(0)) {
                vm.deal(address(this), owed);
                pm.settle{value: owed}();
            } else {
                pm.sync(c);
                deal(Currency.unwrap(c), address(this), owed);
                IERC20(Currency.unwrap(c)).transfer(address(pm), owed);
                pm.settle();
            }
        } else if (delta > 0) {
            pm.take(c, address(this), uint256(uint128(delta)));
        }
    }
}

/// CoinLens's depth against real trades on a copy of the live chain: the coins a pool gives up while the price
/// rises 10%, and takes in while it falls 10%, are what a swap to those prices actually moves.
contract CoinLensForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant BORRO_SHORT = 0xd2D686cEdf225c5C9815187A08812783904E62Eb;
    address constant CHUMP = 0x0E0d2C89a5a019FE1cF762e5e33187631DACC21B;
    address constant CHUMP_POOL = 0x714442e9A611f8561A7dF108D6d925132937cFb8; // v3 WETH 1%
    address constant NOVAAI = 0x51250B135174Ca09450EC01c4afF73CF69DBb590;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    CoinLens lens;
    PriceMover mover;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        EthPrice ep = new EthPrice(IUniV3PoolOracle(ETH_POOL), WETH, USDG, 1800);
        lens = new CoinLens(PM, IV3Factory(V3_FACTORY), WETH, USDG, ep, IStockDesks(BORRO_SHORT));
        mover = new PriceMover(PM);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _v3(address pool) internal pure returns (Venue memory v) {
        v.kind = VENUE_V3;
        v.pool = pool;
        v.pair = PAIR_ETH;
    }

    function _novaai() internal pure returns (Venue memory v) {
        v.kind = VENUE_V4;
        v.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(NOVAAI), 0, 200, IHooks(PONS_HOOK));
        v.pair = PAIR_ETH;
    }

    /// The coin a swap moved, from the pool's side: coins out when the price rose, coins in when it fell.
    function _coinMoved(bool coinIs0, int256 a0, int256 a1) internal pure returns (uint256) {
        int256 c = coinIs0 ? a0 : a1;
        return uint256(c < 0 ? -c : c);
    }

    /// `inFee`: the pool's fee on what a swap puts in (millionths), which the pool keeps outside its liquidity math.
    /// `outFeeBps`: a hook's cut of what a swap takes out (Pons: 1%), which the pool still gives up.
    function _check(address coin, Venue memory v, uint256 startUsd, uint256 inFee, uint256 outFeeBps) internal {
        CoinLens.Pool memory p = lens.pool(coin, v);
        (uint256 up, uint256 down) = lens.depth(coin, v, startUsd);
        console2.log("depth up (coins)", up / 1e18);
        console2.log("depth down (coins)", down / 1e18);
        assertGt(up, 0);
        assertGt(down, 0);
        // Walk the pool to the starting price, then 10% each way, and count what the swaps moved.
        uint160 start = _sqrtAt(p, startUsd);
        uint160 hi = uint160(FullMath.mulDiv(start, 1_048_808_848, 1e9));
        uint160 lo = uint160(FullMath.mulDiv(start, 1e9, 1_048_808_848));
        // The coin's price rising: the raw price rises if the coin is token0, falls if it is token1.
        (uint160 upLimit, uint160 downLimit) = p.coinIs0 ? (hi, lo) : (lo, hi);
        uint256 snap = vm.snapshotState();
        _move(v, start);
        (int256 a0, int256 a1) = _move(v, upLimit);
        uint256 upSwap = _coinMoved(p.coinIs0, a0, a1);
        vm.revertToState(snap);
        _move(v, start);
        (a0, a1) = _move(v, downLimit);
        uint256 downSwap = _coinMoved(p.coinIs0, a0, a1);
        vm.revertToState(snap);
        console2.log("swap to +10% (coins)", upSwap / 1e18);
        console2.log("swap to -10% (coins)", downSwap / 1e18);
        upSwap = (upSwap * 10_000) / (10_000 - outFeeBps);
        downSwap = (downSwap * (1e6 - inFee)) / 1e6;
        assertApproxEqRel(up, upSwap, 0.001e18, "up: the lens counts what a swap to +10% takes out of the pool");
        assertApproxEqRel(down, downSwap, 0.001e18, "down: the lens counts what a swap to -10% puts into the pool");
    }

    function _move(Venue memory v, uint160 limit) internal returns (int256 a0, int256 a1) {
        if (v.kind == VENUE_V3) {
            (uint160 s,,,,,,) = IV3Pool(v.pool).slot0();
            if (s == limit) return (0, 0);
            return mover.v3(v.pool, limit);
        }
        (uint160 s4,,,) = _slot0v4(v.key);
        if (s4 == limit) return (0, 0);
        return mover.v4(v.key, limit, limit < s4);
    }

    function _slot0v4(PoolKey memory key) internal view returns (uint160 s, int24 t, uint24 a, uint24 b) {
        bytes32 id = keccak256(abi.encode(key));
        bytes32 slot = keccak256(abi.encodePacked(id, uint256(6)));
        bytes32 word = PM.extsload(slot);
        s = uint160(uint256(word));
        t = int24(int256(uint256(word) >> 160));
        a;
        b;
    }

    function _sqrtAt(CoinLens.Pool memory p, uint256 coinUsd) internal pure returns (uint160) {
        (uint256 num, uint256 den) = p.coinIs0 ? (coinUsd, p.scale) : (p.scale, coinUsd);
        return uint160(_sqrt(FullMath.mulDiv(num, 2 ** 192, den)));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function test_fork_v3_depth_matches_swaps_at_spot_and_away_from_it() public onFork {
        Venue memory v = _v3(CHUMP_POOL);
        uint256 spot = lens.spotUsd(CHUMP, v);
        console2.log("CHUMP spot (micro-dollars)", spot / 1e12);
        _check(CHUMP, v, spot, 10_000, 0); // the 1% pool
        // From 5% above and 5% below the pool's price, as a delayed price would be.
        _check(CHUMP, v, (spot * 105) / 100, 10_000, 0);
        _check(CHUMP, v, (spot * 95) / 100, 10_000, 0);
    }

    function test_fork_v4_depth_matches_swaps_through_the_pons_hook() public onFork {
        Venue memory v = _novaai();
        uint256 spot = lens.spotUsd(NOVAAI, v);
        console2.log("NOVAAI spot (micro-dollars)", spot / 1e12);
        // No pool fee; the Pons hook takes 1% of what the swapper buys.
        _check(NOVAAI, v, spot, 0, 100);
        _check(NOVAAI, v, (spot * 104) / 100, 0, 100);
        _check(NOVAAI, v, (spot * 96) / 100, 0, 100);
    }
}
