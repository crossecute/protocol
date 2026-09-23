#!/usr/bin/env bash
# Re-vendors the three MIT-tagged CCIP application-facing files this binding depends on.
#
# Usage: contracts/evm/script/vendor/ccip.sh
#
# Bumping the pinned commit: edit COMMIT below, re-run, and diff the result before
# committing. Update the citation in docs/provider-research.md and docs/todo.md to
# match, since both name this exact commit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

REPO="smartcontractkit/ccip"
COMMIT="171f9f0c"
NOTE=$'MIT-tagged in its own SPDX header, distinct from the BUSL-1.1 router/off-ramp\n// infrastructure this repo only ever calls. See\n// docs/provider-research.md#4-ccip-as-a-native-binding.'
DEST="contracts/evm/lib/ccip/contracts/src/v0.8/ccip"

vendor_file "$REPO" "$COMMIT" \
  "contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol" \
  "$DEST/interfaces/IAny2EVMMessageReceiver.sol" "$NOTE"

vendor_file "$REPO" "$COMMIT" \
  "contracts/src/v0.8/ccip/interfaces/IRouterClient.sol" \
  "$DEST/interfaces/IRouterClient.sol" "$NOTE"

vendor_file "$REPO" "$COMMIT" \
  "contracts/src/v0.8/ccip/libraries/Client.sol" \
  "$DEST/libraries/Client.sol" "$NOTE"
