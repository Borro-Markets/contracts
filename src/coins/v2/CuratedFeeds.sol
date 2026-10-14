// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {CoinLens} from "./CoinLens.sol";
import {CoinMedianFeed} from "./CoinMedianFeed.sol";
import {CoinTwapFeed} from "./CoinTwapFeed.sol";
import {Venue, VENUE_V3} from "./VenueDeps.sol";

/// @title CuratedFeeds
/// @notice Makes a curated coin's delayed price feed: CoinTwapFeed for a Uniswap v3 pool, CoinMedianFeed (checks
///         every 15 seconds, 2-minute periods, the median over 30 minutes, 8 observations needed) for a Uniswap v4
///         pool. It lives apart from CuratedListing only so the listing stays under the contract size limit. Anyone
///         may call it; a feed is made at an address fixed by its caller and coin, so nobody can take a listing's.
contract CuratedFeeds {
    uint32 public constant SPACING = 120;
    uint32 public constant WINDOW = 1800;
    uint16 public constant MIN_OBS = 8;

    CoinLens public immutable lens;

    event Made(address indexed caller, address indexed coin, address feed);

    constructor(CoinLens lens_) {
        lens = lens_;
    }

    function make(address coin, Venue calldata v) external returns (address feed) {
        bytes32 salt = keccak256(abi.encode(msg.sender, coin));
        if (v.kind == VENUE_V3) feed = address(new CoinTwapFeed{salt: salt}(lens, coin, v));
        else feed = address(new CoinMedianFeed{salt: salt}(lens, coin, v, SPACING, WINDOW, MIN_OBS));
        emit Made(msg.sender, coin, feed);
    }
}
