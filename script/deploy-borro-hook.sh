#!/usr/bin/env bash
# Deploys BorroHook for real (the owner runs this): the hook, every desk's USDG/stock pool, and the handoff of
# ownership to the Hoard Safe. Reads the RPC and the deployer key from their files without printing either.
#
#   bash ~/borro/contracts/script/deploy-borro-hook.sh             dry run (sends nothing), writes script/out/borro-hook.dryrun.json
#   bash ~/borro/contracts/script/deploy-borro-hook.sh --broadcast for real, writes script/out/borro-hook.json
#
# After a real run the Safe must call acceptOwnership() on the hook. The record's "block" is taken from the hook's
# deploy receipt (block.number inside a forge script on this chain is the parent chain's block).
set -euo pipefail
cd "$(dirname "$0")/.."
# The script's test overrides (another owner, another record) never apply to the real deploy (review 2026-10-08).
unset SAFE HOOK_OUT
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
FORGE="$HOME/.foundry/bin/forge"
CAST="$HOME/.foundry/bin/cast"
if [ "${1:-}" = "--broadcast" ]; then
  KEY="$(cat "$HOME/.config/borro/deployer_key")"
  "$FORGE" script script/BorroHook.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY"
  python3 - <<'PY'
import json
run = json.load(open("broadcast/BorroHook.s.sol/4663/run-latest.json"))
hook_tx = next(t for t in run["transactions"] if t.get("contractName") == "BorroHook" and t["transactionType"] == "CREATE2")
rc = next(r for r in run["receipts"] if r["transactionHash"] == hook_tx["hash"])
rec = json.load(open("script/out/borro-hook.json"))
rec["block"] = int(rc["blockNumber"], 16)
rec["tx"] = hook_tx["hash"]
json.dump(rec, open("script/out/borro-hook.json", "w"), indent=2)
print(json.dumps(rec, indent=2))
PY
else
  SENDER="$("$CAST" wallet address --private-key "$(cat "$HOME/.config/borro/deployer_key")")"
  "$FORGE" script script/BorroHook.s.sol --rpc-url "$RPC" --sender "$SENDER"
  echo
  echo "Dry run only. Nothing was sent. To deploy: bash $0 --broadcast"
fi
