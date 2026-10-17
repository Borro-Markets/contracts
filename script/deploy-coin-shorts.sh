#!/usr/bin/env bash
# Deploys coin shorts for real (the owner runs this): CoinListing, CoinShort (and its cUSDG) and CoinLiquidator,
# owned by the Hoard Safe from the start. A dry run first, then it asks before sending. Reads the RPC and the deployer
# key from their files without printing either. Writes script/out/coin-shorts.json with the chain's own block, taken
# from the receipts.
#
#   bash ~/borro/contracts/script/deploy-coin-shorts.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
KEY="$(cat "$HOME/.config/borro/deployer_key")"
SENDER="$(cast wallet address --private-key "$KEY")"

echo "Dry run from $SENDER (nothing is sent):"
forge script script/CoinShorts.s.sol --rpc-url "$RPC" --sender "$SENDER" 2>&1 \
  | grep -E "listing|short |collateral|liquidator|owner|Estimated amount|Error|error|dry run" || true
read -r -p "Deploy coin shorts for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }
# Keep the record of an earlier deployment: this run writes a new script/out/coin-shorts.json.
if [ -f script/out/coin-shorts.json ]; then
  prev="script/out/coin-shorts.block-$(python3 -c 'import json; print(json.load(open("script/out/coin-shorts.json"))["block"])').json"
  cp script/out/coin-shorts.json "$prev" && echo "kept the earlier deployment's record in $prev"
fi

BROADCASTING=true forge script script/CoinShorts.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY" 2>&1 \
  | grep -E "listing|short |collateral|liquidator|owner|ONCHAIN|Error|error" || true
python3 - <<'PY'
import json
run = json.load(open("broadcast/CoinShorts.s.sol/4663/run-latest.json"))
blocks = [int(r["blockNumber"], 16) for r in run["receipts"]]
bad = [r["transactionHash"] for r in run["receipts"] if r["status"] != "0x1"]
if bad: raise SystemExit(f"failed transactions: {bad}")
out = json.load(open("script/out/coin-shorts.json"))
out["parentChainBlock"] = out["block"]
out["block"] = min(blocks)
out["txs"] = [r["transactionHash"] for r in run["receipts"]]
json.dump(out, open("script/out/coin-shorts.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY
