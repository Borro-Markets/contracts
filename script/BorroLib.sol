// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2Factory} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {IMorphoChainlinkOracleV2Factory} from "morpho-oracles/morpho-chainlink/interfaces/IMorphoChainlinkOracleV2Factory.sol";
import {IMorphoChainlinkOracleV2} from "morpho-oracles/morpho-chainlink/interfaces/IMorphoChainlinkOracleV2.sol";
import {AggregatorV3Interface} from "morpho-oracles/morpho-chainlink/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "morpho-oracles/morpho-chainlink/interfaces/IERC4626.sol";
import {Vm} from "forge-std/Vm.sol";

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// The waiting periods of Morpho's market adapter (MorphoMarketV1AdapterV2), run by the vault's curator.
interface IAdapterTimelocks {
    function submit(bytes memory data) external;
    function increaseTimelock(bytes4 selector, uint256 newDuration) external;
    function burnShares(bytes32 marketId) external;
    function timelock(bytes4 selector) external view returns (uint256);
}

/// What a Safe answers about who signs for it.
interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// The markets, vaults and oracles Borro puts on chain are all made by contracts Morpho already deployed on
/// Robinhood Chain. This library is the one recipe, shared by the deploy script and the fork tests.
///
/// One stock = one price oracle, one market (post dollars, borrow the stock) and one vault (lend the stock).
/// The dollars posted are shares of the Steakhouse USDG lending vault, so money held against a short earns
/// that vault's interest for as long as the short is open.
///
/// The USDG side: each stock also gets a second oracle and market (post the stock vault's shares, borrow
/// USDG), and one Borro USDG vault lends into all of those markets.
library BorroLib {
    using MarketParamsLib for MarketParams;

    // Robinhood Chain, chain id 4663. Morpho's own deployments.
    address internal constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address internal constant IRM = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1;
    address internal constant ORACLE_FACTORY = 0xB7c16F6F8cF531447Bf27Ca7220f981E79C9cdF2;
    address internal constant VAULT_FACTORY = 0x0FBad98595b0186dA120E41f77C102beb49f803c;
    address internal constant ADAPTER_FACTORY = 0x79370Ed003CE325C088E530d5e8655c99c2993e1;

    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    // Steakhouse USDG (a Morpho Vault V2, 18-decimal shares over 6-decimal USDG): the collateral of every market.
    address internal constant HELD = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_MAX_RATE = 200e16 / uint256(365 days);
    // A stock vault's share is the collateral on its USDG market, priced at what the share redeems for. Anyone
    // can send stock straight to the vault, and the vault passes such a gift (and its rent) into the share price
    // no faster than its max rate. At 200% a year the price could be pushed up 0.55% a day; at 50% it is 0.14% a
    // day, so the collateral price cannot be made to jump. Rent above 50% a year is not lost: the vault pays it
    // out later, as the rate allows.
    uint256 internal constant STOCK_MAX_RATE = 50e16 / uint256(365 days);

    // Dead deposits on the USDG side, in USDG wei: one into the Borro USDG vault, and one straight into each
    // USDG market, so no market the vault lends into is ever empty (Morpho's advice for its market adapter).
    uint256 internal constant USDG_SEED = 1e6;
    uint256 internal constant USDG_MARKET_SEED = 0.1e6;

    struct Stock {
        string symbol;
        address token;
        address feed;
        uint256 lltv;
        uint256 cap; // wei of the stock token
        uint256 seed; // wei of the stock token, deposited to DEAD
        uint256 lltvUsdg; // borrow limit when the stock vault's shares are posted for USDG
        uint256 capUsdg; // the most the Borro USDG vault lends into that market, in USDG wei
    }

    struct Terms {
        address owner; // also curator and allocator at launch; msg.sender of every call below
        address feeRecipient;
        uint256 performanceFee; // WAD, share of interest
        bytes32 salt;
    }

    struct Desk {
        address token;
        address oracle;
        address vault;
        address adapter;
        bytes32 marketId;
        MarketParams market;
    }

    /// The USDG side of a desk: post the stock vault's shares (bNVDA etc.), borrow USDG.
    struct Loan {
        address oracle;
        bytes32 marketId;
        MarketParams market;
    }

    /// The Borro USDG vault (bUSDG) and its one adapter, which lends into every USDG market.
    struct Lender {
        address vault;
        address adapter;
        bytes32 liquidityMarketId; // where deposits land first and withdrawals are paid from
    }

    /// The caller must be `t.owner` and must hold `s.seed` of the stock token.
    function open(Stock memory s, Terms memory t) internal returns (Desk memory d) {
        require(IERC20Min(s.token).decimals() == 18, "stock decimals");
        require(AggregatorV3Interface(s.feed).decimals() == 8, "feed decimals");

        d.token = s.token;
        d.oracle = address(_oracle(s.feed, t.salt));
        d.market = MarketParams({loanToken: s.token, collateralToken: HELD, oracle: d.oracle, irm: IRM, lltv: s.lltv});
        d.marketId = Id.unwrap(d.market.id());
        IMorpho(MORPHO).createMarket(d.market);

        IVaultV2 v = IVaultV2(IVaultV2Factory(VAULT_FACTORY).createVaultV2(t.owner, s.token, t.salt));
        d.vault = address(v);
        v.setName(string.concat("Borro ", s.symbol));
        v.setSymbol(string.concat("b", s.symbol));
        v.setCurator(t.owner);

        d.adapter = IMorphoMarketV1AdapterV2Factory(ADAPTER_FACTORY).createMorphoMarketV1AdapterV2(d.vault);

        _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (t.owner, true)));
        _now(v, abi.encodeCall(IVaultV2.addAdapter, (d.adapter)));

        bytes[3] memory ids = idData(d);
        for (uint256 i; i < 3; i++) {
            _now(v, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (ids[i], s.cap)));
            _now(v, abi.encodeCall(IVaultV2.increaseRelativeCap, (ids[i], WAD)));
        }

        if (t.performanceFee != 0) {
            _now(v, abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (t.feeRecipient)));
            _now(v, abi.encodeCall(IVaultV2.setPerformanceFee, (t.performanceFee)));
        }

        v.setLiquidityAdapterAndData(d.adapter, abi.encode(d.market));
        v.setMaxRate(STOCK_MAX_RATE);

        // Dead deposit: keeps the vault and the market from ever being empty (share price attacks).
        IERC20Min(s.token).approve(d.vault, s.seed);
        v.deposit(s.seed, DEAD);
    }

    /// The USDG side of a desk: an oracle that prices one share of the stock vault in USDG, and a market where
    /// those shares are posted to borrow USDG. The caller must hold USDG_MARKET_SEED of USDG.
    function openUsdg(Stock memory s, Desk memory d, bytes32 salt) internal returns (Loan memory l) {
        require(IVaultV2(d.vault).asset() == s.token, "vault asset");
        require(IMorpho(MORPHO).isLltvEnabled(s.lltvUsdg), "lltv not enabled");
        l.oracle = address(_usdgOracle(d.vault, s.feed, salt));
        l.market = MarketParams({loanToken: USDG, collateralToken: d.vault, oracle: l.oracle, irm: IRM, lltv: s.lltvUsdg});
        l.marketId = Id.unwrap(l.market.id());
        IMorpho(MORPHO).createMarket(l.market);

        // Dead supply: the market is never empty, whatever the USDG vault does.
        IERC20Min(USDG).approve(MORPHO, USDG_MARKET_SEED);
        IMorpho(MORPHO).supply(l.market, USDG_MARKET_SEED, 0, DEAD, "");
    }

    /// The Borro USDG vault: lenders deposit USDG, it is lent into the USDG markets, each up to its stock's
    /// `capUsdg`. Deposits land in the SPY market first (or the first market, if SPY is not in the list) and
    /// withdrawals are paid from it; the allocators move money between markets within the caps.
    /// `t.owner` and `keeper` are the allocators. The caller must be `t.owner` and hold USDG_SEED of USDG.
    function openLender(Stock[] memory list, Loan[] memory loans, Terms memory t, address keeper)
        internal
        returns (Lender memory r)
    {
        require(list.length == loans.length && loans.length != 0, "lists");
        IVaultV2 v = IVaultV2(IVaultV2Factory(VAULT_FACTORY).createVaultV2(t.owner, USDG, t.salt));
        r.vault = address(v);
        v.setName("Borro USDG");
        v.setSymbol("bUSDG");
        v.setCurator(t.owner);

        r.adapter = IMorphoMarketV1AdapterV2Factory(ADAPTER_FACTORY).createMorphoMarketV1AdapterV2(r.vault);

        _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (t.owner, true)));
        if (keeper != address(0) && keeper != t.owner) _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (keeper, true)));
        _now(v, abi.encodeCall(IVaultV2.addAdapter, (r.adapter)));

        // Per market: the market itself and its collateral (each stock vault backs one market only).
        (uint256[] memory caps, uint256 first) = usdgCaps(list);
        uint256 total;
        for (uint256 i; i < loans.length; i++) {
            bytes[2] memory ids = loanIdData(r.adapter, loans[i]);
            for (uint256 j; j < 2; j++) {
                _now(v, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (ids[j], caps[i])));
                _now(v, abi.encodeCall(IVaultV2.increaseRelativeCap, (ids[j], WAD)));
            }
            total += caps[i];
        }
        // The adapter as a whole: the sum of the markets.
        bytes memory all = abi.encode("this", r.adapter);
        _now(v, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (all, total)));
        _now(v, abi.encodeCall(IVaultV2.increaseRelativeCap, (all, WAD)));

        if (t.performanceFee != 0) {
            _now(v, abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (t.feeRecipient)));
            _now(v, abi.encodeCall(IVaultV2.setPerformanceFee, (t.performanceFee)));
        }

        v.setLiquidityAdapterAndData(r.adapter, abi.encode(loans[first].market));
        r.liquidityMarketId = loans[first].marketId;
        // bUSDG is not collateral anywhere in Borro, so interest may reach its share price at the full rate.
        v.setMaxRate(MAX_MAX_RATE);

        IERC20Min(USDG).approve(r.vault, USDG_SEED);
        v.deposit(USDG_SEED, DEAD);
    }

    /// What the Borro USDG vault may lend into each USDG market, and which market is the liquidity market (SPY,
    /// or the first in the list if SPY is not in it). Every market gets its stock's `capUsdg`, except the
    /// liquidity market: every deposit lands there first, so its cap is raised, if it is lower, to the sum of
    /// all the other markets' caps. A deposit then never stops at its cap while there is room elsewhere.
    function usdgCaps(Stock[] memory list) internal pure returns (uint256[] memory caps, uint256 first) {
        caps = new uint256[](list.length);
        for (uint256 i; i < list.length; i++) {
            if (keccak256(bytes(list[i].symbol)) == keccak256("SPY")) first = i;
        }
        uint256 others;
        for (uint256 i; i < list.length; i++) {
            caps[i] = list[i].capUsdg;
            if (i != first) others += list[i].capUsdg;
        }
        if (caps[first] < others) caps[first] = others;
    }

    /// The two risk ids, besides the adapter's own, that the USDG vault's adapter reports for one market.
    function loanIdData(address adapter, Loan memory l) internal pure returns (bytes[2] memory ids) {
        ids[0] = abi.encode("collateralToken", l.market.collateralToken);
        ids[1] = abi.encode("this/marketParams", adapter, l.market);
    }

    /// Hands a vault from the wallet that set it up to its long-term owner (a Safe): owner, curator, allocator
    /// and sentinel. As sentinel the Safe can always cut a cap, pull money out of a market and throw out a
    /// change still waiting, even if the curator role ever moves. The setup wallet keeps no role. Run after
    /// `lock`. `from` must be the vault's owner and curator.
    function handOver(address vault, address from, address to) internal {
        IVaultV2 v = IVaultV2(vault);
        v.setIsSentinel(to, true);
        if (to == from) return;
        _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (to, true)));
        _now(v, abi.encodeCall(IVaultV2.setIsAllocator, (from, false)));
        v.setCurator(to);
        v.setOwner(to);
    }

    /// The vault settings `lock` puts a wait on: everything that could hurt a lender if it took effect at once.
    /// Fees and who receives them, gates (each can stop deposits, withdrawals or getting shares back from
    /// Morpho), the adapter registry, adapters, caps, the force deallocate penalty, and abdicating a setting for
    /// good.
    /// Left out on purpose: `setIsAllocator`. In Vault V2 the same call adds and removes an allocator, so a wait
    /// on it would also hold up removing one, and the Safe must be able to remove a compromised keeper at
    /// once. Only the curator (the Safe) can make that call, and an allocator only moves money within the caps,
    /// which are locked.
    function lockedSelectors() internal pure returns (bytes4[15] memory) {
        return [
            IVaultV2.addAdapter.selector,
            IVaultV2.removeAdapter.selector,
            IVaultV2.increaseAbsoluteCap.selector,
            IVaultV2.increaseRelativeCap.selector,
            IVaultV2.setPerformanceFee.selector,
            IVaultV2.setManagementFee.selector,
            IVaultV2.setPerformanceFeeRecipient.selector,
            IVaultV2.setManagementFeeRecipient.selector,
            IVaultV2.setReceiveSharesGate.selector,
            IVaultV2.setSendSharesGate.selector,
            IVaultV2.setReceiveAssetsGate.selector,
            IVaultV2.setSendAssetsGate.selector,
            IVaultV2.setAdapterRegistry.selector,
            IVaultV2.setForceDeallocatePenalty.selector,
            IVaultV2.abdicate.selector
        ];
    }

    /// Puts a waiting period on every setting in `lockedSelectors`. Run once setup is final.
    /// The vault's adapters get the same wait on `burnShares`, which would write off what the vault has lent.
    /// The vault's own settings are locked in one transaction: each `increaseTimelock` is submitted and run
    /// in one `multicall`, which works while its own wait is zero.
    function lock(address vault, uint256 wait) internal {
        IVaultV2 v = IVaultV2(vault);
        bytes4[15] memory sel = lockedSelectors();
        bytes[] memory calls = new bytes[](sel.length * 2);
        for (uint256 i; i < sel.length; i++) {
            bytes memory data = abi.encodeCall(IVaultV2.increaseTimelock, (sel[i], wait));
            calls[2 * i] = abi.encodeCall(IVaultV2.submit, (data));
            calls[2 * i + 1] = data;
        }
        v.multicall(calls);
        for (uint256 i; i < v.adaptersLength(); i++) {
            IAdapterTimelocks a = IAdapterTimelocks(v.adapters(i));
            bytes memory data = abi.encodeCall(IAdapterTimelocks.increaseTimelock, (IAdapterTimelocks.burnShares.selector, wait));
            a.submit(data);
            (bool ok, bytes memory err) = address(a).call(data);
            if (!ok) {
                assembly {
                    revert(add(err, 32), mload(err))
                }
            }
        }
    }

    /// Whether `who` answers like a Safe that has been set up: a threshold of at least one, and at least that
    /// many owners. A Safe's master copy (the singleton every Safe points at) fails: it reports a threshold
    /// of one but has no owners, and nobody can sign for it.
    function looksLikeSafe(address who) internal view returns (bool) {
        if (who.code.length == 0) return false;
        try ISafe(who).getThreshold() returns (uint256 threshold) {
            if (threshold == 0) return false;
            try ISafe(who).getOwners() returns (address[] memory owners) {
                return owners.length >= threshold;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// The latest block number as the chain's RPC counts blocks, for finding logs later. On Robinhood Chain (an
    /// Arbitrum chain) `block.number` is the parent chain's block number, which eth_getLogs does not use.
    function rpcBlock(Vm vm) internal returns (uint256 n) {
        bytes memory raw = vm.rpc("eth_blockNumber", "[]");
        for (uint256 i; i < raw.length; i++) n = (n << 8) | uint8(raw[i]);
    }

    /// The three risk ids the adapter reports for this market.
    function idData(Desk memory d) internal pure returns (bytes[3] memory ids) {
        ids[0] = abi.encode("this", d.adapter);
        ids[1] = abi.encode("collateralToken", HELD);
        ids[2] = abi.encode("this/marketParams", d.adapter, d.market);
    }

    /// Price of one vault share of collateral in the stock: what the share redeems for in USDG, times
    /// USDG/USD, over STOCK/USD. The "base token decimals" are the vault's underlying's (USDG, 6); the
    /// conversion sample of one whole share carries the share's own 18 decimals.
    function _oracle(address stockFeed, bytes32 salt) private returns (IMorphoChainlinkOracleV2) {
        return IMorphoChainlinkOracleV2Factory(ORACLE_FACTORY).createMorphoChainlinkOracleV2(
            IERC4626(HELD),
            1e18,
            AggregatorV3Interface(USDG_FEED),
            AggregatorV3Interface(address(0)),
            6,
            IERC4626(address(0)),
            1,
            AggregatorV3Interface(stockFeed),
            AggregatorV3Interface(address(0)),
            18,
            salt
        );
    }

    /// Price of one stock vault share in USDG: what the share redeems for in the stock, times STOCK/USD, over
    /// USDG/USD. The "base token decimals" are the vault's underlying's (the stock, 18); the conversion sample
    /// is one whole share.
    function _usdgOracle(address stockVault, address stockFeed, bytes32 salt) private returns (IMorphoChainlinkOracleV2) {
        return IMorphoChainlinkOracleV2Factory(ORACLE_FACTORY).createMorphoChainlinkOracleV2(
            IERC4626(stockVault),
            1e18,
            AggregatorV3Interface(stockFeed),
            AggregatorV3Interface(address(0)),
            18,
            IERC4626(address(0)),
            1,
            AggregatorV3Interface(USDG_FEED),
            AggregatorV3Interface(address(0)),
            6,
            salt
        );
    }

    /// Submit and run in one go. Works while the setting's waiting period is zero.
    function _now(IVaultV2 v, bytes memory data) private {
        v.submit(data);
        (bool ok, bytes memory err) = address(v).call(data);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }
}
