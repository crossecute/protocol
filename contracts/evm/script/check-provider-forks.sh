#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export ETH_RPC_URL="${ETH_RPC_URL:-https://eth.drpc.org}"
export ARBITRUM_RPC_URL="${ARBITRUM_RPC_URL:-https://arbitrum.gateway.tenderly.co}"
export FRAXTAL_RPC_URL="${FRAXTAL_RPC_URL:-https://fraxtal.drpc.org}"
export BASE_RPC_URL="${BASE_RPC_URL:-https://base.gateway.tenderly.co}"
export OPTIMISM_RPC_URL="${OPTIMISM_RPC_URL:-https://optimism.gateway.tenderly.co}"

export ETH_FORK_BLOCK=26458714
export ARBITRUM_FORK_BLOCK=526037294
export FRAXTAL_FORK_BLOCK=44198047
export FORK_BLOCK_ETHEREUM="$ETH_FORK_BLOCK" FORK_BLOCK_ARBITRUM="$ARBITRUM_FORK_BLOCK"
export FORK_BLOCK_FRAXTAL="$FRAXTAL_FORK_BLOCK" FORK_BLOCK_BASE=60020248 FORK_BLOCK_OPTIMISM=159797824

export ETH_RPC_TIMEOUT=20

check_block() {
    local chain="$1" rpc="$2" number="$3" expected="$4" actual
    if ! actual=$(timeout 30s cast block "$number" --rpc-url "$rpc" --field hash 2>/dev/null); then
        printf '%s RPC could not read block %s\n' "$chain" "$number" >&2
        return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        printf '%s block %s has hash %s, expected %s\n' "$chain" "$number" "$actual" "$expected" >&2
        return 1
    fi
    printf '%s block %s %s\n' "$chain" "$number" "$actual"
}

check_tests() {
    local IFS='|'
    timeout 480s forge test --match-contract "^($*)$" --json | python3 -c '
import json
import sys

try:
    suites = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit("Forge did not return test results")
expected = set(sys.argv[1:])
seen = set()
ok = True
for suite, result in suites.items():
    tests = result["test_results"]
    if tests:
        seen.add(suite.rsplit(":", 1)[1])
    for name, test in tests.items():
        status = test["status"]
        print(f"{status}: {suite}::{name}")
        if status != "Success":
            print(test["reason"] or status, file=sys.stderr)
            ok = False
if expected - seen:
    print("Missing test suites: " + ", ".join(sorted(expected - seen)), file=sys.stderr)
    ok = False
sys.exit(not ok)
' "$@"
}

check_common_blocks() {
    check_block Ethereum "$ETH_RPC_URL" "$ETH_FORK_BLOCK" \
        0x3eb68b00f48a61cd64d0e11e6b1d0c1e18805d9b376c6fa70cd3aa03bd3777b8
    check_block Arbitrum "$ARBITRUM_RPC_URL" "$ARBITRUM_FORK_BLOCK" \
        0x6464dfa11fc92945cbed4c56038dda469ae9ae4619d012aa0c5cde1be4fe167e
    check_block Fraxtal "$FRAXTAL_RPC_URL" "$FRAXTAL_FORK_BLOCK" \
        0x045e5b2728072c6823a6d545bf52c1cc747a6b4016381626311389257e706ab8
}

case "${1:-}" in
    layerzero)
        check_common_blocks
        check_tests LzConduitDvnForkTest LzDvnForkTest LzFraxtalDvnForkTest \
            LzOftForkTest LzOftForkDeliveryGasTest LzOftSignedForkTest
        ;;
    ccip)
        check_common_blocks
        check_block Base "$BASE_RPC_URL" "$FORK_BLOCK_BASE" \
            0x2bf33e9ff0ede12bdddbed8ef181060782b5bf8df67a59bfd784c619d9445f25
        check_block Optimism "$OPTIMISM_RPC_URL" "$FORK_BLOCK_OPTIMISM" \
            0xce2667dad11f2f36981d085845320d868cf5f8eed5c324f57afe36ad11c0673f

        export RPC_URL_ETHEREUM="$ETH_RPC_URL" RPC_URL_BASE="$BASE_RPC_URL" RPC_URL_OPTIMISM="$OPTIMISM_RPC_URL"
        export RPC_URL_ARBITRUM="$ARBITRUM_RPC_URL" RPC_URL_FRAXTAL="$FRAXTAL_RPC_URL"
        export CCIP_ROUTER_ETHEREUM=0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D
        export CCIP_ROUTER_BASE=0x881e3A65B4d4a04dD529061dd0071cf975F58bCD
        export CCIP_ROUTER_ARBITRUM=0x141fa059441E0ca23ce184B6A78bafD2A517DdE8
        export CCIP_ROUTER_OPTIMISM=0x3206695CaE29952f4b0c22a169725a865bc8Ce0f
        export CCIP_ROUTER_FRAXTAL=0x4bdF20477744Ec5F9DE738b5cC9ACd01763905ee

        check_tests CcipForkTest CcipOffRampTest CcipOffRampTransceiverTest
        timeout 300s forge script script/PreflightCcip.s.sol
        ;;
    *)
        printf 'Usage: %s {layerzero|ccip}\n' "$0" >&2
        exit 2
        ;;
esac
