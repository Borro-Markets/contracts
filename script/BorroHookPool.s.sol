// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BorroHook} from "../src/hooks/BorroHook.sol";
import {IVault, IFeed} from "../src/hooks/BorroHookDeps.sol";

/// One desk's pool on an existing BorroHook, for a stock listed after the hook was deployed (the deploy script does
/// every desk in desks.json at once). Run by the hook's owner it registers and starts the pool; run by anyone else
/// it starts an already registered pool, or prints the register call for the Safe to send.
///
///   HOOK=<hook> SYMBOL=NVDA forge script script/BorroHookPool.s.sol --rpc-url $RPC --sender <you>                 (dry run)
///   ... --broadcast --private-key <key>                                                                       (for real)
contract BorroHookPool is Script {
    using StateLibrary for IPoolManager;

    function run() external {
        BorroHook hook = BorroHook(vm.envAddress("HOOK"));
        string memory symbol = vm.envString("SYMBOL");
        string memory json = vm.readFile("script/out/desks.json");
        uint256 n = abi.decode(vm.parseJson(json, ".desks"), (bytes[])).length;
        bytes32 deskId;
        address vault;
        for (uint256 i; i < n; i++) {
            string memory p = string.concat(".desks[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".symbol")))) == keccak256(bytes(symbol))) {
                deskId = vm.parseJsonBytes32(json, string.concat(p, ".marketId"));
                vault = vm.parseJsonAddress(json, string.concat(p, ".vault"));
            }
        }
        require(deskId != bytes32(0), "no such desk in desks.json");

        vm.startBroadcast();
        (, address caller,) = vm.readCallers();
        IPoolManager pm = hook.poolManager();
        BorroHook.Pool memory pool;
        (bool registered, PoolId id) = _find(hook, deskId);
        if (!registered) {
            if (hook.owner() != caller) {
                vm.stopBroadcast();
                console2.log("Not registered, and you are not the owner. The Safe sends to", address(hook));
                console2.logBytes(abi.encodeCall(hook.register, (deskId, IVault(vault))));
                return;
            }
            id = hook.register(deskId, IVault(vault));
        }
        pool = hook.poolOf(id);
        (uint160 sqrtNow,,,) = pm.getSlot0(id);
        if (sqrtNow == 0) pm.initialize(hook.keyFor(pool.stock), _sqrtPrice(pool));
        vm.stopBroadcast();
        console2.log(symbol, vm.toString(PoolId.unwrap(id)), address(pool.share));
    }

    function _find(BorroHook hook, bytes32 deskId) internal view returns (bool, PoolId) {
        PoolId[] memory ids = hook.pools();
        for (uint256 i; i < ids.length; i++) {
            if (hook.poolOf(ids[i]).marketId == deskId) return (true, ids[i]);
        }
        return (false, PoolId.wrap(bytes32(0)));
    }

    function _sqrtPrice(BorroHook.Pool memory p) internal view returns (uint160) {
        (, int256 a,,,) = IFeed(p.feed).latestRoundData();
        uint256 feedE8 = uint256(a) * 1e8 / p.feedScale;
        uint256 priceX192 = p.usdgIs0
            ? Math.mulDiv(10 ** p.stockDecimals * 1e8, 1 << 192, feedE8 * 1e6)
            : Math.mulDiv(feedE8 * 1e6, 1 << 192, 10 ** p.stockDecimals * 1e8);
        return uint160(Math.sqrt(priceX192));
    }
}
