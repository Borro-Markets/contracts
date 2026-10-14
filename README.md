# Borro contracts

Solidity contracts, tests and deploy scripts for Borro (borro.markets): stock lending, short selling, dollar and
ETH loans, stock liquidity farms, a weekend cover pool and an options desk for tokenized stocks on Robinhood
Chain (an Arbitrum chain, id 4663).

Deposits sit in Morpho Blue markets and Morpho Vault V2 vaults; prices come from Chainlink feeds; swaps and the
farms use Uniswap v4. Borro's own contracts, in `src/`, are the logic around them. Dependencies are pinned under
`lib/` (Morpho as submodules at the audited commits, the rest vendored).

## Layout

- `src/` the contracts. Money paths: `BorroShort.sol` and the routers, `hooks/` (the Uniswap v4 farm hook),
  `eth/` (ETH loans), `GapPool.sol` (weekend cover), `OptionsDesk.sol` and `calls/` (options). Then `coins/`
  (coin markets) and the token contracts (`BorroDrip`, `BorroLock`, `BorroDistributor`, `StockDistributor`,
  `TeamReserve`).
- `test/` forge tests, most of them on a fork of Robinhood Chain.
- `script/` deploy scripts; `script/out/` the deployed addresses.

## Build and test

```
forge build
BORRO_RPC_URL=<a Robinhood Chain RPC> forge test
```

The RPC URL is read from the environment (`foundry.toml`, `rpc_endpoints`); nothing in this repository holds a key
or an endpoint.
