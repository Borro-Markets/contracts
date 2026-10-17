#!/usr/bin/env bash
# Deploys Borro's depositor drip for real (the owner runs this, in his own Terminal): three contracts.
#   BorroDistributor  the drip's own, owned by the Hoard Safe, the keeper as updater, the guardian wallet as guardian
#   BorroDrip         owned by the launch wallet: lets the $BORRO out to depositors over 104 weeks, halving every 26
#   BorroLock         no owner: holders lock their own $BORRO there for a boost on the drip; $BORRO sent to it
#                     outside lock() can be skimmed by anyone to the Hoard Safe
# docs/OPS.md, "Depositor drip".
#
#   bash ~/borro/contracts/script/deploy-borro-drip.sh
#
# 1. A dry run (simulated against the chain, nothing sent): the addresses, the roles, the distributor's growth limit,
#    the schedule for the expected 50M and the gas it would cost.
# 2. It asks. Only on "y" it sends the three transactions one after another, checks every receipt and the contracts on
#    chain, and writes script/out/borro-drip.json with each contract's receipt block ("block" is the distributor's;
#    the script itself can only see the parent chain's block number, kept as "parentChainBlock").
#
# Nothing is funded or started here. Afterwards the owner sends the $BORRO to the drip himself and calls start() from the
# owner wallet; the steps are printed at the end.
#
# The RPC URL and the deployer key are read from their files and handed to forge through the environment: neither is
# printed or put on a command line. DRIP_OWNER (with CONFIRM_OWNER if it is not the launch wallet), DRIP_DIST_OWNER,
# DRIP_UPDATER, DRIP_GUARDIAN, DRIP_STRAYS, EXPECTED_TOTAL and GROWTH_X100 pass through to the script
# (script/BorroDrip.s.sol says what each does). The old names OWNER, DIST_OWNER, UPDATER and GUARDIAN are refused.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
DEPLOYER=0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6
EXPLORER=https://robinhoodchain.blockscout.com
# BORRO_RPC_URL already set: a test chain (keeper/test/drip-deploy.fork.mjs). Otherwise the owner's endpoint.
if [ -z "${BORRO_RPC_URL:-}" ]; then
  BORRO_RPC_URL="$(cat "$HOME/.config/hoard/rpc_url")"
fi
export BORRO_RPC_URL
KEY_FILE="${DEPLOYER_KEY_FILE:-$HOME/.config/borro/deployer_key}"
SENDER="${DEPLOYER_ADDRESS:-$DEPLOYER}"
# The script refuses a key that is not this address's, before anything is sent.
export DEPLOYER_ADDRESS="$SENDER"
OUT_FILE="${DRIP_OUT:-script/out/borro-drip.json}"
export DRIP_OUT="$OUT_FILE"
RUN_FILE="broadcast/BorroDrip.s.sol/4663/run-latest.json"

# Everything forge or cast prints goes through this, so an error that quotes the RPC URL shows <rpc> instead.
scrub() { local s="$1"; printf '%s\n' "${s//"$BORRO_RPC_URL"/<rpc>}"; }

if [ -f "$OUT_FILE" ] && [ -z "${FORCE:-}" ]; then
  echo "$OUT_FILE already exists: the drip was deployed before. Move it away (or FORCE=1) to deploy another."
  exit 1
fi

echo "Dry run from $SENDER (nothing is sent):"
set +e
dry="$(env -u DEPLOYER_PRIVATE_KEY forge script script/BorroDrip.s.sol --rpc-url robinhood --sender "$SENDER" 2>&1)"
status=$?
set -e
if [ "$status" != 0 ]; then
  scrub "$(printf '%s\n' "$dry" | grep -E "Error|error|revert|panic" | head -20)"
  echo "The dry run failed; nothing was sent."
  exit 1
fi
# The script's own summary (its console log), then the schedule table and the gas.
scrub "$(printf '%s\n' "$dry" | awk '/== Logs ==/ { on = 1; next } on && /^$/ { exit } on { print }')"
python3 - "$OUT_FILE" <<'PY'
import json, sys, datetime
out = json.load(open(sys.argv[1]))
period = out["period"]
day = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d")
def units(w):
    c = (int(w) + 5 * 10**15) // 10**16  # hundredths, rounded
    return f"{c // 100:,}.{c % 100:02d}"
t0 = out["time"]
print(f"\nSchedule for {units(out['expectedTotal'])} BORRO (the real total is what the drip holds when start() is called;")
print(f"the dates assume start() now, {day(t0)}; the schedule runs from whenever it is called):")
print(f"  {'period':<8}{'weeks':<10}{'from':<13}{'until':<13}{'amount (BORRO)':>20}{'a day (BORRO)':>17}")
for p in out["expectedPeriods"]:
    i = p["period"] - 1
    weeks = f"{26 * i + 1}-{26 * (i + 1)}"
    print(f"  {p['period']:<8}{weeks:<10}{day(t0 + i * period):<13}{day(t0 + (i + 1) * period):<13}{units(p['amount']):>20}{units(p['perDay']):>17}")
print(f"  all out by {day(t0 + 4 * period)}; the daily amount halves every 26 weeks.")
print(f"Distributor growth limit: {units(int(out['maxIncreasePerSecond']) * 86400)} BORRO a day "
      f"({out['growthX100'] / 100:.2f}x the first period's rate for {units(out['expectedTotal'])}).")
PY
printf '%s\n' "$dry" | grep -E "Estimated amount required|Estimated total gas used" || true
# The dry run writes the record too; it is rewritten by the real run below.
rm -f "$OUT_FILE"
read -r -p "Deploy the drip for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }

key="$(tr -d ' \r\n' < "$KEY_FILE")"
[[ "$key" == 0x* ]] || key="0x$key"
set +e
live="$(DEPLOYER_PRIVATE_KEY="$key" forge script script/BorroDrip.s.sol --rpc-url robinhood --broadcast --slow --sender "$SENDER" 2>&1)"
status=$?
set -e
unset key
scrub "$(printf '%s\n' "$live" | grep -E "BorroDistributor|BorroDrip |BorroLock|ONCHAIN|Error|error|revert" || true)"
[ "$status" = 0 ] || { echo "forge stopped with an error (above). Read $RUN_FILE before trying again: a contract may already be on chain."; exit 1; }

# Every receipt succeeded and came from the deployer; the record gets each contract's receipt block.
python3 - "$OUT_FILE" "$SENDER" "$RUN_FILE" <<'PY'
import json, sys
out_file, sender, run_file = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
receipts = json.load(open(run_file))["receipts"]
if not receipts: raise SystemExit("no receipts: nothing was sent")
bad = [r["transactionHash"] for r in receipts if r["status"] != "0x1"]
if bad: raise SystemExit(f"failed transactions: {bad}")
for r in receipts:
    if r["from"].lower() != sender: raise SystemExit(f"sent from {r['from']}, not {sender}")
if len(receipts) != 3: raise SystemExit(f"expected three transactions, found {len(receipts)}: read {run_file}")
out = json.load(open(out_file))
def made(name):
    m = [r for r in receipts if (r.get("contractAddress") or "").lower() == out[name].lower()]
    if len(m) != 1: raise SystemExit(f"no receipt created the {name} named in {out_file}")
    return m[0]
d, p, l = made("distributor"), made("drip"), made("lock")
out["parentChainBlock"] = out.pop("block")
out["block"] = int(d["blockNumber"], 16)
out["dripBlock"] = int(p["blockNumber"], 16)
out["lockBlock"] = int(l["blockNumber"], 16)
out["txs"] = {"distributor": d["transactionHash"], "drip": p["transactionHash"], "lock": l["transactionHash"]}
out["gasUsed"] = {"distributor": int(d["gasUsed"], 16), "drip": int(p["gasUsed"], 16), "lock": int(l["gasUsed"], 16)}
json.dump(out, open(out_file, "w"), indent=2)
print(json.dumps(out, indent=2))
PY

# Read back from the chain itself: the code is the build recorded, and every link and role is as planned.
field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT_FILE" "$1"; }
onchain() { local o; o="$(ETH_RPC_URL="$BORRO_RPC_URL" cast "$@" 2>&1)" || { scrub "$o" >&2; return 0; }; printf '%s' "${o%% *}"; }
DIST="$(field distributor)"; DRIP="$(field drip)"; LOCK="$(field lock)"
problems=0
expect() {
  local got want
  got="$(printf '%s' "$2" | tr 'A-F' 'a-f')"; want="$(printf '%s' "$3" | tr 'A-F' 'a-f')"
  if [ "$got" != "$want" ]; then echo "MISMATCH $1: the chain says '$2', expected '$3'"; problems=1; fi
}
expect "distributor code" "$(onchain codehash "$DIST")" "$(field distributorCodehash)"
expect "drip code" "$(onchain codehash "$DRIP")" "$(field dripCodehash)"
expect "lock code" "$(onchain codehash "$LOCK")" "$(field lockCodehash)"
expect "distributor token" "$(onchain call "$DIST" 'token()(address)')" "$(field token)"
expect "distributor owner" "$(onchain call "$DIST" 'owner()(address)')" "$(field distributorOwner)"
expect "distributor updater" "$(onchain call "$DIST" 'updater()(address)')" "$(field updater)"
expect "distributor guardian" "$(onchain call "$DIST" 'guardian()(address)')" "$(field guardian)"
expect "distributor growth limit" "$(onchain call "$DIST" 'maxIncreasePerSecond()(uint256)')" "$(field maxIncreasePerSecond)"
expect "drip token" "$(onchain call "$DRIP" 'token()(address)')" "$(field token)"
expect "drip distributor" "$(onchain call "$DRIP" 'distributor()(address)')" "$DIST"
expect "drip owner" "$(onchain call "$DRIP" 'owner()(address)')" "$(field owner)"
expect "drip not started" "$(onchain call "$DRIP" 'startedAt()(uint256)')" "0"
expect "lock token" "$(onchain call "$LOCK" 'token()(address)')" "$(field token)"
expect "lock strays" "$(onchain call "$LOCK" 'strays()(address)')" "$(field strays)"
if [ "$problems" != 0 ]; then
  echo "Something on chain is not what was planned (above). Do NOT send any \$BORRO to the drip; read $OUT_FILE and $RUN_FILE first."
  exit 1
fi
echo "On chain: all three contracts are the recorded build, with the links and roles above."

OWNER_ADDR="$(field owner)"
BLOCK="$(field block)"; LOCK_BLOCK="$(field lockBlock)"
cat <<EOF

Deployed. Next (docs/OPS.md, "Depositor drip"):
  1. Review $OUT_FILE and the three contracts on the explorer:
       drip         $EXPLORER/address/$DRIP
       distributor  $EXPLORER/address/$DIST
       lock         $EXPLORER/address/$LOCK
  2. From the wallet that holds your \$BORRO, send the amount to drip (50,000,000 planned) to the drip yourself, as a
     plain transfer, to:
       $DRIP
     The drip, never the lock: \$BORRO sent straight to BorroLock is nobody's lock and no one can ever move it.
  3. From the owner wallet, call start() on the drip. The total becomes what the drip holds at that moment and the
     schedule runs from then; check total() and startedAt() afterwards. Owner wallet:
       $OWNER_ADDR
  4. Set the keeper and site config per docs/OPS.md "Depositor drip":
       address $DRIP   distributor $DIST   block $BLOCK
       lock $LOCK   lockBlock $LOCK_BLOCK
  To stop it at any time: from the owner wallet, call stop(<to>) on the drip. Everything not yet let out goes to <to>
  at once; what depositors were already promised stays theirs.
EOF
