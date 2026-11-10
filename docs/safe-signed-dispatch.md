# Safe-signed dispatch

How a signature-enabled transmitter sends a standalone Safe-signed dispatch or relays a leaf
from a registered Merkle root, and how a receiver verifies and executes it. Tracked in
[issue #108](https://github.com/crossecute/protocol/issues/108). The source guard is
[#107](https://github.com/crossecute/protocol/issues/107) (implemented in
[PR #117](https://github.com/crossecute/protocol/pull/117)); authority changes are
[#109](https://github.com/crossecute/protocol/issues/109).

**Status.** Working design with proposed Solidity interfaces. It records what is decided,
the conflicts that block a decision, and the open questions with proposed answers and the cases
each answer must handle. The design part of #108 is resolved when every item under
[Conflicts](#conflicts-to-resolve-first) and [Open questions](#open-questions) is either
decided (moved to [Decisions](#decisions)) or explicitly deferred with a reason.

**Labels.** *Decided* items come from #108 or were agreed while refining it. *Proposed*
answers are recommendations awaiting agreement. *Open* items have no recommendation yet. IDs
(D3, C2, Q4.6, R10) are stable so discussion can refer to them; a resolved item keeps its ID.

## Decisions

Envelope and routing:

- **D1.** A standalone Safe transaction signs the normal `sendMessage(bytes,bytes,bytes[])`
  calldata for one destination. The recipient, payload and attributes use the plain variant's
  encoding. The transmitter consumes the guard-staged authorization and sends in the same
  source transaction, wrapping the exact calldata with Safe context, signatures and any
  nested approval evidence. The standalone message has no Merkle root, leaf or proof.
- **D2.** The owner Safe can register any `bytes32` root. The transmitter caches its signed
  registration and nested approval evidence for later relays. Registration needs no leaf data.
  Track cache presence independently of the root value so a zero root can also be registered.
- **D3.** The signed Safe `to` must equal the receiver's configured source transmitter.
- **D4.** A locked receiver deployment uses fixed, distinct standalone and Merkle envelope
  formats. The receiver checks the signed selector for the path being executed.
- **D5.** Anyone can call `relayLeaf` with a registered root, one execution leaf and its
  proof. The transmitter checks membership and the configured route, then sends one
  message to the leaf's destination with the cached Safe authorization, root, leaf and proof.
  The receiver reconstructs the signed root registration, verifies the Safe quorum and
  proof, and checks that the decoded leaf names this chain and receiver before executing it.

Only the signed target can consume the guard's staged record, once. The guard clears it in
the Safe post-hook. A batch of standalone sends uses separately signed, top-level Safe
executions. A signed MultiSend or module call does not stage its inner calls.

Trees and leaves:

- **D6.** One registered root can cover multiple destinations and multiple local nonces on
  the same receiver. Each `relayLeaf` call sends one leaf to one destination. A leaf can
  contain an ordered batch of calls that executes atomically on that destination.
- **D7.** The transmitter marks the leaf hash used when its provider send succeeds. Mark
  before calling the provider and let a revert roll back the mark. The receiver marks the
  same leaf hash used when execution succeeds. The source mark is keyed by leaf hash across all registered roots on that transmitter.
  Destination failure rolls back only the receiver mark, and the original delivery can be
  retried through the provider. Direct execution writes only receiver state. A later
  `relayLeaf` may still send and mark that leaf used on the transmitter.
- **D8.** Each Merkle leaf commits to its receiver's local nonce. The Safe nonce stays in the
  signed transaction context. A standalone send has the same application payload as the
  plain path and uses the Safe digest as its replay identity.

Verification and replay:

- **D9.** Every dispatch verifies before changing state, including a commit-only message.
  For each format, provider delivery and direct submission share the verifier and replay
  state. Provider
  sender metadata and local self-calls never substitute for it, including where the
  transmitter and receiver share an address on different chains.
- **D10.** Each receiver starts Merkle execution at `nextNonce = 0` and requires `leaf.localNonce == nextNonce` for a
  new execution. It records the leaf hash and advances before external calls, rejects
  overflow, and rolls both back if execution reverts.
- **D11.** After authenticating a Merkle delivery, a receiver that already executed the
  same leaf returns success silently, without an event, calls or nonce advance. This
  includes a provider delivery after direct execution, and the same leaf under a different
  valid root. A different leaf at a consumed nonce reverts. Standalone duplicates retain
  `DuplicateMessage()`.
- **D12.** A replacement leaf at the current nonce may carry revised calls or an empty batch.
  If the original leaf is still valid, either may consume the nonce first.
- **D13.** A commit-only leaf consumes its nonce when the commitment is recorded. `finalize`
  consumes the commitment later without touching the nonce.
- **D14.** A new Merkle execution requires `validAfter <= deadline` and
  `validAfter <= block.timestamp <= deadline` on destination time, inclusive. An invalid
  window consumes nothing. An authenticated repeat of an executed leaf succeeds silently
  even after the deadline.

Authority:

- **D15.** One receiver is bound to one parent Safe and source chain. The receiver stores the
  owner and Safe composition, including nested Safes with thresholds preserved; nested Safes
  are required in the first release and must be Safe 1.5.0.
- **D16.** Nested signatures, including cached direct-approval evidence, verify against the
  child's current receiver-stored composition. Only children used to reach the parent's quorum
  are traversed.
- **D17.** Empty nested payloads count only with independently verified signed direct-approval
  evidence. The receiver does not check the signing library's address or code hash. `v = 1`
  is rejected at every level. `v = 27/28` and `v = 31/32` are supported, including mixed sets.
- **D18.** #108 uses fixed authority. #109 specifies how standalone sends and cached
  root approvals are invalidated when authority changes. Authority updates and dispatch
  execution have separate entry points.
- **D19.** Standalone sends and Merkle leaves can execute directly at the destination.
  A direct Merkle submission supplies the signed root registration, leaf and proof. The
  receiver authenticates it locally using the same rules as a provider delivery. Direct
  execution requires neither a source registration receipt nor a source used record.

## Conflicts to resolve first

- **C1. Duplicate acknowledgment after an authority change.** A duplicate still requires
  current authority. A provider retry can fail after rotation even if direct submission
  already executed the leaf.
- **C2. #109 fields in the bootstrap snapshot.** The snapshot carries one applied
  authority counter per Safe. #109 owns the fields and rules for later authority changes.
- **C3.** Deferred to #109. Specify how standalone sends and cached approvals bind the
  source authority counter once rotations are supported.
- **C4. One tree cannot span providers.** D3 binds the signed `to` to one transmitter. Each
  provider has its own transceiver and so its own transmitter and conduit address. Receivers of
  a LayerZero conduit and a CCIP conduit cannot share a signed Safe transaction. *Proposed:*
  state the limit; accepting a set of transmitters is a larger change.
- **C5. Source-side policy does not gate destination effects.** Under D19 a signed but
  unexecuted standalone Safe transaction can execute at the destination, so checks the home
  Safe applies at execution time (the guard's PolicyEngine, SafenetPolicy, delay modules) never see it.
  *Open:* document as accepted, or not.
- **C6. Safe cancellation does not cancel.** Signing a rejection at the same Safe nonce
  replaces the source transaction but leaves the original signatures valid at the destination
  under the standalone replay rules. For registered roots, replacing a source Safe transaction
  at the same nonce cannot undo a registration that already executed.
  Signatures in the Safe Transaction Service are public once threshold is reached. *Open:*
  document as accepted, and say what tooling shows signers.
- **C7. PR #115's draft of this file.** It describes a superseded design: `minimumNonce` with
  gaps, no stored execution hash, leaves committing to the parent nonce, and evidence that must
  delegatecall a supported signing library. This file replaces it.

## Open questions

### Q1. Signed calldata and delivery envelope

[`ISignedDispatch.sol`](../contracts/evm/src/messaging/ISignedDispatch.sol) proposes a
shared `SignedDelivery` containing the exact
[`ICrossecuteGuard.SafeTx`](../contracts/safe-guard/src/ICrossecuteGuard.sol), signatures
and nested approval evidence. For a standalone delivery, decode recipient and plain payload
from the signed `sendMessage` calldata. For a Merkle delivery, decode the root from the
signed `registerRoot` calldata and use the separately supplied leaf and proof.

- **Q1.1** Use the configured source Safe and chain ID for the EIP-712 domain. Check the
  signed target and require `operation == CALL` and zero `safeTxGas` and `gasPrice`.
- **Q1.2** Carry all SafeTx fields in Safe 1.5.0 EIP-712 order. Restore `safeTx.data` from
  `msg.data` after consuming the staged record.
- **Q1.3** Check the signed selector before decoding. Hash exact calldata and test parity
  with Safe 1.5.0 `getTransactionHash`.
- **Q1.4** *Open:* whether to require canonical ABI encoding for signed calldata. Hash and
  execute the same call bytes.
- **Q1.5** The standalone quote and send use the signed `recipient`. The Merkle quote and
  relay use the leaf destination. Each pair prices the same final wire bytes.
- **Q1.6** Teach the guard to stage `registerRoot(bytes32)` for owner transactions and
  reject that selector on the module path. Cache the resulting `SignedDelivery` on the
  transmitter, so relayers only supply the root and witness.
- **Q1.7** Direct Merkle submission can execute a leaf when the provider is unavailable.
  It leaves the transmitter's used state unchanged. A later provider delivery of that
  leaf follows D11.
- **Q1.8** *Open:* relay fee funding and how permissionless relays apply provider attributes
  and gas limits.
- **Q1.9** *Open:* measure cache writes and provider envelope costs, including nested evidence,
  and define bounds. Leaf data and proofs are variable length because the number of calls and
  tree depth vary.
- **Q1.10** A new registration of the same root cannot make an already-used leaf relayable.
  *Open:* whether a repeated registration can replace the cached authorization.

### Q2. Leaf and tree encoding

What fields and byte encoding define an execution leaf? How does it commit to the ordered
calls with the existing EVM `Call[]` codec, and how are leaves and internal nodes hashed? Specify proof ordering and the single-leaf tree.

*Proposed.* Frame the leaf fields with `abi.encode` and double-hash the result. Include the
full destination and `callPayload` bytes in the inner hash. EVM call payloads use the existing
`abi.encode(Call[])` format. Internal nodes hash sorted pairs, as in OpenZeppelin's
`MerkleProof`. Carry an unpaired hash to the next level unchanged. The execution tag, field
order and integer widths remain open.

Cases:

- **Q2.1** #109 owns authority counter binding for root registration. Keep the leaf hash
  stable when the same leaf is approved again.
- **Q2.2** An empty replacement leaf carries the normal encoding of an empty `Call[]`.
- **Q2.3** The leaf hash includes the exact encoded call payload bytes. A call to `commit`
  still takes the existing commitment hash for the batch to be finalized later.
- **Q2.4** The destination is ERC-7930 bytes: `Erc7930.parseStrict`, eip155 only, a 20-byte
  address. The full destination bytes are included in the leaf encoding.
- **Q2.5** The tag is the first field, so #109's management tag cannot collide with it. With no
  version field, a new format needs a new receiver implementation, and tooling identifies a
  receiver's format from its implementation or transceiver.
- **Q2.6** Double hashing keeps a 64-byte internal node from decoding as a leaf.
- **Q2.7** Sorted pairs carry no index; duplicate leaves are harmless.
- **Q2.8** A single-leaf tree has the leaf node as its root and an empty proof.
- **Q2.9** Proof length is capped (Q7).
- **Q2.10** *Open:* whether a leaf may call any function on its own receiver, or only
  `commit`, `cancel` and `revokeGateway`. A self-call to #109's update entry point would be a
  combined update-and-execute and must be blocked; the dispatch entry points already hit the
  reentrancy lock.
- **Q2.11** Two leaves for the same receiver and nonce in one tree are both signed; the first
  delivered wins. Builders refuse to produce them.
- **Q2.12** A nonce gap inside one tree is allowed; another tree fills it.

### Q3. Owner graph

How are EOA owners, nested Safes, thresholds and shared child references canonically encoded?
Are owner kinds explicit, how are owners and nodes ordered, and what does the receiver store?

Each Safe address has one record. Nested owner entries reference that record by source
Safe address.

Cases:

- **Q3.1** Owner kind is a `uint8`: `0` for EOA and `1` for nested Safe. Reject a
  nested owner if its record is missing.
- **Q3.2** Preserve each Safe's `getOwners()` order. Signature verification separately
  requires ascending signer addresses.
- **Q3.3** Traverse depth first from the root, in owner order. Emit each Safe record on
  first visit and reject cycles.
- **Q3.4** Bootstrap snapshot records append each Safe's `uint256 authorityCounter`.
- **Q3.5** Reject invalid thresholds, zero and sentinel owners, duplicate owners, duplicate
  or unreachable records, and inconsistent owner kinds.
- **Q3.6** Classify empty code and the EIP-7702 delegation indicator as EOA. For other
  owner addresses, require valid Safe owner and threshold data.
- **Q3.7** Hash the canonical record array as `keccak256(abi.encode(records))`. At
  transmitter creation derive the salt as `keccak256(abi.encode(userSalt, graphHash))`.
- **Q3.8** The root node is the transmitter's owner Safe.
- **Q3.9** [`NestedOwnerManager.sol`](../contracts/evm/src/messaging/NestedOwnerManager.sol)
  proposes one `SafeState` per Safe, with a linked owner list and threshold. Keep the
  authority counter and owner kind metadata in the surrounding record. The signed update
  carries Safe's mutation selector and arguments. After verifying the update, the receiver
  can use `using NestedOwnerManager for SafeState` and call
  `safeStates[childSafe].swapOwner(prevOwner, oldOwner, newOwner)` on the selected record.
  The signed state is ERC-7201 namespaced so it does not freeze the base's sequential
  layout ([R8.2](provider-spec.md#r8-storage-and-address-parity)).
- **Q3.10** Derive the graph onchain from live `getOwners()` and `getThreshold()` at
  transmitter creation. Creation does not enforce nested Safe implementation identity.

### Q4. Authenticated receiver bootstrap

First bootstrap requires the configured authenticated provider and a Safe-signed
`bootstrap(bytes,bytes[])` transaction. The bootstrap leaf commits to the destination,
execution window and exact setup calls. It omits the execution nonce.

- **Q4.1** The receiver salt is
  `keccak256(abi.encode(sourceTransmitter, parentAuthorityCounter, snapshotHash))`,
  where `snapshotHash = keccak256(abi.encode(snapshotRecords))`. Use the existing
  conduit derivation with this salt.
- **Q4.2** The EIP-155 source chain ID in the Safe domain must match the authenticated
  origin and source chain key.
- **Q4.3** The source checks the live parent counter and sends the current canonical
  snapshot with `SignedDelivery`. The receiver checks the salt and destination, verifies
  authorization, and initializes the per-Safe counters from the snapshot and `nextNonce`
  to zero.
- **Q4.4** PR #117 stages only the top-level `sendMessage` selector today. Before signed
  bootstrap can use `consume`, the guard must also stage the bootstrap selector for
  owner transactions and reject it in the installed module guard.
- **Q4.5** An initialized receiver can accept direct ordinary dispatch before the source
  receives a readiness report. An authenticated repeat of the same bootstrap leaf within
  its window succeeds silently.
- **Q4.6** Bootstrap carries no historical authority updates. Initialized receivers apply
  later updates in sequence under #109.
- **Q4.7** A plain transceiver deploys at a different address from a signed transceiver
  with the same owner and salt. Test both derivations.
- **Q4.8** Measure the encoded bootstrap envelope and initialization gas against graph size.

### Q5. Recursive signature verification

Which Safe 1.5.0 fallback handler behavior is reproduced? Specify ordering, dynamic offsets and
lengths, and the parent's trailing policy extension. Check whether current-authority checks
affect acknowledgment of an executed leaf after an authority change (C1).

*Proposed.* The parent level reproduces Safe 1.5.0 `checkNSignatures` with no executor, so
`v = 1` never passes. Children reproduce `CompatibilityFallbackHandler.isValidSignature(bytes32,
bytes)`: the child message hash is `keccak256(0x1901 ‖ childDomain ‖ keccak256(abi.encode(
SAFE_MSG_TYPEHASH, keccak256(abi.encode(dataHash)))))`, checked against the child's threshold
with executor zero.

For each entry `i < t`, with `t` the stored threshold of the node:

- **Q5.1** A blob shorter than `t * 65` bytes rejects.
- **Q5.2** `v = 0`: owner is `r` and must be Safe-kind; require `s >= t * 65`, `s + 32 <= len`
  and `s + 32 + L <= len`. `L = 0` takes the evidence path (Q6). `L > 0` recurses into the
  child with its message hash.
- **Q5.3** `v = 1` rejects at every level.
- **Q5.4** `v` of 27 or 28 recovers over the hash; 31 or 32 over the eth_sign-prefixed hash with
  `v - 4`. Every other `v` rejects by name.
- **Q5.5** A recovered zero address rejects; the owner must be EOA-kind.
- **Q5.6** Owners strictly ascending across all entry kinds.
- **Q5.7** Safe lets two contract entries share or overlap payload bytes and lets pointers land
  in static entries beyond `t`. *Proposed:* match Safe; bytes outside the verified parts are
  ignored anyway.
- **Q5.8** Carry the parent's signature blob byte for byte as returned by `consume`.
  Verify the quorum entries and their referenced signature payloads without parsing a
  trailing policy extension.
- **Q5.9** A child payload is a full child blob with its own threshold and possibly trailing
  bytes; the same rule applies.
- **Q5.10** Recursion depth is bounded by graph depth and uses memory, not call depth.
- **Q5.11** A shared child under two groups is evaluated twice, over different hashes.
- **Q5.12** #109 specifies the order of counter, signature and duplicate checks after rotation.
- **Q5.13** An EIP-7702 account signing with ECDSA is an EOA owner; contract-style signatures
  from it are unsupported.

### Q6. Nested approval evidence

How does the transmitter find the guard holding an empty-signature child's cached approval, and
how is the evidence packaged for recursive verification? What does a direct submitter obtain
independently? The cache key is the child Safe and message hash.

Look up the child's current transaction guard with `GuardDiscovery`, then
`getApproval(child, messageHash)`. The current guard returns `ICrossecuteGuard.SignedSafeTx`
with the full approval calldata and the child's signatures with its policy extension removed.
Wrap it in a `NestedApproval` keyed by child Safe and message hash. Carry one item per key
in an unsorted flat array and look it up by linear scan.

Cases:

- **Q6.1** The guard keys evidence by the approving Safe on whichever guard that child had when
  its approval executed. Discovery returns the child's current guard: a child that changed
  guards after caching leaves its evidence on the old one; a child with no guard reverts
  `NoGuard`; a non-Crossecute guard has no `getApproval`. *Open:* query the child's guard,
  then the parent's, then revert; or revert at once; or send without evidence and let the
  receiver reject.
- **Q6.2** The transmitter computes the key as the child-domain Safe message digest over
  `abi.encode(parentDataHash)`. The guard hashes the exact bytes passed to `signMessage`.
- **Q6.3** The recursion hash differs by path. Inline contract signatures: a grandchild signs
  over the child's message hash. Evidence: the evidence is a child Safe transaction, so a
  grandchild's empty entry inside it needs evidence over the child's approval transaction hash.
- **Q6.4** Evidence comes from an executed child transaction and may carry the child
  executor's `v = 1`, which the receiver rejects (T6 can catch it).
- **Q6.5** The receiver rebuilds the child transaction hash with `operation = DELEGATECALL` and
  the child domain, verifies its signatures under the current child node, checks the
  `signMessage(bytes)` selector and exact decoded message `abi.encode(parentHash)`. The
  signed target is part of the digest. There is no signing-library allowlist.
- **Q6.6** Missing evidence rejects. *Open:* extra evidence rejects or is ignored.
- **Q6.7** A shared child needing evidence for two hashes contributes two entries.
- **Q6.8** Evidence that no longer meets the child's current stored composition rejects; the
  child re-approves, which replaces the cached record for that hash. A provider message
  already sent carries the old copy.
- **Q6.9** A direct submitter obtains evidence from `getApproval`, from the child Safe's
  Transaction Service confirmations (an unexecuted approval is valid evidence), or from the
  provider message in the source transaction's logs.
- **Q6.10** Measure the full encoded `SignedDelivery` for provider sizing, including the
  lookup keys and flat array framing. The [guard measurements](https://github.com/crossecute/protocol/blob/6be68a278b6594390c0be67a9671d54c8e2f443d/docs/safe-approval-evidence-sizing.md)
  cover guard return data.

### Q7. Resource limits

Which limits are part of the protocol for owner counts, graph depth, proof length, call batch
size, signature blobs and evidence? Which need measurements first?

Cases:

- **Q7.1** Limits in a locked receiver never change for that conduit. Limits enforced only by
  the transmitter can.
- **Q7.2** Graph limits (owners per node, nodes, depth, total owners) must be identical at
  `createTransmitter` and receiver bootstrap. Otherwise a conduit can exist whose graph no
  receiver accepts.
- **Q7.3** The guard caps neither blobs nor evidence, so any receiver cap makes some
  source-valid sends undeliverable. The transmitter enforces receiver caps before paying (T6).
- **Q7.4** Candidates: proof length, calls per leaf (or gas only), blob length, evidence count
  and size, total signature checks per dispatch (the product of thresholds along used paths),
  and #109's catch-up batch size.
- **Q7.5** Measurements needed before choosing numbers: gas per signature entry, per nested
  level and per evidence item; memory expansion for large blobs; bootstrap storage gas against
  owners and nodes; receiver code size against EIP-170; each provider's maximum message size
  and destination gas cap per route (not yet verified).

### Q8. Permissionless bundle availability

What does proposal tooling export so an independent submitter can obtain the signed Safe
transaction, signatures, leaves and proofs, and nested evidence? How does that work before
source execution and when the provider is unavailable?

Cases:

- **Q8.1** The bundle holds every Safe transaction field, the Safe address and home chain id,
  signatures and recursive evidence. For Merkle relay, include the root, every leaf with its
  full calls and proof, and each receiver's Merkle nonce at build time. It carries an
  off-chain schema version; D4 applies only to the on-chain payload.
- **Q8.2** Before source execution, signatures exist only with signers or in the Safe
  Transaction Service. A partial set is useless until it meets the receiver's thresholds.
- **Q8.3** The transmitter caches the original Safe transaction, signatures and nested
  evidence by root. `relayLeaf` reads the cached authorization. The cache itself does not
  contain the tree's leaf data.
- **Q8.4** Publish every leaf's full encoded fields and calls with its proof, or publish the
  full ordered tree data needed to construct proofs. A root and hashes alone cannot recover
  the calls. The entire tree is independently relayable only once those bytes are available.
- **Q8.5** Anyone can check a bundle against the Safe hash, root and proofs, so its source
  needs no trust.
- **Q8.6** Signers need the bundle to review other leaves, since the Safe UI shows an opaque
  payload.
- **Q8.7** Merkle relayers read the transmitter's used state and the receiver's `nextNonce`
  to pick a leaf to relay.
- **Q8.8** #109's update history must stay available for initialized receivers that lag behind.
- **Q8.9** Retryable destination failures include early delivery, a future Merkle nonce,
  insufficient funds or gas, and some target reverts. An expired or conflicting leaf, invalid
  signatures, `v = 1`, missing evidence or a wrong destination needs a corrected submission
  or new authorization.

## Other open items

- **O1.** Gating on zkSync and Tron. `execute`, `commit`, `cancel` and `revokeGateway` accept
  `msg.sender == sourceTransmitter`, which on those chains is whatever code sits at the home
  transmitter's address. *Proposed:* the signed variant accepts only `address(this)` during
  verified execution.
- **O2.** `receiveMessage` always routes to the signed verifier, never `_onMessage`. *Open:*
  keep the gateway role and sender checks as an extra layer.
- **O3.** Fee drain. Whoever executes a fully signed Safe transaction controls the bytes after
  the threshold entries (#117). LayerZero and CCIP price per byte from the transmitter's
  balance. The parent blob stays byte-exact. *Open:* choose a payload cap after measurement.
- **O4.** Quote and send parity. Quote and provider relay need the same signed bundle and
  leaf witness to price the wire message. `DeliveryGas.PAYLOAD` (200,000) does not cover
  nested verification.
- **O5.** `MessageSent` reports the signed recipient for a standalone send and the leaf
  destination for `relayLeaf`. Root registration creates no provider message.
- **O6.** One reentrancy lock covers `receiveMessage`, direct submission, `finalize`, `execute`
  and #109's update entry point. A leaf calling `finalize` reverts; document it.
- **O7.** Gas griefing. `Executor` reverts on any failed call, but a target that catches an
  internal out-of-gas can succeed differently and the nonce is consumed. *Open:* a signed
  minimum gas checked under the 63/64 rule.
- **O8.** Deadlines must cover provider latency (OP Stack L2 to L1 waits out the challenge
  period). The window does not bound `finalize` of a commitment. Anyone chooses the execution
  moment within the window, so narrow windows limit MEV on parameter changes.
- **O9.** With a fixed signer policy in the first release, *open:* what stops source owner
  changes before #109 ships. Without a block, removed owners keep destination authority.
- **O10.** #109 specifies which pending approvals and in-flight dispatches survive parent
  and child rotations.
- **O11.** No atomicity across destinations: a two-chain upgrade can stay half applied.
- **O12.** EVM destinations only in the first release. No leaf can target the home chain.
- **O13.** Receiver code size: the verifier, codec and Merkle code likely exceed EIP-170 and
  need an extension or libraries, fixed with the receiver.
- **O14.** The receiver deduplicates, so the exactly-once transport requirement
  ([P7](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist),
  [R3.5](provider-spec.md#r3-receive)) can be relaxed for the signed variant. Check each provider's retry path for
  failed deliveries; the CCIP ordering preflight is
  [#118](https://github.com/crossecute/protocol/issues/118).
- **O15.** Direct submission: nonpayable, or treat value as a top-up.

## Receiver check order

The proposed sequence for standalone and Merkle delivery. "Retryable" means the same bytes can succeed
later; "permanent" means a replacement leaf or new signatures are needed.

| # | Check | On failure |
| --- | --- | --- |
| R1 | Entry: provider (role and origin checks if kept, O2) or direct | revert |
| R2 | Reentrancy lock | revert |
| R3 | Rebuild the Safe digest from exact calldata and check the expected signed selector | revert, permanent |
| R4 | Decode the signed standalone recipient and payload, or the registered root and supplied leaf | revert, permanent |
| R5 | Destination is (`block.chainid`, `address(this)`) | revert, permanent |
| R6 | Merkle only: verify the leaf proof against the root in signed registration calldata | revert, permanent |
| R8 | Authority counter checks are deferred to #109 | |
| R9 | Verify signatures and nested evidence | revert, permanent |
| R10 | Standalone digest or Merkle leaf already executed | succeed silently for Merkle, emit `DuplicateMessage()` for standalone |
| R11 | `executed[nonce] != 0` | revert, conflicting leaf, permanent |
| R12 | Merkle only: require the next nonce and check the signed execution window | revert |
| R14 | Minimum gas, if O7 is adopted | revert, retryable |
| R15 | Record the standalone digest or Merkle leaf hash. For a new leaf, increment `nextNonce`, rejecting overflow | revert, permanent |
| R16 | Execute the calls atomically; an empty batch is allowed | revert undoes R15, retryable |

A nonce below `nextNonce` always has a record, because nonces advance only through execution,
so R10 to R12 cover every case and a lower nonce with no record is an invariant failure.

## Transmitter send and relay order

| # | Check |
| --- | --- |
| T1 | Only the owner Safe may call `sendMessage` or `registerRoot`. Anyone may call `relayLeaf` |
| T2 | For either Safe call, consume the staged guard record and restore `safeTx.data` from `msg.data` |
| T3 | For `sendMessage`, validate the normal recipient and payload, and wrap the signed authorization |
| T4 | For `registerRoot`, cache the signed authorization and evidence for the supplied root |
| T5 | For `relayLeaf`, require a cached registration, verify the proof, require an unused leaf hash, and validate the destination route |
| T6 | Validate signature and evidence limits before paying for provider relay |
| T7 | Build the Merkle wire message from the cache, root, leaf and proof |
| T8 | Quote the final wire message and check funding |
| T9 | Mark the relayed leaf hash used before calling the provider. Revert the mark if the send fails |

## Tests

#108's acceptance criteria list the required tests. These cases follow from the items above
and are not in them yet:

- standalone signed sends use the plain recipient and application payload, execute once
  across both delivery routes, and never read the root cache;
- only the owner can register a root. Anyone can relay two leaves from the same root in two
  calls using the cached authorization;
- source relay and destination execution each reject altered calls or a proof from another
  root. A standalone authorization cannot serve as root approval or vice versa;
- failed provider sends roll back the source mark. Successful sends reject another relay
  of the same leaf. Destination failure leaves the receiver unmarked, and a retry succeeds
  once without another source send;
- direct Merkle execution leaves the source unused. A later `relayLeaf` marks it used on
  the transmitter and delivers successfully, with no destination event, calls or nonce
  advance, including after the deadline;
- a forged or invalid proof still rejects after the leaf has already executed;
- a signed DELEGATECALL dispatch rejects (Q1.1);
- replay through the same Safe and transmitter addresses on another chain (Q4.2);
- non-canonical calldata and ERC-7930 encodings (Q1.4, Q2.4);
- `v = 1` executor signatures in the parent blob and in cached evidence (Q5.3, Q6.4);
- signature blob padding by the Safe executor and its fee effect (O3);
- a forged bootstrap with the correct graph and a wrong transmitter or home (Q4.1, Q4.2);
- leaves calling #109's update entry point, `finalize` and `revokeGateway` (Q2.10, O6);
- a target exploiting low gas with try/catch (O7);
- a tree spanning two providers' conduits rejects (C4);
- quote and send agree for large blobs (O4);
- a duplicate submitted after a parent rotation and after a child rotation (C1).
