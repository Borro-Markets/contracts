// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";

/// The parts of BorroShort a bear vault uses. The vault is an ordinary shorter there.
interface IBearShort {
    function open(bytes32 id, uint256 deposit, uint256 borrowAmount, uint256 minProceeds, uint256 deadline)
        external
        returns (uint256 proceeds);
    function close(bytes32 id, uint256 shares, uint256 heldOut, uint256 topUp, uint256 maxCost, uint256 deadline)
        external
        returns (uint256 paidOut);
    function addDeposit(bytes32 id, uint256 amount) external returns (uint256 held);
    function accountOf(address shorter) external view returns (address);
    function tabOf(address shorter, bytes32 id)
        external
        view
        returns (uint256 shares, uint256 principal, uint256 entryValue, uint256 soldFor, uint256 openedAt);
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed);
    function openFeeBps() external view returns (uint256);
    function morpho() external view returns (IMorpho);
}

/// Pons's record of a coin it launched (PonsFactory.getLaunchedToken).
struct PonsLaunch {
    address token;
    address curve;
    address deployer;
    address creatorFeeRecipient;
    address pairToken;
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    uint8 phase; // 0 on the curve, 1 swept, 2 in its v4 pool, 3 rescued
    uint256 sweptQuote;
    uint256 sweptTokens;
    uint256 sweptAt;
    bool exists;
}

interface IPonsFactory {
    function getLaunchedToken(address token) external view returns (PonsLaunch memory);
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function graduated() external view returns (bool);
}

interface IPonsFeeVault {
    function claim() external;
    function balanceOf(address who) external view returns (uint256);
}

interface IPonsHook {
    function factory() external view returns (address);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Uniswap's SwapRouter02 (IV3SwapRouter: no deadline in the parameters).
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 {
    function withdraw(uint256 amount) external;
}

interface IV3PoolOracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
    function decimals() external view returns (uint8);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

interface IBearRegistry {
    function register(address coin) external;
}

/// @title BearVault
/// @notice One per bear coin. A coin launched on Pons names this vault as its creator fee recipient; the vault turns
///         those fees into a short of one stock on Borro, and spends what the short makes buying the coin back and
///         sending it to 0x...dEaD. Nothing here promises the short will make anything: it loses when the stock rises.
/// @dev The vault is an ordinary shorter on BorroShort; its position sits in a BorroAccount the vault owns.
///      Three kinds of caller:
///        - anyone: bind the coin the owner launched (Pons's record must name this vault and the owner), claim the
///          coin's creator fees into the vault and move idle USDG into the position (these two only ever move money
///          in), and trim the short once it is near its limit (`emergencyUseBps`);
///        - the keeper: the trading actions, each bounded here by caps, cooldowns and a price that does not come
///          from the keeper (the stock's Chainlink feed, or the WETH/USDG pool's 30 minute average). A stolen
///          keeper key can trade badly only within those bounds, and can never move money out;
///        - the owner (a Safe, or the launcher): pause, set the keeper and the limits inside hard caps, close the
///          whole short at any time, and take money out, but only after 7 days of public notice.
///      Limit used is Morpho's own measure: what is owed against what the posted money allows at the market's
///      LLTV, by the market's own oracle.
contract BearVault is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant RECLAIM_DELAY = 7 days;
    uint32 public constant TWAP_SECONDS = 30 minutes; // the WETH/USDG average every ETH swap is checked against
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Hard caps the owner's limits can never pass.
    uint256 public constant MAX_TARGET_USE_BPS = 5_000;
    uint256 public constant MAX_MAX_USE_BPS = 6_000;
    uint256 public constant MAX_EMERGENCY_USE_BPS = 8_500;
    uint256 public constant MAX_SLIP_BPS = 500;
    uint256 public constant MIN_PROFIT_FLOOR_BPS = 100;
    uint256 public constant MAX_PROFIT_CLOSE_BPS = 5_000;
    uint256 public constant MAX_FEED_AGE = 1 days;
    uint256 public constant MIN_COOLDOWN = 1 minutes;

    /// The chain the vault works on. Every address is fixed at deploy.
    struct Env {
        IBearShort short;
        IERC20 usdg;
        IPonsFactory pons;
        IPonsFeeVault feeVault;
        address ponsHook;
        IUniversalRouter universalRouter;
        ISwapRouter02 swapRouter;
        address weth;
        IV3PoolOracle wethUsdgPool;
    }

    struct Limits {
        uint16 targetUseBps; // the most `grow` may leave the position using of its limit
        uint16 maxUseBps; // above this the keeper may `reduce`
        uint16 emergencyUseBps; // above this anyone may `reduce`
        uint16 slipBps; // how far a fill may be from the outside price
        uint16 minProfitBps; // `takeProfit` only when the stock is this far below entry by its feed
        uint16 profitCloseBps; // the most of the short one `takeProfit` closes
        uint32 maxFeedAge; // a stock price older than this is not traded on (weekends, outages)
        uint32 growCooldown;
        uint32 swapCooldown;
        uint32 burnCooldown;
        uint128 maxGrowUsdg; // the most stock, by its feed, one `grow` shorts, in USDG wei
        uint128 maxBurnUsdg; // the most USDG one `buyAndBurn` spends
        uint128 maxSwapEth; // the most ETH one `swapFees` swaps
    }

    struct Reclaim {
        address token; // address(0): ETH
        uint256 amount;
        address to;
        uint64 readyAt;
    }

    // The chain.
    IBearShort public immutable short;
    IMorpho public immutable morpho;
    IERC20 public immutable usdg;
    IPonsFactory public immutable pons;
    IPonsFeeVault public immutable feeVault;
    address public immutable ponsHook;
    IUniversalRouter public immutable universalRouter;
    ISwapRouter02 public immutable swapRouter;
    address public immutable weth;
    IV3PoolOracle public immutable wethUsdgPool;
    uint24 public immutable wethUsdgFee;
    bool private immutable _wethIs0;
    address public immutable factory; // the BearFactory that made this vault, or zero

    // The desk.
    bytes32 public immutable deskId;
    address public immutable stock;
    address public immutable feed;
    uint256 public immutable feedScale; // turns stock wei times feed price into USDG wei, as BorroShort does
    MarketParams internal _market;

    // State.
    address public coin; // bound once, to the coin whose Pons record names this vault as fee recipient
    address public keeper;
    bool public paused;
    Limits internal _limits;
    uint256 public buybackBudget; // realized short profit set aside for buying the coin back, in USDG wei
    uint256 public lastGrow;
    uint256 public lastSwap;
    uint256 public lastBurn;
    Reclaim internal _reclaim;

    event CoinBound(address indexed coin, address curve);
    event KeeperSet(address keeper);
    event LimitsSet(Limits limits);
    event PausedSet(bool paused);
    event FeesClaimed(uint256 eth);
    event FeesSwapped(uint256 eth, uint256 usdg);
    event Grew(uint256 deposit, uint256 borrowed, uint256 proceeds, uint256 useBps);
    event ToppedUp(address indexed by, uint256 usdg, uint256 useBps);
    event Reduced(address indexed by, uint256 shares, uint256 paidOut, uint256 useBefore, uint256 useAfter);
    event ProfitTaken(uint256 shares, uint256 cost, uint256 paidOut, uint256 profit);
    event Burned(uint256 usdg, uint256 eth, uint256 coins);
    event Unwound(uint256 paidOut);
    event ReclaimQueued(address token, uint256 amount, address to, uint256 readyAt);
    event ReclaimCancelled();
    event Reclaimed(address token, uint256 amount, address to);

    error NotKeeper();
    error IsPaused();
    error BadLimits();
    error AlreadyBound();
    error NotOurCoin();
    error NotBound();
    error NotListed();
    error StaleFeed();
    error TooSoon();
    error TooBig();
    error TooLittle(uint256 got, uint256 floor);
    error TooMuch(uint256 asked, uint256 cap);
    error OverLimit(uint256 useBps, uint256 limitBps);
    error NotAllowed();
    error NoProfit(uint256 gainBps);
    error NoPosition();
    error NotTradable();
    error NothingQueued();
    error NotReady();
    error ZeroAddress();
    error BadEnv();
    error EthSend();

    constructor(Env memory env, bytes32 deskId_, address owner_, address keeper_, Limits memory limits_, address factory_)
        Ownable(owner_)
    {
        short = env.short;
        morpho = env.short.morpho();
        usdg = env.usdg;
        pons = env.pons;
        feeVault = env.feeVault;
        ponsHook = env.ponsHook;
        universalRouter = env.universalRouter;
        swapRouter = env.swapRouter;
        weth = env.weth;
        wethUsdgPool = env.wethUsdgPool;
        factory = factory_;
        if (IPonsHook(env.ponsHook).factory() != address(env.pons)) revert BadEnv();

        // The ETH pool must be WETH against USDG.
        address t0 = env.wethUsdgPool.token0();
        address t1 = env.wethUsdgPool.token1();
        if (!((t0 == env.weth && t1 == address(env.usdg)) || (t0 == address(env.usdg) && t1 == env.weth))) revert BadEnv();
        _wethIs0 = t0 == env.weth;
        wethUsdgFee = env.wethUsdgPool.fee();

        // The desk must be listed on BorroShort; its feed prices every stock trade here.
        // A desk trades through v3 or v4; BorroShort does the trading either way, so only the market and feed matter.
        (MarketParams memory m,,,, address feed_) = env.short.deskOf(deskId_);
        if (feed_ == address(0) || m.loanToken == address(0)) revert NotListed();
        deskId = deskId_;
        _market = m;
        stock = m.loanToken;
        feed = feed_;
        feedScale = 10 ** (uint256(IDecimals(m.loanToken).decimals()) + IFeed(feed_).decimals() - 6);

        _setLimits(limits_);
        keeper = keeper_;
        env.usdg.forceApprove(address(env.short), type(uint256).max);
        env.usdg.forceApprove(address(env.swapRouter), type(uint256).max);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ owner

    /// @notice Bind the coin, once. Pons's own record must show the coin pays its creator fees to this vault, in ETH.
    ///         Anyone may bind a coin Pons records as launched by this vault's owner (so a stranger's coin that names
    ///         this vault can never take its place); the owner may bind any coin that names this vault.
    function bindCoin(address coin_) external {
        if (coin != address(0)) revert AlreadyBound();
        PonsLaunch memory l = pons.getLaunchedToken(coin_);
        if (!l.exists || l.token != coin_ || l.creatorFeeRecipient != address(this) || l.pairToken != address(0)) {
            revert NotOurCoin();
        }
        if (msg.sender != owner() && l.deployer != owner()) revert NotAllowed();
        coin = coin_;
        if (factory != address(0)) IBearRegistry(factory).register(coin_);
        emit CoinBound(coin_, l.curve);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setLimits(Limits calldata limits_) external onlyOwner {
        _setLimits(limits_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Close the whole short now and bring what is left back to the vault as USDG. Works while paused.
    /// @param maxCost The most the buy-back may cost, the owner's own cap.
    function unwind(uint256 maxCost) external nonReentrant onlyOwner returns (uint256 paidOut) {
        Position memory p = morpho.position(_id(), short.accountOf(address(this)));
        if (p.borrowShares == 0 && p.collateral == 0) revert NoPosition();
        paidOut = short.close(deskId, type(uint256).max, type(uint256).max, 0, maxCost, block.timestamp);
        emit Unwound(paidOut);
    }

    /// @notice Ask to send `amount` of `token` (address(0) for ETH) to `to`. It can go after RECLAIM_DELAY, in public.
    ///         Queuing again replaces the request and restarts the wait.
    function queueReclaim(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint64 readyAt = uint64(block.timestamp + RECLAIM_DELAY);
        _reclaim = Reclaim({token: token, amount: amount, to: to, readyAt: readyAt});
        emit ReclaimQueued(token, amount, to, readyAt);
    }

    function cancelReclaim() external onlyOwner {
        if (_reclaim.readyAt == 0) revert NothingQueued();
        delete _reclaim;
        emit ReclaimCancelled();
    }

    /// @notice Send the queued amount (or all there is, if less) once the wait is over.
    function executeReclaim() external nonReentrant onlyOwner returns (uint256 sent) {
        Reclaim memory r = _reclaim;
        if (r.readyAt == 0) revert NothingQueued();
        if (block.timestamp < r.readyAt) revert NotReady();
        delete _reclaim;
        if (r.token == address(0)) {
            sent = r.amount < address(this).balance ? r.amount : address(this).balance;
            (bool ok,) = r.to.call{value: sent}("");
            if (!ok) revert EthSend();
        } else {
            uint256 bal = IERC20(r.token).balanceOf(address(this));
            sent = r.amount < bal ? r.amount : bal;
            IERC20(r.token).safeTransfer(r.to, sent);
            if (r.token == address(usdg)) {
                uint256 left = usdg.balanceOf(address(this));
                if (buybackBudget > left) buybackBudget = left;
            }
        }
        emit Reclaimed(r.token, sent, r.to);
    }

    // ------------------------------------------------------------------ anyone

    /// @notice Pull the coin's creator fees from Pons's fee vault. They can only land here.
    function claimFees() external nonReentrant returns (uint256 got) {
        uint256 before = address(this).balance;
        feeVault.claim();
        got = address(this).balance - before;
        emit FeesClaimed(got);
    }

    /// @notice Move idle USDG (not the buyback budget) into the open position. It only ever lowers the risk.
    function topUp(uint256 amount) external nonReentrant {
        Position memory p = morpho.position(_id(), short.accountOf(address(this)));
        if (p.borrowShares == 0) revert NoPosition();
        if (amount > idleUsdg()) revert TooMuch(amount, idleUsdg());
        short.addDeposit(deskId, amount);
        emit ToppedUp(msg.sender, amount, limitUsedBps());
    }

    /// @notice Close part of the short, paying the buy-back from the money posted behind it. The keeper may once the
    ///         position uses more than `maxUseBps` of its limit, anyone once it uses more than `emergencyUseBps`, the
    ///         owner at any time. Only as much posted money comes out as the buy-back may cost, so the debt falls by
    ///         about what the posted money does, and the position always ends using less of its limit.
    /// @param maxCost The most the buy-back may cost; capped at the stock's feed value plus `slipBps`.
    function reduce(uint256 shares, uint256 maxCost) external nonReentrant returns (uint256 paidOut) {
        morpho.accrueInterest(_market);
        uint256 useBefore = limitUsedBps();
        Limits memory L = _limits;
        bool ok = msg.sender == owner() || (msg.sender == keeper && useBefore > L.maxUseBps) || useBefore > L.emergencyUseBps;
        if (!ok) revert NotAllowed();
        _checkCost(shares, maxCost);
        uint256 posted = morpho.position(_id(), short.accountOf(address(this))).collateral;
        uint256 heldOut = IHeldPreview(_market.collateralToken).previewWithdraw(maxCost);
        if (heldOut > posted) heldOut = posted;
        paidOut = short.close(deskId, shares, heldOut, 0, maxCost, block.timestamp);
        uint256 useAfter = limitUsedBps();
        if (useAfter >= useBefore && useAfter != 0) revert OverLimit(useAfter, useBefore);
        emit Reduced(msg.sender, shares, paidOut, useBefore, useAfter);
    }

    // ------------------------------------------------------------------ keeper

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        if (paused) revert IsPaused();
        _;
    }

    /// @notice Swap creator-fee ETH for USDG in the WETH/USDG pool. The least accepted must be at least the pool's 30
    ///         minute average less `slipBps`.
    function swapFees(uint256 ethIn, uint256 minUsdg) external nonReentrant onlyKeeper returns (uint256 out) {
        Limits memory L = _limits;
        _cooldown(lastSwap, L.swapCooldown);
        lastSwap = block.timestamp;
        if (ethIn == 0 || ethIn > L.maxSwapEth || ethIn > address(this).balance) revert TooBig();
        uint256 floor = (usdgForEth(ethIn) * (BPS - L.slipBps)) / BPS;
        if (minUsdg < floor) revert TooLittle(minUsdg, floor);
        out = swapRouter.exactInputSingle{value: ethIn}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(usdg),
                fee: wethUsdgFee,
                recipient: address(this),
                amountIn: ethIn,
                amountOutMinimum: minUsdg,
                sqrtPriceLimitX96: 0
            })
        );
        emit FeesSwapped(ethIn, out);
    }

    /// @notice Short more of the stock with idle USDG as the deposit. The sale must bring at least its feed value less
    ///         `slipBps` and Borro's open fee, and the position may use at most `targetUseBps` of its limit after.
    function grow(uint256 deposit, uint256 borrowAmount, uint256 minProceeds)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 proceeds)
    {
        Limits memory L = _limits;
        _cooldown(lastGrow, L.growCooldown);
        lastGrow = block.timestamp;
        if (borrowAmount == 0) revert TooLittle(0, 1);
        if (deposit > idleUsdg()) revert TooMuch(deposit, idleUsdg());
        uint256 value = (borrowAmount * _price()) / feedScale;
        if (value > L.maxGrowUsdg) revert TooMuch(value, L.maxGrowUsdg);
        uint256 floor = (value * (BPS - L.slipBps - short.openFeeBps())) / BPS;
        if (minProceeds < floor) revert TooLittle(minProceeds, floor);
        proceeds = short.open(deskId, deposit, borrowAmount, minProceeds, block.timestamp);
        uint256 use = limitUsedBps();
        if (use > L.targetUseBps) revert OverLimit(use, L.targetUseBps);
        emit Grew(deposit, borrowAmount, proceeds, use);
    }

    /// @notice Close part of a short that is in profit by the stock's feed. The trade's own profit on that part (what
    ///         it sold for, less what buying it back cost) is set aside for buying the coin back; the rest comes back
    ///         to the vault as idle USDG.
    function takeProfit(uint256 shares, uint256 maxCost) external nonReentrant onlyKeeper returns (uint256 profit) {
        Limits memory L = _limits;
        morpho.accrueInterest(_market);
        (uint256 tShares, uint256 principal, uint256 entryValue, uint256 soldFor,) = short.tabOf(address(this), deskId);
        if (tShares == 0 || entryValue == 0) revert NoPosition();
        if (shares == 0 || shares > (tShares * L.profitCloseBps) / BPS) revert TooBig();
        uint256 nowValue = (principal * _price()) / feedScale;
        uint256 gainBps = nowValue < entryValue ? ((entryValue - nowValue) * BPS) / entryValue : 0;
        if (gainBps < L.minProfitBps) revert NoProfit(gainBps);
        _checkCost(shares, maxCost);

        Position memory p = morpho.position(_id(), short.accountOf(address(this)));
        // The part's share of the posted money comes out with it, so the rest of the position keeps its shape.
        uint256 heldOut = (uint256(p.collateral) * shares) / p.borrowShares;
        uint256 freed = _heldValue(heldOut);
        uint256 paidOut = short.close(deskId, shares, heldOut, 0, maxCost, block.timestamp);
        uint256 cost = freed > paidOut ? freed - paidOut : 0;
        uint256 sold = (soldFor * (shares < tShares ? shares : tShares)) / tShares;
        profit = sold > cost ? sold - cost : 0;
        if (profit > paidOut) profit = paidOut;
        buybackBudget += profit;
        emit ProfitTaken(shares, cost, paidOut, profit);
    }

    /// @notice Spend part of the buyback budget: USDG to ETH in the WETH/USDG pool (checked against its 30 minute
    ///         average), then the coin, on its Pons curve while it bonds or in its Pons pool after, sent to 0x...dEaD.
    /// @param minCoins The least coin the ETH must buy. The coin has no outside price; this, the cap per call and the
    ///        cooldown are what guard that leg.
    function buyAndBurn(uint256 usdgIn, uint256 minEth, uint256 minCoins)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 coins)
    {
        if (coin == address(0)) revert NotBound();
        Limits memory L = _limits;
        _cooldown(lastBurn, L.burnCooldown);
        lastBurn = block.timestamp;
        if (usdgIn == 0 || usdgIn > buybackBudget || usdgIn > L.maxBurnUsdg) revert TooBig();
        if (minCoins == 0) revert TooLittle(0, 1);
        uint256 floor = (ethForUsdg(usdgIn) * (BPS - L.slipBps)) / BPS;
        if (minEth < floor) revert TooLittle(minEth, floor);
        buybackBudget -= usdgIn;

        uint256 eth = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(usdg),
                tokenOut: weth,
                fee: wethUsdgFee,
                recipient: address(this),
                amountIn: usdgIn,
                amountOutMinimum: minEth,
                sqrtPriceLimitX96: 0
            })
        );
        IWETH9(weth).withdraw(eth);
        coins = _buyCoin(eth, minCoins);
        emit Burned(usdgIn, eth, coins);
    }

    // ------------------------------------------------------------------ views

    function limits() external view returns (Limits memory) {
        return _limits;
    }

    function market() external view returns (MarketParams memory) {
        return _market;
    }

    function pendingReclaim() external view returns (Reclaim memory) {
        return _reclaim;
    }

    /// @notice USDG here that is not set aside for buybacks.
    function idleUsdg() public view returns (uint256) {
        uint256 bal = usdg.balanceOf(address(this));
        return bal > buybackBudget ? bal - buybackBudget : 0;
    }

    /// @notice How much of its limit the position uses, in basis points, by Morpho's own measure (without accruing).
    function limitUsedBps() public view returns (uint256) {
        Position memory p = morpho.position(_id(), short.accountOf(address(this)));
        if (p.borrowShares == 0) return 0;
        Market memory m = morpho.market(_id());
        uint256 owed = uint256(p.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 room = FullMath.mulDiv(
            FullMath.mulDiv(p.collateral, IOracle(_market.oracle).price(), 1e36), _market.lltv, 1e18
        );
        if (room == 0) return type(uint256).max;
        return FullMath.mulDiv(owed, BPS, room) + 1;
    }

    /// @notice USDG wei that `ethIn` wei is worth at the WETH/USDG pool's 30 minute average.
    function usdgForEth(uint256 ethIn) public view returns (uint256) {
        uint160 sq = _twapSqrtPrice();
        return _wethIs0
            ? FullMath.mulDiv(FullMath.mulDiv(ethIn, sq, 1 << 96), sq, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(ethIn, 1 << 96, sq), 1 << 96, sq);
    }

    /// @notice ETH wei that `usdgIn` USDG wei is worth at the WETH/USDG pool's 30 minute average.
    function ethForUsdg(uint256 usdgIn) public view returns (uint256) {
        uint160 sq = _twapSqrtPrice();
        return _wethIs0
            ? FullMath.mulDiv(FullMath.mulDiv(usdgIn, 1 << 96, sq), 1 << 96, sq)
            : FullMath.mulDiv(FullMath.mulDiv(usdgIn, sq, 1 << 96), sq, 1 << 96);
    }

    // ------------------------------------------------------------------ internals

    function _id() internal view returns (Id) {
        return _market.id();
    }

    function _setLimits(Limits memory l) internal {
        if (
            l.targetUseBps == 0 || l.targetUseBps > MAX_TARGET_USE_BPS || l.maxUseBps < l.targetUseBps
                || l.maxUseBps > MAX_MAX_USE_BPS || l.emergencyUseBps <= l.maxUseBps || l.emergencyUseBps > MAX_EMERGENCY_USE_BPS
                || l.slipBps > MAX_SLIP_BPS || l.minProfitBps < MIN_PROFIT_FLOOR_BPS || l.profitCloseBps == 0
                || l.profitCloseBps > MAX_PROFIT_CLOSE_BPS || l.maxFeedAge == 0 || l.maxFeedAge > MAX_FEED_AGE
                || l.growCooldown < MIN_COOLDOWN || l.swapCooldown < MIN_COOLDOWN || l.burnCooldown < MIN_COOLDOWN
        ) revert BadLimits();
        _limits = l;
        emit LimitsSet(l);
    }

    function _cooldown(uint256 last, uint256 wait) internal view {
        if (last != 0 && block.timestamp < last + wait) revert TooSoon();
    }

    /// @dev The stock's feed price, refused when missing or older than `maxFeedAge`.
    function _price() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IFeed(feed).latestRoundData();
        if (answer <= 0 || block.timestamp > updatedAt + _limits.maxFeedAge) revert StaleFeed();
        return uint256(answer);
    }

    /// @dev The buy-back of `shares` may cost at most the stock owed for them, at its feed price, plus `slipBps`.
    function _checkCost(uint256 shares, uint256 maxCost) internal view {
        Market memory m = morpho.market(_id());
        uint256 owed = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 cap = (((owed * _price()) / feedScale) * (BPS + _limits.slipBps)) / BPS;
        if (maxCost > cap) revert TooMuch(maxCost, cap);
    }

    /// @dev What `held` shares of the held-money vault redeem for now, in USDG wei.
    function _heldValue(uint256 held) internal view returns (uint256) {
        return IHeldPreview(_market.collateralToken).previewRedeem(held);
    }

    /// @dev The WETH/USDG pool's average sqrt price over the last TWAP_SECONDS, from its own observations.
    function _twapSqrtPrice() internal view returns (uint160) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_SECONDS;
        (int56[] memory tc,) = wethUsdgPool.observe(ago);
        int56 delta = tc[1] - tc[0];
        int24 tick = int24(delta / int56(uint56(TWAP_SECONDS)));
        if (delta < 0 && delta % int56(uint56(TWAP_SECONDS)) != 0) tick--;
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @dev Buys the coin with `eth` and makes sure it ends at 0x...dEaD. The route comes from Pons's own record.
    function _buyCoin(uint256 eth, uint256 minCoins) internal returns (uint256 coins) {
        PonsLaunch memory l = pons.getLaunchedToken(coin);
        if (l.phase == 0 && !IPonsCurve(l.curve).graduated()) {
            uint256 before = IERC20(coin).balanceOf(DEAD);
            IPonsCurve(l.curve).buy{value: eth}(eth, minCoins, DEAD);
            coins = IERC20(coin).balanceOf(DEAD) - before;
            if (coins < minCoins) revert TooLittle(coins, minCoins);
        } else if (l.phase == 2) {
            uint256 before = IERC20(coin).balanceOf(address(this));
            universalRouter.execute{value: eth}(hex"10", _v4BuyInputs(l, eth, minCoins), block.timestamp);
            coins = IERC20(coin).balanceOf(address(this)) - before;
            if (coins < minCoins) revert TooLittle(coins, minCoins);
            IERC20(coin).safeTransfer(DEAD, coins);
        } else {
            revert NotTradable();
        }
    }

    // Universal Router V4_SWAP: SWAP_EXACT_IN, SETTLE_ALL, TAKE_ALL, in the newer ExactInputParams layout the live
    // router takes (a per-hop price floor list, left empty: the minimum out covers the route), as keeper/jobs/fund.mjs.
    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        address currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    function _v4BuyInputs(PonsLaunch memory l, uint256 eth, uint256 minCoins) internal view returns (bytes[] memory inputs) {
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({intermediateCurrency: coin, fee: l.poolFee, tickSpacing: l.tickSpacing, hooks: ponsHook, hookData: ""});
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputParams({
                currencyIn: address(0),
                path: path,
                minHopPriceX36: new uint256[](0),
                amountIn: uint128(eth),
                amountOutMinimum: uint128(minCoins)
            })
        );
        params[1] = abi.encode(address(0), eth);
        params[2] = abi.encode(coin, minCoins);
        bytes memory actions = hex"070c0f";
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}

interface IHeldPreview {
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
}
