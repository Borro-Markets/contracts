// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams, Id, Authorization, Signature} from "morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "morpho-blue/interfaces/IMorphoCallbacks.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {BorroSwap} from "./BorroSwap.sol";

/// BorroShort's desks: each short market, and the route its stock trades through.
interface ILeverDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed);
}

/// BorroRouter's list of Borro's own USDG markets (USDG lent against a stock vault's shares).
interface ILeverMarkets {
    function listed(bytes32 id) external view returns (bool);
}

/// A Morpho Vault V2 seen as an ERC-4626 vault: the stock vaults (bNVDA etc.).
interface ILeverVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
}

/// @title LeverRouter
/// @notice A leveraged long on a stock in one transaction, and its close in one transaction. 2026-10-06:
///         "one clicl leveraged longs".
///         Open: the caller's USDG margin plus a free Morpho flash loan of the debt buy the stock through the route
///         Borro's short desk uses; the stock is lent to its Borro vault (so it earns rent from shorters) and the vault
///         shares are posted as the caller's collateral on the stock's Borro USDG market; the debt is borrowed there in
///         the caller's name and repays the flash loan; any USDG not spent goes straight back.
///         Close (all or a share): a flash loan repays that share of the caller's debt, that share of the collateral
///         comes out, is redeemed for the stock and sold, the flash loan is repaid, and the rest goes to the caller.
/// @dev Borrowing and taking collateral out in someone's name needs their Morpho authorization of this contract (one
///      signature, which open can submit itself). Every action is for msg.sender and nobody else: no function takes
///      an account to act for, the flash loan callback runs only inside a call this contract started, so an
///      authorization never lets anyone else move a caller's position.
///      Holds nothing between transactions. The owner (the Hoard Safe) can only stop new opens; closes always work,
///      and there is no function that sends out anyone's tokens. Opens are held to MAX_OPEN_OF_LLTV_BPS of the
///      market's LLTV, so a fresh position is liquidated only after the stock falls about a quarter.
///      A close needs the stock vault to have the stock on hand to redeem. If shorters have it all, the close says so
///      (CannotRedeem) and the caller repays on Morpho directly and takes the vault shares, which keep earning.
contract LeverRouter is BorroSwap, IMorphoFlashLoanCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    /// A fresh open may use at most this share of the market's LLTV: three quarters, so the stock has to fall about
    /// 25% from the open before the position can be liquidated (less what interest adds over time).
    uint256 public constant MAX_OPEN_OF_LLTV_BPS = 7_500;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ORACLE_SCALE = 1e36;

    IMorpho public immutable morpho;
    ILeverDesks public immutable desks;
    ILeverMarkets public immutable markets;

    bool public opensPaused;

    /// USDG each caller has put into its leveraged long on each market through here, less the share taken out by
    /// closes: the cost basis the site shows P/L against. Bookkeeping only; it holds and moves nothing.
    mapping(address who => mapping(bytes32 market => uint256)) public basisOf;

    // Set only inside open or close, for the flash loan callback: who, and what.
    address private transient _who;
    uint8 private transient _op; // 1 open, 2 close

    struct Open {
        bytes32 desk; // the BorroShort desk of the stock: the route its purchase takes
        MarketParams market; // the stock's Borro USDG market (USDG lent against the stock vault's shares)
        uint256 margin; // USDG taken from the caller
        uint256 stockAmount; // stock wei to buy
        uint256 maxCost; // the most the purchase may cost, at most margin + debt
        uint256 debt; // USDG borrowed in the caller's name
        uint256 minShares; // the fewest vault shares the deposit may bring
        uint256 deadline;
    }

    struct Close {
        bytes32 desk;
        MarketParams market;
        uint256 shareBps; // the share of the position to close, 1 to 10,000 (all)
        uint256 minOut; // the least USDG the caller must get back
        uint256 deadline;
    }

    event Opened(
        address indexed who, bytes32 indexed market, uint256 stockAmount, uint256 cost, uint256 shares, uint256 debt, uint256 margin
    );
    event Closed(
        address indexed who, bytes32 indexed market, uint256 shareBps, uint256 shares, uint256 stockSold, uint256 repaid, uint256 returned
    );
    event OpensPaused(bool paused);

    error Expired();
    error Paused();
    error Nothing();
    error BadMarket();
    error NotAuthorized();
    error BadSignature();
    error OnlyMorpho();
    error NotInFlight();
    error TooFewShares(uint256 got, uint256 wanted);
    error OverLimit(uint256 debt, uint256 allowed);
    error CannotRedeem();
    error TooLittleBack(uint256 got, uint256 wanted);
    error Underwater(uint256 sold, uint256 owed);

    constructor(
        IMorpho morpho_,
        IPoolManager poolManager_,
        IERC20 usdg_,
        ILeverDesks desks_,
        ILeverMarkets markets_,
        address owner_
    ) BorroSwap(poolManager_, usdg_) Ownable(owner_) {
        morpho = morpho_;
        desks = desks_;
        markets = markets_;
    }

    // ================================================================= open

    /// @notice Open (or add to) a leveraged long. The caller must already have authorized this contract on Morpho.
    function open(Open calldata o) external nonReentrant returns (uint256 cost, uint256 shares) {
        if (!morpho.isAuthorized(msg.sender, address(this))) revert NotAuthorized();
        return _open(o);
    }

    /// @notice Open with the caller's Morpho authorization of this contract submitted in the same transaction.
    ///         If someone submitted the same signature first, the authorization already stands and open goes on.
    function openWithSig(Open calldata o, Authorization calldata auth, Signature calldata sig)
        external
        nonReentrant
        returns (uint256 cost, uint256 shares)
    {
        if (auth.authorizer != msg.sender || auth.authorized != address(this) || !auth.isAuthorized) revert BadSignature();
        if (!morpho.isAuthorized(msg.sender, address(this))) {
            try morpho.setAuthorizationWithSig(auth, sig) {} catch {}
            if (!morpho.isAuthorized(msg.sender, address(this))) revert NotAuthorized();
        }
        return _open(o);
    }

    function _open(Open calldata o) internal returns (uint256 cost, uint256 shares) {
        if (opensPaused) revert Paused();
        if (block.timestamp > o.deadline) revert Expired();
        if (o.margin == 0 || o.stockAmount == 0 || o.debt == 0) revert Nothing();
        (address stock, address vault) = _check(o.desk, o.market);

        usdg.safeTransferFrom(msg.sender, address(this), o.margin);
        _who = msg.sender;
        _op = 1;
        morpho.flashLoan(address(usdg), o.debt, abi.encode(o, stock, vault));
        (cost, shares) = (_lastCost, _lastShares);
        _who = address(0);
        _op = 0;
        // margin + debt came in, the purchase cost `cost`, the flash loan took `debt` back.
        uint256 back = o.margin + o.debt - cost;
        if (back != 0) usdg.safeTransfer(msg.sender, back);
        basisOf[msg.sender][Id.unwrap(o.market.id())] += o.margin - back;
        emit Opened(msg.sender, Id.unwrap(o.market.id()), o.stockAmount, cost, shares, o.debt, o.margin);
    }

    // Results of the callback, read back by open and close.
    uint256 private transient _lastCost;
    uint256 private transient _lastShares;
    uint256 private transient _lastRepaid;

    function _openInFlight(uint256 debt, bytes calldata data) internal {
        (Open memory o, address stock, address vault) = abi.decode(data, (Open, address, address));
        address who = _who;
        (, PoolKey[] memory route, address v3Pool,,) = desks.deskOf(o.desk);

        uint256 cost = _swap(route, v3Pool, stock, o.stockAmount, true, false);
        if (cost > o.maxCost || cost > o.margin + debt) revert TooMuch(cost, o.maxCost);

        IERC20(stock).forceApprove(vault, o.stockAmount);
        uint256 shares = ILeverVault(vault).deposit(o.stockAmount, address(this));
        if (shares < o.minShares) revert TooFewShares(shares, o.minShares);
        IERC20(vault).forceApprove(address(morpho), shares);
        morpho.supplyCollateral(o.market, shares, who, "");
        morpho.borrow(o.market, debt, 0, who, address(this));

        // The whole position after this open, held to MAX_OPEN_OF_LLTV_BPS of the LLTV at the market's own price.
        uint256 owed = morpho.expectedBorrowAssets(o.market, who);
        uint256 coll = morpho.position(o.market.id(), who).collateral;
        uint256 worth = coll * IOracle(o.market.oracle).price() / ORACLE_SCALE;
        uint256 allowed = worth * o.market.lltv / 1e18 * MAX_OPEN_OF_LLTV_BPS / BPS;
        if (owed > allowed) revert OverLimit(owed, allowed);

        usdg.forceApprove(address(morpho), debt); // the flash loan's repayment
        (_lastCost, _lastShares) = (cost, shares);
    }

    // ================================================================= close

    /// @notice Close `c.shareBps` of the caller's leveraged long (10,000 closes it all). Never paused.
    function close(Close calldata c) external nonReentrant returns (uint256 returned) {
        if (block.timestamp > c.deadline) revert Expired();
        if (c.shareBps == 0 || c.shareBps > BPS) revert Nothing();
        (address stock, address vault) = _check(c.desk, c.market);
        if (!morpho.isAuthorized(msg.sender, address(this))) revert NotAuthorized();

        Id id = c.market.id();
        uint256 borrowShares = morpho.position(id, msg.sender).borrowShares;
        uint256 coll = morpho.position(id, msg.sender).collateral;
        if (coll == 0) revert Nothing();
        uint256 repayShares = c.shareBps == BPS ? borrowShares : borrowShares * c.shareBps / BPS;
        uint256 out = c.shareBps == BPS ? coll : coll * c.shareBps / BPS;
        if (out == 0) revert Nothing();
        uint256 repayAssets;
        if (repayShares != 0) {
            (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(c.market);
            repayAssets = repayShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
        }

        _who = msg.sender;
        _op = 2;
        bytes memory data = abi.encode(c, stock, vault, repayShares, out);
        if (repayAssets != 0) {
            morpho.flashLoan(address(usdg), repayAssets, data);
        } else {
            _closeInFlight(0, data);
        }
        uint256 sold = _lastCost; // USDG the stock sold for
        uint256 stockSold = _lastShares;
        uint256 repaid = _lastRepaid;
        _who = address(0);
        _op = 0;
        // The flash loan (repayAssets) came in and went back; Morpho took `repaid` of it for the debt; the sale
        // brought `sold`. What is left is the caller's.
        returned = sold - repaid;
        if (returned < c.minOut) revert TooLittleBack(returned, c.minOut);
        if (returned != 0) usdg.safeTransfer(msg.sender, returned);
        uint256 basis = basisOf[msg.sender][Id.unwrap(id)];
        basisOf[msg.sender][Id.unwrap(id)] = c.shareBps == BPS ? 0 : basis - basis * c.shareBps / BPS;
        emit Closed(msg.sender, Id.unwrap(id), c.shareBps, out, stockSold, repaid, returned);
    }

    function _closeInFlight(uint256 flash, bytes memory data) internal {
        (Close memory c, address stock, address vault, uint256 repayShares, uint256 out) =
            abi.decode(data, (Close, address, address, uint256, uint256));
        address who = _who;
        uint256 repaid;
        if (repayShares != 0) {
            usdg.forceApprove(address(morpho), flash);
            // Morpho takes what the shares are worth now: the same rounding up as the flash loan's size.
            (repaid,) = morpho.repay(c.market, 0, repayShares, who, "");
        }
        morpho.withdrawCollateral(c.market, out, who, address(this));
        uint256 stockOut;
        try ILeverVault(vault).redeem(out, address(this), address(this)) returns (uint256 a) {
            stockOut = a;
        } catch {
            revert CannotRedeem();
        }
        (, PoolKey[] memory route, address v3Pool,,) = desks.deskOf(c.desk);
        uint256 sold = _swap(route, v3Pool, stock, stockOut, false, false);
        // Here now: what is left of the flash loan after the repayment, plus the sale. The flash loan goes back whole.
        if (sold < repaid) revert Underwater(sold, repaid);
        if (flash != 0) usdg.forceApprove(address(morpho), flash);
        (_lastCost, _lastShares, _lastRepaid) = (sold, stockOut, repaid);
    }

    // ================================================================= Morpho's flash loan

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        uint8 op = _op;
        if (op == 1) _openInFlight(assets, data);
        else if (op == 2) _closeInFlight(assets, data);
        else revert NotInFlight();
    }

    // ================================================================= owner

    /// @notice Stop or allow new opens. Closes are never stopped.
    function setOpensPaused(bool paused) external onlyOwner {
        opensPaused = paused;
        emit OpensPaused(paused);
    }

    // ================================================================= checks

    /// @dev The desk's stock, and the USDG market must be one of Borro's, lending against that stock's vault.
    function _check(bytes32 desk, MarketParams calldata market) internal view returns (address stock, address vault) {
        (MarketParams memory shortMarket, PoolKey[] memory route, address v3Pool,,) = desks.deskOf(desk);
        stock = shortMarket.loanToken;
        if (stock == address(0) || (route.length == 0 && v3Pool == address(0))) revert BadMarket();
        if (market.loanToken != address(usdg) || !markets.listed(Id.unwrap(market.id()))) revert BadMarket();
        vault = market.collateralToken;
        if (ILeverVault(vault).asset() != stock) revert BadMarket();
    }
}
