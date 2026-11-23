#!/usr/bin/env bash
# Packs @crossecute/protocol and compiles every shipped source from a fresh project that installs
# it with OpenZeppelin from npm, so an import pack.mjs leaves unresolvable fails here.
# Run from contracts/evm.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

npm --prefix npm run build
tarball="$(cd npm && npm pack --ignore-scripts --json --pack-destination "$work" | node -p 'JSON.parse(require("fs").readFileSync(0))[0].filename')"
oz="$(node -p 'require("./npm/package.json").peerDependencies["@openzeppelin/contracts"]')"

cd "$work"
npm init -y >/dev/null
# forge reads foundry.lock through git and warns outside a repository.
git init -q
npm install --no-audit --no-fund --loglevel=error "./$tarball" "@openzeppelin/contracts@$oz" "@openzeppelin/contracts-upgradeable@$oz"

node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { ILzOftCreateAbi, ISourceAuthorityGuardAbi, SafeBatchExecutorAbi } from "@crossecute/protocol/abi";

const create = ILzOftCreateAbi.find((entry) => entry.name === "createTransmitter");
assert.deepEqual(create.inputs.map(({ type }) => type), ["bytes32", "address", "tuple[]"]);
assert.equal(create.inputs[2].internalType, "struct ILzOftCreate.OftLeaf[]");
assert.deepEqual(create.inputs[2].components.map(({ name, type }) => [name, type]), [
  ["chainKey", "bytes32"], ["eid", "uint32"], ["oft", "address"],
]);
const execute = SafeBatchExecutorAbi.find((entry) => entry.name === "execute");
assert.equal(execute.inputs[0].internalType, "struct SafeBatchExecutor.SafeExecution[]");
for (const name of ["stageUpdate", "publishedAuthority", "selection", "AuthorityPublished", "AuthorityUpdateExecuted"]) {
  assert(ISourceAuthorityGuardAbi.some((entry) => entry.name === name), `Missing ${name}`);
}
JS

mkdir src
{
  echo '// SPDX-License-Identifier: MIT'
  # The oldest compiler the package README promises.
  echo 'pragma solidity 0.8.28;'
  (cd node_modules/@crossecute/protocol/contracts && find . -name '*.sol' | sort | sed 's#^\./#import "@crossecute/protocol/#; s#$#";#')
  cat <<'SOL'
contract All {
    function encodeOftCreate(bytes32 salt, address homeOft, ILzOftCreate.OftLeaf[] calldata leaves)
        external pure returns (bytes memory)
    {
        return abi.encodeCall(ILzOftCreate.createTransmitter, (salt, homeOft, leaves));
    }
}
SOL
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
