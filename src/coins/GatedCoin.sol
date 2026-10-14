// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GatedCoin
/// @notice The collateral of one coin's loan market (docs/COIN-SHORTS.md, "Borrowing against a coin"): one GatedCoin
///         is one of the coin, held here.
/// @dev Gated so the market's borrow cap is real: Morpho is open to anyone, so if anyone could post the coin as
///      collateral they could borrow USDG straight from Morpho, past CoinLoans' cap and open limit. GatedCoin can be
///      handed to Morpho only by CoinLoans (its gate), and only the gate makes new GatedCoin. Anyone holding it (a
///      borrower who took collateral out directly, a liquidator who seized some) can always turn it back into the
///      coin, one for one. No owner. Morpho flash loans of it fail (the loan is paid back by a transfer to Morpho).
contract GatedCoin is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable coin;
    address public immutable gate; // CoinLoans
    address public immutable morpho;

    error OnlyGate();
    error OnlyGateToMorpho();
    error NotReceived(uint256 got, uint256 wanted);

    constructor(IERC20 coin_, address morpho_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        coin = coin_;
        gate = msg.sender;
        morpho = morpho_;
    }

    /// @notice Make GatedCoin from the coin, one for one. Only the gate.
    function wrap(uint256 amount, address to) external {
        if (msg.sender != gate) revert OnlyGate();
        uint256 before = coin.balanceOf(address(this));
        coin.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = coin.balanceOf(address(this)) - before;
        if (got != amount) revert NotReceived(got, amount); // a coin that takes a cut on transfer cannot back one for one
        _mint(to, amount);
    }

    /// @notice Turn GatedCoin back into the coin, one for one. Anyone holding it.
    function unwrap(uint256 amount, address to) external {
        _burn(msg.sender, amount);
        coin.safeTransfer(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == morpho && from != gate) revert OnlyGateToMorpho();
        super._update(from, to, value);
    }
}
