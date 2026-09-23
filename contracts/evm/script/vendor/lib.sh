#!/usr/bin/env bash
# The engine behind contracts/evm/script/vendor/<provider>.sh. Not run directly.
#
# Every native provider binding hand-copies a handful of application-facing files
# (interfaces, a codec library) rather than pulling in a provider's full SDK repo as a
# submodule, because none of them ship an isolated package for just those files: the
# LayerZero, CCIP, and Hyperlane repos each mix the files a binding actually needs with
# a much larger tree under a different license (see docs/todo.md and
# docs/provider-research.md for the per-provider reasoning). A driver script per
# provider calls vendor_file below once per file, naming the exact source commit; running
# it again re-fetches every file fresh and reapplies the provenance header, so bumping a
# pinned version is "edit the commit, re-run, diff" instead of a hand copy-paste.
set -euo pipefail

# vendor_file <repo> <commit> <upstream_path> <dest_path> <license_note>
#
#   repo          "owner/name", e.g. "smartcontractkit/ccip"
#   commit        the pinned commit (short or full SHA) -- never a branch or tag, either
#                 of which can move out from under the pin
#   upstream_path the file's path in that repo at that commit
#   dest_path     where to write it, relative to the repo root
#   license_note  one line, folded into the provenance comment -- state which SPDX tag
#                 the file itself carries, and why that differs from the rest of its
#                 source repo where it does
vendor_file() {
  local repo="$1" commit="$2" upstream_path="$3" dest_path="$4" license_note="$5"
  local url="https://raw.githubusercontent.com/${repo}/${commit}/${upstream_path}"

  mkdir -p "$(dirname "$dest_path")"
  if ! curl -sf "$url" -o "$dest_path"; then
    echo "vendor_file: failed to fetch $url" >&2
    return 1
  fi

  # Provenance comment goes right after line 1, which every vendored file here starts
  # with its own `// SPDX-License-Identifier: ...` tag -- so the comment sits ahead of
  # `pragma solidity` and everything else, immediately under the license it is about.
  awk -v repo="$repo" -v commit="$commit" -v path="$upstream_path" -v note="$license_note" '
    NR == 1 {
      print
      print ""
      print "// Vendored, unmodified, from " repo " @ " commit
      print "// (" path ")."
      print "// " note
      next
    }
    { print }
  ' "$dest_path" > "$dest_path.vendor_tmp" && mv "$dest_path.vendor_tmp" "$dest_path"

  echo "vendored ${repo}@${commit}:${upstream_path} -> ${dest_path}"
}
