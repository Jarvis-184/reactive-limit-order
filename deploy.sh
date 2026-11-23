#!/bin/bash
# Deploy Reactive Limit Order: Unichain Sepolia (1301) + Reactive Lasna (5318007)
set -e
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")"
KEY=$(cat ~/.agentguard-admin-key)
UNICHAIN=https://sepolia.unichain.org
LASNA=https://lasna-rpc.rnk.dev/
DEPLOYER=$(cast wallet address --private-key $KEY)
TKA=0xafBF77C5587E365712416D6EFF9A40FDF2545F95

echo "deployer $DEPLOYER  TKA=$TKA"

deploy () { # $1=contract path:Name, $2=rpc, $3=value(or -), rest=ctor args
  local spec=$1 rpc=$2 val=$3; shift 3
  local args=(--rpc-url "$rpc" --private-key "$KEY" --broadcast --json)
  if [ "$rpc" = "$LASNA" ]; then args+=(--legacy); fi
  if [ "$val" != "-" ]; then args+=(--value "$val"); fi
  forge create "$spec" "${args[@]}" --constructor-args "$@" 2>/dev/null | grep -o '"deployedTo": *"[^"]*"' | cut -d'"' -f4
}

TKB=$(deploy src/TestToken.sol:TestToken $UNICHAIN - "Token B" "TKB"); echo "TKB=$TKB"
POOL=$(deploy src/MiniPool.sol:MiniPool $UNICHAIN - $TKA $TKB); echo "POOL=$POOL"

NONCE=$(cast nonce $DEPLOYER --rpc-url $LASNA)
REACTIVE=$(cast compute-address --nonce $NONCE $DEPLOYER | awk '{print $NF}')
echo "predicted REACTIVE=$REACTIVE (lasna nonce $NONCE)"

UNIPROXY=0x775c9B990ADe401060B78D0e98684eEf8d2466C1
VAULT=$(deploy src/LimitOrderVault.sol:LimitOrderVault $UNICHAIN - $UNIPROXY $REACTIVE $TKA $POOL); echo "VAULT=$VAULT"

REACTIVE_DEPLOYED=$(deploy src/LimitOrderReactive.sol:LimitOrderReactive $LASNA 1.5ether 1301 $VAULT $POOL); echo "REACTIVE_DEPLOYED=$REACTIVE_DEPLOYED"
[ "$REACTIVE_DEPLOYED" = "$REACTIVE" ] || { echo "ADDRESS MISMATCH!"; exit 1; }

echo "vault callback sender: $(cast call $VAULT '_CALLBACK_SENDER()(address)' --rpc-url $UNICHAIN)"
echo "$TKA $TKB $POOL $VAULT $REACTIVE_DEPLOYED" > deployed.txt
echo "ALL OK"
