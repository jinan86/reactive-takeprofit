#!/usr/bin/env bash
# TakeProfit live demo (testnet only):
#  (1) create order: sell 10 tTOKEN when price >= $2000, payee = deployer
#  (2) set price $1500 (below target) -> reactive sees it, NO execution
#  (3) set price $2100 (above target) -> reactive fires -> callback executes
#      -> payee receives exactly 10 * $2100 = 21,000 tUSD
#  (4) set price $2200 again -> second callback requested but order is
#      already executed: no double pay (payee balance unchanged)
# All tx hashes are printed and logged to demo-run.log.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.foundry/bin:$PATH"
BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
LOG="demo-run.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

WALLET_JSON="$HOME/workspace/hackathons/reactive-buildathon/sentinel/.wallet.json"
PK=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['private_key'])")
ADDR=$(python3 -c "import json;print(json.load(open('$WALLET_JSON'))['data'][0]['address'])")

TUSD=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['tUSD'])")
TTOKEN=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['tTOKEN'])")
ORACLE=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['oracle'])")
VAULT=$(python3 -c "import json;print(json.load(open('deployments/base.json'))['vault'])")
REACTIVE=$(python3 -c "import json;print(json.load(open('deployments/lasna.json'))['reactive'])")
EXECUTOR=$(python3 -c "import json;print(json.load(open('deployments/executor.json'))['executor'])")

echo "Deployer/payee: $ADDR"
echo "tUSD=$TUSD tTOKEN=$TTOKEN oracle=$ORACLE vault=$VAULT"
echo "reactive=$REACTIVE executor=$EXECUTOR"

txhash() { python3 -c "import json,sys;print(json.load(sys.stdin).get('transactionHash',''))"; }

poll_until() { # poll_until <desc> <cmd...> -- polls a cast call until output == expected
  local desc="$1"; local want="$2"; shift 2
  echo -n "Polling $desc (want $want) ..."
  for i in $(seq 1 36); do
    got=$("$@" 2>/dev/null | tr -d '[:space:]' || echo "?")
    if [ "$got" = "$want" ]; then echo " OK after ${i}x10s (=$got)"; return 0; fi
    sleep 10; echo -n "."
  done
  echo " TIMEOUT (last=$got)"; return 1
}

echo
echo "=== Step 0: approve vault for 10 tTOKEN ==="
cast send "$TTOKEN" "approve(address,uint256)" "$VAULT" 10000000000000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | txhash | xargs -I{} echo " approve tx: {}"

echo
echo "=== Step 1: create order — sell 10 tTOKEN at >= \$2000, payee deployer ==="
ORDER_TX=$(cast send "$VAULT" "createOrder(address,uint256,uint256,address)" "$TTOKEN" 10000000000000000000 200000000000 "$ADDR" --rpc-url "$BASE_RPC" --private-key "$PK" --json | txhash)
echo " createOrder tx: $ORDER_TX"
ORDER_ID=$(( $(cast call "$VAULT" "nextOrderId()(uint256)" --rpc-url "$BASE_RPC") - 1 ))
echo " order id: $ORDER_ID"
echo " https://sepolia.basescan.org/tx/$ORDER_TX"
sleep 5
echo " vault tTOKEN balance: $(cast call "$TTOKEN" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) tTOKEN (expect 10)"
echo " nextOrderId: $(cast call "$VAULT" "nextOrderId()(uint256)" --rpc-url "$BASE_RPC")"

echo
echo "=== Step 2: price \$1500 (BELOW target) — expect NO execution ==="
BELOW_TX=$(cast send "$ORACLE" "setPrice(uint256)" 150000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | txhash)
echo " setPrice(1500) tx: $BELOW_TX"
echo " https://sepolia.basescan.org/tx/$BELOW_TX"
# Wait for the reactive to process the PriceUpdate (reactCount rises, actedCount stays 0).
poll_until "reactive.reactCount -> 2 (order mirror + price)" "2" cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC" || true
sleep 20
echo " reactive.reactCount: $(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC")"
echo " reactive.actedCount: $(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC") (expect 0)"
echo " reactive.lastPrice: $(cast call "$REACTIVE" "lastPrice()(uint256)" --rpc-url "$LASNA_RPC") (expect 150000000000)"
echo " order active: $(cast call "$VAULT" "orders(uint256)(address,address,uint256,uint256,address,bool,bool)" $ORDER_ID --rpc-url "$BASE_RPC")"
echo " payee tUSD: $(cast call "$TUSD" "balanceOf(address)(uint256)" "$ADDR" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) (expect 0)"

echo
echo "=== Step 3: price \$2100 (ABOVE target) — expect execution ==="
ABOVE_TX=$(cast send "$ORACLE" "setPrice(uint256)" 210000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | txhash)
echo " setPrice(2100) tx: $ABOVE_TX"
echo " https://sepolia.basescan.org/tx/$ABOVE_TX"
poll_until "reactive.actedCount -> 1" "1" cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC" || true
echo " reactive.reactCount: $(cast call "$REACTIVE" "reactCount()(uint256)" --rpc-url "$LASNA_RPC")"
echo " reactive.actedCount: $(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC") (expect 1)"
echo " reactive.lastPrice: $(cast call "$REACTIVE" "lastPrice()(uint256)" --rpc-url "$LASNA_RPC") (expect 210000000000)"
# Wait for the callback to settle on Base Sepolia (order executed flag).
poll_until "order executed" "true" bash -c "cast call \"$VAULT\" \"orders(uint256)(address,address,uint256,uint256,address,bool,bool)\" $ORDER_ID --rpc-url \"$BASE_RPC\" | tail -1 | tr -d '[:space:]'" || true
echo " order #$ORDER_ID: $(cast call "$VAULT" "orders(uint256)(address,address,uint256,uint256,address,bool,bool)" $ORDER_ID --rpc-url "$BASE_RPC")"
echo " payee tUSD: $(cast call "$TUSD" "balanceOf(address)(uint256)" "$ADDR" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) (expect 21000)"
echo " vault tUSD left: $(cast call "$TUSD" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) (expect 979000)"

echo
echo "=== Step 4: price \$2200 again — second callback must NOT pay twice ==="
AGAIN_TX=$(cast send "$ORACLE" "setPrice(uint256)" 220000000000 --rpc-url "$BASE_RPC" --private-key "$PK" --json | txhash)
echo " setPrice(2200) tx: $AGAIN_TX"
echo " https://sepolia.basescan.org/tx/$AGAIN_TX"
sleep 60
echo " reactive.actedCount: $(cast call "$REACTIVE" "actedCount()(uint256)" --rpc-url "$LASNA_RPC") (expect 2 — duplicate callback requested)"
echo " order #$ORDER_ID executed stays true; payee tUSD: $(cast call "$TUSD" "balanceOf(address)(uint256)" "$ADDR" --rpc-url "$BASE_RPC" | awk '{print $1}' | xargs -I{} cast to-unit {} ether) (expect still 21000 — no double pay)"

echo
echo "=== Step 5: unauthenticated / direct execution attempts must fail ==="
echo "-- direct vault.executeOrder as deployer (not executor):"
cast send "$VAULT" "executeOrder(uint256,uint256)" $ORDER_ID 220000000000 --rpc-url "$BASE_RPC" --private-key "$PK" 2>&1 | tail -2 || true
echo "-- direct executor.execute as deployer (not the proxy):"
cast send "$EXECUTOR" "execute(address,uint256)" "$REACTIVE" $ORDER_ID --rpc-url "$BASE_RPC" --private-key "$PK" 2>&1 | tail -2 || true
echo
echo "Demo done. See demo-run.log for the full trail."
