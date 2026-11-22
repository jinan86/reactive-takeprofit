#!/usr/bin/env bash
# TakeProfit redeploy — Lasna reactive + Base Sepolia executor ONLY.
# Reuses the existing base stack (tokens/oracle/vault in
# deployments/base.json). Used after the v1 reactive fix (opCode gate bug).
# The old reactive (with its stranded lREACT) and old executor (with its
# stranded ETH) are abandoned; the vault is re-pointed at the new executor.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.foundry/bin:$PATH"
BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev/"

WALLET_JSON="$HOME/workspace/hackathons/reactive-buildathon/sentinel/.wallet.json"
[ -f "$WALLET_JSON" ] || { echo "ERROR: $WALLET_JSON not found"; exit 1; }
PK=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['private_key'])")
ADDR=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['address'])")
echo "Deployer: $ADDR"

ORACLE=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['oracle'])")
VAULT=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['vault'])")
echo "Reusing oracle=$ORACLE vault=$VAULT"

echo "=== Step B: deploy TakeProfitReactive (Lasna) ==="
ORACLE_ADDRESS="$ORACLE" VAULT_ADDRESS="$VAULT" forge script script/DeployLasna.s.sol --rpc-url "$LASNA_RPC" --private-key "$PK" --broadcast
REACTIVE=$(python3 -c "import json;print(json.load(open('deployments/lasna.json'))['reactive'])")
echo "Reactive: $REACTIVE"

echo "=== Step C: deploy OrderExecutor (Base Sepolia) ==="
REACTIVE_ADDRESS="$REACTIVE" VAULT_ADDRESS="$VAULT" ORACLE_ADDRESS="$ORACLE" forge script script/DeployExecutor.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
EXECUTOR=$(python3 -c "import json;print(json.load(open('deployments/executor.json'))['executor'])")
echo "Executor: $EXECUTOR"

echo "=== Wire up: reactive.setExecutor(executor) on Lasna ==="
cast send "$REACTIVE" "setExecutor(address)" "$EXECUTOR" --rpc-url "$LASNA_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(' tx:',json.load(sys.stdin).get('transactionHash'))"

echo "=== Verify ==="
echo "vault.executor: $(cast call "$VAULT" "executor()(address)" --rpc-url "$BASE_RPC")"
echo "reactive.executor: $(cast call "$REACTIVE" "executor()(address)" --rpc-url "$LASNA_RPC")"
echo "reactive balance: $(cast to-unit "$(cast balance "$REACTIVE" --rpc-url "$LASNA_RPC")" ether) lREACT"
echo "executor balance: $(cast to-unit "$(cast balance "$EXECUTOR" --rpc-url "$BASE_RPC")" ether) ETH"
echo "reactive=$REACTIVE executor=$EXECUTOR"
