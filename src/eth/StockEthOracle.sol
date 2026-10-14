// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MarketHours} from "./MarketHours.sol";

/// A Chainlink price feed (its proxy).
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// A Robinhood stock token. `oraclePaused` is true while a corporate action (a split, say) is being processed, when
/// the token's balances and the feed's price may not match.
interface IStockToken {
    function decimals() external view returns (uint8);
    function oraclePaused() external view returns (bool);
}

/// A Borro stock vault (a Morpho Vault V2) whose shares are the collateral.
interface IShareVault {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// Dollars (USDG) per ETH, 18 decimals, from the WETH/USDG Uniswap v3 pool's own 30-minute average: Borro's EthPrice
/// (contracts/src/coins/EthPrice.sol), already live for coin shorts.
interface IEthUsd {
    function ethUsd() external view returns (uint256);
}

/// @title StockEthOracle
/// @notice The Morpho oracle of a "borrow ETH against a stock" market: what one unit of collateral (a share of a Borro
///         stock vault, or the stock token itself) is worth in WETH, scaled by 1e36 as Morpho expects.
///         price = stock per share (the vault's own rate) x stock/USD (Chainlink) / ETH/USD (Chainlink).
/// @dev Morpho asks one question, price(), for every action that needs a price (borrowing, taking collateral out of a
///      position that owes, liquidating) and cannot say which action is asking. This oracle answers in two ways.
///
///      Strict, to every caller: a price only while the stock is live (its 24/5 market is open by MarketHours and its
///      feed updated within STOCK_MAX_AGE), the stock token is not paused for a corporate action, the ETH feed updated
///      within ETH_MAX_AGE, and Chainlink's ETH price is within BAND_BPS of the WETH/USDG pool's 30-minute average.
///      Otherwise it reverts, and Morpho refuses borrowing, withdrawing collateral against a debt, and liquidating.
///
///      For a liquidation that `liquidator` started (it arms this oracle around its own call to Morpho): the same
///      price while the stock is live. While it is not (a weekend, a holiday, a feed silent for over STOCK_MAX_AGE),
///      the last stock price raised by CUSHION_BPS, if that price is no older than CLOSED_MAX_AGE. So over a weekend
///      a position is closed out only once it is past its limit even with the stock CUSHION_BPS above Friday's close,
///      and only through `liquidator`. This mode never reads the pool: the pool can stop borrowing, but it can
///      never set a price or stop a liquidation.
///
///      Repaying and adding collateral never ask Morpho for a price, so they always work.
///      With `liquidator` set to zero nothing can arm the oracle, and nothing at all needs a price while the stock is
///      not live: no liquidations on weekends.
///
///      The liquidator is trusted with the armed window. It must arm only for a market whose loan token is WETH, whose
///      collateral is `collateral()` and whose oracle is this one, and the window must hold nothing but Morpho's own
///      liquidate call with no liquidation callback (EthLoanLiquidator: arm, liquidate, disarm, and only then trade).
///      Inside the window this oracle prices every caller as a liquidation, including a borrow. No owner, no
///      settings; the only state is the armed flag, in transient storage, so it is gone at the end of every
///      transaction whatever happens.
contract StockEthOracle {
    /// @notice A stock feed updates at least daily while its market is open (24 hour heartbeat, 0.5% deviation).
    uint256 public constant STOCK_MAX_AGE = 25 hours;
    /// @notice Chainlink's ETH/USD feed on this chain: 24 hour heartbeat, 0.5% deviation, around the clock.
    uint256 public constant ETH_MAX_AGE = 25 hours;
    /// @notice The oldest stock price a liquidation may use while the stock is not live. The longest ordinary
    ///         silence is a three-day weekend after a quiet day: about four days.
    uint256 public constant CLOSED_MAX_AGE = 5 days;
    /// @notice While the stock is not live, a liquidation prices it this much above its last price.
    uint256 public constant CUSHION_BPS = 500;
    /// @notice The most Chainlink's ETH price may differ from the pool's 30-minute average for the strict price.
    uint256 public constant BAND_BPS = 500;
    uint256 internal constant BPS = 10_000;

    address public immutable stock;
    IShareVault public immutable vault; // zero: the collateral is the stock token itself
    IChainlinkFeed public immutable stockFeed;
    IChainlinkFeed public immutable ethFeed;
    IEthUsd public immutable ethPool;
    address public immutable liquidator; // the one caller that may arm; zero: nobody

    bool private transient _armed;

    error BadSetup();
    error NotLiquidator();
    /// The stock is not live: its market is shut (a weekend or a holiday) or its feed has not updated for over a day.
    error MarketClosed(uint256 stockUpdatedAt);
    /// Even a liquidation will not use a stock price this old.
    error StockTooOld(uint256 stockUpdatedAt);
    error StockPaused();
    error BadStockPrice();
    error EthTooOld(uint256 ethUpdatedAt);
    error BadEthPrice();
    /// Chainlink's ETH price and the pool's 30-minute average are more than BAND_BPS apart (18 decimals each).
    error EthPricesDisagree(uint256 chainlinkUsd, uint256 poolUsd);

    /// @param stock_ The Robinhood stock token (18 decimals).
    /// @param vault_ The Borro stock vault whose shares are posted (18 decimals, asset `stock_`), or zero when the stock
    ///        token itself is posted.
    /// @param stockFeed_ Chainlink's stock/USD feed (8 decimals).
    /// @param ethFeed_ Chainlink's ETH/USD feed (8 decimals).
    /// @param ethPool_ The WETH/USDG pool's 30-minute average (Borro's EthPrice).
    /// @param liquidator_ The contract that may arm this oracle for its liquidations, or zero.
    constructor(
        address stock_,
        IShareVault vault_,
        IChainlinkFeed stockFeed_,
        IChainlinkFeed ethFeed_,
        IEthUsd ethPool_,
        address liquidator_
    ) {
        if (IStockToken(stock_).decimals() != 18) revert BadSetup();
        IStockToken(stock_).oraclePaused(); // must answer at setup
        if (address(vault_) != address(0) && (vault_.asset() != stock_ || vault_.decimals() != 18)) revert BadSetup();
        if (stockFeed_.decimals() != 8 || ethFeed_.decimals() != 8) revert BadSetup();
        if (ethPool_.ethUsd() == 0) revert BadSetup();
        stock = stock_;
        vault = vault_;
        stockFeed = stockFeed_;
        ethFeed = ethFeed_;
        ethPool = ethPool_;
        liquidator = liquidator_;
    }

    /// @notice What Morpho reads. The strict price, or inside a liquidation `liquidator` started, the liquidation price.
    function price() external view returns (uint256) {
        return _price(_armed);
    }

    /// @notice What price() answers to anyone but an armed liquidation: borrowing, withdrawing collateral against a
    ///         debt, liquidating straight on Morpho. Reverts when any of those is not allowed now.
    function borrowPrice() external view returns (uint256) {
        return _price(false);
    }

    /// @notice What price() answers inside a liquidation `liquidator` started. For a keeper or a page working out
    ///         whether a position can be liquidated now, weekends included.
    function liquidationPrice() external view returns (uint256) {
        return _price(true);
    }

    /// @notice True while the stock's 24/5 market is open by the calendar (the feed's age is checked separately).
    function marketOpen() external view returns (bool) {
        return MarketHours.isOpen(block.timestamp);
    }

    /// @notice The token Morpho holds as collateral in a market that uses this oracle.
    function collateral() external view returns (address) {
        return address(vault) == address(0) ? stock : address(vault);
    }

    /// @notice True while `liquidator` has the liquidation price switched on (only ever inside its own call to
    ///         Morpho's liquidate, within one transaction).
    function armed() external view returns (bool) {
        return _armed;
    }

    /// @notice Arms the oracle for the rest of the caller's Morpho liquidation. Only `liquidator`.
    function arm() external {
        if (msg.sender != liquidator) revert NotLiquidator();
        _armed = true;
    }

    /// @notice Ends the armed window. Only `liquidator`.
    function disarm() external {
        if (msg.sender != liquidator) revert NotLiquidator();
        _armed = false;
    }

    function _price(bool forLiquidation) internal view returns (uint256) {
        (uint256 stockUsd, uint256 stockAt) = _read(stockFeed);
        if (stockUsd == 0) revert BadStockPrice();
        // A token that stops answering (an upgrade that drops the function) must not freeze liquidations: it counts as
        // not paused. The probe is cheap, so a caller cannot starve it of gas and still have enough left to finish.
        try IStockToken(stock).oraclePaused() returns (bool paused) {
            if (paused) revert StockPaused();
        } catch {}

        (uint256 ethUsd, uint256 ethAt) = _read(ethFeed);
        if (ethUsd == 0) revert BadEthPrice();
        if (block.timestamp - ethAt > ETH_MAX_AGE) revert EthTooOld(ethAt);

        uint256 stockAge = block.timestamp - stockAt;
        bool live = stockAge <= STOCK_MAX_AGE && MarketHours.isOpen(block.timestamp);
        if (!forLiquidation) {
            if (!live) revert MarketClosed(stockAt);
            uint256 chainlinkUsd = ethUsd * 1e10;
            uint256 poolUsd = ethPool.ethUsd();
            uint256 gap = chainlinkUsd > poolUsd ? chainlinkUsd - poolUsd : poolUsd - chainlinkUsd;
            if (gap * BPS > poolUsd * BAND_BPS) revert EthPricesDisagree(chainlinkUsd, poolUsd);
        } else if (!live) {
            if (stockAge > CLOSED_MAX_AGE) revert StockTooOld(stockAt);
            stockUsd = stockUsd * (BPS + CUSHION_BPS) / BPS;
        }

        // Both tokens and the vault share have 18 decimals and both feeds 8, so WETH per stock is stockUsd / ethUsd.
        uint256 perShare = address(vault) == address(0) ? 1e18 : vault.convertToAssets(1e18);
        return FullMath.mulDiv(perShare * 1e18, stockUsd, ethUsd);
    }

    /// @dev A feed's answer and update time, or zeros for an answer that is not positive or a time that is zero or in
    ///      the future.
    function _read(IChainlinkFeed feed) private view returns (uint256 answer, uint256 updatedAt) {
        (, int256 a,, uint256 u,) = feed.latestRoundData();
        if (a <= 0 || u == 0 || u > block.timestamp) return (0, 0);
        return (uint256(a), u);
    }
}
