#!/usr/bin/env bash
# Deploys the team reserve for real (Roy runs this himself, in his own Terminal): one TeamReserve for $BORRO, owned by
# the Hoard Safe. docs/OPS.md, "Team reserve".
#
#   bash ~/borro/contracts/script/deploy-team-reserve.sh
#
# 1. A dry run (simulated against the chain, nothing sent): the address, the owner and the gas it would cost.
# 2. It asks. Only on "y" it sends the one transaction, checks the receipt and the contract on chain, and writes
#    script/out/team-reserve.json with the receipt's chain block ("block"; the script itself can only see the parent
#    chain's block number, kept as "parentChainBlock").
#
# Nothing is funded here. Afterwards Roy checks the address on the explorer and sends the $BORRO to it himself; grants
# and withdrawals go through the Safe (keeper/tools/team-grant.mjs writes each one as a Safe batch).
#
# The RPC URL and the deployer key are read from their files and handed to forge through the environment: neither is
# printed or put on a command line. OWNER, ALLOW_EOA_OWNER and EXPECTED_AMOUNT pass through to the script
# (script/TeamReserve.s.sol says what each does).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
DEPLOYER=0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6
EXPLORER=https://robinhoodchain.blockscout.com
BORRO=0x89B76DCDDa801f2e456765742C64950eB2A0c93C
# BORRO_RPC_URL already set: a test chain. Otherwise Roy's endpoint.
if [ -z "${BORRO_RPC_URL:-}" ]; then
  BORRO_RPC_URL="$(cat "$HOME/.config/hoard/rpc_url")"
fi
export BORRO_RPC_URL
KEY_FILE="${DEPLOYER_KEY_FILE:-$HOME/.config/borro/deployer_key}"
SENDER="${DEPLOYER_ADDRESS:-$DEPLOYER}"
# The script refuses a key that is not this address's, before anything is sent.
export DEPLOYER_ADDRESS="$SENDER"
OUT_FILE="${RESERVE_OUT:-script/out/team-reserve.json}"
export RESERVE_OUT="$OUT_FILE"
RUN_FILE="${FOUNDRY_BROADCAST:-broadcast}/TeamReserve.s.sol/4663/run-latest.json"

# Everything forge or cast prints goes through this, so an error that quotes the RPC URL shows <rpc> instead.
scrub() { local s="$1"; printf '%s\n' "${s//"$BORRO_RPC_URL"/<rpc>}"; }

if [ -f "$OUT_FILE" ] && [ -z "${FORCE:-}" ]; then
  echo "$OUT_FILE already exists: the reserve was deployed before. Move it away (or FORCE=1) to deploy another."
  exit 1
fi

echo "Dry run from $SENDER (nothing is sent):"
set +e
dry="$(env -u DEPLOYER_PRIVATE_KEY forge script script/TeamReserve.s.sol --rpc-url robinhood --sender "$SENDER" 2>&1)"
status=$?
set -e
if [ "$status" != 0 ]; then
  scrub "$(printf '%s\n' "$dry" | grep -E "Error|error|revert|panic" | head -20)"
  echo "The dry run failed; nothing was sent."
  exit 1
fi
# The script's own summary (its console log), then the gas.
scrub "$(printf '%s\n' "$dry" | awk '/== Logs ==/ { on = 1; next } on && /^$/ { exit } on { print }')"
printf '%s\n' "$dry" | grep -E "Estimated amount required|Estimated total gas used" || true
# The dry run writes the record too; it is rewritten by the real run below.
rm -f "$OUT_FILE"
read -r -p "Deploy the team reserve for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }

key="$(tr -d ' \r\n' < "$KEY_FILE")"
[[ "$key" == 0x* ]] || key="0x$key"
set +e
live="$(DEPLOYER_PRIVATE_KEY="$key" forge script script/TeamReserve.s.sol --rpc-url robinhood --broadcast --slow --sender "$SENDER" 2>&1)"
status=$?
set -e
unset key
scrub "$(printf '%s\n' "$live" | grep -E "TeamReserve|ONCHAIN|Error|error|revert" || true)"
[ "$status" = 0 ] || { echo "forge stopped with an error (above). Read $RUN_FILE before trying again: the contract may already be on chain."; exit 1; }

# The receipt succeeded, came from the deployer and created the reserve; the record gets its chain block.
python3 - "$OUT_FILE" "$SENDER" "$RUN_FILE" <<'PY'
import json, sys
out_file, sender, run_file = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
receipts = json.load(open(run_file))["receipts"]
if not receipts: raise SystemExit("no receipts: nothing was sent")
bad = [r["transactionHash"] for r in receipts if r["status"] != "0x1"]
if bad: raise SystemExit(f"failed transactions: {bad}")
for r in receipts:
    if r["from"].lower() != sender: raise SystemExit(f"sent from {r['from']}, not {sender}")
if len(receipts) != 1: raise SystemExit(f"expected one transaction, found {len(receipts)}: read {run_file}")
out = json.load(open(out_file))
r = receipts[0]
if (r.get("contractAddress") or "").lower() != out["reserve"].lower():
    raise SystemExit(f"the receipt did not create the reserve named in {out_file}")
out["parentChainBlock"] = out.pop("block")
out["block"] = int(r["blockNumber"], 16)
out["tx"] = r["transactionHash"]
out["gasUsed"] = int(r["gasUsed"], 16)
json.dump(out, open(out_file, "w"), indent=2)
print(json.dumps(out, indent=2))
PY

# Read back from the chain itself: the code is the build recorded, and the token and owner are as planned.
field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT_FILE" "$1"; }
onchain() { local o; o="$(ETH_RPC_URL="$BORRO_RPC_URL" cast "$@" 2>&1)" || { scrub "$o" >&2; return 0; }; printf '%s' "${o%% *}"; }
RESERVE="$(field reserve)"
problems=0
expect() {
  local got want
  got="$(printf '%s' "$2" | tr 'A-F' 'a-f')"; want="$(printf '%s' "$3" | tr 'A-F' 'a-f')"
  if [ "$got" != "$want" ]; then echo "MISMATCH $1: the chain says '$2', expected '$3'"; problems=1; fi
}
expect "reserve code" "$(onchain codehash "$RESERVE")" "$(field reserveCodehash)"
expect "token" "$(onchain call "$RESERVE" 'token()(address)')" "$BORRO"
expect "owner" "$(onchain call "$RESERVE" 'owner()(address)')" "$(field owner)"
expect "pending owner" "$(onchain call "$RESERVE" 'pendingOwner()(address)')" "0x0000000000000000000000000000000000000000"
expect "nothing granted" "$(onchain call "$RESERVE" 'totalGranted()(uint256)')" "0"
expect "nothing queued" "$(onchain call "$RESERVE" 'totalQueued()(uint256)')" "0"
expect "withdrawal delay" "$(onchain call "$RESERVE" 'WITHDRAW_DELAY()(uint256)')" "2592000"
expect "execution window" "$(onchain call "$RESERVE" 'EXECUTE_WINDOW()(uint256)')" "1209600"
if [ "$problems" != 0 ]; then
  echo "Something on chain is not what was planned (above). Do NOT send any \$BORRO to it; read $OUT_FILE and $RUN_FILE first."
  exit 1
fi
echo "On chain: the reserve is the recorded build, for \$BORRO, owned by $(field owner)."

cat <<EOF

Deployed. Next (docs/OPS.md, "Team reserve"):
  1. Check it on the explorer: owner() is the Hoard Safe, token() is \$BORRO $BORRO.
       $EXPLORER/address/$RESERVE
  2. From the wallet that holds your \$BORRO, send the amount (34,100,000 planned) to the reserve, as a plain
     transfer, yourself:  $RESERVE
     Then check: unallocated() on the reserve equals what you sent.
  3. Grants, revokes and withdrawals go through the Safe. In ~/borro:
       node keeper/tools/team-grant.mjs grant --to <hire wallet> --amount <BORRO> --start <YYYY-MM-DD>
     writes a Safe batch to ~/Desktop/Borro/; load it in the Safe's Transaction Builder and sign with two owners.
EOF
