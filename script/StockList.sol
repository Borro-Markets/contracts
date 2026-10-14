// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BorroLib} from "./BorroLib.sol";

/// Reads script/stocks.json (the launch desks) or, through the `...From` functions, another file of the same
/// shape in script/ (stocks-add.json: desks added later). `cap` is written in whole tokens and `capUsdg` in
/// whole USDG in the file, and both are turned into wei here.
abstract contract StockList is CommonBase {
    using stdJson for string;

    function loadStocks() internal view returns (BorroLib.Stock[] memory list) {
        return loadStocksFrom("stocks.json");
    }

    /// The Uniswap v3 pool stock number `i` trades through, or zero if it uses a v4 route.
    function loadV3Pool(uint256 i) internal view returns (address) {
        return loadV3PoolFrom("stocks.json", i);
    }

    /// The pools stock number `i` trades through, from USDG to the stock. All hookless.
    function loadRoute(uint256 i) internal view returns (PoolKey[] memory) {
        return loadRouteFrom("stocks.json", i);
    }

    /// `file` is a name inside script/, such as "stocks-add.json".
    function loadStocksFrom(string memory file) internal view returns (BorroLib.Stock[] memory list) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/", file));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".stocks[", vm.toString(n), "]"))) n++;
        list = new BorroLib.Stock[](n);
        for (uint256 i; i < n; i++) {
            string memory k = string.concat(".stocks[", vm.toString(i), "]");
            list[i] = BorroLib.Stock({
                symbol: json.readString(string.concat(k, ".symbol")),
                token: json.readAddress(string.concat(k, ".token")),
                feed: json.readAddress(string.concat(k, ".feed")),
                lltv: vm.parseUint(json.readString(string.concat(k, ".lltv"))),
                cap: json.readUint(string.concat(k, ".cap")) * 1e18,
                seed: vm.parseUint(json.readString(string.concat(k, ".seed"))),
                lltvUsdg: vm.parseUint(json.readString(string.concat(k, ".lltvUsdg"))),
                capUsdg: json.readUint(string.concat(k, ".capUsdg")) * 1e6
            });
        }
    }

    /// The stock's name for the site ("Apple"), or its symbol if the file has none.
    function loadNameFrom(string memory file, uint256 i) internal view returns (string memory) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/", file));
        string memory k = string.concat(".stocks[", vm.toString(i), "]");
        if (!vm.keyExistsJson(json, string.concat(k, ".name"))) return json.readString(string.concat(k, ".symbol"));
        return json.readString(string.concat(k, ".name"));
    }

    function loadV3PoolFrom(string memory file, uint256 i) internal view returns (address) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/", file));
        return json.readAddress(string.concat(".stocks[", vm.toString(i), "].v3Pool"));
    }

    function loadRouteFrom(string memory file, uint256 i) internal view returns (PoolKey[] memory route) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/script/", file));
        string memory k = string.concat(".stocks[", vm.toString(i), "].route[");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(k, vm.toString(n), "]"))) n++;
        route = new PoolKey[](n);
        for (uint256 j; j < n; j++) {
            string memory h = string.concat(k, vm.toString(j), "]");
            route[j] = PoolKey({
                currency0: Currency.wrap(json.readAddress(string.concat(h, ".currency0"))),
                currency1: Currency.wrap(json.readAddress(string.concat(h, ".currency1"))),
                fee: uint24(json.readUint(string.concat(h, ".fee"))),
                tickSpacing: int24(int256(json.readUint(string.concat(h, ".tickSpacing")))),
                hooks: IHooks(address(0))
            });
        }
    }
}
