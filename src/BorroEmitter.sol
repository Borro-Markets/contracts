// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BorroToken} from "./BorroToken.sol";

/// @title BorroEmitter
/// @notice Makes BORRO at a fixed rate per second, from a start time until the cap is reached. Of each drip, 88%
///         goes to the distributor (claimed by lenders, shorters and liquidity providers) and 12% to the treasury.
///         Anyone can call `drip`.
/// @dev Deploys the token, so it is the token's only minter. The rate starts at DEFAULT_RATE or lower; the owner
///      can lower it, never raise it, and can change the distributor only through a change that waits two
///      days in public. The treasury is fixed.
///      Emission starts at the start time or at deployment, whichever is later, so nothing is owed for time
///      before the contract existed.
contract BorroEmitter is Ownable2Step {
    uint256 public constant BPS = 10_000;
    uint256 public constant DISTRIBUTOR_BPS = 8_800; // the rest goes to the treasury
    uint256 public constant DISTRIBUTOR_DELAY = 2 days; // changing the distributor waits this long
    uint256 public constant DEFAULT_RATE = 100_000e18 / uint256(365 days); // the whole cap over a year

    BorroToken public immutable token;
    address public immutable treasury;
    uint256 public immutable start;

    uint256 public rate; // BORRO wei per second
    uint256 public last; // everything up to this time has been dripped
    address public distributor;
    address public nextDistributor;
    uint256 public nextDistributorAt; // zero: no change waiting

    event Dripped(uint256 toDistributor, uint256 toTreasury);
    event RateLowered(uint256 rate);
    event DistributorQueued(address distributor, uint256 readyAt);
    event DistributorSet(address distributor);

    error ZeroAddress();
    error RateUp();
    error NotReady();

    constructor(address owner_, address distributor_, address treasury_, uint256 start_, uint256 rate_) Ownable(owner_) {
        if (distributor_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (rate_ > DEFAULT_RATE) revert RateUp();
        token = new BorroToken();
        distributor = distributor_;
        treasury = treasury_;
        start = start_ > block.timestamp ? start_ : block.timestamp;
        last = start;
        rate = rate_;
        emit DistributorSet(distributor_);
    }

    /// @notice BORRO a drip would make right now.
    function due() public view returns (uint256 amount) {
        if (block.timestamp <= last) return 0;
        amount = (block.timestamp - last) * rate;
        uint256 room = token.CAP() - token.minted();
        if (amount > room) amount = room;
    }

    /// @notice Make what is due and send it out. Anyone can call it.
    function drip() public returns (uint256 amount) {
        amount = due();
        if (block.timestamp > last) last = block.timestamp;
        if (amount == 0) return 0;
        uint256 toDistributor = (amount * DISTRIBUTOR_BPS) / BPS;
        token.mint(distributor, toDistributor);
        token.mint(treasury, amount - toDistributor);
        emit Dripped(toDistributor, amount - toDistributor);
    }

    /// @notice Lower the rate. Everything due at the old rate is dripped first. Zero stops emission for good.
    function lowerRate(uint256 newRate) external onlyOwner {
        if (newRate > rate) revert RateUp();
        drip();
        rate = newRate;
        emit RateLowered(newRate);
    }

    /// @notice Ask to send future drips to a new distributor. Takes effect after DISTRIBUTOR_DELAY, by
    ///         `applyDistributor`. Queuing again replaces the waiting change and restarts the wait.
    function queueDistributor(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        nextDistributor = next;
        nextDistributorAt = block.timestamp + DISTRIBUTOR_DELAY;
        emit DistributorQueued(next, nextDistributorAt);
    }

    /// @notice Drop a waiting distributor change.
    function cancelDistributor() external onlyOwner {
        delete nextDistributor;
        delete nextDistributorAt;
        emit DistributorQueued(address(0), 0);
    }

    /// @notice Put a queued distributor change into effect. Anyone can call it once the wait is over. Everything
    ///         due until now goes to the old distributor first.
    function applyDistributor() external {
        if (nextDistributorAt == 0 || block.timestamp < nextDistributorAt) revert NotReady();
        drip();
        distributor = nextDistributor;
        delete nextDistributor;
        delete nextDistributorAt;
        emit DistributorSet(distributor);
    }
}
