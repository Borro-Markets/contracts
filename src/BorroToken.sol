// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title BorroToken
/// @notice BORRO. At most 100,000 are ever made, all by the emitter that deploys this contract, over time.
///         There is no premine. Anyone can burn their own.
/// @dev The cap counts every token ever minted, not the supply, so a burn is for good: burning never makes room
///      for more to be minted.
contract BorroToken is ERC20, ERC20Permit, ERC20Burnable {
    uint256 public constant CAP = 100_000e18;

    address public immutable minter;
    uint256 public minted; // every BORRO ever made

    error OnlyMinter();
    error PastCap();

    constructor() ERC20("Borro", "BORRO") ERC20Permit("Borro") {
        minter = msg.sender;
    }

    function cap() external pure returns (uint256) {
        return CAP;
    }

    /// @notice Make new BORRO. Only the minter can, and never past the cap.
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        if (minted + amount > CAP) revert PastCap();
        minted += amount;
        _mint(to, amount);
    }
}
