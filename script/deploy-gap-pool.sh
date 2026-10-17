#!/usr/bin/env bash
# Deploys GapPool (the Weekend Desk's Monday-gap cover) for real (the owner runs this). Dry run first, then asks
# before sending. Reads the RPC and the deployer key from their files without printing either; writes
# script/out/gap-pool.json with the deploy's chain block from the receipt (block.number inside a forge script on
# this chain is the parent chain's block). The script does the setup from the deployer and hands the pool to the
# Hoard Safe at the end, so it sends several transactions; the record keeps the one that created the contract.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
KEY="$(cat "$HOME/.config/borro/deployer_key")"
forge script script/GapPool.s.sol --rpc-url "$RPC" --sender "$(cast wallet address --private-key "$KEY")" 2>&1 \
  | grep -E "gapPool|owner|quoter|feeds|Estimated amount|Error|error" || true
read -r -p "Deploy GapPool for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }
forge script script/GapPool.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY" 2>&1 \
  | grep -E "gapPool|ONCHAIN|Error|error" || true
python3 - <<'PY'
import json
run = json.load(open("broadcast/GapPool.s.sol/4663/run-latest.json"))
r = [x for x in run["receipts"] if x.get("contractAddress")][0]
out = json.load(open("script/out/gap-pool.json"))
out["block"] = int(r["blockNumber"], 16)
out["tx"] = r["transactionHash"]
assert out["gapPool"].lower() == r["contractAddress"].lower(), "receipt and record disagree"
json.dump(out, open("script/out/gap-pool.json", "w"), indent=2)
print(json.dumps(out, indent=2))
PY
