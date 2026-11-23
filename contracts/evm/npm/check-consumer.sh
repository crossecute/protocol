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
import {
  ILzOftConduitFactoryAbi, ISignedReceiverAbi, ISignedTransmitterAbi, ISourceAuthorityGuardAbi, SafeBatchExecutorAbi,
} from "@crossecute/protocol/abi";

const has = (abi, type, name) => abi.some((entry) => entry.type === type && entry.name === name);

const create = ILzOftConduitFactoryAbi.find((entry) => entry.name === "createTransmitter");
assert.deepEqual(create.inputs.map(({ type }) => type), ["bytes32", "address", "tuple[]"]);
assert.equal(create.inputs[2].internalType, "struct ILzOftConduitFactory.Destination[]");
assert.deepEqual(create.inputs[2].components.map(({ name, type }) => [name, type]), [
  ["chainKey", "bytes32"], ["eid", "uint32"], ["oft", "address"],
]);

for (const [abi, names] of [
  [ILzOftConduitFactoryAbi, ["conduitSalt", "predictConduit", "destinationOf", "bootstrapRoute", "isSigned", "localChainKey",
    "PROXY_INIT_CODE_HASH", "SIGNED_BOOTSTRAP"]],
  [ISignedTransmitterAbi, ["quoteLeaf", "isRootRegistered", "isLeafRelayed"]],
]) {
  for (const name of names) {
    assert(abi.some((entry) => entry.type === "function" && entry.name === name
      && ["view", "pure"].includes(entry.stateMutability)), `Missing ${name} view`);
  }
}
const quoteLeaf = ISignedTransmitterAbi.find((entry) => entry.name === "quoteLeaf");
const relayLeaf = ISignedTransmitterAbi.find((entry) => entry.name === "relayLeaf");
assert.deepEqual(quoteLeaf.inputs, relayLeaf.inputs);

// Each interface ABI decodes what its implementation emits and reverts with.
for (const [abi, type, names] of [
  [ILzOftConduitFactoryAbi, "event", ["TransmitterCreated", "ReceiverCreated", "SignedConduitCreated"]],
  [ILzOftConduitFactoryAbi, "error", ["NoDestinations", "DestinationsNotSorted", "BadDestination", "NotInRoot"]],
  [ISignedTransmitterAbi, "event", ["RootRegistered", "LeafRelayed", "AuthorityRelayed"]],
  [ISignedTransmitterAbi, "error", ["RootNotRegistered", "LeafAlreadyRelayed", "InsufficientPayment", "NoSignedAuthority"]],
  [ISignedReceiverAbi, "event", ["LeafExecuted", "MessageExecuted"]],
  [ISignedReceiverAbi, "error", ["NonceNotNext", "ConflictingLeaf", "UnknownWire"]],
  [ISourceAuthorityGuardAbi, "event", ["AuthorityPublished", "AuthorityUpdateExecuted"]],
  [ISourceAuthorityGuardAbi, "error", ["NotActivated", "PositionNotExecuted", "AuthorityHashMismatch"]],
]) {
  for (const name of names) assert(has(abi, type, name), `Missing ${type} ${name}`);
}

const execute = SafeBatchExecutorAbi.find((entry) => entry.name === "execute");
assert.equal(execute.inputs[0].internalType, "struct SafeBatchExecutor.SafeExecution[]");
for (const name of ["stageUpdate", "publishedAuthority", "selection"]) {
  assert(has(ISourceAuthorityGuardAbi, "function", name), `Missing ${name}`);
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
    function encodeOftCreate(bytes32 salt, address homeOft, ILzOftConduitFactory.Destination[] calldata destinations)
        external pure returns (bytes memory)
    {
        return abi.encodeCall(ILzOftConduitFactory.createTransmitter, (salt, homeOft, destinations));
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
