#!/usr/bin/env bash
# Deploys Borrow ETH (docs/BORROW-ETH.md) for real. The owner runs this, in his own Terminal. Dry run first (sends
# nothing, prints the plan), then asks before sending. Reads the RPC and the deployer key from their files without
# printing either. Writes script/out/borrow-eth.json, with the deploy's chain block taken from the receipts
# (block.number inside a forge script on this chain is the parent chain's block).
#
# Settings (environment, all optional; the defaults are the recommendations in docs/BORROW-ETH.md):
#   LLTV=385000000000000000  LLTV_<SYMBOL>=...  CAP_TOTAL=10e18  CAP_BIG=2e18  CAP_SMALL=1e18  BIG=SPY,QQQ,NVDA
#   WEEKEND_LIQ=true  DEAD_DEPOSITS=false  OWNER=<Hoard Safe>  KEEPER=<keeper>  TIMELOCK=259200
# DEAD_DEPOSITS=true wraps 0.00019 ETH of the deployer's and leaves it in bETH and the nine markets for good. Only with
# The owner's yes.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
KEY="$(cat "$HOME/.config/borro/deployer_key")"
SENDER="$(cast wallet address --private-key "$KEY")"
echo "deployer $SENDER"
echo "settings: LLTV=${LLTV:-385000000000000000} CAP_TOTAL=${CAP_TOTAL:-10 ETH} CAP_BIG=${CAP_BIG:-2 ETH} CAP_SMALL=${CAP_SMALL:-1 ETH} WEEKEND_LIQ=${WEEKEND_LIQ:-true} DEAD_DEPOSITS=${DEAD_DEPOSITS:-false}"
forge script script/BorrowEth.s.sol --rpc-url "$RPC" --sender "$SENDER" 2>&1 \
  | grep -E "liquidator|router|bETH|adapter|WETH per share|Estimated|Error|error" || true
read -r -p "Deploy Borrow ETH for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }
forge script script/BorrowEth.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY" 2>&1 \
  | grep -E "liquidator|router|bETH|adapter|ONCHAIN|Error|error" || true
python3 - <<'PY'
import json
run = json.load(open("broadcast/BorrowEth.s.sol/4663/run-latest.json"))
blocks = [int(r["blockNumber"], 16) for r in run["receipts"]]
assert all(r.get("status") in ("0x1", 1) for r in run["receipts"]), "a transaction failed"
out = json.load(open("script/out/borrow-eth.json"))
out["block"] = min(blocks)
out["txs"] = len(blocks)
json.dump(out, open("script/out/borrow-eth.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY
echo "Next: the Safe accepts the router's ownership (acceptOwnership on the router), then config.js ethLoans and the keeper's ethLoans section."
