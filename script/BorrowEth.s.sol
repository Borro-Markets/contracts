// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2Factory} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {StockEthOracle, IShareVault, IChainlinkFeed, IEthUsd} from "../src/eth/StockEthOracle.sol";
import {EthLoanLiquidator, IEthLoanDesks} from "../src/eth/EthLoanLiquidator.sol";
import {EthLoanRouter, IEthLoanWeth} from "../src/eth/EthLoanRouter.sol";
import {BorroLib} from "./BorroLib.sol";

/// Deploys Borrow ETH (docs/BORROW-ETH.md): EthLoanLiquidator, one StockEthOracle and one Morpho market per desk stock
/// (loan WETH, collateral the stock's live Borro vault share), the Borro ETH lending vault (bETH, a Morpho Vault V2 with
/// one market adapter, caps, a 10% fee to the owner, 3-day waits) handed to the Hoard Safe, and EthLoanRouter with the
/// nine markets listed, its ownership offered to the Safe (it must accept).
///
/// Every number the owner has not decided yet is a setting, with the recommended value as the default:
///   LLTV               every market's LLTV, WAD (default 385000000000000000 = 38.5%); LLTV_<SYMBOL> overrides one
///   CAP_TOTAL          the most bETH lends in all, WETH wei (default 10 ETH)
///   CAP_BIG / BIG      per market for the stocks in BIG (default 2 ETH for SPY,QQQ,NVDA)
///   CAP_SMALL          per market for the others (default 1 ETH). The deposit market (SPY) is raised to the sum of the
///                      others, as on bUSDG, so a deposit never stops while there is room elsewhere.
///   WEEKEND_LIQ        1 (default): oracles name the liquidator, so loans can be closed out at weekends with the stock
///                      counted 5% above its last close; 0: oracles name nobody, no liquidation at all while closed
///   DEAD_DEPOSITS      0 (default): none. 1: 0.0001 WETH into bETH and 0.00001 WETH into each market for 0xdEaD,
///                      wrapped from the deployer's ETH; permanent, so only with the owner's explicit yes. bETH must not be
///                      opened to lenders before they are in (the site stays hidden until config names the vault).
///   OWNER              default the Hoard Safe; KEEPER default the live keeper (an allocator on bETH, as on bUSDG)
///   TIMELOCK           seconds, default 259200 (3 days)
/// The Safe's own seed (if the owner says yes) is not in this script: it is the Safe's money, deposited by the Safe itself
/// (WETH approve, then bETH deposit), and it can be redeemed like any lender's.
///
///   forge script script/BorrowEth.s.sol --rpc-url $RPC --sender <deployer>                (dry run, sends nothing)
///   ... --broadcast --slow --private-key $(cat ~/.config/borro/deployer_key)               (for real: the owner, via the .sh)
contract BorrowEthScript is Script {
    using stdJson for string;
    using MarketParamsLib for MarketParams;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG 0.01% v3
    address constant ETH_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9; // Chainlink ETH / USD
    address constant ETH_PRICE = 0x1d1B3096406279A93C955ED0d65fA2597B08CDef; // EthPrice: the pool's 30-minute average
    uint256 constant WAD = 1e18;
    uint256 constant VAULT_DEAD = 0.0001 ether;
    uint256 constant MARKET_DEAD = 0.00001 ether;

    struct Cfg {
        address owner;
        address keeper;
        uint256 capTotal;
        uint256 capBig;
        uint256 capSmall;
        string big;
        bool weekendLiq;
        bool dead;
        uint256 timelock;
        uint256 lltv;
    }

    struct Desk {
        string symbol;
        address token;
        address feed;
        address vault;
        bytes32 deskId; // BorroShort's desk: the stock's short market
        uint256 lltv;
        uint256 cap;
        StockEthOracle oracle;
        MarketParams market;
    }

    struct Out {
        EthLoanLiquidator liq;
        EthLoanRouter router;
        address vault;
        address adapter;
        StockEthOracle[] oracles; // in desks.json's order
    }

    function _cfg() internal view returns (Cfg memory c) {
        c.owner = vm.envOr("OWNER", HOARD_SAFE);
        c.keeper = vm.envOr("KEEPER", KEEPER);
        c.capTotal = vm.envOr("CAP_TOTAL", uint256(10 ether));
        c.capBig = vm.envOr("CAP_BIG", uint256(2 ether));
        c.capSmall = vm.envOr("CAP_SMALL", uint256(1 ether));
        c.big = string.concat(",", vm.envOr("BIG", string("SPY,QQQ,NVDA")), ",");
        c.weekendLiq = vm.envOr("WEEKEND_LIQ", true);
        c.dead = vm.envOr("DEAD_DEPOSITS", false);
        c.timelock = vm.envOr("TIMELOCK", uint256(259_200));
        c.lltv = vm.envOr("LLTV", uint256(0.385e18));
    }

    function _desks(Cfg memory c) internal view returns (Desk[] memory ds, address short) {
        string memory desksJson = vm.readFile(string.concat(vm.projectRoot(), "/script/out/desks.json"));
        string memory stocksJson = vm.readFile(string.concat(vm.projectRoot(), "/script/stocks.json"));
        short = desksJson.readAddress(".short");
        uint256 n;
        while (vm.keyExistsJson(desksJson, string.concat(".desks[", vm.toString(n), "]"))) n++;
        ds = new Desk[](n);
        for (uint256 i; i < n; i++) {
            string memory at = string.concat(".desks[", vm.toString(i), "]");
            string memory st = string.concat(".stocks[", vm.toString(i), "]");
            Desk memory d = ds[i];
            d.symbol = desksJson.readString(string.concat(at, ".symbol"));
            require(keccak256(bytes(d.symbol)) == keccak256(bytes(stocksJson.readString(string.concat(st, ".symbol")))), "desks.json and stocks.json in the same order");
            d.token = stocksJson.readAddress(string.concat(st, ".token"));
            d.feed = stocksJson.readAddress(string.concat(st, ".feed"));
            d.vault = desksJson.readAddress(string.concat(at, ".vault"));
            d.deskId = desksJson.readBytes32(string.concat(at, ".marketId"));
            d.lltv = vm.envOr(string.concat("LLTV_", d.symbol), c.lltv);
            bool isBig = vm.indexOf(c.big, string.concat(",", d.symbol, ",")) != type(uint256).max;
            d.cap = isBig ? c.capBig : c.capSmall;
            // Checked against the chain before anything is sent.
            require(IMorpho(BorroLib.MORPHO).isLltvEnabled(d.lltv), "lltv not enabled on Morpho");
            require(IShareVault(d.vault).asset() == d.token, "vault holds the stock");
            (MarketParams memory sm, PoolKey[] memory route, address v3Pool,,) = IEthLoanDesks(short).deskOf(d.deskId);
            require(sm.loanToken == d.token && (route.length != 0 || v3Pool != address(0)), "desk route");
        }
    }

    function run() external returns (Out memory o) {
        Cfg memory c = _cfg();
        (Desk[] memory ds, address short) = _desks(c);
        require(BorroLib.looksLikeSafe(c.owner), "owner is a Safe");
        IMorpho morpho = IMorpho(BorroLib.MORPHO);
        bytes32 salt = keccak256(abi.encode("borro.borrow-eth", block.chainid));

        vm.startBroadcast();
        (, address me,) = vm.readCallers(); // the account that sends (the deployer), in a script or a test
        if (c.dead) IEthLoanWeth(WETH).deposit{value: VAULT_DEAD + MARKET_DEAD * ds.length}();

        o.liq = new EthLoanLiquidator(
            morpho, IPoolManager(POOL_MANAGER), IERC20(BorroLib.USDG), IERC20(WETH), ETH_POOL, IEthLoanDesks(short), BorroLib.IRM
        );
        address named = c.weekendLiq ? address(o.liq) : address(0);
        o.oracles = new StockEthOracle[](ds.length);
        for (uint256 i; i < ds.length; i++) {
            Desk memory d = ds[i];
            d.oracle = new StockEthOracle(
                d.token, IShareVault(d.vault), IChainlinkFeed(d.feed), IChainlinkFeed(ETH_FEED), IEthUsd(ETH_PRICE), named
            );
            d.market = MarketParams({loanToken: WETH, collateralToken: d.vault, oracle: address(d.oracle), irm: BorroLib.IRM, lltv: d.lltv});
            morpho.createMarket(d.market);
            o.oracles[i] = d.oracle;
            if (c.dead) {
                IERC20(WETH).approve(address(morpho), MARKET_DEAD);
                morpho.supply(d.market, MARKET_DEAD, 0, BorroLib.DEAD, "");
            }
        }

        (o.vault, o.adapter) = _lender(c, ds, me, salt);

        o.router = new EthLoanRouter(morpho, IEthLoanWeth(WETH), BorroLib.IRM, named, me);
        for (uint256 i; i < ds.length; i++) {
            o.router.list(ds[i].market);
        }
        if (c.owner != me) o.router.transferOwnership(c.owner); // two steps: the Safe accepts
        vm.stopBroadcast();

        _checkAndWrite(c, ds, o, short);
    }

    /// The Borro ETH vault, its adapter, caps and waits, handed to the owner.
    function _lender(Cfg memory c, Desk[] memory ds, address me, bytes32 salt) internal returns (address vault, address adapter) {
        IVaultV2 v = IVaultV2(IVaultV2Factory(BorroLib.VAULT_FACTORY).createVaultV2(me, WETH, salt));
        vault = address(v);
        v.setName("Borro ETH");
        v.setSymbol("bETH");
        v.setCurator(me);
        adapter = IMorphoMarketV1AdapterV2Factory(BorroLib.ADAPTER_FACTORY).createMorphoMarketV1AdapterV2(vault);
        _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (me, true)));
        if (c.keeper != address(0) && c.keeper != me) _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (c.keeper, true)));
        _now(v, abi.encodeCall(IVaultV2.addAdapter, (adapter)));

        // SPY (or the first desk) is the deposit market; its cap is raised to the sum of the others.
        uint256 first;
        uint256 others;
        for (uint256 i; i < ds.length; i++) {
            if (keccak256(bytes(ds[i].symbol)) == keccak256("SPY")) first = i;
        }
        for (uint256 i; i < ds.length; i++) {
            if (i != first) others += ds[i].cap;
        }
        for (uint256 i; i < ds.length; i++) {
            uint256 cap = i == first && ds[i].cap < others ? others : ds[i].cap;
            bytes[2] memory ids = [
                abi.encode("collateralToken", ds[i].market.collateralToken),
                abi.encode("this/marketParams", adapter, ds[i].market)
            ];
            for (uint256 k; k < 2; k++) {
                _now(v, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (ids[k], cap)));
                _now(v, abi.encodeCall(IVaultV2.increaseRelativeCap, (ids[k], WAD)));
            }
        }
        bytes memory all = abi.encode("this", adapter);
        _now(v, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (all, c.capTotal)));
        _now(v, abi.encodeCall(IVaultV2.increaseRelativeCap, (all, WAD)));

        _now(v, abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (c.owner)));
        _now(v, abi.encodeCall(IVaultV2.setPerformanceFee, (0.1e18)));
        v.setLiquidityAdapterAndData(adapter, abi.encode(ds[first].market));
        v.setMaxRate(BorroLib.MAX_MAX_RATE); // bETH is collateral nowhere
        if (c.dead) {
            IERC20(WETH).approve(vault, VAULT_DEAD);
            v.deposit(VAULT_DEAD, BorroLib.DEAD);
        }
        BorroLib.lock(vault, c.timelock);
        BorroLib.handOver(vault, me, c.owner);
    }

    function _now(IVaultV2 v, bytes memory data) internal {
        v.submit(data);
        (bool ok, bytes memory err) = address(v).call(data);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    function _checkAndWrite(Cfg memory c, Desk[] memory ds, Out memory o, address short) internal {
        IVaultV2 v = IVaultV2(o.vault);
        require(v.owner() == c.owner && v.curator() == c.owner && v.isSentinel(c.owner) && v.isAllocator(c.owner), "bETH roles");
        require(v.timelock(IVaultV2.increaseAbsoluteCap.selector) == c.timelock, "bETH waits");
        require(address(o.liq.desks()) == short && address(o.liq.weth()) == WETH, "liquidator links");
        string memory markets = "[";
        for (uint256 i; i < ds.length; i++) {
            Desk memory d = ds[i];
            require(o.router.listed(Id.unwrap(d.market.id())), "listed");
            require(d.oracle.liquidator() == (c.weekendLiq ? address(o.liq) : address(0)), "oracle names the liquidator");
            uint256 p = d.oracle.liquidationPrice();
            console2.log(d.symbol, "WETH per share (18 dp):", p / 1e18);
            markets = string.concat(
                markets,
                i == 0 ? "" : ",",
                "{\"symbol\":\"", d.symbol, "\",\"oracle\":\"", vm.toString(address(d.oracle)), "\",\"marketId\":\"",
                vm.toString(Id.unwrap(d.market.id())), "\",\"vault\":\"", vm.toString(d.vault), "\",\"deskId\":\"",
                vm.toString(d.deskId), "\",\"lltv\":\"", vm.toString(d.lltv), "\",\"cap\":\"", vm.toString(d.cap), "\"}"
            );
        }
        markets = string.concat(markets, "]");
        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory json = string.concat(
            "{\"liquidator\":\"", vm.toString(address(o.liq)), "\",\"router\":\"", vm.toString(address(o.router)),
            "\",\"vault\":\"", vm.toString(o.vault), "\",\"adapter\":\"", vm.toString(o.adapter), "\",\"owner\":\"",
            vm.toString(c.owner), "\",\"weekendLiquidations\":", c.weekendLiq ? "true" : "false", ",\"deadDeposits\":",
            c.dead ? "true" : "false", ",\"capTotal\":\"", vm.toString(c.capTotal), "\",\"block\":0,\"dryRun\":",
            real ? "false" : "true", ",\"markets\":", markets, "}\n"
        );
        // A test that runs this script (test/eth/BorrowEthDeploy.fork.t.sol) writes nothing. RECORD names the file for a
        // run against a private local chain, so it never lands on the real record.
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            string memory name = vm.envOr("RECORD", string(real ? "borrow-eth" : "borrow-eth.dryrun"));
            vm.writeFile(string.concat(vm.projectRoot(), "/script/out/", name, ".json"), json);
        }
        console2.log("liquidator", address(o.liq));
        console2.log("router    ", address(o.router));
        console2.log("bETH      ", o.vault);
        console2.log("adapter   ", o.adapter);
    }
}
