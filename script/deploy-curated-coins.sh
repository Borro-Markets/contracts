#!/usr/bin/env bash
# Deploys curated coins for real (Roy runs this himself): the add-on beside the Pons coin shorts (docs/COIN-SHORTS.md,
# phase 2): CoinLens, CuratedFeeds, CuratedListing, CoinRouter, CuratedShort (and its cUSDG), CuratedLiquidator,
# CuratedLoans and CuratedLoanLiquidator,
# owned by the Hoard Safe from the start. A dry run first, then it asks before sending. Reads the RPC and the deployer
# key from their files without printing either. Writes script/out/curated-coins.json with the chain's own block, taken
# from the receipts.
#
#   bash ~/borro/contracts/script/deploy-curated-coins.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
KEY="$(cat "$HOME/.config/borro/deployer_key")"
SENDER="$(cast wallet address --private-key "$KEY")"

echo "Dry run from $SENDER (nothing is sent):"
BORRO_RPC_URL="$RPC" forge script script/CuratedCoins.s.sol --rpc-url robinhood --sender "$SENDER" 2>&1 \
  | grep -E "lens|feeds|listing|router|short |collateral|liquidator|loans|owner|Estimated amount|Error|error|dry run" || true
read -r -p "Deploy curated coins for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }
# Keep the record of an earlier deployment: this run writes a new script/out/curated-coins.json.
if [ -f script/out/curated-coins.json ]; then
  prev="script/out/curated-coins.block-$(python3 -c 'import json; print(json.load(open("script/out/curated-coins.json"))["block"])').json"
  cp script/out/curated-coins.json "$prev" && echo "kept the earlier deployment's record in $prev"
fi

BROADCASTING=true BORRO_RPC_URL="$RPC" forge script script/CuratedCoins.s.sol --rpc-url robinhood --broadcast --slow --private-key "$KEY" 2>&1 \
  | grep -E "lens|feeds|listing|router|short |collateral|liquidator|loans|owner|ONCHAIN|Error|error" || true
python3 - <<'PY'
import json
run = json.load(open("broadcast/CuratedCoins.s.sol/4663/run-latest.json"))
blocks = [int(r["blockNumber"], 16) for r in run["receipts"]]
bad = [r["transactionHash"] for r in run["receipts"] if r["status"] != "0x1"]
if bad: raise SystemExit(f"failed transactions: {bad}")
out = json.load(open("script/out/curated-coins.json"))
out["parentChainBlock"] = out["block"]
out["block"] = min(blocks)
out["txs"] = [r["transactionHash"] for r in run["receipts"]]
json.dump(out, open("script/out/curated-coins.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY
