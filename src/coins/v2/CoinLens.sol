// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {EthPrice} from "../EthPrice.sol";
import {Venue, VENUE_V3, VENUE_V4, PAIR_ETH, PAIR_USDG, PAIR_STOCK, IV3Pool, IV3Factory, IPriceFeed, IStockDesks} from "./VenueDeps.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

/// @title CoinLens
/// @notice Reads a coin's pool wherever it trades (a Uniswap v3 pool, or a Uniswap v4 pool with any hook), against
///         ETH, USDG or a Borro stock token: its dollar price, its market cap, and its depth, the coins the pool
///         gives up while the coin's price rises MOVE_BPS and takes in while it falls MOVE_BPS, from any starting
///         price, measured from the pool's live liquidity tick by tick. CuratedListing, the coin feeds and the
///         vetting tool (keeper/tools/vet-coin.mjs) all read through it, so they measure the same way. No owner, no state.
/// @dev Prices are dollars per whole coin with 18 decimals. A pair token's dollars: ETH by the WETH/USDG pool's
///      30-minute average (EthPrice), USDG one, a stock token by its Chainlink feed (fresh when updated within
///      STOCK_MAX_AGE; a stale stock price is still a price, and only new positions refuse it).
///      Depth starts at the given price, not the pool's: from the pool's price now it walks the initialized ticks to
///      the starting price to learn the liquidity there, then counts the coins over the next MOVE_BPS each way. A
///      walk longer than MAX_STEPS stops early and counts less, never more; a starting price it cannot reach counts
///      nothing.
contract CoinLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant MOVE_BPS = 1_000; // depth: what the pool trades while the price moves 10%
    uint256 internal constant SQRT_MOVE = 1_048_808_848; // sqrt(1.1), 9 decimals
    uint256 public constant STOCK_MAX_AGE = 26 hours; // the stock feeds' 24-hour heartbeat, and some slack
    uint256 public constant MAX_STEPS = 160; // ticks or bitmap words a depth walk may visit

    IPoolManager public immutable poolManager;
    IV3Factory public immutable v3Factory;
    address public immutable weth;
    address public immutable usdg;
    EthPrice public immutable ethPrice;
    IStockDesks public immutable stockDesks; // BorroShort

    /// The pool's state where a walk is: price, tick and the liquidity in range there.
    struct Walk {
        uint160 sqrtP;
        int24 tick;
        uint128 liq;
    }

    /// One pool, resolved for reading.
    struct Pool {
        uint8 kind;
        address v3;
        PoolId id;
        int24 spacing;
        bool coinIs0;
        address pair; // the pair token; zero for native ETH
        uint256 scale; // pair dollars * 10^coinDecimals / 10^pairDecimals: turns a raw pool price into dollars
    }

    /// Everything the vetting tool and the listing show about a coin in a venue, at the pool's price now.
    struct Look {
        bool ok;
        string why;
        address pair;
        bool coinIs0;
        uint8 coinDecimals;
        uint256 pairUsd;
        bool pairFresh;
        uint256 spotUsd;
        uint256 mcapUsd;
        uint256 upCoins;
        uint256 downCoins;
        uint160 sqrtP;
        int24 tick;
        uint128 liquidity;
        uint16 cardinality; // v3 only
        uint16 cardinalityNext; // v3 only
        uint256 twapUsd; // v3 only: the 30-minute average price, zero while the pool's history is too short
    }

    constructor(IPoolManager pm_, IV3Factory v3Factory_, address weth_, address usdg_, EthPrice ethPrice_, IStockDesks stockDesks_) {
        poolManager = pm_;
        v3Factory = v3Factory_;
        weth = weth_;
        usdg = usdg_;
        ethPrice = ethPrice_;
        stockDesks = stockDesks_;
    }

    // ------------------------------------------------------------------ the venue

    /// @notice Whether `v` is a real pool of `coin` against the pair it names. The reason when not.
    function check(address coin, Venue memory v) public view returns (bool ok, string memory why) {
        address t0;
        address t1;
        if (v.kind == VENUE_V3) {
            if (v.pool.code.length == 0) return (false, "no pool");
            try IV3Pool(v.pool).token0() returns (address a) {
                t0 = a;
            } catch {
                return (false, "not a v3 pool");
            }
            t1 = IV3Pool(v.pool).token1();
            if (v3Factory.getPool(t0, t1, IV3Pool(v.pool).fee()) != v.pool) return (false, "not from the Uniswap v3 factory");
            if (Currency.unwrap(v.key.currency0) != address(0) || Currency.unwrap(v.key.currency1) != address(0)) return (false, "a v3 venue has no v4 key");
        } else if (v.kind == VENUE_V4) {
            if (v.pool != address(0)) return (false, "a v4 venue has no v3 pool");
            t0 = Currency.unwrap(v.key.currency0);
            t1 = Currency.unwrap(v.key.currency1);
            if (t0 >= t1) return (false, "currencies out of order");
            (uint160 s,,,) = poolManager.getSlot0(v.key.toId());
            if (s == 0) return (false, "pool not initialized");
        } else {
            return (false, "unknown venue kind");
        }
        if (t0 != coin && t1 != coin) return (false, "the pool does not hold the coin");
        address pair = t0 == coin ? t1 : t0;
        if (v.pair == PAIR_ETH) {
            if (pair != weth && !(pair == address(0) && v.kind == VENUE_V4)) return (false, "pair is not ETH");
        } else if (v.pair == PAIR_USDG) {
            if (pair != usdg) return (false, "pair is not USDG");
        } else if (v.pair == PAIR_STOCK) {
            try stockDesks.deskOf(v.stockDesk) returns (MarketParams memory m, PoolKey[] memory, address, bool, address feed) {
                if (m.loanToken != pair || pair == address(0)) return (false, "pair is not that desk's stock");
                if (feed != v.pairFeed || feed == address(0)) return (false, "pair feed is not the desk's");
            } catch {
                return (false, "no such stock desk");
            }
        } else {
            return (false, "unknown pair kind");
        }
        if (v.pair != PAIR_STOCK && (v.stockDesk != bytes32(0) || v.pairFeed != address(0))) return (false, "stock fields set for a non-stock pair");
        return (true, "");
    }

    /// @notice The pair token's dollars (18 decimals per whole token), and whether it is fresh enough for a new
    ///         position. Zero if there is no price.
    function pairUsd(Venue memory v) public view returns (uint256 usd, bool fresh) {
        if (v.pair == PAIR_USDG) return (1e18, true);
        if (v.pair == PAIR_ETH) {
            try ethPrice.ethUsd() returns (uint256 e) {
                return (e, e != 0);
            } catch {
                return (0, false);
            }
        }
        try IPriceFeed(v.pairFeed).latestRoundData() returns (uint80, int256 a, uint256, uint256 at, uint80) {
            if (a <= 0) return (0, false);
            usd = Math.mulDiv(uint256(a), 1e18, 10 ** IPriceFeed(v.pairFeed).decimals());
            fresh = block.timestamp <= at + STOCK_MAX_AGE;
        } catch {
            return (0, false);
        }
    }

    // ------------------------------------------------------------------ prices

    /// @notice A whole coin in dollars at the pool's price now. Zero without a pool price or a pair price.
    function spotUsd(address coin, Venue memory v) public view returns (uint256) {
        Pool memory p = _pool(coin, v);
        (uint160 s,,) = _slot(p);
        return usdAt(p, s);
    }

    /// @notice A whole coin in dollars at the pool's raw price `sqrtP` (token1 per token0, Q96).
    function usdAtSqrt(address coin, Venue memory v, uint160 sqrtP) external view returns (uint256) {
        return usdAt(_pool(coin, v), sqrtP);
    }

    function usdAt(Pool memory p, uint160 sqrtP) internal pure returns (uint256) {
        if (sqrtP == 0 || p.scale == 0) return 0;
        // Coin is token0: dollars = scale * P. Coin is token1: dollars = scale / P. P = sqrtP^2 / 2^192.
        if (p.coinIs0) return FullMath.mulDiv(FullMath.mulDiv(p.scale, sqrtP, 2 ** 96), sqrtP, 2 ** 96);
        return FullMath.mulDiv(FullMath.mulDiv(p.scale, 2 ** 96, sqrtP), 2 ** 96, sqrtP);
    }

    /// @dev The pool's raw sqrt price at which a whole coin is worth `coinUsd`, inside the pool's price range.
    function _sqrtAt(Pool memory p, uint256 coinUsd) internal pure returns (uint160) {
        if (coinUsd == 0 || p.scale == 0) return 0;
        // Coin is token0: P = coinUsd / scale. Coin is token1: P = scale / coinUsd.
        (uint256 num, uint256 den) = p.coinIs0 ? (coinUsd, p.scale) : (p.scale, coinUsd);
        uint256 s;
        if (num / den < 2 ** 64) s = Math.sqrt(FullMath.mulDiv(num, 2 ** 192, den));
        else s = Math.sqrt(FullMath.mulDiv(num, 2 ** 96, den)) << 48;
        if (s <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (s >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    /// @notice The coin's total supply at `coinUsd`, in dollars (18 decimals). Zero for a coin that will not say.
    function mcap(address coin, uint256 coinUsd) public view returns (uint256) {
        try IERC20Decimals(coin).totalSupply() returns (uint256 supply) {
            return FullMath.mulDiv(supply, coinUsd, 10 ** IERC20Decimals(coin).decimals());
        } catch {
            return 0;
        }
    }

    // ------------------------------------------------------------------ depth

    /// @notice The coins the pool gives up while the coin's price rises MOVE_BPS from `coinUsd` (what buying the
    ///         coin back can take out), and takes in while it falls MOVE_BPS (what selling the coin can put in), by
    ///         the pool's liquidity now. Both zero if the pool cannot be walked to `coinUsd`.
    function depth(address coin, Venue memory v, uint256 coinUsd) public view returns (uint256 up, uint256 down) {
        Pool memory p = _pool(coin, v);
        return _depth(p, _sqrtAt(p, coinUsd));
    }

    function _depth(Pool memory p, uint160 start) internal view returns (uint256 up, uint256 down) {
        if (start == 0) return (0, 0);
        (uint160 s, int24 t, uint128 l) = _slot(p);
        if (s == 0) return (0, 0);
        Walk memory w = Walk(s, t, l);
        (,, bool reached) = _move(p, w, start, false);
        if (!reached) return (0, 0);
        uint160 hi = _clamp(FullMath.mulDiv(start, SQRT_MOVE, 1e9));
        uint160 lo = _clamp(FullMath.mulDiv(start, 1e9, SQRT_MOVE));
        (uint256 hi0, uint256 hi1,) = _move(p, Walk(w.sqrtP, w.tick, w.liq), hi, true);
        (uint256 lo0, uint256 lo1,) = _move(p, Walk(w.sqrtP, w.tick, w.liq), lo, true);
        // The raw price rising takes token1 in and gives token0 out; falling, the other way round.
        if (p.coinIs0) return (hi0, lo0); // the coin's price is the raw price
        return (lo1, hi1); // the coin's price is its inverse
    }

    function _clamp(uint256 s) internal pure returns (uint160) {
        if (s <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (s >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    /// @dev Moves `w` toward `target` as a swap would, crossing initialized ticks and adjusting the liquidity in
    ///      range. With `count`, adds up the token0 and token1 passed over. Stops after MAX_STEPS.
    function _move(Pool memory p, Walk memory w, uint160 target, bool count) internal view returns (uint256 a0, uint256 a1, bool reached) {
        bool up = target > w.sqrtP;
        for (uint256 i; i < MAX_STEPS && w.sqrtP != target; i++) {
            (int24 next, bool init) = _nextTick(p, w.tick, !up);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 sNext = TickMath.getSqrtPriceAtTick(next);
            uint160 stop = up ? (sNext > target ? target : sNext) : (sNext < target ? target : sNext);
            if (count && w.liq != 0) {
                (uint160 a, uint160 b) = up ? (w.sqrtP, stop) : (stop, w.sqrtP);
                a0 += SqrtPriceMath.getAmount0Delta(a, b, w.liq, false);
                a1 += SqrtPriceMath.getAmount1Delta(a, b, w.liq, false);
            }
            w.sqrtP = stop;
            if (stop == sNext) {
                if (init) {
                    int128 net = _net(p, next);
                    if (!up) net = -net;
                    if (net < 0) w.liq = uint128(-net) > w.liq ? 0 : w.liq - uint128(-net);
                    else w.liq += uint128(net);
                }
                w.tick = up ? next : next - 1;
            } else {
                w.tick = TickMath.getTickAtSqrtPrice(stop);
            }
        }
        reached = w.sqrtP == target;
    }

    /// @dev Uniswap's nextInitializedTickWithinOneWord, reading the pool's bitmap.
    function _nextTick(Pool memory p, int24 tick, bool lte) internal view returns (int24 next, bool init) {
        int24 sp = p.spacing;
        int24 compressed = tick / sp;
        if (tick < 0 && tick % sp != 0) compressed--;
        if (lte) {
            (int16 word, uint8 bit) = (int16(compressed >> 8), uint8(int8(compressed % 256)));
            uint256 masked = _bitmap(p, word) & ((uint256(1) << bit) - 1 + (uint256(1) << bit));
            init = masked != 0;
            next = init
                ? (compressed - int24(uint24(bit - BitMath.mostSignificantBit(masked)))) * sp
                : (compressed - int24(uint24(bit))) * sp;
        } else {
            compressed++;
            (int16 word, uint8 bit) = (int16(compressed >> 8), uint8(int8(compressed % 256)));
            uint256 masked = _bitmap(p, word) & ~((uint256(1) << bit) - 1);
            init = masked != 0;
            next = init
                ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bit))) * sp
                : (compressed + int24(uint24(type(uint8).max - bit))) * sp;
        }
    }

    function _bitmap(Pool memory p, int16 word) internal view returns (uint256) {
        if (p.kind == VENUE_V3) return IV3Pool(p.v3).tickBitmap(word);
        return poolManager.getTickBitmap(p.id, word);
    }

    function _net(Pool memory p, int24 tick) internal view returns (int128 net) {
        if (p.kind == VENUE_V3) (, net,,,,,,) = IV3Pool(p.v3).ticks(tick);
        else (, net) = poolManager.getTickLiquidity(p.id, tick);
    }

    // ------------------------------------------------------------------ the pool

    /// @notice The venue resolved for reading: which token is the coin, the pair, and the dollar scale.
    function pool(address coin, Venue memory v) external view returns (Pool memory) {
        return _pool(coin, v);
    }

    function _pool(address coin, Venue memory v) internal view returns (Pool memory p) {
        p.kind = v.kind;
        address t0;
        address t1;
        if (v.kind == VENUE_V3) {
            p.v3 = v.pool;
            t0 = IV3Pool(v.pool).token0();
            t1 = IV3Pool(v.pool).token1();
            p.spacing = IV3Pool(v.pool).tickSpacing();
        } else {
            p.id = v.key.toId();
            t0 = Currency.unwrap(v.key.currency0);
            t1 = Currency.unwrap(v.key.currency1);
            p.spacing = v.key.tickSpacing;
        }
        p.coinIs0 = t0 == coin;
        p.pair = p.coinIs0 ? t1 : t0;
        (uint256 usd,) = pairUsd(v);
        uint256 cd = IERC20Decimals(coin).decimals();
        uint256 pd = p.pair == address(0) ? 18 : IERC20Decimals(p.pair).decimals();
        p.scale = FullMath.mulDiv(usd, 10 ** cd, 10 ** pd);
    }

    function _slot(Pool memory p) internal view returns (uint160 s, int24 t, uint128 l) {
        if (p.kind == VENUE_V3) {
            (s, t,,,,,) = IV3Pool(p.v3).slot0();
            l = IV3Pool(p.v3).liquidity();
        } else {
            (s, t,,) = poolManager.getSlot0(p.id);
            l = poolManager.getLiquidity(p.id);
        }
    }

    /// @notice Everything about a coin in a venue at the pool's price now, for the vetting tool and the site.
    function look(address coin, Venue memory v) external view returns (Look memory l) {
        (l.ok, l.why) = check(coin, v);
        if (!l.ok) return l;
        Pool memory p = _pool(coin, v);
        l.pair = p.pair;
        l.coinIs0 = p.coinIs0;
        l.coinDecimals = IERC20Decimals(coin).decimals();
        (l.pairUsd, l.pairFresh) = pairUsd(v);
        (l.sqrtP, l.tick, l.liquidity) = _slot(p);
        l.spotUsd = usdAt(p, l.sqrtP);
        l.mcapUsd = mcap(coin, l.spotUsd);
        (l.upCoins, l.downCoins) = _depth(p, l.sqrtP);
        if (v.kind == VENUE_V3) {
            (,,, l.cardinality, l.cardinalityNext,,) = IV3Pool(v.pool).slot0();
            l.twapUsd = twapUsd(coin, v, 1800);
        }
    }

    /// @notice A v3 coin's dollar price by its pool's own time-weighted average over `secs`, times the pair's
    ///         dollars now. Zero while the pool's history is shorter than that.
    function twapUsd(address coin, Venue memory v, uint32 secs) public view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = secs;
        try IV3Pool(v.pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 d = cum[1] - cum[0];
            int56 span = int56(uint56(secs));
            int24 tick = int24(d / span);
            if (d < 0 && d % span != 0) tick--; // round toward minus infinity, as Uniswap does
            return usdAt(_pool(coin, v), TickMath.getSqrtPriceAtTick(tick));
        } catch {
            return 0;
        }
    }
}
