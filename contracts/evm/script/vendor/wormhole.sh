#!/usr/bin/env bash
# Re-vendors the Wormhole Relayer interface this binding depends on.
#
# Usage: contracts/evm/script/vendor/wormhole.sh
#
# Bumping the pinned commit: edit COMMIT below, re-run, and diff the result before
# committing. Update the citation in docs/provider-research.md and docs/todo.md to
# match, since both name this exact commit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

REPO="wormhole-foundation/wormhole-solidity-sdk"
COMMIT="2cb855ea"
NOTE=$'Apache-2.0, like the rest of its source repo. No imports; declares IWormholeReceiver\n// too. See docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings.'
DEST="contracts/evm/lib/wormhole-solidity-sdk/src"

vendor_file "$REPO" "$COMMIT" \
  "src/interfaces/IWormholeRelayer.sol" \
  "$DEST/interfaces/IWormholeRelayer.sol" "$NOTE"
