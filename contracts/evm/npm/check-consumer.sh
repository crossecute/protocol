#!/usr/bin/env bash
# Packs @crossecute/protocol and compiles every shipped source from a fresh project that installs
# it with OpenZeppelin from npm, so an import pack.mjs leaves unresolvable fails here. Run from
# contracts/evm after `forge build`.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

node npm/pack.mjs >/dev/null
tarball="$(cd npm && npm pack --ignore-scripts --json --pack-destination "$work" | node -p 'JSON.parse(require("fs").readFileSync(0))[0].filename')"
oz="$(node -p 'require("./npm/package.json").peerDependencies["@openzeppelin/contracts"]')"

cd "$work"
npm init -y >/dev/null
# forge reads foundry.lock through git and warns outside a repository.
git init -q
npm install --no-audit --no-fund --loglevel=error "./$tarball" "@openzeppelin/contracts@$oz" "@openzeppelin/contracts-upgradeable@$oz"

mkdir src
{
  echo '// SPDX-License-Identifier: MIT'
  # The oldest compiler the package README promises.
  echo 'pragma solidity 0.8.28;'
  (cd node_modules/@crossecute/protocol/contracts && find . -name '*.sol' | sort | sed 's#^\./#import "@crossecute/protocol/#; s#$#";#')
  echo 'contract All {}'
} > src/All.sol

cat > foundry.toml <<'TOML'
[profile.default]
src = "src"
libs = ["node_modules"]
solc_version = "0.8.28"
remappings = [
    "@crossecute/protocol/=node_modules/@crossecute/protocol/contracts/",
    "@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/",
    "@openzeppelin/contracts-upgradeable/=node_modules/@openzeppelin/contracts-upgradeable/",
]
TOML

echo "compiling $(grep -c '^import' src/All.sol) shipped sources from $tarball"
forge build
