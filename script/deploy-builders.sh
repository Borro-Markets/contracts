#!/usr/bin/env bash
# Deploys BorroBuilders (the referral program's contract) for real (the owner runs this). Dry run first, then asks
# before sending. Reads the RPC and the deployer key from their files without printing either; writes
# script/out/builders.json with the deploy's chain block from the receipt (block.number inside a forge script on this
# chain is the parent chain's block), which is where the keeper starts scanning the contract's events.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
KEY="$(cat "$HOME/.config/borro/deployer_key")"
forge script script/BorroBuilders.s.sol --rpc-url "$RPC" --sender "$(cast wallet address --private-key "$KEY")" 2>&1 \
  | grep -E "builders|owner|vaults|Estimated amount|Error|error" || true
read -r -p "Deploy BorroBuilders for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }
forge script script/BorroBuilders.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY" 2>&1 \
  | grep -E "builders|ONCHAIN|Error|error" || true
python3 - <<'PY'
import json
run = json.load(open("broadcast/BorroBuilders.s.sol/4663/run-latest.json"))
r = [x for x in run["receipts"] if x.get("contractAddress")][0]
out = json.load(open("script/out/builders.json"))
out["block"] = int(r["blockNumber"], 16)
out["tx"] = r["transactionHash"]
assert out["builders"].lower() == r["contractAddress"].lower(), "receipt and record disagree"
json.dump(out, open("script/out/builders.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY
echo "next: python3 tools/desks.py (from the repo root) to put the address into site/desks.js as BORRO_BUILDERS"
