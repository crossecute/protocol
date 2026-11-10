# Safe-signed dispatch

How a signature-enabled transmitter sends a Safe-signed Merkle dispatch, and how a receiver
verifies it through provider delivery or permissionless direct submission. Tracked in
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

- **D1.** The Safe signs a normal queued `sendMessage(bytes,bytes,bytes[])` transaction.
  Its payload commits to the Merkle root and parent authority counter. One Safe quorum
  authorizes every leaf under that root.
- **D2.** The ERC-7786 signature is unchanged. Each leaf commits to its full ERC-7930
  destination. Leaf publication and delivery use witnesses supplied separately from the
  signed payload. Q1 covers the source entry points and routing.
- **D3.** The signed Safe `to` must equal the receiver's configured source transmitter.
- **D4.** A locked receiver deployment uses one fixed payload format. There is no payload
  version field.
- **D5.** Both delivery paths supply the exact signed Safe calldata and context. The receiver
  verifies the Safe quorum over the root authorization and checks the submitted leaf's proof
  against that root. It hashes and executes only that leaf. No per-leaf signature is required.

The transmitter discovers the transaction guard from the owner Safe on every send. Only the
signed target can consume the staged record, once. The guard clears it in the Safe post-hook.
Each dispatch in an outer batch must be a separately signed, top-level Safe execution.
A single Safe-signed MultiSend does not stage its inner calls. Module calls do not stage
owner authorization either.

Trees and leaves:

- **D6.** One tree can cover multiple destinations and consecutive local nonces on the same
  receiver. Each provider delivery or direct submission processes exactly one leaf. A leaf
  carries an ordered batch of calls that executes atomically.
- **D7.** The transmitter records authorized roots and their verified leaf hashes. The full
  signed Safe transaction, signature blob and nested approval evidence are published in
  source-chain logs. Full leaf data is published so anyone can submit every batch independently
  with its proof. The receiver verifies the submission locally using its configured authority.
- **D8.** Each leaf commits to its destination receiver's local nonce. The source Safe nonce
  stays in the signed Safe transaction context and is used only to rebuild the digest.

Verification and replay:

- **D9.** Provider delivery and direct submission share one verifier and one replay state.
  Every dispatch, including a commit-only leaf, verifies before changing state. Provider
  sender metadata and local self-calls never substitute for it, including where the
  transmitter and receiver share an address on different chains.
- **D10.** Each receiver starts at `nextNonce = 0` and requires `leaf.localNonce == nextNonce` for a
  new execution. It records the leaf hash and advances before external calls, rejects
  overflow, and rolls both back if execution reverts.
- **D11.** An authenticated replay of an executed leaf returns successfully with
  `DuplicateMessage()`, without calls or nonce advance, including under a different valid root, within the signed window. The leaf hash comes from the leaf's fields, not the root or proof. A
  different leaf at a consumed nonce reverts. First and repeat deliveries after the deadline revert.
- **D12.** A replacement leaf at the current nonce may carry revised calls or an empty batch.
  If the original leaf is still valid, either may consume the nonce first.
- **D13.** A commit-only leaf consumes its nonce when the commitment is recorded. `finalize`
  consumes the commitment later without touching the nonce.
- **D14.** Each leaf commits to `validAfter` and `deadline`. First and repeat deliveries require
  `validAfter <= deadline` and `validAfter <= block.timestamp <= deadline` on destination time,
  inclusive. No zero-deadline bypass. A rejected window consumes nothing.

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
- **D18.** Trees commit to the parent's authority-change counter, which must equal the
  receiver's counter. Authority updates and dispatch execution have separate entry points.
  The change protocol is #109's.
- **D19.** No light clients. Quorum-authorized dispatches can execute at the destination
  without source execution or bridge delivery.

## Conflicts to resolve first

- **C1. Duplicate acknowledgment after an authority change.** A duplicate still requires
  current authority. A provider retry can fail after rotation even if direct submission
  already executed the leaf.
- **C2. #109 fields in the bootstrap snapshot.** The snapshot carries one applied
  authority counter per Safe. #109 owns the fields and rules for later authority changes.
- **C3. "Verify source counter consistency."** #108 uses the phrase without defining what the
  receiver checks. *Proposed:* the transmitter compares the tree's counter with its stored
  parent counter at root registration (T5); the receiver checks only equality with its own counter.
- **C4. One tree cannot span providers.** D3 binds the signed `to` to one transmitter. Each
  provider has its own transceiver and so its own transmitter and conduit address. Receivers of
  a LayerZero conduit and a CCIP conduit cannot share a signed Safe transaction. *Proposed:*
  state the limit; accepting a set of transmitters is a larger change.
- **C5. Source-side policy does not gate destination effects.** Under D19 a signed but
  unexecuted Safe transaction executes at the destination, so checks the home Safe applies at
  execution time (the guard's PolicyEngine, SafenetPolicy, delay modules) never see it.
  *Open:* document as accepted, or not.
- **C6. Safe cancellation does not cancel.** Signing a rejection at the same Safe nonce
  replaces the source transaction but leaves the original signatures valid at the destination
  until the window expires, a replacement leaf consumes the nonce, or a parent rotation lands.
  Signatures in the Safe Transaction Service are public once threshold is reached. *Open:*
  document as accepted, and say what tooling shows signers.
- **C7. PR #115's draft of this file.** It describes a superseded design: `minimumNonce` with
  gaps, no stored execution hash, leaves committing to the parent nonce, and evidence that must
  delegatecall a supported signing library. This file replaces it.

## Open questions

### Q1. Signed calldata and delivery envelope

[`ISignedDispatch.sol`](../contracts/evm/src/messaging/ISignedDispatch.sol) proposes a
two-word `DispatchPayload` containing the root and parent authority counter. Both delivery
paths carry a `SignedDelivery` with the exact
[`ICrossecuteGuard.SafeTx`](../contracts/safe-guard/src/ICrossecuteGuard.sol), the original
parent signature blob and nested approval evidence. The leaf and proof travel alongside it.
A direct submission carries only the batch being executed and its proof, even when the root
authorizes other destinations.

- **Q1.1** Use the configured source Safe and chain ID for the EIP-712 domain. Check the
  signed target against the configured source transmitter and require `operation == CALL`
  and zero `safeTxGas` and `gasPrice`, as the guard policy does.
- **Q1.2** All SafeTx fields travel in Safe 1.5.0 EIP-712 order. The transmitter restores
  `safeTx.data` from `msg.data` after `consume(ownerSafe)` returns it empty.
- **Q1.3** Check the selector before decoding. Hash the exact calldata and test digest parity
  with Safe 1.5.0 `getTransactionHash`.
- **Q1.4** *Open:* require canonical ABI encoding of the signed calldata. Hash the exact
  call payload bytes and decode those same bytes for execution.
- **Q1.5** Provider and direct delivery of the same leaf share the proof check and duplicate
  record.
- **Q1.6** *Proposed:* `sendMessage` registers and publishes the signed root authorization.
  A permissionless source entry point accepts a leaf and proof for a registered root,
  verifies membership, and records and publishes the leaf. A proof is required before a
  leaf hash is recorded. Direct submission can proceed independently of source registration.
- **Q1.7** *Open:* whether to combine leaf publication with provider relay, and how to
  supply the signed bundle, pay provider fees and return a send ID in that flow.
- **Q1.8** *Open:* required values for the signed ERC-7786 `recipient` and `attributes`
  when registering a root.
- **Q1.9** *Open:* registry layout, event format and publication limits. Measure source
  storage and log cost per root and per leaf, plus the provider envelope with signatures
  and nested evidence. A relay must have the full bytes and proof even if a leaf hash is
  already registered.
- **Q1.10** If a root is signed at different Safe nonces, the signatures authenticate distinct
  Safe transactions. Publish each authorization independently. Executing a leaf via one
  still consumes the same receiver nonce.

### Q2. Leaf and tree encoding

What fields and byte encoding define an execution leaf? How does it commit to the ordered
calls with the existing EVM `Call[]` codec, where does the parent authority counter belong,
and how are leaves and internal nodes hashed? Specify proof ordering and the single-leaf tree.

*Proposed.* Frame the leaf fields with `abi.encode` and double-hash the result. Include the
full destination and `callPayload` bytes in the inner hash. EVM call payloads use the existing
`abi.encode(Call[])` format. Internal nodes hash sorted pairs, as in OpenZeppelin's
`MerkleProof`. Carry an unpaired hash to the next level unchanged. The execution tag, field
order and integer widths remain open.

Cases:

- **Q2.1** Counter placement. In each leaf, a leaf re-signed after a rotation gets a new hash
  and stops matching its duplicate record. Beside the root in the signed payload, the leaf
  hash is stable across rotations and every leaf in a tree shares the parent counter.
  *Proposed:* beside the root. #109's management leaves carry their own prior and next
  counters either way.
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
- **Q5.12** The counter check runs before signatures to save gas on stale trees. Its order
  relative to the duplicate check follows C1.
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
  signatures, recursive evidence, the root and counter, every leaf with its full calls and
  proof, the graph or its commitment, and each receiver's nonce at build time. It carries an
  off-chain schema version; D4 applies only to the on-chain payload.
- **Q8.2** Before source execution, signatures exist only with signers or in the Safe
  Transaction Service. A partial set is useless until it meets the receiver's thresholds.
- **Q8.3** Source registration publishes the original Safe transaction, signatures and nested
  evidence in a log keyed by root. Relayers can retrieve the authorization without tracing a
  Safe call. The registry holds hashes for lookup.
- **Q8.4** Publish every leaf's full encoded fields and calls with its proof, or publish the
  full ordered tree data needed to construct proofs. A root and hashes alone cannot recover
  the calls. The entire tree is independently relayable only once those bytes are available.
- **Q8.5** Anyone can check a bundle against the Safe hash, root and proofs, so its source
  needs no trust.
- **Q8.6** Signers need the bundle to review other leaves, since the Safe UI shows an opaque
  payload.
- **Q8.7** Direct submitters read `nextNonce` and the counter from receiver views to pick an
  executable leaf.
- **Q8.8** #109's update history must stay available for initialized receivers that lag behind.
- **Q8.9** Failures a submitter can retry: early, future nonce, receiver counter behind, low
  balance or gas, and possibly a reverting call. Failures that need a replacement leaf or new
  signatures: expired, conflicting leaf at a consumed nonce, invalid signatures, receiver
  counter ahead, `v = 1`, missing evidence, wrong destination.

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
- **O5.** `MessageSent` reports the leaf's destination, not `recipient`.
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
- **O10.** Exact counter equality invalidates every pending tree at each parent rotation, and a
  lagging receiver rejects new trees until someone delivers updates. A child rotation
  invalidates in-flight dispatches that used that child.
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

The proposed sequence for both delivery routes. "Retryable" means the same bytes can succeed
later; "permanent" means a replacement leaf or new signatures are needed.

| # | Check | On failure |
| --- | --- | --- |
| R1 | Entry: provider (role and origin checks if kept, O2) or direct | revert |
| R2 | Reentrancy lock | revert |
| R3 | `sendMessage` selector; calldata decode (canonical if Q1.4) | revert, permanent |
| R4 | Decode the supplied leaf; tag | revert, permanent |
| R5 | Destination is (`block.chainid`, `address(this)`) | revert, permanent |
| R6 | Proof against the root from the signed calldata | revert, permanent |
| R7 | Rebuild the Safe digest from configuration and wire fields | |
| R8 | Counter equals the receiver's counter (order per C1) | revert; retryable if the receiver lags, permanent if ahead |
| R9 | Signatures and evidence under current authority, then check the inclusive execution window | revert, permanent |
| R10 | `executed[nonce] == leafHash` | emit `DuplicateMessage()`, succeed |
| R11 | `executed[nonce] != 0` | revert, conflicting leaf, permanent |
| R12 | `nonce > nextNonce` | revert, future nonce, retryable |
| R14 | Minimum gas, if O7 is adopted | revert, retryable |
| R15 | Record the leaf hash; increment `nextNonce`, rejecting overflow | |
| R16 | Execute the calls atomically; an empty batch is allowed | revert undoes R15, retryable |

A nonce below `nextNonce` always has a record, because nonces advance only through execution,
so R10 to R12 cover every case and a lower nonce with no record is an invariant failure.

## Transmitter registration and relay order

The split below is proposed in Q1.6. Q1.7 covers the provider entry point and fee handling.

| # | Check |
| --- | --- |
| T1 | Root registration requires the conduit owner Safe |
| T2 | Discover the current guard, consume the Safe record once, and restore `safeTx.data` from `msg.data` |
| T3 | Decode the signed root and counter; check canonical encoding if Q1.4 is adopted |
| T4 | For provider relay, require the leaf's destination to be the recorded receiver on a bootstrapped chain |
| T5 | Check the live counter at root registration. Verify a leaf's proof against a registered root before recording its hash or relaying it |
| T6 | *Proposed:* no `v = 1`, evidence found (Q6.1), and within receiver caps before paying for provider relay (Q7.3) |
| T7 | Build `SignedDelivery` with the full SafeTx, original parent signatures and keyed approvals. Record the root and publish the bundle |
| T8 | For provider relay, quote the wire message and check funding (O4) |
| T9 | Send the signed bundle with the leaf and proof; emit `MessageSent` with the leaf's destination (O5) |

## Tests

#108's acceptance criteria list the required tests. These cases follow from the items above
and are not in them yet:

- two destination leaves execute from one signed root and separate proofs;
- a relayer supplies altered calls or a leaf from another tree with an otherwise valid signed
  root, and registration and execution both reject the proof;
- an independent relayer can reconstruct submissions for all leaves from the published bundle
  and leaf data;
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
