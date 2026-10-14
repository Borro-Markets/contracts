// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// A Borro stock vault (bNVDA and so on): a Morpho Vault V2 whose asset is the stock token, as far as the calls vault
/// uses it. Its shares are what the calls vault holds; it never takes the stock back out of it.
interface IStockVault {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

/// A Chainlink price feed proxy, with its round history. Round ids carry the proxy's phase in their top 16 bits
/// (phase << 64 | the aggregator's own round). A round not posted yet reads as zeros.
interface IRoundFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// A Robinhood stock token. `oraclePaused` is true while a corporate action (a split, say) is being processed, when
/// the token and its feed may disagree.
interface IStockToken {
    function decimals() external view returns (uint8);
    function oraclePaused() external view returns (bool);
}
