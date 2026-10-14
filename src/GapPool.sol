// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketHours} from "./eth/MarketHours.sol";

/// The lending vault the pool's capital sits in (Morpho Vault V2's ERC-4626 surface): the same Steakhouse USDG vault
/// BorroShort's held money sits in.
interface IHeldVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// A Chainlink price feed proxy, with its round history. Round ids carry the proxy's phase in their top 16 bits
/// (phase << 64 | the aggregator's own round).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80);
    function getRoundData(uint80 roundId) external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title GapPool
/// @notice Monday-gap insurance for Borro's Weekend Desk (docs/WEEKEND.md). While the 24/5 stock market is shut, a
///         shorter holding NVDA over the weekend buys "up cover": if the first feed print after the market reopens is
///         more than the strike above the feed's last print, the cover pays the move beyond the strike, up to a cap. A
///         leveraged long buys "down cover". USDG lenders fund the pool and hold its shares (bGAP); their capital sits
///         in the Steakhouse USDG vault, so premiums stack on the vault's interest. Borro keeps a share of each premium.
/// @dev One contract for every stock; a stock is its Chainlink feed. Every cover is collateralized in full at the cap
///      the moment it is bought: the reserve comes out of free capital and is released once, by the settlement or the
///      void, so a seller never owes more than what is in the pool and a buyer is paid from money set aside for them.
///      The reference price is the paused feed, the same number Morpho uses. Settlement is by the first feed round
///      after the reopen, a public fact anyone can supply and this contract checks against the round before it.
///      The stocks are fixed at deploy (their feeds are the only ones a cover can ever be written on). The owner (the
///      Hoard Safe) switches them on and off, caps exposure per stock and for the pool, bounds premiums, sets the fee
///      within a hard cap, names the quoter and pauses buys or deposits. It cannot move capital or touch a cover,
///      and it cannot add a feed. What lenders trust the owner with: not naming a quoter that sells cover too cheaply.
///      The quoter (the keeper) can only post premiums inside the owner's bounds, and each quote dies after QUOTE_TTL.
///      Capital is locked while any cover is live (from the first buy of a closure to the last settlement), so a
///      seller cannot leave on Sunday night ahead of a loss that lands on Monday; losses fall on every seller alike.
///      A cover settles only on the first print after the reopen, and only if that print lands within SETTLE_WINDOW
///      and inside MAX_MOVE_BPS; otherwise, or if the feed never prints, the cover is voided: premium back, capital
///      released. A payout the buyer's address cannot receive is held for them to claim. Shares use OpenZeppelin's
///      virtual offset against inflation attacks.
contract GapPool is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_CAP_BPS = 2_000; // a cover never pays more than 20% of its notional
    uint256 public constant MIN_STRIKE_BPS = 50; // strikes from 0.5%
    uint256 public constant MAX_STRIKE_BPS = 1_000; // to 10%
    uint256 public constant MAX_FEE_BPS = 2_000; // Borro's share of a premium never passes 20%
    uint256 public constant QUOTE_TTL = 6 hours; // a quote older than this is no quote
    uint256 public constant LAST_BUY = 1 hours; // no buys in the last hour before the reopen
    uint256 public constant SETTLE_GRACE = 7 days; // a cover unsettled this long after its reopen can be voided
    uint256 public constant MAX_REF_AGE = 5 days; // a feed silent longer is not a closed market, it is a broken feed
    uint256 public constant SETTLE_WINDOW = 2 hours; // the first print after the reopen must land within this (it lands within a minute)
    uint256 public constant MAX_MOVE_BPS = 5_000; // a first print further than this from the reference is bad data, not a gap
    uint256 public constant MAX_TOTAL_EXPOSURE_BPS = 5_000; // live covers can never reserve more than half the pool
    uint256 public constant VIRTUAL_SHARES = 1e6; // against share inflation (OpenZeppelin's offset), over one virtual asset

    IERC20 public immutable usdg;
    IHeldVault public immutable vault; // vault.asset() == usdg; idle capital is vault shares

    struct Stock {
        address feed;
        bool allowed;
        uint16 maxExposureBps; // the most of totalAssets this stock's live covers may reserve together
        uint256 reserved; // USDG wei set aside for this stock's live covers
    }

    struct Quote {
        uint64 at;
        uint16 premiumBps;
    }

    struct Cover {
        address buyer;
        address feed;
        uint8 side; // 0 up, 1 down
        uint16 strikeBps;
        uint16 capBps; // the pool's cap when bought
        uint96 notional; // USDG wei
        uint96 premium; // what the pool kept: the premium paid less Borro's fee. Returned on a void.
        uint256 refPrice; // the feed's last print when bought
        uint64 reopenAt; // the market's next open when bought; settles on the first round at or after it
        uint64 boughtAt;
        bool settled; // final: settled or voided
    }

    mapping(address feed => Stock) public stocks;
    mapping(address feed => mapping(uint8 side => mapping(uint16 strikeBps => Quote))) public quotes;
    mapping(uint256 id => Cover) internal _covers;
    mapping(address buyer => uint256[]) internal _coversOf;
    mapping(address to => uint256) public owed; // USDG a settlement or void could not deliver, waiting to be claimed

    uint256 public nextId = 1; // cover ids start at 1
    uint256 public totalReserved; // across every stock
    address public quoter;
    address public feeRecipient;
    uint16 public feeBps;
    uint16 public capBps;
    uint16 public minPremiumBps;
    uint16 public maxPremiumBps;
    uint16 public maxTotalExposureBps; // the most of totalAssets all live covers may reserve together
    bool public buysPaused;
    bool public depositsPaused;

    event StockSet(address indexed feed, bool allowed, uint16 maxExposureBps);
    event QuoterSet(address quoter);
    event FeeSet(uint16 feeBps, address recipient);
    event PremiumBoundsSet(uint16 minBps, uint16 maxBps);
    event CapSet(uint16 capBps);
    event TotalExposureSet(uint16 maxTotalExposureBps);
    event Owed(address indexed to, uint256 amount);
    event Claimed(address indexed from, address indexed to, uint256 amount);
    event PausedSet(bool buys, bool deposits);
    event Quoted(address indexed feed, uint8 indexed side, uint16 strikeBps, uint16 premiumBps);
    event Deposited(address indexed from, address indexed receiver, uint256 assets, uint256 shares);
    event Withdrawn(address indexed from, address indexed receiver, uint256 shares, uint256 assets);
    event Bought(
        uint256 indexed id,
        address indexed buyer,
        address indexed feed,
        uint8 side,
        uint96 notional,
        uint16 strikeBps,
        uint16 capBps,
        uint256 premium,
        uint256 fee,
        uint256 refPrice,
        uint64 reopenAt
    );
    event Settled(uint256 indexed id, uint80 roundId, int256 answer, uint256 payout);
    event Voided(uint256 indexed id, uint256 refund);
    event Swept(address indexed token, address to, uint256 amount);

    error BadVault();
    error BadValue();
    error OnlyQuoter();
    error LengthMismatch();
    error NotAllowed();
    error Paused();
    error Nothing();
    error MarketOpen();
    error TooLate();
    error NoQuote();
    error BadStrike();
    error BadSide();
    error TooMuch(uint256 premium, uint256 maxPremium);
    error BadFeed();
    error NotEnoughCapital(uint256 wanted, uint256 free);
    error OverExposure(uint256 reserved, uint256 allowed);
    error NoCover();
    error AlreadySettled();
    error WrongRound();
    error TooSoon();
    error NotFree(uint256 wanted, uint256 free);
    error CannotSweep();
    error NotListed();
    error Locked();
    error Settleable();

    /// @param feeds_ The stocks, by their Chainlink feeds, fixed for good. Each starts switched off.
    constructor(IERC20 usdg_, IHeldVault vault_, address owner_, address[] memory feeds_)
        ERC20("Borro Gap Cover", "bGAP")
        Ownable(owner_)
    {
        if (vault_.asset() != address(usdg_)) revert BadVault();
        usdg = usdg_;
        vault = vault_;
        for (uint256 i; i < feeds_.length; i++) {
            address feed = feeds_[i];
            if (feed == address(0) || stocks[feed].feed != address(0)) revert BadValue();
            if (IPriceFeed(feed).decimals() == 0) revert BadFeed();
            stocks[feed].feed = feed;
            emit StockSet(feed, false, 0);
        }
    }

    /// @dev USDG has 6 decimals and the first deposit mints VIRTUAL_SHARES (1e6) share units per USDG wei, so 12
    ///      decimals make one USDG of capital read as about one bGAP.
    function decimals() public pure override returns (uint8) {
        return 12;
    }

    // ================================================================= owner

    /// @notice Switch a stock (one of the feeds fixed at deploy) on or off for new covers, and cap how much of the pool
    ///         its covers may reserve. Switching off stops new buys only; live covers settle as bought.
    function setStock(address feed, bool allowed, uint16 maxExposureBps) external onlyOwner {
        if (maxExposureBps > BPS) revert BadValue();
        Stock storage s = stocks[feed];
        if (s.feed == address(0)) revert NotListed();
        s.allowed = allowed;
        s.maxExposureBps = maxExposureBps;
        emit StockSet(feed, allowed, maxExposureBps);
    }

    function setQuoter(address quoter_) external onlyOwner {
        quoter = quoter_;
        emit QuoterSet(quoter_);
    }

    /// @notice Borro's share of each premium, at most MAX_FEE_BPS, and who gets it.
    function setFee(uint16 feeBps_, address recipient) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS || recipient == address(0)) revert BadValue();
        feeBps = feeBps_;
        feeRecipient = recipient;
        emit FeeSet(feeBps_, recipient);
    }

    /// @notice The premiums the quoter may post, in basis points of the notional.
    function setPremiumBounds(uint16 minBps, uint16 maxBps) external onlyOwner {
        if (minBps == 0 || minBps > maxBps || maxBps > BPS) revert BadValue();
        minPremiumBps = minBps;
        maxPremiumBps = maxBps;
        emit PremiumBoundsSet(minBps, maxBps);
    }

    /// @notice The most a cover pays, as a share of its notional. Applies to new covers only.
    function setCapBps(uint16 capBps_) external onlyOwner {
        if (capBps_ == 0 || capBps_ > MAX_CAP_BPS) revert BadValue();
        capBps = capBps_;
        emit CapSet(capBps_);
    }

    /// @notice The most of the pool all live covers may reserve together, at most MAX_TOTAL_EXPOSURE_BPS.
    function setTotalExposure(uint16 maxTotalExposureBps_) external onlyOwner {
        if (maxTotalExposureBps_ > MAX_TOTAL_EXPOSURE_BPS) revert BadValue();
        maxTotalExposureBps = maxTotalExposureBps_;
        emit TotalExposureSet(maxTotalExposureBps_);
    }

    /// @notice Stop new buys or new deposits. Settlements, voids and withdrawals are never stopped.
    function setPaused(bool buys, bool deposits) external onlyOwner {
        buysPaused = buys;
        depositsPaused = deposits;
        emit PausedSet(buys, deposits);
    }

    /// @notice Send out a token that ended up here by mistake. Never USDG and never the vault's shares.
    function sweep(IERC20 token, address to) external onlyOwner {
        if (address(token) == address(usdg) || address(token) == address(vault)) revert CannotSweep();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
    }

    // ================================================================= quoter

    /// @notice Post premiums for one stock and side, one per strike, inside the owner's bounds. A premium of zero
    ///         withdraws that quote (no buys at that strike). Each quote lives QUOTE_TTL from now.
    function setQuotes(address feed, uint8 side, uint16[] calldata strikesBps, uint16[] calldata premiumsBps) external {
        if (msg.sender != quoter) revert OnlyQuoter();
        if (strikesBps.length != premiumsBps.length) revert LengthMismatch();
        if (side > 1) revert BadSide();
        if (!stocks[feed].allowed) revert NotAllowed();
        for (uint256 i; i < strikesBps.length; i++) {
            uint16 strike = strikesBps[i];
            uint16 premium = premiumsBps[i];
            if (strike < MIN_STRIKE_BPS || strike > MAX_STRIKE_BPS) revert BadStrike();
            if (premium != 0 && (premium < minPremiumBps || premium > maxPremiumBps)) revert BadValue();
            quotes[feed][side][strike] = Quote({at: uint64(block.timestamp), premiumBps: premium});
            emit Quoted(feed, side, strike, premium);
        }
    }

    // ================================================================= sellers

    /// @notice Fund the pool with USDG; `receiver` gets bGAP shares. The USDG goes into the vault at once.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (depositsPaused) revert Paused();
        if (assets == 0) revert Nothing();
        shares = _toShares(assets, totalAssets());
        if (shares == 0) revert Nothing();
        usdg.safeTransferFrom(msg.sender, address(this), assets);
        usdg.forceApprove(address(vault), assets);
        vault.deposit(assets, address(this));
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, assets, shares);
    }

    /// @notice Burn bGAP shares for their USDG, out of the vault. Only while no cover is live: capital is locked from
    ///         the first buy of a closure until every cover of it has settled or been voided, so a loss that lands on
    ///         Monday falls on every seller alike.
    function withdraw(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert Nothing();
        if (totalReserved != 0) revert Locked();
        uint256 total = totalAssets();
        assets = _toAssets(shares, total);
        if (assets == 0) revert Nothing();
        uint256 free = _free(total);
        if (assets > free) revert NotFree(assets, free);
        _burn(msg.sender, shares);
        vault.withdraw(assets, receiver, address(this));
        emit Withdrawn(msg.sender, receiver, shares, assets);
    }

    // ================================================================= buyers

    /// @notice Buy cover on `feed`'s stock while the market is shut, against the gap between the feed's last print and
    ///         its first print after the reopen. Up (side 0) pays when the stock gaps up past the strike, down (side 1)
    ///         when it gaps down, in either case the move beyond the strike up to the cap, on `notional` USDG.
    function buy(address feed, uint8 side, uint96 notional, uint16 strikeBps, uint256 maxPremium)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (buysPaused) revert Paused();
        if (side > 1) revert BadSide();
        if (notional == 0) revert Nothing();
        (bool closed, uint256 reopenAt) = marketClosed();
        if (!closed) revert MarketOpen();
        if (reopenAt - block.timestamp < LAST_BUY) revert TooLate();
        Stock storage s = stocks[feed];
        if (!s.allowed) revert NotAllowed();
        uint16 cap = capBps;
        if (strikeBps < MIN_STRIKE_BPS || strikeBps > MAX_STRIKE_BPS || strikeBps >= cap) revert BadStrike();
        (uint16 premiumBps, bool fresh) = quoteOf(feed, side, strikeBps);
        if (!fresh) revert NoQuote();
        uint256 premium = uint256(notional) * premiumBps / BPS;
        if (premium == 0) revert Nothing();
        if (premium > maxPremium) revert TooMuch(premium, maxPremium);

        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
        if (answer <= 0 || updatedAt >= block.timestamp || block.timestamp - updatedAt > MAX_REF_AGE) revert BadFeed();

        uint256 reserve = uint256(notional) * (cap - strikeBps) / BPS;
        if (reserve == 0) revert Nothing();
        uint256 total = totalAssets();
        uint256 free = _free(total);
        if (reserve > free) revert NotEnoughCapital(reserve, free);
        uint256 allowed = uint256(s.maxExposureBps) * total / BPS;
        if (s.reserved + reserve > allowed) revert OverExposure(s.reserved + reserve, allowed);
        uint256 allowedAll = uint256(maxTotalExposureBps) * total / BPS;
        if (totalReserved + reserve > allowedAll) revert OverExposure(totalReserved + reserve, allowedAll);
        s.reserved += reserve;
        totalReserved += reserve;

        uint256 fee = premium * feeBps / BPS;
        usdg.safeTransferFrom(msg.sender, address(this), premium);
        if (fee != 0) usdg.safeTransfer(feeRecipient, fee);
        uint256 kept = premium - fee;
        if (kept != 0) {
            usdg.forceApprove(address(vault), kept);
            vault.deposit(kept, address(this));
        }

        id = nextId++;
        _covers[id] = Cover({
            buyer: msg.sender,
            feed: feed,
            side: side,
            strikeBps: strikeBps,
            capBps: cap,
            notional: notional,
            premium: uint96(kept),
            refPrice: uint256(answer),
            reopenAt: uint64(reopenAt),
            boughtAt: uint64(block.timestamp),
            settled: false
        });
        _coversOf[msg.sender].push(id);
        emit Bought(id, msg.sender, feed, side, notional, strikeBps, cap, premium, fee, uint256(answer), uint64(reopenAt));
    }

    // ================================================================= anyone

    /// @notice Settle a cover with the first feed round at or after its reopen: `roundId` printed at or after
    ///         `reopenAt`, the round before it printed before, and it landed within SETTLE_WINDOW of the reopen and
    ///         within MAX_MOVE_BPS of the reference. Pays the buyer out of the vault. Final.
    function settle(uint256 id, uint80 roundId) external nonReentrant returns (uint256 payout) {
        Cover storage c = _covers[id];
        if (c.buyer == address(0)) revert NoCover();
        if (c.settled) revert AlreadySettled();
        (int256 answer, uint256 updatedAt) = _firstRound(c, roundId);
        if (updatedAt > uint256(c.reopenAt) + SETTLE_WINDOW || _absMoveBps(c, answer) > MAX_MOVE_BPS) revert WrongRound();
        payout = payoutFor(c, answer);
        c.settled = true;
        _release(c);
        if (payout != 0) payout = _pay(c.buyer, payout);
        emit Settled(id, roundId, answer, payout);
    }

    /// @notice Void a cover that cannot settle: the premium the pool kept goes back to the buyer and the reserve is
    ///         released. Three cases, each proven here: the feed has not printed since the reopen and SETTLE_GRACE has
    ///         passed (`roundId` is ignored); or `roundId` is the first round after the reopen and it landed after
    ///         SETTLE_WINDOW; or it is that round and its answer is further than MAX_MOVE_BPS from the reference. A
    ///         cover that can be settled can never be voided.
    function void(uint256 id, uint80 roundId) external nonReentrant {
        Cover storage c = _covers[id];
        if (c.buyer == address(0)) revert NoCover();
        if (c.settled) revert AlreadySettled();
        (,,, uint256 latestAt,) = IPriceFeed(c.feed).latestRoundData();
        if (latestAt < c.reopenAt) {
            if (block.timestamp < uint256(c.reopenAt) + SETTLE_GRACE) revert TooSoon();
        } else {
            (int256 answer, uint256 updatedAt) = _firstRound(c, roundId);
            if (updatedAt <= uint256(c.reopenAt) + SETTLE_WINDOW && _absMoveBps(c, answer) <= MAX_MOVE_BPS) revert Settleable();
        }
        c.settled = true;
        _release(c);
        uint256 refund = c.premium;
        if (refund != 0) refund = _pay(c.buyer, refund);
        emit Voided(id, refund);
    }

    /// @notice Take USDG a settlement or void could not deliver to the caller's address.
    function claim(address to) external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert Nothing();
        owed[msg.sender] = 0;
        usdg.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    // ================================================================= views

    /// @notice The pool's capital: what its vault shares are worth in USDG.
    function totalAssets() public view returns (uint256) {
        return vault.convertToAssets(IERC20(address(vault)).balanceOf(address(this)));
    }

    /// @notice Capital no live cover reserves: what can be withdrawn, and what new covers can reserve.
    function freeAssets() public view returns (uint256) {
        return _free(totalAssets());
    }

    /// @notice What a cover of `notional` at `strikeBps` reserves at the current cap: its largest payout.
    function reserveFor(uint96 notional, uint16 strikeBps) public view returns (uint256) {
        if (strikeBps >= capBps) return 0;
        return uint256(notional) * (capBps - strikeBps) / BPS;
    }

    /// @notice The quoter's premium for a stock, side and strike, and whether it is still live.
    function quoteOf(address feed, uint8 side, uint16 strikeBps) public view returns (uint16 premiumBps, bool fresh) {
        Quote memory q = quotes[feed][side][strikeBps];
        premiumBps = q.premiumBps;
        fresh = premiumBps != 0 && block.timestamp - q.at <= QUOTE_TTL;
    }

    /// @notice The premium a buy would cost now and Borro's fee inside it, or zeros without a live quote.
    function premiumFor(address feed, uint8 side, uint96 notional, uint16 strikeBps)
        external
        view
        returns (uint256 premium, uint256 fee)
    {
        (uint16 premiumBps, bool fresh) = quoteOf(feed, side, strikeBps);
        if (!fresh) return (0, 0);
        premium = uint256(notional) * premiumBps / BPS;
        fee = premium * feeBps / BPS;
    }

    function coverOf(uint256 id) external view returns (Cover memory) {
        return _covers[id];
    }

    function coversOf(address buyer) external view returns (uint256[] memory) {
        return _coversOf[buyer];
    }

    /// @notice Whether the market is shut now, and when it next opens (now, if it is open).
    function marketClosed() public view returns (bool closed, uint256 reopenAt) {
        closed = !MarketHours.isOpen(block.timestamp);
        reopenAt = closed ? MarketHours.nextOpen(block.timestamp) : block.timestamp;
    }

    /// @notice What a cover pays at a settling print of `answer`: the move beyond the strike, up to the cap, on the
    ///         notional. Zero when the gap went the other way or stayed inside the strike.
    function payoutFor(Cover memory c, int256 answer) public pure returns (uint256) {
        int256 move = (answer - int256(c.refPrice)) * int256(BPS) / int256(c.refPrice);
        if (c.side == 1) move = -move;
        int256 beyond = move - int256(uint256(c.strikeBps));
        if (beyond <= 0) return 0;
        uint256 room = uint256(c.capBps - c.strikeBps);
        uint256 paid = uint256(beyond) > room ? room : uint256(beyond);
        return uint256(c.notional) * paid / BPS;
    }

    /// @notice bGAP shares for `assets` USDG at the pool's current share price.
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _toShares(assets, totalAssets());
    }

    /// @notice USDG for `shares` of bGAP at the pool's current share price.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _toAssets(shares, totalAssets());
    }

    // ================================================================= internals

    function _toShares(uint256 assets, uint256 total) internal view returns (uint256) {
        return assets * (totalSupply() + VIRTUAL_SHARES) / (total + 1);
    }

    function _toAssets(uint256 shares, uint256 total) internal view returns (uint256) {
        return shares * (total + 1) / (totalSupply() + VIRTUAL_SHARES);
    }

    function _free(uint256 total) internal view returns (uint256) {
        return total > totalReserved ? total - totalReserved : 0;
    }

    /// @dev The answer and time of `roundId`, checked to be the first round of the cover's feed at or after its reopen:
    ///      it printed at or after `reopenAt` and the round before it printed before. The proxy's round id is
    ///      phase << 64 | the aggregator's round; the round before is in the same phase only when the aggregator's
    ///      round is above 1, and a phase's first round has nothing before it to check.
    function _firstRound(Cover storage c, uint80 roundId) internal view returns (int256 answer, uint256 updatedAt) {
        IPriceFeed feed = IPriceFeed(c.feed);
        (, answer,, updatedAt,) = feed.getRoundData(roundId);
        if (answer <= 0 || updatedAt < c.reopenAt) revert WrongRound();
        if (uint64(roundId) > 1) {
            (,,, uint256 prevAt,) = feed.getRoundData(roundId - 1);
            if (prevAt >= c.reopenAt) revert WrongRound();
        }
    }

    /// @dev How far `answer` is from the cover's reference, either way, in basis points.
    function _absMoveBps(Cover storage c, int256 answer) internal view returns (uint256) {
        int256 move = (answer - int256(c.refPrice)) * int256(BPS) / int256(c.refPrice);
        return uint256(move < 0 ? -move : move);
    }

    /// @dev Pay `amount` USDG out of the vault to `to`, clamped to what the pool holds (only short if the vault itself
    ///      lost money; the reserve was in it when bought). An address USDG cannot pay (frozen, say) is credited in
    ///      `owed` instead, so a settlement never fails on the buyer's account. Returns what was paid or credited.
    function _pay(address to, uint256 amount) internal returns (uint256) {
        uint256 total = totalAssets();
        if (amount > total) amount = total;
        if (amount == 0) return 0;
        vault.withdraw(amount, address(this), address(this));
        (bool ok, bytes memory ret) = address(usdg).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) {
            owed[to] += amount;
            emit Owed(to, amount);
        }
        return amount;
    }

    /// @dev Give a cover's reserve back to free capital. Called once per cover, by its settlement or its void.
    function _release(Cover storage c) internal {
        uint256 reserve = uint256(c.notional) * (c.capBps - c.strikeBps) / BPS;
        stocks[c.feed].reserved -= reserve;
        totalReserved -= reserve;
    }
}
