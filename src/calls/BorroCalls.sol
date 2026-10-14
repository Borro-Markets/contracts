// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MarketHours} from "../eth/MarketHours.sol";
import {CallsCalendar} from "./CallsCalendar.sol";
import {CallsPrice} from "./CallsPrice.sol";
import {IStockVault, IRoundFeed, IStockToken} from "./CallsDeps.sol";

/// @title BorroCalls
/// @notice Covered calls on lent stock, one vault per stock (docs/COVERED-CALLS.md). Lenders put in the stock (it goes
///         into its Borro vault) or their Borro vault shares (bNVDA and so on) and get this vault's shares. The stock
///         stays lent on Borro the whole time: this vault only ever holds Borro vault shares.
///
///         Each week it sells call options on what it holds, for USDG, by a falling-price sale anyone can buy from. The
///         strike is a fixed step over the stock's Chainlink price at the start. The options expire when the 24/5 market
///         shuts for the weekend (Friday 20:00 New York). Above the strike then, each option pays (price - strike) /
///         price of one stock token, in Borro vault shares; at or below it, nothing. What does not sell is not written.
///         The premium goes to the round's depositors when the round settles.
///
/// @dev Nobody runs this vault. Starting a round, selling, settling and calling a round off are open to anyone and
///      checked against the clock, the calendar and the feed, so a keeper that misbehaves or stops can only delay. The
///      sale's price is a function of the time and the feed's live price; the settlement price is the feed's answer at
///      expiry, read in the feed phase the round started on, found from a round id the caller suggests and checked so
///      that only one round can pass. One round a week.
///
///      The owner (the Hoard Safe) can stop new rounds and end a live sale (a pause ends it for good), change the
///      settings inside hard limits (a change waits PARAM_DELAY, applies at the first round start after that, so
///      depositors always see it coming with a withdrawal window in between, and at most halves the step or the floor),
///      and take back tokens nobody is owed. It has no path to depositors' or buyers' money: the books below say what is
///      owed, and reclaim() never reaches it.
///
///      Books, in Borro vault shares: `active` backs this vault's shares (and every option of the live round);
///      `pendingIn` waits to join at the end of the live round; `leaving` is set aside for withdrawals queued in a round
///      that has ended; `forOptions` is set aside for option holders. In USDG: `usdgOwed` is the live round's premium,
///      premium credited to depositors and not yet claimed, and refunds owed for rounds called off. Donations are in no
///      book. Every conversion rounds for the vault, and each book covers the sum of the claims on it.
contract BorroCalls is ERC20, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice A stock feed posts at least every 24 hours while its market is open.
    uint256 public constant MAX_PRICE_AGE = 25 hours;
    /// @notice A sale ends at least this long before its options expire.
    uint256 public constant MIN_LIFE = 1 days;
    /// @notice A round whose price at expiry was stale settles on the feed's first post after expiry, if it comes within
    ///         this long; if none does, the round is called off.
    uint256 public constant SETTLE_WAIT = 7 days;
    /// @notice A round nobody has settled this long after expiry can be called off by anyone, whatever the feed did.
    uint256 public constant VOID_AFTER = 30 days;
    /// @notice A settings change waits this long and applies at the first round start after it.
    uint256 public constant PARAM_DELAY = 3 days;
    /// @notice Strikes are whole cents (the feeds have 8 decimals).
    uint256 public constant STRIKE_TICK = 1e6;
    /// @notice No round starts from 2029-01-01 00:00 UTC: the calendar (MarketHours) knows the exchange's holidays only
    ///         through 2028, so a vault for later years needs a new deploy with a longer calendar (review L-4).
    uint256 public constant CALENDAR_END = 1861920000;
    /// @notice A purchase must cost at least this (1 USDG) unless it takes the last options of the round, so nobody can
    ///         keep a round that sold nothing open all week for a wei (review I-1).
    uint256 public constant MIN_COST = 1e6;

    uint16 public constant MIN_STEP_BPS = 100;
    uint16 public constant MAX_STEP_BPS = 5_000;
    uint16 public constant MAX_START_BPS = 2_000;
    uint16 public constant MIN_MOVE_BPS = 25;
    uint16 public constant MIN_WRITE_BPS = 100;
    uint32 public constant MIN_AUCTION = 1 hours;
    uint32 public constant MAX_AUCTION = 24 hours;
    uint32 public constant MIN_START_OFFSET = 13.5 hours; // 09:30 New York: no sale before the regular open
    uint32 public constant SALE_CLOSE = 20 hours; // 16:00 New York: every sale ends by the regular close

    uint256 internal constant ACC = 1e30; // premium per share, in USDG wei times this

    struct Params {
        uint16 stepBps; // the strike, above the price at the start: MIN_STEP_BPS to MAX_STEP_BPS
        uint16 startBps; // an option's price when the sale opens, as a share of the stock's live price: up to MAX_START_BPS
        uint16 floorBps; // and when it ends: at least a fortieth of stepBps, at most startBps
        uint16 maxMoveBps; // no sales while the live price is more than this over the start price: MIN_MOVE_BPS to stepBps / 2
        uint16 writeBps; // the share of the vault's stock offered each round: MIN_WRITE_BPS to BPS
        uint32 auctionSeconds; // how long the sale runs: MIN_AUCTION to MAX_AUCTION
        uint32 startOffset; // seconds into a trading date before a round may start: from MIN_START_OFFSET, with the sale over by SALE_CLOSE
    }

    enum Outcome {
        None,
        Live,
        Settled,
        Void
    }

    struct Round {
        Outcome outcome;
        uint64 startedAt;
        uint64 auctionEnd;
        uint64 expiry;
        uint64 settledAt;
        uint16 startBps;
        uint16 floorBps;
        uint16 maxMoveBps;
        uint16 phase; // the feed phase the round started on (settlement reads the newest phase begun before expiry)
        uint32 span; // the sale's length on its price schedule (auctionSeconds); a late start is cut at 16:00 New York
        uint256 spot; // the feed's price at the start, 8 decimals
        uint256 strike; // 8 decimals
        uint256 settlePrice; // 8 decimals; 0 when nothing sold or the round was called off
        uint256 capacity; // options on offer; one option is on one whole stock token (1e18)
        uint256 sold;
        uint256 premium; // USDG paid for them
        uint256 owedShares; // Borro vault shares set aside for the round's option holders
    }

    /// How a round's queued withdrawals and deposits converted when it ended, and its premium per share.
    struct Book {
        uint256 outNum; // Borro vault shares out per calls share = outNum / outDen
        uint256 outDen;
        uint256 inNum; // calls shares per Borro vault share in = inNum / inDen
        uint256 inDen;
        uint256 accBefore;
        uint256 accAt;
    }

    struct Queued {
        uint64 round;
        uint192 amount;
    }

    IERC20 public immutable stock;
    IStockVault public immutable bVault;
    IERC20 public immutable usdg;
    IRoundFeed public immutable feed;

    Params public params;
    Params public pendingParams;
    uint256 public paramsReadyAt; // zero: no change waiting
    bool public paused; // no new rounds and no sales

    uint256 public currentRound; // the latest round's id; rounds count from 1
    mapping(uint256 => Round) internal _rounds;
    mapping(uint256 => Book) internal _books;
    mapping(uint256 => mapping(address => uint256)) public optionsOf;
    mapping(uint256 => mapping(address => uint256)) public paidOf; // USDG, refunded if the round is called off

    uint256 public active;
    uint256 public pendingIn;
    uint256 public leaving;
    uint256 public forOptions;
    uint256 public usdgOwed;
    uint256 public unclaimed; // calls shares made for queued deposits, not yet handed to their owners
    uint256 public queuedOut; // calls shares queued to leave at the end of the live round

    mapping(address => Queued) public depositQueued; // Borro vault shares
    mapping(address => Queued) public withdrawQueued; // calls shares
    mapping(address => uint256) public sharesOut; // Borro vault shares ready to collect, from withdrawals queued earlier

    uint256 public acc; // premium per calls share, times ACC
    mapping(address => uint256) internal _accPaid;
    mapping(address => uint256) internal _earned;

    event RoundStarted(uint256 indexed round, uint256 spot, uint256 strike, uint256 capacity, uint256 auctionEnd, uint256 expiry);
    event Bought(uint256 indexed round, address indexed buyer, address indexed receiver, uint256 options, uint256 cost);
    event Settled(uint256 indexed round, uint256 price, uint256 sold, uint256 owedShares, uint256 premium);
    event Voided(uint256 indexed round, uint256 sold, uint256 premium);
    event Deposited(address indexed sender, address indexed receiver, uint256 vaultShares, uint256 shares);
    event DepositQueued(address indexed sender, address indexed receiver, uint256 indexed round, uint256 vaultShares);
    event DepositCancelled(address indexed owner, uint256 indexed round, uint256 vaultShares);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 shares, uint256 vaultShares);
    event WithdrawQueued(address indexed owner, uint256 indexed round, uint256 shares);
    event WithdrawCancelled(address indexed owner, uint256 indexed round, uint256 shares);
    event Collected(address indexed owner, address indexed receiver, uint256 vaultShares, uint256 usdg);
    event Exercised(uint256 indexed round, address indexed holder, address indexed receiver, uint256 options, uint256 vaultShares, uint256 refund);
    event ParamsQueued(Params params, uint256 readyAt);
    event ParamsApplied(Params params);
    event PausedSet(bool paused);
    event Reclaimed(address indexed token, address indexed to, uint256 amount);

    error BadSetup();
    error BadParams();
    error IsPaused();
    error RoundLive();
    error NoRound();
    error MarketClosed();
    error TooEarly();
    error TooLate();
    error NoPrice();
    error StockPaused();
    error NothingToWrite();
    error SaleOver();
    error PriceMoved(uint256 live, uint256 limit);
    error SoldOut();
    error TooMuch(uint256 cost, uint256 maxCost);
    error BadHint();
    error StaleAtExpiry();
    error FreshAtExpiry();
    error NotVoid();
    error Nothing();
    error OverReclaimable(uint256 wanted, uint256 free);
    error NoRenounce();
    error ZeroAddress();
    error WeekDone();
    error CalendarEnded();
    error TooSmall(uint256 cost, uint256 min);

    /// @param stock_ The Robinhood stock token (18 decimals).
    /// @param bVault_ Its Borro vault (a Morpho Vault V2 whose asset is the stock, 18 decimals).
    /// @param usdg_ USDG (6 decimals): what options are bought with.
    /// @param feed_ The stock's Chainlink feed (8 decimals): the same one its Borro desk prices by.
    /// @param owner_ The Hoard Safe.
    constructor(
        IERC20 stock_,
        IStockVault bVault_,
        IERC20 usdg_,
        IRoundFeed feed_,
        address owner_,
        Params memory params_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        if (
            bVault_.asset() != address(stock_) || bVault_.decimals() != 18 || IStockToken(address(stock_)).decimals() != 18
                || IStockToken(address(usdg_)).decimals() != 6 || feed_.decimals() != 8
        ) revert BadSetup();
        IStockToken(address(stock_)).oraclePaused(); // must answer
        _check(params_);
        stock = stock_;
        bVault = bVault_;
        usdg = usdg_;
        feed = feed_;
        params = params_;
        emit ParamsApplied(params_);
    }

    // ------------------------------------------------------------------ depositors

    /// @notice Put `amount` of the stock in. It goes into its Borro vault at once, and stays lent. Between rounds the
    ///         receiver gets shares now; during a round it waits for the round to end (cancelDeposit takes it back).
    function deposit(uint256 amount, address receiver) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert Nothing();
        stock.safeTransferFrom(msg.sender, address(this), amount);
        uint256 before = bVault.balanceOf(address(this));
        stock.forceApprove(address(bVault), amount);
        bVault.deposit(amount, address(this));
        shares = _enter(bVault.balanceOf(address(this)) - before, receiver);
    }

    /// @notice Put `vaultShares` of the stock's Borro vault shares in (bNVDA and so on). As deposit().
    function depositShares(uint256 vaultShares, address receiver) external nonReentrant returns (uint256 shares) {
        if (vaultShares == 0) revert Nothing();
        uint256 before = bVault.balanceOf(address(this));
        IERC20(address(bVault)).safeTransferFrom(msg.sender, address(this), vaultShares);
        shares = _enter(bVault.balanceOf(address(this)) - before, receiver);
    }

    /// @notice Take back a deposit still waiting for the live round to end, as Borro vault shares.
    function cancelDeposit() external nonReentrant returns (uint256 vaultShares) {
        Queued memory q = depositQueued[msg.sender];
        if (q.amount == 0 || q.round != currentRound || !_live()) revert Nothing();
        vaultShares = q.amount;
        delete depositQueued[msg.sender];
        pendingIn -= vaultShares;
        IERC20(address(bVault)).safeTransfer(msg.sender, vaultShares);
        emit DepositCancelled(msg.sender, q.round, vaultShares);
    }

    /// @notice Between rounds: burn `shares` (all of them with the maximum uint) for their part of the vault's Borro vault
    ///         shares, paid with anything else waiting for the caller (earlier withdrawals, premium). `asStock` redeems
    ///         the vault shares for the stock (only while the Borro vault has the stock free).
    function withdraw(uint256 shares, address receiver, bool asStock)
        external
        nonReentrant
        returns (uint256 vaultShares, uint256 usdgOut)
    {
        if (_live()) revert RoundLive();
        _sync(msg.sender);
        if (shares == type(uint256).max) shares = balanceOf(msg.sender);
        if (shares != 0) {
            uint256 out = Math.mulDiv(shares, active + 1, totalSupply() + unclaimed + 1);
            _burn(msg.sender, shares);
            active -= out;
            emit Withdrawn(msg.sender, receiver, shares, out);
            vaultShares = out;
        }
        (uint256 more, uint256 u) = _collect(msg.sender, receiver, asStock, vaultShares);
        vaultShares += more;
        usdgOut = u;
    }

    /// @notice During a round: queue `shares` to leave when it ends. They stay in the round (its premium and its
    ///         options) and turn into Borro vault shares at the round's end, to collect().
    function requestWithdraw(uint256 shares) external nonReentrant {
        if (!_live()) revert NoRound();
        _sync(msg.sender);
        if (shares == type(uint256).max) shares = balanceOf(msg.sender);
        if (shares == 0) revert Nothing();
        _burn(msg.sender, shares);
        queuedOut += shares;
        Queued storage q = withdrawQueued[msg.sender];
        q.round = uint64(currentRound);
        q.amount += SafeCast.toUint192(shares);
        emit WithdrawQueued(msg.sender, currentRound, shares);
    }

    /// @notice Take back a withdrawal queued in the live round: the shares come back as they were.
    function cancelWithdraw() external nonReentrant returns (uint256 shares) {
        Queued memory q = withdrawQueued[msg.sender];
        if (q.amount == 0 || q.round != currentRound || !_live()) revert Nothing();
        shares = q.amount;
        delete withdrawQueued[msg.sender];
        queuedOut -= shares;
        _mint(msg.sender, shares);
        emit WithdrawCancelled(msg.sender, q.round, shares);
    }

    /// @notice Collect what is waiting for the caller: Borro vault shares from withdrawals queued in rounds that have
    ///         ended, and premium (USDG). Shares made for a deposit that waited are added to the caller's balance.
    function collect(address receiver, bool asStock) external nonReentrant returns (uint256 vaultShares, uint256 usdgOut) {
        _sync(msg.sender);
        return _collect(msg.sender, receiver, asStock, 0);
    }

    // ------------------------------------------------------------------ the round

    /// @notice Start this week's round: anyone, once the market is open, `startOffset` into the trading date, the feed
    ///         current and the last round over. Writes the strike (the feed's price plus `stepBps`, up to the cent) and
    ///         opens the sale of up to `writeBps` of the vault's stock.
    function startRound() external nonReentrant returns (uint256 id) {
        if (paused) revert IsPaused();
        if (_live()) revert RoundLive();
        uint256 t = block.timestamp;
        if (t >= CALENDAR_END) revert CalendarEnded();
        if (!MarketHours.isOpen(t)) revert MarketClosed();
        _applyParams();
        Params memory p = params;
        uint256 into = CallsCalendar.secondsIntoDate(t);
        if (into < p.startOffset) revert TooEarly();
        (uint256 spot, uint80 feedRound) = _livePrice();
        uint256 expiry = CallsCalendar.expiryOf(t);
        // One round a week: after a round ends (even one that sold nothing on Monday), the next starts next week.
        if (currentRound != 0 && _rounds[currentRound].expiry == expiry) revert WeekDone();
        // The sale runs its schedule, but never past 16:00 New York that day: a round started late sells in the regular
        // session only, ends before reaching its floor, and needs at least MIN_AUCTION left (review re-check R-2).
        uint256 end = t + p.auctionSeconds;
        uint256 close = t - into + SALE_CLOSE;
        if (end > close) end = close;
        if (end < t + MIN_AUCTION || end + MIN_LIFE > expiry) revert TooLate();
        uint256 capacity = Math.mulDiv(bVault.convertToAssets(active), p.writeBps, BPS);
        if (capacity == 0) revert NothingToWrite();
        uint256 strike = Math.mulDiv(spot, BPS + p.stepBps, BPS * STRIKE_TICK, Math.Rounding.Ceil) * STRIKE_TICK;

        id = ++currentRound;
        Round storage r = _rounds[id];
        r.outcome = Outcome.Live;
        r.startedAt = uint64(t);
        r.auctionEnd = uint64(end);
        r.expiry = uint64(expiry);
        r.startBps = p.startBps;
        r.floorBps = p.floorBps;
        r.maxMoveBps = p.maxMoveBps;
        r.phase = uint16(uint256(feedRound) >> 64);
        r.span = p.auctionSeconds;
        r.spot = spot;
        r.strike = strike;
        r.capacity = capacity;
        emit RoundStarted(id, spot, strike, capacity, end, expiry);
    }

    /// @notice Buy up to `amount` options of the live round (one option is on one whole stock token, 1e18) at the sale's
    ///         price now, paying at most `maxCost` USDG. Fills what is left if less. The most a buyer can lose is what
    ///         they pay. If the round is ever called off, `receiver` gets the payment back.
    function buy(uint256 amount, uint256 maxCost, address receiver)
        external
        nonReentrant
        returns (uint256 filled, uint256 cost)
    {
        if (paused) revert IsPaused();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 id = currentRound;
        Round storage r = _rounds[id];
        (filled, cost) = _quote(r, amount);
        if (cost > maxCost) revert TooMuch(cost, maxCost);
        usdg.safeTransferFrom(msg.sender, address(this), cost);
        r.sold += filled;
        r.premium += cost;
        usdgOwed += cost;
        optionsOf[id][receiver] += filled;
        paidOf[id][receiver] += cost;
        emit Bought(id, msg.sender, receiver, filled, cost);
    }

    /// @notice Settle the live round. A round that sold nothing settles once its sale is over (the hint is ignored).
    ///         Otherwise, after expiry and while the stock is not paused for a corporate action, at the feed's answer at
    ///         expiry, read in settlementPhase (the newest feed phase begun before expiry): `hint` is that phase's last
    ///         round posted before expiry if it was current then (posted within MAX_PRICE_AGE, no weekend or holiday
    ///         since); if it was stale, `hint` is the phase's first round posted at or after expiry, within SETTLE_WAIT.
    ///         Only one round passes either way. Above the strike, each option gets (price - strike) / price of a stock token,
    ///         in Borro vault shares, set aside at once; the premium goes to the round's depositors.
    function settle(uint80 hint) external nonReentrant {
        uint256 id = currentRound;
        Round storage r = _rounds[id];
        if (r.outcome != Outcome.Live) revert NoRound();
        uint256 before = acc;
        if (r.sold == 0) {
            if (block.timestamp < r.auctionEnd) revert TooEarly();
        } else {
            uint256 x = r.expiry;
            if (block.timestamp <= x) revert TooEarly();
            if (_stockPaused()) revert StockPaused();
            uint256 price = _priceAtExpiry(hint, x, _settlePhase(r.phase, x));
            r.settlePrice = price;
            if (price > r.strike) {
                uint256 owed = bVault.convertToShares(Math.mulDiv(r.sold, price - r.strike, price));
                if (owed > active) owed = active; // only if the Borro vault lost stock: holders share what there is
                active -= owed;
                forOptions += owed;
                r.owedShares = owed;
            }
            // The premium was owed (held) since the sale; now it is owed to the round's depositors instead.
            uint256 part = totalSupply() + unclaimed + queuedOut;
            if (part != 0) acc += Math.mulDiv(r.premium, ACC, part);
            else usdgOwed -= r.premium; // nobody to pay: owed to nobody (cannot happen: a sale needs depositors)
        }
        r.outcome = Outcome.Settled;
        r.settledAt = uint64(block.timestamp);
        emit Settled(id, r.settlePrice, r.sold, r.owedShares, r.premium);
        _close(id, before);
    }

    /// @notice Call the live round off: its options are cancelled, buyers get their payment back (exercise()), and the
    ///         depositors get no premium. Only when no settlement price can exist: after SETTLE_WAIT, with `hint` the
    ///         feed's answer at expiry in settlementPhase, stale, and nothing posted in that phase within SETTLE_WAIT
    ///         after; or by anyone VOID_AFTER after expiry, whatever the feed did, for a round nobody settled.
    function voidRound(uint80 hint) external nonReentrant {
        uint256 id = currentRound;
        Round storage r = _rounds[id];
        if (r.outcome != Outcome.Live || r.sold == 0) revert NoRound();
        uint256 x = r.expiry;
        if (block.timestamp <= x + VOID_AFTER) {
            if (block.timestamp <= x + SETTLE_WAIT) revert TooEarly();
            (int256 a, uint256 u, uint256 next) = _answerAt(hint, x - 1, _settlePhase(r.phase, x));
            if (next != 0 && next <= x + SETTLE_WAIT) revert NotVoid();
            if (a > 0 && CallsCalendar.fresh(u, x - 1, MAX_PRICE_AGE)) revert FreshAtExpiry();
        }
        r.outcome = Outcome.Void;
        r.settledAt = uint64(block.timestamp);
        emit Voided(id, r.sold, r.premium);
        _close(id, acc);
    }

    /// @notice An option holder's payout from a round that has ended: Borro vault shares for options that finished above
    ///         the strike, or the payment back for a round called off. Options that expired worthless just close.
    function exercise(uint256 id, address receiver, bool asStock) external nonReentrant returns (uint256 vaultShares, uint256 refund) {
        Round storage r = _rounds[id];
        if (r.outcome != Outcome.Settled && r.outcome != Outcome.Void) revert NoRound();
        uint256 n = optionsOf[id][msg.sender];
        if (n == 0) revert Nothing();
        optionsOf[id][msg.sender] = 0;
        if (r.outcome == Outcome.Void) {
            refund = paidOf[id][msg.sender];
            paidOf[id][msg.sender] = 0;
            usdgOwed -= refund;
            usdg.safeTransfer(receiver, refund);
        } else if (r.owedShares != 0) {
            vaultShares = Math.mulDiv(n, r.owedShares, r.sold);
            forOptions -= vaultShares;
            _payShares(receiver, vaultShares, asStock);
        }
        emit Exercised(id, msg.sender, receiver, n, vaultShares, refund);
    }

    // ------------------------------------------------------------------ the owner

    /// @notice Stop new rounds and new sales, or allow them again. A pause ends a live round's sale for good (what sold
    ///         stays written; unpausing never reopens it), so a pause can never hold the price falling for one buyer
    ///         (review M-1). Settling, withdrawing, collecting and exercising are never stopped.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        if (paused_) {
            Round storage r = _rounds[currentRound];
            if (r.outcome == Outcome.Live && block.timestamp < r.auctionEnd) r.auctionEnd = uint64(block.timestamp);
        }
        emit PausedSet(paused_);
    }

    /// @notice Change the settings, inside the hard limits. Applies at the first round start PARAM_DELAY or more from
    ///         now; a later call replaces a change still waiting, and restarts the wait.
    function queueParams(Params calldata p) external onlyOwner {
        _check(p);
        // One change can at most halve the step, the start or the floor, so a fire sale takes several notices in a row
        // (review M-2).
        Params memory cur = params;
        if (uint256(p.stepBps) * 2 < cur.stepBps || uint256(p.floorBps) * 2 < cur.floorBps || uint256(p.startBps) * 2 < cur.startBps) {
            revert BadParams();
        }
        pendingParams = p;
        paramsReadyAt = block.timestamp + PARAM_DELAY;
        emit ParamsQueued(p, paramsReadyAt);
    }

    /// @notice Drop a waiting settings change.
    function cancelParams() external onlyOwner {
        delete pendingParams;
        delete paramsReadyAt;
    }

    /// @notice What the owner could take back of `token`: what this vault holds of it beyond its books (all of it for a
    ///         token in no book).
    function reclaimable(address token) public view returns (uint256) {
        uint256 held = IERC20(token).balanceOf(address(this));
        uint256 owed;
        if (token == address(bVault)) owed = active + pendingIn + leaving + forOptions;
        else if (token == address(usdg)) owed = usdgOwed;
        return held > owed ? held - owed : 0;
    }

    /// @notice Send `amount` of `token` nobody is owed to `to`. Only the owner, never more than reclaimable().
    function reclaim(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        uint256 free = reclaimable(token);
        if (amount > free) revert OverReclaimable(amount, free);
        IERC20(token).safeTransfer(to, amount);
        emit Reclaimed(token, to, amount);
    }

    /// @notice Ownership moves in two steps and is never given up: without an owner, strays could not be reclaimed.
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }

    // ------------------------------------------------------------------ views

    function roundOf(uint256 id) external view returns (Round memory) {
        return _rounds[id];
    }

    function bookOf(uint256 id) external view returns (Book memory) {
        return _books[id];
    }

    /// @notice True while a round is live (from its start until it is settled or called off).
    function live() external view returns (bool) {
        return _live();
    }

    /// @notice The feed phase round `id` settles in: the newest phase whose first round was posted before its expiry
    ///         (the round's own phase unless the feed was upgraded before expiry).
    function settlementPhase(uint256 id) external view returns (uint16) {
        Round storage r = _rounds[id];
        return _settlePhase(r.phase, r.expiry);
    }

    /// @notice What buying `amount` options now would fill and cost (USDG). Reverts as buy() would.
    function quote(uint256 amount) external view returns (uint256 filled, uint256 cost) {
        return _quote(_rounds[currentRound], amount);
    }

    /// @notice What `shares` would take out between rounds, in Borro vault shares, and that in the stock.
    function previewWithdraw(uint256 shares) external view returns (uint256 vaultShares, uint256 stockAmount) {
        vaultShares = Math.mulDiv(shares, active + 1, totalSupply() + unclaimed + queuedOut + 1);
        stockAmount = bVault.convertToAssets(vaultShares);
    }

    /// @notice Premium (USDG) `who` can collect now, counting deposits and withdrawals that waited for a round that has
    ///         since ended.
    function premiumOf(address who) external view returns (uint256 amount) {
        amount = _earned[who] + Math.mulDiv(balanceOf(who), acc - _accPaid[who], ACC);
        Queued memory q = depositQueued[who];
        if (q.amount != 0 && _ended(q.round)) {
            Book storage b = _books[q.round];
            amount += Math.mulDiv(Math.mulDiv(q.amount, b.inNum, b.inDen), acc - b.accAt, ACC);
        }
        q = withdrawQueued[who];
        if (q.amount != 0 && _ended(q.round)) {
            Book storage b = _books[q.round];
            amount += Math.mulDiv(q.amount, b.accAt - b.accBefore, ACC);
        }
    }

    // ------------------------------------------------------------------ internals

    function _live() internal view returns (bool) {
        return _rounds[currentRound].outcome == Outcome.Live;
    }

    function _ended(uint256 id) internal view returns (bool) {
        Outcome o = _rounds[id].outcome;
        return o == Outcome.Settled || o == Outcome.Void;
    }

    function _check(Params memory p) internal pure {
        if (
            p.stepBps < MIN_STEP_BPS || p.stepBps > MAX_STEP_BPS || p.startBps > MAX_START_BPS || p.floorBps == 0
                || uint256(p.floorBps) * 40 < p.stepBps || p.floorBps > p.startBps || p.maxMoveBps < MIN_MOVE_BPS
                || p.maxMoveBps > p.stepBps / 2 || p.writeBps < MIN_WRITE_BPS || p.writeBps > BPS
                || p.auctionSeconds < MIN_AUCTION || p.auctionSeconds > MAX_AUCTION || p.startOffset < MIN_START_OFFSET
                || uint256(p.startOffset) + p.auctionSeconds > SALE_CLOSE
        ) revert BadParams();
    }

    function _applyParams() internal {
        uint256 at = paramsReadyAt;
        if (at == 0 || block.timestamp < at) return;
        params = pendingParams;
        delete pendingParams;
        delete paramsReadyAt;
        emit ParamsApplied(params);
    }

    function _stockPaused() internal view returns (bool) {
        // A token that stops answering counts as not paused: it must not freeze settlement.
        try IStockToken(address(stock)).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return false;
        }
    }

    /// @dev The stock's price now, or a revert: a positive answer, current by CallsCalendar.fresh, the stock not paused.
    function _livePrice() internal view returns (uint256, uint80) {
        (uint80 id, int256 a,, uint256 u,) = feed.latestRoundData();
        if (a <= 0 || !CallsCalendar.fresh(u, block.timestamp, MAX_PRICE_AGE)) revert NoPrice();
        if (_stockPaused()) revert StockPaused();
        return (uint256(a), id);
    }

    /// @dev The sale: open from the start to auctionEnd, with options left, the feed current and its price no more than
    ///      maxMoveBps over the start. Price per option = live price x a share falling straight from startBps to
    ///      floorBps over the sale, rounded up.
    function _quote(Round storage r, uint256 amount) internal view returns (uint256 filled, uint256 cost) {
        if (r.outcome != Outcome.Live) revert NoRound();
        if (block.timestamp >= r.auctionEnd) revert SaleOver();
        (uint256 live_,) = _livePrice();
        uint256 limit = Math.mulDiv(r.spot, BPS + r.maxMoveBps, BPS);
        if (live_ > limit) revert PriceMoved(live_, limit);
        uint256 left = r.capacity - r.sold;
        filled = amount < left ? amount : left;
        if (filled == 0) revert SoldOut();
        uint256 drop = Math.mulDiv(uint256(r.startBps - r.floorBps) * 1e18, block.timestamp - r.startedAt, r.span);
        uint256 shareE18 = uint256(r.startBps) * 1e18 - drop; // bps times 1e18
        // filled (1e18 per token) x live (1e8 per dollar) x share (1e4 x 1e18 per whole) -> USDG (1e6 per dollar)
        cost = Math.mulDiv(filled, live_ * shareE18, 1e42, Math.Rounding.Ceil);
        if (cost < MIN_COST && filled < left) revert TooSmall(cost, MIN_COST);
    }

    /// @dev The newest feed phase, from the round's own `p` up, whose first round was posted before `x`: the phase that
    ///      answered at expiry. Read from the chain, no caller input, so at any moment there is one (review L-3 and the
    ///      re-check's R-1: an upgrade mid-week settles in the new phase even if the old one stopped posting). At most four
    ///      upgrades in a week are followed.
    function _settlePhase(uint16 p, uint256 x) internal view returns (uint16 g) {
        g = p;
        for (uint256 k = uint256(p) + 1; k <= uint256(p) + 4; k++) {
            (, uint256 first) = CallsPrice.read(feed, uint80((k << 64) | 1));
            if (first == 0 || first >= x) break;
            g = uint16(k);
        }
    }

    /// @dev The feed's answer at expiry `x` (see settle()), or a revert. Everything is read in `phase` (_settlePhase), so
    ///      a feed upgrade can never offer a second answer. The cutoff is the last second before expiry, so a post landing
    ///      exactly at expiry (when the market is already shut) counts as after it, and the answer before it settles
    ///      (review L-1).
    function _priceAtExpiry(uint80 hint, uint256 x, uint16 phase) internal view returns (uint256) {
        (int256 a, uint256 u) = CallsPrice.read(feed, hint);
        if (a <= 0 || u == 0 || uint256(hint) >> 64 != phase) revert BadHint();
        if (u < x) {
            _answerAt(hint, x - 1, phase);
            if (!CallsCalendar.fresh(u, x - 1, MAX_PRICE_AGE)) revert StaleAtExpiry();
        } else {
            if (u > x + SETTLE_WAIT) revert TooLate();
            if (uint64(hint) <= 1) revert BadHint();
            (int256 pa, uint256 pu) = CallsPrice.read(feed, hint - 1);
            if (pu == 0 || pu >= x) revert BadHint(); // hint is the phase's first post at or after expiry
            if (pa > 0 && CallsCalendar.fresh(pu, x - 1, MAX_PRICE_AGE)) revert FreshAtExpiry();
        }
        return uint256(a);
    }

    /// @dev Checks that `hint` is the last round of `phase` posted at or before `t`, and returns its answer, its time and
    ///      when the phase's next round was posted (zero: not yet). Reverts BadHint otherwise.
    function _answerAt(uint80 hint, uint256 t, uint16 phase) internal view returns (int256 a, uint256 u, uint256 next) {
        if (uint256(hint) >> 64 != phase) revert BadHint();
        (a, u) = CallsPrice.read(feed, hint);
        if (u == 0 || u > t) revert BadHint();
        (, next) = CallsPrice.read(feed, hint + 1);
        if (next != 0 && next <= t) revert BadHint();
    }

    /// @dev The end of round `id`: withdrawals queued in it leave at the vault's share price after its payout, then
    ///      deposits queued in it join at the share price after that. `before` is the premium per share before the round
    ///      paid its own.
    function _close(uint256 id, uint256 before) internal {
        Book storage b = _books[id];
        b.accBefore = before;
        b.accAt = acc;
        uint256 part = totalSupply() + unclaimed + queuedOut;
        b.outNum = active + 1;
        b.outDen = part + 1;
        uint256 out = Math.mulDiv(queuedOut, b.outNum, b.outDen);
        active -= out;
        leaving += out;
        part -= queuedOut;
        queuedOut = 0;
        b.inNum = part + 1;
        b.inDen = active + 1;
        unclaimed += Math.mulDiv(pendingIn, b.inNum, b.inDen);
        active += pendingIn;
        pendingIn = 0;
    }

    /// @dev Brings `who` up to date with rounds that have ended: a deposit that waited becomes shares (with the premium
    ///      they earned since), a withdrawal that waited becomes Borro vault shares to collect (with its round's premium).
    function _sync(address who) internal {
        Queued memory q = depositQueued[who];
        if (q.amount != 0 && _ended(q.round)) {
            Book storage b = _books[q.round];
            uint256 shares = Math.mulDiv(q.amount, b.inNum, b.inDen);
            delete depositQueued[who];
            unclaimed -= shares;
            _earned[who] += Math.mulDiv(shares, acc - b.accAt, ACC);
            if (shares != 0) _mint(who, shares);
            emit Deposited(who, who, q.amount, shares);
        }
        q = withdrawQueued[who];
        if (q.amount != 0 && _ended(q.round)) {
            Book storage b = _books[q.round];
            delete withdrawQueued[who];
            _earned[who] += Math.mulDiv(q.amount, b.accAt - b.accBefore, ACC);
            sharesOut[who] += Math.mulDiv(q.amount, b.outNum, b.outDen);
        }
    }

    function _enter(uint256 vaultShares, address receiver) internal returns (uint256 shares) {
        if (vaultShares == 0) revert Nothing();
        if (receiver == address(0)) revert ZeroAddress();
        _sync(receiver);
        if (_live()) {
            Queued storage q = depositQueued[receiver];
            q.round = uint64(currentRound);
            q.amount += SafeCast.toUint192(vaultShares);
            pendingIn += vaultShares;
            emit DepositQueued(msg.sender, receiver, currentRound, vaultShares);
            return 0;
        }
        shares = Math.mulDiv(vaultShares, totalSupply() + unclaimed + 1, active + 1);
        if (shares == 0) revert Nothing();
        active += vaultShares;
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, vaultShares, shares);
    }

    /// @dev Pays `who`'s waiting Borro vault shares (plus `extra` already taken from `active`) and premium to `receiver`.
    function _collect(address who, address receiver, bool asStock, uint256 extra)
        internal
        returns (uint256 vaultShares, uint256 usdgOut)
    {
        vaultShares = sharesOut[who];
        if (vaultShares != 0) {
            sharesOut[who] = 0;
            leaving -= vaultShares;
        }
        _settleAccrual(who);
        usdgOut = _earned[who];
        if (usdgOut != 0) {
            _earned[who] = 0;
            usdgOwed -= usdgOut;
            // A USDG transfer that fails (USDG paused, or the receiver frozen) leaves the premium owed: it never stops
            // the stock from leaving.
            if (!usdg.trySafeTransfer(receiver, usdgOut)) {
                _earned[who] = usdgOut;
                usdgOwed += usdgOut;
                usdgOut = 0;
            }
        }
        if (vaultShares + extra != 0) _payShares(receiver, vaultShares + extra, asStock);
        if (vaultShares != 0 || usdgOut != 0) emit Collected(who, receiver, vaultShares, usdgOut);
    }

    function _payShares(address receiver, uint256 vaultShares, bool asStock) internal {
        if (asStock) bVault.redeem(vaultShares, receiver, address(this));
        else IERC20(address(bVault)).safeTransfer(receiver, vaultShares);
    }

    function _settleAccrual(address who) internal {
        uint256 a = acc;
        uint256 paid = _accPaid[who];
        if (a != paid) {
            _earned[who] += Math.mulDiv(balanceOf(who), a - paid, ACC);
            _accPaid[who] = a;
        }
    }

    /// @dev Every balance change first credits the premium earned on the balance before it.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _settleAccrual(from);
        if (to != address(0)) _settleAccrual(to);
        super._update(from, to, value);
    }
}
