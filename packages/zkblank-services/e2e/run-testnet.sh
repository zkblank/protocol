#!/usr/bin/env bash
# ZKBLANK, the full loop on Robinhood Chain TESTNET (46630), with the indexer, ASP and relayer running locally.
# Keys come from ~/.zkblank-testnet/keys.json (relayer, postman, alice; testnet only, mode 600).
#   bash packages/zkblank-services/e2e/run-testnet.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVICES="$(dirname "$HERE")"
CONTRACTS="$(dirname "$SERVICES")/contracts"
KEYS="$HOME/.zkblank-testnet/keys.json"
LOGS="$(mktemp -d)"

export RPC_URL="${RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
export DEPLOYMENT="$CONTRACTS/deployments/zkblank-testnet.json"
key() { python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['pk'])" "$KEYS" "$1"; }
export RELAYER_PK="$(key relayer)" POSTMAN_PK="$(key postman)" ALICE_PK="$(key alice)"
export DEPOSIT_WEI="${DEPOSIT_WEI:-2000000000000000}" WAIT_MS="${WAIT_MS:-120000}" POLL_MS="${POLL_MS:-1500}"

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

node "$SERVICES/src/indexer.mjs" >"$LOGS/indexer.log" 2>&1 & PIDS+=($!)
node "$SERVICES/src/asp.mjs" >"$LOGS/asp.log" 2>&1 & PIDS+=($!)
node "$SERVICES/src/relayer.mjs" >"$LOGS/relayer.log" 2>&1 & PIDS+=($!)
for u in 8701/v1/health 8702/v1/health 8703/v1/relayer/details; do
  until curl -sf "http://127.0.0.1:$u" >/dev/null; do sleep 0.5; done
done
echo "services up against $RPC_URL"

node "$HERE/client.mjs" || { echo "--- logs"; tail -8 "$LOGS"/*.log; exit 1; }
