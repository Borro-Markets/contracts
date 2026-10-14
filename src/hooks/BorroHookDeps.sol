// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

/// Morpho Vault V2, as far as this hook uses it (ERC-4626 plus the liquidity adapter).
interface IVault {
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
}

interface IDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed);
    function rewards() external view returns (address);
    function morpho() external view returns (IMorpho);
}

interface IPots {
    function fund(uint256 amount) external;
}

interface IFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

interface IMsgSender {
    function msgSender() external view returns (address);
}

interface ISymbol {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}
