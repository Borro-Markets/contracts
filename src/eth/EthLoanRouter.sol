// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMorpho, MarketParams, Id, Authorization, Signature} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

interface IEthLoanWeth {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// What the router needs from a StockEthOracle.
interface IEthRouterOracle {
    function liquidator() external view returns (address);
    function collateral() external view returns (address);
    function stock() external view returns (address);
    function borrowPrice() external view returns (uint256);
}

/// A Borro stock vault (a Morpho Vault V2), whose shares are the collateral.
interface IEthRouterVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
}

/// @title EthLoanRouter
/// @notice Borrow ETH against a stock in one transaction, and back again. Open: the caller's stock goes into its Borro
///         vault (so it keeps earning rent from shorters), the vault shares (plus any the caller already holds) are
///         posted as the caller's collateral on the stock's Borro ETH market, and WETH is borrowed there in the
///         caller's name and sent to them as ETH. Repay with ETH, any day. Take the collateral back as the stock or as
///         vault shares.
/// @dev Every action is for msg.sender and nobody else: no function takes an account to act for, so a caller's Morpho
///      authorization of this contract (needed to borrow and to take collateral back in their name) never lets anyone
///      else move their position. Holds nothing between transactions. The owner (the Hoard Safe) lists Borro's ETH
///      markets and can stop new opens; repaying and taking back are never stopped, and nothing here can send out
///      anyone's tokens. A borrow keeps the whole position at or under MAX_OPEN_OF_LLTV_BPS of the market's LLTV at
///      the oracle's strict price, which only exists while the stock's market is open: no borrowing at weekends.
contract EthLoanRouter is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    /// A borrow may bring the position to at most this share of the LLTV: the stock (in ETH) has to fall about a quarter
    /// before the position can be liquidated.
    uint256 public constant MAX_OPEN_OF_LLTV_BPS = 7_500;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ORACLE_SCALE = 1e36;

    IMorpho public immutable morpho;
    IEthLoanWeth public immutable weth;
    address public immutable irm;
    address public immutable liquidator; // EthLoanLiquidator: the oracles of Borro's ETH markets name it

    bool public opensPaused;
    mapping(bytes32 id => bool) public listed;

    struct Open {
        MarketParams market;
        uint256 stockIn; // stock taken from the caller and put into its vault
        uint256 sharesIn; // vault shares the caller already holds, posted as they are
        uint256 minShares; // the fewest vault shares the deposit may bring
        uint256 borrow; // WETH borrowed in the caller's name and sent to them as ETH (zero: only post)
        uint256 deadline;
    }

    event Listed(bytes32 indexed id, address indexed collateral);
    event OpensPaused(bool paused);
    event Opened(address indexed who, bytes32 indexed id, uint256 stockIn, uint256 sharesPosted, uint256 borrowed);
    event Repaid(address indexed who, bytes32 indexed id, uint256 repaid, uint256 refunded);
    event Withdrawn(address indexed who, bytes32 indexed id, uint256 shares, uint256 stockOut);

    error Expired();
    error Paused();
    error Nothing();
    error BadMarket();
    error NotListed();
    error NotAuthorized();
    error BadSignature();
    error TooFewShares(uint256 got, uint256 wanted);
    error OverLimit(uint256 debt, uint256 allowed);
    error CannotRedeem();
    error EthSendFailed();
    error NotEnoughEth();
    error NotWeth();

    constructor(IMorpho morpho_, IEthLoanWeth weth_, address irm_, address liquidator_, address owner_) Ownable(owner_) {
        morpho = morpho_;
        weth = weth_;
        irm = irm_;
        liquidator = liquidator_;
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert NotWeth();
    }

    // ================================================================= owner

    /// @notice Lists one of Borro's ETH markets: loan WETH, Morpho's IRM, an oracle that names Borro's ETH liquidator,
    ///         the oracle's collateral. A market cannot be unlisted; opens can be paused.
    function list(MarketParams calldata m) external onlyOwner {
        if (m.loanToken != address(weth) || m.irm != irm) revert BadMarket();
        IEthRouterOracle o = IEthRouterOracle(m.oracle);
        if (o.liquidator() != liquidator || o.collateral() != m.collateralToken) revert BadMarket();
        bytes32 id = Id.unwrap(m.id());
        if (morpho.market(m.id()).lastUpdate == 0) revert BadMarket();
        listed[id] = true;
        emit Listed(id, m.collateralToken);
    }

    /// @notice Stop or allow new opens. Repaying and taking back are never stopped.
    function setOpensPaused(bool paused) external onlyOwner {
        opensPaused = paused;
        emit OpensPaused(paused);
    }

    // ================================================================= open

    /// @notice Post stock (and or vault shares) and borrow ETH, in the caller's name. Borrowing needs the caller's
    ///         Morpho authorization of this contract; posting alone does not.
    function open(Open calldata o) external nonReentrant returns (uint256 posted) {
        if (o.borrow != 0 && !morpho.isAuthorized(msg.sender, address(this))) revert NotAuthorized();
        return _open(o);
    }

    /// @notice Open with the caller's Morpho authorization of this contract submitted in the same transaction. If
    ///         someone submitted the same signature first, the authorization already stands and the open goes on.
    function openWithSig(Open calldata o, Authorization calldata auth, Signature calldata sig)
        external
        nonReentrant
        returns (uint256 posted)
    {
        if (auth.authorizer != msg.sender || auth.authorized != address(this) || !auth.isAuthorized) revert BadSignature();
        if (!morpho.isAuthorized(msg.sender, address(this))) {
            try morpho.setAuthorizationWithSig(auth, sig) {} catch {}
            if (!morpho.isAuthorized(msg.sender, address(this))) revert NotAuthorized();
        }
        return _open(o);
    }

    function _open(Open calldata o) internal returns (uint256 posted) {
        if (opensPaused) revert Paused();
        if (block.timestamp > o.deadline) revert Expired();
        Id id = o.market.id();
        if (!listed[Id.unwrap(id)]) revert NotListed();
        if (o.stockIn == 0 && o.sharesIn == 0 && o.borrow == 0) revert Nothing();
        address vault = o.market.collateralToken;
        address stock = IEthRouterOracle(o.market.oracle).stock();

        if (o.stockIn != 0) {
            IERC20(stock).safeTransferFrom(msg.sender, address(this), o.stockIn);
            if (vault == stock) {
                posted = o.stockIn;
            } else {
                IERC20(stock).forceApprove(vault, o.stockIn);
                posted = IEthRouterVault(vault).deposit(o.stockIn, address(this));
                if (posted < o.minShares) revert TooFewShares(posted, o.minShares);
            }
        }
        if (o.sharesIn != 0) {
            IERC20(vault).safeTransferFrom(msg.sender, address(this), o.sharesIn);
            posted += o.sharesIn;
        }
        if (posted != 0) {
            IERC20(vault).forceApprove(address(morpho), posted);
            morpho.supplyCollateral(o.market, posted, msg.sender, "");
        }
        if (o.borrow != 0) {
            morpho.borrow(o.market, o.borrow, 0, msg.sender, address(this));
            // The whole position, at the oracle's strict price, held to MAX_OPEN_OF_LLTV_BPS of the LLTV.
            uint256 owed = morpho.expectedBorrowAssets(o.market, msg.sender);
            uint256 coll = morpho.position(id, msg.sender).collateral;
            uint256 worth = coll * IEthRouterOracle(o.market.oracle).borrowPrice() / ORACLE_SCALE;
            uint256 allowed = worth * o.market.lltv / 1e18 * MAX_OPEN_OF_LLTV_BPS / BPS;
            if (owed > allowed) revert OverLimit(owed, allowed);
            weth.withdraw(o.borrow);
            _sendEth(msg.sender, o.borrow);
        }
        emit Opened(msg.sender, Id.unwrap(id), o.stockIn, posted, o.borrow);
    }

    // ================================================================= repay and take back

    /// @notice Repay the caller's loan with the ETH sent. More than the debt repays all of it and the rest comes back.
    function repay(MarketParams calldata m) external payable nonReentrant returns (uint256 repaid) {
        repaid = _repay(m);
    }

    /// @notice Take `shares` of the caller's posted vault shares back, as the stock (`asStock`) or as the shares.
    ///         Needs the caller's Morpho authorization of this contract. While a loan is open this needs a price, so
    ///         it works only while the stock's market is open; with no loan it works any day.
    function withdraw(MarketParams calldata m, uint256 shares, bool asStock) external nonReentrant returns (uint256 out) {
        out = _withdraw(m, shares, asStock);
    }

    /// @notice Repay everything with the ETH sent (the rest comes back) and take all the collateral back.
    function close(MarketParams calldata m, bool asStock) external payable nonReentrant returns (uint256 out) {
        _repay(m);
        if (morpho.position(m.id(), msg.sender).borrowShares != 0) revert NotEnoughEth();
        out = _withdraw(m, morpho.position(m.id(), msg.sender).collateral, asStock);
    }

    function _repay(MarketParams calldata m) internal returns (uint256 repaid) {
        Id id = m.id();
        if (!listed[Id.unwrap(id)]) revert NotListed();
        if (msg.value == 0) return 0;
        weth.deposit{value: msg.value}();
        IERC20(address(weth)).forceApprove(address(morpho), msg.value);
        uint256 debt = morpho.expectedBorrowAssets(m, msg.sender);
        if (debt == 0) {
            repaid = 0;
        } else if (msg.value >= debt) {
            (repaid,) = morpho.repay(m, 0, morpho.position(id, msg.sender).borrowShares, msg.sender, "");
        } else {
            (repaid,) = morpho.repay(m, msg.value, 0, msg.sender, "");
        }
        IERC20(address(weth)).forceApprove(address(morpho), 0);
        uint256 back = msg.value - repaid;
        if (back != 0) {
            weth.withdraw(back);
            _sendEth(msg.sender, back);
        }
        emit Repaid(msg.sender, Id.unwrap(id), repaid, back);
    }

    function _withdraw(MarketParams calldata m, uint256 shares, bool asStock) internal returns (uint256 out) {
        if (!listed[Id.unwrap(m.id())]) revert NotListed();
        if (shares == 0) revert Nothing();
        if (!morpho.isAuthorized(msg.sender, address(this))) revert NotAuthorized();
        address vault = m.collateralToken;
        morpho.withdrawCollateral(m, shares, msg.sender, address(this));
        address stock = IEthRouterOracle(m.oracle).stock();
        if (asStock && vault != stock) {
            try IEthRouterVault(vault).redeem(shares, msg.sender, address(this)) returns (uint256 a) {
                out = a;
            } catch {
                revert CannotRedeem();
            }
        } else {
            IERC20(vault).safeTransfer(msg.sender, shares);
            out = shares;
        }
        emit Withdrawn(msg.sender, Id.unwrap(m.id()), shares, asStock ? out : 0);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }
}
