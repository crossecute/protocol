#!/usr/bin/env bash
# Re-vendors the Hyperlane interfaces and pure libraries this binding depends on.
#
# Usage: contracts/evm/script/vendor/hyperlane.sh
#
# Bumping the pinned commit: edit COMMIT below, re-run, and diff the result before
# committing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
source contracts/evm/script/vendor/lib.sh

REPO="hyperlane-xyz/hyperlane-monorepo"
COMMIT="983831f6"
NOTE=$'MIT OR Apache-2.0, like the rest of its source repo. No OpenZeppelin imports, unlike\n// MailboxClient/Router.'
SRC="solidity/contracts"
DEST="contracts/evm/lib/hyperlane/solidity/contracts"

for path in \
  interfaces/IMailbox.sol \
  interfaces/IMessageRecipient.sol \
  interfaces/IInterchainSecurityModule.sol \
  interfaces/hooks/IPostDispatchHook.sol \
  libs/TypeCasts.sol \
  hooks/libs/StandardHookMetadata.sol; do
  vendor_file "$REPO" "$COMMIT" "$SRC/$path" "$DEST/$path" "$NOTE"
done
