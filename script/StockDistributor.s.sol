// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StockDistributor} from "../src/StockDistributor.sol";

/// BorroShort's desk record, as its ABI lays it out (Morpho's MarketParams; Uniswap v4's PoolKey, whose currencies
/// and hooks are addresses).
struct MarketParamsLike {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct PoolKeyLike {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IBorroShortDesks {
    function deskOf(bytes32 id)
        external
        view
        returns (MarketParamsLike memory market, PoolKeyLike[] memory route, address v3Pool, bool paused, address feed);
}

interface IFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// Deploys StockDistributor: the basket of stock tokens paid to $BORRO holders (docs/OPS.md, "Stocks for holders").
///
///   forge script script/StockDistributor.s.sol --rpc-url robinhood --sender <deployer>            (dry run)
///   DEPLOYER_PRIVATE_KEY=... forge script ... --broadcast --slow                                    (for real)
///
/// Roy runs contracts/script/deploy-stock-distributor.sh, which does both and asks in between.
///
/// The basket (BASKET, default NVDA,TSLA,SPY,PLTR,COIN) is read from Borro's own desks: each symbol's market id from
/// script/out/desks.json (DESKS), then its token and Chainlink feed from BorroShort.deskOf, so the distributor lists
/// exactly the tokens Borro trades. Owner: the Hoard Safe, from the start (no transfer to accept). Updater: the
/// keeper. Guardian: the guardian wallet. OWNER, UPDATER and GUARDIAN override them.
///
/// Growth limit: for each token, MAX_USD_PER_DAY (default 2,000) of it a day at the feed price when deployed, as
/// token wei per second (plus an hour of slack per root). It bounds how fast promises grow, not who they go to: a
/// stolen updater key can keep the totals and move the leaves to itself, so it can take everything the distributor
/// holds unless the guardian revokes the root within its two hours (keeper/tools/stockpay-verify.mjs checks each root
/// from the chain and can revoke). A payout bigger than a day's limit is not lost: the keeper promises it over the next
/// days. The Safe can change a limit (setMaxIncreasePerSecond).
///
/// Writes script/out/stock-distributor.json (or STOCKS_OUT, inside script/out). Its "block" is block.number, which
/// on Robinhood Chain is the PARENT chain's block: deploy-stock-distributor.sh replaces it with the receipt's block.
contract StockDistributorDeploy is Script {
    address constant HOARD_SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;
    address constant KEEPER = 0x3a17bfFF7c6FB05f8c49D3d7181849E531026896;
    address constant GUARDIAN = 0x81E1b17D1f036303C6147c90b259852E80b767Bc;

    struct Item {
        string symbol;
        address token;
        address feed;
        uint256 price;
        uint8 feedDecimals;
        uint256 maxIncreasePerSecond;
    }

    function run() external returns (StockDistributor dist) {
        address owner = vm.envOr("OWNER", HOARD_SAFE);
        address updater = vm.envOr("UPDATER", KEEPER);
        address guardian = vm.envOr("GUARDIAN", GUARDIAN);
        uint256 usdPerDay = vm.envOr("MAX_USD_PER_DAY", uint256(2000));
        require(usdPerDay > 0 && usdPerDay <= 1_000_000, "MAX_USD_PER_DAY");
        string[] memory symbols = vm.split(vm.envOr("BASKET", string("NVDA,TSLA,SPY,PLTR,COIN")), ",");
        require(symbols.length > 0 && symbols.length <= 16, "BASKET");

        string memory json = vm.readFile(vm.envOr("DESKS", string("script/out/desks.json")));
        IBorroShortDesks short = IBorroShortDesks(vm.parseJsonAddress(json, ".short"));
        uint256 deskCount;
        while (vm.keyExistsJson(json, string.concat(".desks[", vm.toString(deskCount), "]"))) ++deskCount;

        Item[] memory items = new Item[](symbols.length);
        address[] memory tokens = new address[](symbols.length);
        uint256[] memory rates = new uint256[](symbols.length);
        for (uint256 i; i < symbols.length; ++i) {
            bytes32 id;
            for (uint256 j; j < deskCount; ++j) {
                string memory p = string.concat(".desks[", vm.toString(j), "]");
                if (keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".symbol")))) == keccak256(bytes(symbols[i]))) {
                    id = vm.parseJsonBytes32(json, string.concat(p, ".marketId"));
                }
            }
            require(id != bytes32(0), string.concat("no desk for ", symbols[i], " in desks.json"));
            (MarketParamsLike memory market,,,, address feed) = short.deskOf(id);
            require(market.loanToken != address(0) && feed != address(0), string.concat("BorroShort has no desk for ", symbols[i]));
            require(IERC20Metadata(market.loanToken).decimals() == 18, "stock tokens have 18 decimals");
            for (uint256 k; k < i; ++k) require(tokens[k] != market.loanToken, "a stock twice in BASKET");
            (, int256 answer,,,) = IFeed(feed).latestRoundData();
            require(answer > 0, string.concat("no price for ", symbols[i]));
            uint8 dec = IFeed(feed).decimals();
            // usdPerDay dollars of the stock, in token wei, per second.
            uint256 perDay = (usdPerDay * 10 ** dec * 1e18) / uint256(answer);
            uint256 rate = perDay / 1 days;
            require(rate > 0, "limit rounds to zero");
            items[i] = Item(symbols[i], market.loanToken, feed, uint256(answer), dec, rate);
            tokens[i] = market.loanToken;
            rates[i] = rate;
        }

        uint256 key = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        dist = new StockDistributor(owner, updater, guardian, tokens, rates);
        vm.stopBroadcast();

        require(dist.owner() == owner && dist.updater() == updater && dist.guardian() == guardian, "roles");
        address[] memory listed = dist.tokens();
        require(listed.length == tokens.length, "tokens");
        for (uint256 i; i < tokens.length; ++i) {
            require(listed[i] == tokens[i] && dist.maxIncreasePerSecond(tokens[i]) == rates[i], "listing");
        }

        string memory list = "[";
        for (uint256 i; i < items.length; ++i) {
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                "{\"symbol\":\"", items[i].symbol, "\",\"token\":\"", vm.toString(items[i].token), "\",\"feed\":\"",
                vm.toString(items[i].feed), "\",\"maxIncreasePerSecond\":\"", vm.toString(items[i].maxIncreasePerSecond), "\"}"
            );
        }
        string memory out = string.concat(
            "{\"distributor\":\"", vm.toString(address(dist)), "\",\"owner\":\"", vm.toString(owner), "\",\"updater\":\"",
            vm.toString(updater), "\",\"guardian\":\"", vm.toString(guardian), "\",\"maxUsdPerDay\":", vm.toString(usdPerDay),
            ",\"tokens\":", list, "],\"codehash\":\"", vm.toString(address(dist).codehash), "\",\"block\":", vm.toString(block.number), "}\n"
        );
        vm.writeFile(string.concat(vm.projectRoot(), "/", vm.envOr("STOCKS_OUT", string("script/out/stock-distributor.json"))), out);
        console2.log("distributor ", address(dist));
        console2.log("owner       ", owner);
        console2.log("updater     ", updater);
        console2.log("guardian    ", guardian);
        for (uint256 i; i < items.length; ++i) {
            console2.log(string.concat("token        ", items[i].symbol), items[i].token, items[i].maxIncreasePerSecond);
        }
    }
}
