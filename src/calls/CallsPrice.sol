// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IRoundFeed} from "./CallsDeps.sol";

/// @title CallsPrice
/// @notice Reads one round of a Chainlink feed's history. BorroCalls checks the round a caller suggests against its
///         neighbours in the same phase, so for any moment exactly one round passes and nobody can choose the price.
/// @dev Round ids are phase << 64 | the aggregator's round. Within a phase, rounds are numbered one after another and
///      posted in time order, and a round not posted yet reads as zeros (checked on chain 4663: the NVDA feed answers
///      round 1204 with zeros while 1203 is its latest). A round the proxy cannot read at all (an unknown phase) counts
///      as not posted. A read starved of gas also counts as not posted, and every check that uses a read fails closed
///      on that; the 63/64 rule leaves the caller too little gas to finish anyway.
library CallsPrice {
    /// @notice A round's answer and the time it was posted, or zeros if there is no such round.
    function read(IRoundFeed feed, uint80 id) internal view returns (int256 answer, uint256 updatedAt) {
        try feed.getRoundData(id) returns (uint80, int256 a, uint256, uint256 u, uint80) {
            return (a, u);
        } catch {
            return (0, 0);
        }
    }
}
