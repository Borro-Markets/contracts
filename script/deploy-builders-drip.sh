#!/usr/bin/env bash
# Deploys the Builders Drip's own BorroDistributor for real (the owner runs this, in his own Terminal). docs/OPS.md,
# "Builders", and docs/BUILDERS.md, "The Builders Drip". One contract, the one the depositor drip claims from:
#   owner     the Hoard Safe (names the updater and the guardian, pauses, reclaims what no root promises)
#   updater   the keeper (proposes each cumulative root; the builders job)
#   guardian  the guardian wallet (throws out a waiting root)
#   token     $BORRO, as the team reserve holds it; growth limit 2x the Drip's daily rate (20,000,000 over 365 days)
#
#   bash ~/borro/contracts/script/deploy-builders-drip.sh
#
# 1. A dry run (simulated against the chain, nothing sent): the address, the roles, the schedule and the gas.
# 2. It asks. Only on "y" it sends the one transaction (--slow), checks the receipt and the contract on chain, and writes
#    script/out/builders-drip.json (address, the receipt's chain block, tx; the script itself only sees the parent
#    chain's block number).
# 3. It writes script/out/builders-drip-fund.safe.json, the Safe's funding: queueWithdraw(distributor, 20,000,000 $BORRO)
#    on the team reserve, simulated as the Safe first (no file if the simulation fails). Nothing is funded here.
#
#   FUND_ONLY=1 bash ~/borro/contracts/script/deploy-builders-drip.sh
#      writes the Safe file again from builders-drip.json (say a queued withdrawal lapsed and must be queued again);
#      sends nothing
#
# The RPC URL and the deployer key are read from their files and handed to forge through the environment: neither is
# printed or put on a command line. BD_OWNER, BD_UPDATER, BD_GUARDIAN, BD_TOTAL, BD_DAYS and BD_GROWTH_X100 pass
# through to the script (script/BuildersDrip.s.sol says what each does).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
DEPLOYER=0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6
SAFE=0x8A22d6e75e9427b9D57e42a7984200029e7E173C
EXPLORER=https://robinhoodchain.blockscout.com
# BORRO_RPC_URL already set: a test chain. Otherwise the owner's endpoint.
if [ -z "${BORRO_RPC_URL:-}" ]; then
  BORRO_RPC_URL="$(cat "$HOME/.config/hoard/rpc_url")"
fi
export BORRO_RPC_URL
KEY_FILE="${DEPLOYER_KEY_FILE:-$HOME/.config/borro/deployer_key}"
SENDER="${DEPLOYER_ADDRESS:-$DEPLOYER}"
# The script refuses a key that is not this address's, before anything is sent.
export DEPLOYER_ADDRESS="$SENDER"
OUT_FILE=script/out/builders-drip.json
FUND_FILE=script/out/builders-drip-fund.safe.json
RUN_FILE="broadcast/BuildersDrip.s.sol/4663/run-latest.json"

# Everything forge or cast prints goes through this, so an error that quotes the RPC URL shows <rpc> instead.
scrub() { local s="$1"; printf '%s\n' "${s//"$BORRO_RPC_URL"/<rpc>}" | sed -E 's#https?://[^ "]*alchemy[^ "]*#<rpc>#g'; }
field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT_FILE" "$1"; }
onchain() { local o; o="$(ETH_RPC_URL="$BORRO_RPC_URL" cast "$@" 2>&1)" || { scrub "$o" >&2; return 0; }; printf '%s' "${o%% *}"; }

# The Safe's funding call, simulated as the Safe against the live chain, as a Transaction Builder file.
fund() {
  local dist total reserve data sim block
  dist="$(field distributor)"; total="$(field total)"; reserve="$(field reserve)"
  data="$(cast calldata 'queueWithdraw(address,uint256)' "$dist" "$total")"
  block="$(onchain block-number)"
  if ! sim="$(ETH_RPC_URL="$BORRO_RPC_URL" cast call --from "$SAFE" "$reserve" 'queueWithdraw(address,uint256)(uint256)' "$dist" "$total" 2>&1)"; then
    scrub "$sim"
    echo "The Safe's queueWithdraw on the team reserve would fail (above), so no Safe file was written."
    return 1
  fi
  python3 - "$OUT_FILE" "$FUND_FILE" "$data" "${sim%% *}" "$SAFE" "$block" <<'PY'
import json, sys, time
out_file, fund_file, data, wid, safe, block = sys.argv[1:7]
out = json.load(open(out_file))
if out.get("dryRun"): raise SystemExit(f"{out_file} is a dry run's record: no Safe file for it")
def units(w):
    c = (int(w) + 5 * 10**15) // 10**16
    return f"{c // 100:,}" + ("" if c % 100 == 0 else f".{c % 100:02d}")
total, dist, reserve = out["total"], out["distributor"], out["reserve"]
day = time.strftime("%Y-%m-%d", time.gmtime())
batch = {
    "version": "1.0",
    "chainId": "4663",
    "createdAt": int(time.time() * 1000),
    "meta": {
        "name": f"Borro: fund the Builders Drip, queue {units(total)} $BORRO from the team reserve (step 1 of 2)",
        "description": (
            f"TeamReserve {reserve}: queueWithdraw(to = the Builders Drip's BorroDistributor {dist}, amount = {units(total)} $BORRO). "
            "The reserve's 30-day public notice starts when the Safe executes this. From day 30 until day 44 anyone calls "
            f"executeWithdraw({wid}) on the reserve (step 2; any wallet, the $BORRO goes to the distributor either way); after day 44 "
            "it lapses and can only be cancelled. The Safe can cancelWithdraw it until it is executed. Then the keeper's "
            "builders.drip.start is set to the first UTC day after the funding lands. "
            f"Simulated as the Safe at block {block} ({day}): OK, withdrawal id {wid} if no other withdrawal is queued first."
        ),
        "createdFromSafeAddress": safe,
    },
    "transactions": [
        {
            "to": reserve,
            "value": "0",
            "data": data,
            "contractMethod": {
                "inputs": [
                    {"internalType": "address", "name": "to", "type": "address"},
                    {"internalType": "uint256", "name": "amount", "type": "uint256"},
                ],
                "name": "queueWithdraw",
                "payable": False,
            },
            "contractInputsValues": {"to": dist, "amount": str(total)},
        }
    ],
}
json.dump(batch, open(fund_file, "w"), indent=2)
open(fund_file, "a").write("\n")
print(f"Wrote {fund_file}: queueWithdraw({dist}, {total}) on {reserve}, simulated as the Safe at block {block}: withdrawal id {wid}.")
PY
}

if [ -n "${FUND_ONLY:-}" ]; then
  [ -f "$OUT_FILE" ] || { echo "no $OUT_FILE: deploy the distributor first"; exit 1; }
  fund
  exit $?
fi

if [ -f "$OUT_FILE" ] && [ -z "${FORCE:-}" ]; then
  echo "$OUT_FILE already exists: the Builders Drip's distributor was deployed before. Move it away (or FORCE=1) to deploy another."
  exit 1
fi

echo "Dry run from $SENDER (nothing is sent):"
set +e
dry="$(env -u DEPLOYER_PRIVATE_KEY forge script script/BuildersDrip.s.sol --rpc-url robinhood --sender "$SENDER" 2>&1)"
status=$?
set -e
if [ "$status" != 0 ]; then
  scrub "$(printf '%s\n' "$dry" | grep -E "Error|error|revert|panic" | head -20)"
  echo "The dry run failed; nothing was sent."
  exit 1
fi
scrub "$(printf '%s\n' "$dry" | awk '/== Logs ==/ { on = 1; next } on && /^$/ { exit } on { print }')"
printf '%s\n' "$dry" | grep -E "Estimated amount required|Estimated total gas used" || true
read -r -p "Deploy the Builders Drip's distributor for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }

key="$(tr -d ' \r\n' < "$KEY_FILE")"
[[ "$key" == 0x* ]] || key="0x$key"
set +e
live="$(DEPLOYER_PRIVATE_KEY="$key" forge script script/BuildersDrip.s.sol --rpc-url robinhood --broadcast --slow --sender "$SENDER" 2>&1)"
status=$?
set -e
unset key
scrub "$(printf '%s\n' "$live" | grep -E "BorroDistributor|ONCHAIN|Error|error|revert" || true)"
[ "$status" = 0 ] || { echo "forge stopped with an error (above). Read $RUN_FILE before trying again: the contract may already be on chain."; exit 1; }

# The one receipt succeeded, came from the deployer and made the address in the record; the record gets its block.
python3 - "$OUT_FILE" "$SENDER" "$RUN_FILE" <<'PY'
import json, sys
out_file, sender, run_file = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
receipts = json.load(open(run_file))["receipts"]
if len(receipts) != 1: raise SystemExit(f"expected one transaction, found {len(receipts)}: read {run_file}")
r = receipts[0]
if r["status"] != "0x1": raise SystemExit(f"the transaction failed: {r['transactionHash']}")
if r["from"].lower() != sender: raise SystemExit(f"sent from {r['from']}, not {sender}")
out = json.load(open(out_file))
if out.get("dryRun"): raise SystemExit(f"{out_file} says dryRun: read {run_file}")
if (r.get("contractAddress") or "").lower() != out["distributor"].lower(): raise SystemExit("receipt and record disagree")
out["block"] = int(r["blockNumber"], 16)
out["tx"] = r["transactionHash"]
out["gasUsed"] = int(r["gasUsed"], 16)
json.dump(out, open(out_file, "w"), indent=2)
open(out_file, "a").write("\n")
print(json.dumps(out, indent=2))
PY

# Read back from the chain itself: the code is the build recorded, and every link and role is as planned.
DIST="$(field distributor)"
problems=0
expect() {
  local got want
  got="$(printf '%s' "$2" | tr 'A-F' 'a-f')"; want="$(printf '%s' "$3" | tr 'A-F' 'a-f')"
  if [ "$got" != "$want" ]; then echo "MISMATCH $1: the chain says '$2', expected '$3'"; problems=1; fi
}
expect "code" "$(onchain codehash "$DIST")" "$(field codehash)"
expect "token" "$(onchain call "$DIST" 'token()(address)')" "$(field token)"
expect "owner" "$(onchain call "$DIST" 'owner()(address)')" "$(field owner)"
expect "updater" "$(onchain call "$DIST" 'updater()(address)')" "$(field updater)"
expect "guardian" "$(onchain call "$DIST" 'guardian()(address)')" "$(field guardian)"
expect "growth limit" "$(onchain call "$DIST" 'maxIncreasePerSecond()(uint256)')" "$(field maxIncreasePerSecond)"
expect "no root yet" "$(onchain call "$DIST" 'root()(bytes32)')" "0x0000000000000000000000000000000000000000000000000000000000000000"
if [ "$problems" != 0 ]; then
  echo "Something on chain is not what was planned (above). Do NOT sign the funding; read $OUT_FILE and $RUN_FILE first."
  exit 1
fi
echo "On chain: the distributor is the recorded build, with the token and roles above."

fund || { echo "Deployed, but no Safe file was written; fix the cause above, then FUND_ONLY=1 bash $0"; exit 1; }

BLOCK="$(field block)"
cat <<EOF

Deployed. Next (docs/OPS.md, "Builders", the Builders Drip):
  1. Review $OUT_FILE and the distributor on the explorer:
       $EXPLORER/address/$DIST
  2. Safe app, Apps, Transaction Builder: drag in contracts/$FUND_FILE, check the call (queueWithdraw on the team
     reserve, to the distributor above, 20,000,000 \$BORRO); two owners sign, one executes. The 30-day notice starts then.
  3. From day 30 to day 44 after that, anyone calls executeWithdraw(<id>) on the team reserve (the id is in the Safe
     file's description, and in the reserve's WithdrawQueued event): node keeper/tools/team-grant.mjs execute --id <id>
     writes a Safe file for it, or send it from any wallet. The \$BORRO lands in the distributor.
  4. The keeper (droplet config, "builders" block): "drip": { "enabled": true, "distributor": "$DIST",
     "start": "<the first UTC day after step 3>" }, dryRun left true for a day, then false.
  5. The site: site/config.js buildersDrip.distributor = "$DIST", then the usual site deploy.
  Distributor deploy block: $BLOCK
EOF
