// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2Factory} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {IMorphoChainlinkOracleV2Factory} from "morpho-oracles/morpho-chainlink/interfaces/IMorphoChainlinkOracleV2Factory.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "morpho-oracles/morpho-chainlink/interfaces/IERC4626.sol";
import {BorroLib} from "../../script/BorroLib.sol";
import {CoinFeed, IUniV3PoolOracle} from "./CoinFeed.sol";
import {EthPrice} from "./EthPrice.sol";
import {PonsLaunch, IPonsFactory, IPonsHook, IPonsLocker, CoinDesk} from "./CoinDeps.sol";

interface ICoinShortCollateral {
    function collateral() external view returns (address);
}

/// The v4 PositionManager, as far as a listing reads it.
interface IPositionManager {
    function ownerOf(uint256 id) external view returns (address);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, PositionInfo);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

/// The coin's Pons curve: launchedAt is the launch block's time, set once in initialize (only the Pons factory may
/// call it, once; checked in its bytecode on 2026-10-06: storage slot 10, written nowhere else).
interface IPonsCurve {
    function launchedAt() external view returns (uint256);
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

/// @title CoinListing
/// @notice Lists a graduated Pons coin for coin shorts, for anyone, in one step, with nothing chosen by the lister:
///         every number below is fixed here (docs/COIN-SHORTS.md). list(coin) checks the coin on chain (launched by
///         Pons, paired with ETH, graduated to its pool, its graduation liquidity locked for good and at least
///         MIN_DEPTH_ETH deep, worth at least MIN_MCAP_USD, launched at least MIN_AGE ago by its Pons curve's
///         launchedAt), then deploys its
///         price feed, its oracle, its Morpho market and its lending vault (the stock vaults' recipe: BorroLib), and
///         hands the vault to the Safe. The lister puts SEED (one coin) into the vault as its first, dead deposit.
///         Nothing can be shorted until the new feed has a price (about 16 minutes of checks).
/// @dev What the owner (the Hoard Safe) can do here: pause new listings. Nothing else. A listed coin cannot be
///      unlisted, and no number can change.
///      Depth is the locked liquidity only: Pons's graduation position, which its locker can never move. Anyone may
///      add liquidity of their own to a Pons pool and take it out again, so that never counts. At listing the new
///      feed has no price yet, so depth is read at the pool's spot price, which a trade can move for a moment; the
///      cap reads it again at the delayed price and is zero while the locked ETH side is under MIN_DEPTH_ETH, so a
///      coin listed on a moved price can never be shorted or borrowed against until it really is that deep.
///      Market cap (total supply times the dollar price) is the same: at listing it is read at the pool's spot price
///      (times ETH's 30-minute average dollar price, as the feeds take it), and the cap reads it again at the delayed
///      price and is zero while it is under MIN_MCAP_USD, so a coin pumped for one block to list, or one that falls
///      under the floor later, takes no new shorts and no new loans. Closing, repaying, withdrawing and liquidating
///      never look at it.
///      Age: Pons records no graduation time, so it is measured from launch: the curve sets launchedAt to the launch
///      block's time once, in initialize, which only the Pons factory may call, once.
contract CoinListing is Ownable2Step {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using MarketParamsLib for MarketParams;
    using PositionInfoLibrary for PositionInfo;

    // ---------------------------------------------------------------- fixed at listing, for every coin
    uint256 public constant LLTV = 0.385e18;
    uint256 public constant CAP_DEPTH_BPS = 200; // shorts on a coin: at most 2% of the locked pool's coin side
    uint256 public constant CAP_USD = 5_000e18; // and at most $5,000, at the delayed price
    uint256 public constant MIN_DEPTH_ETH = 2e18; // the locked pool's ETH side
    uint256 public constant MIN_MCAP_USD = 10_000_000e18; // the coin's market cap: its total supply at its dollar price
    uint256 public constant MIN_AGE = 3 days; // since the coin's launch on Pons
    uint256 public constant MAX_CREATOR_TAX_BPS = 300;
    uint256 public constant MAX_HOOK_FEE_BPS = 200; // Pons's hook fee today: 100 (it may be raised to 1,000)
    uint256 public constant SEED = 1e18; // the dead deposit: one coin
    uint256 public constant VAULT_TIMELOCK = 3 days; // the stock vaults' wait
    uint32 public constant FEED_SPACING = 120;
    uint32 public constant FEED_WINDOW = 1800;
    uint16 public constant FEED_MIN_OBS = 8;
    uint32 public constant FEED_ETH_TWAP = 1800;
    uint8 internal constant GRADUATED = 2;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IPonsFactory public immutable pons;
    address public immutable ponsHook;
    IPonsLocker public immutable locker;
    IUniV3PoolOracle public immutable ethPool;
    address public immutable weth;
    address public immutable usdg;
    address public immutable safe; // gets every coin vault
    address public immutable coinShort;
    EthPrice public immutable ethPrice; // ETH in dollars, as the feeds take it: made here, read before a coin has a feed

    /// Every check, for the site to show before a listing is sent.
    struct Checks {
        bool launchedByPons;
        bool pairedWithEth;
        bool graduated;
        bool decimals18;
        bool taxOk; // the coin's creator tax at most MAX_CREATOR_TAX_BPS
        bool hookFeeOk; // Pons's hook fee at most MAX_HOOK_FEE_BPS
        bool poolLive;
        bool liquidityLocked; // Pons's locker holds a full-range position in this pool, with liquidity
        bool oldEnough; // launched at least MIN_AGE ago
        bool deepEnough; // the locked ETH side at least MIN_DEPTH_ETH at the pool's price now
        bool mcapOk; // the market cap at least MIN_MCAP_USD at the pool's price now
        bool notListed;
        bool open; // listings not paused
        uint256 lockedId;
        uint256 ethDepth; // wei, the locked ETH side at the pool's price now
        uint256 mcapUsd; // dollars (18 decimals): total supply at the pool's price now
        uint256 launchedAt; // the curve's launch time
        uint256 readyAt; // launchedAt + MIN_AGE: when the coin is old enough
    }

    mapping(address coin => CoinDesk) internal _desk;
    address[] public coins;
    bool public paused;

    event Listed(address indexed coin, bytes32 indexed marketId, address feed, address oracle, address vault, address adapter, uint256 lockedId);
    event PausedSet(bool paused);

    error IsPaused();
    error CheckFailed(string what);
    error AlreadyListed();
    error NotListed();

    constructor(
        IPoolManager pm_,
        IPositionManager posm_,
        IPonsFactory pons_,
        IPonsLocker locker_,
        IUniV3PoolOracle ethPool_,
        address weth_,
        address usdg_,
        address safe_,
        address coinShort_
    ) Ownable(safe_) {
        poolManager = pm_;
        positionManager = posm_;
        pons = pons_;
        ponsHook = pons_.memeHook();
        locker = locker_;
        if (pons_.locker() != address(locker_)) revert CheckFailed("locker");
        ethPool = ethPool_;
        weth = weth_;
        usdg = usdg_;
        safe = safe_;
        coinShort = coinShort_;
        ethPrice = new EthPrice(ethPool_, weth_, usdg_, FEED_ETH_TWAP);
    }

    // ------------------------------------------------------------------ owner

    /// @notice Stop or allow new listings. Listed coins are not touched.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ------------------------------------------------------------------ listing

    /// @notice For anyone: check the coin, then deploy its price feed, oracle, market and lending vault. The caller
    ///         pays in the vault's dead deposit: SEED of the coin, approved to this contract.
    function list(address coin) external returns (bytes32 marketId) {
        if (paused) revert IsPaused();
        Checks memory c = checks(coin);
        _require(c.notListed, "not listed");
        _require(c.launchedByPons, "launched by Pons");
        _require(c.pairedWithEth, "paired with ETH");
        _require(c.graduated, "graduated");
        _require(c.decimals18, "18 decimals");
        _require(c.taxOk, "creator tax");
        _require(c.hookFeeOk, "Pons hook fee");
        _require(c.poolLive, "pool live");
        _require(c.liquidityLocked, "liquidity locked");
        _require(c.oldEnough, "3 days since launch");
        _require(c.deepEnough, "locked depth");
        _require(c.mcapOk, "market cap");

        address feed = address(
            new CoinFeed{salt: bytes32(uint256(uint160(coin)))}(
                poolManager, keyOf(coin), ethPool, weth, usdg, FEED_SPACING, FEED_WINDOW, FEED_MIN_OBS, FEED_ETH_TWAP
            )
        );
        address cusdg = ICoinShortCollateral(coinShort).collateral();
        CoinDesk storage d = _desk[coin];
        d.feed = feed;
        d.key = keyOf(coin);
        d.lockedId = c.lockedId;
        d.listedAt = uint64(block.timestamp);

        address oracle = address(
            IMorphoChainlinkOracleV2Factory(BorroLib.ORACLE_FACTORY).createMorphoChainlinkOracleV2(
                IERC4626(BorroLib.HELD), // one Steakhouse share: what it redeems for in USDG (6 decimals)
                1e18,
                AggregatorV3Interface(address(0)),
                AggregatorV3Interface(address(0)),
                6,
                IERC4626(address(0)),
                1,
                AggregatorV3Interface(feed), // over the coin's delayed price in USDG (18 decimals)
                AggregatorV3Interface(address(0)),
                18,
                bytes32(uint256(uint160(coin)))
            )
        );
        d.market = MarketParams({loanToken: coin, collateralToken: cusdg, oracle: oracle, irm: BorroLib.IRM, lltv: LLTV});
        marketId = Id.unwrap(d.market.id());
        IMorpho(BorroLib.MORPHO).createMarket(d.market);

        (address vault, address adapter) = _vault(coin, d.market);
        d.vault = vault;
        coins.push(coin);
        emit Listed(coin, marketId, feed, oracle, vault, adapter, c.lockedId);
    }

    /// @dev The coin's lending vault, as BorroLib.open makes a stock's: this contract sets it up as owner and
    ///      curator, the dead deposit goes in, the risky settings get VAULT_TIMELOCK, and the Safe takes over.
    function _vault(address coin, MarketParams memory market) internal returns (address vault, address adapter) {
        bytes32 salt = bytes32(uint256(uint160(coin)));
        IVaultV2 v = IVaultV2(IVaultV2Factory(BorroLib.VAULT_FACTORY).createVaultV2(address(this), coin, salt));
        vault = address(v);
        string memory sym = IERC20Meta(coin).symbol();
        v.setName(string.concat("Borro ", sym));
        v.setSymbol(string.concat("b", sym));
        v.setCurator(address(this));
        adapter = IMorphoMarketV1AdapterV2Factory(BorroLib.ADAPTER_FACTORY).createMorphoMarketV1AdapterV2(vault);
        _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _now(v, abi.encodeCall(IVaultV2.addAdapter, (adapter)));
        // Lending is not capped below the coin's whole supply: the short cap lives in CoinShort.
        uint256 cap = IERC20Meta(coin).totalSupply();
        bytes[3] memory ids = [
            abi.encode("this", adapter),
            abi.encode("collateralToken", market.collateralToken),
            abi.encode("this/marketParams", adapter, market)
        ];
        for (uint256 i; i < 3; i++) {
            _now(v, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (ids[i], cap)));
            _now(v, abi.encodeCall(IVaultV2.increaseRelativeCap, (ids[i], 1e18)));
        }
        v.setLiquidityAdapterAndData(adapter, abi.encode(market));
        v.setMaxRate(BorroLib.STOCK_MAX_RATE);
        IERC20(coin).safeTransferFrom(msg.sender, address(this), SEED);
        IERC20(coin).forceApprove(vault, SEED);
        v.deposit(SEED, DEAD);
        BorroLib.lock(vault, VAULT_TIMELOCK);
        BorroLib.handOver(vault, address(this), safe);
    }

    function _now(IVaultV2 v, bytes memory data) private {
        v.submit(data);
        (bool ok, bytes memory err) = address(v).call(data);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    function _require(bool ok, string memory what) private pure {
        if (!ok) revert CheckFailed(what);
    }

    // ------------------------------------------------------------------ views

    /// @notice The coin's Pons pool, by Pons's own record. All zero for a coin Pons did not launch.
    function keyOf(address coin) public view returns (PoolKey memory key) {
        PonsLaunch memory l = pons.getLaunchedToken(coin);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: l.poolFee,
            tickSpacing: l.tickSpacing,
            hooks: IHooks(ponsHook)
        });
    }

    /// @notice Every check, passing or not. Never reverts for a coin that is a contract.
    function checks(address coin) public view returns (Checks memory c) {
        c.open = !paused;
        c.notListed = _desk[coin].vault == address(0);
        c.hookFeeOk = IPonsHook(ponsHook).hookFeeBps() <= MAX_HOOK_FEE_BPS;
        if (coin.code.length == 0) return c;

        PonsLaunch memory l;
        try pons.getLaunchedToken(coin) returns (PonsLaunch memory got) {
            l = got;
        } catch {
            return c;
        }
        c.launchedByPons = l.exists && l.token == coin;
        if (!c.launchedByPons) return c;
        c.pairedWithEth = l.pairToken == address(0);
        c.graduated = l.phase == GRADUATED;
        c.taxOk = l.creatorTaxBps <= MAX_CREATOR_TAX_BPS;
        try IPonsCurve(l.curve).launchedAt() returns (uint256 at) {
            c.launchedAt = at;
            c.readyAt = at + MIN_AGE;
            c.oldEnough = at != 0 && block.timestamp >= c.readyAt;
        } catch {}
        try IERC20Meta(coin).decimals() returns (uint8 dec) {
            c.decimals18 = dec == 18;
        } catch {}
        if (!c.pairedWithEth || !c.graduated) return c;

        PoolKey memory key = keyOf(coin);
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        c.poolLive = sqrtP != 0;
        if (c.poolLive) {
            // A whole coin in dollars: the pool's coin wei per ETH wei is sqrtP^2 / 2^192.
            c.mcapUsd = _mcap(coin, Math.mulDiv(Math.mulDiv(ethUsd(), 2 ** 96, sqrtP), 2 ** 96, sqrtP));
            c.mcapOk = c.mcapUsd >= MIN_MCAP_USD;
        }
        (c.liquidityLocked, c.lockedId) = _locked(coin, key);
        if (!c.poolLive || !c.liquidityLocked) return c;
        // The ETH side of a full-range position at the pool's price now: L / sqrt(P), sqrtP in Q96.
        c.ethDepth = Math.mulDiv(positionManager.getPositionLiquidity(c.lockedId), 2 ** 96, sqrtP);
        c.deepEnough = c.ethDepth >= MIN_DEPTH_ETH;
    }

    /// @notice How much of the coin may be shorted in all right now, and the locked pool's coin side, both in coin
    ///         wei at the delayed price. Zero room while the locked ETH side is under MIN_DEPTH_ETH or the market cap
    ///         is under MIN_MCAP_USD at that price; coin loans take their cap from this too. Reverts while the coin's
    ///         feed has no price.
    function capOf(address coin) external view returns (uint256 cap, uint256 depthCoins) {
        CoinDesk storage d = _desk[coin];
        if (d.vault == address(0)) revert NotListed();
        (, int256 answer,,,) = CoinFeed(d.feed).latestRoundData();
        uint256 delayed = uint256(answer);
        uint256 ethSide;
        (ethSide, depthCoins) = _depth(d.lockedId, delayed, CoinFeed(d.feed).ethUsd());
        // Under either floor at the delayed price, no room at all.
        if (ethSide < MIN_DEPTH_ETH || _mcap(coin, delayed) < MIN_MCAP_USD) return (0, depthCoins);
        cap = Math.min((depthCoins * CAP_DEPTH_BPS) / 10_000, Math.mulDiv(CAP_USD, 1e18, delayed));
    }

    /// @notice A listed coin's market cap at its delayed price, in dollars (18 decimals). Reverts while the coin's
    ///         feed has no price.
    function mcapOf(address coin) external view returns (uint256) {
        CoinDesk storage d = _desk[coin];
        if (d.vault == address(0)) revert NotListed();
        (, int256 answer,,,) = CoinFeed(d.feed).latestRoundData();
        return _mcap(coin, uint256(answer));
    }

    /// @notice Dollars per ETH, 18 decimals, from the WETH/USDG pool's own average over FEED_ETH_TWAP: the number
    ///         every coin's feed multiplies by. Zero if the pool cannot say.
    function ethUsd() public view returns (uint256) {
        try ethPrice.ethUsd() returns (uint256 e) {
            return e;
        } catch {
            return 0;
        }
    }

    function deskOf(address coin) external view returns (CoinDesk memory d) {
        d = _desk[coin];
        if (d.vault == address(0)) revert NotListed();
    }

    function coinsLength() external view returns (uint256) {
        return coins.length;
    }

    /// @dev Pons's locker holds the pool's graduation position: a full-range position in exactly this pool, with
    ///      liquidity, and the NFT is the locker's.
    function _locked(address coin, PoolKey memory key) internal view returns (bool ok, uint256 id) {
        try locker.lockedPositions(coin) returns (uint256 got) {
            id = got;
        } catch {
            return (false, 0);
        }
        if (id == 0 || !locker.isLocked(coin)) return (false, id);
        try positionManager.ownerOf(id) returns (address owner) {
            if (owner != address(locker)) return (false, id);
        } catch {
            return (false, id);
        }
        (PoolKey memory k, PositionInfo info) = positionManager.getPoolAndPositionInfo(id);
        if (PoolId.unwrap(k.toId()) != PoolId.unwrap(key.toId())) return (false, id);
        if (info.tickLower() != TickMath.minUsableTick(key.tickSpacing) || info.tickUpper() != TickMath.maxUsableTick(key.tickSpacing)) {
            return (false, id);
        }
        ok = positionManager.getPositionLiquidity(id) != 0;
    }

    /// @dev Total supply times a dollar price for a whole coin (18 decimals); zero for a coin that will not say.
    function _mcap(address coin, uint256 coinUsd) internal view returns (uint256) {
        try IERC20Meta(coin).totalSupply() returns (uint256 s) {
            return Math.mulDiv(s, coinUsd, 1e18);
        } catch {
            return 0;
        }
    }

    /// @dev The locked full-range position's two sides at the delayed price (coin and ETH both 18 decimals; prices
    ///      in dollars with 18 decimals): with P coin per ETH, x = L / sqrt(P) ETH and y = L * sqrt(P) coin.
    function _depth(uint256 lockedId, uint256 coinUsd, uint256 ethUsd_) internal view returns (uint256 ethSide, uint256 coinSide) {
        uint256 L = positionManager.getPositionLiquidity(lockedId);
        uint256 sqrtP = Math.sqrt(Math.mulDiv(ethUsd_, 1e36, coinUsd)); // sqrt(P) * 1e18
        if (sqrtP == 0) return (0, 0);
        ethSide = Math.mulDiv(L, 1e18, sqrtP);
        coinSide = Math.mulDiv(L, sqrtP, 1e18);
    }
}
