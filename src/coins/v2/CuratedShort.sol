// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {IMorphoSupplyCollateralCallback, IMorphoRepayCallback} from "morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {CoinCollateral} from "../CoinCollateral.sol";
import {CoinAccount, IHeld} from "../CoinShort.sol";
import {CoinRouter} from "./CoinRouter.sol";
import {ICuratedListing, CuratedDesk, ICoinFeed} from "./VenueDeps.sol";

/// @title CuratedShort
/// @notice Shorts a curated coin in one transaction (docs/COIN-SHORTS.md, phase 2): CoinShort's design for coins the
///         Safe allowed on CuratedListing, wherever they trade. Open: the shorter's USDG goes in as collateral, the
///         coin is borrowed and sold through CoinRouter (its own pool and its pair's way to USDG), and the sale money
///         joins the collateral. Close: the coin is bought back with the collateral and repaid, and the rest goes
///         back. Each shorter's positions sit in a CoinAccount (the Pons coin shorts' account contract).
///         The collateral is cUSDG (Steakhouse USDG shares, gated: only this contract can post it to Morpho), so
///         every borrow of a listed coin goes through here and the short cap holds.
/// @dev An open or a grow needs both: the coin's feed lets shorts open (it has a price, a fresh pair price, and the
///      pool's spot is no more than MAX_ABOVE_BPS above the delayed price), and the coin's shorts stay under its
///      cap (zero under the market-cap or depth floor) and the position under OPEN_LTV (half the market's LLTV).
///      Never checked on the way out: closing, reducing, adding collateral and taking collateral out are not
///      stopped by a pause, the guard or the cap. Taking collateral out while debt remains keeps the position
///      under OPEN_LTV; a full close needs no price at all.
///      Every action pokes the coin's feed first. Holds nothing between transactions. The owner (the Hoard
///      Safe) can pause new opens, for one coin or all; it has no other power and no path to anyone's money.
contract CuratedShort is IMorphoSupplyCollateralCallback, IMorphoRepayCallback, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 public constant MAX_ABOVE_BPS = 1_000; // opens wait while the spot is more than 10% over the delayed price
    uint256 public constant OPEN_LTV = 0.1925e18; // half of 38.5%
    uint256 internal constant ORACLE_SCALE = 1e36;

    IMorpho public immutable morpho;
    IERC20 public immutable usdg;
    IHeld public immutable heldVault; // Steakhouse USDG
    CoinCollateral public immutable collateral; // cUSDG for curated coins
    ICuratedListing public immutable listing;
    CoinRouter public immutable router;

    mapping(address shorter => address) internal _accounts;
    mapping(address coin => bool) public paused;
    bool public pausedAll;

    // Set only for the length of one call.
    uint256 private _carry;
    uint256 private _carryHeld;
    uint256 private _budget;

    event AccountOpened(address indexed shorter, address account);
    event Opened(address indexed shorter, address indexed coin, uint256 deposit, uint256 borrowed, uint256 proceeds);
    event Closed(address indexed shorter, address indexed coin, uint256 returned, uint256 cost, uint256 paidOut);
    event DepositAdded(address indexed shorter, address indexed coin, uint256 usdg, uint256 held);
    event DepositTaken(address indexed shorter, address indexed coin, uint256 held, uint256 usdg);
    event Paused(address indexed coin, bool paused);
    event PausedAll(bool paused);

    error OnlyMorpho();
    error IsPaused();
    error Expired();
    error GuardClosed();
    error OverCap(uint256 wanted, uint256 room);
    error OverOpenLimit(uint256 owed, uint256 limit);
    error TooLittle(uint256 got, uint256 wanted);
    error TooMuch(uint256 cost, uint256 limit);
    error NothingOwed();
    error BadSetup();

    constructor(IMorpho morpho_, IERC20 usdg_, IHeld held_, ICuratedListing listing_, CoinRouter router_, address owner_)
        Ownable(owner_)
    {
        if (held_.asset() != address(usdg_) || listing_.curatedShort() != address(this)) revert BadSetup();
        if (address(router_.listing()) != address(listing_) || address(router_.usdg()) != address(usdg_)) revert BadSetup();
        morpho = morpho_;
        usdg = usdg_;
        heldVault = held_;
        listing = listing_;
        router = router_;
        collateral = new CoinCollateral(IERC20(address(held_)), address(morpho_));
        usdg_.forceApprove(address(held_), type(uint256).max);
        IERC20(address(held_)).forceApprove(address(collateral), type(uint256).max);
        IERC20(address(collateral)).forceApprove(address(morpho_), type(uint256).max);
    }

    // ------------------------------------------------------------------ owner

    /// @notice Stop new shorts on one coin, or allow them again. Nothing on the way out is ever stopped.
    function pause(address coin, bool paused_) external onlyOwner {
        paused[coin] = paused_;
        emit Paused(coin, paused_);
    }

    /// @notice Stop new shorts on every coin, or allow them again.
    function pauseAll(bool paused_) external onlyOwner {
        pausedAll = paused_;
        emit PausedAll(paused_);
    }

    // ------------------------------------------------------------------ opening

    /// @notice Deposit USDG, borrow `borrowAmount` of the coin and sell it. The sale money joins the deposit.
    /// @param minProceeds The least USDG the sale may bring. Less than this and nothing happens.
    function open(address coin, uint256 deposit, uint256 borrowAmount, uint256 minProceeds, uint256 deadline)
        external
        nonReentrant
        returns (uint256 proceeds)
    {
        if (block.timestamp > deadline) revert Expired();
        CuratedDesk memory d = listing.deskOf(coin);
        if (pausedAll || paused[coin]) revert IsPaused();
        ICoinFeed(d.feed).poke();
        _mayOpen(coin, d, borrowAmount);
        address acct = _account(msg.sender);

        uint256 held;
        if (deposit != 0) held = _hold(deposit, msg.sender);
        uint256 minHeld = heldVault.previewDeposit(minProceeds);

        // Morpho credits the collateral first and collects it last. In between, the coin is borrowed and sold,
        // and the sale money is put in the vault and wrapped, so the cUSDG is on hand when Morpho collects.
        morpho.supplyCollateral(d.market, held + minHeld, acct, abi.encode(acct, coin, borrowAmount, minProceeds, minHeld));
        proceeds = _carry;
        uint256 extra = _carryHeld - minHeld;
        _carry = 0;
        _carryHeld = 0;
        if (extra != 0) morpho.supplyCollateral(d.market, extra, acct, "");

        _withinOpenLimit(d.market, acct);
        emit Opened(msg.sender, coin, deposit, borrowAmount, proceeds);
    }

    function onMorphoSupplyCollateral(uint256, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        (address acct, address coin, uint256 borrowAmount, uint256 minProceeds, uint256 minHeld) =
            abi.decode(data, (address, address, uint256, uint256, uint256));
        CuratedDesk memory d = listing.deskOf(coin);
        morpho.borrow(d.market, borrowAmount, 0, acct, address(this));
        IERC20(coin).forceApprove(address(router), borrowAmount);
        uint256 got = router.sell(coin, borrowAmount, minProceeds, address(this));
        uint256 held = heldVault.deposit(got, address(this));
        if (held < minHeld) revert TooLittle(held, minHeld);
        collateral.wrap(held, address(this));
        _carry = got;
        _carryHeld = held;
    }

    /// @dev The conditions on a new or bigger short. Interest is brought up to date first, so the cap counts
    ///      what is owed now.
    function _mayOpen(address coin, CuratedDesk memory d, uint256 borrowAmount) internal {
        if (!ICoinFeed(d.feed).openOk(MAX_ABOVE_BPS)) revert GuardClosed();
        morpho.accrueInterest(d.market);
        uint256 owed = morpho.market(d.market.id()).totalBorrowAssets;
        (uint256 cap,) = listing.capOf(coin);
        uint256 room = cap > owed ? cap - owed : 0;
        if (borrowAmount > room) revert OverCap(borrowAmount, room);
    }

    /// @dev What the account owes in the market is at most OPEN_LTV of its collateral, at the market's own price.
    function _withinOpenLimit(MarketParams memory market, address acct) internal view {
        Id id = market.id();
        Position memory p = morpho.position(id, acct);
        if (p.borrowShares == 0) return;
        Market memory m = morpho.market(id);
        uint256 owed = uint256(p.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 limit = Math.mulDiv(Math.mulDiv(p.collateral, IOracle(market.oracle).price(), ORACLE_SCALE), OPEN_LTV, 1e18);
        if (owed > limit) revert OverOpenLimit(owed, limit);
    }

    // ------------------------------------------------------------------ collateral

    /// @notice Add USDG to the collateral behind the caller's short on a coin. Never paused.
    function addDeposit(address coin, uint256 amount) external nonReentrant returns (uint256 held) {
        CuratedDesk memory d = listing.deskOf(coin);
        _poke(d.feed);
        held = _hold(amount, msg.sender);
        morpho.supplyCollateral(d.market, held, _account(msg.sender), "");
        emit DepositAdded(msg.sender, coin, amount, held);
    }

    /// @notice Take collateral out as USDG. With debt left, the position must stay within OPEN_LTV. Never paused.
    /// @param held cUSDG to take out. Pass the maximum uint to take all of it (only with nothing owed).
    function takeDeposit(address coin, uint256 held) external nonReentrant returns (uint256 amount) {
        CuratedDesk memory d = listing.deskOf(coin);
        address acct = _accounts[msg.sender];
        if (acct == address(0)) revert NothingOwed();
        _poke(d.feed);
        if (held == type(uint256).max) held = morpho.position(d.market.id(), acct).collateral;
        morpho.withdrawCollateral(d.market, held, acct, address(this));
        _withinOpenLimit(d.market, acct);
        amount = _release(held, msg.sender);
        emit DepositTaken(msg.sender, coin, held, amount);
    }

    // ------------------------------------------------------------------ closing

    /// @notice Buy the coin back with the collateral and repay it. Never paused, never capped, never guarded.
    /// @param shares Borrow shares to repay. Pass the maximum uint to repay everything owed.
    /// @param heldOut Collateral (cUSDG) to take out. Pass the maximum uint to take all of it.
    /// @param topUp Extra USDG pulled from the caller toward the purchase. Whatever is not needed comes back.
    /// @param maxCost The most USDG the purchase may cost.
    /// @return paidOut USDG sent to the caller: the collateral taken out plus the top-up, less the purchase.
    function close(address coin, uint256 shares, uint256 heldOut, uint256 topUp, uint256 maxCost, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paidOut)
    {
        if (block.timestamp > deadline) revert Expired();
        CuratedDesk memory d = listing.deskOf(coin);
        address acct = _accounts[msg.sender];
        if (acct == address(0)) revert NothingOwed();
        _poke(d.feed);
        Position memory p = morpho.position(d.market.id(), acct);
        if (shares == type(uint256).max) shares = p.borrowShares;
        if (heldOut == type(uint256).max) heldOut = p.collateral;

        if (shares == 0) {
            // Nothing owed (perhaps someone else repaid it): just hand the collateral back.
            if (heldOut == 0) revert NothingOwed();
            morpho.withdrawCollateral(d.market, heldOut, acct, address(this));
            paidOut = _release(heldOut, msg.sender);
            emit Closed(msg.sender, coin, 0, 0, paidOut);
            return paidOut;
        }

        if (topUp != 0) usdg.safeTransferFrom(msg.sender, address(this), topUp);
        _budget = topUp;
        (uint256 returned,) = morpho.repay(d.market, 0, shares, acct, abi.encode(acct, coin, heldOut, maxCost));
        uint256 cost = _carry;
        _carry = 0;
        // A partial close that takes collateral out keeps the rest within the open limit; one that only repays
        // can only lower what is owed.
        if (heldOut != 0) _withinOpenLimit(d.market, acct);

        paidOut = _budget - cost;
        _budget = 0;
        if (paidOut != 0) usdg.safeTransfer(msg.sender, paidOut);
        emit Closed(msg.sender, coin, returned, cost, paidOut);
    }

    function onMorphoRepay(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        (address acct, address coin, uint256 heldOut, uint256 maxCost) = abi.decode(data, (address, address, uint256, uint256));
        CuratedDesk memory d = listing.deskOf(coin);
        // The debt is already written down, so the collateral behind it is free to leave (a full repay needs no
        // price for this).
        if (heldOut != 0) {
            morpho.withdrawCollateral(d.market, heldOut, acct, address(this));
            _budget += _release(heldOut, address(this));
        }
        uint256 limit = maxCost < _budget ? maxCost : _budget;
        usdg.forceApprove(address(router), limit);
        uint256 cost = router.buy(coin, assets, limit, address(this));
        _carry = cost;
        IERC20(coin).forceApprove(address(morpho), assets);
    }

    // ------------------------------------------------------------------ quotes

    /// @notice USDG that selling `amount` of the coin brings now. Moves nothing (call it, do not send it).
    function quoteSell(address coin, uint256 amount) external returns (uint256) {
        return router.quoteSell(coin, amount);
    }

    /// @notice USDG that buying `amount` of the coin costs now. Moves nothing (call it, do not send it).
    function quoteBuy(address coin, uint256 amount) external returns (uint256) {
        return router.quoteBuy(coin, amount);
    }

    // ------------------------------------------------------------------ accounts and money

    /// @notice The account that holds a shorter's positions. The address is fixed before the account exists.
    function accountOf(address shorter) public view returns (address acct) {
        acct = _accounts[shorter];
        if (acct == address(0)) {
            bytes32 init = keccak256(abi.encodePacked(type(CoinAccount).creationCode, abi.encode(shorter, morpho)));
            acct = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(shorter))), init)))));
        }
    }

    function _account(address shorter) internal returns (address acct) {
        acct = _accounts[shorter];
        if (acct == address(0)) {
            acct = address(new CoinAccount{salt: bytes32(uint256(uint160(shorter)))}(shorter, morpho));
            _accounts[shorter] = acct;
            emit AccountOpened(shorter, acct);
        }
    }

    /// @dev USDG from `from` into Steakhouse shares, wrapped as cUSDG here.
    function _hold(uint256 amount, address from) internal returns (uint256 held) {
        usdg.safeTransferFrom(from, address(this), amount);
        held = heldVault.deposit(amount, address(this));
        collateral.wrap(held, address(this));
    }

    /// @dev cUSDG here back into USDG, sent to `to`.
    function _release(uint256 held, address to) internal returns (uint256 amount) {
        collateral.unwrap(held, address(this));
        amount = heldVault.redeem(held, to, address(this));
    }

    /// @dev A check for the coin's feed. A feed that cannot check never stops a way out.
    function _poke(address feed) internal {
        try ICoinFeed(feed).poke() {} catch {}
    }
}
