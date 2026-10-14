// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Test only: a Robinhood stock token (18 decimals) with the corporate-action switch.
contract MockStock is ERC20 {
    bool public oraclePaused;

    constructor() ERC20("Mock NVDA", "NVDA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}

/// Test only: USDG (6 decimals), which its issuer can pause (every transfer then fails, as Paxos's can).
contract MockUsdg is ERC20 {
    bool public frozen;

    constructor() ERC20("Mock USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFrozen(bool f) external {
        frozen = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!frozen, "paused");
        super._update(from, to, value);
    }
}

/// Test only: a Borro stock vault (Morpho Vault V2 surface). Assets = the stock it holds + rent (`gain`) - bad debt
/// (`lose`). `setLocked` marks held stock as lent out to shorters: still counted, but not payable until unlocked.
contract MockStockVault is ERC20 {
    IERC20 public immutable asset_;
    uint256 public locked; // held stock that is out with borrowers: counted, not payable
    uint256 public extra; // rent earned
    uint256 public lost; // bad debt written off

    constructor(IERC20 a) ERC20("Borro NVDA", "bNVDA") {
        asset_ = a;
    }

    function asset() external view returns (address) {
        return address(asset_);
    }

    function totalAssets() public view returns (uint256) {
        return asset_.balanceOf(address(this)) + extra - lost;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 1, totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply() + 1);
    }

    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset_.transferFrom(msg.sender, address(this), assets);
        _mint(onBehalf, shares);
    }

    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets) {
        require(msg.sender == onBehalf, "only own");
        assets = convertToAssets(shares);
        require(assets + locked <= asset_.balanceOf(address(this)), "lent out");
        _burn(onBehalf, shares);
        asset_.transfer(receiver, assets);
    }

    function setLocked(uint256 amount) external {
        locked = amount;
    }

    /// Rent: the test must also send the stock in for redemptions of it to work; counting it is enough for prices.
    function gain(uint256 amount) external {
        extra += amount;
    }

    function lose(uint256 amount) external {
        lost += amount;
    }
}

/// Test only: a Chainlink proxy with history. Rounds are phase << 64 | n; post() adds a round now (or at a given time);
/// newPhase() starts a new phase whose rounds count from 1.
contract MockRoundFeed {
    struct R {
        int256 answer;
        uint256 updatedAt;
    }

    uint16 public phase = 1;
    mapping(uint16 => R[]) internal _r; // index 0 is round 1
    bool public broken; // latestRoundData reverts

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function post(int256 answer) external returns (uint80) {
        return postAt(answer, block.timestamp);
    }

    function postAt(int256 answer, uint256 at) public returns (uint80) {
        _r[phase].push(R(answer, at));
        return _id(phase, _r[phase].length);
    }

    function newPhase() external {
        phase++;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function _id(uint16 p, uint256 n) internal pure returns (uint80) {
        return uint80((uint256(p) << 64) | n);
    }

    function latestId() public view returns (uint80) {
        uint16 p = phase;
        while (p > 1 && _r[p].length == 0) p--;
        return _id(p, _r[p].length);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "broken");
        uint80 id = latestId();
        (int256 a, uint256 u) = _get(id);
        return (id, a, u, u, id);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        uint16 p = uint16(uint256(id) >> 64);
        require(p >= 1 && p <= phase, "no phase");
        (int256 a, uint256 u) = _get(id);
        return (u == 0 ? _id(p, 0) : id, a, u, u, u == 0 ? _id(p, 0) : id);
    }

    function _get(uint80 id) internal view returns (int256, uint256) {
        uint16 p = uint16(uint256(id) >> 64);
        uint256 n = uint64(id);
        if (n == 0 || n > _r[p].length) return (0, 0);
        R memory x = _r[p][n - 1];
        return (x.answer, x.updatedAt);
    }
}
