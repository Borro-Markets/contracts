// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IMorpho, MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {IMorphoSupplyCollateralCallback, IMorphoRepayCallback} from "morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {BorroSwap, IUniswapV3Pool} from "./BorroSwap.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// The lending vault the held money sits in (Morpho Vault V2's ERC-4626 surface).
interface IHeldVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
}

interface IStockOracle {
    function QUOTE_FEED_1() external view returns (address);
    function QUOTE_FEED_2() external view returns (address);
    function QUOTE_VAULT() external view returns (address);
    function BASE_VAULT() external view returns (address);
}

interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256, uint80);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// Told about every close, so it can refund rent and score the weekly prize. See BorroRewards.
interface IBorroRewards {
    function onClose(address shorter, bytes32 id, uint256 notional, uint256 rentPaid, uint256 heldFor, int256 returnBps) external;
}

/// @title BorroAccount
/// @notice One per shorter. It owns that shorter's positions on Morpho.
/// @dev Only BorroShort can borrow against it, and BorroShort only ever does so when the owner calls it.
///      That is what lets a short's history be trusted: nobody can quietly repay and re-borrow behind the
///      record. The owner's way out never depends on BorroShort: anyone may repay an account's stock on
///      Morpho directly, and the owner can then take the held money out here.
contract BorroAccount {
    address public immutable owner;
    address public immutable short;
    IMorpho public immutable morpho;

    error OnlyOwner();

    constructor(address owner_, IMorpho morpho_) {
        owner = owner_;
        short = msg.sender;
        morpho = morpho_;
        morpho_.setAuthorization(msg.sender, true);
    }

    /// @notice Take held money (vault shares) out of a market, as far as the position allows.
    function withdrawHeld(MarketParams calldata market, uint256 held, address receiver) external {
        if (msg.sender != owner) revert OnlyOwner();
        morpho.withdrawCollateral(market, held, address(this), receiver);
    }

    /// @notice Send out a token that ended up here.
    function sweep(IERC20 token, address to) external {
        if (msg.sender != owner) revert OnlyOwner();
        SafeERC20.safeTransfer(token, to, token.balanceOf(address(this)));
    }
}

/// @title BorroShort
/// @notice Opens and closes a short in one transaction.
///         Open: the shorter's USDG deposit goes in as collateral, the stock is borrowed and sold, and the sale
///         money joins the deposit. Close: the stock is bought back with the collateral, returned, and what is
///         left of the collateral goes to the shorter.
///         The collateral is held as shares of a USDG lending vault, so the money held against a short earns
///         that vault's interest while the short is open. The shorter pays in USDG and is paid out in USDG.
/// @dev Each shorter's positions sit on Morpho under an account contract of their own (BorroAccount). This
///      contract holds nothing between transactions. It needs an allowance of the shorter's USDG, and it
///      only ever acts on the account of whoever is calling it.
///      The owner lists which markets can be shorted and the pools each stock trades through, and sets the
///      fee on opening a short within a hard cap. Changing where a listed stock trades waits two days in
///      public; pausing a stock only stops new shorts, never a close. The owner cannot reach a position:
///      every trade is bounded by the caller's own minimum or maximum, and the minimum is counted after the
///      fee. What the owner is trusted with: choosing markets with honest price oracles.
///      A stock trades through Uniswap v4 (a route of hookless pools) or through one Uniswap v3 pool (BorroSwap).
///      Each short opened here is remembered (how much was borrowed, at what feed price, when), so that a
///      close can tell the rewards contract the rent paid and the return made. That record is only ever used
///      to size a refund or a prize score; it never moves the position.
///      A basket is one `multicall` of several opens (or closes). Each call runs as if sent on its own, by the
///      same sender, one after the other; if any leg fails, the whole basket fails.
contract BorroShort is
    BorroSwap,
    IMorphoSupplyCollateralCallback,
    IMorphoRepayCallback,
    ReentrancyGuard,
    Multicall,
    Ownable2Step
{
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    uint256 public constant MAX_HOPS = 3;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_OPEN_FEE_BPS = 30; // the fee on opening a short never passes 0.30%
    uint256 public constant ROUTE_DELAY = 2 days; // changing where a listed stock trades waits this long

    IMorpho public immutable morpho;
    IUniswapV3Factory public immutable v3Factory;
    IHeldVault public immutable vault; // the collateral of every listed market is a share of this vault
    address public immutable irm; // every listed market must use the chain's adaptive curve IRM

    struct Desk {
        MarketParams market;
        PoolKey[] route; // Uniswap v4, from USDG to the stock. Empty if the stock trades on v3.
        address v3Pool; // Uniswap v3 pool of USDG and the stock. Zero if the stock trades on v4.
        bool paused; // no new shorts; closing always works
        address feed; // the stock's dollar price feed, read from the market's own oracle
        uint256 feedScale; // turns stock wei times feed price into USDG wei
    }

    /// What this contract opened for one shorter in one market, and has not yet seen closed.
    struct Tab {
        uint128 shares; // borrow shares on Morpho created by opens here
        uint128 principal; // stock borrowed for those shares
        uint128 entryValue; // what that stock was worth at the feed price when borrowed, in USDG wei
        uint128 soldFor; // what it was sold for after the fee, in USDG wei
        uint64 openedAt; // when, averaged by size over every open
    }

    struct Pending {
        PoolKey[] route;
        address v3Pool;
        uint256 readyAt;
    }

    mapping(bytes32 id => Desk) internal _desk;
    mapping(bytes32 id => Pending) internal _pending;
    mapping(address shorter => mapping(bytes32 id => Tab)) internal _tab;
    mapping(address shorter => address) internal _accounts;

    uint256 public constant REWARDS_GAS = 400_000; // the most a close spends telling the rewards contract
    uint256 public constant MAX_FEED_AGE = 4 days; // an older feed price is not used to score rewards

    uint256 public openFeeBps;
    address public feeRecipient;
    IBorroRewards public rewards; // zero: no refunds, no prize

    // Set only for the length of one call.
    uint256 private _carry;
    uint256 private _carryFee;
    uint256 private _carryHeld;
    uint256 private _carryBorrowShares;
    uint256 private _budget;

    event Listed(bytes32 indexed id, address indexed stock, address v3Pool);
    event RouteQueued(bytes32 indexed id, address v3Pool, uint256 readyAt);
    event Paused(bytes32 indexed id, bool paused);
    event FeeSet(uint256 openFeeBps, address feeRecipient);
    event RewardsSet(address rewards);
    event AccountOpened(address indexed shorter, address account);
    event Opened(address indexed shorter, bytes32 indexed id, uint256 deposit, uint256 borrowed, uint256 proceeds, uint256 fee);
    event Closed(address indexed shorter, bytes32 indexed id, uint256 returned, uint256 cost, uint256 paidOut);

    error NotListed();
    error BadRoute();
    error BadMarket();
    error OnlyMorpho();
    error FeeTooHigh();
    error AlreadyListed();
    error NotReady();
    error IsPaused();
    error Expired();
    error TooLittle(uint256 got, uint256 wanted);
    error NothingOwed();

    constructor(
        IMorpho morpho_,
        IPoolManager poolManager_,
        IUniswapV3Factory v3Factory_,
        IERC20 usdg_,
        IHeldVault vault_,
        address irm_,
        address owner_
    ) BorroSwap(poolManager_, usdg_) Ownable(owner_) {
        if (vault_.asset() != address(usdg_)) revert BadMarket();
        morpho = morpho_;
        v3Factory = v3Factory_;
        vault = vault_;
        irm = irm_;
        feeRecipient = owner_;
        usdg_.forceApprove(address(vault_), type(uint256).max);
        IERC20(address(vault_)).forceApprove(address(morpho_), type(uint256).max);
    }

    // ------------------------------------------------------------------ owner

    /// @notice List a market for the first time. Pass a v4 route or a v3 pool, not both.
    function list(MarketParams calldata market, PoolKey[] calldata route, address v3Pool) external onlyOwner {
        if (market.collateralToken != address(vault) || market.irm != irm) revert BadMarket();
        bytes32 id = Id.unwrap(market.id());
        if (morpho.market(Id.wrap(id)).lastUpdate == 0) revert BadMarket();
        Desk storage d = _desk[id];
        if (_listed(d)) revert AlreadyListed();
        _checkWhere(route, v3Pool, market.loanToken);
        d.market = market;
        // The feed that prices the stock inside the market's own oracle also scores rent and returns.
        // The oracle must price the stock by that one feed and nothing else.
        d.feed = IStockOracle(market.oracle).QUOTE_FEED_1();
        if (d.feed == address(0)) revert BadMarket();
        if (
            IStockOracle(market.oracle).QUOTE_FEED_2() != address(0) || IStockOracle(market.oracle).QUOTE_VAULT() != address(0)
                || IStockOracle(market.oracle).BASE_VAULT() != address(vault)
        ) revert BadMarket();
        d.feedScale = 10 ** (uint256(IERC20Decimals(market.loanToken).decimals()) + IPriceFeed(d.feed).decimals() - 6);
        _setWhere(d, route, v3Pool);
        IERC20(market.loanToken).forceApprove(address(morpho), type(uint256).max);
        emit Listed(id, market.loanToken, v3Pool);
    }

    /// @notice Ask to change where a listed stock trades. Takes effect after ROUTE_DELAY, by `applyRoute`.
    function queueRoute(bytes32 id, PoolKey[] calldata route, address v3Pool) external onlyOwner {
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        _checkWhere(route, v3Pool, d.market.loanToken);
        Pending storage q = _pending[id];
        delete q.route;
        for (uint256 i; i < route.length; i++) q.route.push(route[i]);
        q.v3Pool = v3Pool;
        q.readyAt = block.timestamp + ROUTE_DELAY;
        emit RouteQueued(id, v3Pool, q.readyAt);
    }

    /// @notice Put a queued route change into effect. Anyone can call it once the wait is over.
    function applyRoute(bytes32 id) external {
        Pending storage q = _pending[id];
        if (q.readyAt == 0) revert NotListed();
        if (block.timestamp < q.readyAt) revert NotReady();
        Desk storage d = _desk[id];
        _setWhere(d, q.route, q.v3Pool);
        emit Listed(id, d.market.loanToken, q.v3Pool);
        delete _pending[id];
    }

    /// @notice Stop new shorts on a stock, or allow them again. Closing is never stopped.
    function pause(bytes32 id, bool paused_) external onlyOwner {
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        d.paused = paused_;
        emit Paused(id, paused_);
    }

    function _checkWhere(PoolKey[] memory route, address v3Pool, address stock) internal view {
        if (v3Pool == address(0)) {
            _check(route, stock);
        } else {
            if (route.length != 0) revert BadRoute();
            _checkV3(v3Pool, stock);
        }
    }

    function _setWhere(Desk storage d, PoolKey[] memory route, address v3Pool) internal {
        d.v3Pool = v3Pool;
        delete d.route;
        for (uint256 i; i < route.length; i++) d.route.push(route[i]);
    }

    /// @notice Set the fee taken from the sale money when a short opens, and who receives it.
    function setFee(uint256 openFeeBps_, address feeRecipient_) external onlyOwner {
        if (openFeeBps_ > MAX_OPEN_FEE_BPS) revert FeeTooHigh();
        if (feeRecipient_ == address(0)) revert FeeTooHigh();
        openFeeBps = openFeeBps_;
        feeRecipient = feeRecipient_;
        emit FeeSet(openFeeBps_, feeRecipient_);
    }

    /// @notice Name the contract that refunds rent and scores the weekly prize. Zero switches both off.
    function setRewards(IBorroRewards rewards_) external onlyOwner {
        rewards = rewards_;
        emit RewardsSet(address(rewards_));
    }

    /// @notice Send out a token left here by mistake. Positions live on Morpho and are out of reach.
    function sweep(IERC20 token, address to) external onlyOwner {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    // ------------------------------------------------------------------ shorting

    /// @notice Deposit USDG, borrow `borrowAmount` of the stock and sell it. The sale money joins the deposit.
    /// @param minProceeds The least USDG the sale may bring after the fee. Less than this and nothing happens. It is also
    ///        the sale money Morpho counts as collateral when it checks the borrow, so a caller who passes
    ///        zero gets no more room than a plain borrow against the deposit.
    /// @param deadline The transaction is worthless after this time.
    function open(bytes32 id, uint256 deposit, uint256 borrowAmount, uint256 minProceeds, uint256 deadline)
        external
        nonReentrant
        returns (uint256 proceeds)
    {
        if (block.timestamp > deadline) revert Expired();
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        if (d.paused) revert IsPaused();
        address acct = _account(msg.sender);
        _sync(msg.sender, id, acct);
        uint256 held;
        if (deposit != 0) {
            usdg.safeTransferFrom(msg.sender, address(this), deposit);
            held = vault.deposit(deposit, address(this));
        }
        // The least the sale may bring, in vault shares, at the vault's price in this transaction.
        uint256 minHeld = vault.previewDeposit(minProceeds);

        // Morpho credits the collateral first and collects it last. In between, the stock is borrowed against
        // it and sold, and the sale money is put in the vault, so the shares are on hand when Morpho collects.
        morpho.supplyCollateral(d.market, held + minHeld, acct, abi.encode(acct, id, borrowAmount, minProceeds, minHeld));
        proceeds = _carry;
        uint256 fee = _carryFee;
        uint256 extra = _carryHeld - minHeld;
        uint256 borrowShares = _carryBorrowShares;
        _carry = 0;
        _carryFee = 0;
        _carryHeld = 0;
        _carryBorrowShares = 0;

        if (fee != 0) usdg.safeTransfer(feeRecipient, fee);
        if (extra != 0) morpho.supplyCollateral(d.market, extra, acct, "");
        _remember(msg.sender, id, d, borrowShares, borrowAmount, proceeds);
        emit Opened(msg.sender, id, deposit, borrowAmount, proceeds, fee);
    }

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        (address acct, bytes32 id, uint256 borrowAmount, uint256 minProceeds, uint256 minHeld) =
            abi.decode(data, (address, bytes32, uint256, uint256, uint256));
        Desk storage d = _desk[id];
        (, uint256 borrowShares) = morpho.borrow(d.market, borrowAmount, 0, acct, address(this));
        uint256 got = _trade(d, borrowAmount, false, false);
        uint256 fee = (got * openFeeBps) / BPS;
        uint256 net = got - fee;
        if (net < minProceeds) revert TooLittle(net, minProceeds);
        uint256 held = vault.deposit(net, address(this));
        if (held < minHeld) revert TooLittle(held, minHeld);
        _carry = net;
        _carryFee = fee;
        _carryHeld = held;
        _carryBorrowShares = borrowShares;
    }

    /// @notice Borrow the stock to the caller's wallet without selling it, against the money already held.
    ///         A borrow like this earns no rent refund and cannot win the prize.
    function borrow(bytes32 id, uint256 amount) external nonReentrant {
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        if (d.paused) revert IsPaused();
        address acct = _account(msg.sender);
        _sync(msg.sender, id, acct);
        morpho.borrow(d.market, amount, 0, acct, msg.sender);
    }

    /// @notice Add USDG to the money held against the caller's position.
    function addDeposit(bytes32 id, uint256 amount) external nonReentrant returns (uint256 held) {
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        held = vault.deposit(amount, address(this));
        morpho.supplyCollateral(d.market, held, _account(msg.sender), "");
    }

    /// @notice Take held money out as USDG, as far as the caller's position allows.
    /// @param held Vault shares to take out. Pass the maximum uint to take all of it.
    function takeDeposit(bytes32 id, uint256 held) external nonReentrant returns (uint256 amount) {
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        address acct = _accounts[msg.sender];
        if (acct == address(0)) revert NothingOwed();
        if (held == type(uint256).max) held = morpho.position(Id.wrap(id), acct).collateral;
        morpho.withdrawCollateral(d.market, held, acct, address(this));
        amount = vault.redeem(held, msg.sender, address(this));
    }

    /// @notice Buy the stock back with the collateral and return it.
    /// @param shares Borrow shares to repay. Pass the maximum uint to repay everything owed.
    /// @param heldOut Held money to take out, in vault shares. Pass the maximum uint to take all of it.
    /// @param topUp Extra USDG pulled from the caller to help pay for the stock, for a short that has lost
    ///        more than the held money taken out covers. Whatever is not needed comes back.
    /// @param maxCost The most USDG the purchase may cost. More than this and nothing happens.
    /// @param deadline The transaction is worthless after this time.
    /// @return paidOut USDG sent to the caller: the held money taken out plus the top-up, less the cost of
    ///         the stock.
    function close(bytes32 id, uint256 shares, uint256 heldOut, uint256 topUp, uint256 maxCost, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paidOut)
    {
        if (block.timestamp > deadline) revert Expired();
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        address acct = _accounts[msg.sender];
        if (acct == address(0)) revert NothingOwed();
        _sync(msg.sender, id, acct);
        Position memory p = morpho.position(Id.wrap(id), acct);
        if (shares == type(uint256).max) shares = p.borrowShares;
        if (heldOut == type(uint256).max) heldOut = p.collateral;

        if (shares == 0) {
            // Nothing owed (perhaps someone else repaid it): just hand the held money back.
            if (heldOut == 0) revert NothingOwed();
            morpho.withdrawCollateral(d.market, heldOut, acct, address(this));
            paidOut = vault.redeem(heldOut, msg.sender, address(this));
            emit Closed(msg.sender, id, 0, 0, paidOut);
            return paidOut;
        }

        if (topUp != 0) usdg.safeTransferFrom(msg.sender, address(this), topUp);
        _budget = topUp;
        (uint256 returned,) = morpho.repay(d.market, 0, shares, acct, abi.encode(acct, id, heldOut, maxCost));
        uint256 cost = _carry;
        _carry = 0;

        // Only the money that came in for this close goes out with it. Anything else here is not the caller's.
        paidOut = _budget - cost;
        _budget = 0;
        if (paidOut != 0) usdg.safeTransfer(msg.sender, paidOut);
        emit Closed(msg.sender, id, returned, cost, paidOut);
        _settle(msg.sender, id, d, shares, returned, cost);
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        (address acct, bytes32 id, uint256 heldOut, uint256 maxCost) = abi.decode(data, (address, bytes32, uint256, uint256));
        Desk storage d = _desk[id];
        // The debt is already written down, so the money held behind it is free to leave.
        if (heldOut != 0) {
            morpho.withdrawCollateral(d.market, heldOut, acct, address(this));
            _budget += vault.redeem(heldOut, address(this), address(this));
        }
        uint256 cost = _trade(d, assets, true, false);
        if (cost > maxCost) revert TooMuch(cost, maxCost);
        if (cost > _budget) revert TooMuch(cost, _budget);
        _carry = cost;
    }

    // ------------------------------------------------------------------ accounts

    /// @notice The account that holds a shorter's positions. The address is fixed before the account exists.
    function accountOf(address shorter) public view returns (address acct) {
        acct = _accounts[shorter];
        if (acct == address(0)) {
            bytes32 init = keccak256(abi.encodePacked(type(BorroAccount).creationCode, abi.encode(shorter, morpho)));
            acct = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(shorter), init)))));
        }
    }

    function _salt(address shorter) private pure returns (bytes32) {
        return bytes32(uint256(uint160(shorter)));
    }

    function _account(address shorter) internal returns (address acct) {
        acct = _accounts[shorter];
        if (acct == address(0)) {
            acct = address(new BorroAccount{salt: _salt(shorter)}(shorter, morpho));
            _accounts[shorter] = acct;
            emit AccountOpened(shorter, acct);
        }
    }

    // ------------------------------------------------------------------ the record behind rewards

    /// @dev The stock's dollar price by its feed, or zero if the feed has no usable price.
    function _price(Desk storage d) internal view returns (uint256) {
        (, int256 price,,,) = IPriceFeed(d.feed).latestRoundData();
        return price <= 0 ? 0 : uint256(price);
    }

    function _u128(uint256 x) private pure returns (uint128) {
        require(x <= type(uint128).max);
        return uint128(x);
    }

    /// @dev Borrowing against an account only ever happens through this contract, so the borrow shares on
    ///      Morpho can only have fallen since the record was last touched (a repayment made straight to
    ///      Morpho, or a liquidation). Whatever fell away is struck from the record here, before anything
    ///      is borrowed or repaid. That keeps the record to stock that has been owed the whole time.
    function _sync(address who, bytes32 id, address acct) internal {
        Tab storage t = _tab[who][id];
        uint256 tracked = t.shares;
        if (tracked == 0) return;
        uint256 real = morpho.position(Id.wrap(id), acct).borrowShares;
        if (real >= tracked) return;
        if (real == 0) {
            delete _tab[who][id];
            return;
        }
        t.principal = uint128((uint256(t.principal) * real) / tracked);
        t.entryValue = uint128((uint256(t.entryValue) * real) / tracked);
        t.soldFor = uint128((uint256(t.soldFor) * real) / tracked);
        t.shares = uint128(real);
    }

    function _remember(address who, bytes32 id, Desk storage d, uint256 borrowShares, uint256 borrowed, uint256 soldFor) internal {
        Tab storage t = _tab[who][id];
        uint256 before = t.principal;
        // The opening time is averaged by size, so adding to a short does not reset the clock on the old part.
        t.openedAt = uint64((uint256(t.openedAt) * before + block.timestamp * borrowed) / (before + borrowed));
        t.shares = _u128(uint256(t.shares) + borrowShares);
        t.principal = _u128(before + borrowed);
        t.entryValue = _u128(uint256(t.entryValue) + (borrowed * _price(d)) / d.feedScale);
        t.soldFor = _u128(uint256(t.soldFor) + soldFor);
    }

    /// @dev Works out, for the part of a close that repays what was opened here, the rent paid and the
    ///      return made, and tells the rewards contract. `close` has already brought the record in line
    ///      with Morpho. Stock borrowed to the wallet through `borrow` is never in the record.
    function _settle(address who, bytes32 id, Desk storage d, uint256 shares, uint256 returned, uint256 cost) internal {
        Tab storage t = _tab[who][id];
        uint256 tracked = t.shares;
        if (tracked == 0) return;
        uint256 part = shares < tracked ? shares : tracked;
        uint256 principal = (uint256(t.principal) * part) / tracked;
        uint256 entry = (uint256(t.entryValue) * part) / tracked;
        uint256 sold = (uint256(t.soldFor) * part) / tracked;
        uint256 heldFor = block.timestamp - t.openedAt;

        if (part == tracked) {
            delete _tab[who][id];
        } else {
            t.shares = uint128(tracked - part);
            t.principal = uint128(uint256(t.principal) - principal);
            t.entryValue = uint128(uint256(t.entryValue) - entry);
            t.soldFor = uint128(uint256(t.soldFor) - sold);
        }

        IBorroRewards r = rewards;
        if (address(r) == address(0) || entry == 0 || sold == 0) return;
        // A feed that fails, or whose price is missing or old, scores nothing. It never stops a close.
        uint256 price;
        try IPriceFeed(d.feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer > 0 && block.timestamp <= updatedAt + MAX_FEED_AGE) price = uint256(answer);
        } catch {}
        if (price == 0) return;

        uint256 stock = (returned * part) / shares; // what was returned for that part
        // Rent is the stock owed beyond what was borrowed, valued at the feed price.
        uint256 rentPaid = stock > principal ? ((stock - principal) * price) / d.feedScale : 0;
        // The return is the smaller of two measures, so neither a stale feed nor a pushed pool can fake it:
        // the fall in the feed price, and what the trade itself made (sold for, less bought back for).
        int256 byFeed = ((int256(entry) - int256((principal * price) / d.feedScale)) * int256(BPS)) / int256(entry);
        int256 byTrade = ((int256(sold) - int256((cost * stock) / returned)) * int256(BPS)) / int256(sold);
        int256 returnBps = byFeed < byTrade ? byFeed : byTrade;

        // A close never fails because of rewards, and never spends more than a set amount of gas on them.
        try r.onClose{gas: REWARDS_GAS}(who, id, entry, rentPaid, heldFor, returnBps) {} catch {}
    }

    // ------------------------------------------------------------------ views

    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed)
    {
        Desk storage d = _desk[id];
        return (d.market, d.route, d.v3Pool, d.paused, d.feed);
    }

    function tabOf(address shorter, bytes32 id)
        external
        view
        returns (uint256 shares, uint256 principal, uint256 entryValue, uint256 soldFor, uint256 openedAt)
    {
        Tab storage t = _tab[shorter][id];
        return (t.shares, t.principal, t.entryValue, t.soldFor, t.openedAt);
    }

    function pendingOf(bytes32 id) external view returns (PoolKey[] memory route, address v3Pool, uint256 readyAt) {
        Pending storage q = _pending[id];
        return (q.route, q.v3Pool, q.readyAt);
    }

    function _listed(Desk storage d) internal view returns (bool) {
        return d.route.length != 0 || d.v3Pool != address(0);
    }

    /// @notice USDG that selling `amount` of the stock brings, before the fee. Always reverts with QuoteResult.
    function quoteSell(bytes32 id, uint256 amount) external {
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        _trade(d, amount, false, true);
    }

    /// @notice USDG that buying `amount` of the stock costs. Always reverts with QuoteResult.
    function quoteBuy(bytes32 id, uint256 amount) external {
        Desk storage d = _desk[id];
        if (!_listed(d)) revert NotListed();
        _trade(d, amount, true, true);
    }

    // ------------------------------------------------------------------ swaps

    /// @dev buying = false: sells exactly `amount` of the stock, returns USDG received and held here.
    ///      buying = true:  buys exactly `amount` of the stock with USDG held here, returns the USDG cost.
    ///      quoting = true: reverts with QuoteResult instead of trading.
    ///      The trading itself is BorroSwap's; a close pays for the purchase from the collateral just taken out.
    function _trade(Desk storage d, uint256 amount, bool buying, bool quoting) internal returns (uint256) {
        return _swap(d.route, d.v3Pool, d.market.loanToken, amount, buying, quoting);
    }

    /// @dev A v3 pool must come from the chain's Uniswap v3 factory and hold USDG and the stock.
    function _checkV3(address pool, address stock) internal view {
        if (stock == address(0) || stock == address(usdg)) revert BadRoute();
        address t0 = IUniswapV3Pool(pool).token0();
        address t1 = IUniswapV3Pool(pool).token1();
        if (!((t0 == stock && t1 == address(usdg)) || (t0 == address(usdg) && t1 == stock))) revert BadRoute();
        if (v3Factory.getPool(t0, t1, IUniswapV3Pool(pool).fee()) != pool) revert BadRoute();
    }

    /// @dev A route is one to three hookless pools, no native ETH, starting at USDG and ending at the stock.
    function _check(PoolKey[] memory route, address stock) internal view {
        if (route.length == 0 || route.length > MAX_HOPS) revert BadRoute();
        if (stock == address(0) || stock == address(usdg)) revert BadRoute();
        address at = address(usdg);
        for (uint256 i; i < route.length; i++) {
            if (address(route[i].hooks) != address(0)) revert BadRoute();
            address c0 = Currency.unwrap(route[i].currency0);
            address c1 = Currency.unwrap(route[i].currency1);
            if (c0 == address(0)) revert BadRoute();
            if (at == c0) at = c1; else if (at == c1) at = c0; else revert BadRoute();
        }
        if (at != stock) revert BadRoute();
    }
}
