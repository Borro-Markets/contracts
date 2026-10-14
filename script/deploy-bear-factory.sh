#!/usr/bin/env bash
# Deploys BearFactory to Robinhood Chain for real (Roy runs this himself). Reads the RPC and the deployer key from
# their files without printing either; writes script/out/bear-factory.json. Dry run it first by leaving out --broadcast.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC="$(cat "$HOME/.config/hoard/rpc_url")"
KEY="$(cat "$HOME/.config/borro/deployer_key")"
"$HOME/.foundry/bin/forge" script script/BearFactory.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$KEY"
echo
cat script/out/bear-factory.json
