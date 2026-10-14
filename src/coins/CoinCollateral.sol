// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CoinCollateral (cUSDG)
/// @notice The collateral of every coin-shorts market: one cUSDG is one share of the Steakhouse USDG vault, held
///         here, so money held against a coin short earns that vault's interest.
/// @dev Gated so a coin market's short cap is real: Morpho is open to anyone, so if anyone could post collateral
///      they could borrow a coin straight from Morpho, past CoinShort's cap. cUSDG can be handed to Morpho only by
///      CoinShort (Morpho pulls collateral from whoever supplies it), and only CoinShort makes new cUSDG. Everyone
///      who holds cUSDG (a shorter who took collateral out directly, a liquidator who seized some) can always turn
///      it back into the Steakhouse shares behind it, one for one. No owner; nothing else can move the shares.
///      This also stops Morpho flash loans of cUSDG (the loan is paid back by a transfer to Morpho).
contract CoinCollateral is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable held; // Steakhouse USDG shares, 18 decimals
    address public immutable short; // CoinShort
    address public immutable morpho;

    error OnlyShort();
    error OnlyShortToMorpho();

    constructor(IERC20 held_, address morpho_) ERC20("Borro coin-short collateral", "cUSDG") {
        held = held_;
        short = msg.sender;
        morpho = morpho_;
    }

    /// @notice Make cUSDG from Steakhouse shares, one for one. Only CoinShort.
    function wrap(uint256 amount, address to) external {
        if (msg.sender != short) revert OnlyShort();
        held.safeTransferFrom(msg.sender, address(this), amount);
        _mint(to, amount);
    }

    /// @notice Turn cUSDG back into the Steakhouse shares behind it, one for one. Anyone holding cUSDG.
    function unwrap(uint256 amount, address to) external {
        _burn(msg.sender, amount);
        held.safeTransfer(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == morpho && from != short) revert OnlyShortToMorpho();
        super._update(from, to, value);
    }
}
