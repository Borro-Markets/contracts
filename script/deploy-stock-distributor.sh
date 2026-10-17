#!/usr/bin/env bash
# Deploys StockDistributor for real (the owner runs this, in his own Terminal): the contract that pays a basket of
# stock tokens to $BORRO holders (docs/OPS.md, "Stocks for holders"). Owned by the Hoard Safe from the start, the
# keeper as updater, the guardian wallet as guardian, the basket NVDA TSLA SPY PLTR COIN from Borro's own desks.
#
#   bash ~/borro/contracts/script/deploy-stock-distributor.sh
#
# 1. A dry run (simulated against the chain, nothing sent): the addresses, the basket, each token's growth limit and
#    the gas it would cost.
# 2. It asks. Only on "y" it sends, then reads the receipt: the chain block and the address go into
#    script/out/stock-distributor.json ("block" there is the receipt's block; the script itself can only see the
#    parent chain's block number, kept as "parentChainBlock").
#
# The RPC URL and the deployer key are read from their files and handed to forge through the environment: neither is
# printed or put on a command line. MAX_USD_PER_DAY (default 2000) and BASKET pass through to the script.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
DEPLOYER=0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6
# BORRO_RPC_URL already set: a test chain (keeper/test/stockpay.fork.mjs). Otherwise the owner's endpoint.
export BORRO_RPC_URL="${BORRO_RPC_URL:-$(cat "$HOME/.config/hoard/rpc_url")}"
KEY_FILE="${DEPLOYER_KEY_FILE:-$HOME/.config/borro/deployer_key}"
SENDER="${DEPLOYER_ADDRESS:-$DEPLOYER}"
OUT_FILE="${STOCKS_OUT:-script/out/stock-distributor.json}"
export STOCKS_OUT="$OUT_FILE"

if [ -f "$OUT_FILE" ] && [ -z "${FORCE:-}" ]; then
  echo "$OUT_FILE already exists: a StockDistributor was deployed before. Move it away (or FORCE=1) to deploy another."
  exit 1
fi

echo "Dry run from $SENDER (nothing is sent):"
if ! dry="$(forge script script/StockDistributor.s.sol --rpc-url robinhood --sender "$SENDER" 2>&1)"; then
  printf '%s\n' "$dry" | grep -E "Error|error|revert|panic" | head -20
  echo "The dry run failed; nothing was sent."
  exit 1
fi
printf '%s\n' "$dry" | grep -E "distributor|owner|updater|guardian|token  |Estimated amount" || true
# The dry run writes the record too; it is rewritten by the real run below.
rm -f "$OUT_FILE"
read -r -p "Deploy StockDistributor for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }

key="$(tr -d ' \r\n' < "$KEY_FILE")"
[[ "$key" == 0x* ]] || key="0x$key"
set +e
live="$(DEPLOYER_PRIVATE_KEY="$key" forge script script/StockDistributor.s.sol --rpc-url robinhood --broadcast --slow --sender "$SENDER" 2>&1)"
status=$?
set -e
unset key
printf '%s\n' "$live" | grep -E "distributor|ONCHAIN|Error|error|revert" || true
[ "$status" = 0 ] || { echo "forge stopped with an error (above); read broadcast/StockDistributor.s.sol/4663/run-latest.json before trying again"; exit 1; }

python3 - "$OUT_FILE" "$SENDER" <<'PY'
import json, sys
out_file, sender = sys.argv[1], sys.argv[2].lower()
run = json.load(open("broadcast/StockDistributor.s.sol/4663/run-latest.json"))
receipts = run["receipts"]
bad = [r["transactionHash"] for r in receipts if r["status"] != "0x1"]
if bad: raise SystemExit(f"failed transactions: {bad}")
if not receipts: raise SystemExit("no receipts: nothing was sent")
for r in receipts:
    if r["from"].lower() != sender: raise SystemExit(f"sent from {r['from']}, not {sender}")
out = json.load(open(out_file))
made = [r for r in receipts if (r.get("contractAddress") or "").lower() == out["distributor"].lower()]
if not made: raise SystemExit("no receipt created the distributor named in " + out_file)
out["parentChainBlock"] = out["block"]
out["block"] = int(made[0]["blockNumber"], 16)
out["tx"] = made[0]["transactionHash"]
json.dump(out, open(out_file, "w"), indent=2)
print(json.dumps(out, indent=2))
PY
echo "Next: docs/OPS.md, \"Stocks for holders\": the keeper config, then approve-stocks.sh for the first basket."
