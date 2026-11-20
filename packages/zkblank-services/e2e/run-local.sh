#!/usr/bin/env bash
# ZKBLANK, the full loop on a local chain: anvil -> deploy -> indexer + ASP + relayer -> client e2e.
# Uses anvil's public test keys only (never real funds). Run from anywhere:
#   bash packages/zkblank-services/e2e/run-local.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVICES="$(dirname "$HERE")"
CONTRACTS="$(dirname "$SERVICES")/contracts"
PORT=${ANVIL_PORT:-8545}
LOGS="$(mktemp -d)"

# anvil's well-known dev accounts #0 deployer, #1 postman (ASP), #2 Alice, #3 relayer
export DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export POSTMAN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export POSTMAN_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export ALICE_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
export RELAYER_PK=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
export RPC_URL="http://127.0.0.1:$PORT"
export DEPLOYMENT="$CONTRACTS/deployments/zkblank-local.json"

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

anvil --port "$PORT" --silent >"$LOGS/anvil.log" 2>&1 &
PIDS+=($!)
until cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; do sleep 0.3; done

mkdir -p "$CONTRACTS/deployments"
(cd "$CONTRACTS" && forge script script/zkblank/DeployLocal.s.sol --rpc-url "$RPC_URL" --broadcast >"$LOGS/deploy.log" 2>&1) \
  || { tail -20 "$LOGS/deploy.log"; exit 1; }
echo "deployed: $(tr -d '\n ' <"$DEPLOYMENT")"

node "$SERVICES/src/indexer.mjs" >"$LOGS/indexer.log" 2>&1 & PIDS+=($!)
node "$SERVICES/src/asp.mjs" >"$LOGS/asp.log" 2>&1 & PIDS+=($!)
node "$SERVICES/src/relayer.mjs" >"$LOGS/relayer.log" 2>&1 & PIDS+=($!)
for u in 8701/v1/health 8702/v1/health 8703/v1/relayer/details; do
  until curl -sf "http://127.0.0.1:$u" >/dev/null; do sleep 0.3; done
done
echo "services up: indexer :8701, asp :8702, relayer :8703"

node "$HERE/client.mjs" || { echo "--- logs"; tail -5 "$LOGS"/*.log; exit 1; }
