// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {CoinFeed} from "../../src/coins/CoinFeed.sol";
import {CoinListing} from "../../src/coins/CoinListing.sol";
import {CoinLoans} from "../../src/coins/CoinLoans.sol";
import {CoinLoanLiquidator} from "../../src/coins/CoinLoanLiquidator.sol";
import {GatedCoin} from "../../src/coins/GatedCoin.sol";
import {PoolTrader} from "./CoinFeed.fork.t.sol";
import {CoinLoansBase} from "./CoinLoans.fork.t.sol";

/// Random traffic against loans on two coins at once. Each action on one coin checks the other coin's money did not
/// move; every full repay is tried as it comes and every failure counted.
contract CoinLoansHandler is Test {
    using MarketParamsLib for MarketParams;

    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IMorpho constant MORPHO = IMorpho(0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010);
    address constant SAFE = 0x8A22d6e75e9427b9D57e42a7984200029e7E173C;

    CoinLoans public loans;
    CoinLoanLiquidator public liq;
    CoinListing public listing;
    address[2] public coins;
    PoolTrader[2] public traders;
    address[3] public actors;
    address public keeper = makeAddr("inv loan keeper");
    address public stranger = makeAddr("inv loan stranger");

    uint256 public capBreaches;
    uint256 public repayFailures;
    uint256 public crossTouches; // an action on one coin moved the other coin's vault or market
    uint256 public strangerWins;
    uint256 public borrows;
    uint256 public repays;
    uint256 public liquidations;

    constructor(CoinLoans l, CoinLoanLiquidator q, CoinListing li, address c0, address c1, PoolTrader t0, PoolTrader t1) {
        (loans, liq, listing) = (l, q, li);
        coins = [c0, c1];
        traders = [t0, t1];
        actors = [makeAddr("inv borrower a"), makeAddr("inv borrower b"), makeAddr("inv borrower c")];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(actors[i]);
            IERC20(c0).approve(address(loans), type(uint256).max);
            IERC20(c1).approve(address(loans), type(uint256).max);
            USDG.approve(address(loans), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// The other coin's money, to compare before and after an action.
    function _other(uint256 k) internal view returns (uint256 vaultAssets, uint256 supply, uint256 borrowed, uint256 collateralHeld) {
        CoinLoans.LoanDesk memory d = loans.loanDeskOf(coins[1 - k]);
        vaultAssets = IVaultV2(d.vault).totalAssets();
        Market memory m = MORPHO.market(d.market.id());
        (supply, borrowed) = (m.totalSupplyAssets, m.totalBorrowAssets);
        collateralHeld = IERC20(d.wrapper).balanceOf(address(MORPHO));
    }

    modifier isolated(uint256 c) {
        uint256 k = c % 2;
        // Interest accrues on its own; bring the other market up to date first so only this action shows.
        MORPHO.accrueInterest(loans.loanDeskOf(coins[1 - k]).market);
        (uint256 a0, uint256 s0, uint256 b0, uint256 h0) = _other(k);
        _;
        (uint256 a1, uint256 s1, uint256 b1, uint256 h1) = _other(k);
        if (a1 != a0 || s1 != s0 || b1 != b0 || h1 != h0) crossTouches++;
    }

    function _steps(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.warp(vm.getBlockTimestamp() + 15);
            vm.roll(vm.getBlockNumber() + 1);
            CoinFeed(loans.loanDeskOf(coins[0]).feed).poke();
            CoinFeed(loans.loanDeskOf(coins[1]).feed).poke();
        }
    }

    function borrow(uint256 c, uint256 who, uint256 size, uint256 ltv) external isolated(c) {
        address coin = coins[c % 2];
        address a = actors[who % 3];
        uint256 cap;
        try loans.loanCapOf(coin) returns (uint256 x, uint256) {
            cap = x;
        } catch {
            return;
        }
        uint256 amount = size % 5 == 0 ? cap + 1e6 : bound(size, 1e5, cap / 2 + 1e5); // over the cap one time in five
        (uint256 delayed,,) = CoinFeed(loans.loanDeskOf(coin).feed).price();
        if (delayed == 0) return;
        uint256 col = ((amount * 10_000) / bound(ltv, 800, 1_900)) * 1e30 / delayed;
        deal(coin, a, IERC20(coin).balanceOf(a) + col);
        vm.prank(a);
        try loans.borrow(coin, col, amount, block.timestamp + 1) {
            borrows++;
            if (MORPHO.market(loans.loanDeskOf(coin).market.id()).totalBorrowAssets > cap + 1) capBreaches++;
        } catch {}
    }

    function repayAll(uint256 c, uint256 who) external isolated(c) {
        address coin = coins[c % 2];
        address a = actors[who % 3];
        address acct = loans.accountOf(a);
        if (acct.code.length == 0) return;
        Position memory p = MORPHO.position(loans.loanDeskOf(coin).market.id(), acct);
        if (p.borrowShares == 0 && p.collateral == 0) return;
        deal(address(USDG), a, USDG.balanceOf(a) + 10_000e6);
        vm.prank(a);
        try loans.repay(coin, type(uint256).max, type(uint256).max, type(uint256).max) {
            repays++;
        } catch {
            repayFailures++;
        }
    }

    function addCollateral(uint256 c, uint256 who, uint256 amount) external isolated(c) {
        address coin = coins[c % 2];
        address a = actors[who % 3];
        if (loans.accountOf(a).code.length == 0) return;
        amount = bound(amount, 1e18, 1e24);
        deal(coin, a, IERC20(coin).balanceOf(a) + amount);
        vm.prank(a);
        loans.addCollateral(coin, amount); // must never fail
    }

    function takeSome(uint256 c, uint256 who, uint256 part) external isolated(c) {
        address coin = coins[c % 2];
        address a = actors[who % 3];
        address acct = loans.accountOf(a);
        if (acct.code.length == 0) return;
        uint256 col = MORPHO.position(loans.loanDeskOf(coin).market.id(), acct).collateral;
        if (col == 0) return;
        vm.prank(a);
        try loans.repay(coin, 0, (col * bound(part, 1, 100)) / 1_000, 0) {} catch {}
    }

    function dump(uint256 c, uint256 coinsIn) external {
        uint256 k = c % 2;
        coinsIn = bound(coinsIn, 1e20, IERC20(coins[k]).totalSupply() / 60);
        deal(coins[k], address(traders[k]), coinsIn);
        traders[k].sell(coinsIn);
    }

    function pump(uint256 c, uint256 eth) external {
        traders[c % 2].buy(bound(eth, 0.005 ether, 0.4 ether));
    }

    /// A big held dump, so loans reach liquidation.
    function crash(uint256 c, uint256 coinsIn) external {
        uint256 k = c % 2;
        coinsIn = bound(coinsIn, IERC20(coins[k]).totalSupply() / 20, IERC20(coins[k]).totalSupply() / 4);
        deal(coins[k], address(traders[k]), coinsIn);
        traders[k].sell(coinsIn);
        _steps(75);
    }

    function wait(uint256 n) external {
        _steps(bound(n, 1, 80));
    }

    function liquidate(uint256 c, uint256 who) external isolated(c) {
        address coin = coins[c % 2];
        address acct = loans.accountOf(actors[who % 3]);
        if (acct.code.length == 0) return;
        try liq.plan(loans.loanDeskOf(coin).market, acct) returns (uint256 seize, uint256 rep) {
            if (seize == 0 && rep == 0) return;
        } catch {
            return;
        }
        vm.prank(keeper);
        try liq.liquidate(coin, acct, 0, keeper) {
            liquidations++;
        } catch {}
    }

    /// Someone lends USDG straight into a coin's loan market, outside its vault.
    function outsideSupply(uint256 c, uint256 amount) external isolated(c) {
        amount = bound(amount, 1e6, 20_000e6);
        deal(address(USDG), stranger, amount);
        vm.startPrank(stranger);
        USDG.approve(address(MORPHO), amount);
        MORPHO.supply(loans.loanDeskOf(coins[c % 2]).market, amount, 0, stranger, "");
        vm.stopPrank();
    }

    function safePauses(uint256 c, uint256 seed) external {
        bool on = seed % 4 == 0;
        vm.prank(SAFE);
        if (seed % 2 == 0) loans.pauseAll(on);
        else loans.pause(coins[c % 2], on);
    }

    function strangerTries(uint256 c, uint256 which) external {
        CoinLoans.LoanDesk memory d = loans.loanDeskOf(coins[c % 2]);
        which = which % 4;
        vm.startPrank(stranger);
        bool ok;
        if (which == 0) (ok,) = address(d.wrapper).call(abi.encodeCall(GatedCoin.wrap, (1, stranger)));
        else if (which == 1) (ok,) = address(liq).call(abi.encodeCall(liq.onMorphoLiquidate, (1, abi.encode(coins[c % 2]))));
        else if (which == 2) {
            deal(coins[c % 2], stranger, 1e24);
            IERC20(coins[c % 2]).approve(address(MORPHO), 1e24);
            (ok,) = address(MORPHO).call(abi.encodeWithSignature("supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)", d.market, 1e24, stranger, ""));
        } else (ok,) = address(liq).call(abi.encodeWithSignature("unlockCallback(bytes)", abi.encode(listing.keyOf(coins[c % 2]), 1, false, false)));
        vm.stopPrank();
        if (ok) strangerWins++;
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract CoinLoansInvariantTest is CoinLoansBase {
    using MarketParamsLib for MarketParams;

    CoinLoansHandler h;
    Market nvda0;
    uint256 bUsdg0;
    uint256 safeUsdg0;

    function setUp() public {
        string memory rpc = vm.envOr("BORRO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        _deployAndList();
        h = new CoinLoansHandler(loans, liq, listing, address(BORRO), address(COIN2), trader, trader2);
        nvda0 = MORPHO.market(Id.wrap(NVDA_MARKET));
        bUsdg0 = IVaultV2(BUSDG).totalAssets();
        safeUsdg0 = USDG.balanceOf(SAFE);
        targetContract(address(h));
    }

    function _skipUnlessForked() internal {
        if (!forked) vm.skip(true);
    }

    function invariant_nothing_is_held_between_transactions() public {
        _skipUnlessForked();
        for (uint256 i; i < 2; i++) {
            address c = i == 0 ? address(BORRO) : address(COIN2);
            address w = loans.loanDeskOf(c).wrapper;
            for (uint256 j; j < 2; j++) {
                address who = j == 0 ? address(loans) : address(liq);
                assertEq(IERC20(c).balanceOf(who), 0);
                assertEq(IERC20(w).balanceOf(who), 0);
            }
        }
        assertEq(USDG.balanceOf(address(loans)), 0);
        assertEq(USDG.balanceOf(address(liq)), 0);
        assertEq(IERC20(WETH).balanceOf(address(liq)), 0);
        assertEq(address(liq).balance, 0);
    }

    function invariant_every_gated_coin_backed_and_only_on_coinloans_accounts() public {
        _skipUnlessForked();
        for (uint256 i; i < 2; i++) {
            address c = i == 0 ? address(BORRO) : address(COIN2);
            CoinLoans.LoanDesk memory d = loans.loanDeskOf(c);
            assertEq(IERC20(c).balanceOf(d.wrapper), IERC20(d.wrapper).totalSupply(), "backed one for one");
            uint256 onAccounts;
            for (uint256 a; a < 3; a++) onAccounts += MORPHO.position(d.market.id(), loans.accountOf(h.actors(a))).collateral;
            assertEq(IERC20(d.wrapper).balanceOf(address(MORPHO)), onAccounts, "collateral only on CoinLoans accounts");
        }
    }

    function invariant_caps_repays_isolation_and_doors() public {
        _skipUnlessForked();
        assertEq(h.capBreaches(), 0, "cap breached");
        assertEq(h.repayFailures(), 0, "a full repay failed");
        assertEq(h.crossTouches(), 0, "one coin's action moved another coin's money");
        assertEq(h.strangerWins(), 0, "a stranger got through");
    }

    function invariant_borro_money_untouched_and_the_safe_takes_nothing() public {
        _skipUnlessForked();
        assertEq(MORPHO.market(Id.wrap(NVDA_MARKET)).totalSupplyAssets, nvda0.totalSupplyAssets);
        assertGe(IVaultV2(BUSDG).totalAssets(), bUsdg0);
        assertEq(USDG.balanceOf(SAFE), safeUsdg0);
    }

    function afterInvariant() public {
        if (!forked) return;
        vm.writeLine(
            "script/out/coin-loans-invariant-tally.txt",
            string.concat("borrows ", vm.toString(h.borrows()), " repays ", vm.toString(h.repays()), " liquidations ", vm.toString(h.liquidations()))
        );
    }
}
