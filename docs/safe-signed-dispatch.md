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

- **D1.** The Safe signs the full `sendMessage(bytes,bytes,bytes[])` calldata as a normal queued
  Safe transaction. The transmitter sends in one step: the Safe calls it directly, it consumes
  the guard-staged context and initiates provider delivery in the same source transaction. No
  separate publication or witness submission.
- **D2.** The ERC-7786 signature is unchanged. The signed variant ignores `recipient` for
  routing and uses the full ERC-7930 destination committed in the selected leaf. `recipient`
  stays part of the signed bytes.
- **D3.** The signed Safe `to` must equal the receiver's configured source transmitter.
- **D4.** A locked receiver deployment uses one fixed payload format. There is no payload
  version field.
- **D5.** Provider delivery and direct submission both supply the exact signed calldata bytes
  so the receiver can reconstruct the Safe transaction hash. A Merkle root or proof never
  substitutes for signed bytes.

Trees and leaves:

- **D6.** One tree can cover multiple destinations and consecutive local nonces on the same
  receiver. Each provider delivery or direct submission processes exactly one leaf. A leaf
  carries an ordered batch of calls that executes atomically.
- **D7.** The multisig can reuse the same tree in separately signed `sendMessage` transactions
  at different Safe nonces. Anyone can submit another destination's leaf directly without
  new signatures.
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
  `DuplicateMessage()`, without calls or nonce advance, even under a different valid root or
  after its deadline. The leaf hash comes from the leaf's fields, not the root or proof. A
  different leaf at a consumed nonce reverts. A first delivery after the deadline reverts. See
  [C1](#conflicts-to-resolve-first) for the case this cannot cover as written.
- **D12.** A replacement leaf at the current nonce may carry revised calls or an empty batch.
  If the original leaf is still valid, either may consume the nonce first.
- **D13.** A commit-only leaf consumes its nonce when the commitment is recorded. `finalize`
  consumes the commitment later without touching the nonce.
- **D14.** Each leaf commits to `validAfter` and `deadline`. A new execution requires
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

- **C1. Duplicate acknowledgment after an authority change.** D11 asks for an *authenticated*
  replay, and authentication runs against the receiver's current authority. After an authority
  change it can fail for a leaf that already executed: a parent counter advance fails the
  equality check (if that check runs before the duplicate check), a raised parent threshold
  leaves the blob short, and a removed owner or rotated child leaves the old signatures
  short. The receiver keeps no old composition to check against. A provider retry of a leaf
  that already executed by direct submission then fails permanently. Options:
  - (a) Accept that acknowledgment reverts after an authority change. Nothing executes, but
    the provider message stays failed.
  - (b) Skip the counter check for duplicates but keep signature verification. Covers counter
    changes, not signer changes.
  - (c) Accept a leaf-hash match at its nonce as sufficient for `DuplicateMessage()` without
    signatures. The leaf is public once executed, so anyone can trigger the event, but it
    can never execute or write state. The provider path then reports success for
    unauthenticated bytes.

  *Proposed:* (a) or (c); the choice changes the order of R8 to R10 in the
  [receiver check order](#receiver-check-order).
- **C2. #109 fields in the frozen genesis format.** The initial commitment is part of the
  conduit address and receivers are locked, so anything genesis may need cannot be added for
  existing conduits later: a rotation quorum stricter than the dispatch quorum (#109's
  acceptance criteria), a freeze authority, per-node starting counters, handler kind, version.
  *Open:* which #109 features touch genesis, before Q3's codec is fixed.
- **C3. "Verify source counter consistency."** #108 uses the phrase without defining what the
  receiver checks. *Proposed:* the transmitter compares the tree's counter with its stored
  parent counter before sending (T5); the receiver checks only equality with its own counter.
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

Should `sendMessage.payload` contain the shared root and the selected leaf and proof? If the
Safe sends to Base, can the bridge deliver the exact signed calldata and let Base extract its
leaf? For a direct submission on Arbitrum, how does the caller supply the Arbitrum leaf and
proof alongside the original signed Base calldata? Which Safe context, signatures and evidence
travel with each path, and which fields come from receiver configuration?

*Proposed.* [`ISignedDispatch.sol`](../contracts/evm/src/messaging/ISignedDispatch.sol) shows
`DispatchPayload` with the parent authority counter, root, selected leaf and proof. Encode it
as a single struct with `abi.encode(dispatch)` and read it with
`abi.decode(payload, (DispatchPayload))`. The provider path carries the original signed
calldata and verifies its embedded leaf. `submitDirect` takes the Safe context containing that
same calldata, signatures, evidence, and the requested leaf and proof. The verifier reads the
counter and root from the signed calldata. Field widths and the context and evidence encodings
are provisional.

| Field | Provider path | Direct path | From receiver configuration |
| --- | --- | --- | --- |
| Safe address, home chain id (domain) | | | yes |
| `to` | | | yes, the source transmitter |
| `operation`, `safeTxGas`, `gasPrice` | if not fixed | if not fixed | yes, if fixed (Q1.1) |
| `value`, `baseGas`, `gasToken`, `refundReceiver`, Safe `nonce` | yes | yes | |
| `data` (full signed calldata) | yes | yes | |
| `signatures` | yes, possibly trimmed (O3) | yes | |
| nested evidence | yes, attached by the transmitter | yes | |
| requested leaf and proof | embedded | explicit in the proposed interface | |

Cases:

- **Q1.1** Fixing `operation = CALL` and `safeTxGas = gasPrice = 0` in configuration makes any
  other value inexpressible on the wire, which is the intended rejection. Leaving them on the
  wire unchecked lets a signed but unexecuted DELEGATECALL dispatch verify.
- **Q1.2** The guard records `baseGas`, `gasToken` and `refundReceiver` and the policy does not
  force them to zero, so they travel. *Open:* require zero anyway.
- **Q1.3** Check the `sendMessage` selector before decoding.
- **Q1.4** *Open:* require canonical ABI encoding of the signed calldata (re-encode and
  compare). The leaf hash commits to the exact call payload bytes, and the receiver decodes
  those same bytes to execute the calls.
- **Q1.5** The provider path executes the embedded leaf. A direct submission of that same leaf
  gives the same result and the same duplicate record.
- **Q1.6** *Proposed:* a receiver executing an override leaf does not check the embedded leaf's
  proof, so a mistake in Base's proof does not block Arbitrum.
- **Q1.7** The provider path never carries an override. *Open:* one struct for the wire format
  and the direct input, with the override empty on the provider path, or two.
- **Q1.8** `recipient` and `attributes` are decoded only to reach `payload`.
- **Q1.9** A direct submitter on Arbitrum carries Base's full batch inside the signed calldata.
  Which leaf is embedded affects every other destination's submission cost.
- **Q1.10** The same root signed at Safe nonces 42 and 43 with different embedded leaves gives
  two valid envelopes.

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

*Proposed.* A node array with the root at index 0 and children referenced by index. Each
Safe address has one record with explicit owner kinds and the owner order returned by Safe.

Cases:

- **Q3.1** Owner kind is a tag: EOA, or Safe with a node index. Inferring kind from whether a
  node exists lets a missing record turn a Safe into an EOA. A Safe owner whose index points to
  a node with a different address rejects.
- **Q3.2** The commitment preserves each Safe's `getOwners()` order. Signature verification
  checks ascending signer addresses independently of the stored owner list order.
- **Q3.3** Node order must be canonical and make cycles cheap to reject. Breadth-first by first
  reference does not guarantee forward edges: a shared child first reached at depth 1 and
  referenced again from depth 2 points backward. *Proposed:* every edge points to a higher
  index, with a canonical tie-break.
- **Q3.4** Fields left implicit (handler kind, version, starting counter) can never be added
  for existing conduits. Depends on C2.
- **Q3.5** Reject: threshold outside `1..owners`, `address(0)` or `address(1)` as an owner, a
  node owning itself, duplicate node addresses, unreachable nodes, and an address that is an
  EOA in one group and a Safe in another.
- **Q3.6** Safe permits mutual ownership (A owns B, B owns A), and non-Safe contract owners such
  as timelocks cannot be verified without a light client. *Open:* a "cannot sign" owner kind.
  Without it such Safes cannot use signed conduits; with it, creation checks that the owners
  able to sign can still reach threshold.
- **Q3.7** The owner hash and the threshold hash both include each node's address, so
  thresholds cannot move between nodes. *Open:* record why the commitment uses two hashes.
- **Q3.8** The root node is the transmitter's owner Safe.
- **Q3.9** [`SafeOwnerManager.sol`](../contracts/evm/src/messaging/SafeOwnerManager.sol)
  proposes one `SafeState` per Safe, with a linked owner list and threshold. Keep the
  authority counter and owner kind metadata in the surrounding record. The signed update
  carries Safe's mutation selector and arguments. After verifying the update, the receiver
  can use `using SafeOwnerManager for SafeState` and call
  `safeStates[childSafe].swapOwner(prevOwner, oldOwner, newOwner)` on the selected record.
  The signed state is ERC-7201 namespaced so it does not freeze the base's sequential
  layout ([R8.2](provider-spec.md#r8-storage-and-address-parity)).
- **Q3.10** *Open:* whether `createTransmitter` checks the graph against live Safe state
  (owners and threshold per node, `VERSION`, fallback handler). Checking the handler by address
  needs a list of accepted deployments per chain.

### Q4. Authenticated receiver bootstrap

How do the initial owner graph, creation salt, source transmitter and intended implementation
bind to the receiver address? What does the receiver recompute before accepting its initial
authority or running bootstrap calls?

*Proposed.* A separate signed transceiver per provider, so the deployer address in CREATE2
separates signed and plain conduits and binds the implementation (the address does not
include it: `Proxy`'s initcode is fixed and the transceiver installs the implementation).
`salt = H(TAG, initialCommitment, userSalt)`, and the receiver recomputes its own address.

Cases:

- **Q4.1** The transmitter cannot be part of the salt, since its address is derived from it.
  The receiver derives the transmitter only when the home is `Predetermined`. For a `Unique`
  home a bridge carries it, and a forged bootstrap with the correct graph but a wrong
  transmitter permanently disables that address on that chain, because `Proxy` arms once.
  *Open:* refuse `Unique` homes for signed conduits, or bind the home transceiver and its
  derivation formula into the salt.
- **Q4.2** The EIP-155 home chain id used in the Safe domain must agree with the authenticated
  origin and the home chain key; mismatch rejects.
- **Q4.3** Before accepting authority, in order: decode the graph, validate it (Q3.5), compute
  the commitment, compute the salt, compute `conduitSalt(rootSafe, salt, homeChainKey)`,
  compare the prediction with `address(this)`, check the transmitter derivation, then store
  the graph with counters and `nextNonce` at zero.
- **Q4.4** Bootstrap carries no calls. The guard never stages `bootstrap`, so its calls are
  never signed, and a compromised bridge with the correct graph could run them at the real
  address. The first action is the nonce-0 leaf.
- **Q4.5** With Q4.1 and Q4.4 in place, a forged bootstrap can only create the state a real one
  would. *Open:* offer bootstrap without a bridge.
- **Q4.6** A late bootstrap starts from the genesis graph and catches up through #109's updates;
  the current graph cannot be bootstrapped directly.
- **Q4.7** A plain transceiver's bootstrap for the same owner and salt lands at a different
  address. Test it.
- **Q4.8** The new envelope kind changes `IReceiverInit.initialize`; measure bootstrap payload
  size and gas against graph size. The receiver exposes the initial commitment and `userSalt`.

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
- **Q5.8** The receiver reads only bytes the first `t` entries and their pointers reach, so it
  never parses the parent's policy extension. If the transmitter trims (O3), it keeps exactly
  those bytes and rewrites pointers, which changes the blob but not the digest. Trimming to
  the source threshold drops extra entries that a higher receiver threshold could have used.
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

*Proposed.* Look up the child's current transaction guard with `GuardDiscovery`, then
`getApproval(child, messageHash)`. Package evidence in the depth-first order in which
verification meets empty entries.

Cases:

- **Q6.1** The guard keys evidence by the approving Safe on whichever guard that child had when
  its approval executed. Discovery returns the child's current guard: a child that changed
  guards after caching leaves its evidence on the old one; a child with no guard reverts
  `NoGuard`; a non-Crossecute guard has no `getApproval`. *Open:* query the child's guard,
  then the parent's, then revert; or revert at once; or send without evidence and let the
  receiver reject.
- **Q6.2** The transmitter computes the key over `abi.encode(parentDataHash)`. It matches the
  guard's key only if the child passed exactly those 32 bytes to `signMessage`.
- **Q6.3** The recursion hash differs by path. Inline contract signatures: a grandchild signs
  over the child's message hash. Evidence: the evidence is a child Safe transaction, so a
  grandchild's empty entry inside it needs evidence over the child's approval transaction hash.
- **Q6.4** Evidence comes from an executed child transaction and may carry the child
  executor's `v = 1`, which the receiver rejects (T6 can catch it).
- **Q6.5** The receiver rebuilds the child transaction hash with `operation = DELEGATECALL` and
  the child domain, verifies its signatures under the current child node, requires
  `data == signMessage(abi.encode(parentHash))`, and leaves `to` unchecked. *Open:* omit `data`
  from the wire and rebuild it, which saves bytes and rejects non-canonical encodings Safe
  accepted.
- **Q6.6** Missing evidence rejects. *Open:* extra evidence rejects or is ignored.
- **Q6.7** A shared child needing evidence for two hashes contributes two entries.
- **Q6.8** Evidence that no longer meets the child's current stored composition rejects; the
  child re-approves, which replaces the cached record for that hash. A provider message
  already sent carries the old copy.
- **Q6.9** A direct submitter obtains evidence from `getApproval`, from the child Safe's
  Transaction Service confirmations (an unexecuted approval is valid evidence), or from the
  provider message in the source transaction's logs.
- **Q6.10** For two children with 10 and 5 signatures, `getApproval` returns 2,176
  ABI-encoded bytes in total
  ([sizing on #117](https://github.com/crossecute/protocol/blob/6be68a278b6594390c0be67a9671d54c8e2f443d/docs/safe-approval-evidence-sizing.md)).

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
- **Q8.3** After execution, the `execTransaction` input holds every field and the signatures
  (recovering them needs a trace if a contract made the call). `SafeL2` also emits
  `SafeMultiSigTransaction` with all of them; the plain `Safe` singleton does not. *Open:*
  the transmitter emits the full wire message, making the home chain a complete source for
  the routed leaf.
- **Q8.4** Leaves that are not routed are never on-chain unless published. *Open:* publish
  them, or accept that losing the bundle means they never run.
- **Q8.5** Anyone can check a bundle against the Safe hash, root and proofs, so its source
  needs no trust.
- **Q8.6** Signers need the bundle to review other leaves, since the Safe UI shows an opaque
  payload.
- **Q8.7** Direct submitters read `nextNonce` and the counter from receiver views to pick an
  executable leaf.
- **Q8.8** #109's update history must stay available for late receivers (Q4.6).
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
  balance. *Open:* trim (Q5.8) or cap.
- **O4.** Quote and send parity. `quoteMessage(recipient, payload, attributes)` cannot know
  signature or evidence size; a signed quote takes them and shares one computation with the
  send. `DeliveryGas.PAYLOAD` (200,000) does not cover nested verification.
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
| R4 | Select the leaf (override or embedded); tag | revert, permanent |
| R5 | Destination is (`block.chainid`, `address(this)`) | revert, permanent |
| R6 | Proof against the root from the signed calldata | revert, permanent |
| R7 | Rebuild the Safe digest from configuration and wire fields | |
| R8 | Counter equals the receiver's counter (order per C1) | revert; retryable if the receiver lags, permanent if ahead |
| R9 | Signatures and evidence under current authority (order per C1) | revert, permanent |
| R10 | `executed[nonce] == leafHash` | emit `DuplicateMessage()`, succeed |
| R11 | `executed[nonce] != 0` | revert, conflicting leaf, permanent |
| R12 | `nonce > nextNonce` | revert, future nonce, retryable |
| R13 | `validAfter <= block.timestamp <= deadline` | revert; retryable if early, permanent if expired |
| R14 | Minimum gas, if O7 is adopted | revert, retryable |
| R15 | Record the leaf hash; increment `nextNonce`, rejecting overflow | |
| R16 | Execute the calls atomically; an empty batch is allowed | revert undoes R15, retryable |

A nonce below `nextNonce` always has a record, because nonces advance only through execution,
so R10 to R12 cover every case and a lower nonce with no record is an invariant failure.

## Transmitter send order

| # | Check |
| --- | --- |
| T1 | `onlyConduitOwner` (the Safe) |
| T2 | Discover and consume the guard record before any external call; no unsigned fallback |
| T3 | Decode the payload; tag; canonical encoding if Q1.4 |
| T4 | The leaf's destination is the recorded receiver on a bootstrapped chain |
| T5 | *Proposed:* the proof verifies and the counter equals the stored counter (C3) |
| T6 | *Proposed:* no `v = 1`, evidence found (Q6.1), within receiver caps (Q7.3) |
| T7 | Build the wire message: calldata, Safe context, signatures (trimmed if O3), evidence |
| T8 | Quote from the wire message and check funding (O4) |
| T9 | Send; emit `MessageSent` with the leaf's destination (O5) |

## Tests

#108's acceptance criteria list the required tests. These cases follow from the items above
and are not in them yet:

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
