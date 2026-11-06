#!/usr/bin/env bash
# Re-vendors the Wormhole Core and Executor interfaces this binding depends on.
#
# Usage: contracts/evm/script/vendor/wormhole.sh
#
# Bumping the pinned commit: edit COMMIT below, re-run, and diff the result before
# committing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

REPO="wormhole-foundation/wormhole-solidity-sdk"
COMMIT="2cb855ea"
NOTE=$'Apache-2.0, like the rest of its source repo. No imports.'
DEST="contracts/evm/lib/wormhole-solidity-sdk/src"

for path in \
  interfaces/ICoreBridge.sol \
  interfaces/IExecutor.sol \
  Executor/Request.sol; do
  vendor_file "$REPO" "$COMMIT" "src/$path" "$DEST/$path" "$NOTE"
done
