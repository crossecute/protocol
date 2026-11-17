#!/usr/bin/env bash
# Re-vendors the MIT-tagged CCIP application-facing files this binding depends on.
#
# Usage: contracts/evm/script/vendor/ccip.sh
#
# Bumping the pinned commit: edit COMMIT below, re-run, and diff the result before
# committing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

REPO="smartcontractkit/chainlink-ccip"
# @chainlink/contracts-ccip 2.0.0 (contracts-ccip-v2.0.0).
COMMIT="c2c125c27f056db2e98d21501922b6eff5750f36"
NOTE=$'MIT-tagged in its own SPDX header, distinct from the BUSL-1.1 router/off-ramp\n// infrastructure this repo only ever calls.'
DEST="contracts/evm/lib/ccip/contracts"

vendor_file "$REPO" "$COMMIT" \
  "chains/evm/contracts/interfaces/IAny2EVMMessageReceiver.sol" \
  "$DEST/interfaces/IAny2EVMMessageReceiver.sol" "$NOTE"

vendor_file "$REPO" "$COMMIT" \
  "chains/evm/contracts/interfaces/IRouterClient.sol" \
  "$DEST/interfaces/IRouterClient.sol" "$NOTE"

vendor_file "$REPO" "$COMMIT" \
  "chains/evm/contracts/libraries/Client.sol" \
  "$DEST/libraries/Client.sol" "$NOTE"

for path in applications/CCIPReceiver.sol interfaces/IAny2EVMMessageReceiverV2.sol libraries/FinalityCodec.sol libraries/ExtraArgsCodec.sol; do
  vendor_file "$REPO" "$COMMIT" "chains/evm/contracts/$path" "$DEST/$path" "$NOTE"
done

# Roles.supportsInterface reads storage; Solidity forbids a view override of pure.
sed -i 's/public pure virtual override/public view virtual override/' "$DEST/applications/CCIPReceiver.sol"
sed -i 's/Vendored, unmodified, from/Vendored, supportsInterface changed from pure to view, from/' "$DEST/applications/CCIPReceiver.sol"
