// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {CoinFeed, IUniV3PoolOracle} from "../../src/coins/CoinFeed.sol";
import {CoinListing, IPositionManager} from "../../src/coins/CoinListing.sol";
import {CoinShort, IHeld} from "../../src/coins/CoinShort.sol";
import {CoinLiquidator, IHeldRedeem} from "../../src/coins/CoinLiquidator.sol";
import {CoinCollateral} from "../../src/coins/CoinCollateral.sol";
import {IPonsFactory, IPonsLocker, IWETH, IUniswapV3PoolSwap, ICoinListing, CoinDesk} from "../../src/coins/CoinDeps.sol";
import {PoolTrader, McapKnob} from "./CoinFeed.fork.t.sol";

/// Random traffic against coin shorts on a copy of the live chain. Every way out is tried as it comes, and every
/// try that fails is counted.
contract CoinShortsHandler is Test {
    using MarketParamsLib for MarketParams;

    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    CoinListing public listing;
    CoinShort public short;
    CoinLiquidator public liq;
    PoolTrader public trader;
    CoinDesk public d;
    address[3] public actors;
    address public keeper = makeAddr("inv keeper");
    address public stranger = makeAddr("inv stranger");

    uint256 public capBreaches; // opens that left the coin's shorts over its cap
    uint256 public closeFailures; // full closes that did not go through
    uint256 public strangerWins; // a stranger's call that moved something it should not
    uint256 public opens;
    uint256 public closes;
    uint256 public liquidations;
    mapping(bytes4 => uint256) public openFail; // why opens were refused
    bytes4[] public failKinds;

    constructor(CoinListing l, CoinShort s, CoinLiquidator q, PoolTrader t) {
        (listing, short, liq, trader) = (l, s, q, t);
        d = listing.deskOf(address(BORRO));
        actors = [makeAddr("inv a"), makeAddr("inv b"), makeAddr("inv c")];
        for (uint256 i; i < 3; i++) {
            vm.prank(actors[i]);
            USDG.approve(address(short), type(uint256).max);
        }
    }

    function desk() external view returns (CoinDesk memory) {
        return d;
    }

    function _feed() internal view returns (CoinFeed) {
        return CoinFeed(d.feed);
    }

    function _steps(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.warp(vm.getBlockTimestamp() + 15);
            vm.roll(vm.getBlockNumber() + 1);
            _feed().poke();
        }
    }

    function open(uint256 who, uint256 size, uint256 ltv) external {
        address a = actors[who % 3];
        (bool okPrice,) = _tryPrice();
        if (!okPrice) return;
        (uint256 cap,) = listing.capOf(address(BORRO));
        uint256 owed = MORPHO.market(d.market.id()).totalBorrowAssets;
        uint256 room = cap > owed ? cap - owed : 0;
        uint256 borrow = size % 5 == 0 ? room + 1e18 : bound(size, 1e18, room / 2 + 1e18); // over the cap one time in five, on purpose
        uint256 ltvBps = bound(ltv, 800, 1_900);
        (, int256 p,,,) = _feed().latestRoundData();
        uint256 debtUsd = (borrow * uint256(p)) / 1e30 + 1;
        uint256 deposit = (debtUsd * 10_000) / ltvBps;
        deal(address(USDG), a, USDG.balanceOf(a) + deposit);
        vm.prank(a);
        try short.open(address(BORRO), deposit, borrow, 0, block.timestamp + 1) {
            opens++;
            uint256 after_ = MORPHO.market(d.market.id()).totalBorrowAssets;
            if (after_ > cap + 1) capBreaches++;
        } catch (bytes memory err) {
            bytes4 k = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (openFail[k] == 0) failKinds.push(k);
            openFail[k]++;
        }
    }

    function close(uint256 who) external {
        address a = actors[who % 3];
        address acct = short.accountOf(a);
        if (acct.code.length == 0) return;
        Position memory pos = MORPHO.position(d.market.id(), acct);
        if (pos.borrowShares == 0 && pos.collateral == 0) return;
        deal(address(USDG), a, USDG.balanceOf(a) + 100_000e6); // enough to cover any loss
        vm.prank(a);
        try short.close(address(BORRO), type(uint256).max, type(uint256).max, 100_000e6, type(uint256).max, block.timestamp + 1) {
            closes++;
        } catch {
            closeFailures++;
        }
    }

    function addDeposit(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        if (short.accountOf(a).code.length == 0) return;
        amount = bound(amount, 1e6, 500e6);
        deal(address(USDG), a, USDG.balanceOf(a) + amount);
        vm.prank(a);
        short.addDeposit(address(BORRO), amount); // must never fail
    }

    function takeDeposit(uint256 who, uint256 part) external {
        address a = actors[who % 3];
        address acct = short.accountOf(a);
        if (acct.code.length == 0) return;
        uint256 col = MORPHO.position(d.market.id(), acct).collateral;
        if (col == 0) return;
        vm.prank(a);
        try short.takeDeposit(address(BORRO), (col * bound(part, 1, 100)) / 1_000) {} catch {}
    }

    function pump(uint256 eth) external {
        eth = bound(eth, 0.005 ether, 0.4 ether); // up to about +20%: shorts still open between moves
        trader.buy(eth);
    }

    function dump(uint256 coins) external {
        coins = bound(coins, 1_000e18, 15_000_000e18);
        deal(address(BORRO), address(trader), coins);
        trader.sell(coins);
    }

    /// A squeeze: a big buy that holds while the delayed price follows, so shorts reach liquidation.
    function squeeze(uint256 eth) external {
        trader.buy(bound(eth, 1 ether, 6 ether));
        _steps(75);
    }

    function wait(uint256 n) external {
        _steps(bound(n, 1, 80));
    }

    function liquidate(uint256 who) external {
        address acct = short.accountOf(actors[who % 3]);
        if (acct.code.length == 0) return;
        (bool okPrice,) = _tryPrice();
        if (!okPrice) return;
        (uint256 seize, uint256 rep) = liq.plan(d.market, acct);
        if (seize == 0 && rep == 0) return;
        vm.prank(keeper);
        try liq.liquidate(address(BORRO), acct, 0, keeper) {
            liquidations++;
        } catch {}
    }

    function safePauses(bool all, uint256 seed) external {
        bool on = seed % 4 == 0; // paused a quarter of the time, so traffic still flows
        vm.prank(SAFE);
        if (all) short.pauseAll(on);
        else short.pause(address(BORRO), on);
    }

    /// A stranger tries the doors that must stay shut.
    function strangerTries(uint256 which) external {
        which = which % 6;
        vm.startPrank(stranger);
        bool ok;
        if (which == 0) (ok,) = address(short).call(abi.encodeCall(short.onMorphoRepay, (1, abi.encode(short.accountOf(actors[0]), address(BORRO), 1, type(uint256).max))));
        else if (which == 1) (ok,) = address(short).call(abi.encodeCall(short.onMorphoSupplyCollateral, (1, abi.encode(short.accountOf(actors[0]), address(BORRO), 1, 0, 0))));
        else if (which == 2) (ok,) = address(short).call(abi.encodeCall(short.unlockCallback, (abi.encode(d.key, 1, true, false))));
        else if (which == 3) (ok,) = address(short).call(abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", int256(-1), int256(1e9), abi.encode(1, true, false)));
        else if (which == 4) (ok,) = address(short.collateral()).call(abi.encodeCall(CoinCollateral.wrap, (1, stranger)));
        else (ok,) = address(liq).call(abi.encodeCall(liq.onMorphoLiquidate, (1, abi.encode(address(BORRO)))));
        vm.stopPrank();
        if (ok) strangerWins++;
    }

    function failKindsLength() external view returns (uint256) {
        return failKinds.length;
    }

    function _tryPrice() internal view returns (bool ok, uint256 p) {
        try _feed().latestRoundData() returns (uint80, int256 a, uint256, uint256, uint80) {
            return (true, uint256(a));
        } catch {
            return (false, 0);
        }
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract CoinShortsInvariantTest is McapKnob {
    using MarketParamsLib for MarketParams;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant LOCKER = 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant HELD = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    IERC20 constant BORRO = IERC20(0x89B76DCDDa801f2e456765742C64950eB2A0c93C);
    bytes32 constant NVDA_MARKET = 0x7ff4053d7caa99de7aa19febadcc2178377e8a31b163046539d6fb35c5abc08b;

    CoinShortsHandler h;
    CoinListing listing;
    CoinShort short;
    CoinLiquidator liq;
    Market nvda0;
    uint256 safeUsdg0;
    uint256 safeBorro0;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        listing = new CoinListing(PM, IPositionManager(POSM), IPonsFactory(PONS), IPonsLocker(LOCKER), IUniV3PoolOracle(ETH_POOL), WETH, address(USDG), SAFE, predicted);
        short = new CoinShort(MORPHO, PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), USDG, IHeld(HELD), ICoinListing(address(listing)), PONS_HOOK, SAFE);
        liq = new CoinLiquidator(MORPHO, PM, IUniswapV3PoolSwap(ETH_POOL), IWETH(WETH), USDG, IHeldRedeem(HELD), ICoinListing(address(listing)));
        if (vm.getBlockTimestamp() < 1791227460 + 3 days) vm.warp(1791227460 + 3 days + 1); // $BORRO three days old
        _mcapTo(address(BORRO), listing.checks(address(BORRO)).mcapUsd, 15_000_000e18); // over the $10M floor
        deal(address(BORRO), address(this), 1e18);
        BORRO.approve(address(listing), 1e18);
        listing.list(address(BORRO));
        CoinDesk memory d = listing.deskOf(address(BORRO));
        for (uint256 i; i < 72; i++) {
            vm.warp(vm.getBlockTimestamp() + 15);
            vm.roll(vm.getBlockNumber() + 1);
            CoinFeed(d.feed).poke();
        }
        address lender = makeAddr("inv lender");
        deal(address(BORRO), lender, 40_000_000e18);
        vm.startPrank(lender);
        BORRO.approve(d.vault, type(uint256).max);
        IVaultV2(d.vault).deposit(40_000_000e18, lender);
        vm.stopPrank();

        PoolTrader trader = new PoolTrader(PM, listing.keyOf(address(BORRO)));
        vm.deal(address(trader), 10_000 ether);
        h = new CoinShortsHandler(listing, short, liq, trader);
        nvda0 = MORPHO.market(Id.wrap(NVDA_MARKET));
        safeUsdg0 = USDG.balanceOf(SAFE);
        safeBorro0 = BORRO.balanceOf(SAFE);
        targetContract(address(h));
    }

    function _skipUnlessForked() internal {
        if (!forked) vm.skip(true);
    }

    function _empty(address who) internal view {
        assertEq(USDG.balanceOf(who), 0);
        assertEq(BORRO.balanceOf(who), 0);
        assertEq(IERC20(HELD).balanceOf(who), 0);
        assertEq(IERC20(address(short.collateral())).balanceOf(who), 0);
        assertEq(IERC20(WETH).balanceOf(who), 0);
        assertEq(who.balance, 0);
    }

    /// The contracts hold nothing between transactions.
    function invariant_nothing_is_held_between_transactions() public {
        _skipUnlessForked();
        _empty(address(short));
        _empty(address(liq));
        _empty(address(listing));
    }

    /// Every cUSDG is backed one for one, and all of Morpho's cUSDG sits on CoinShort accounts.
    function invariant_collateral_is_backed_and_only_on_coinshort_accounts() public {
        _skipUnlessForked();
        CoinCollateral c = short.collateral();
        assertEq(IERC20(HELD).balanceOf(address(c)), c.totalSupply());
        CoinDesk memory d = h.desk();
        uint256 onAccounts;
        for (uint256 i; i < 3; i++) onAccounts += MORPHO.position(d.market.id(), short.accountOf(h.actors(i))).collateral;
        assertEq(IERC20(address(c)).balanceOf(address(MORPHO)), onAccounts);
    }

    /// Opens never took a coin's shorts over its cap; every full close went through; strangers got nowhere.
    function invariant_caps_closes_and_doors() public {
        _skipUnlessForked();
        assertEq(h.capBreaches(), 0, "cap breached");
        assertEq(h.closeFailures(), 0, "a close failed");
        assertEq(h.strangerWins(), 0, "a stranger got through");
    }

    /// Nothing outside the coin's market moved, and the Safe never received anyone's money.
    function invariant_isolated_and_the_safe_takes_nothing() public {
        _skipUnlessForked();
        Market memory n = MORPHO.market(Id.wrap(NVDA_MARKET));
        assertEq(n.totalSupplyAssets, nvda0.totalSupplyAssets);
        assertEq(n.totalBorrowAssets, nvda0.totalBorrowAssets);
        assertEq(USDG.balanceOf(SAFE), safeUsdg0);
        assertEq(BORRO.balanceOf(SAFE), safeBorro0);
    }

    function test_handler_opens_and_closes() public {
        _skipUnlessForked();
        h.open(0, 1_000_000e18 + 1, 1_500);
        assertEq(h.opens(), 1, "an open went through");
        h.close(0);
        assertEq(h.closes(), 1, "a close went through");
    }

    /// What the runs did, so a pass means something: opens, closes and liquidations that went through.
    function afterInvariant() public {
        if (!forked) return;
        vm.writeLine(
            "script/out/coin-shorts-invariant-tally.txt",
            string.concat("opens ", vm.toString(h.opens()), " closes ", vm.toString(h.closes()), " liquidations ", vm.toString(h.liquidations()))
        );
        for (uint256 i; i < h.failKindsLength(); i++) {
            bytes4 k = h.failKinds(i);
            vm.writeLine("script/out/coin-shorts-invariant-tally.txt", string.concat("fail ", vm.toString(abi.encodePacked(k)), " x", vm.toString(h.openFail(k))));
        }
    }
}
