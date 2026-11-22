#!/usr/bin/env bash
# TakeProfit deploy — Base Sepolia stack + Lasna reactive + executor.
# Order: A (Base: tokens/oracle/vault) -> B (Lasna: reactive + lREACT)
#     -> C (Base: executor + wire vault.setExecutor + reactive.setExecutor)
# Testnet only. The project wallet key lives in the Sentinel .wallet.json
# (mode 600, outside this repo); it is read into a shell variable and
# NEVER echoed or logged.
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
echo "Base Sepolia balance: $(cast to-unit "$(cast balance "$ADDR" --rpc-url "$BASE_RPC")" ether) ETH"
echo "Lasna balance: $(cast to-unit "$(cast balance "$ADDR" --rpc-url "$LASNA_RPC")" ether) lREACT"

echo "=== Step A: deploy base stack (Base Sepolia) ==="
forge script script/DeployBase.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
TUSD=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['tUSD'])")
TTOKEN=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['tTOKEN'])")
ORACLE=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['oracle'])")
VAULT=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['vault'])")
echo "tUSD: $TUSD  tTOKEN: $TTOKEN  Oracle: $ORACLE  Vault: $VAULT"

echo "=== Step B: deploy TakeProfitReactive (Lasna) ==="
ORACLE_ADDRESS="$ORACLE" VAULT_ADDRESS="$VAULT" forge script script/DeployLasna.s.sol --rpc-url "$LASNA_RPC" --private-key "$PK" --broadcast
REACTIVE=$(python3 -c "import json;print(json.load(open('deployments/lasna.json'))['reactive'])")
echo "Reactive: $REACTIVE"
echo -n "Reactive on-chain code check: "
cast code "$REACTIVE" --rpc-url "$LASNA_RPC" | wc -c

echo "=== Step C: deploy OrderExecutor (Base Sepolia) ==="
REACTIVE_ADDRESS="$REACTIVE" VAULT_ADDRESS="$VAULT" ORACLE_ADDRESS="$ORACLE" forge script script/DeployExecutor.s.sol --rpc-url "$BASE_RPC" --private-key "$PK" --broadcast
EXECUTOR=$(python3 -c "import json;print(json.load(open('deployments/executor.json'))['executor'])")
echo "Executor: $EXECUTOR"

echo "=== Wire up: reactive.setExecutor(executor) on Lasna ==="
cast send "$REACTIVE" "setExecutor(address)" "$EXECUTOR" --rpc-url "$LASNA_RPC" --private-key "$PK" --json | python3 -c "import json,sys;print(' tx:',json.load(sys.stdin).get('transactionHash'))"

echo "=== Verify ==="
echo "vault.executor: $(cast call "$VAULT" "executor()(address)" --rpc-url "$BASE_RPC")"
echo "reactive.executor: $(cast call "$REACTIVE" "executor()(address)" --rpc-url "$LASNA_RPC")"
echo "reactive.oracle: $(cast call "$REACTIVE" "oracle()(address)" --rpc-url "$LASNA_RPC")"
echo "reactive.vault: $(cast call "$REACTIVE" "vault()(address)" --rpc-url "$LASNA_RPC")"
echo "oracle.price: $(cast call "$ORACLE" "price()(uint256)" --rpc-url "$BASE_RPC")"
echo "vault tUSD balance: $(cast call "$TUSD" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether)"
echo "deployer tTOKEN balance: $(cast call "$TTOKEN" "balanceOf(address)(uint256)" "$ADDR" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether)"
echo "reactive balance: $(cast to-unit "$(cast balance "$REACTIVE" --rpc-url "$LASNA_RPC")" ether) lREACT"
echo "executor balance: $(cast to-unit "$(cast balance "$EXECUTOR" --rpc-url "$BASE_RPC")" ether) ETH"
echo
echo "TakeProfit deployed:"
echo "  tUSD=$TUSD tTOKEN=$TTOKEN oracle=$ORACLE vault=$VAULT"
echo "  reactive=$REACTIVE executor=$EXECUTOR"
