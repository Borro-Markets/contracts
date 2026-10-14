#!/usr/bin/env bash
# Deploys Borro's covered calls vaults (docs/COVERED-CALLS.md) for real: Roy runs this himself, in his own Terminal.
# One BorroCalls per stock in CALLS_STOCKS (default all nine desks: SPY,QQQ,NVDA,TSLA,MSTR,COIN,PLTR,SPCX,GME), each
# owned by the Hoard Safe from the start, so there is nothing for the Safe to accept afterwards.
#
#   bash ~/borro/contracts/script/deploy-calls.sh               dry run: simulated against the chain, nothing sent;
#                                                                writes script/out/calls.dryrun.json
#   bash ~/borro/contracts/script/deploy-calls.sh --broadcast   for real; writes script/out/calls.json, with the chain
#                                                                block and transaction of every vault from the receipts
#   CALLS_STOCKS=NVDA,TSLA bash ~/borro/contracts/script/deploy-calls.sh     only some stocks (dry run or real)
#   bash ~/borro/contracts/script/deploy-calls.sh --broadcast --force       for real although calls.json exists
#                                                                (more vaults later: the old record is kept aside)
#
# Nothing is funded, started or opened here: an empty vault starts no round until someone deposits, and the site and
# keeper only use a vault once its address is in their config (docs/COVERED-CALLS.md, "Going live").
#
# The RPC URL and the deployer key are read from their files and handed to forge through the environment: neither is
# printed or put on a command line, and everything forge prints has the RPC URL replaced by <rpc>.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
unset DEPLOYER_PRIVATE_KEY FORCE # a stray key or override in the shell never applies here
DEPLOYER=0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6
SAFE=0x8A22d6e75e9427b9D57e42a7984200029e7E173C
# BORRO_RPC_URL already set to a local chain: a test (keeper/test/calls.fork.mjs). Otherwise Roy's endpoint, and then
# nothing a test may set (another record, another key file or deployer, extra forge flags) is taken from the shell.
FORGE_EXTRA_ARGS=()
case "${BORRO_RPC_URL:-}" in
  http://127.0.0.1:*|http://localhost:*)
    # A test names its own (throwaway) key: the real deployer's key is never used against a local URL.
    [ -n "${DEPLOYER_KEY_FILE:-}" ] || { echo "a local chain needs DEPLOYER_KEY_FILE (a test key)"; exit 1; }
    KEY_FILE="$DEPLOYER_KEY_FILE"
    export DEPLOYER_ADDRESS="${DEPLOYER_ADDRESS:-$DEPLOYER}"
    if [ -n "${FORGE_EXTRA:-}" ]; then read -r -a FORGE_EXTRA_ARGS <<< "$FORGE_EXTRA"; fi
    ;;
  *)
    unset CALLS_OUT DEPLOYER_KEY_FILE FORGE_EXTRA
    BORRO_RPC_URL="$(cat "$HOME/.config/hoard/rpc_url")"
    KEY_FILE="$HOME/.config/borro/deployer_key"
    export DEPLOYER_ADDRESS="$DEPLOYER"
    ;;
esac
export BORRO_RPC_URL
OUT_FILE="script/out/${CALLS_OUT:-calls}.json"
RUN_FILE=broadcast/BorroCalls.s.sol/4663/run-latest.json

scrub() { local s="$1"; printf '%s\n' "${s//"$BORRO_RPC_URL"/<rpc>}"; }

if [ "${1:-}" != "--broadcast" ]; then
  echo "Dry run from $DEPLOYER_ADDRESS (nothing is sent):"
  set +e
  dry="$(forge script script/BorroCalls.s.sol --rpc-url robinhood --sender "$DEPLOYER_ADDRESS" ${FORGE_EXTRA_ARGS[@]+"${FORGE_EXTRA_ARGS[@]}"} 2>&1)"
  status=$?
  set -e
  scrub "$dry" | grep -E "^  (SPY|QQQ|NVDA|TSLA|MSTR|COIN|PLTR|SPCX|GME) |step|owner|Estimated|Error|error|revert" || true
  [ "$status" = 0 ] || { echo "The dry run failed; nothing was sent."; exit 1; }
  echo
  echo "Dry run only. Nothing was sent. Record: ${OUT_FILE%.json}.dryrun.json. To deploy: bash $0 --broadcast"
  exit 0
fi

if [ -f "$OUT_FILE" ]; then
  if [ "${2:-}" != "--force" ]; then
    echo "$OUT_FILE already exists: calls vaults were deployed before. To deploy more: bash $0 --broadcast --force"
    exit 1
  fi
  kept="${OUT_FILE%.json}.before-$(date -u +%Y%m%dT%H%M%SZ).json"
  mv "$OUT_FILE" "$kept"
  echo "The earlier record is kept as $kept"
fi
# forge writes the record during its own simulation, before anything lands: if the run or a receipt fails, that record
# is moved aside so it is never taken for a deploy.
failed() { [ -f "$OUT_FILE" ] && mv "$OUT_FILE" "${OUT_FILE%.json}.failed-$(date -u +%Y%m%dT%H%M%SZ).json"; echo "$1"; exit 1; }
key="$(tr -d ' \r\n' < "$KEY_FILE")"
[[ "$key" == 0x* ]] || key="0x$key"
set +e
live="$(DEPLOYER_PRIVATE_KEY="$key" forge script script/BorroCalls.s.sol --rpc-url robinhood --broadcast --slow --sender "$DEPLOYER_ADDRESS" ${FORGE_EXTRA_ARGS[@]+"${FORGE_EXTRA_ARGS[@]}"} 2>&1)"
status=$?
set -e
unset key
scrub "$live" | grep -E "^  (SPY|QQQ|NVDA|TSLA|MSTR|COIN|PLTR|SPCX|GME) |owner|ONCHAIN|Error|error|revert" || true
[ "$status" = 0 ] || failed "forge stopped with an error (above); read $RUN_FILE before trying again"

python3 - "$OUT_FILE" "$RUN_FILE" "$DEPLOYER_ADDRESS" "$SAFE" <<'PY' || failed "the receipts do not match the record (above); nothing is recorded as deployed"
import json, sys
out_file, run_file, sender, safe = sys.argv[1], sys.argv[2], sys.argv[3].lower(), sys.argv[4].lower()
run = json.load(open(run_file))
receipts = run["receipts"]
if not receipts: raise SystemExit("no receipts: nothing was sent")
bad = [r["transactionHash"] for r in receipts if r["status"] != "0x1"]
if bad: raise SystemExit(f"failed transactions: {bad}")
for r in receipts:
    if r["from"].lower() != sender: raise SystemExit(f"sent from {r['from']}, not {sender}")
out = json.load(open(out_file))
if out["owner"].lower() != safe: raise SystemExit("the record names another owner")
first = None
for v in out["vaults"]:
    made = [r for r in receipts if (r.get("contractAddress") or "").lower() == v["calls"].lower()]
    if not made: raise SystemExit("no receipt created " + v["symbol"] + "'s vault " + v["calls"])
    v["block"] = int(made[0]["blockNumber"], 16)
    v["tx"] = made[0]["transactionHash"]
    first = v["block"] if first is None else min(first, v["block"])
out["block"] = first
out["note"] = "block: the first vault's chain block (from the receipts); each vault has its own"
json.dump(out, open(out_file, "w"), indent=2)
print(json.dumps(out, indent=2))
PY

# Read every vault back from the chain: owner, stock, Borro vault and feed as recorded. (Plain bash 3: macOS's.)
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
read_back() { lower "$(cast call "$1" "$2" --rpc-url "$BORRO_RPC_URL" 2>/dev/null || true)"; }
list="$(mktemp)"
python3 - "$OUT_FILE" <<'PY' > "$list"
import json, sys
for v in json.load(open(sys.argv[1]))["vaults"]:
    print(v["symbol"], v["calls"], v["stock"], v["vault"], v["feed"])
PY
while read -r sym calls stock vault feed; do
  if [ "$(read_back "$calls" "owner()(address)")" = "$(lower "$SAFE")" ] \
    && [ "$(read_back "$calls" "stock()(address)")" = "$(lower "$stock")" ] \
    && [ "$(read_back "$calls" "bVault()(address)")" = "$(lower "$vault")" ] \
    && [ "$(read_back "$calls" "feed()(address)")" = "$(lower "$feed")" ]; then
    echo "$sym $calls: on chain as recorded, owned by the Hoard Safe"
  else
    echo "$sym $calls: could not be read back as recorded (the node may lag a block; check it again with cast)"
  fi
done < "$list"
rm -f "$list"
echo "Next: docs/COVERED-CALLS.md, \"Going live\": the keeper's calls block, then the site."
