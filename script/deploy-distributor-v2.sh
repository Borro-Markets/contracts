#!/usr/bin/env bash
# Deploys the new $BORRO payout distributor, the one with the owner's reclaim of anything no payout has promised
# (the owner runs this). Dry run first, then asks before sending. Reads the RPC and the deployer key from their
# files without printing either; writes script/out/pons-distributor-v2.json.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
KEY="$(cat "$HOME/.config/borro/deployer_key")"
export BORRO_TOKEN=0x89B76DCDDa801f2e456765742C64950eB2A0c93C PONS_OUT=script/out/pons-distributor-v2.json
forge script script/PonsDistributor.s.sol --rpc-url "$RPC" --sender "$(cast wallet address --private-key "$KEY")" 2>&1 | grep -E "distributor|owner|updater|guardian|Estimated amount|Error" || true
read -r -p "Deploy it for real? (y/n) " ok
[ "$ok" = "y" ] || { echo "nothing sent"; exit 0; }
forge script script/PonsDistributor.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY" 2>&1 | grep -E "distributor|ONCHAIN|Error|error" || true
python3 -c "
import json; r=json.load(open('broadcast/PonsDistributor.s.sol/4663/run-latest.json'))
for x in r['receipts']: print('tx', x['transactionHash'], 'chain block', int(x['blockNumber'],16), 'status', x['status'], 'contract', x.get('contractAddress'))"
cat script/out/pons-distributor-v2.json
