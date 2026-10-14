// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {IMorphoLiquidateCallback} from "morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {GatedCoin} from "../GatedCoin.sol";
import {CoinRouter} from "./CoinRouter.sol";
import {CuratedLoans} from "./CuratedLoans.sol";
import {ICuratedListing, ICoinFeed} from "./VenueDeps.sol";

/// @title CuratedLoanLiquidator
/// @notice Liquidates a USDG loan against a curated coin that is past its market's LLTV, for anyone: Morpho hands
///         over the seized GatedCoin, it becomes the coin, the coin is sold through CoinRouter for USDG, Morpho is
///         repaid, and what is left goes to the caller. CoinLoanLiquidator's design for CuratedLoans. Holds nothing
///         between transactions; no owner.
/// @dev Anyone can also liquidate on Morpho directly and turn the GatedCoin they seize into the coin. If a loan's
///      collateral cannot cover its debt, seizing all of it leaves the rest as bad debt, which Morpho writes off
///      against that coin's loan market alone: only that coin's USDG lenders carry it.
contract CuratedLoanLiquidator is IMorphoLiquidateCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 public constant LIF = 1.15e18; // Morpho's liquidation incentive at LLTV 38.5% (its cap)
    uint256 internal constant ORACLE_SCALE = 1e36;

    IMorpho public immutable morpho;
    IERC20 public immutable usdg;
    CuratedLoans public immutable loans;
    ICuratedListing public immutable listing;
    CoinRouter public immutable router;

    error OnlyMorpho();
    error Healthy();
    error TooLittle(uint256 got, uint256 wanted);

    constructor(IMorpho morpho_, IERC20 usdg_, CuratedLoans loans_, CoinRouter router_) {
        morpho = morpho_;
        usdg = usdg_;
        loans = loans_;
        listing = loans_.listing();
        router = router_;
        usdg_.forceApprove(address(morpho_), type(uint256).max);
    }

    /// @notice Liquidate `borrower` (a CuratedLoans account) in `coin`'s loan market as far as Morpho allows: the whole
    ///         debt when the collateral covers it plus the incentive, otherwise all the collateral (the rest is bad
    ///         debt). Pays what is left over, at least `minProfit` USDG, to `to`.
    function liquidate(address coin, address borrower, uint256 minProfit, address to) external nonReentrant returns (uint256 profit) {
        CuratedLoans.LoanDesk memory d = loans.loanDeskOf(coin);
        try ICoinFeed(d.feed).poke() {} catch {}
        (uint256 seize, uint256 repayShares) = plan(d.market, borrower);
        if (seize == 0 && repayShares == 0) revert Healthy();
        morpho.liquidate(d.market, borrower, seize, repayShares, abi.encode(coin));
        profit = usdg.balanceOf(address(this));
        if (profit < minProfit) revert TooLittle(profit, minProfit);
        if (profit != 0) usdg.safeTransfer(to, profit);
    }

    /// @notice How a liquidation of `borrower` would go now: all its borrow shares repaid when its collateral covers
    ///         the debt plus the incentive, or else all its collateral seized. Both zero while it is healthy.
    function plan(MarketParams memory market, address borrower) public returns (uint256 seize, uint256 repayShares) {
        Id id = market.id();
        morpho.accrueInterest(market);
        Position memory p = morpho.position(id, borrower);
        if (p.borrowShares == 0) return (0, 0);
        Market memory m = morpho.market(id);
        uint256 owed = uint256(p.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 price = IOracle(market.oracle).price();
        uint256 worth = Math.mulDiv(p.collateral, price, ORACLE_SCALE); // in USDG
        if (owed <= Math.mulDiv(worth, market.lltv, 1e18)) return (0, 0);
        uint256 forAll = Math.mulDiv(Math.mulDiv(owed, LIF, 1e18, Math.Rounding.Ceil), ORACLE_SCALE, price, Math.Rounding.Ceil);
        if (p.collateral >= forAll) return (0, p.borrowShares);
        return (p.collateral, 0);
    }

    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        address coin = abi.decode(data, (address));
        CuratedLoans.LoanDesk memory d = loans.loanDeskOf(coin);
        uint256 seized = IERC20(d.wrapper).balanceOf(address(this));
        GatedCoin(d.wrapper).unwrap(seized, address(this));
        IERC20(coin).forceApprove(address(router), seized);
        router.sell(coin, seized, repaidAssets, address(this)); // reverts TooLittle under what Morpho is owed
    }
}
