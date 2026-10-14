// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Id} from "morpho-blue/interfaces/IMorpho.sol";
import {BorroSetup} from "./BorroSetup.sol";
import {BorroShort} from "../src/BorroShort.sol";
import {IUniswapV3Pool} from "../src/BorroSwap.sol";
import {
    BearVault,
    IBearShort,
    IPonsFactory,
    IPonsFeeVault,
    IUniversalRouter,
    ISwapRouter02,
    IV3PoolOracle,
    PonsLaunch
} from "../src/BearVault.sol";
import {BearFactory} from "../src/BearFactory.sol";

struct Socials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

struct TokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    Socials socials;
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    bytes32 expectedEconomics;
    bytes32 salt;
}

interface IPonsLauncher {
    function launchFee() external view returns (uint256);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken, address[] calldata exempt)
        external
        payable
        returns (address token, address curve);
}

interface IPonsLaunchRouter {
    function launchAndBuy(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve, uint256 tokensOut);
}

interface ICurveBuy {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

/// A vault whose buyback budget a test can set, to drive buy-and-burn on its own.
contract BearVaultHarness is BearVault {
    constructor(Env memory env, bytes32 deskId_, address owner_, address keeper_, Limits memory limits_)
        BearVault(env, deskId_, owner_, keeper_, limits_, address(0))
    {}

    function setBudget(uint256 b) external {
        buybackBudget = b;
    }
}

/// Bear vaults on a fork of Robinhood Chain: the whole Borro system from BorroSetup, the real Pons factory, curve,
/// fee vault and hook, the real WETH/USDG pool and routers. Runs only with BORRO_FORK_RPC set.
abstract contract BearBase is BorroSetup {
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant PONS_FEE_VAULT = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant PONS_GRADUATOR = 0x01D1B5EeC161054Ce2E7De29A1dA53c5c200C654;
    address constant PONS_OPS = 0xDeB70D6327d500Dd7AC527a61F4eE08d208a9588;
    address constant PONS_LAUNCH_ROUTER = 0xe33E9E479dF8802cb0866d5d05258bEc4cF62948;
    address constant PONS_FLUSHER = 0xa1018c1D9655292A2dE0F7dEa9a0F848EaA8cA83;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant WETH_USDG_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    string constant SYM = "TSLA";

    BearFactory bears;
    BearVault vault;
    bytes32 id;
    address tom = makeAddr("tom"); // trades the coin
    address whale = makeAddr("whale"); // shorts TSLA big

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        bears = new BearFactory(_env(), type(BearVault).creationCode, keeper, owner);
        id = desk[SYM].marketId;
        vm.prank(owner);
        vault = BearVault(payable(bears.createVault(id)));
        _lend(SYM, ann, (60_000e6 * 1e20) / _price(SYM)); // about $60K of TSLA to short
        vm.deal(tom, 100 ether);
    }

    function _env() internal view returns (BearVault.Env memory) {
        return BearVault.Env({
            short: IBearShort(address(short)),
            usdg: usdg,
            pons: IPonsFactory(PONS_FACTORY),
            feeVault: IPonsFeeVault(PONS_FEE_VAULT),
            ponsHook: PONS_HOOK,
            universalRouter: IUniversalRouter(UNIVERSAL_ROUTER),
            swapRouter: ISwapRouter02(SWAP_ROUTER02),
            weth: WETH,
            wethUsdgPool: IV3PoolOracle(WETH_USDG_POOL)
        });
    }

    /// Launches a coin on Pons whose creator fees go to `recipient`, 1% creator tax, paired with ETH.
    function _launch(address recipient, string memory symbol) internal returns (address token, address curve) {
        IPonsLauncher f = IPonsLauncher(PONS_FACTORY);
        TokenParams memory p = TokenParams({
            name: symbol,
            symbol: symbol,
            logo: "",
            description: "bear coin test",
            socials: Socials("", "", "", "", ""),
            creatorFeeRecipient: recipient,
            creatorTaxBps: 100,
            buybackEnabled: false,
            expectedEconomics: f.previewLaunchEconomics(0, address(0)),
            salt: keccak256(abi.encode(symbol, recipient, block.timestamp))
        });
        uint256 fee = f.launchFee();
        vm.deal(address(this), address(this).balance + fee);
        (token, curve) = f.launchToken{value: fee}(p, 0, address(0), new address[](0));
        // Past the launch's snipe tax window (a buy in the first moments pays most of it as tax).
        vm.roll(block.number + 600);
        vm.warp(block.timestamp + 1 hours);
    }

    /// Buys past the graduation line, then Pons's own pool maker moves the coin to its v4 pool.
    function _graduate(address coin, address curve) internal {
        _buyCoin(curve, 5 ether);
        vm.deal(PONS_OPS, 1 ether);
        vm.prank(PONS_OPS);
        (bool ok,) = PONS_GRADUATOR.call{value: 0.02 ether, gas: 8_000_000}(
            abi.encodeWithSelector(0x60c1bddf, coin, bytes(""), bytes(""), bytes(""), uint256(0), uint256(0))
        );
        require(ok, "graduation failed");
        require(IPonsFactory(PONS_FACTORY).getLaunchedToken(coin).phase == 2, "not in its pool");
    }

    /// Tom buys the coin with `eth` in its Pons v4 pool, through the Universal Router (the hook takes the creator tax).
    function _poolBuy(address coin, uint256 eth) internal {
        PonsLaunch memory l = IPonsFactory(PONS_FACTORY).getLaunchedToken(coin);
        BearVault.PathKey[] memory path = new BearVault.PathKey[](1);
        path[0] = BearVault.PathKey({intermediateCurrency: coin, fee: l.poolFee, tickSpacing: l.tickSpacing, hooks: PONS_HOOK, hookData: ""});
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            BearVault.ExactInputParams({currencyIn: address(0), path: path, minHopPriceX36: new uint256[](0), amountIn: uint128(eth), amountOutMinimum: 0})
        );
        params[1] = abi.encode(address(0), eth);
        params[2] = abi.encode(coin, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions = hex"070c0f";
        inputs[0] = abi.encode(actions, params);
        vm.prank(tom);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: eth}(hex"10", inputs, block.timestamp);
    }

    function _buyCoin(address curve, uint256 eth) internal {
        vm.prank(tom);
        ICurveBuy(curve).buy{value: eth}(eth, 0, tom);
    }

    /// The stock's price moved to `price` by its feed, fresh now.
    function _feed(uint256 price) internal {
        _setFeed(SYM, price);
    }

    /// Stock wei worth `usd` USDG wei at the feed price.
    function _amountFor(uint256 usd) internal view returns (uint256) {
        return (usd * 1e20) / _price(SYM);
    }

    /// A grow that leaves the position at about 32% of its limit: short a quarter of the deposit's worth.
    function _grow(uint256 deposit) internal returns (uint256 amount) {
        deal(address(usdg), address(vault), usdg.balanceOf(address(vault)) + deposit);
        amount = _amountFor(deposit / 4);
        uint256 q = _quote(id, amount, false);
        vm.prank(keeper);
        vault.grow(deposit, amount, (q * 9_980) / 10_000);
    }

    /// The cap `_checkCost` allows for `shares`: the stock owed at the feed price, plus 3%.
    function _cap(uint256 shares) internal returns (uint256) {
        morpho.accrueInterest(desk[SYM].market);
        (uint128 tsa, uint128 tss, uint128 tba, uint128 tbs,,) = _marketTotals();
        tsa;
        tss;
        uint256 owed = (shares * (uint256(tba) + 1) + (uint256(tbs) + 1e6) - 1) / (uint256(tbs) + 1e6);
        return (((owed * _price(SYM)) / 1e20) * 10_300) / 10_000;
    }

    function _marketTotals() internal view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (
            morpho.market(Id.wrap(id)).totalSupplyAssets,
            morpho.market(Id.wrap(id)).totalSupplyShares,
            morpho.market(Id.wrap(id)).totalBorrowAssets,
            morpho.market(Id.wrap(id)).totalBorrowShares,
            morpho.market(Id.wrap(id)).lastUpdate,
            morpho.market(Id.wrap(id)).fee
        );
    }

    /// Stock sold into the desk's v3 pool until one share sells for `percent` less; the feed set to the new mid.
    function _fallV3(string memory sym, uint256 percent) internal {
        bytes32 did = desk[sym].marketId;
        (,, address pool,,) = short.deskOf(did);
        require(pool != address(0), "not a v3 stock");
        address token = desk[sym].token;
        uint256 target = (_quote(did, 1e18, false) * (100 - percent)) / 100;
        bool zeroForOne = IUniswapV3Pool(pool).token0() == token;
        for (uint256 i; i < 200 && _quote(did, 1e18, false) > target; i++) {
            deal(token, address(this), 100e18);
            IUniswapV3Pool(pool).swap(
                address(this),
                zeroForOne,
                int256(100e18),
                zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341),
                abi.encode(token)
            );
        }
        _setFeed(sym, ((_quote(did, 1e18, false) + _quote(did, 1e18, true)) / 2) * 100);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        IERC20(abi.decode(data, (address))).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    function _capFor(bytes32 did, string memory sym, uint256 shares) internal returns (uint256) {
        morpho.accrueInterest(desk[sym].market);
        uint256 tba = morpho.market(Id.wrap(did)).totalBorrowAssets;
        uint256 tbs = morpho.market(Id.wrap(did)).totalBorrowShares;
        uint256 owed = (shares * (tba + 1) + (tbs + 1e6) - 1) / (tbs + 1e6);
        return (((owed * _price(sym)) / 1e20) * 10_300) / 10_000;
    }

    /// The launch the site sends from the launcher's wallet: Pons's launch router, creator fees to `recipient`, 1%
    /// creator tax, ETH pair, the launcher exempt from the snipe tax on its own dev buy.
    function _selfLaunch(address launcher, address recipient, string memory symbol, uint256 devBuy)
        internal
        returns (address token, address curve, uint256 tokensOut)
    {
        IPonsLauncher f = IPonsLauncher(PONS_FACTORY);
        TokenParams memory p = TokenParams({
            name: symbol,
            symbol: symbol,
            logo: "ipfs://bafkreihc5g6xauzi4h36tcczu6fnludkzuibvsx7rfuxxe26fkmupqp6ha",
            description: "bear coin test",
            socials: Socials("https://x.com/test", "", "", "", ""),
            creatorFeeRecipient: recipient,
            creatorTaxBps: 100,
            buybackEnabled: false,
            expectedEconomics: f.previewLaunchEconomics(0, address(0)),
            salt: keccak256(abi.encode(symbol, launcher, block.timestamp))
        });
        address[] memory exempt = new address[](1);
        exempt[0] = launcher;
        uint256 fee = f.launchFee();
        vm.deal(launcher, launcher.balance + fee + devBuy);
        vm.prank(launcher, launcher);
        (token, curve, tokensOut) = IPonsLaunchRouter(PONS_LAUNCH_ROUTER).launchAndBuy{value: fee + devBuy}(
            p, 0, address(0), devBuy, 0, launcher, exempt
        );
    }

    /// Creator tax a coin's curve holds until Pons's flusher moves it to the fee vault (selector read from the live curve).
    function _accrued(address curve) internal view returns (uint256) {
        (bool ok, bytes memory r) = curve.staticcall(hex"db2bd533");
        require(ok, "accrued read");
        return abi.decode(r, (uint256));
    }

    /// What Pons's bot 0x49bb...73d2 sends (selector 0xe6b71b11 from its transactions): flush a curve's fees.
    function _flush(address curve) internal {
        vm.prank(eve, eve); // anyone may
        (bool ok,) = PONS_FLUSHER.call(abi.encodeWithSelector(0xe6b71b11, curve));
        require(ok, "flush failed");
    }

    receive() external payable {}
}

/// Roles, limits, the coin's binding and fees, the short's guards, and the owner's way out.
contract BearVaultForkTest is BearBase {
    // ------------------------------------------------------------------ setup and roles

    function test_factory_makes_and_lists_vaults() public onFork {
        assertEq(bears.vaults().length, 1);
        assertTrue(bears.isVault(address(vault)));
        assertEq(vault.owner(), owner);
        assertEq(vault.keeper(), keeper);
        assertEq(vault.stock(), desk[SYM].token);
        assertEq(vault.deskId(), id);
        vm.expectRevert(BearFactory.NotVault.selector);
        bears.register(address(1));
        // The code it deploys is BearVault's, byte for byte, and the hash says so.
        assertEq(keccak256(bears.vaultCode()), keccak256(type(BearVault).creationCode));
        assertEq(bears.vaultCodeHash(), keccak256(type(BearVault).creationCode));
        assertEq(keccak256(address(vault).code), keccak256(address(_sameVault()).code), "runs the published code");

        // A launcher makes their own: they own it, Borro's keeper keeps it, default limits.
        address launcher = makeAddr("launcher");
        vm.prank(launcher);
        BearVault mine = BearVault(payable(bears.createVault(desk["NVDA"].marketId)));
        assertEq(mine.owner(), launcher);
        assertEq(mine.keeper(), keeper);
        assertEq(mine.stock(), desk["NVDA"].token);
        assertEq(abi.encode(mine.limits()), abi.encode(bears.defaultLimits()));
        assertEq(bears.vaultCount(), 2);
        // Only a listed desk.
        vm.prank(launcher);
        vm.expectRevert(BearFactory.CreateFailed.selector);
        bears.createVault(bytes32(uint256(1)));

        // The factory's owner may change the keeper new vaults get; never an existing vault's.
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        bears.setKeeper(eve);
        vm.prank(owner);
        bears.setKeeper(eve);
        assertEq(mine.keeper(), keeper);
        vm.prank(launcher);
        assertEq(BearVault(payable(bears.createVault(id))).keeper(), eve);
    }

    /// A vault made straight from BearVault's code, to compare runtime code with the factory's.
    function _sameVault() internal returns (BearVault) {
        return new BearVault(_env(), id, owner, keeper, bears.defaultLimits(), address(bears));
    }

    function test_limits_stay_inside_the_hard_caps() public onFork {
        BearVault.Limits memory l = bears.defaultLimits();
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        vault.setLimits(l);

        BearVault.Limits memory bad = bears.defaultLimits();
        bad.targetUseBps = 6_000; // over 50%
        vm.prank(owner);
        vm.expectRevert(BearVault.BadLimits.selector);
        vault.setLimits(bad);
        bad = bears.defaultLimits();
        bad.slipBps = 600; // over 5%
        vm.prank(owner);
        vm.expectRevert(BearVault.BadLimits.selector);
        vault.setLimits(bad);
        bad = bears.defaultLimits();
        bad.emergencyUseBps = bad.maxUseBps; // must sit above the keeper's line
        vm.prank(owner);
        vm.expectRevert(BearVault.BadLimits.selector);
        vault.setLimits(bad);
        bad = bears.defaultLimits();
        bad.growCooldown = 0;
        vm.prank(owner);
        vm.expectRevert(BearVault.BadLimits.selector);
        vault.setLimits(bad);
        vm.prank(owner);
        vault.setLimits(l);
    }

    function test_only_the_keeper_or_owner_trades_and_pause_stops_them() public onFork {
        deal(address(usdg), address(vault), 300e6);
        uint256 amount = _amountFor(100e6);
        vm.prank(eve);
        vm.expectRevert(BearVault.NotKeeper.selector);
        vault.grow(300e6, amount, 1);
        vm.prank(eve);
        vm.expectRevert(BearVault.NotKeeper.selector);
        vault.swapFees(1, 1);
        vm.prank(eve);
        vm.expectRevert(BearVault.NotKeeper.selector);
        vault.takeProfit(1, 1);
        vm.prank(eve);
        vm.expectRevert(BearVault.NotKeeper.selector);
        vault.buyAndBurn(1, 1, 1);

        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(BearVault.IsPaused.selector);
        vault.grow(300e6, amount, 1);
        vm.prank(owner);
        vault.setPaused(false);
        _grow(300e6);
        assertGt(vault.limitUsedBps(), 0);
    }

    // ------------------------------------------------------------------ the coin and its fees

    function test_bind_coin_checks_pons_record() public onFork {
        (address mine,) = _launch(address(vault), "BEARA");
        (address theirs,) = _launch(eve, "BEARB");
        vm.prank(owner);
        vm.expectRevert(BearVault.NotOurCoin.selector);
        vault.bindCoin(theirs);
        // This test contract launched `mine`, not the vault's owner: only the owner may bind it.
        vm.prank(eve);
        vm.expectRevert(BearVault.NotAllowed.selector);
        vault.bindCoin(mine);
        vm.prank(owner);
        vault.bindCoin(mine);
        assertEq(vault.coin(), mine);
        assertEq(bears.vaultOf(mine), address(vault));
        vm.prank(owner);
        vm.expectRevert(BearVault.AlreadyBound.selector);
        vault.bindCoin(mine);
    }

    /// The site's three steps, from the launcher's own wallet: make the vault, launch on Pons through its launch
    /// router with the vault as creator fee recipient (and a dev buy), then anyone binds it.
    function test_self_launch_then_anyone_binds_and_a_strangers_coin_cannot_take_its_place() public onFork {
        address launcher = makeAddr("launcher");
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        BearVault v = BearVault(payable(bears.createVault(id)));

        // A stranger launches a coin naming the launcher's vault first, hoping to have it bound instead.
        (address junk,) = _launch(address(v), "JUNK");
        vm.prank(eve);
        vm.expectRevert(BearVault.NotAllowed.selector);
        v.bindCoin(junk);

        (address coin,, uint256 devTokens) = _selfLaunch(launcher, address(v), "BEARL", 0.01 ether);
        assertGt(devTokens, 0, "the dev buy landed");
        assertEq(IERC20(coin).balanceOf(launcher), devTokens);
        PonsLaunch memory l = IPonsFactory(PONS_FACTORY).getLaunchedToken(coin);
        assertEq(l.deployer, launcher, "Pons records the launcher as the developer");
        assertEq(l.creatorFeeRecipient, address(v));

        vm.prank(eve); // anyone, e.g. the keeper or a visitor finishing someone's launch
        v.bindCoin(coin);
        assertEq(v.coin(), coin);
        assertEq(bears.vaultOf(coin), address(v));
        vm.prank(launcher);
        vm.expectRevert(BearVault.AlreadyBound.selector);
        v.bindCoin(junk);
    }

    /// Creator tax is taken on every curve buy and held in the curve; Pons's fee flusher (which its own bot calls
    /// every few minutes, and anyone may call) credits it to the fee vault while the coin is still on its curve.
    function test_creator_fees_accrue_on_the_curve_and_reach_the_vault_before_graduation() public onFork {
        address launcher = makeAddr("launcher");
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        BearVault v = BearVault(payable(bears.createVault(id)));
        (address coin, address curve,) = _selfLaunch(launcher, address(v), "BEARF", 0.01 ether);
        v.bindCoin(coin);
        vm.roll(block.number + 600);
        vm.warp(block.timestamp + 1 hours); // past the snipe window
        _buyCoin(curve, 1 ether);
        assertEq(IPonsFeeVault(PONS_FEE_VAULT).balanceOf(address(v)), 0, "held in the curve until flushed");
        assertEq(_accrued(curve), 0.0101 ether, "1% creator tax on 1.01 ETH of buys");
        _flush(curve);
        assertEq(_accrued(curve), 0);
        uint256 owed = IPonsFeeVault(PONS_FEE_VAULT).balanceOf(address(v));
        assertGe(owed, 0.0101 ether, "credited to the vault while the coin bonds");
        assertEq(IPonsFactory(PONS_FACTORY).getLaunchedToken(coin).phase, 0, "still on its curve");
        vm.prank(keeper);
        assertEq(v.claimFees(), owed);
        assertEq(address(v).balance, owed);
    }

    function test_launcher_takes_money_out_only_after_seven_days_in_public() public onFork {
        address launcher = makeAddr("launcher");
        vm.prank(launcher);
        BearVault v = BearVault(payable(bears.createVault(id)));
        vm.deal(address(v), 0.3 ether);
        deal(address(usdg), address(v), 50e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        v.queueReclaim(address(0), 0.3 ether, keeper);
        vm.prank(launcher);
        v.queueReclaim(address(0), 0.3 ether, launcher);
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(launcher);
        vm.expectRevert(BearVault.NotReady.selector);
        v.executeReclaim();
        vm.warp(block.timestamp + 1);
        vm.prank(launcher);
        assertEq(v.executeReclaim(), 0.3 ether);
        assertEq(launcher.balance, 0.3 ether);
        vm.prank(launcher);
        v.queueReclaim(address(usdg), type(uint256).max, launcher);
        vm.warp(block.timestamp + 7 days);
        vm.prank(launcher);
        assertEq(v.executeReclaim(), 50e6, "all there is");
        assertEq(usdg.balanceOf(launcher), 50e6);
    }

    function test_creator_fees_reach_the_vault_and_swap_to_usdg_near_the_average() public onFork {
        (address coin, address curve) = _launch(address(vault), "BEARC");
        vm.prank(owner);
        vault.bindCoin(coin);
        // In the coin's pool the Pons hook takes the creator tax; it is credited in batches, and graduation flushes the curve's.
        _graduate(coin, curve);
        _poolBuy(coin, 3 ether);
        uint256 owed = IPonsFeeVault(PONS_FEE_VAULT).balanceOf(address(vault));
        uint256 pushed = address(vault).balance;
        assertGt(owed + pushed, 0, "the pool's 1% creator tax reached the vault's fee vault account");
        if (owed > 0) {
            vm.prank(eve); // anyone may pull them; they can only land in the vault
            uint256 got = vault.claimFees();
            assertEq(got, owed);
        }
        uint256 eth = address(vault).balance;
        assertGt(eth, 0);

        uint256 fair = vault.usdgForEth(eth);
        vm.prank(keeper);
        vm.expectRevert(); // far under the 30 minute average less 3%
        vault.swapFees(eth, fair / 2);
        vm.prank(keeper);
        uint256 out = vault.swapFees(eth, (fair * 9_700) / 10_000);
        assertEq(usdg.balanceOf(address(vault)), out);
        assertApproxEqRel(out, fair, 0.03e18, "filled near the average");
        vm.prank(keeper);
        vm.expectRevert(BearVault.TooSoon.selector);
        vault.swapFees(1, 0);
    }

    // ------------------------------------------------------------------ the short

    function test_grow_is_bounded_by_feed_price_size_limit_and_cooldown() public onFork {
        deal(address(usdg), address(vault), 3_000e6);
        uint256 amount = _amountFor(300e6);
        uint256 q = _quote(id, amount, false);

        vm.prank(keeper);
        vm.expectRevert(); // a floor far under the feed value less 3% and the fee
        vault.grow(1_000e6, amount, q / 2);

        uint256 tooBig = _amountFor(1_200e6);
        vm.prank(keeper);
        vm.expectRevert(); // more than 1,000 USDG of stock in one grow
        vault.grow(3_000e6, tooBig, 1);

        uint256 tooMuch = _amountFor(900e6);
        uint256 q2 = _quote(id, tooMuch, false);
        vm.prank(keeper);
        vm.expectRevert(); // a short this size on this deposit would use more than 40% of its limit
        vault.grow(100e6, tooMuch, (q2 * 9_980) / 10_000);

        vm.prank(keeper);
        vault.grow(1_000e6, amount, (q * 9_980) / 10_000);
        uint256 use = vault.limitUsedBps();
        assertGt(use, 0);
        assertLe(use, 4_000);
        (uint256 shares,,,,) = short.tabOf(address(vault), id);
        assertGt(shares, 0, "the vault is the shorter on BorroShort");

        vm.prank(keeper);
        vm.expectRevert(BearVault.TooSoon.selector);
        vault.grow(500e6, amount, 1);
    }

    function test_stale_feed_stops_stock_trades() public onFork {
        deal(address(usdg), address(vault), 1_000e6);
        uint256 amount = _amountFor(100e6);
        vm.mockCall(
            stockOf[SYM].feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(_price(SYM)), block.timestamp - 4 hours, block.timestamp - 4 hours, uint80(1))
        );
        vm.prank(keeper);
        vm.expectRevert(BearVault.StaleFeed.selector);
        vault.grow(1_000e6, amount, 1);
    }

    function test_top_up_moves_idle_usdg_in_and_lowers_use() public onFork {
        vm.expectRevert(BearVault.NoPosition.selector);
        vault.topUp(1);
        _grow(600e6);
        uint256 before = vault.limitUsedBps();
        deal(address(usdg), address(vault), 300e6);
        vm.prank(eve);
        vm.expectRevert();
        vault.topUp(301e6);
        vm.prank(eve);
        vault.topUp(300e6);
        assertLt(vault.limitUsedBps(), before);
    }

    function test_reduce_is_open_to_keeper_past_50_and_anyone_past_70() public onFork {
        _grow(600e6);
        uint256 p0 = _price(SYM);
        uint256 use0 = vault.limitUsedBps();
        // The stock rises until the position uses about 55% of its limit.
        _feed((p0 * 5_500) / use0);
        uint256 use = vault.limitUsedBps();
        assertGt(use, 5_000);
        assertLt(use, 7_000);
        (uint256 tShares,,,,) = short.tabOf(address(vault), id);
        uint256 part = tShares / 4;
        uint256 cap = _cap(part);

        vm.prank(eve);
        vm.expectRevert(BearVault.NotAllowed.selector);
        vault.reduce(part, cap);
        vm.prank(keeper);
        vault.reduce(part, cap);
        uint256 useAfter = vault.limitUsedBps();
        assertLt(useAfter, use, "a reduce always leaves the position using less of its limit");

        // Further up: past 70%, anyone may trim, but never with a cost cap over the feed value plus 3%.
        _feed((_price(SYM) * 7_600) / useAfter);
        assertGt(vault.limitUsedBps(), 7_000);
        (tShares,,,,) = short.tabOf(address(vault), id);
        part = tShares / 4;
        cap = _cap(part);
        vm.prank(eve);
        vm.expectRevert();
        vault.reduce(part, cap * 2);
        vm.prank(eve);
        vault.reduce(part, cap);
    }

    // ------------------------------------------------------------------ the owner's way out

    function test_unwind_then_reclaim_after_seven_days_in_public() public onFork {
        _grow(600e6);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        vault.unwind(type(uint256).max);
        vm.prank(owner);
        vault.setPaused(true); // unwinding works while paused
        vm.prank(owner);
        uint256 paid = vault.unwind(type(uint256).max);
        assertGt(paid, 0);
        assertEq(vault.limitUsedBps(), 0);
        uint256 bal = usdg.balanceOf(address(vault));
        assertGt(bal, 0);

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        vault.queueReclaim(address(usdg), bal, eve);
        vm.prank(owner);
        vault.queueReclaim(address(usdg), bal, owner);
        vm.prank(owner);
        vm.expectRevert(BearVault.NotReady.selector);
        vault.executeReclaim();
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(owner);
        vm.expectRevert(BearVault.NotReady.selector);
        vault.executeReclaim();
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        uint256 sent = vault.executeReclaim();
        assertEq(sent, bal);
        assertEq(usdg.balanceOf(owner), bal);
        vm.prank(owner);
        vm.expectRevert(BearVault.NothingQueued.selector);
        vault.executeReclaim();

        // ETH too, and a request can be cancelled.
        vm.deal(address(vault), 1 ether);
        vm.prank(owner);
        vault.queueReclaim(address(0), 1 ether, owner);
        vm.prank(owner);
        vault.cancelReclaim();
        vm.prank(owner);
        vm.expectRevert(BearVault.NothingQueued.selector);
        vault.executeReclaim();
        vm.prank(owner);
        vault.queueReclaim(address(0), 5 ether, owner);
        vm.warp(block.timestamp + 7 days);
        uint256 ownerEth = owner.balance;
        vm.prank(owner);
        assertEq(vault.executeReclaim(), 1 ether, "capped at what is there");
        assertEq(owner.balance - ownerEth, 1 ether);
    }

}

/// Real profit (GME pushed down in its pool), buy and burn on the curve and in the graduated pool.
contract BearBurnForkTest is BearBase {
    // ------------------------------------------------------------------ profit, buy and burn

    function test_profit_buys_the_coin_back_and_burns_it() public onFork {
        // GME trades in one Uniswap v3 pool, which a test can push down for real.
        string memory g = "GME";
        bytes32 gid = desk[g].marketId;
        vm.prank(owner);
        BearVault gv = BearVault(payable(bears.createVault(gid)));
        _lend(g, ann, (20_000e6 * 1e20) / _price(g));
        (address coin, address curve) = _launch(address(gv), "BEARD");
        vm.prank(owner);
        gv.bindCoin(coin);
        _buyCoin(curve, 1 ether);
        _setFeed(g, _price(g)); // GME's feed, fresh as of now (at this fork block its last update is hours old)

        deal(address(usdg), address(gv), 1_500e6);
        uint256 amount = (375e6 * 1e20) / _price(g);
        uint256 q = _quote(gid, amount, false);
        vm.prank(keeper);
        gv.grow(1_500e6, amount, (q * 9_980) / 10_000);
        (uint256 tShares,,,,) = short.tabOf(address(gv), gid);
        uint256 part = tShares / 4;

        // Not in profit yet: refused.
        vm.prank(keeper);
        vm.expectRevert();
        gv.takeProfit(part, type(uint256).max);

        // GME falls 12% in its pool, and the feed follows.
        _fallV3(g, 12);
        uint256 cap = _capFor(gid, g, part);
        vm.prank(keeper);
        uint256 profit = gv.takeProfit(part, cap);
        assertGt(profit, 0, "bought back cheaper than it sold");
        assertEq(gv.buybackBudget(), profit);
        assertLe(gv.limitUsedBps(), 5_000);

        // Buy and burn: guarded by the average ETH price, the budget, and a non-zero coin minimum.
        uint256 spend = profit < 500e6 ? profit : 500e6;
        uint256 fairEth = gv.ethForUsdg(spend);
        vm.prank(keeper);
        vm.expectRevert();
        gv.buyAndBurn(spend, fairEth / 2, 1);
        vm.prank(keeper);
        vm.expectRevert(BearVault.TooBig.selector);
        gv.buyAndBurn(profit + 1, 0, 1);
        uint256 deadBefore = IERC20(coin).balanceOf(DEAD);
        uint256 minEth = (fairEth * 9_700) / 10_000;
        vm.prank(keeper);
        uint256 coins = gv.buyAndBurn(spend, minEth, 1);
        assertGt(coins, 0);
        assertEq(IERC20(coin).balanceOf(DEAD) - deadBefore, coins, "every coin bought went to 0x...dEaD");
        assertEq(gv.buybackBudget(), profit - spend);
        assertEq(IERC20(coin).balanceOf(address(gv)), 0);
    }

    function test_buy_and_burn_in_the_pons_pool_after_graduation() public onFork {
        BearVaultHarness h = new BearVaultHarness(_env(), id, owner, keeper, bears.defaultLimits());
        (address coin, address curve) = _launch(address(h), "BEARE");
        vm.prank(owner);
        h.bindCoin(coin);
        _graduate(coin, curve);
        PonsLaunch memory l = IPonsFactory(PONS_FACTORY).getLaunchedToken(coin);
        assertEq(l.phase, 2);

        deal(address(usdg), address(h), 200e6);
        h.setBudget(200e6);
        uint256 deadBefore = IERC20(coin).balanceOf(DEAD);
        uint256 minEth = (h.ethForUsdg(200e6) * 9_700) / 10_000;
        vm.prank(keeper);
        uint256 coins = h.buyAndBurn(200e6, minEth, 1);
        assertGt(coins, 0);
        assertEq(IERC20(coin).balanceOf(DEAD) - deadBefore, coins);
        assertEq(h.buybackBudget(), 0);
    }

    function test_buy_and_burn_on_the_curve_and_its_guards() public onFork {
        BearVaultHarness h = new BearVaultHarness(_env(), id, owner, keeper, bears.defaultLimits());
        vm.prank(keeper);
        vm.expectRevert(BearVault.NotBound.selector);
        h.buyAndBurn(1, 0, 1);
        (address coin,) = _launch(address(h), "BEARF");
        vm.prank(owner);
        h.bindCoin(coin);
        deal(address(usdg), address(h), 100e6);
        h.setBudget(100e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BearVault.TooLittle.selector, 0, 1));
        h.buyAndBurn(100e6, 0, 0);
        uint256 deadBefore = IERC20(coin).balanceOf(DEAD);
        uint256 minEth = (h.ethForUsdg(100e6) * 9_700) / 10_000;
        vm.prank(keeper);
        uint256 coins = h.buyAndBurn(100e6, minEth, 1);
        assertEq(IERC20(coin).balanceOf(DEAD) - deadBefore, coins);
        vm.prank(keeper);
        vm.expectRevert(BearVault.TooSoon.selector);
        h.buyAndBurn(1, 0, 1);
    }
}
