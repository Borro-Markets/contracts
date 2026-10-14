// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketHours} from "./eth/MarketHours.sol";

/// A Morpho Vault V2 seen as an ERC-4626 vault: the stock vaults (bNVDA and the rest) and the Steakhouse USDG vault
/// GapPool's capital sits in. Shares are 18 decimals; conversions round down.
interface IShareVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// A Chainlink price feed proxy, with its round history. Round ids carry the proxy's phase in their top 16 bits
/// (phase << 64 | the aggregator's own round). A round the current phase never printed answers zeros; a phase the
/// proxy never had reverts. `phaseAggregators` names each phase's aggregator, whose `latestRound()` is that phase's
/// last round number (read here by a raw staticcall; a proxy or aggregator that will not answer leaves a phase's
/// first round unprovable, and the void covers that).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80);
    function getRoundData(uint80 roundId) external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
    function phaseAggregators(uint16 phase) external view returns (address);
}

interface IAggregator {
    function latestRound() external view returns (uint256);
}

/// @title OptionsDesk
/// @notice Weekly European calls and puts on Borro's stocks (docs/OPTIONS.md), written against money that keeps
///         earning. A covered call locks the stock's Borro vault shares (bNVDA and the rest) and pays in those shares,
///         so the stock earns rent from shorters until it is called away. A cash-secured put locks shares of the
///         Steakhouse USDG vault and pays in USDG, so the dollars earn the vault's interest. Every option is
///         collateralized in full the moment it is sold: one unit of stock per unit of a call, the strike in USDG per
///         unit of a put. No margin, no liquidations. Writers post asks and buyers post bids; either side fills the
///         other, and Borro keeps a share of every premium paid. Longs are ERC-1155 balances, one id per series, so a
///         long can move; a writer's obligation is a record on the writer and does not. Expiry is Friday 20:00 New
///         York, and the settlement price is the feed's last print at or before it, proven on chain by its round id.
///         If the feed printed nothing in the FEED_MAX_AGE before expiry, the price is its first print after expiry
///         instead, proven the same way; and a series the feed has not priced VOID_AFTER past expiry can be voided
///         by anyone: writers take their whole lock back and longs get nothing, since there is no price to pay on.
/// @dev One contract for every stock; a stock is its Chainlink feed, and its vault is fixed the first time it is
///      listed. The owner (the Hoard Safe) lists stocks, switches them off for new orders, sets the fee within a hard
///      cap and pauses new orders and fills. It cannot touch an order, a lock, a payout or a settlement, and it can
///      never point a feed at another vault, so a lock can never be redirected. Shares pulled for locks sit here;
///      the contract holds nothing else. Settlement pays each unit the same, so the per-unit payout is capped by the
///      thinnest lock any fill brought (a vault loss between fill and settlement could otherwise leave the last
///      claimant short); writers always get back their lock less what they owe, never less than nothing. An ask's
///      lock is measured again when it fills, and a fill that would sell a lock worth less than the series needs
///      is refused. The fee an order pays is the fee when it was posted.
///
///      Settlement, exactly. `settle(id, roundId)` after expiry accepts one of two rounds, and the proof is checked
///      against the feed's own history, so nobody chooses the price:
///      1. The last round at or before expiry: it printed in (expiry - FEED_MAX_AGE, expiry], and the round after it
///         (the next in its phase) printed after expiry or does not exist, in which case the round is the feed's
///         latest.
///      2. Otherwise the first round after expiry: it printed after expiry, and the round before it (the previous in
///         its phase, or the prior phase's last round when it is a phase's first) does not exist or printed at or
///         before expiry - FEED_MAX_AGE.
///      The round's phase must be the feed's latest phase. The phase before it is accepted only when the latest
///      phase's first round printed after expiry, so an old aggregator that keeps printing after a phase switch
///      cannot offer a second price. A phase's first round proves as the first after expiry only when the prior
///      phase's last round can be read and is stale: a lookup that fails is refused, never read as "no round
///      before", so a phase switch after expiry cannot offer a second price either. Settlement opens the second
///      after expiry, so it cannot race a print stamped in the expiry second. `void(id)` is for a feed that never
///      printed again (or a phase that cannot be proven): VOID_AFTER past expiry, anyone may close an unsettled
///      series with zero payouts. Settle first; a void is final too.
contract OptionsDesk is ERC1155, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 2_000; // Borro's share of a premium never passes 20%
    uint256 public constant STRIKE_TICK = 25_000_000; // $0.25 in the feeds' 8-decimal units
    uint256 public constant MAX_WEEKS = 8; // the furthest expiry an order may name
    uint256 public constant MIN_UNITS = 1e15; // 0.001 of a share; smaller orders and fills are refused
    uint256 public constant FEED_MAX_AGE = 2 days; // the feed's 24-hour heartbeat plus a holiday: a round older than this before expiry is not the close
    uint256 public constant VOID_AFTER = 14 days; // a series the feed has not priced this long after expiry can be voided
    uint256 public constant LOCK_SLACK_PPM = 1; // an ask's lock may fall short of the series' need by one part in a million (rounding) at fill
    uint256 public constant LAST_FILL = 1 hours; // the last hour before expiry belongs to settlement: no orders, no fills
    uint256 internal constant UNIT = 1e18; // one unit of stock, and the denominator of every per-unit number

    IERC20 public immutable usdg;
    IShareVault public immutable usdgVault; // Steakhouse; usdgVault.asset() == usdg. Puts lock its shares.

    struct Stock {
        address feed;
        IShareVault vault; // the stock's Borro vault; vault.asset() is the stock token. Never changes once set.
        bool allowed; // open for new orders
    }

    struct Series {
        address feed;
        uint64 expiry;
        uint128 strike; // feed units, 8 decimals
        bool isCall;
        uint128 openUnits; // units written; claims burn tokens, not this
        uint128 lockedShares; // every writer's lock together (stock vault shares for a call, USDG vault shares for a put)
        uint128 minLockPerUnit; // the thinnest lock any fill brought, in shares per 1e18 units: the payout's ceiling
        bool settled;
        uint128 settlePrice; // feed units
        uint128 payoutSharesPerUnit; // shares per 1e18 units a long is paid
        uint128 payoutUsdgPerUnit; // puts only: what those shares were worth at settlement, USDG wei per 1e18 units
    }

    struct Order {
        address maker;
        bytes32 series;
        bool isAsk;
        uint128 units; // still open
        uint128 premium; // USDG wei per 1e18 units
        uint128 locked; // an ask: collateral shares for its units; a bid: the USDG its premium locks
        uint16 feeBps; // Borro's share of the premium, as it was when the order was posted
    }

    struct Written {
        uint128 units;
        uint128 lockedShares;
        bool released;
    }

    mapping(address feed => Stock) public stocks;
    mapping(bytes32 id => Series) internal _series;
    mapping(uint256 id => Order) internal _orders;
    mapping(address writer => mapping(bytes32 id => Written)) internal _written;

    uint256 public nextId = 1; // order ids start at 1
    address public feeRecipient;
    uint16 public feeBps;
    bool public paused;

    event StockSet(address indexed feed, address indexed vault, bool allowed);
    event FeeSet(uint16 feeBps, address recipient);
    event PausedSet(bool paused);
    event SeriesOpened(bytes32 indexed id, address indexed feed, uint64 expiry, uint128 strike, bool isCall);
    event Posted(
        uint256 indexed orderId, address indexed maker, bytes32 indexed series, bool isAsk, uint128 units, uint128 premium, uint256 locked
    );
    event Filled(
        uint256 indexed orderId,
        bytes32 indexed series,
        address indexed writer,
        address buyer,
        uint128 units,
        uint256 premium,
        uint256 fee,
        uint256 lockedShares
    );
    event Cancelled(uint256 indexed orderId, address indexed maker, address by, uint256 returned);
    event Settled(bytes32 indexed id, uint80 roundId, uint256 settlePrice, uint256 payoutSharesPerUnit, uint256 payoutUsdgPerUnit);
    event Voided(bytes32 indexed id);
    event Claimed(bytes32 indexed id, address indexed who, uint256 units, uint256 shares, uint256 usdgPaid);
    event Released(bytes32 indexed id, address indexed writer, uint256 shares);

    error BadVault();
    error BadFeed();
    error BadValue();
    error NotAllowed();
    error Paused();
    error BadExpiry();
    error BadStrike();
    error TooSmall();
    error TooLate();
    error Nothing();
    error NoOrder();
    error NotMaker();
    error WrongSide();
    error TooMuch(uint256 premium, uint256 maxPremium);
    error TooLittle(uint256 premium, uint256 minPremium);
    error NoSeries();
    error NotExpired();
    error AlreadySettled();
    error NotSettled();
    error WrongRound();
    error AlreadyReleased();
    error LockShort();

    constructor(IERC20 usdg_, IShareVault usdgVault_, address owner_) ERC1155("") Ownable(owner_) {
        if (usdgVault_.asset() != address(usdg_)) revert BadVault();
        usdg = usdg_;
        usdgVault = usdgVault_;
    }

    // ================================================================= owner

    /// @notice List a stock by its feed and its Borro vault, or switch a listed one on or off for new orders. The
    ///         vault is fixed the first time: later calls must name the same one. Switching off stops new orders
    ///         only; open orders still fill, and every series settles as written.
    function setStock(address feed, IShareVault vault, bool allowed) external onlyOwner {
        Stock storage s = stocks[feed];
        if (s.feed == address(0)) {
            if (feed == address(0) || IPriceFeed(feed).decimals() != 8) revert BadFeed();
            if (address(vault) == address(0) || address(vault) == address(usdgVault) || vault.asset() == address(0)) {
                revert BadVault();
            }
            s.feed = feed;
            s.vault = vault;
        } else if (vault != s.vault) {
            revert BadVault();
        }
        s.allowed = allowed;
        emit StockSet(feed, address(vault), allowed);
    }

    /// @notice Borro's share of each premium, at most MAX_FEE_BPS, and who gets it.
    function setFee(uint16 feeBps_, address recipient) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS || recipient == address(0)) revert BadValue();
        feeBps = feeBps_;
        feeRecipient = recipient;
        emit FeeSet(feeBps_, recipient);
    }

    /// @notice Stop new orders and fills. Cancels, settlements, claims and releases are never stopped.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ================================================================= orders

    /// @notice Offer to write `units` of a series at `premium` USDG per 1e18 units. Locks the collateral now: a
    ///         call pulls the stock vault's shares for `units`, a put pulls USDG vault shares worth the strike.
    function postAsk(address feed, uint64 expiry, uint128 strike, bool isCall, uint128 units, uint128 premium)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        (bytes32 id, Stock storage s) = _open(feed, expiry, strike, isCall, units, premium);
        orderId = _post(id, true, units, premium, _lockShares(s, strike, isCall, units));
    }

    /// @notice A put ask paid for in USDG: the strike's worth is deposited into the USDG vault for the writer and
    ///         those shares are the lock.
    function postAskWithUsdg(address feed, uint64 expiry, uint128 strike, uint128 units, uint128 premium)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        (bytes32 id,) = _open(feed, expiry, strike, false, units, premium);
        orderId = _post(id, true, units, premium, _lockUsdg(strike, units));
    }

    /// @notice A call ask paid for in the stock itself: `units` of the stock token are lent into the stock's vault
    ///         for the writer and those shares are the lock.
    function postAskWithStock(address feed, uint64 expiry, uint128 strike, uint128 units, uint128 premium)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        (bytes32 id, Stock storage s) = _open(feed, expiry, strike, true, units, premium);
        orderId = _post(id, true, units, premium, _lockStock(s, units));
    }

    /// @notice Offer to buy `units` of a series at `premium` USDG per 1e18 units. Locks the premium now.
    function postBid(address feed, uint64 expiry, uint128 strike, bool isCall, uint128 units, uint128 premium)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        (bytes32 id,) = _open(feed, expiry, strike, isCall, units, premium);
        uint256 locked = uint256(units) * premium / UNIT;
        if (locked == 0) revert Nothing();
        usdg.safeTransferFrom(msg.sender, address(this), locked);
        orderId = _post(id, false, units, premium, locked);
    }

    /// @notice Take an order back. Its maker may at any time; anyone may once the series has expired. Returns what
    ///         is still locked: an ask's collateral shares, a bid's USDG.
    function cancel(uint256 orderId) external nonReentrant {
        Order memory o = _orders[orderId];
        if (o.maker == address(0)) revert NoOrder();
        Series storage sr = _series[o.series];
        if (msg.sender != o.maker && block.timestamp < sr.expiry) revert NotMaker();
        delete _orders[orderId];
        if (o.locked != 0) {
            if (o.isAsk) IERC20(_vaultOf(sr)).safeTransfer(o.maker, o.locked);
            else usdg.safeTransfer(o.maker, o.locked);
        }
        emit Cancelled(orderId, o.maker, msg.sender, o.locked);
    }

    /// @notice Buy `units` of an ask: pay units * premium / 1e18 USDG (at most `maxPremium` in all; the fee comes
    ///         out of it) and receive `units` of the series' ERC-1155 token. The ask's lock moves pro rata into the
    ///         writer's obligation, and must still be worth what the series needs for those units (a vault loss
    ///         since the post makes the ask unfillable: the writer cancels and posts again).
    function fillAsk(uint256 orderId, uint128 units, uint128 maxPremium) external nonReentrant {
        Order storage o = _orders[orderId];
        Series storage sr = _fillable(o, true, units);
        uint256 premium = uint256(units) * o.premium / UNIT;
        if (premium > maxPremium) revert TooMuch(premium, maxPremium);
        uint256 moved = _share(o.locked, units, o.units);
        uint256 need = sr.isCall ? units : _usdgFor(sr.strike, units);
        uint256 slack = need * LOCK_SLACK_PPM / 1e6;
        if (slack < 3) slack = 3; // rounding between post and fill loses up to two base units; never refuse those
        if (IShareVault(_vaultOf(sr)).convertToAssets(moved) + slack < need) revert LockShort();
        uint256 fee = premium * o.feeBps / BPS;
        address writer = o.maker;
        bytes32 id = o.series;
        _consume(orderId, o, units, moved);
        if (premium != fee) usdg.safeTransferFrom(msg.sender, writer, premium - fee);
        if (fee != 0) usdg.safeTransferFrom(msg.sender, feeRecipient, fee);
        _write(orderId, sr, id, writer, msg.sender, units, moved, premium, fee);
    }

    /// @notice Write `units` against a bid: lock the collateral (pulled as vault shares) and receive the bid's
    ///         premium for those units less the fee, which must come to at least `minPremium` in all.
    function fillBid(uint256 orderId, uint128 units, uint128 minPremium) external nonReentrant {
        _fillBid(orderId, units, minPremium, 0);
    }

    /// @notice Write a put against a bid, paying the collateral in USDG, which is deposited into the USDG vault.
    function fillBidWithUsdg(uint256 orderId, uint128 units, uint128 minPremium) external nonReentrant {
        _fillBid(orderId, units, minPremium, 1);
    }

    /// @notice Write a call against a bid, paying the collateral in the stock, which is lent into its vault.
    function fillBidWithStock(uint256 orderId, uint128 units, uint128 minPremium) external nonReentrant {
        _fillBid(orderId, units, minPremium, 2);
    }

    // ================================================================= after expiry

    /// @notice Settle a series with its proving round (see the contract notes): the feed's last round at or before
    ///         expiry, or, when nothing printed in the FEED_MAX_AGE before expiry, its first round after. Opens the
    ///         second after expiry. Fixes the payout per unit, capped by the thinnest lock. Anyone may call; final.
    function settle(bytes32 id, uint80 roundId) external nonReentrant {
        Series storage sr = _series[id];
        if (sr.feed == address(0)) revert NoSeries();
        if (sr.settled) revert AlreadySettled();
        if (block.timestamp <= sr.expiry) revert NotExpired();
        uint256 price = _provenPrice(sr.feed, sr.expiry, roundId);
        uint256 strike = sr.strike;
        uint256 shares;
        uint256 usdgPer;
        if (sr.isCall) {
            if (price > strike) shares = stocks[sr.feed].vault.convertToShares((price - strike) * UNIT / price);
        } else if (strike > price) {
            usdgPer = (strike - price) / 100;
            shares = _sharesUp(usdgVault, usdgPer);
        }
        if (sr.openUnits != 0 && shares > sr.minLockPerUnit) {
            shares = sr.minLockPerUnit;
            if (!sr.isCall) usdgPer = usdgVault.convertToAssets(shares);
        }
        sr.settled = true;
        sr.settlePrice = uint128(price);
        sr.payoutSharesPerUnit = uint128(shares);
        sr.payoutUsdgPerUnit = uint128(usdgPer);
        emit Settled(id, roundId, price, shares, usdgPer);
    }

    /// @notice Close a series the feed never priced: VOID_AFTER past expiry, if it is still unsettled, anyone may
    ///         mark it settled with zero payouts. Writers then release their whole lock; longs get nothing, as a
    ///         feed that printed nothing for two weeks after expiry has no price to pay them on. Settle while a round
    ///         proves; a void is final too.
    function void(bytes32 id) external nonReentrant {
        Series storage sr = _series[id];
        if (sr.feed == address(0)) revert NoSeries();
        if (sr.settled) revert AlreadySettled();
        if (block.timestamp < uint256(sr.expiry) + VOID_AFTER) revert NotExpired();
        sr.settled = true;
        emit Voided(id);
    }

    /// @notice Burn `units` of a settled series and take their payout: a call pays stock vault shares; a put pays
    ///         USDG, redeemed from the USDG vault (the payout fixed at settlement plus what it earned since), or the
    ///         vault's shares themselves when `asShares` (for when the vault is short of liquidity).
    function claim(bytes32 id, uint256 units, bool asShares) external nonReentrant returns (uint256 paid) {
        Series storage sr = _series[id];
        if (!sr.settled) revert NotSettled();
        if (units == 0) revert Nothing();
        _burn(msg.sender, uint256(id), units);
        uint256 shares = units * sr.payoutSharesPerUnit / UNIT;
        uint256 usdgPaid;
        if (shares != 0) {
            if (sr.isCall || asShares) {
                IERC20(_vaultOf(sr)).safeTransfer(msg.sender, shares);
                paid = shares;
            } else {
                usdgPaid = usdgVault.redeem(shares, msg.sender, address(this));
                paid = usdgPaid;
            }
        }
        emit Claimed(id, msg.sender, units, shares, usdgPaid);
    }

    /// @notice A writer takes back the lock of a settled series less what the units written owe, once.
    function release(bytes32 id) external nonReentrant returns (uint256 sharesBack) {
        Series storage sr = _series[id];
        if (!sr.settled) revert NotSettled();
        Written storage w = _written[msg.sender][id];
        if (w.units == 0) revert Nothing();
        if (w.released) revert AlreadyReleased();
        w.released = true;
        uint256 owed = (uint256(w.units) * sr.payoutSharesPerUnit + UNIT - 1) / UNIT;
        sharesBack = w.lockedShares > owed ? w.lockedShares - owed : 0;
        if (sharesBack != 0) IERC20(_vaultOf(sr)).safeTransfer(msg.sender, sharesBack);
        emit Released(id, msg.sender, sharesBack);
    }

    // ================================================================= views

    function seriesIdOf(address feed, uint64 expiry, uint128 strike, bool isCall) public pure returns (bytes32) {
        return keccak256(abi.encode(feed, expiry, strike, isCall));
    }

    function seriesOf(bytes32 id) external view returns (Series memory) {
        return _series[id];
    }

    function orderOf(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    function writtenOf(address writer, bytes32 id) external view returns (Written memory) {
        return _written[writer][id];
    }

    /// @notice What an ask, or a fill of a bid, locks now for `units`: stock vault shares for a call, USDG vault
    ///         shares worth the strike for a put. Zero for a feed that is not listed.
    function collateralFor(address feed, uint128 strike, bool isCall, uint128 units) external view returns (uint256) {
        if (isCall) {
            IShareVault v = stocks[feed].vault;
            return address(v) == address(0) ? 0 : _sharesUp(v, units);
        }
        return _sharesUp(usdgVault, _usdgFor(strike, units));
    }

    /// @notice What `units` of a settled series pay: shares (of the stock vault for a call, the USDG vault for a
    ///         put) and, for a put, what those shares were worth in USDG at settlement. Zeros before settlement.
    function payoutOf(bytes32 id, uint256 units) external view returns (uint256 shares, uint256 usdgOut) {
        Series storage sr = _series[id];
        shares = units * sr.payoutSharesPerUnit / UNIT;
        usdgOut = units * sr.payoutUsdgPerUnit / UNIT;
    }

    /// @notice Whether `t` is a valid expiry: exactly Friday 20:00 New York.
    function isExpiry(uint64 t) external pure returns (bool) {
        return MarketHours.isWeekClose(t);
    }

    /// @notice The first expiry strictly after `t`.
    function expiryAfter(uint64 t) external pure returns (uint64) {
        return uint64(MarketHours.weekCloseAfter(t));
    }

    // ================================================================= internals

    /// @dev Every check an order must pass, and the series' record if this is its first order.
    function _open(address feed, uint64 expiry, uint128 strike, bool isCall, uint128 units, uint128 premium)
        internal
        returns (bytes32 id, Stock storage s)
    {
        if (paused) revert Paused();
        s = stocks[feed];
        if (!s.allowed) revert NotAllowed();
        if (!MarketHours.isWeekClose(expiry) || expiry > block.timestamp + MAX_WEEKS * 1 weeks) revert BadExpiry();
        if (block.timestamp + LAST_FILL > expiry) revert TooLate();
        if (strike == 0 || strike % STRIKE_TICK != 0) revert BadStrike();
        if (units < MIN_UNITS) revert TooSmall();
        if (premium == 0) revert BadValue();
        id = seriesIdOf(feed, expiry, strike, isCall);
        Series storage sr = _series[id];
        if (sr.feed == address(0)) {
            sr.feed = feed;
            sr.expiry = expiry;
            sr.strike = strike;
            sr.isCall = isCall;
            emit SeriesOpened(id, feed, expiry, strike, isCall);
        }
    }

    function _post(bytes32 id, bool isAsk, uint128 units, uint128 premium, uint256 locked) internal returns (uint256 orderId) {
        orderId = nextId++;
        _orders[orderId] = Order({
            maker: msg.sender,
            series: id,
            isAsk: isAsk,
            units: units,
            premium: premium,
            locked: _u128(locked),
            feeBps: feeBps
        });
        emit Posted(orderId, msg.sender, id, isAsk, units, premium, locked);
    }

    /// @dev The order exists, is the side asked for, can still be filled, and `units` is a whole fill or a partial
    ///      one that leaves neither side below MIN_UNITS.
    function _fillable(Order storage o, bool isAsk, uint128 units) internal view returns (Series storage sr) {
        if (o.maker == address(0)) revert NoOrder();
        if (o.isAsk != isAsk) revert WrongSide();
        if (paused) revert Paused();
        sr = _series[o.series];
        if (block.timestamp + LAST_FILL > sr.expiry) revert TooLate();
        if (units == 0 || units > o.units) revert BadValue();
        if (units != o.units && (units < MIN_UNITS || o.units - units < MIN_UNITS)) revert TooSmall();
    }

    function _fillBid(uint256 orderId, uint128 units, uint128 minPremium, uint8 how) internal {
        Order storage o = _orders[orderId];
        Series storage sr = _fillable(o, false, units);
        uint256 premium = _share(o.locked, units, o.units); // the bid's lock, pro rata, so nothing is left behind
        uint256 fee = premium * o.feeBps / BPS;
        if (premium - fee < minPremium) revert TooLittle(premium - fee, minPremium);
        address buyer = o.maker;
        bytes32 id = o.series;
        _consume(orderId, o, units, premium);
        uint256 locked;
        if (how == 0) locked = _lockShares(stocks[sr.feed], sr.strike, sr.isCall, units);
        else if (how == 1) locked = sr.isCall ? _wrongSide() : _lockUsdg(sr.strike, units);
        else locked = sr.isCall ? _lockStock(stocks[sr.feed], units) : _wrongSide();
        if (premium != fee) usdg.safeTransfer(msg.sender, premium - fee);
        if (fee != 0) usdg.safeTransfer(feeRecipient, fee);
        _write(orderId, sr, id, msg.sender, buyer, units, locked, premium, fee);
    }

    function _wrongSide() internal pure returns (uint256) {
        revert WrongSide();
    }

    /// @dev Take `units` and `locked` off an order, deleting it when nothing is left.
    function _consume(uint256 orderId, Order storage o, uint128 units, uint256 locked) internal {
        if (units == o.units) {
            delete _orders[orderId];
        } else {
            o.units -= units;
            o.locked -= uint128(locked);
        }
    }

    /// @dev Record a fill: the writer's obligation, the series' book, the thinnest lock, and the buyer's tokens.
    function _write(
        uint256 orderId,
        Series storage sr,
        bytes32 id,
        address writer,
        address buyer,
        uint128 units,
        uint256 locked,
        uint256 premium,
        uint256 fee
    ) internal {
        Written storage w = _written[writer][id];
        w.units += units;
        w.lockedShares += _u128(locked);
        uint256 perUnit = locked * UNIT / units;
        if (sr.openUnits == 0 || perUnit < sr.minLockPerUnit) sr.minLockPerUnit = _u128(perUnit);
        sr.openUnits += units;
        sr.lockedShares += _u128(locked);
        // Minted without the ERC-1155 acceptance check: a buyer with code (a delegated wallet, a Safe, any contract
        // without the receiver hook) can hold a long; the tokens never need to be handed back here to be claimed.
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = uint256(id);
        values[0] = units;
        _update(address(0), buyer, ids, values);
        emit Filled(orderId, id, writer, buyer, units, premium, fee, locked);
    }

    /// @dev Pull the collateral for `units` from the writer as vault shares, rounded up.
    function _lockShares(Stock storage s, uint128 strike, bool isCall, uint128 units) internal returns (uint256 shares) {
        IShareVault v = isCall ? s.vault : usdgVault;
        shares = _sharesUp(v, isCall ? units : _usdgFor(strike, units));
        IERC20(address(v)).safeTransferFrom(msg.sender, address(this), shares);
    }

    /// @dev Pull the strike's worth of USDG for `units` from the writer and deposit it into the USDG vault.
    function _lockUsdg(uint128 strike, uint128 units) internal returns (uint256 shares) {
        uint256 assets = _usdgFor(strike, units);
        usdg.safeTransferFrom(msg.sender, address(this), assets);
        usdg.forceApprove(address(usdgVault), assets);
        shares = usdgVault.deposit(assets, address(this));
    }

    /// @dev Pull `units` of the stock from the writer and lend it into the stock's vault.
    function _lockStock(Stock storage s, uint128 units) internal returns (uint256 shares) {
        IERC20 stock = IERC20(s.vault.asset());
        stock.safeTransferFrom(msg.sender, address(this), units);
        stock.forceApprove(address(s.vault), units);
        shares = s.vault.deposit(units, address(this));
    }

    /// @dev The strike in USDG for `units`: units * strike / 1e18 / 100 (strike 8 decimals, USDG 6), rounded up.
    function _usdgFor(uint128 strike, uint128 units) internal pure returns (uint256) {
        return (uint256(units) * strike + 1e20 - 1) / 1e20;
    }

    /// @dev `assets` in `v`'s shares, rounded up.
    function _sharesUp(IShareVault v, uint256 assets) internal view returns (uint256 shares) {
        shares = v.convertToShares(assets);
        if (v.convertToAssets(shares) < assets) shares += 1;
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert BadValue();
        return uint128(x);
    }

    /// @dev `part` of `whole` out of `total`; the whole of it when the order is taken entirely.
    function _share(uint256 total, uint128 part, uint128 whole) internal pure returns (uint256) {
        return part == whole ? total : total * part / whole;
    }

    function _vaultOf(Series storage sr) internal view returns (address) {
        return sr.isCall ? address(stocks[sr.feed].vault) : address(usdgVault);
    }

    /// @dev The price of `roundId`, checked to be the series' proving round: the feed's last round at or before
    ///      `expiry` if one printed within FEED_MAX_AGE of it, else its first round after. The round's phase is the
    ///      feed's latest phase, or the one before it when the latest phase began after expiry.
    function _provenPrice(address feed, uint64 expiry, uint80 roundId) internal view returns (uint256) {
        IPriceFeed f = IPriceFeed(feed);
        (, int256 answer,, uint256 at,) = f.getRoundData(roundId);
        if (answer <= 0 || at == 0 || uint256(answer) > type(uint128).max) revert WrongRound();
        (uint80 latest,,,,) = f.latestRoundData();
        uint16 phase = uint16(roundId >> 64);
        uint16 latestPhase = uint16(latest >> 64);
        if (phase != latestPhase) {
            if (phase + 1 != latestPhase || _roundTime(f, (uint80(latestPhase) << 64) | 1) <= expiry) revert WrongRound();
        }
        if (at <= expiry) {
            // The last round at or before expiry: recent enough, and nothing of its phase after it before expiry.
            if (at + FEED_MAX_AGE <= expiry) revert WrongRound();
            uint256 nextAt = uint64(roundId) == type(uint64).max ? 0 : _roundTime(f, roundId + 1);
            if (nextAt != 0) {
                if (nextAt <= expiry) revert WrongRound();
            } else if (phase == latestPhase && latest != roundId) {
                revert WrongRound();
            }
        } else {
            // The first round after expiry: the round before it printed too early to be the close, or never.
            uint256 prevAt = _prevRoundTime(f, roundId, phase);
            if (prevAt != 0 && prevAt + FEED_MAX_AGE > expiry) revert WrongRound();
        }
        return uint256(answer);
    }

    /// @dev When the round before `roundId` printed: the previous round of its phase, or, for a phase's first round,
    ///      the prior phase's last round (its aggregator's `latestRound()`). Zero when the first phase has nothing
    ///      before it. A prior phase that cannot be read is a failed proof, not a missing round.
    function _prevRoundTime(IPriceFeed f, uint80 roundId, uint16 phase) internal view returns (uint256) {
        if (uint64(roundId) > 1) return _roundTime(f, roundId - 1);
        if (phase <= 1) return 0;
        (bool ok, uint256 agg) = _staticUint(address(f), abi.encodeCall(IPriceFeed.phaseAggregators, (phase - 1)));
        if (!ok || agg == 0 || agg > type(uint160).max) revert WrongRound();
        uint256 last;
        (ok, last) = _staticUint(address(uint160(agg)), abi.encodeCall(IAggregator.latestRound, ()));
        if (!ok || last == 0 || last > type(uint64).max) revert WrongRound();
        return _roundTime(f, (uint80(phase - 1) << 64) | uint80(last));
    }

    /// @dev A staticcall that answers one word, or nothing: a missing function or contract is not a revert here.
    function _staticUint(address to, bytes memory data) internal view returns (bool ok, uint256 word) {
        bytes memory ret;
        (ok, ret) = to.staticcall(data);
        if (!ok || ret.length < 32) return (false, 0);
        word = abi.decode(ret, (uint256));
    }

    function _roundTime(IPriceFeed f, uint80 id) internal view returns (uint256) {
        try f.getRoundData(id) returns (uint80, int256, uint256, uint256 at, uint80) {
            return at;
        } catch {
            return 0;
        }
    }
}
