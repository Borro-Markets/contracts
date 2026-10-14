// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// A stand-in $BORRO (18 decimals) for the drip and lock tests. It writes down every transfer out of one watched
/// address (the contract under test), so a test can say exactly who has ever received from it, and how much.
contract WatchedCoin is ERC20 {
    address public watched;
    address[] internal _paidTo;
    mapping(address => bool) internal _seen;
    mapping(address => uint256) public paidFromWatched;
    uint256 public paidOutTotal;

    constructor() ERC20("BORRO", "BORRO") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function watch(address a) external {
        watched = a;
    }

    /// How many different addresses have received from the watched address.
    function paidToCount() external view returns (uint256) {
        return _paidTo.length;
    }

    function paidTo(uint256 i) external view returns (address) {
        return _paidTo[i];
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from == watched) {
            if (!_seen[to]) {
                _seen[to] = true;
                _paidTo.push(to);
            }
            paidFromWatched[to] += value;
            paidOutTotal += value;
        }
        super._update(from, to, value);
    }
}
