// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2Factory} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {IMorphoChainlinkOracleV2Factory} from "morpho-oracles/morpho-chainlink/interfaces/IMorphoChainlinkOracleV2Factory.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "morpho-oracles/morpho-chainlink/interfaces/IERC4626.sol";
import {BorroLib} from "../../script/BorroLib.sol";
import {CoinFeed} from "./CoinFeed.sol";
import {GatedCoin} from "./GatedCoin.sol";
import {CoinAccount} from "./CoinShort.sol";
import {IPonsHook, ICoinListing, CoinDesk} from "./CoinDeps.sol";

interface ISymbol {
    function symbol() external view returns (string memory);
}

/// @title CoinLoans
/// @notice Borrow USDG against a listed Pons coin (docs/COIN-SHORTS.md, "Borrowing against a coin"). A coin listed
///         for shorts on CoinListing can have its loans opened here, by anyone: a second Morpho market (the coin as
///         collateral, held as GatedCoin; USDG as the loan; the same delayed price) and its own USDG lending vault,
///         so the dollars lent against a coin come only from lenders who chose that coin, and carry only that coin.
///         Nothing from the Borro USDG vault or the stock desks is ever lent here.
/// @dev A borrow (or a bigger one) needs: the coin's feed has a price and the pool's spot price is no more than
///      MAX_BELOW_BPS under it (the delayed price lagging a fall would overvalue the coin); Pons's hook fee at most
///      MAX_HOOK_FEE_BPS; the coin's loans stay under its cap; and the position under OPEN_LTV (half the market's
///      LLTV) at the lower of the spot and the delayed price. The cap is CAP_DEPTH_BPS of the locked pool's coin side
///      in dollars at the delayed price, and at most CAP_USD: what a liquidation can sell into the coin's locked
///      Pons liquidity (the docs show the working); zero while that pool is under 2 ETH at the delayed price.
///      Never checked on the way out: repaying, adding collateral and taking collateral out are not stopped by a
///      pause, the guard or the cap. Taking collateral out while debt remains keeps the position under OPEN_LTV; a
///      full repay and withdrawal needs no price at all. Each borrower's position sits under a CoinAccount, whose
///      own way out (once the debt is repaid on Morpho, which anyone can do) needs nothing from here.
///      The owner (the Hoard Safe) can pause new borrows for one coin or all, and pause opening loans on new coins.
///      It has no other power and no path to anyone's money. Holds nothing between transactions.
contract CoinLoans is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 public constant LLTV = 0.385e18;
    uint256 public constant OPEN_LTV = 0.1925e18; // half of 38.5%
    uint256 public constant CAP_DEPTH_BPS = 120; // of the locked pool's coin side in dollars, at the delayed price
    uint256 public constant CAP_USD = 5_000e6; // USDG
    uint256 public constant MAX_BELOW_BPS = 1_000; // borrows wait while the spot is more than 10% under the delayed price
    uint256 public constant MAX_HOOK_FEE_BPS = 200;
    uint256 public constant VAULT_CAP = 10_000e6; // the most a coin's USDG vault lends into its market
    uint256 public constant SEED = 1e6; // the dead deposit in a coin's USDG vault: 1 USDG
    uint256 public constant VAULT_TIMELOCK = 3 days;
    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IMorpho public immutable morpho;
    ICoinListing public immutable listing;
    IERC20 public immutable usdg;
    address public immutable safe;
    address public immutable ponsHook;

    struct LoanDesk {
        MarketParams market; // loan USDG, collateral the coin's GatedCoin, the coin's loan oracle, the adaptive IRM, 38.5%
        address wrapper; // the coin's GatedCoin
        address vault; // the coin's USDG lending vault
        address feed; // the coin's CoinFeed (shared with its shorts market)
        uint64 openedAt;
    }

    mapping(address coin => LoanDesk) internal _desk;
    address[] public coins;
    mapping(address borrower => address) internal _accounts;
    mapping(address coin => bool) public paused;
    bool public pausedAll;
    bool public openingPaused;

    event LoansOpened(address indexed coin, bytes32 indexed marketId, address wrapper, address oracle, address vault, address adapter);
    event AccountOpened(address indexed borrower, address account);
    event Borrowed(address indexed borrower, address indexed coin, uint256 collateralIn, uint256 amount);
    event Repaid(address indexed borrower, address indexed coin, uint256 usdg, uint256 collateralOut);
    event CollateralAdded(address indexed borrower, address indexed coin, uint256 amount);
    event Paused(address indexed coin, bool paused);
    event PausedAll(bool paused);
    event OpeningPaused(bool paused);

    error IsPaused();
    error Expired();
    error NotOpen();
    error AlreadyOpen();
    error GuardClosed();
    error HookFeeTooHigh(uint256 bps);
    error OverCap(uint256 wanted, uint256 room);
    error OverOpenLimit(uint256 owed, uint256 limit);
    error TooMuch(uint256 cost, uint256 limit);
    error NothingOwed();

    constructor(IMorpho morpho_, ICoinListing listing_, IERC20 usdg_, address ponsHook_, address safe_) Ownable(safe_) {
        morpho = morpho_;
        listing = listing_;
        usdg = usdg_;
        safe = safe_;
        ponsHook = ponsHook_;
        usdg_.forceApprove(address(morpho_), type(uint256).max);
    }

    // ------------------------------------------------------------------ owner

    /// @notice Stop new borrows against one coin, or allow them again. Nothing on the way out is ever stopped.
    function pause(address coin, bool paused_) external onlyOwner {
        paused[coin] = paused_;
        emit Paused(coin, paused_);
    }

    /// @notice Stop new borrows against every coin, or allow them again.
    function pauseAll(bool paused_) external onlyOwner {
        pausedAll = paused_;
        emit PausedAll(paused_);
    }

    /// @notice Stop or allow opening loans on coins that have none yet.
    function pauseOpening(bool paused_) external onlyOwner {
        openingPaused = paused_;
        emit OpeningPaused(paused_);
    }

    // ------------------------------------------------------------------ opening a coin's loans

    /// @notice For anyone: open loans against a coin listed on CoinListing. Makes its GatedCoin, its loan oracle (the
    ///         coin's delayed price in USDG), its Morpho market and its USDG lending vault, which goes to the Safe.
    ///         The caller pays in the vault's dead deposit: SEED of USDG, approved to this contract.
    function openLoans(address coin) external nonReentrant returns (bytes32 marketId) {
        if (openingPaused) revert IsPaused();
        CoinDesk memory c = listing.deskOf(coin); // reverts for a coin not listed
        if (_desk[coin].vault != address(0)) revert AlreadyOpen();
        bytes32 salt = keccak256(abi.encode(coin, "borro coin loans"));
        string memory sym = ISymbol(coin).symbol();
        GatedCoin w = new GatedCoin{salt: salt}(IERC20(coin), address(morpho), string.concat("Borro loan collateral ", sym), string.concat("l", sym));
        address oracle = address(
            IMorphoChainlinkOracleV2Factory(BorroLib.ORACLE_FACTORY).createMorphoChainlinkOracleV2(
                IERC4626(address(0)),
                1,
                AggregatorV3Interface(c.feed), // one coin (18 decimals) in USDG, by the coin's delayed price
                AggregatorV3Interface(address(0)),
                18,
                IERC4626(address(0)),
                1,
                AggregatorV3Interface(address(0)),
                AggregatorV3Interface(address(0)),
                6,
                salt
            )
        );
        LoanDesk storage d = _desk[coin];
        d.market = MarketParams({loanToken: address(usdg), collateralToken: address(w), oracle: oracle, irm: BorroLib.IRM, lltv: LLTV});
        d.wrapper = address(w);
        d.feed = c.feed;
        d.openedAt = uint64(block.timestamp);
        marketId = Id.unwrap(d.market.id());
        morpho.createMarket(d.market);
        IERC20(coin).forceApprove(address(w), type(uint256).max);
        IERC20(address(w)).forceApprove(address(morpho), type(uint256).max);
        address adapter;
        (d.vault, adapter) = _vault(sym, d.market, salt);
        coins.push(coin);
        emit LoansOpened(coin, marketId, address(w), oracle, d.vault, adapter);
    }

    /// @dev The coin's USDG lending vault, as BorroLib.openLender makes Borro's: this contract sets it up as owner and
    ///      curator, the dead deposit goes in, the risky settings get VAULT_TIMELOCK, and the Safe takes over.
    function _vault(string memory sym, MarketParams memory market, bytes32 salt) internal returns (address vault, address adapter) {
        IVaultV2 v = IVaultV2(IVaultV2Factory(BorroLib.VAULT_FACTORY).createVaultV2(address(this), address(usdg), salt));
        vault = address(v);
        v.setName(string.concat("Borro USDG for ", sym));
        v.setSymbol(string.concat("bUSDG.", sym));
        v.setCurator(address(this));
        adapter = IMorphoMarketV1AdapterV2Factory(BorroLib.ADAPTER_FACTORY).createMorphoMarketV1AdapterV2(vault);
        _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _now(v, abi.encodeCall(IVaultV2.addAdapter, (adapter)));
        bytes[3] memory ids = [
            abi.encode("this", adapter),
            abi.encode("collateralToken", market.collateralToken),
            abi.encode("this/marketParams", adapter, market)
        ];
        for (uint256 i; i < 3; i++) {
            _now(v, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (ids[i], VAULT_CAP)));
            _now(v, abi.encodeCall(IVaultV2.increaseRelativeCap, (ids[i], 1e18)));
        }
        v.setLiquidityAdapterAndData(adapter, abi.encode(market));
        v.setMaxRate(BorroLib.MAX_MAX_RATE);
        usdg.safeTransferFrom(msg.sender, address(this), SEED);
        usdg.forceApprove(vault, SEED);
        v.deposit(SEED, DEAD);
        BorroLib.lock(vault, VAULT_TIMELOCK);
        BorroLib.handOver(vault, address(this), safe);
    }

    function _now(IVaultV2 v, bytes memory data) private {
        v.submit(data);
        (bool ok, bytes memory err) = address(v).call(data);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    // ------------------------------------------------------------------ borrowing

    /// @notice Put `collateralIn` of the coin in (approved to this contract) and borrow `amount` of USDG to the
    ///         caller. Either may be zero: add collateral and borrow later, or borrow more against what is in.
    function borrow(address coin, uint256 collateralIn, uint256 amount, uint256 deadline) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        LoanDesk memory d = _open(coin);
        if (pausedAll || paused[coin]) revert IsPaused();
        CoinFeed(d.feed).poke();
        uint256 price = _mayBorrow(coin, d, amount);
        address acct = _account(msg.sender);
        if (collateralIn != 0) _hold(coin, d, collateralIn, acct);
        if (amount != 0) morpho.borrow(d.market, amount, 0, acct, msg.sender);
        _withinOpenLimit(d.market, acct, price);
        emit Borrowed(msg.sender, coin, collateralIn, amount);
    }

    /// @notice Add the coin to the collateral behind the caller's loan. Never paused.
    function addCollateral(address coin, uint256 amount) external nonReentrant {
        LoanDesk memory d = _open(coin);
        _poke(d.feed);
        _hold(coin, d, amount, _account(msg.sender));
        emit CollateralAdded(msg.sender, coin, amount);
    }

    /// @notice Repay `shares` of the caller's loan (the maximum uint: all of it) with USDG pulled from the caller (at
    ///         most `maxUsdg`), then send `collateralOut` of the coin back (the maximum uint: all of it). With debt
    ///         left, what stays must be within OPEN_LTV. Never paused, never capped, never guarded; a full repay and
    ///         withdrawal needs no price.
    function repay(address coin, uint256 shares, uint256 collateralOut, uint256 maxUsdg)
        external
        nonReentrant
        returns (uint256 paid)
    {
        LoanDesk memory d = _open(coin);
        address acct = _accounts[msg.sender];
        if (acct == address(0)) revert NothingOwed();
        _poke(d.feed);
        Id id = d.market.id();
        morpho.accrueInterest(d.market);
        Position memory p = morpho.position(id, acct);
        if (shares == type(uint256).max) shares = p.borrowShares;
        if (collateralOut == type(uint256).max) collateralOut = p.collateral;
        if (shares == 0 && collateralOut == 0) revert NothingOwed();
        if (shares != 0) {
            Market memory m = morpho.market(id);
            uint256 assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
            if (assets > maxUsdg) revert TooMuch(assets, maxUsdg);
            usdg.safeTransferFrom(msg.sender, address(this), assets);
            (paid,) = morpho.repay(d.market, 0, shares, acct, "");
            if (assets > paid) usdg.safeTransfer(msg.sender, assets - paid);
        }
        if (collateralOut != 0) {
            morpho.withdrawCollateral(d.market, collateralOut, acct, address(this));
            if (morpho.position(id, acct).borrowShares != 0) _withinOpenLimit(d.market, acct, _price(d.feed));
            GatedCoin(d.wrapper).unwrap(collateralOut, msg.sender);
        }
        emit Repaid(msg.sender, coin, paid, collateralOut);
    }

    // ------------------------------------------------------------------ views

    function loanDeskOf(address coin) external view returns (LoanDesk memory d) {
        d = _desk[coin];
        if (d.vault == address(0)) revert NotOpen();
    }

    function coinsLength() external view returns (uint256) {
        return coins.length;
    }

    /// @notice USDG that may be lent against the coin in all now, and the locked pool's coin side in dollars (USDG
    ///         wei), both at the delayed price. Reverts while the coin's feed has no price.
    function loanCapOf(address coin) public view returns (uint256 cap, uint256 depthUsd) {
        LoanDesk storage d = _desk[coin];
        if (d.vault == address(0)) revert NotOpen();
        (uint256 shortCap, uint256 depthCoins) = listing.capOf(coin); // reverts without a price
        (uint256 delayed,,) = CoinFeed(d.feed).price();
        depthUsd = Math.mulDiv(depthCoins, delayed, 1e30);
        // CoinListing gives no room at all while the locked pool is under 2 ETH at the delayed price; nor do loans.
        cap = shortCap == 0 ? 0 : Math.min((depthUsd * CAP_DEPTH_BPS) / BPS, CAP_USD);
    }

    /// @notice The account that holds a borrower's positions. The address is fixed before the account exists.
    function accountOf(address borrower) public view returns (address acct) {
        acct = _accounts[borrower];
        if (acct == address(0)) {
            bytes32 init = keccak256(abi.encodePacked(type(CoinAccount).creationCode, abi.encode(borrower, morpho)));
            acct = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(borrower))), init)))));
        }
    }

    // ------------------------------------------------------------------ internals

    function _open(address coin) internal view returns (LoanDesk memory d) {
        d = _desk[coin];
        if (d.vault == address(0)) revert NotOpen();
    }

    /// @dev The conditions on a new or bigger loan; returns the price the open limit is checked at: the lower of
    ///      the spot and the delayed price.
    function _mayBorrow(address coin, LoanDesk memory d, uint256 amount) internal returns (uint256 price) {
        price = _price(d.feed);
        uint256 hookFee = IPonsHook(ponsHook).hookFeeBps();
        if (hookFee > MAX_HOOK_FEE_BPS) revert HookFeeTooHigh(hookFee);
        morpho.accrueInterest(d.market);
        uint256 owed = morpho.market(d.market.id()).totalBorrowAssets;
        (uint256 cap,) = loanCapOf(coin);
        uint256 room = cap > owed ? cap - owed : 0;
        if (amount > room) revert OverCap(amount, room);
    }

    /// @dev The coin's price for loans: the lower of the spot and the delayed price, and only while the feed has a
    ///      price and the spot is no more than MAX_BELOW_BPS under the delayed one.
    function _price(address feed) internal view returns (uint256) {
        (uint256 delayed, uint256 n,) = CoinFeed(feed).price();
        if (n < CoinFeed(feed).minObs() || delayed == 0) revert GuardClosed();
        uint256 spot = CoinFeed(feed).spot();
        if (spot * BPS < delayed * (BPS - MAX_BELOW_BPS)) revert GuardClosed();
        return Math.min(spot, delayed);
    }

    /// @dev What the account owes in the market is at most OPEN_LTV of its collateral at `price` (USDG a coin, 18
    ///      decimals).
    function _withinOpenLimit(MarketParams memory market, address acct, uint256 price) internal view {
        Id id = market.id();
        Position memory p = morpho.position(id, acct);
        if (p.borrowShares == 0) return;
        Market memory m = morpho.market(id);
        uint256 owed = uint256(p.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 limit = Math.mulDiv(Math.mulDiv(p.collateral, price, 1e30), OPEN_LTV, 1e18);
        if (owed > limit) revert OverOpenLimit(owed, limit);
    }

    function _account(address borrower) internal returns (address acct) {
        acct = _accounts[borrower];
        if (acct == address(0)) {
            acct = address(new CoinAccount{salt: bytes32(uint256(uint160(borrower)))}(borrower, morpho));
            _accounts[borrower] = acct;
            emit AccountOpened(borrower, acct);
        }
    }

    /// @dev The coin from the caller, wrapped and posted as the account's collateral.
    function _hold(address coin, LoanDesk memory d, uint256 amount, address acct) internal {
        IERC20(coin).safeTransferFrom(msg.sender, address(this), amount);
        GatedCoin(d.wrapper).wrap(amount, address(this));
        morpho.supplyCollateral(d.market, amount, acct, "");
    }

    /// @dev A check for the coin's feed. A feed that cannot check never stops a way out.
    function _poke(address feed) internal {
        try CoinFeed(feed).poke() {} catch {}
    }
}
