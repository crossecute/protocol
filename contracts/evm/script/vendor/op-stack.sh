#!/usr/bin/env bash
# Re-vendors the OP Stack messenger interface this binding depends on.
#
# Usage: contracts/evm/script/vendor/op-stack.sh
#
# Bumping the pinned commit: edit COMMIT below, re-run, and diff the result before
# committing. Update the citation in docs/provider-research.md and docs/todo.md to
# match, since both name this exact commit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

REPO="ethereum-optimism/optimism"
COMMIT="0abfb166"
NOTE=$'MIT, like the rest of contracts-bedrock. No imports. See\n// docs/provider-research.md#7-op-stack-as-a-native-binding.'
P="packages/contracts-bedrock/interfaces/universal/ICrossDomainMessenger.sol"

vendor_file "$REPO" "$COMMIT" "$P" "contracts/evm/lib/optimism/$P" "$NOTE"
