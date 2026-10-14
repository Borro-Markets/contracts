// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IWETH} from "../CoinDeps.sol";
import {Venue, CuratedDesk, ICuratedListing, IV3Pool, IStockDesks, VENUE_V3, PAIR_ETH, PAIR_STOCK} from "./VenueDeps.sol";

/// @title CoinRouter
/// @notice Trades a curated coin against USDG wherever it is listed to trade: its own pool (Uniswap v3, or Uniswap v4
///         with any hook) and its pair's way to USDG (ETH through the WETH/USDG v3 pool; a stock token through the
///         route BorroShort trades that stock by; USDG needs none). Exact input to sell, exact output to buy, each
///         with the caller's bound. CuratedShort, CuratedLiquidator and CuratedLoanLiquidator trade through it.
/// @dev No owner and no state: it holds nothing between transactions. Selling pulls the coin from the caller and
///      sends the USDG out; buying works out the USDG each step needs first (by quoting each pool, which moves
///      nothing), pulls exactly that much, then trades step by step and sends the coin out. The pools are distinct,
///      so a step's quote is what it then costs. There is no price limit inside a pool; a pool that cannot fill the
///      exact amount reverts. Quotes run the trade and revert with QuoteResult.
contract CoinRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IV3Pool public immutable ethPool; // WETH/USDG
    IWETH public immutable weth;
    IERC20 public immutable usdg;
    ICuratedListing public immutable listing;
    IStockDesks public immutable stockDesks; // BorroShort

    /// One step of a route: a v3 pool, or (v3 zero) a v4 pool.
    struct Hop {
        address v3;
        PoolKey key;
    }

    address private transient _live; // the v3 pool a swap is under way in, for its callback
    bool private transient _locked;

    error OnlyPoolManager();
    error OnlyPool();
    error PoolRanDry();
    error Reentered();
    error TooLittle(uint256 got, uint256 wanted);
    error TooMuch(uint256 cost, uint256 limit);
    error QuoteResult(uint256 amount);
    error BadRoute();

    constructor(IPoolManager pm_, IV3Pool ethPool_, IWETH weth_, IERC20 usdg_, ICuratedListing listing_, IStockDesks stockDesks_) {
        poolManager = pm_;
        ethPool = ethPool_;
        weth = weth_;
        usdg = usdg_;
        listing = listing_;
        stockDesks = stockDesks_;
    }

    /// @dev ETH arrives from the PoolManager (taken out of a v4 pool) and from WETH (unwrapped for one).
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(weth)) revert OnlyPool();
    }

    modifier locked() {
        if (_locked) revert Reentered();
        _locked = true;
        _;
        _locked = false;
    }

    // ------------------------------------------------------------------ trades

    /// @notice Sell exactly `coinIn` of the coin (pulled from the caller) for at least `minUsdg`, sent to `to`.
    function sell(address coin, uint256 coinIn, uint256 minUsdg, address to) external locked returns (uint256 usdgOut) {
        (Hop[] memory hops, address[] memory tok) = route(coin);
        IERC20(coin).safeTransferFrom(msg.sender, address(this), coinIn);
        uint256 amount = coinIn;
        address held = coin;
        for (uint256 i = hops.length; i > 0; i--) {
            // Step i-1 backwards: it takes in what it gives out when buying, and gives out what it takes in.
            (address tin, address tout) = _ends(hops[i - 1], tok[i - 1], tok[i]);
            _convert(held, tout, amount);
            amount = _swap(hops[i - 1], tout, tin, amount, false, false);
            held = tin;
        }
        usdgOut = amount;
        if (usdgOut < minUsdg) revert TooLittle(usdgOut, minUsdg);
        usdg.safeTransfer(to, usdgOut);
    }

    /// @notice Buy exactly `coinOut` of the coin, sent to `to`, for at most `maxUsdg` (pulled from the caller).
    function buy(address coin, uint256 coinOut, uint256 maxUsdg, address to) external locked returns (uint256 usdgIn) {
        (Hop[] memory hops, address[] memory tok) = route(coin);
        uint256[] memory need = _needs(hops, tok, coinOut);
        usdgIn = need[0];
        if (usdgIn > maxUsdg) revert TooMuch(usdgIn, maxUsdg);
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        address held = address(usdg);
        for (uint256 i; i < hops.length; i++) {
            (address tin, address tout) = _ends(hops[i], tok[i], tok[i + 1]);
            _convert(held, tin, need[i]);
            _swap(hops[i], tin, tout, need[i + 1], true, false);
            held = tout;
        }
        IERC20(coin).safeTransfer(to, coinOut);
    }

    /// @notice USDG that selling `coinIn` brings now. Moves nothing (call it, do not send it).
    function quoteSell(address coin, uint256 coinIn) external returns (uint256 amount) {
        (Hop[] memory hops, address[] memory tok) = route(coin);
        amount = coinIn;
        for (uint256 i = hops.length; i > 0; i--) {
            (address tin, address tout) = _ends(hops[i - 1], tok[i - 1], tok[i]);
            amount = _quote(hops[i - 1], tout, tin, amount, false);
        }
    }

    /// @notice USDG that buying `coinOut` costs now. Moves nothing (call it, do not send it).
    function quoteBuy(address coin, uint256 coinOut) external returns (uint256) {
        (Hop[] memory hops, address[] memory tok) = route(coin);
        return _needs(hops, tok, coinOut)[0];
    }

    /// @notice Only for quoting one step: always reverts with QuoteResult. Moves nothing.
    function quoteHop(Hop calldata h, address tokenIn, address tokenOut, uint256 amount, bool exactOut) external {
        _swap(h, tokenIn, tokenOut, amount, exactOut, true);
    }

    // ------------------------------------------------------------------ the route

    /// @notice The steps from USDG to the coin, and the token each step starts from (tok[0] USDG) and ends with
    ///         (tok[n] the coin). Native ETH is address(0); WETH and ETH change into each other between steps.
    function route(address coin) public view returns (Hop[] memory hops, address[] memory tok) {
        CuratedDesk memory d = listing.deskOf(coin);
        Venue memory v = d.venue;
        Hop[] memory pre = new Hop[](8);
        address[] memory at = new address[](9);
        uint256 n;
        at[0] = address(usdg);
        address pairToken;
        if (v.kind == VENUE_V3) {
            address t0 = IV3Pool(v.pool).token0();
            pairToken = t0 == coin ? IV3Pool(v.pool).token1() : t0;
        } else {
            address c0 = Currency.unwrap(v.key.currency0);
            pairToken = c0 == coin ? Currency.unwrap(v.key.currency1) : c0;
        }
        if (v.pair == PAIR_ETH) {
            pre[n].v3 = address(ethPool);
            at[++n] = pairToken; // WETH, or native ETH after an unwrap
        } else if (v.pair == PAIR_STOCK) {
            (MarketParams memory m, PoolKey[] memory r, address v3Pool,,) = stockDesks.deskOf(v.stockDesk);
            if (m.loanToken != pairToken) revert BadRoute();
            if (v3Pool != address(0)) {
                pre[n].v3 = v3Pool;
                at[++n] = pairToken;
            } else {
                address cur = address(usdg);
                for (uint256 i; i < r.length; i++) {
                    pre[n].key = r[i];
                    cur = Currency.unwrap(r[i].currency0) == cur ? Currency.unwrap(r[i].currency1) : Currency.unwrap(r[i].currency0);
                    at[++n] = cur;
                }
                if (cur != pairToken) revert BadRoute();
            }
        }
        if (v.kind == VENUE_V3) pre[n].v3 = v.pool;
        else pre[n].key = v.key;
        at[++n] = coin;
        hops = new Hop[](n);
        tok = new address[](n + 1);
        for (uint256 i; i < n; i++) hops[i] = pre[i];
        for (uint256 i; i <= n; i++) tok[i] = at[i];
    }

    /// @dev What step `h` takes in and gives out, going from `from` to `to`: the same tokens, except that the
    ///      WETH/USDG pool deals in WETH where the route says native ETH.
    function _ends(Hop memory h, address from, address to) internal view returns (address tin, address tout) {
        tin = from;
        tout = to;
        if (h.v3 != address(0)) {
            if (tin == address(0)) tin = address(weth);
            if (tout == address(0)) tout = address(weth);
        }
    }

    /// @dev Turns `amount` of `have` into `want` where they are WETH and native ETH.
    function _convert(address have, address want, uint256 amount) internal {
        if (have == want) return;
        if (have == address(weth) && want == address(0)) weth.withdraw(amount);
        else if (have == address(0) && want == address(weth)) weth.deposit{value: amount}();
        else revert BadRoute();
    }

    /// @dev What each step needs going in, from the last back: need[n] = coinOut, need[0] the USDG.
    function _needs(Hop[] memory hops, address[] memory tok, uint256 coinOut) internal returns (uint256[] memory need) {
        need = new uint256[](hops.length + 1);
        need[hops.length] = coinOut;
        for (uint256 i = hops.length; i > 0; i--) {
            (address tin, address tout) = _ends(hops[i - 1], tok[i - 1], tok[i]);
            need[i - 1] = _quote(hops[i - 1], tin, tout, need[i], true);
        }
    }

    function _quote(Hop memory h, address tin, address tout, uint256 amount, bool exactOut) internal returns (uint256 got) {
        (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.quoteHop, (h, tin, tout, amount, exactOut)));
        if (ok || err.length != 36 || bytes4(err) != QuoteResult.selector) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
        assembly {
            got := mload(add(err, 36))
        }
    }

    // ------------------------------------------------------------------ one step

    /// @dev Trades `tin` for `tout` in one pool, paying from what is held here. Exact input: `amount` in, returns
    ///      what came out. Exact output: `amount` out, returns what went in. Quoting reverts with that number.
    function _swap(Hop memory h, address tin, address tout, uint256 amount, bool exactOut, bool quoting) internal returns (uint256) {
        if (h.v3 != address(0)) return _swapV3(h.v3, tin, tout, amount, exactOut, quoting);
        bool zeroForOne = Currency.unwrap(h.key.currency0) == tin;
        if (zeroForOne ? Currency.unwrap(h.key.currency1) != tout : (Currency.unwrap(h.key.currency1) != tin || Currency.unwrap(h.key.currency0) != tout)) {
            revert BadRoute();
        }
        return abi.decode(poolManager.unlock(abi.encode(h.key, zeroForOne, amount, exactOut, quoting)), (uint256));
    }

    function _swapV3(address pool, address tin, address tout, uint256 amount, bool exactOut, bool quoting) internal returns (uint256) {
        address t0 = IV3Pool(pool).token0();
        address t1 = IV3Pool(pool).token1();
        bool zeroForOne = t0 == tin;
        if (zeroForOne ? t1 != tout : (t1 != tin || t0 != tout)) revert BadRoute();
        _live = pool;
        (int256 a0, int256 a1) = IV3Pool(pool).swap(
            address(this),
            zeroForOne,
            exactOut ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            abi.encode(tin, amount, exactOut, quoting)
        );
        _live = address(0);
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        if (exactOut ? uint256(-dOut) != amount : uint256(dIn) != amount) revert PoolRanDry();
        return exactOut ? uint256(dIn) : uint256(-dOut);
    }

    /// @dev Uniswap v3 sends what was bought first, then calls here to be paid.
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        if (msg.sender != _live || msg.sender == address(0)) revert OnlyPool();
        (address tin, uint256 amount, bool exactOut, bool quoting) = abi.decode(data, (address, uint256, bool, bool));
        bool zeroForOne = IV3Pool(msg.sender).token0() == tin;
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        if (quoting) {
            if (exactOut ? uint256(-dOut) != amount : uint256(dIn) != amount) revert PoolRanDry();
            revert QuoteResult(exactOut ? uint256(dIn) : uint256(-dOut));
        }
        IERC20(tin).safeTransfer(msg.sender, uint256(dIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amount, bool exactOut, bool quoting) =
            abi.decode(data, (PoolKey, bool, uint256, bool, bool));
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactOut ? int256(amount) : -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 dIn, int128 dOut) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (dIn > 0 || dOut < 0) revert PoolRanDry();
        uint256 paid = uint256(uint128(-dIn));
        uint256 got = uint256(uint128(dOut));
        if (exactOut ? got != amount : paid != amount) revert PoolRanDry();
        if (quoting) revert QuoteResult(exactOut ? paid : got);
        if (Currency.unwrap(cin) == address(0)) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(cin);
            IERC20(Currency.unwrap(cin)).safeTransfer(address(poolManager), paid);
            poolManager.settle();
        }
        poolManager.take(cout, address(this), got);
        return abi.encode(exactOut ? paid : got);
    }
}
