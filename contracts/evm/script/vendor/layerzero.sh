#!/usr/bin/env bash
# Re-vendors the 12 files behind the LayerZero binding: OApp's upgradeable core/sender/
# receiver + their interface closure, hand-copied because neither package has a
# dedicated repo of its own that isolates just these files (see docs/provider-research.md §8).
#
# Usage: contracts/evm/script/vendor/layerzero.sh
#
# Bumping a pinned commit: edit the relevant COMMIT below, re-run, and diff the result
# before committing. Update the citation in docs/provider-research.md §8 to match.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

# --- @layerzerolabs/oapp-evm-upgradeable + @layerzerolabs/oapp-evm ---
# Both live in the same monorepo (LayerZero-Labs/devtools, 393MB, mostly off-chain
# tooling this repo has no use for), so one commit pin covers both packages.
DEVTOOLS_REPO="LayerZero-Labs/devtools"
DEVTOOLS_COMMIT="4973ba8bef7b0fdf7268469abea3ea50dbd4bbd8"
DEVTOOLS_NOTE=$'@layerzerolabs/oapp-evm-upgradeable and @layerzerolabs/oapp-evm have no\n// dedicated repo of their own; this is their actual home. See docs/provider-research.md §8.'

UPGRADEABLE_SRC="packages/oapp-evm-upgradeable/contracts/oapp"
UPGRADEABLE_DEST="contracts/evm/lib/layerzero-oapp-evm-upgradeable/contracts/oapp"
for f in OAppCoreUpgradeable OAppSenderUpgradeable OAppReceiverUpgradeable OAppUpgradeable; do
  vendor_file "$DEVTOOLS_REPO" "$DEVTOOLS_COMMIT" \
    "$UPGRADEABLE_SRC/$f.sol" "$UPGRADEABLE_DEST/$f.sol" "$DEVTOOLS_NOTE"
done

INTERFACES_SRC="packages/oapp-evm/contracts/oapp/interfaces"
INTERFACES_DEST="contracts/evm/lib/layerzero-oapp-evm/contracts/oapp/interfaces"
for f in IOAppCore IOAppReceiver; do
  vendor_file "$DEVTOOLS_REPO" "$DEVTOOLS_COMMIT" \
    "$INTERFACES_SRC/$f.sol" "$INTERFACES_DEST/$f.sol" "$DEVTOOLS_NOTE"
done

# --- @layerzerolabs/lz-evm-protocol-v2 ---
# LayerZero-Labs/LayerZero-v2 carries the whole V2 stack, on-chain and off; same
# reasoning, different repo.
V2_REPO="LayerZero-Labs/LayerZero-v2"
V2_COMMIT="9c741e7f9790639537b1710a203bcdfd73b0b9ac"
V2_NOTE=$'@layerzerolabs/lz-evm-protocol-v2 has no standalone package repo of its own;\n// this is its actual home. See docs/provider-research.md §8.'

V2_SRC="packages/layerzero-v2/evm/protocol/contracts/interfaces"
V2_DEST="contracts/evm/lib/layerzero-protocol-v2/contracts/interfaces"
for f in ILayerZeroEndpointV2 ILayerZeroReceiver IMessageLibManager IMessagingComposer \
  IMessagingChannel IMessagingContext; do
  vendor_file "$V2_REPO" "$V2_COMMIT" "$V2_SRC/$f.sol" "$V2_DEST/$f.sol" "$V2_NOTE"
done
