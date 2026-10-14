// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IMorpho, MarketParams, Market, Position, Id} from "morpho-blue/interfaces/IMorpho.sol";

contract MockToken is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// The Vault V2 surface BorroHook uses. Assets are idle (here) or "lent" to shorters (gone until repaid); rent
/// raises what is owed. Withdrawals pay only from idle, like a real vault whose market is borrowed out.
contract MockVault is ERC20 {
    IERC20 public immutable assetToken;
    uint256 public immutable virtualShares;
    uint256 public lentOut;
    bool public refuseDeposits;
    uint256 public depositGas; // a real Borro vault's deposit runs through its adapter into Morpho: costly

    constructor(IERC20 a, uint8 assetDecimals) ERC20("vault", "v") {
        assetToken = a;
        virtualShares = 10 ** (18 - assetDecimals);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view returns (uint256) {
        return assetToken.balanceOf(address(this)) + lentOut;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply() + virtualShares);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + virtualShares, totalAssets() + 1, Math.Rounding.Ceil);
    }

    function deposit(uint256 assets, address onBehalf) external virtual returns (uint256 shares) {
        require(!refuseDeposits, "full");
        uint256 left = gasleft();
        uint256 stop = left > depositGas ? left - depositGas : 0;
        while (gasleft() > stop) {}
        shares = Math.mulDiv(assets, totalSupply() + virtualShares, totalAssets() + 1);
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(onBehalf, shares);
    }

    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares) {
        require(assets <= assetToken.balanceOf(address(this)), "illiquid");
        shares = previewWithdraw(assets);
        if (msg.sender != onBehalf) _spendAllowance(onBehalf, msg.sender, shares);
        _burn(onBehalf, shares);
        assetToken.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets) {
        assets = previewRedeem(shares);
        require(assets <= assetToken.balanceOf(address(this)), "illiquid");
        if (msg.sender != onBehalf) _spendAllowance(onBehalf, msg.sender, shares);
        _burn(onBehalf, shares);
        assetToken.transfer(receiver, assets);
    }

    function liquidityAdapter() external pure returns (address) {
        return address(0);
    }

    function liquidityData() external pure returns (bytes memory) {
        return "";
    }

    // test controls
    function lend(uint256 amount, address to) external {
        lentOut += amount;
        assetToken.transfer(to, amount);
    }

    function repay(uint256 amount) external {
        lentOut -= amount;
        assetToken.transferFrom(msg.sender, address(this), amount);
    }

    function accrue(uint256 rent) external {
        lentOut += rent;
    }

    function setRefuseDeposits(bool r) external {
        refuseDeposits = r;
    }

    function setDepositGas(uint256 g) external {
        depositGas = g;
    }
}

contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function set(int256 a, uint256 t) external {
        (answer, updatedAt) = (a, t);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockMorpho {
    mapping(Id => Market) internal _m;

    function setUse(Id id, uint128 supplied, uint128 borrowed) external {
        _m[id].totalSupplyAssets = supplied;
        _m[id].totalBorrowAssets = borrowed;
        _m[id].totalSupplyShares = supplied;
        _m[id].totalBorrowShares = borrowed;
    }

    function market(Id id) external view returns (Market memory) {
        return _m[id];
    }

    function position(Id, address) external pure returns (Position memory p) {
        return p;
    }
}

contract MockDesks {
    mapping(bytes32 => MarketParams) internal _market;
    mapping(bytes32 => address) internal _feed;
    address public rewards;
    IMorpho public morpho;

    constructor(IMorpho m) {
        morpho = m;
    }

    function setDesk(bytes32 id, MarketParams memory m, address feed) external {
        _market[id] = m;
        _feed[id] = feed;
    }

    function setRewards(address r) external {
        rewards = r;
    }

    function deskOf(bytes32 id)
        external
        view
        returns (MarketParams memory market, PoolKey[] memory route, address v3Pool, bool paused, address feed)
    {
        return (_market[id], route, address(0), false, _feed[id]);
    }
}

contract MockPots {
    IERC20 public immutable usdg;
    uint256 public funded;

    constructor(IERC20 u) {
        usdg = u;
    }

    function fund(uint256 amount) external {
        usdg.transferFrom(msg.sender, address(this), amount);
        funded += amount;
    }
}

/// A swap router that, like Uniswap's, reports who it is swapping for through msgSender().
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable pm;
    address transient _payer;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function msgSender() external view returns (address) {
        return _payer;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta d) {
        _payer = msg.sender;
        d = abi.decode(pm.unlock(abi.encode(msg.sender, key, zeroForOne, amountSpecified)), (BalanceDelta));
        _payer = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (address payer, PoolKey memory key, bool zeroForOne, int256 amountSpecified) = abi.decode(data, (address, PoolKey, bool, int256));
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settle(key.currency0, payer, d.amount0());
        _settle(key.currency1, payer, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, address payer, int128 amount) internal {
        if (amount < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transferFrom(payer, address(pm), uint128(-amount));
            pm.settle();
        } else if (amount > 0) {
            pm.take(c, payer, uint128(amount));
        }
    }
}

/// Calls the hook from inside its own PoolManager unlock, to show a withdrawal still pays when the PoolManager is busy.
contract BusyCaller is IUnlockCallback {
    IPoolManager public immutable pm;
    address public target;
    bytes public call_;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function run(address t, bytes calldata c) external returns (bytes memory) {
        (target, call_) = (t, c);
        return pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(call_);
        require(ok, "call failed");
        return ret;
    }
}

/// A vault that, when the hook lends to it, tries to swap on the pool and to withdraw from the hook mid-call.
contract ReenteringVault is MockVault {
    TestRouter public router;
    PoolKey public poolKey;
    address public hook;
    bytes public withdrawCall;
    bool public swapGotIn;
    bool public withdrawGotIn;

    constructor(IERC20 a, uint8 d) MockVault(a, d) {}

    function arm(TestRouter r, PoolKey memory k, address h, bytes memory w) external {
        (router, poolKey, hook, withdrawCall) = (r, k, h, w);
    }

    function deposit(uint256 assets, address onBehalf) external override returns (uint256 shares) {
        if (hook != address(0) && msg.sender == hook) {
            try router.swap(poolKey, true, -1e6) {
                swapGotIn = true;
            } catch {}
            (bool ok,) = hook.call(withdrawCall);
            withdrawGotIn = ok;
        }
        shares = previewWithdraw(assets) == 0 ? assets * virtualShares : previewWithdraw(assets);
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(onBehalf, shares);
    }
}
