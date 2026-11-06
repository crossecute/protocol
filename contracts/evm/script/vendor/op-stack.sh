#!/usr/bin/env bash
# Re-vendors the OP Stack messenger interfaces the two OP Stack bindings depend on:
# `CrossDomainMessenger` (op-stack-l1-l2) and `L2ToL2CrossDomainMessenger` (op-stack-l2-l2).
#
# Usage: contracts/evm/script/vendor/op-stack.sh
#
# Bumping the pinned commit: edit COMMIT below, re-run, and diff the result before
# committing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

REPO="ethereum-optimism/optimism"
COMMIT="0abfb166"
NOTE=$'MIT, like the rest of contracts-bedrock. No imports.'
P="packages/contracts-bedrock/interfaces/universal/ICrossDomainMessenger.sol"

vendor_file "$REPO" "$COMMIT" "$P" "contracts/evm/lib/optimism/$P" "$NOTE"

# Superchain interop, read later than the messenger above, so pinned separately.
INTEROP_COMMIT="dfe4f947ca48f872ce207c3e1e36a9256beaa044"
INTEROP_NOTE=$'MIT, like the rest of contracts-bedrock. Imports only ICrossL2Inbox, vendored\n// beside it.'
for P in packages/contracts-bedrock/interfaces/L2/ICrossL2Inbox.sol \
         packages/contracts-bedrock/interfaces/L2/IL2ToL2CrossDomainMessenger.sol; do
  vendor_file "$REPO" "$INTEROP_COMMIT" "$P" "contracts/evm/lib/optimism/$P" "$INTEROP_NOTE"
done
