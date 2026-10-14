// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BorroCalls} from "../src/calls/BorroCalls.sol";
import {IStockVault, IRoundFeed} from "../src/calls/CallsDeps.sol";

/// BorroShort's desk record, as its ABI lays it out.
struct CallsMarketLike {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct CallsPoolKeyLike {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface ICallsDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (CallsMarketLike memory market, CallsPoolKeyLike[] memory route, address v3Pool, bool paused, address feed);
}

/// Deploys a covered calls vault (BorroCalls, docs/COVERED-CALLS.md) for each stock in CALLS_STOCKS (default: all nine
/// desks), owned by the Hoard Safe from the start (no transfer to accept). Each vault takes its stock, its Borro vault
/// and its Chainlink feed from Borro's own live desk (desks.json for the market id and vault, BorroShort.deskOf for the
/// stock and the feed), so it lends to exactly the vault Borro's shorters borrow from and prices by exactly the feed the
/// desk's market uses. Settings per stock are in _params (docs/COVERED-CALLS.md, "Settings").
///
///   forge script script/BorroCalls.s.sol --rpc-url <rpc> --sender <deployer>            (dry run, nothing sent)
///   DEPLOYER_PRIVATE_KEY=... DEPLOYER_ADDRESS=... forge script ... --broadcast --slow      (for real)
///
/// Roy runs contracts/script/deploy-calls.sh, which does both. Writes script/out/calls.json on a real run
/// (calls.dryrun.json on a dry run; CALLS_OUT names another record, for tests). Its "block" is filled in by the wrapper
/// from the receipts (block.number in a script on this chain reads the parent chain's).
contract DeployBorroCalls is Script {
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// desks.json's desk entries (fields in alphabetical order, as parseJson needs).
    struct Desk {
        address adapter;
        bytes32 marketId;
        address oracle;
        string symbol;
        bytes32 usdgMarketId;
        address usdgOracle;
        address vault;
    }

    struct Made {
        string symbol;
        BorroCalls calls;
    }

    function run() external returns (BorroCalls[] memory) {
        return deploy(vm.envOr("CALLS_STOCKS", string("SPY,QQQ,NVDA,TSLA,MSTR,COIN,PLTR,SPCX,GME")), vm.envOr("CALLS_OUT", string("calls")));
    }

    /// @notice The deploy itself, for `stocks` (comma separated), writing script/out/<out>.json (.dryrun.json on a dry
    ///         run). Tests call this directly, so suites running side by side never share a setting through the
    ///         environment.
    function deploy(string memory stocks, string memory out) public returns (BorroCalls[] memory made) {
        string memory json = vm.readFile("script/out/desks.json");
        ICallsDesks short = ICallsDesks(vm.parseJsonAddress(json, ".short"));
        Desk[] memory desks = abi.decode(vm.parseJson(json, ".desks"), (Desk[]));
        string[] memory want = vm.split(stocks, ",");
        require(want.length > 0 && want.length <= desks.length, "CALLS_STOCKS");
        made = new BorroCalls[](want.length);

        // The key comes from the environment (never the command line) and must be the deployer's.
        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address sender = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (key != 0) require(sender != address(0) && vm.addr(key) == sender, "DEPLOYER_PRIVATE_KEY is not DEPLOYER_ADDRESS's key");
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        for (uint256 w; w < want.length; w++) {
            for (uint256 v; v < w; v++) require(keccak256(bytes(want[v])) != keccak256(bytes(want[w])), "a stock named twice in CALLS_STOCKS");
            Desk memory d = _desk(desks, want[w]);
            (CallsMarketLike memory market,,, bool deskPaused, address feed) = short.deskOf(d.marketId);
            require(market.loanToken != address(0) && feed != address(0), "desk not listed");
            require(!deskPaused, string.concat(want[w], "'s desk is paused on BorroShort: leave it out of CALLS_STOCKS"));
            require(IStockVault(d.vault).asset() == market.loanToken, "vault lends another token");
            made[w] = new BorroCalls(
                IERC20(market.loanToken),
                IStockVault(d.vault),
                IERC20(USDG),
                IRoundFeed(feed),
                HOARD_SAFE,
                _params(d.symbol),
                string.concat("Borro ", d.symbol, " Calls"),
                string.concat("cc", d.symbol)
            );
        }
        vm.stopBroadcast();

        string memory list = "[";
        for (uint256 w; w < want.length; w++) list = string.concat(list, w == 0 ? "" : ",", _entry(want[w], made[w]));
        list = string.concat(list, "]");
        console2.log("owner    ", HOARD_SAFE);
        _record(out, list, address(short));
    }

    /// One vault's record (and its log lines), checking it is the Safe's.
    function _entry(string memory symbol, BorroCalls c) internal view returns (string memory) {
        require(c.owner() == HOARD_SAFE, "owner");
        (uint16 step, uint16 start, uint16 floor, uint16 move, uint16 write, uint32 auction, uint32 offset) = c.params();
        console2.log(symbol, address(c));
        console2.log("  step / start / floor bps", step, start, floor);
        string memory head = string.concat(
            '{"symbol":"', symbol, '","calls":"', vm.toString(address(c)), '","stock":"', vm.toString(address(c.stock())),
            '","vault":"', vm.toString(address(c.bVault())), '","feed":"', vm.toString(address(c.feed())), '",'
        );
        return string.concat(
            head, '"params":{"stepBps":', vm.toString(step), ',"startBps":', vm.toString(start), ',"floorBps":',
            vm.toString(floor), ',"maxMoveBps":', vm.toString(move), ',"writeBps":', vm.toString(write),
            ',"auctionSeconds":', vm.toString(auction), ',"startOffset":', vm.toString(offset), "}}"
        );
    }

    /// Writes script/out/<out>.json on a real run, <out>.dryrun.json on a dry run.
    function _record(string memory out, string memory list, address short) internal {
        bool real = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        vm.writeFile(
            string.concat("script/out/", out, real ? ".json" : ".dryrun.json"),
            string.concat(
                '{"owner":"', vm.toString(HOARD_SAFE), '","usdg":"', vm.toString(USDG), '","short":"', vm.toString(short),
                '","vaults":', list, ',"note":"block is the chain block from the receipts, filled in by deploy-calls.sh"}'
            )
        );
    }

    function _desk(Desk[] memory desks, string memory symbol) internal pure returns (Desk memory) {
        for (uint256 i; i < desks.length; i++) {
            if (keccak256(bytes(desks[i].symbol)) == keccak256(bytes(symbol))) return desks[i];
        }
        revert(string.concat("no desk for ", symbol));
    }

    /// Settings per stock (docs/COVERED-CALLS.md, "Settings"). The strike step is about one week's typical move (the
    /// stock's weekly standard deviation from 120 days of Hyperliquid daily closes, read 2026-10-09, rounded), so a
    /// call is about one standard deviation out of the money; the sale starts at about three times what such a call is
    /// worth (0.083 of a weekly standard deviation of the price) and falls to about a third of it; sales stop once the
    /// price is a quarter of the step over the start (SPY: 0.6%, above the feeds' 0.5% posting band). Every vault: 100% of its stock offered, a 6 hour sale from 09:30
    /// New York.
    function _params(string memory s) internal pure returns (BorroCalls.Params memory p) {
        p.writeBps = 10_000;
        p.auctionSeconds = 6 hours;
        p.startOffset = 13.75 hours; // 09:45 New York: the open's feed post (within about a minute of 09:30) is in by then
        bytes32 k = keccak256(bytes(s));
        // SPY's sale guard sits above the feeds' 0.5% posting band, so one ordinary post does not end its sale.
        if (k == keccak256("SPY")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (150, 36, 4, 60);
        else if (k == keccak256("QQQ")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (300, 70, 8, 75);
        else if (k == keccak256("NVDA")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (500, 120, 13, 125);
        else if (k == keccak256("TSLA")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (650, 160, 18, 162);
        else if (k == keccak256("MSTR")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (1200, 300, 33, 300);
        else if (k == keccak256("COIN")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (1000, 240, 27, 250);
        else if (k == keccak256("PLTR")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (800, 195, 22, 200);
        else if (k == keccak256("SPCX")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (1000, 255, 28, 250);
        else if (k == keccak256("GME")) (p.stepBps, p.startBps, p.floorBps, p.maxMoveBps) = (600, 145, 16, 150);
        else revert(string.concat("no settings for ", s));
    }
}
