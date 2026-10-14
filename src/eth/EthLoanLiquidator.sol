// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {MathLib, WAD} from "morpho-blue/libraries/MathLib.sol";
import {UtilsLib} from "morpho-blue/libraries/UtilsLib.sol";
import {
    ORACLE_PRICE_SCALE, LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR
} from "morpho-blue/libraries/ConstantsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {BorroSwap} from "../BorroSwap.sol";

/// What the liquidator needs from a StockEthOracle.
interface IEthLoanOracle {
    function liquidator() external view returns (address);
    function collateral() external view returns (address);
    function stock() external view returns (address);
    function liquidationPrice() external view returns (uint256);
    function armed() external view returns (bool);
    function arm() external;
    function disarm() external;
}

/// Where each stock trades, as listed on BorroShort.
interface IEthLoanDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed);
}

/// A Borro stock vault (Morpho Vault V2), whose shares are the collateral.
interface IEthLoanVault {
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
}

/// @title EthLoanLiquidator
/// @notice Liquidates an unhealthy loan in a Borro "borrow ETH against a stock" market (loan WETH, collateral a Borro
///         stock vault's shares, priced by StockEthOracle), weekends included. Anyone can call it.
/// @dev The one rule this contract is built around: while the oracle's liquidation price is switched on, nothing runs
///      but Morpho's own liquidate. In order:
///        1. A Morpho flash loan brings the WETH owed. Inside its callback:
///        2. the oracle is armed, Morpho.liquidate runs WITHOUT a liquidation callback (empty data), and the oracle is
///           disarmed the moment liquidate returns. Inside that window Morpho calls only its IRM, the oracle (by
///           staticcall, so nothing it reaches can change state), the vault share's transfer (Morpho Vault V2; its
///           gates are view calls only the Hoard Safe can set) and WETH's transferFrom;
///        3. only then, with the oracle strict again, the seized shares are redeemed, the stock is sold for USDG along
///           its Borro route (where a pool's hook may run code of its own), and exactly the WETH repaid is bought back
///           on the WETH/USDG pool;
///        4. Morpho takes the flash loan back. The USDG left is the caller's, and less than `minProfit` reverts.
///      liquidateForShares is the same window, but the caller pays the WETH and takes the seized shares (for when the
///      vault has lent out its stock and cannot redeem, which the capital-free path needs).
///      Holds nothing between transactions; no owner; no setting. A market qualifies when its loan token is WETH, its
///      IRM is Morpho's, its oracle names this contract as its liquidator (or nobody: then it is never armed, and
///      liquidations need the strict price, so weekdays only) and the oracle's collateral is the market's.
///      Arming touches only that market's own oracle, so a market made up to look like one gains nothing.
contract EthLoanLiquidator is BorroSwap, IMorphoFlashLoanCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    IMorpho public immutable morpho;
    IERC20 public immutable weth;
    address public immutable ethPool; // the WETH/USDG Uniswap v3 pool WETH is bought back on
    IEthLoanDesks public immutable desks; // BorroShort
    address public immutable irm; // Morpho's AdaptiveCurveIRM, the only IRM a Borro ETH market uses

    // Set only for the length of one liquidation.
    uint8 private transient _op; // 1: sell and buy back, 2: the caller pays and takes the shares
    address private transient _caller;
    uint256 private transient _seized;
    uint256 private transient _repaid;

    struct Job {
        MarketParams market;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
        IEthLoanOracle oracle;
        address stock;
        PoolKey[] route;
        address v3Pool;
        uint256 maxWethIn; // liquidateForShares only
        bool arm; // the oracle names this contract: switch its liquidation price on around Morpho's liquidate
    }

    event Liquidated(
        address indexed caller, bytes32 indexed marketId, address indexed borrower, uint256 seized, uint256 repaid, uint256 profit
    );
    event LiquidatedForShares(
        address indexed caller, bytes32 indexed marketId, address indexed borrower, uint256 seized, uint256 repaid
    );

    error OnlyMorpho();
    error NotInFlight();
    error BadMarket();
    error NoRoute();
    error StillArmed();
    error Nothing();
    error TooLittle(uint256 got, uint256 wanted);
    error TooMuchWeth(uint256 repaid, uint256 limit);
    /// The vault cannot pay out the seized shares now (its stock is lent to shorters). Use liquidateForShares.
    error CannotRedeem(address vault, uint256 shares);

    constructor(
        IMorpho morpho_,
        IPoolManager poolManager_,
        IERC20 usdg_,
        IERC20 weth_,
        address ethPool_,
        IEthLoanDesks desks_,
        address irm_
    ) BorroSwap(poolManager_, usdg_) {
        morpho = morpho_;
        weth = weth_;
        ethPool = ethPool_;
        desks = desks_;
        irm = irm_;
    }

    /// @notice Liquidate `borrower` on `market`, paid for by selling what is seized. Pass exactly one of
    ///         `seizedAssets` (vault shares to take) and `repaidShares` (borrow shares to repay), as Morpho's liquidate.
    /// @param routeId The BorroShort desk of the market's stock (the id of that stock's short market).
    /// @param minProfit The least USDG the caller must be left with; less reverts.
    /// @return profit USDG sent to the caller.
    function liquidate(
        MarketParams calldata market,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes32 routeId,
        uint256 minProfit
    ) external nonReentrant returns (uint256 profit) {
        Job memory j = _job(market, borrower, seizedAssets, repaidShares, routeId, true);
        uint256 before = usdg.balanceOf(address(this));
        _run(1, j);
        profit = usdg.balanceOf(address(this)) - before;
        if (profit < minProfit) revert TooLittle(profit, minProfit);
        if (profit != 0) usdg.safeTransfer(msg.sender, profit);
        emit Liquidated(msg.sender, Id.unwrap(market.id()), borrower, _seized, _repaid, profit);
    }

    /// @notice The same liquidation, but the caller pays the WETH repaid (at most `maxWethIn`, approved to this
    ///         contract) and receives the seized vault shares. For when the vault cannot redeem them right now.
    function liquidateForShares(
        MarketParams calldata market,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 maxWethIn
    ) external nonReentrant returns (uint256 seized, uint256 repaid) {
        Job memory j = _job(market, borrower, seizedAssets, repaidShares, bytes32(0), false);
        j.maxWethIn = maxWethIn;
        _run(2, j);
        (seized, repaid) = (_seized, _repaid);
        emit LiquidatedForShares(msg.sender, Id.unwrap(market.id()), borrower, seized, repaid);
    }

    /// @notice The WETH Morpho would take for this liquidation now (what the flash loan must at least bring).
    function repaidFor(MarketParams memory market, uint256 seizedAssets, uint256 repaidShares) public view returns (uint256) {
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = morpho.expectedMarketBalances(market);
        if (seizedAssets != 0) {
            uint256 lif = UtilsLib.min(
                MAX_LIQUIDATION_INCENTIVE_FACTOR, WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - market.lltv))
            );
            uint256 price = IEthLoanOracle(market.oracle).liquidationPrice();
            repaidShares = seizedAssets.mulDivUp(price, ORACLE_PRICE_SCALE).wDivUp(lif).toSharesUp(totalBorrowAssets, totalBorrowShares);
        }
        return repaidShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    function _job(
        MarketParams calldata market,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes32 routeId,
        bool needRoute
    ) internal view returns (Job memory j) {
        if (!UtilsLib.exactlyOneZero(seizedAssets, repaidShares)) revert Nothing();
        if (market.loanToken != address(weth) || market.irm != irm) revert BadMarket();
        IEthLoanOracle oracle = IEthLoanOracle(market.oracle);
        // An oracle names this contract (weekend liquidations at the cushioned price), or nobody (no weekend
        // liquidations: the strict price only, so weekdays only).
        address named = oracle.liquidator();
        if ((named != address(this) && named != address(0)) || oracle.collateral() != market.collateralToken) revert BadMarket();
        j.arm = named == address(this);
        j.market = market;
        j.borrower = borrower;
        j.seizedAssets = seizedAssets;
        j.repaidShares = repaidShares;
        j.oracle = oracle;
        if (needRoute) {
            j.stock = oracle.stock();
            (MarketParams memory desk, PoolKey[] memory route, address v3Pool,,) = desks.deskOf(routeId);
            if (desk.loanToken != j.stock || (route.length == 0 && v3Pool == address(0))) revert NoRoute();
            j.route = route;
            j.v3Pool = v3Pool;
        }
    }

    function _run(uint8 op, Job memory j) internal {
        uint256 need = repaidFor(j.market, j.seizedAssets, j.repaidShares);
        if (need == 0) revert Nothing();
        // A little over what Morpho will take; what is not used repays its own part of the flash loan.
        uint256 flash = need + need / 10_000 + 1;
        _op = op;
        _caller = msg.sender;
        morpho.flashLoan(address(weth), flash, abi.encode(j));
        _op = 0;
        _caller = address(0);
    }

    /// @dev Morpho's flash loan has sent `assets` WETH here.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        uint8 op = _op;
        if (op == 0) revert NotInFlight();
        Job memory j = abi.decode(data, (Job));

        // Approvals first, so the armed window below holds Morpho's liquidate and nothing else.
        weth.forceApprove(address(morpho), assets);
        if (j.arm) j.oracle.arm();
        (uint256 seized, uint256 repaid) = morpho.liquidate(j.market, j.borrower, j.seizedAssets, j.repaidShares, "");
        if (j.arm) {
            j.oracle.disarm();
            if (j.oracle.armed()) revert StillArmed();
        }
        // From here on the oracle is strict again; code Borro does not control may run.

        if (op == 1) {
            uint256 stockOut = seized; // collateral that is the stock token itself needs no redeeming
            if (j.market.collateralToken != j.stock) {
                try IEthLoanVault(j.market.collateralToken).redeem(seized, address(this), address(this)) returns (uint256 a) {
                    stockOut = a;
                } catch {
                    revert CannotRedeem(j.market.collateralToken, seized);
                }
            }
            _swap(j.route, j.v3Pool, j.stock, stockOut, false, false); // stock to USDG
            if (repaid != 0) _tradeV3(ethPool, address(weth), repaid, true, false); // exactly the WETH repaid
        } else {
            if (repaid > j.maxWethIn) revert TooMuchWeth(repaid, j.maxWethIn);
            address caller = _caller;
            weth.safeTransferFrom(caller, address(this), repaid);
            IERC20(j.market.collateralToken).safeTransfer(caller, seized);
        }
        weth.forceApprove(address(morpho), assets); // the flash loan's repayment
        (_seized, _repaid) = (seized, repaid);
    }
}
