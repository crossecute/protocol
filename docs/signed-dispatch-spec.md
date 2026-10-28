# Signed dispatch: owner signatures any relayer can deliver

Status: design, not built. Dated 2026-10-28. This is a proposal for verification that does not rest on a provider's
signers (the gap recorded in
[crossecute/protocol#99](https://github.com/crossecute/protocol/pull/99)): a path on which a destination conduit accepts a payload
because the owner's own signers signed it, so no provider's signers are in the trust path. It covers how signers build and sign a Merkle root of
per-chain dispatches, how a conduit verifies and executes one leaf, how signer sets rotate,
and what home publishes for relayers. How it attaches to the existing contracts is open
(section 10).

Keywords MUST, MUST NOT, SHOULD and MAY are used in the RFC 2119 sense.

## Contents

| | |
| --- | --- |
| [1. Constraint](#1-constraint-relay-only) | what a destination may and may not rely on |
| [2. Terms](#2-terms) | |
| [3. Data types](#3-data-types) | calls, leaves, the tree, the signed messages, the signer tree |
| [4. Conduit state](#4-conduit-state) | what each destination stores |
| [5. Building and signing](#5-building-and-signing-off-chain) | off-chain steps |
| [6. Verification](#6-verification-on-a-destination) | `execute`, `rotate`, nonces, equivocation |
| [7. Errors](#7-errors) | which failures a relayer can retry |
| [8. Home publishing and relayers](#8-home-publishing-and-relayers) | |
| [9. Size and cost](#9-size-and-cost-estimates-not-measured) | |
| [10. Open: integration with this repository](#10-open-integration-with-this-repository) | |
| [11. Required tests](#11-required-tests) | |
| [12. Decisions](#12-decisions) | what was chosen and why |

## 1. Constraint: relay only

A destination uses no provider, light client, ZK client, canonical rollup read or other read
of home state. It learns only what signed bytes carry. Anyone can relay those bytes, and
nobody who relays them can forge or alter them.

Consequences that follow from this and are not fixable inside it:

- **A destination runs what a quorum signed, whether or not home executed it.** It cannot
  tell the difference. Signing is the action; home execution only publishes. A complete
  signature set is final: cancelling at home does not reach destinations. The only stops are
  a rotation to a new epoch (the same owners are fine) and a freeze.
- **A destination knows only the rotations it has received.** A removed key stays valid on a
  chain nobody has relayed the rotation to. It matters only if the attacker also holds enough
  current keys to reach the threshold.
- **An attacker with a full quorum controls every chain**, home included. No destination rule
  protects against it.
- **Home never learns destination outcomes.** There are no acknowledgements.
- **Signers must be plain keys.** Safe contract signatures (`v=0`), pre-approved hashes
  (`v=1`) and ERC-1271 signers depend on home state and cannot be checked elsewhere.

## 2. Terms

- **Conduit**: as in the README, the `CrossProxy` at the same address on every chain. Here,
  "destination" means a conduit on any chain other than home that runs this path.
- **Signer tree**: the keys allowed to sign and the thresholds that combine them.
- **Epoch**: the index of the current signer tree. Epoch 0 is the genesis tree.
- **Dispatch root**: the signed message. It commits to a Merkle root of leaves.
- **Leaf**: one chain's batch of calls under one nonce.
- **Relayer**: anyone who submits signed bytes to a destination.

## 3. Data types

### 3.1 Calls

`Call` and its commitment are the ones in [`encoding.md`](encoding.md): `Call` is
`(target, value, data)`, and `callsHash = hashCalls(chainKey, calls)`, which folds the
destination chainKey in first. Calls are plain `CALL`s; there is no `DELEGATECALL`.

### 3.2 Leaf

| Field | Type | Meaning |
| --- | --- | --- |
| `tag` | `bytes32` | `keccak256("crossecute.dispatch.leaf.v1")`. Separates dispatch leaves from any other tree format. |
| `chainKey` | `bytes32` | The only chain this leaf runs on. |
| `conduit` | `address` | The conduit's address. |
| `nonce` | `uint64` | From the conduit's single running count. |
| `validAfterKind` | `uint8` | 0 none, 1 timestamp, 2 block number. |
| `validAfter` | `uint64` | Refused before this time or block. Ignored when the kind is 0. |
| `maxRelayFee` | `uint256` | Cap on the relayer refund in the destination's native token, in wei. 0 means no refund. |
| `callsHash` | `bytes32` | `hashCalls(chainKey, calls)`. |

`maxRelayFee` and `validAfter` are per leaf because native token prices and block numbers
differ by chain.

Leaf hash, in the OpenZeppelin `StandardMerkleTree` format:

```
leafHash = keccak256(bytes.concat(keccak256(abi.encode(
    tag, chainKey, conduit, nonce, validAfterKind, validAfter, maxRelayFee, callsHash
))))
```

The double hash keeps a leaf from being read as a 64-byte pair of internal nodes. Builders
MUST use the leaf types
`["bytes32","bytes32","address","uint64","uint8","uint64","uint256","bytes32"]` in that
order.

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
`SafeMessage` form is also accepted is open (section 10).

A tree is satisfied when node 0 is: a key node is satisfied if its signature is valid, and a
threshold node is satisfied if at least `threshold` children are.

### 3.7 Rotation (signed)

Same domain as 3.4. Not a Merkle tree: one message for every chain.

```
Rotation(uint64 epoch,bytes32 prevRotationHash,bytes32 signerTreeHash)
```

`epoch` is the new epoch. `prevRotationHash` is the EIP-712 struct hash of the previous
rotation, or the genesis hash (4.1) for epoch 1. The new tree's full `Node[]` travels in
calldata. A rotation carries the full new set, never "remove index i": a remove-by-index
replayed on a chain with a different set order removes a different owner (Coinbase Smart
Wallet, Code4rena 2024-03 H-01). A rotation has no expiry (section 12).

## 4. Conduit state

| Slot | Set by |
| --- | --- |
| `epoch` (`uint64`) | Genesis, then each rotation |
| `signerTreeHash` (`bytes32`) | Genesis, then each rotation |
| `rotationHash` (`bytes32`) | The genesis hash, then each rotation's struct hash |
| `frozen` (`bool`) | Freeze rules fixed at creation |
| Nonce state | `lastNonce` (`uint64`) under the ordered policy, or a used-nonce bitmap under the unordered one |
| `verifiedDigest[digest]` (`bool`) | First successful signature check of a `Dispatch` on this chain |
| Policy (immutable) | Nonce ordering, caps, freeze rules, relay fee premium |

The conduit stores only the tree's hash. Relayers supply the tree with each call.

### 4.1 Genesis

`genesisHash = keccak256(abi.encode(keccak256("crossecute.signed-dispatch.genesis.v1"), signerTreeHash0, policyHash))`.

A destination's starting tree and policy MUST follow from its address, so nobody who deploys
the conduit on a new chain can choose them. How that fits the existing derivation is open
(section 10). The conduit stores `epoch = 0`, `signerTreeHash = signerTreeHash0`,
`rotationHash = genesisHash`.

## 5. Building and signing (off chain)

1. **Draft.** For each target chain, list the calls, then assign `nonce`, `validAfterKind`,
   `validAfter` and `maxRelayFee`. Calls that must run in order on one chain go in one leaf,
   since a leaf is atomic.
2. **Build.** Make the leaves (3.2), build the tree (3.3), and form
   `Dispatch(root, currentEpoch, validUntil)`. Save the tree with `StandardMerkleTree.dump()`
   alongside the full `Call[]` for each leaf.
3. **Review.** Each signer's tool MUST rebuild the root from the dumped leaves and calls, and
   refuse to sign if it differs. It MUST show each leaf decoded per chain: target, value,
   decoded calldata, nonce, timing and relay fee. A hardware wallet shows only `root`,
   `epoch` and `validUntil`, so this review is where signers see what they approve.
4. **Check before signing.** The tool SHOULD warn when a nonce is already used or would be
   skipped on a chain (6.3), when `validUntil` is far in the future, and when a target has no
   code on its chain.
5. **Sign.** Each key signs the EIP-712 digest of the `Dispatch`.
6. **Collect.** Order signatures by key node index (3.6). Once the tree is satisfied the set
   is final: anyone holding it can relay it to every listed chain.
7. **Publish.** Home emits `Published` (section 8) so relayers can find it.

Rotations follow the same steps without the tree: build the `Rotation`, review the new
`Node[]` (every key and threshold), sign, collect, publish.

## 6. Verification on a destination

### 6.1 `execute`

```solidity
function execute(
    bytes32 root, uint64 epoch, uint64 validUntil,
    Node[] calldata tree, bytes[] calldata sigs,
    Leaf calldata leaf, Call[] calldata calls, bytes32[] calldata proof
) external;
```

Checks in this order. Cheap checks come first, and every check runs before any call.

1. `!frozen`.
2. `epoch == this.epoch`.
3. `block.timestamp <= validUntil`.
4. `leaf.tag` is the dispatch tag, `leaf.chainKey == ChainKey.local()`,
   `leaf.conduit == address(this)`.
5. `hashCalls(calls) == leaf.callsHash` (the local-chainKey form in
   [`encoding.md`](encoding.md#commitment-preimage)).
6. `MerkleProof.verify(proof, root, leafHash(leaf))`.
7. Timing: kind 1 requires `block.timestamp >= validAfter`, kind 2 requires
   `block.number >= validAfter`, kind 0 skips, any other kind reverts.
8. Nonce (6.3).
9. Signatures: `digest = hashTypedData(Dispatch(root, epoch, validUntil))`. If
   `verifiedDigest[digest]` is set, skip. Else require `hashTree(tree) == signerTreeHash`,
   require the tree is satisfied by `sigs` over `digest`, then set `verifiedDigest[digest]`.
10. Record the nonce as used.
11. Run each call in order with its `value`. If any call reverts, revert the whole
    transaction, so the leaf stays retryable until `validUntil` and then expires.
12. If `leaf.maxRelayFee > 0`, pay `msg.sender`
    `min(gasUsed * block.basefee * premium, leaf.maxRelayFee)` from the conduit's balance. A
    failed payment reverts the whole transaction.
13. Emit `Executed(nonce, root, leafHash)`.

`execute` MUST be non-reentrant. Step 10 comes before step 11, so a call that re-enters
cannot replay the leaf even if the guard is wrong.

The digest cache is safe across rotations because step 2 checks the epoch on every call and
the epoch is part of the digest.

### 6.2 `rotate`

```solidity
function rotate(
    uint64 newEpoch, bytes32 prevRotationHash, Node[] calldata newTree,
    Node[] calldata currentTree, bytes[] calldata sigs
) external;
```

1. `!frozen`.
2. `newEpoch == epoch + 1`.
3. `prevRotationHash == rotationHash`.
4. `hashTree(currentTree) == signerTreeHash`, and `currentTree` is satisfied by `sigs` over
   the `Rotation` digest. A policy MAY name a stricter rotation tree at creation; its hash
   then replaces `signerTreeHash` in this check.
5. `newTree` passes the validity rules in 3.5.
6. Store `epoch = newEpoch`, `signerTreeHash = hashTree(newTree)`,
   `rotationHash = structHash(Rotation)`.
7. Emit `Rotated(newEpoch, signerTreeHash, rotationHash)`.

A chain added late replays rotations from epoch 1 in order.

### 6.3 Nonces

One running count per conduit that never restarts at a new epoch. The ordering policy is
fixed at creation.

- **Unordered:** a nonce runs once per chain, in any order. Stored as a bitmap.
- **Ordered:** a leaf runs only if `nonce > lastNonce`, then `lastNonce = nonce`. Gaps are
  allowed, because most nonces target only some chains and an expired nonce must not block
  the queue. Running nonce n voids any lower nonce not yet run on that chain.

### 6.4 Equivocation

`proveEquivocation` takes two `Rotation` messages with the same `epoch` and different
struct hashes, each satisfying the tree for `epoch - 1`. What it triggers is the freeze
policy fixed at creation. There is no trusting period: a conduit does not freeze on its own
when signers are quiet.

## 7. Errors

One custom error per check in 6.1 and 6.2, so relayers can tell a retryable failure from a
permanent one:

| Error | Retryable |
| --- | --- |
| `Frozen`, `WrongEpoch`, `Expired`, `WrongChain`, `WrongConduit`, `BadCalls`, `BadProof`, `BadSignatures`, `BadTree`, `NonceUsed` | No |
| `TooEarly` | Yes, after `validAfter` |
| `CallFailed(index, returndata)` | Yes, until `validUntil` |
| `RelayFeeUnpaid` | Yes, once the conduit is funded |

`WrongEpoch` with a lower message epoch is permanent. With a higher one, the relayer should
submit the missing rotations first.

## 8. Home publishing and relayers

Home emits after the owner executes:

```solidity
event Published(address indexed conduit, uint64 indexed epoch, uint8 indexed kind, bytes payload);
```

`kind` 0 is a dispatch:
`payload = abi.encode(root, epoch, validUntil, tree, sigs, Leaf[] leaves, Call[][] calls)`.
`kind` 1 is a rotation:
`payload = abi.encode(newEpoch, prevRotationHash, newTree, currentTree, sigs)`.

Publishing is for discovery only. Destinations never check that something was published.

**Keeping home in step.** For a Safe owner, a guard keeps the Safe's owners equal to the
signer tree: it records owners and threshold in `checkTransaction`, compares them in
`checkAfterExecution`, allows owner changes only as direct self-calls (or a MultiSend of
them) matching a signed `Rotation`, rejects `v=1` and `approveHash` approvals, blocks
`setGuard`, `setModuleGuard` and owner-changing modules, and hashes owners sorted so Safe's
linked-list order never makes two chains disagree. A Safe below v1.5.0 has no module guard
and must have no such modules; below v1.3.0 it has no guard and must migrate first. A guard
that reverts on every transaction locks the Safe, so it needs the same audit depth as the
conduit.

**Relayers** read `Published`, rebuild each leaf's proof from `leaves`, and submit to every
chain where `leaf.chainKey` has code at the conduit address. They submit pending rotations
before later-epoch dispatches. A bad RPC can withhold or delay a message, never forge one.
Relayer software SHOULD archive payloads, since log availability under future history expiry
is not guaranteed.

## 9. Size and cost (estimates, not measured)

| Item | Calldata |
| --- | --- |
| Dispatch root fields | 96 bytes |
| Leaf | 256 bytes |
| Proof | 32 bytes per level; `ceil(log2(leaves))` levels |
| ECDSA key node / signature | about 160 bytes / 65 bytes |
| P-256 key node / signature | about 192 bytes / 64 bytes |

Signature checks dominate: about 3,000 gas per ECDSA recover; 3,450 per P-256 check under
RIP-7212 or 6,900 under EIP-7951 where the precompile exists, and hundreds of thousands where
OpenZeppelin falls back to Solidity. The digest cache means a root with several leaves for one
chain pays for signatures once on that chain. A nested signer tree such as Optimism's 2-of-2
upgrade Safe, whose owners are themselves Safes, needs measuring before caps are set.

## 10. Open: integration with this repository

- **Address and genesis.** A conduit's address is
  `CREATE2(transceiver, keccak256(abi.encode(owner, salt, homeChainKey)), CrossProxy)`. The
  genesis hash has to follow from that address, for example by requiring
  `salt = keccak256(abi.encode(userSalt, genesisHash))` and checking it when the destination
  is armed. Not decided.
- **Who deploys a destination.** Today a bootstrap message through a provider creates it. A
  path with no provider needs a permissionless creation that takes the genesis tree and
  policy and checks them against the address.
- **Alongside providers or instead of them.** This path can be a second check on provider
  messages (a provider alone cannot deliver) or a separate entry point that needs no
  provider. The two give different liveness.
- **The approval map and cancellation.** Signed dispatches do not pass through home's
  approval map, and cancelling at home does not reach them (section 1).
- **Safe signing format.** Whether Safe{Wallet}'s off-chain message signing yields per-owner
  signatures over a conduit-domain `Dispatch`, or the conduit must also accept the wrapped
  `SafeMessage` form.
- **Chains without standard CREATE2.** zkSync Era and Tron derive addresses differently;
  how a destination there commits to the genesis tree is open.
- **Failed calls.** Section 6.1 follows the Compound Timelock model (revert, stay retryable,
  expire). Aave's and Safe's behavior for comparison has not been verified.

## 11. Required tests

Shared test vectors (leaf hash, root, digest, tree hash, signatures) generated with
`@openzeppelin/merkle-tree` and checked in Solidity, so the off-chain builder and the conduit
cannot drift. They belong in the `test/vectors/` corpus described in
[`encoding.md`](encoding.md#the-vector-corpus).

Negative cases, each MUST revert with the listed error:

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
- a call that re-enters `execute` or `rotate`;
- a rotation that skips an epoch or links to the wrong previous hash.

Property tests: a satisfied tree stays satisfied when extra valid signatures are added; an
unsatisfied tree stays unsatisfied when any signature is removed; the same signed bytes give
the same result on every chain except through `leaf.chainKey`.

## 12. Decisions

Decided 2026-10-28.

1. **The epoch is in the signed root, not in each leaf.** One field binds every leaf and
   saves 32 bytes per leaf.
2. **`maxRelayFee` and the target chain are per leaf**, so each chain has its own cap in its
   own native token.
3. **No `DELEGATECALL`.** A delegatecall could rewrite the epoch, tree hash or nonce state.
4. **Rotations do not expire.** A chain added later must replay every rotation from epoch 1,
   which an expiry would block. Rotations are stopped only by a freeze.
5. **Ordered nonces allow gaps.** Ordered means increasing, not consecutive. An expired nonce
   cannot block the queue, but a relayer can void a lower pending nonce by relaying a higher
   one first. Dispatches that must run in order on one chain go in one leaf.
6. **Conduits store the tree hash, not the tree.** Relayers resend the tree with each call.
   Rotations usually respond to a compromised key, so they should be cheap to land on every
   chain; the extra calldata per dispatch is the smaller cost.
7. **The current tree approves a rotation** unless the policy names a stricter rotation tree.
8. **OpenZeppelin `StandardMerkleTree` format**, because OpenZeppelin's code is more widely
   trusted than a custom builder, on the condition that it adds no complexity: single proofs
   through `MerkleProof.verify` only, and the `tag` field is the only addition. Boring-vault's
   format (one hash over packed fields, padded with filler leaves) was the alternative; it
   needs filler-leaf handling and relies on leaf length to tell leaves from internal nodes.
9. **Reuse this repository's `Call` and `hashCalls`.** The leaf binds the chainKey and the
   commitment from [`encoding.md`](encoding.md), so a signed leaf and a provider payload for
   the same calls commit to the same `callsHash`.
