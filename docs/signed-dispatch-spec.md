# Signed dispatch: owner signatures checked on every destination

Status: design, not built. Dated 2026-10-28. This resolves the trust assumption that
[crossecute/protocol#99](https://github.com/crossecute/protocol/pull/99) records for
attestation-based providers: a destination conduit runs a payload only if the owner's own
signers signed it, so a provider alone cannot deliver one. It covers how signers build and
sign a Merkle root of per-chain dispatches, how a destination verifies one leaf, and how
signer sets rotate.

It is built in two iterations:

1. **This spec.** The existing providers deliver the signed bundle, and the destination checks
   the signatures as well as the provider's authentication.
2. **A custom provider**
   ([crossecute/protocol#101](https://github.com/crossecute/protocol/issues/101)). Anyone
   relays the same signed bundle with no third-party transport. It adds the freeze, relayer
   fees, discovery and relayer-facing errors that permissionless relay needs. The signed
   formats here are designed so it adds a delivery path rather than a new signing scheme.

How this iteration attaches to the existing contracts is open (section 9).

Keywords MUST, MUST NOT, SHOULD and MAY are used in the RFC 2119 sense.

## Contents

| | |
| --- | --- |
| [1. Trust model](#1-trust-model) | what each party can and cannot do |
| [2. Terms](#2-terms) | |
| [3. Data types](#3-data-types) | calls, leaves, the tree, the signed messages, the signer tree |
| [4. Conduit state](#4-conduit-state) | what each destination stores |
| [5. Building, signing and sending](#5-building-signing-and-sending) | off-chain steps and the home transaction |
| [6. Verification on a destination](#6-verification-on-a-destination) | dispatch, rotation, nonces |
| [7. Errors](#7-errors) | |
| [8. Keeping a Safe home in step](#8-keeping-a-safe-home-in-step) | the guard |
| [9. Open: integration with this repository](#9-open-integration-with-this-repository) | |
| [10. Size and cost](#10-size-and-cost-estimates-not-measured) | |
| [11. Required tests](#11-required-tests) | |
| [12. Decisions](#12-decisions) | what was chosen and why |

## 1. Trust model

A destination runs a payload only when both hold:

- a provider delivered it from the conduit's home, authenticated as today; and
- a quorum of the conduit's current signer tree signed it.

So a provider alone cannot deliver a payload: forging one needs the signers too. A provider
can still withhold or delay one, so liveness still rests on the providers.

Every message reaches a destination only because the owner executed a transaction at home,
which the existing providers require. That keeps two properties this iteration relies on:

- **The full quorum is met before anything is sent.** There is no message that fewer signers
  can send, which is why a sub-quorum freeze belongs to the custom provider (#101).
- **Cancelling at home still works until execution.** Signatures alone reach no destination.

Two limits remain:

- **An attacker with a full quorum controls every chain**, home included. No destination rule
  protects against it.
- **Signers must be plain keys.** Safe contract signatures (`v=0`), pre-approved hashes
  (`v=1`) and ERC-1271 signers depend on home state and cannot be checked elsewhere.

## 2. Terms

- **Conduit**: as in the README, the `CrossProxy` at the same address on every chain. Here,
  "destination" means a conduit on any chain other than home.
- **Signer tree**: the keys allowed to sign and the thresholds that combine them.
- **Epoch**: the index of the current signer tree. Epoch 0 is the genesis tree.
- **Dispatch root**: the signed message. It commits to a Merkle root of leaves.
- **Leaf**: one chain's batch of calls under one nonce.
- **Bundle**: what a destination receives for one leaf: the dispatch root fields, the signer
  tree, the signatures, the leaf, its calls and its proof.

## 3. Data types

### 3.1 Calls

`Call` and its commitment are the ones in [`encoding.md`](encoding.md): `Call` is
`(target, value, data)`, and `callsHash = hashCalls(chainKey, calls)`, which folds the
destination chainKey in first. Calls are plain `CALL`s; there is no `DELEGATECALL`.

### 3.2 Leaf

| Field | Type | Meaning |
| --- | --- | --- |
| `tag` | `bytes32` | `keccak256("crossecute.dispatch.leaf.v1")`. Separates dispatch leaves from any other tree format, and versions the leaf. |
| `chainKey` | `bytes32` | The only chain this leaf runs on. |
| `conduit` | `address` | The conduit's address. |
| `nonce` | `uint64` | From the conduit's single running count. |
| `validAfterKind` | `uint8` | 0 none, 1 timestamp, 2 block number. |
| `validAfter` | `uint64` | Refused before this time or block. Ignored when the kind is 0. |
| `callsHash` | `bytes32` | `hashCalls(chainKey, calls)`. |

`validAfter` is per leaf because block numbers differ by chain. The custom provider adds a
per-leaf relay fee under a new tag version (#101).

Leaf hash, in the OpenZeppelin `StandardMerkleTree` format:

```
leafHash = keccak256(bytes.concat(keccak256(abi.encode(
    tag, chainKey, conduit, nonce, validAfterKind, validAfter, callsHash
))))
```

The double hash keeps a leaf from being read as a 64-byte pair of internal nodes. Builders
MUST use the leaf types `["bytes32","bytes32","address","uint64","uint8","uint64","bytes32"]`
in that order.

### 3.3 Tree

Built with `@openzeppelin/merkle-tree` `StandardMerkleTree.of(values, types)` with sorted
leaves (the default). Internal nodes hash sorted pairs, which OpenZeppelin's
`MerkleProof.verify` expects. The conduit verifies single proofs only; multiproofs are not
supported. No padding and no filler leaves. A tree with one leaf has `root == leafHash` and an
empty proof.

A root MAY hold leaves for many chains and several nonces. It MUST NOT hold two leaves with
the same `(chainKey, nonce)`. A nonce MAY appear on several chains, which is how one dispatch
reaches many chains.

### 3.4 Dispatch root (signed)

EIP-712, with this domain on every chain:

```
EIP712Domain(string name,string version,address verifyingContract)
name = "Crossecute", version = "1", verifyingContract = conduit
```

No `chainId`, since one signature must verify on every chain. Chain binding is in each leaf.

```
Dispatch(bytes32 root,uint64 epoch,uint64 validUntil)
```

`validUntil` is a Unix timestamp and covers every leaf in the root.

### 3.5 Signer tree

```solidity
enum NodeKind { EcdsaKey, P256Key, Threshold }

struct Node {
    NodeKind kind;
    bytes key;         // EcdsaKey: abi.encode(address). P256Key: abi.encode(bytes32 x, bytes32 y). Threshold: empty.
    uint16 threshold;  // Threshold only: children needed. Else 0.
    uint16[] children; // Threshold only: indexes into the node array. Else empty.
}
```

The tree is passed as `Node[]` with the root at index 0. Every non-root node MUST be the
child of exactly one node, and every child index MUST be greater than its parent's index, so
the tree has no cycles and can be checked in one pass.

Hash, computed bottom up:

```
nodeHash(EcdsaKey)  = keccak256(abi.encode(0, address))
nodeHash(P256Key)   = keccak256(abi.encode(1, x, y))
nodeHash(Threshold) = keccak256(abi.encode(2, threshold, [nodeHash(child) for child in children]))
signerTreeHash      = nodeHash(nodes[0])
```

A nested Safe is a `Threshold` node over its owners' keys.

A valid tree MUST satisfy:

- `1 <= threshold <= children.length` for every `Threshold` node;
- no key appears twice anywhere in the tree;
- depth and key count are within caps fixed at creation.

### 3.6 Signatures

`bytes[] sigs`, one entry per key node in ascending node index order. An empty entry means
that key did not sign.

- ECDSA: 65 bytes `r || s || v`, verified with OpenZeppelin `ECDSA.tryRecover`, which rejects
  high `s`. The recovered address MUST equal the key.
- P-256: 64 bytes `r || s`, verified with OpenZeppelin `P256.verify`. It calls the precompile
  at `0x100` (RIP-7212 on rollups, EIP-7951 on Ethereum), falls back to Solidity where it is
  missing, and rejects high `s` and invalid public keys.

Every key signs the same 32-byte EIP-712 digest directly. Whether Safe{Wallet}'s wrapped
`SafeMessage` form is also accepted is open (section 9).

A tree is satisfied when node 0 is: a key node is satisfied if its signature is valid, and a
threshold node is satisfied if at least `threshold` children are.

### 3.7 Rotation (signed)

Same domain as 3.4. Not a Merkle tree: one message for every chain.

```
Rotation(uint64 epoch,bytes32 prevRotationHash,bytes32 signerTreeHash)
```

`epoch` is the new epoch. `prevRotationHash` is the EIP-712 struct hash of the previous
rotation, or the genesis hash (4.1) for epoch 1. The new tree's full `Node[]` travels with
it. A rotation carries the full new set, never "remove index i": a remove-by-index replayed
on a chain with a different set order removes a different owner (Coinbase Smart Wallet,
Code4rena 2024-03 H-01). A rotation has no expiry, so a chain added later can replay every
rotation from epoch 1.

## 4. Conduit state

| Slot | Set by |
| --- | --- |
| `epoch` (`uint64`) | Genesis, then each rotation |
| `signerTreeHash` (`bytes32`) | Genesis, then each rotation |
| `rotationHash` (`bytes32`) | The genesis hash, then each rotation's struct hash |
| Nonce state | `lastNonce` (`uint64`) under the ordered policy, or a used-nonce bitmap under the unordered one |
| `verifiedDigest[digest]` (`bool`) | First successful signature check of a `Dispatch` on this chain |
| Policy (immutable) | Nonce ordering and tree caps |

The conduit stores only the tree's hash. Each bundle carries the tree.

### 4.1 Genesis

`genesisHash = keccak256(abi.encode(keccak256("crossecute.signed-dispatch.genesis.v1"), signerTreeHash0, policyHash))`.

A destination's starting tree and policy MUST follow from its address. If they came from the
bootstrap message, a provider that forged a bootstrap could choose them, which is the trust
this spec removes. How that fits the existing derivation is open (section 9). The conduit
stores `epoch = 0`, `signerTreeHash = signerTreeHash0`, `rotationHash = genesisHash`.

## 5. Building, signing and sending

1. **Draft.** For each target chain, list the calls, then assign `nonce`, `validAfterKind`
   and `validAfter`. Calls that must run in order on one chain go in one leaf, since a leaf is
   atomic.
2. **Build.** Make the leaves (3.2), build the tree (3.3), and form
   `Dispatch(root, currentEpoch, validUntil)`. Save the tree with `StandardMerkleTree.dump()`
   alongside the full `Call[]` for each leaf.
3. **Review.** Each signer's tool MUST rebuild the root from the dumped leaves and calls, and
   refuse to sign if it differs. It MUST show each leaf decoded per chain: target, value,
   decoded calldata, nonce and timing. A hardware wallet shows only `root`, `epoch` and
   `validUntil`, so this review is where signers see what they approve.
4. **Check before signing.** The tool SHOULD warn when a nonce is already used or would be
   skipped on a chain (6.3), when `validUntil` is far in the future, and when a target has no
   code on its chain.
5. **Sign.** Each key signs the EIP-712 digest of the `Dispatch`.
6. **Collect.** Order signatures by key node index (3.6).
7. **Send.** The owner executes one home transaction that hands the bundle to the home
   conduit, which sends each destination its own leaf, calls and proof, with the shared root
   fields, tree and signatures, over the providers it uses today.

Rotations follow the same steps without the tree: build the `Rotation`, review the new
`Node[]` (every key and threshold), sign, collect, and send it to every chain.

## 6. Verification on a destination

### 6.1 Dispatch

Runs when a provider delivers a dispatch bundle, after the provider's own authentication.
Checks in this order. Cheap checks come first, and every check runs before any call.

1. `epoch == this.epoch`.
2. `block.timestamp <= validUntil`.
3. `leaf.tag` is the dispatch tag, `leaf.chainKey == ChainKey.local()`,
   `leaf.conduit == address(this)`.
4. `hashCalls(calls) == leaf.callsHash` (the local-chainKey form in
   [`encoding.md`](encoding.md#commitment-preimage)).
5. `MerkleProof.verify(proof, root, leafHash(leaf))`.
6. Timing: kind 1 requires `block.timestamp >= validAfter`, kind 2 requires
   `block.number >= validAfter`, kind 0 skips, any other kind reverts.
7. Nonce (6.3).
8. Signatures: `digest = hashTypedData(Dispatch(root, epoch, validUntil))`. If
   `verifiedDigest[digest]` is set, skip. Else require `hashTree(tree) == signerTreeHash`,
   require the tree is satisfied by `sigs` over `digest`, then set `verifiedDigest[digest]`.
9. Record the nonce as used.
10. Run each call in order with its `value`. If any call reverts, revert the whole delivery,
    so the provider's retry can run it again until `validUntil`.
11. Emit `Executed(nonce, root, leafHash)`.

The path MUST be non-reentrant. Step 9 comes before step 10, so a call that re-enters cannot
replay the leaf even if the guard is wrong.

The digest cache is safe across rotations because step 1 checks the epoch on every delivery
and the epoch is part of the digest.

### 6.2 Rotation

Runs when a provider delivers a rotation bundle `(newEpoch, prevRotationHash, newTree,
currentTree, sigs)`.

1. `newEpoch == epoch + 1`.
2. `prevRotationHash == rotationHash`.
3. `hashTree(currentTree) == signerTreeHash`, and `currentTree` is satisfied by `sigs` over
   the `Rotation` digest. A policy MAY name a stricter rotation tree at creation; its hash
   then replaces `signerTreeHash` in this check.
4. `newTree` passes the validity rules in 3.5.
5. Store `epoch = newEpoch`, `signerTreeHash = hashTree(newTree)`,
   `rotationHash = structHash(Rotation)`.
6. Emit `Rotated(newEpoch, signerTreeHash, rotationHash)`.

A chain added late receives rotations from epoch 1 in order.

### 6.3 Nonces

One running count per conduit that never restarts at a new epoch. The ordering policy is
fixed at creation.

- **Unordered:** a nonce runs once per chain, in any order. Stored as a bitmap.
- **Ordered:** a leaf runs only if `nonce > lastNonce`, then `lastNonce = nonce`. Gaps are
  allowed, because most nonces target only some chains and an expired nonce must not block
  the queue. Running nonce n voids any lower nonce not yet run on that chain, which matters
  where providers deliver out of order. Dispatches that must run in order on one chain go in
  one leaf.

## 7. Errors

One custom error per check in 6.1 and 6.2: `WrongEpoch`, `Expired`, `WrongChain`,
`WrongConduit`, `BadCalls`, `BadProof`, `TooEarly`, `NonceUsed`, `BadSignatures`, `BadTree`,
`CallFailed(index, returndata)`.

`TooEarly` and `CallFailed` are worth a provider retry, until `validUntil`. `WrongEpoch` with
a higher message epoch means a rotation has not arrived yet; retry after it does. The rest
are permanent.

## 8. Keeping a Safe home in step

For a Safe owner, a guard keeps the Safe's owners equal to the signer tree:

1. Record owners and threshold in `checkTransaction` and compare them in
   `checkAfterExecution`. Any change is allowed only as a recognized rotation.
2. Accept owner changes only as a direct `Call` from the Safe to itself using
   `addOwnerWithThreshold`, `removeOwner`, `swapOwner` or `changeThreshold`, or a MultiSend
   of only those, matching a signed `Rotation`.
3. Block `setGuard`, `setModuleGuard`, and enabling any module that could change owners. A
   Safe below v1.5.0 has no module guard and must have no such modules. A Safe below v1.3.0
   has no guard and must migrate first.
4. Reject owner changes that rely on home-only approvals: `v=1` or `approveHash`.
5. Hash the owner set sorted, plus the threshold, so the order of Safe's owner list never
   makes two chains disagree.

A guard that reverts on every transaction locks the Safe, so it needs the same audit depth
as the conduit.

## 9. Open: integration with this repository

- **Address and genesis.** A conduit's address is
  `CREATE2(transceiver, keccak256(abi.encode(owner, salt, homeChainKey)), CrossProxy)`. The
  genesis hash has to follow from that address, for example by requiring
  `salt = keccak256(abi.encode(userSalt, genesisHash))` and checking it when the destination
  is armed. Not decided.
- **Where the checks run.** Whether section 6 runs in the receiver's delivery handling for
  every payload, or behind a per-conduit flag set at creation.
- **The approval map and cancellation.** How a signed bundle relates to home's approval map,
  and whether a bundle is approved at home before it is sent.
- **Safe signing format.** Signers currently sign twice: the `Dispatch` and the Safe
  transaction that sends it. Whether Safe{Wallet}'s off-chain message signing yields
  per-owner signatures over a conduit-domain `Dispatch`, or the conduit must also accept the
  wrapped `SafeMessage` form, and whether one signature can serve both.
- **Chains without standard CREATE2.** zkSync Era and Tron derive addresses differently;
  how a destination there commits to the genesis tree is open.
- **Failed calls.** Section 6.1 follows the Compound Timelock model (revert, stay retryable,
  expire). Aave's and Safe's behavior for comparison has not been verified.

## 10. Size and cost (estimates, not measured)

| Item | Bytes |
| --- | --- |
| Dispatch root fields | 96 |
| Leaf | 224 |
| Proof | 32 per level; `ceil(log2(leaves))` levels |
| ECDSA key node / signature | about 160 / 65 |
| P-256 key node / signature | about 192 / 64 |

The bundle adds to every message. LayerZero, CCIP and Hyperlane price a payload per byte, so
on those three it is a direct cost; Wormhole's Executor and the OP Stack providers do not
price per byte. A 3-of-5 ECDSA tree adds roughly 1.1 KB per message before the proof.

Signature checks dominate the destination's gas: about 3,000 per ECDSA recover; 3,450 per
P-256 check under RIP-7212 or 6,900 under EIP-7951 where the precompile exists, and hundreds
of thousands where OpenZeppelin falls back to Solidity. The check counts against the gas
limit the provider delivers with. The digest cache means a root with several leaves for one
chain pays for signatures once on that chain. A nested signer tree such as Optimism's 2-of-2
upgrade Safe, whose owners are themselves Safes, needs measuring before caps are set.

## 11. Required tests

Shared test vectors (leaf hash, root, digest, tree hash, signatures) generated with
`@openzeppelin/merkle-tree` and checked in Solidity, so the off-chain builder and the conduit
cannot drift. They belong in the `test/vectors/` corpus described in
[`encoding.md`](encoding.md#the-vector-corpus).

Negative cases, each MUST revert with the listed error:

- a correctly authenticated provider delivery with missing or insufficient signatures;
- a leaf for another chainKey, another conduit, or with a different tag;
- calls that do not hash to `callsHash`;
- empty, truncated, reordered and extended proofs; an internal node submitted as a leaf;
- signatures under the previous epoch's tree; a `Dispatch` digest replayed as a `Rotation`
  and the reverse;
- high-`s` ECDSA and P-256 signatures; a signature in the wrong key slot; duplicate keys in a
  new tree; a threshold of 0 or above the child count; a child index not greater than its
  parent;
- an expired `validUntil`, an early `validAfter`, an unknown `validAfterKind`;
- a reused nonce under both policies, and a lower nonce under the ordered one;
- a call that re-enters the delivery path;
- a rotation that skips an epoch or links to the wrong previous hash.

Property tests: a satisfied tree stays satisfied when extra valid signatures are added; an
unsatisfied tree stays unsatisfied when any signature is removed; the same signed bytes give
the same result on every chain except through `leaf.chainKey`.

## 12. Decisions

Decided 2026-10-28.

1. **The epoch is in the signed root, not in each leaf.** One field binds every leaf and
   saves 32 bytes per leaf.
2. **The target chain is per leaf**, so one root reaches many chains and each leaf is bound
   to one.
3. **No `DELEGATECALL`.** A delegatecall could rewrite the epoch, tree hash or nonce state.
4. **Rotations do not expire.** A chain added later must replay every rotation from epoch 1,
   which an expiry would block.
5. **Ordered nonces allow gaps.** Ordered means increasing, not consecutive. An expired nonce
   cannot block the queue, but a delivery of a higher nonce voids a lower pending one.
   Dispatches that must run in order on one chain go in one leaf.
6. **Conduits store the tree hash, not the tree.** Each bundle carries the tree. Rotations
   usually respond to a compromised key, so they should be cheap to land on every chain; the
   extra bytes per dispatch are the smaller cost.
7. **The current tree approves a rotation** unless the policy names a stricter rotation tree.
8. **OpenZeppelin `StandardMerkleTree` format**, because OpenZeppelin's code is more widely
   trusted than a custom builder, on the condition that it adds no complexity: single proofs
   through `MerkleProof.verify` only, and the `tag` field is the only addition. Boring-vault's
   format (one hash over packed fields, padded with filler leaves) was the alternative; it
   needs filler-leaf handling and relies on leaf length to tell leaves from internal nodes.
9. **Reuse this repository's `Call` and `hashCalls`.** The leaf binds the chainKey and the
   commitment from [`encoding.md`](encoding.md).
10. **Two iterations.** This one checks signatures on provider deliveries. Freeze, relayer
    fees, discovery and permissionless relay belong to the custom provider (#101), because
    the existing providers send only what the owner executes at home, so every message
    already needs the full quorum.
