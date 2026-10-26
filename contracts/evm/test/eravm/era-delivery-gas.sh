#!/usr/bin/env bash
# Measures, on a local EraVM node, the gas a delivery to a zkSync transceiver needs: the
# smallest gas limit on the transceiver's `handle` (or a receiver's) under which it succeeds.
# That limit is what `DeliveryGas` sets. Each probe is an eth_call against the same state,
# so every bootstrap creates its conduit against cold storage.
#
# Needs anvil-zksync and foundry-zksync's forge and cast:
#   ANVIL_ZKSYNC=... FORGE_ZKSYNC=... CAST_ZKSYNC=... test/eravm/era-delivery-gas.sh [anvil-zksync options]
# Extra arguments go to anvil-zksync, e.g. --l1-pubdata-price to vary what pubdata costs.
set -euo pipefail

: "${ANVIL_ZKSYNC:?path to anvil-zksync}" "${FORGE_ZKSYNC:?path to foundry-zksync forge}"
: "${CAST_ZKSYNC:?path to foundry-zksync cast}"
PORT="${PORT:-8011}"
RPC="http://127.0.0.1:$PORT"
cd "$(dirname "$0")/../.."

LOG="$(mktemp)"
NODE_LOG="$(mktemp)"
"$ANVIL_ZKSYNC" --offline --port "$PORT" --log-file-path "$NODE_LOG" "$@" > "$LOG" 2>&1 &
NODE=$!
# NODE_OUT=<file> keeps the node's output, which lists each transaction's gas.
trap 'kill $NODE 2>/dev/null || true; [ -n "${NODE_OUT:-}" ] && cp "$LOG" "$NODE_OUT"; rm -f "$LOG" "$NODE_LOG"' EXIT
for _ in $(seq 60); do
  "$CAST_ZKSYNC" chain-id --rpc-url "$RPC" > /dev/null 2>&1 && break
  sleep 1
done

cast() { "$CAST_ZKSYNC" "$@" --rpc-url "$RPC"; }
# The node's first local test conduit, whose key it prints at startup. Deployments are signed,
# not sent unlocked: only a signed EIP-712 transaction carries the factory deps a deployment
# needs, and without them ContractDeployer reverts `UnknownCodeHash`. `--slow` waits for each
# receipt: the node validates a nonce against the conduit's current one, even when estimating.
KEY="$(awk '/^Private Keys/ { f = 1 } f && /^\(0\) / { print $2; exit }' "$LOG")"

# Only this directory and what it imports: zksolc rejects ripemd160 (`BitcoinDerive`) and the
# Tron variants' EXTCODECOPY, which the rest of the tree compiles.
OUT="$(FOUNDRY_SRC=test/eravm FOUNDRY_TEST=test/eravm FOUNDRY_SCRIPT=test/eravm "$FORGE_ZKSYNC" script \
  test/eravm/EraDeliveryGas.s.sol:EraDeliveryGas --zk-compile --rpc-url "$RPC" --broadcast \
  --private-key "$KEY" --slow 2>&1)" || { echo "$OUT"; exit 1; }
# console.log lines are indented under "== Logs ==".
LOGS="$(sed -n '/== Logs ==/,/^$/p' <<< "$OUT" | sed 's/^ *//')"
field() { awk -v k="$1" '$1 == k { print $2 }' <<< "$LOGS"; }
after() { awk -v k="$1" -v n="$2" 'f && ++i == n { print; exit } $0 == k { f = 1 }' <<< "$LOGS"; }

MAILBOX="$(field mailbox)"
T="$(field transceiver)"
echo "transceiver $T, conduitBytecodeHash $(after conduitBytecodeHash 1)"

OWNER="$(cast call "$T" 'owner()(address)')"
cast rpc anvil_impersonateAccount "$OWNER" > /dev/null
cast rpc anvil_setBalance "$OWNER" 0xde0b6b3a7640000 > /dev/null
for i in 1 2 3 4; do
  cast send --unlocked --from "$OWNER" "$T" "$(after ownerCalls "$i")" > /dev/null
done

HOME_TRANSCEIVER=0x000000000000000000000000000000000000c0de
TRANSMITTER=0x0000000000000000000000000000000000007a11
HOME_KEY="$(after messages 4)"

# Smallest gas limit under which `deliver` succeeds, to the nearest 100.
min_gas() {
  local to="$1" sender="$2" message="$3" lo=0 hi=4000000 mid
  while (( hi - lo > 100 )); do
    mid=$(( (lo + hi) / 2 ))
    if cast call "$MAILBOX" 'deliver(address,uint32,bytes32,bytes,uint256)' \
      "$to" 8453 "$("$CAST_ZKSYNC" to-uint256 "$sender")" "$message" "$mid" > /dev/null 2>&1; then
      hi=$mid
    else
      lo=$mid
    fi
  done
  echo "$hi"
}

echo "bootstrap, no calls:  $(min_gas "$T" "$HOME_TRANSCEIVER" "$(after messages 1)")"
echo "bootstrap, one call:  $(min_gas "$T" "$HOME_TRANSCEIVER" "$(after messages 2)")"

# Create the first conduit for real, then measure a payload to its receiver.
TX="$(cast send --private-key "$KEY" "$MAILBOX" 'deliver(address,uint32,bytes32,bytes,uint256)' \
  "$T" 8453 "$("$CAST_ZKSYNC" to-uint256 "$HOME_TRANSCEIVER")" "$(after messages 1)" 3000000 --gas-limit 20000000 --json)"
echo "bootstrap tx, no calls: status $(jq -r .status <<< "$TX"), gasUsed $("$CAST_ZKSYNC" to-dec "$(jq -r .gasUsed <<< "$TX")")"
RECEIVER="$(cast call "$T" 'predictCrossConduit(address,bytes32,bytes32)(address)' 0x000000000000000000000000000000000000A110 \
  0x0000000000000000000000000000000000000000000000000000000000000000 "$HOME_KEY")"
echo "payload, no calls:    $(min_gas "$RECEIVER" "$TRANSMITTER" "$(after messages 3)")"
