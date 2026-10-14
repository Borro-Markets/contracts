// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IMorpho, MarketParams, Market, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {BorroHookShare} from "./BorroHookShare.sol";
import {IVault, IDesks, IPots, IFeed, IMsgSender, ISymbol} from "./BorroHookDeps.sol";
import {BorroHookMath} from "./BorroHookMath.sol";

/// @title BorroHook
/// @notice One Uniswap v4 hook for Borro's USDG/stock pools, with four things in it:
///         1. Liquidity that earns rent. LPs deposit USDG and the stock and get this pool's ERC-20 shares. The hook
///            keeps a buffer of each token for swaps and lends the rest on Borro: the stock to the stock's Borro
///            vault (shorters pay it rent), USDG to Borro's USDG vault. Swaps price against everything the LPs own
///            (a constant-product curve over buffer plus lent), and draw on the vault when the buffer runs short.
///         2. A squeeze fee. On top of the LPs' fee, a surcharge that grows with how much of the stock is borrowed
///            on Borro, taken in USDG. Anyone can flush it: part buys the stock (from the pool, never above the
///            curve or the feed price) and gives it to the stock's Borro lenders, the rest funds the rent and prize
///            pots.
///         3. A discount for wallets holding $BORRO or Borro lending (bUSDG, the stock's vault shares, this pool's
///            shares).
///         4. A price guard. A swap that ends more than a set distance from the stock's Chainlink price, or any
///            swap while that price is older than a set age, is refused, unless it moves the pool toward the feed.
/// @dev What the owner (the Hoard Safe) can and cannot do. Pools are listed at deploy, once per stock (which vault
///      lends the stock), and then listing is closed for good (closeRegistry), before the Safe takes over: no
///      later pool can point at a vault other than Borro's own. The owner tunes the numbers below inside the hard
///      caps written here, names routers trusted to report
///      who is swapping, and can pause new deposits into a pool. It has no path to anyone's money: no sweep, no
///      withdraw, no upgrade. Withdrawals work whatever the owner sets, whatever the feed says, and whatever the
///      vaults can pay: what the vaults cannot pay now is handed over as the vault's own shares, which keep earning
///      and redeem from the vault directly once its stock or USDG is free.
///      Money held for LPs may sit here as tokens or as the PoolManager's ERC-6909 claims (swaps in are minted as
///      claims, to need no tokens in the PoolManager); per pool only the numbers are kept, and the hook's tokens
///      plus claims always cover every pool's buffer plus its held surcharge.
contract BorroHook is Ownable2Step, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using MarketParamsLib for MarketParams;

    // ---------------------------------------------------------------- hard caps

    uint256 public constant PIPS = 1_000_000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BASE_FEE_PIPS = 10_000; // the LPs' fee never passes 1%
    uint256 public constant MAX_SQUEEZE_PIPS = 20_000; // the surcharge never passes 2%
    uint256 public constant MAX_DISCOUNT_BPS = 5_000; // a holder never gets more than half off
    uint256 public constant MIN_GUARD_BPS = 50;
    uint256 public constant MAX_GUARD_BPS = 1_500;
    uint256 public constant MIN_FEED_AGE = 1 hours;
    uint256 public constant MAX_FEED_AGE = 4 days;
    uint256 public constant MIN_BUFFER_BPS = 1_000; // at least a tenth of each side stays in the pool
    uint256 public constant MIN_SHARES = 1_000; // locked forever by the first deposit, at least
    uint256 public constant MIN_LOCK_USDG = 1e6; // and at least $1 of its USDG (and that part of its stock) with them
    int24 public constant TICK_SPACING = 60;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant ROUTER_GAS = 30_000;

    IPoolManager public immutable poolManager;
    IDesks public immutable desks; // BorroShort: where a stock's market, feed and the pots are read
    IMorpho public immutable morpho;
    IERC20 public immutable usdg;
    IVault public immutable usdgVault; // Borro's USDG vault (bUSDG)
    IERC20 public immutable borro; // $BORRO
    address public immutable shareImpl;

    // ---------------------------------------------------------------- the numbers the owner tunes

    uint24 public baseFeePips = 3_000; // 0.30% to the LPs
    uint24 public squeezeMaxPips = 10_000; // up to 1% more when the stock is fully borrowed
    uint16 public squeezeStartBps = 5_000; // the surcharge starts once half the stock is borrowed
    uint16 public discountBps = 5_000; // holders pay half
    uint24 public feeFloorPips = 500; // nobody pays less than 0.05%
    uint16 public guardBps = 300; // a swap may not end more than 3% from the feed
    uint32 public maxFeedAge = 25 hours; // the stock feeds' heartbeat is a day
    uint16 public bufferBps = 3_000; // 30% of each side stays in the pool, the rest is lent
    bool public registryClosed; // set once by closeRegistry: no pool can ever be listed again
    uint16 public lenderShareBps = 5_000; // half the surcharge to the stock's lenders, half to the pots
    uint256 public minBorro = 1_000e18; // $BORRO a holder needs
    uint256 public minLendUsdg = 100e6; // or this much lent on Borro, in USDG
    mapping(address router => bool) public trustedRouter;

    // ---------------------------------------------------------------- pools

    struct Pool {
        // set once, at registration
        address stock;
        bool usdgIs0; // currency0 is USDG
        bool depositsPaused;
        uint8 stockDecimals;
        IVault stockVault;
        address feed;
        uint256 feedScale; // turns the feed's answer into 8 decimals: answer * 1e8 / feedScale
        bytes32 marketId; // the Morpho market shorts borrow this stock from
        BorroHookShare share;
        // live
        uint128 bufUsdg; // USDG in the pool for swaps (tokens or claims here)
        uint128 bufStock;
        uint128 lentUsdg; // bUSDG shares owned for this pool
        uint128 lentStock; // stock vault shares owned for this pool
        uint128 resUsdg; // what the curve prices against: buffer plus the value of what is lent, as of the last sync
        uint128 resStock;
        uint128 squeezeHeld; // surcharge waiting for flush, in USDG
        uint128 stockPerShare; // stock vault assets per 1e18 shares, at the last sync
        uint128 feesUsdg; // every LP fee taken in USDG, ever
        uint128 feesStock; // every LP fee taken in the stock, ever
        uint64 lastSync;
        uint64 startedAt; // the first deposit
    }

    mapping(PoolId => Pool) internal _pools;
    mapping(address stock => PoolId) public poolOfStock;
    PoolId[] internal _ids;
    uint128 public usdgPerShare; // bUSDG assets per 1e18 shares, at the last sync of any pool

    bool private transient _lock;
    bool private transient _converting;

    // ---------------------------------------------------------------- events and errors

    event Registered(PoolId indexed id, address indexed stock, address stockVault, address share, bytes32 marketId, address feed);
    event Deposited(PoolId indexed id, address indexed from, address indexed to, uint256 usdg, uint256 stock, uint256 shares);
    event Withdrawn(
        PoolId indexed id,
        address indexed from,
        address indexed to,
        uint256 shares,
        uint256 usdg,
        uint256 stock,
        uint256 usdgVaultShares,
        uint256 stockVaultShares
    );
    /// @dev The custom-curve swap record indexers read (amounts from the swapper's side, fees to the LPs).
    event HookSwap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint128 hookLPfeeAmount0, uint128 hookLPfeeAmount1);
    event Squeeze(PoolId indexed id, address indexed trader, uint256 feePips, uint256 surchargePips, bool holder, uint256 surcharge);
    event Flushed(PoolId indexed id, uint256 toPots, uint256 toLenders, uint256 stockToLenders);
    event Synced(PoolId indexed id, uint256 resUsdg, uint256 resStock);
    event Rebalanced(PoolId indexed id, int256 usdgLent, int256 stockLent);
    event ParamsSet();
    event RouterSet(address indexed router, bool trusted);
    event DepositsPaused(PoolId indexed id, bool paused);

    error OnlyPoolManager();
    error Locked();
    error NotRegistered();
    error AlreadyRegistered();
    error BadDesk();
    error RegistryClosed();
    error OutOfBounds();
    error NoDirectLiquidity();
    error Stale();
    error Guard(uint256 poolPriceE8, uint256 feedPriceE8);
    error NotEnoughFree();
    error TooMuch();
    error TooLittle(uint256 got, uint256 wanted);
    error IsPaused();
    error Zero();
    error OutOfGas();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier locked() {
        if (_lock) revert Locked();
        _lock = true;
        _;
        _lock = false;
    }

    constructor(IPoolManager poolManager_, IDesks desks_, IVault usdgVault_, IERC20 borro_, address owner_) Ownable(owner_) {
        poolManager = poolManager_;
        desks = desks_;
        morpho = desks_.morpho();
        usdgVault = usdgVault_;
        usdg = IERC20(usdgVault_.asset());
        borro = borro_;
        shareImpl = address(new BorroHookShare());
        Hooks.validateHookPermissions(IHooks(address(this)), permissions());
        usdg.forceApprove(address(usdgVault_), type(uint256).max);
    }

    function permissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    // ================================================================= owner

    /// @notice List a stock: a USDG/stock pool on this hook, its stock lent to `stockVault`. Once per stock, forever.
    function register(bytes32 deskId, IVault stockVault) external onlyOwner returns (PoolId id) {
        if (registryClosed) revert RegistryClosed();
        (MarketParams memory m,,,, address feed) = desks.deskOf(deskId);
        address stock = m.loanToken;
        if (stock == address(0) || feed == address(0) || Id.unwrap(m.id()) != deskId) revert BadDesk();
        if (stockVault.asset() != stock) revert BadDesk();
        if (PoolId.unwrap(poolOfStock[stock]) != bytes32(0)) revert AlreadyRegistered();
        PoolKey memory key = keyFor(stock);
        id = key.toId();
        Pool storage p = _pools[id];
        p.stock = stock;
        p.usdgIs0 = address(usdg) < stock;
        p.stockDecimals = ISymbol(stock).decimals();
        p.stockVault = stockVault;
        p.feed = feed;
        p.feedScale = 10 ** IFeed(feed).decimals();
        p.marketId = deskId;
        string memory sym = ISymbol(stock).symbol();
        BorroHookShare s = BorroHookShare(Clones.clone(shareImpl));
        s.initialize(string.concat("Borro ", sym, " pool"), string.concat("bp", sym));
        p.share = s;
        poolOfStock[stock] = id;
        _ids.push(id);
        IERC20(stock).forceApprove(address(stockVault), type(uint256).max);
        emit Registered(id, stock, address(stockVault), address(s), deskId, feed);
    }

    /// @notice No more listings, ever. The deploy calls it after listing Borro's stocks, before the Safe takes over.
    function closeRegistry() external onlyOwner {
        registryClosed = true;
        emit ParamsSet();
    }

    function setFees(uint24 base, uint24 squeezeMax, uint16 squeezeStart, uint24 floor) external onlyOwner {
        if (base > MAX_BASE_FEE_PIPS || squeezeMax > MAX_SQUEEZE_PIPS || squeezeStart >= BPS || floor > base) revert OutOfBounds();
        (baseFeePips, squeezeMaxPips, squeezeStartBps, feeFloorPips) = (base, squeezeMax, squeezeStart, floor);
        emit ParamsSet();
    }

    function setDiscount(uint16 discount, uint256 minBorro_, uint256 minLendUsdg_) external onlyOwner {
        if (discount > MAX_DISCOUNT_BPS) revert OutOfBounds();
        (discountBps, minBorro, minLendUsdg) = (discount, minBorro_, minLendUsdg_);
        emit ParamsSet();
    }

    function setGuard(uint16 band, uint32 feedAge) external onlyOwner {
        if (band < MIN_GUARD_BPS || band > MAX_GUARD_BPS || feedAge < MIN_FEED_AGE || feedAge > MAX_FEED_AGE) revert OutOfBounds();
        (guardBps, maxFeedAge) = (band, feedAge);
        emit ParamsSet();
    }

    function setBuffer(uint16 buffer) external onlyOwner {
        if (buffer < MIN_BUFFER_BPS || buffer > BPS) revert OutOfBounds();
        bufferBps = buffer;
        emit ParamsSet();
    }

    function setLenderShare(uint16 share) external onlyOwner {
        if (share > BPS) revert OutOfBounds();
        lenderShareBps = share;
        emit ParamsSet();
    }

    function setRouter(address router, bool trusted) external onlyOwner {
        trustedRouter[router] = trusted;
        emit RouterSet(router, trusted);
    }

    /// @notice Stop or allow new deposits into one pool. Withdrawals and swaps are never affected.
    function setDepositsPaused(PoolId id, bool paused) external onlyOwner {
        _registered(id).depositsPaused = paused;
        emit DepositsPaused(id, paused);
    }

    // ================================================================= hook callbacks

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _registered(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert NoDirectLiquidity();
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_lock) revert Locked();
        PoolId id = key.toId();
        Pool storage p = _registered(id);
        uint256 feedE8 = _feedPrice(p);
        bool usdgIn = params.zeroForOne == p.usdgIs0;
        bool exactIn = params.amountSpecified < 0;
        uint256 specified = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        address trader = _trader(sender);
        (uint256 lpPips, uint256 surPips, bool holder) = _fees(p, trader, feedE8);
        BorroHookMath.Fill memory f = _fill(p, usdgIn, exactIn, specified, lpPips, surPips);
        if (f.amountIn == 0 || f.amountOut == 0) revert Zero();
        if (f.amountIn > uint128(type(int128).max) || f.amountOut > uint128(type(int128).max)) revert TooMuch();

        // The reserves after, and the guard on them.
        uint256 before = _poolPrice(p.resUsdg, p.resStock, p.stockDecimals);
        if (usdgIn) {
            p.resUsdg += uint128(f.amountIn - f.surcharge);
            p.resStock -= uint128(f.amountOut);
            p.feesUsdg += uint128(f.lpFee);
        } else {
            p.resStock += uint128(f.amountIn);
            p.resUsdg -= uint128(f.usdgLeaving);
            p.feesStock += uint128(f.lpFee);
        }
        _guard(before, _poolPrice(p.resUsdg, p.resStock, p.stockDecimals), feedE8);

        // Move the tokens: the input is taken as claims, the output paid from the buffer, then from the vault.
        (Currency cIn, Currency cOut) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        poolManager.mint(address(this), cIn.toId(), f.amountIn);
        if (usdgIn) {
            p.bufUsdg += uint128(f.amountIn - f.surcharge);
            _drawBuffer(p, false, f.amountOut);
        } else {
            p.bufStock += uint128(f.amountIn);
            _drawBuffer(p, true, f.usdgLeaving);
        }
        p.squeezeHeld += uint128(f.surcharge);
        _payPoolManager(cOut, f.amountOut);

        emit Squeeze(id, trader, lpPips + surPips, surPips, holder, f.surcharge);
        _emitSwap(id, sender, params.zeroForOne, f);
        BeforeSwapDelta d = exactIn
            ? toBeforeSwapDelta(int128(int256(f.amountIn)), -int128(int256(f.amountOut)))
            : toBeforeSwapDelta(-int128(int256(f.amountOut)), int128(int256(f.amountIn)));
        return (IHooks.beforeSwap.selector, d, 0);
    }

    /// @dev Only to turn claims back into tokens, from inside this contract's own calls.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_converting) revert Locked();
        (Currency c, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), c.toId(), amount);
        poolManager.take(c, address(this), amount);
        return "";
    }

    // ================================================================= LPs

    /// @notice Add liquidity. Takes the two tokens in the pool's current ratio, at most the amounts given, and
    ///         returns shares of the pool. The first deposit sets the price and must be within the guard of the feed.
    function deposit(PoolId id, uint256 usdgMax, uint256 stockMax, uint256 minShares, address to)
        external
        locked
        returns (uint256 shares, uint256 usdgIn, uint256 stockIn)
    {
        Pool storage p = _registered(id);
        if (p.depositsPaused) revert IsPaused();
        _sync(id, p);
        uint256 supply = p.share.totalSupply();
        if (supply == 0) {
            uint256 feedE8 = _feedPrice(p);
            _guard(type(uint256).max, _poolPrice(usdgMax, stockMax, p.stockDecimals), feedE8);
            (usdgIn, stockIn) = (usdgMax, stockMax);
            // Review 2026-10-08: the locked part must hold real money, so that once every LP has left, what stays
            // still carries the pool's price (1,000 shares alone held a few wei of USDG, 100x off the feed).
            uint256 lock;
            (shares, lock) = BorroHookMath.firstShares(usdgIn, stockIn, MIN_SHARES, MIN_LOCK_USDG);
            if (shares <= lock) revert TooLittle(shares, lock + 1);
            shares -= lock;
            p.share.mint(DEAD, lock);
            p.startedAt = uint64(block.timestamp);
        } else {
            if (p.resUsdg == 0 || p.resStock == 0) revert Zero();
            shares = Math.min(Math.mulDiv(usdgMax, supply, p.resUsdg), Math.mulDiv(stockMax, supply, p.resStock));
            usdgIn = Math.mulDiv(shares, p.resUsdg, supply, Math.Rounding.Ceil);
            stockIn = Math.mulDiv(shares, p.resStock, supply, Math.Rounding.Ceil);
        }
        if (shares == 0 || shares < minShares) revert TooLittle(shares, minShares);
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        IERC20(p.stock).safeTransferFrom(msg.sender, address(this), stockIn);
        p.bufUsdg += uint128(usdgIn);
        p.bufStock += uint128(stockIn);
        p.resUsdg += uint128(usdgIn);
        p.resStock += uint128(stockIn);
        p.share.mint(to, shares);
        emit Deposited(id, msg.sender, to, usdgIn, stockIn, shares);
        _rebalance(id, p);
    }

    /// @notice Take liquidity out: your share of the pool's tokens, and of what it has lent. Lent money the vaults
    ///         can pay now comes as tokens; the rest comes as the vaults' own shares (bUSDG, the stock's vault
    ///         share), which keep earning and redeem from the vault once it is free. Always works: never paused, no
    ///         feed needed. The minimums count those vault shares at their value now.
    function withdraw(PoolId id, uint256 shares, uint256 minUsdg, uint256 minStock, address to)
        external
        locked
        returns (uint256 usdgOut, uint256 stockOut, uint256 usdgVaultShares, uint256 stockVaultShares)
    {
        Pool storage p = _registered(id);
        uint256 supply = p.share.totalSupply();
        if (shares == 0) revert Zero();
        p.share.burn(msg.sender, shares);

        uint256 bufU = Math.mulDiv(p.bufUsdg, shares, supply);
        uint256 bufS = Math.mulDiv(p.bufStock, shares, supply);
        uint256 lentU = Math.mulDiv(p.lentUsdg, shares, supply);
        uint256 lentS = Math.mulDiv(p.lentStock, shares, supply);
        p.bufUsdg -= uint128(bufU);
        p.bufStock -= uint128(bufS);
        p.lentUsdg -= uint128(lentU);
        p.lentStock -= uint128(lentS);
        p.resUsdg -= uint128(Math.mulDiv(p.resUsdg, shares, supply));
        p.resStock -= uint128(Math.mulDiv(p.resStock, shares, supply));

        Currency cU = Currency.wrap(address(usdg));
        Currency cS = Currency.wrap(p.stock);
        _send(cU, to, bufU);
        _send(cS, to, bufS);
        uint256 got;
        (got, usdgVaultShares) = _redeemOrHand(usdgVault, lentU, to);
        usdgOut = bufU + got;
        (got, stockVaultShares) = _redeemOrHand(p.stockVault, lentS, to);
        stockOut = bufS + got;

        uint256 worthU = usdgOut + (usdgVaultShares == 0 ? 0 : usdgVault.previewRedeem(usdgVaultShares));
        uint256 worthS = stockOut + (stockVaultShares == 0 ? 0 : p.stockVault.previewRedeem(stockVaultShares));
        if (worthU < minUsdg) revert TooLittle(worthU, minUsdg);
        if (worthS < minStock) revert TooLittle(worthS, minStock);
        emit Withdrawn(id, msg.sender, to, shares, usdgOut, stockOut, usdgVaultShares, stockVaultShares);
    }

    // ================================================================= anyone

    /// @notice Bring the pool's prices up to date with the rent its lent side has earned, and move money between
    ///         the pool's buffer and the vaults toward the buffer target. Anyone can call it; the keeper does.
    function rebalance(PoolId id) external locked {
        Pool storage p = _registered(id);
        _sync(id, p);
        _rebalance(id, p);
    }

    /// @notice Pay out the pool's held surcharge: lenderShareBps of it buys the stock from the pool (at the curve or
    ///         the feed price, whichever gives less stock) and gives it to the stock's Borro vault, so its lenders
    ///         earn it; the rest funds Borro's rent and prize pots. Anyone can call it.
    function flush(PoolId id) external locked returns (uint256 toPots, uint256 toLenders, uint256 stockToLenders) {
        Pool storage p = _registered(id);
        uint256 held = p.squeezeHeld;
        if (held == 0) return (0, 0, 0);
        toLenders = held * lenderShareBps / BPS;
        toPots = held - toLenders;
        if (toLenders != 0) {
            (bool ok, uint256 feedE8) = _feedPriceView(p);
            if (ok) {
                uint256 curve = Math.mulDiv(p.resStock, toLenders, uint256(p.resUsdg) + toLenders);
                uint256 atFeed = Math.mulDiv(toLenders * 1e8, 10 ** p.stockDecimals, feedE8 * 1e6);
                stockToLenders = Math.min(curve, atFeed);
                if (stockToLenders != 0 && _tryDrawBuffer(p, false, stockToLenders)) {
                    p.bufStock -= uint128(stockToLenders);
                    p.resStock -= uint128(stockToLenders);
                    p.bufUsdg += uint128(toLenders);
                    p.resUsdg += uint128(toLenders);
                    p.squeezeHeld -= uint128(toLenders);
                    _real(Currency.wrap(p.stock), stockToLenders);
                    IERC20(p.stock).safeTransfer(address(p.stockVault), stockToLenders);
                } else {
                    (toLenders, stockToLenders) = (0, 0);
                }
            } else {
                toLenders = 0;
            }
        }
        address pots = desks.rewards();
        if (toPots != 0 && pots != address(0)) {
            p.squeezeHeld -= uint128(toPots);
            _real(Currency.wrap(address(usdg)), toPots);
            usdg.forceApprove(pots, toPots);
            IPots(pots).fund(toPots);
        } else {
            toPots = 0;
        }
        emit Flushed(id, toPots, toLenders, stockToLenders);
    }

    // ================================================================= views

    function keyFor(address stock) public view returns (PoolKey memory key) {
        (address a, address b) = address(usdg) < stock ? (address(usdg), stock) : (stock, address(usdg));
        key = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function pools() external view returns (PoolId[] memory) {
        return _ids;
    }

    function poolOf(PoolId id) external view returns (Pool memory) {
        return _pools[id];
    }

    /// @notice How much of the stock is borrowed on Borro, in bps, and the surcharge that makes.
    function squeeze(PoolId id) external view returns (uint256 useBps, uint256 surchargePips) {
        return _squeeze(_pools[id]);
    }

    function _squeeze(Pool storage p) internal view returns (uint256 useBps, uint256 surchargePips) {
        Market memory m = morpho.market(Id.wrap(p.marketId));
        useBps = m.totalSupplyAssets == 0 ? 0 : uint256(m.totalBorrowAssets) * BPS / m.totalSupplyAssets;
        if (useBps > BPS) useBps = BPS;
        surchargePips = useBps <= squeezeStartBps ? 0 : squeezeMaxPips * (useBps - squeezeStartBps) / (BPS - squeezeStartBps);
    }

    /// @notice The fee `trader` would pay on this pool now: the LPs' part and the surcharge, in pips, and whether
    ///         they count as a holder. (Quotes are in BorroHookLens.)
    function feeFor(PoolId id, address trader) external view returns (uint256 lpPips, uint256 surchargePips, bool holder) {
        Pool storage p = _pools[id];
        (, uint256 feedE8) = _feedPriceView(p);
        return _fees(p, trader, feedE8);
    }

    // ================================================================= internals: pricing

    function _registered(PoolId id) internal view returns (Pool storage p) {
        p = _pools[id];
        if (p.stock == address(0)) revert NotRegistered();
    }

    /// @dev USD per whole stock, 8 decimals.
    function _poolPrice(uint256 resU, uint256 resS, uint8 stockDecimals) internal pure returns (uint256) {
        if (resS == 0) return type(uint256).max;
        return Math.mulDiv(resU * 1e8, 10 ** stockDecimals, resS * 1e6);
    }

    function _feedPriceView(Pool storage p) internal view returns (bool fresh, uint256 priceE8) {
        (, int256 answer,, uint256 updatedAt,) = IFeed(p.feed).latestRoundData();
        if (answer <= 0 || updatedAt > block.timestamp) return (false, 0);
        priceE8 = uint256(answer) * 1e8 / p.feedScale;
        fresh = priceE8 != 0 && block.timestamp - updatedAt <= maxFeedAge;
    }

    function _feedPrice(Pool storage p) internal view returns (uint256 priceE8) {
        bool fresh;
        (fresh, priceE8) = _feedPriceView(p);
        if (!fresh) revert Stale();
    }

    /// @dev A swap may end anywhere within guardBps of the feed, or anywhere closer to the feed than it began.
    function _guard(uint256 beforeE8, uint256 afterE8, uint256 feedE8) internal view {
        uint256 devAfter = _dev(afterE8, feedE8);
        if (devAfter <= guardBps) return;
        if (beforeE8 != type(uint256).max && devAfter < _dev(beforeE8, feedE8)) return;
        revert Guard(afterE8, feedE8);
    }

    function _dev(uint256 a, uint256 feedE8) internal pure returns (uint256) {
        if (a == type(uint256).max) return type(uint256).max;
        uint256 diff = a > feedE8 ? a - feedE8 : feedE8 - a;
        return diff * BPS / feedE8;
    }

    function _trader(address sender) internal view returns (address) {
        if (trustedRouter[sender]) {
            try IMsgSender(sender).msgSender{gas: ROUTER_GAS}() returns (address who) {
                if (who != address(0)) return who;
            } catch {}
        }
        return tx.origin;
    }

    function _fees(Pool storage p, address trader, uint256 feedE8) internal view returns (uint256 lpPips, uint256 surPips, bool holder) {
        lpPips = baseFeePips;
        (, surPips) = _squeeze(p);
        holder = _holds(p, trader, feedE8);
        if (holder) {
            lpPips = lpPips * (BPS - discountBps) / BPS;
            surPips = surPips * (BPS - discountBps) / BPS;
        }
        if (lpPips + surPips < feeFloorPips) lpPips = feeFloorPips - surPips;
    }

    /// @dev $BORRO, or lending on Borro worth minLendUsdg: bUSDG, this stock's vault shares, this pool's shares.
    function _holds(Pool storage p, address who, uint256 feedE8) internal view returns (bool) {
        if (minBorro != 0 && borro.balanceOf(who) >= minBorro) return true;
        if (minLendUsdg == 0) return false;
        return BorroHookMath.lends(
            BorroHookMath.Lending(usdgVault, usdgPerShare, p.stockVault, p.stockPerShare, address(p.share), p.resUsdg, p.resStock, p.stockDecimals, feedE8),
            who,
            minLendUsdg
        );
    }

    function _fill(Pool storage p, bool usdgIn, bool exactIn, uint256 amount, uint256 lpPips, uint256 surPips)
        internal
        view
        returns (BorroHookMath.Fill memory)
    {
        return BorroHookMath.fill(p.resUsdg, p.resStock, usdgIn, exactIn, amount, lpPips, surPips);
    }

    function _emitSwap(PoolId id, address sender, bool zeroForOne, BorroHookMath.Fill memory f) internal {
        int128 inA = int128(int256(f.amountIn));
        int128 outA = -int128(int256(f.amountOut));
        (int128 a0, int128 a1) = zeroForOne ? (inA, outA) : (outA, inA);
        (uint128 fee0, uint128 fee1) = zeroForOne ? (uint128(f.lpFee), uint128(0)) : (uint128(0), uint128(f.lpFee));
        emit HookSwap(PoolId.unwrap(id), sender, a0, a1, fee0, fee1);
    }

    // ================================================================= internals: money

    /// @dev Take `amount` out of the pool's buffer of USDG (`isUsdg`) or the stock, first drawing what the buffer
    ///      lacks from the vault. A swap that needs more than the vault can pay now is refused.
    function _drawBuffer(Pool storage p, bool isUsdg, uint256 amount) internal {
        if (!_tryDrawBuffer(p, isUsdg, amount)) revert NotEnoughFree();
        if (isUsdg) p.bufUsdg -= uint128(amount);
        else p.bufStock -= uint128(amount);
    }

    /// @dev Makes sure the pool's buffer holds `amount`, drawing the shortfall from the vault. False if it cannot.
    function _tryDrawBuffer(Pool storage p, bool isUsdg, uint256 amount) internal returns (bool) {
        uint256 buf = isUsdg ? p.bufUsdg : p.bufStock;
        if (buf >= amount) return true;
        uint256 need = amount - buf;
        IVault v = isUsdg ? usdgVault : p.stockVault;
        uint256 owned = isUsdg ? p.lentUsdg : p.lentStock;
        if (owned == 0 || v.previewWithdraw(need) > owned) return false;
        uint256 g = gasleft();
        try v.withdraw(need, address(this), address(this)) returns (uint256 burned) {
            if (burned > owned) revert NotEnoughFree();
            if (isUsdg) {
                p.lentUsdg -= uint128(burned);
                p.bufUsdg += uint128(need);
            } else {
                p.lentStock -= uint128(burned);
                p.bufStock += uint128(need);
            }
            return true;
        } catch {
            _gasCheck(g);
            return false;
        }
    }

    /// @dev After a call that failed inside try/catch: if it failed by running out of gas, fail the whole
    ///      transaction, so a gas estimate can never be low enough to skip a step. A starved call leaves about the
    ///      1/64 the EVM keeps back, plus a little its inner frames hand back when an out-of-gas deep inside bubbles up
    ///      as a revert (seen on the real NVDA vault: its token transfer ran out); a call that simply refused leaves
    ///      nearly all of it. Under 1/32 left counts as starved.
    function _gasCheck(uint256 before) internal view {
        if (gasleft() < before / 32) revert OutOfGas();
    }

    /// @dev Pays `amount` of `c` to the PoolManager inside a swap: claims first, then tokens.
    function _payPoolManager(Currency c, uint256 amount) internal {
        uint256 claims = poolManager.balanceOf(address(this), c.toId());
        uint256 fromClaims = claims < amount ? claims : amount;
        if (fromClaims != 0) poolManager.burn(address(this), c.toId(), fromClaims);
        uint256 rest = amount - fromClaims;
        if (rest != 0) {
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(poolManager), rest);
            poolManager.settle();
        }
    }

    /// @dev Makes sure this contract holds `amount` of `c` as tokens, turning claims into tokens if it must.
    function _real(Currency c, uint256 amount) internal {
        uint256 bal = IERC20(Currency.unwrap(c)).balanceOf(address(this));
        if (bal >= amount) return;
        _converting = true;
        poolManager.unlock(abi.encode(c, amount - bal));
        _converting = false;
    }

    /// @dev Like _real, but never fails: returns how much of `amount` this contract holds as tokens afterwards.
    function _realUpTo(Currency c, uint256 amount) internal returns (uint256) {
        IERC20 t = IERC20(Currency.unwrap(c));
        uint256 bal = t.balanceOf(address(this));
        if (bal < amount) {
            _converting = true;
            uint256 g = gasleft();
            try poolManager.unlock(abi.encode(c, amount - bal)) {} catch {
                _gasCheck(g);
            }
            _converting = false;
            bal = t.balanceOf(address(this));
        }
        return bal < amount ? bal : amount;
    }

    /// @dev Sends `amount` of `c` to `to` as tokens; if claims cannot be turned into tokens right now (the
    ///      PoolManager is busy in someone else's call), the rest goes as ERC-6909 claims, redeemable any time.
    function _send(Currency c, address to, uint256 amount) internal {
        if (amount == 0) return;
        IERC20 t = IERC20(Currency.unwrap(c));
        uint256 bal = t.balanceOf(address(this));
        if (bal < amount) {
            _converting = true;
            uint256 g = gasleft();
            try poolManager.unlock(abi.encode(c, amount - bal)) {} catch {
                _gasCheck(g);
            }
            _converting = false;
            bal = t.balanceOf(address(this));
        }
        uint256 asTokens = bal < amount ? bal : amount;
        if (asTokens != 0) t.safeTransfer(to, asTokens);
        if (amount > asTokens) poolManager.transfer(to, c.toId(), amount - asTokens);
    }

    /// @dev Redeems `shares` of `v` to `to`; what the vault cannot pay now is handed over as the shares themselves.
    function _redeemOrHand(IVault v, uint256 shares, address to) internal returns (uint256 assets, uint256 handed) {
        if (shares == 0) return (0, 0);
        uint256 g = gasleft();
        try v.redeem(shares, to, address(this)) returns (uint256 a) {
            return (a, 0);
        } catch {
            _gasCheck(g);
        }
        uint256 freeShares = v.previewWithdraw(_free(v));
        if (freeShares > shares) freeShares = shares;
        if (freeShares > 1) {
            g = gasleft();
            try v.redeem(freeShares - 1, to, address(this)) returns (uint256 a) {
                assets = a;
                shares -= freeShares - 1;
            } catch {
                _gasCheck(g);
            }
        }
        handed = shares;
        IERC20(address(v)).safeTransfer(to, handed);
    }

    function _free(IVault v) internal view returns (uint256) {
        return BorroHookMath.free(v, morpho);
    }

    /// @dev Values what the pool has lent at the vaults' prices now, so the curve counts the rent earned.
    function _sync(PoolId id, Pool storage p) internal {
        usdgPerShare = uint128(usdgVault.previewRedeem(1e18));
        p.stockPerShare = uint128(p.stockVault.previewRedeem(1e18));
        p.resUsdg = uint128(p.bufUsdg + (p.lentUsdg == 0 ? 0 : usdgVault.previewRedeem(p.lentUsdg)));
        p.resStock = uint128(p.bufStock + (p.lentStock == 0 ? 0 : p.stockVault.previewRedeem(p.lentStock)));
        p.lastSync = uint64(block.timestamp);
        emit Synced(id, p.resUsdg, p.resStock);
    }

    /// @dev Moves each side toward bufferBps of its reserve kept in the pool, the rest lent, with a tenth of slack
    ///      so it does not churn. A vault that refuses (full, or nothing free) is left alone.
    function _rebalance(PoolId id, Pool storage p) internal {
        int256 movedU = _rebalanceSide(p, true);
        int256 movedS = _rebalanceSide(p, false);
        if (movedU != 0 || movedS != 0) emit Rebalanced(id, movedU, movedS);
    }

    function _rebalanceSide(Pool storage p, bool isUsdg) internal returns (int256 moved) {
        uint256 res = isUsdg ? p.resUsdg : p.resStock;
        uint256 buf = isUsdg ? p.bufUsdg : p.bufStock;
        uint256 target = res * bufferBps / BPS;
        uint256 slack = target / 10;
        IVault v = isUsdg ? usdgVault : p.stockVault;
        Currency c = Currency.wrap(isUsdg ? address(usdg) : p.stock);
        if (buf > target + slack) {
            uint256 lend = _realUpTo(c, buf - target);
            if (lend == 0) return 0;
            uint256 g = gasleft();
            try v.deposit(lend, address(this)) returns (uint256 shares) {
                if (isUsdg) {
                    p.bufUsdg -= uint128(lend);
                    p.lentUsdg += uint128(shares);
                } else {
                    p.bufStock -= uint128(lend);
                    p.lentStock += uint128(shares);
                }
                moved = int256(lend);
            } catch {
                _gasCheck(g);
            }
        } else if (buf + slack < target) {
            uint256 want = target - buf;
            uint256 owned = isUsdg ? p.lentUsdg : p.lentStock;
            if (owned == 0) return 0;
            uint256 ownedAssets = v.previewRedeem(owned);
            if (want > ownedAssets) want = ownedAssets;
            uint256 free = _free(v);
            if (want > free) want = free;
            if (want == 0) return 0;
            uint256 g = gasleft();
            try v.withdraw(want, address(this), address(this)) returns (uint256 burned) {
                if (burned > owned) return 0;
                if (isUsdg) {
                    p.lentUsdg -= uint128(burned);
                    p.bufUsdg += uint128(want);
                } else {
                    p.lentStock -= uint128(burned);
                    p.bufStock += uint128(want);
                }
                moved = -int256(want);
            } catch {
                _gasCheck(g);
            }
        }
    }
}
