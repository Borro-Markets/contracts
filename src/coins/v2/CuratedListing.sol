// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2Factory} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {IMorphoChainlinkOracleV2Factory} from "morpho-oracles/morpho-chainlink/interfaces/IMorphoChainlinkOracleV2Factory.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "morpho-oracles/morpho-chainlink/interfaces/IERC4626.sol";
import {BorroLib} from "../../../script/BorroLib.sol";
import {CoinLens} from "./CoinLens.sol";
import {CuratedFeeds} from "./CuratedFeeds.sol";
import {Venue, CuratedDesk, ICoinFeed, IV3Pool, VENUE_V3} from "./VenueDeps.sol";

interface ICuratedCollateral {
    function collateral() external view returns (address);
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

/// @title CuratedListing
/// @notice Lists coins the Safe has allowed, wherever they trade on Uniswap, for curated coin shorts and coin loans
///         (docs/COIN-SHORTS.md, phase 2). Beside the Pons-only coin shorts (contracts/src/coins), which it never
///         touches. Two steps: the Safe allows a coin with its venue (the pool it trades and is priced in, and its
///         pair) and a cap at most CAP_USD; then anyone lists it, if on chain at the pool's price now it is worth at
///         least MIN_MCAP_USD and its pool is at least MIN_DEPTH_USD deep each way within a 10% move. Listing makes
///         the coin's delayed price feed, its oracle, its Morpho market and its lending vault, which goes to the Safe;
///         the lister puts about a dollar of the coin into the vault for good.
/// @dev What the Safe can do here: allow a coin that is not listed yet (with its venue and cap), and pause new
///      listings. Nothing else: once listed, a coin's venue, cap and every number are fixed, and it cannot be
///      unlisted. The caps read depth and market cap again at the delayed price and give no room at all under
///      either floor, so a coin listed on a moved price, or one that falls under a floor later, takes no new shorts
///      and no new loans; closing, repaying and liquidating never look.
///      Depth is the pool's live liquidity (CoinLens walks its ticks), so it counts liquidity anyone could take out;
///      the Safe's vetting (keeper/tools/vet-coin.mjs) says who holds it, and a coin whose liquidity can be pulled is
///      allowed with a cap sized to what cannot be, or not at all.
contract CuratedListing is Ownable2Step {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    uint256 public constant LLTV = 0.385e18;
    uint256 public constant CAP_DEPTH_BPS = 200; // shorts: at most 2% of what the pool gives up in a 10% rise
    uint256 public constant LOAN_DEPTH_BPS = 200; // loans: at most 2% of what it takes in during a 10% fall
    uint256 public constant CAP_USD = 5_000e18; // and at most $5,000 each, or the coin's own lower cap
    uint256 public constant MIN_MCAP_USD = 10_000_000e18;
    uint256 public constant MIN_DEPTH_USD = 10_000e18; // each way, within a 10% move
    uint256 public constant SEED_USD = 1e18; // the lister's dead deposit: about a dollar of the coin
    uint256 public constant VAULT_TIMELOCK = 3 days;
    uint16 public constant MIN_CARDINALITY = 1801; // v3 observation slots: 30 minutes at one a second
    uint16 public constant GROW_STEP = 400; // slots a listing adds at most (about 9M gas); anyone may add more
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    CoinLens public immutable lens;
    CuratedFeeds public immutable feeds;
    address public immutable usdg;
    address public immutable safe; // gets every coin vault
    address public immutable curatedShort;

    struct Allowed {
        Venue venue;
        uint256 capUsd; // this coin's own cap, at most CAP_USD
        bool set;
    }

    /// Every check, for the site and the Safe to see before a listing is sent.
    struct Checks {
        bool allowed;
        bool notListed;
        bool open; // listings not paused
        bool venueOk; // the pool is real and holds the coin against the named pair
        bool decimals18;
        bool poolLive;
        bool mcapOk; // worth at least MIN_MCAP_USD at the pool's price now
        bool deepEnough; // at least MIN_DEPTH_USD each way within a 10% move, at the pool's price now
        uint256 mcapUsd;
        uint256 spotUsd;
        uint256 upUsd; // dollars of the coin the pool gives up in a 10% rise
        uint256 downUsd; // dollars of the coin it takes in during a 10% fall
        uint256 capUsd;
        string why; // the venue's problem, if it has one
    }

    mapping(address coin => Allowed) internal _allowed;
    mapping(address coin => CuratedDesk) internal _desk;
    mapping(address coin => uint256) public capUsdOf;
    address[] public coins;
    bool public paused;

    event Allowed_(address indexed coin, Venue venue, uint256 capUsd);
    event Listed(address indexed coin, bytes32 indexed marketId, address feed, address oracle, address vault, address adapter);
    event PausedSet(bool paused);

    error IsPaused();
    error CheckFailed(string what);
    error AlreadyListed();
    error NotListed();
    error NotAllowed();
    error BadCap();

    constructor(CoinLens lens_, CuratedFeeds feeds_, address usdg_, address safe_, address curatedShort_) Ownable(safe_) {
        lens = lens_;
        feeds = feeds_;
        usdg = usdg_;
        safe = safe_;
        curatedShort = curatedShort_;
    }

    // ------------------------------------------------------------------ the Safe

    /// @notice Allow a coin that is not listed yet, with where it trades and its cap (at most CAP_USD). Allowing it
    ///         again before it lists replaces both; once it lists, nothing about it can change.
    function allow(address coin, Venue calldata venue, uint256 capUsd) external onlyOwner {
        if (_desk[coin].vault != address(0)) revert AlreadyListed();
        if (capUsd == 0 || capUsd > CAP_USD) revert BadCap();
        (bool ok, string memory why) = lens.check(coin, venue);
        if (!ok) revert CheckFailed(why);
        if (IERC20Meta(coin).decimals() != 18) revert CheckFailed("18 decimals");
        _allowed[coin] = Allowed(venue, capUsd, true);
        emit Allowed_(coin, venue, capUsd);
    }

    /// @notice Stop or allow new listings. Listed coins are not touched.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ------------------------------------------------------------------ listing

    /// @notice For anyone: list an allowed coin that passes every check now. The caller pays in the vault's dead
    ///         deposit, about a dollar of the coin (seedOf), approved to this contract.
    function list(address coin) external returns (bytes32 marketId) {
        if (paused) revert IsPaused();
        Checks memory c = checks(coin);
        if (!c.notListed) revert AlreadyListed();
        if (!c.allowed) revert NotAllowed();
        if (!c.venueOk) revert CheckFailed(c.why);
        if (!c.decimals18) revert CheckFailed("18 decimals");
        if (!c.poolLive) revert CheckFailed("pool live");
        if (!c.mcapOk) revert CheckFailed("market cap");
        if (!c.deepEnough) revert CheckFailed("depth");
        Allowed storage a = _allowed[coin];
        Venue memory v = a.venue;
        if (v.kind == VENUE_V3) {
            // The pool's own history needs MIN_CARDINALITY slots before shorts open; each slot costs a storage
            // write, so a listing adds at most GROW_STEP and anyone can add the rest at the pool itself.
            (,,,, uint16 next,,) = IV3Pool(v.pool).slot0();
            if (next < MIN_CARDINALITY) {
                IV3Pool(v.pool).increaseObservationCardinalityNext(next + GROW_STEP < MIN_CARDINALITY ? next + GROW_STEP : MIN_CARDINALITY);
            }
        }
        address feed = feeds.make(coin, v);
        CuratedDesk storage d = _desk[coin];
        d.venue = v;
        d.feed = feed;
        d.listedAt = uint64(block.timestamp);
        capUsdOf[coin] = a.capUsd;

        bytes32 salt = bytes32(uint256(uint160(coin)));
        address oracle = address(
            IMorphoChainlinkOracleV2Factory(BorroLib.ORACLE_FACTORY).createMorphoChainlinkOracleV2(
                IERC4626(BorroLib.HELD), // one Steakhouse share: what it redeems for in USDG (6 decimals)
                1e18,
                AggregatorV3Interface(address(0)),
                AggregatorV3Interface(address(0)),
                6,
                IERC4626(address(0)),
                1,
                AggregatorV3Interface(feed), // over the coin's delayed price in dollars (18 decimals)
                AggregatorV3Interface(address(0)),
                18,
                salt
            )
        );
        address cusdg = ICuratedCollateral(curatedShort).collateral();
        d.market = MarketParams({loanToken: coin, collateralToken: cusdg, oracle: oracle, irm: BorroLib.IRM, lltv: LLTV});
        marketId = Id.unwrap(d.market.id());
        IMorpho(BorroLib.MORPHO).createMarket(d.market);
        (address vault, address adapter) = _vault(coin, d.market, Math.mulDiv(SEED_USD, 1e18, c.spotUsd));
        d.vault = vault;
        coins.push(coin);
        emit Listed(coin, marketId, feed, oracle, vault, adapter);
    }

    /// @dev The coin's lending vault, as BorroLib.open makes a stock's: this contract sets it up as owner and
    ///      curator, the dead deposit goes in, the risky settings get VAULT_TIMELOCK, and the Safe takes over.
    function _vault(address coin, MarketParams memory market, uint256 seed) internal returns (address vault, address adapter) {
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
        // Lending is not capped below the coin's whole supply: the short cap lives in CuratedShort.
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
        if (seed == 0) seed = 1;
        IERC20(coin).safeTransferFrom(msg.sender, address(this), seed);
        IERC20(coin).forceApprove(vault, seed);
        v.deposit(seed, DEAD);
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

    // ------------------------------------------------------------------ views

    /// @notice Every check, passing or not. Never reverts for a coin that is a contract.
    function checks(address coin) public view returns (Checks memory c) {
        c.open = !paused;
        c.notListed = _desk[coin].vault == address(0);
        Allowed storage a = _allowed[coin];
        c.allowed = a.set;
        if (!a.set || coin.code.length == 0) return c;
        c.capUsd = a.capUsd;
        Venue memory v = a.venue;
        (c.venueOk, c.why) = lens.check(coin, v);
        try IERC20Meta(coin).decimals() returns (uint8 d) {
            c.decimals18 = d == 18;
        } catch {}
        if (!c.venueOk || !c.decimals18) return c;
        c.spotUsd = lens.spotUsd(coin, v);
        c.poolLive = c.spotUsd != 0;
        if (!c.poolLive) return c;
        c.mcapUsd = lens.mcap(coin, c.spotUsd);
        c.mcapOk = c.mcapUsd >= MIN_MCAP_USD;
        (uint256 up, uint256 down) = lens.depth(coin, v, c.spotUsd);
        c.upUsd = Math.mulDiv(up, c.spotUsd, 1e18);
        c.downUsd = Math.mulDiv(down, c.spotUsd, 1e18);
        c.deepEnough = c.upUsd >= MIN_DEPTH_USD && c.downUsd >= MIN_DEPTH_USD;
    }

    /// @notice What the pool gives up in a 10% rise (up) and takes in during a 10% fall (down), in coins, at the
    ///         coin's delayed price; that price; and whether the coin clears both floors there. Reverts while the
    ///         coin's feed has no price.
    function depthOf(address coin) public view returns (uint256 up, uint256 down, uint256 delayed, bool floorsOk) {
        CuratedDesk storage d = _desk[coin];
        if (d.vault == address(0)) revert NotListed();
        (, int256 answer,,,) = ICoinFeed(d.feed).latestRoundData();
        delayed = uint256(answer);
        (up, down) = lens.depth(coin, d.venue, delayed);
        floorsOk = lens.mcap(coin, delayed) >= MIN_MCAP_USD && Math.mulDiv(up, delayed, 1e18) >= MIN_DEPTH_USD
            && Math.mulDiv(down, delayed, 1e18) >= MIN_DEPTH_USD;
    }

    /// @notice How much of the coin may be shorted in all now (coin wei), and what the pool gives up in a 10% rise.
    ///         No room under either floor. Reverts while the coin's feed has no price.
    function capOf(address coin) external view returns (uint256 cap, uint256 depthCoins) {
        (uint256 up,, uint256 delayed, bool ok) = depthOf(coin);
        depthCoins = up;
        if (ok) cap = Math.min((up * CAP_DEPTH_BPS) / 10_000, Math.mulDiv(capUsdOf[coin], 1e18, delayed));
    }

    /// @notice USDG (6 decimals) that may be lent against the coin in all now, and the dollars (18 decimals) the
    ///         pool takes in during a 10% fall. No room under either floor. Reverts while the feed has no price.
    function loanCapOf(address coin) external view returns (uint256 cap, uint256 downUsd) {
        (, uint256 down, uint256 delayed, bool ok) = depthOf(coin);
        downUsd = Math.mulDiv(down, delayed, 1e18);
        if (ok) cap = Math.min((downUsd * LOAN_DEPTH_BPS) / 10_000, capUsdOf[coin]) / 1e12;
    }

    /// @notice A listed coin's market cap at its delayed price, in dollars (18 decimals).
    function mcapOf(address coin) external view returns (uint256) {
        CuratedDesk storage d = _desk[coin];
        if (d.vault == address(0)) revert NotListed();
        (, int256 answer,,,) = ICoinFeed(d.feed).latestRoundData();
        return lens.mcap(coin, uint256(answer));
    }

    /// @notice The venue and cap the Safe allowed for a coin, listed or not.
    function allowedOf(address coin) external view returns (Venue memory venue, uint256 capUsd, bool set) {
        Allowed storage a = _allowed[coin];
        return (a.venue, a.capUsd, a.set);
    }

    /// @notice The dead deposit listing would take now: about a dollar of the coin at the pool's price.
    function seedOf(address coin) external view returns (uint256) {
        uint256 s = lens.spotUsd(coin, _allowed[coin].venue);
        return s == 0 ? 0 : Math.mulDiv(SEED_USD, 1e18, s);
    }

    function deskOf(address coin) external view returns (CuratedDesk memory d) {
        d = _desk[coin];
        if (d.vault == address(0)) revert NotListed();
    }

    function coinsLength() external view returns (uint256) {
        return coins.length;
    }
}
