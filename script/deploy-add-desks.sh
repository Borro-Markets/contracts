#!/usr/bin/env bash
# Adds the stock desks in script/stocks-add.json to the live Borro (docs/ADD-DESKS.md). The owner runs this.
#
#   script/deploy-add-desks.sh           dry run against the chain (sends nothing), then asks before sending for real
#   script/deploy-add-desks.sh --fork    rehearsal on a local anvil fork of the chain: funds the deployer with the
#                                        seeds by impersonation, runs the script with --broadcast against anvil only,
#                                        writes script/out/*.fork.json, stops anvil. Nothing reaches the chain.
#   ONLY=AAPL script/deploy-add-desks.sh one stock only (the files get -AAPL in their names)
#
# Reads the RPC and the deployer key from their files without printing either. The script itself checks every
# stock on chain, prints what the deployer must hold and refuses if it is short, opens the desks, hands each
# vault to the Hoard Safe, writes script/out/desks-add.json and the two Safe batches
# (script/out/safe-add-desks.json now, script/out/safe-add-desks-2-execute.json after 3 days), and simulates both
# batches from the Safe before it finishes. The listings themselves are the Safe's: load batch 1 in the Safe
# app's Transaction Builder and sign with two owners.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
DEPLOYER=0x82c33e1c6Ef8d4704d0AD064585D1FB4f83681E6
STOCKS="${STOCKS_ADD:-stocks-add.json}"
FILTER="checks out|needs|has|deployer|vault |adapter |oracle |market |USDG |bUSDG|cap|wrote|simulated|new desks|batch|NOTE|Error|error|revert|^[A-Z]{1,6}$"

if [ "${1:-}" = "--fork" ]; then
  PORT=8547
  anvil --fork-url "$RPC" --port $PORT --silent --no-storage-caching --auto-impersonate &
  ANVIL=$!
  trap 'kill $ANVIL 2>/dev/null || true' EXIT
  for _ in $(seq 1 60); do cast chain-id --rpc-url http://127.0.0.1:$PORT >/dev/null 2>&1 && break; sleep 0.5; done
  LOCAL=http://127.0.0.1:$PORT
  echo "anvil fork up on $LOCAL (chain id $(cast chain-id --rpc-url $LOCAL)); funding the deployer by impersonation"
  # 1 ETH: anvil quotes a gas price about 50 times the chain's, so the script's ETH check would otherwise refuse.
  cast rpc anvil_setBalance "$DEPLOYER" 0xDE0B6B3A7640000 --rpc-url $LOCAL >/dev/null
  # The seeds: each stock's pool (or the v4 PoolManager) holds plenty; a transfer from it on the fork is the seed.
  python3 - "$STOCKS" "$LOCAL" "$DEPLOYER" <<'PY'
import json, subprocess, sys, pathlib
stocks, rpc, dep = sys.argv[1:]
only = __import__("os").environ.get("ONLY", "")
CAST = str(pathlib.Path.home() / ".foundry/bin/cast")
PM = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
def rpc_(method, *params):
    subprocess.run([CAST, "rpc", method, *params, "--rpc-url", rpc], check=True, capture_output=True)
def give(token, holder, to, amount):
    rpc_("anvil_impersonateAccount", holder)
    subprocess.run([CAST, "send", token, "transfer(address,uint256)", to, str(amount), "--from", holder, "--unlocked", "--rpc-url", rpc], check=True, capture_output=True)
    rpc_("anvil_stopImpersonatingAccount", holder)
    # a holder that is a contract has no ETH for gas on the fork: give it some first (idempotent)
lst = json.load(open(pathlib.Path("script") / stocks))["stocks"]
n = 0
for s in lst:
    if only and s["symbol"] != only: continue
    holder = s["v3Pool"] if int(s["v3Pool"], 16) else PM
    rpc_("anvil_setBalance", holder, "0x2386F26FC10000")
    give(s["token"], holder, dep, int(s["seed"]))
    n += 1
    print("  gave the deployer", s["symbol"], "seed", s["seed"], "from", holder)
rpc_("anvil_setBalance", PM, "0x2386F26FC10000")
give(USDG, PM, dep, n * 100_000 + 1_000_000)
print("  gave the deployer USDG", n * 100_000 + 1_000_000)
PY
  set +e
  OUT_TAG=fork forge script script/AddDesks.s.sol --rpc-url $LOCAL --broadcast --slow --unlocked --sender "$DEPLOYER" 2>&1 \
    | grep -v "├─\|└─\|│" | grep -E "$FILTER"
  status=${PIPESTATUS[0]}
  set -e
  # The rehearsal's broadcast record carries the real chain id; drop it so a real --resume can never pick it up.
  rm -rf broadcast/AddDesks.s.sol
  [ "$status" = 0 ] || { echo "the rehearsal FAILED (see above); nothing was sent to the chain"; exit 1; }
  echo "rehearsal done: script/out/desks-add${ONLY:+-$ONLY}.fork.json and script/out/safe-add-desks${ONLY:+-$ONLY}.fork.json; nothing was sent to the chain"
  exit 0
fi

KEY="$(cat "$HOME/.config/borro/deployer_key")"
[ "$(cast wallet address --private-key "$KEY")" = "$DEPLOYER" ] || { echo "the key in ~/.config/borro/deployer_key is not the deployer"; exit 1; }
set +e
forge script script/AddDesks.s.sol --rpc-url "$RPC" --sender "$DEPLOYER" 2>&1 | grep -v "├─\|└─\|│" | grep -E "$FILTER"
status=${PIPESTATUS[0]}
set -e
[ "$status" = 0 ] || { echo "the dry run FAILED (see above); nothing sent"; exit 1; }
read -r -p "Add the desks for real (about 12.5M gas each, nothing goes to the Safe until it signs batch 1)? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }
set +e
forge script script/AddDesks.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY" 2>&1 | grep -v "├─\|└─\|│" | grep -E "$FILTER|ONCHAIN"
status=${PIPESTATUS[0]}
set -e
[ "$status" = 0 ] || { echo "the deploy FAILED part way: fix the cause, then re-run the forge command above with --resume"; exit 1; }
OUT_DIR="$HOME/Desktop/Borro/add-desks-$(date +%Y-%m-%d)"
mkdir -p "$OUT_DIR"
cp script/out/desks-add${ONLY:+-$ONLY}.json script/out/safe-add-desks${ONLY:+-$ONLY}.json script/out/safe-add-desks-2-execute${ONLY:+-$ONLY}.json "$OUT_DIR"/ 2>/dev/null || true
echo "done. Safe batch 1 (sign now): $OUT_DIR/safe-add-desks${ONLY:+-$ONLY}.json; batch 2 (after 3 days): safe-add-desks-2-execute${ONLY:+-$ONLY}.json"
echo "if it stopped part way: re-run the same forge command with --resume (never start over: the seeds and nonces are spent)"
