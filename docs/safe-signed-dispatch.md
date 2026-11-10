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
  calldata for one destination. The recipient, payload and attributes use the plain mode's
  encoding. The transmitter consumes the guard-staged authorization and sends in the same
  source transaction, wrapping the exact calldata with Safe context, signatures and any
  nested approval evidence. The standalone message has no Merkle root, leaf or proof.
- **D2.** The owner Safe can register any `bytes32` root. The transmitter caches its signed
  registration and nested approval evidence for later relays. Registration needs no leaf data.
  Track cache presence independently of the root value so a zero root can also be registered.
  Registering an existing root reverts with `RootAlreadyRegistered(bytes32 root)`.
- **D3.** The signed Safe `to` must equal the receiver's configured source transmitter.
- **D4.** A locked receiver deployment uses fixed, distinct standalone and Merkle envelope
  formats. The receiver checks the signed selector for the path being executed.
- **D5.** Anyone can call `relayLeaf` with a registered root, one execution leaf and its
  proof. Each leaf commits to its provider attributes, including any LayerZero execution
  options. The transmitter verifies membership and the route, then quotes and sends one
  message using those attributes, with the cached Safe authorization, root, leaf and proof.
  The relayer pays the full provider fee from `msg.value` and receives any excess.
  A successful relay preserves the transmitter's pre-call native balance.
  The receiver reconstructs the signed root registration, verifies the Safe quorum and
  proof, and checks that the decoded leaf names this chain and receiver before executing it.

Only the signed target can consume the guard's staged record, once. The guard clears it in
the Safe post-hook. A batch of standalone sends uses separately signed, top-level Safe
executions. A signed MultiSend or module call does not stage its inner calls.

Trees and leaves:

- **D6.** One registered root can cover multiple destinations and multiple local nonces on
  the same receiver. Each `relayLeaf` call sends one leaf to one destination. A leaf can
  contain an ordered batch of calls that executes atomically on that destination.
- **D7.** The transmitter tracks used state by the full leaf hash, including attributes,
  across all roots. It marks the hash before calling the provider and rolls it back if
  the send reverts. The Safe can register a new root with changed attributes for the same
  batch. The new leaf can be sent independently of the first delivery's outcome, which
  the transmitter does not track. Direct execution writes only receiver state.
- **D8.** Each Merkle leaf commits to its receiver's local nonce. The Safe nonce stays in the
  signed transaction context. A standalone send has the same application payload as the
  plain path and uses the Safe digest as its replay identity.

Verification and replay:

- **D9.** Every dispatch verifies before changing state, including a commit-only message.
  For each format, provider delivery and direct submission share the verifier and replay
  state. Provider delivery also requires an enabled gateway and authenticated origin and
  sender matching the configured source chain and transmitter. Direct submission uses
  the signed Safe domain and target without provider metadata. In signed mode, a bare
  call from the local address matching `sourceTransmitter` grants no authority to
  `execute`, `commit`, `cancel`, or `revokeGateway`. Protected self-calls must run
  within verified signed execution, including signed bootstrap setup, or through
  `finalize` of a commitment established by signed authorization. Existing
  function-specific checks still apply.
- **D10.** Each receiver starts Merkle execution at `nextNonce = 0` and requires `leaf.localNonce == nextNonce` for a
  new execution. It records the execution ID, which excludes delivery attributes, and
  advances before external calls. It rejects overflow and rolls both writes back if
  execution reverts.
- **D11.** After authenticating the root and full leaf, a receiver that already executed
  the same execution ID returns silently without an event, calls or nonce advance. This
  applies across direct and provider delivery, roots and attribute changes. A different
  execution ID at a consumed nonce reverts. Standalone duplicates retain
  `DuplicateMessage()`.
- **D12.** A replacement leaf at the current nonce may carry revised calls or an empty batch.
  If the original leaf is still valid, either may consume the nonce first.
- **D13.** A verified standalone signed message or Merkle leaf can self-call
  `commit(bytes32)`, `cancel(bytes32)`, or `revokeGateway(address)` with the same
  effects as in plain mode. Verify Safe authorization before executing any of these
  calls. A commit-only leaf consumes its nonce when the commitment is recorded.
  `finalize` consumes the commitment later without touching the nonce. A revoked
  gateway cannot deliver provider messages. Direct submission remains available.
- **D14.** A new Merkle execution requires `validAfter <= deadline` and
  `validAfter <= block.timestamp <= deadline` on destination time, inclusive. An invalid
  window consumes nothing. An authenticated repeat of an executed batch succeeds silently
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
- **D18.** #108 fixes authority at the receiver. Source owner and threshold changes remain
  possible, and the transmitter accepts sends and root registrations authorized by the
  live Safe. A delivery that fails the receiver's stored quorum reverts without consuming
  receiver state. The provider can retain it for retry where supported. #109 delivers
  authority changes separately so a still-valid pending message can execute after the
  receiver applies the update.
- **D19.** Standalone sends and Merkle leaves can execute directly at the destination.
  A direct Merkle submission supplies the signed root registration, leaf and proof. The
  receiver authenticates it locally using the same rules as a provider delivery. Direct
  execution requires neither a source registration receipt nor a source used record.
- **D20.** One transmitter and one receiver implementation per provider support both modes.
  At creation, the transceiver discovers the owner's installed transaction guard and probes
  `supportsInterface(type(ICrossecuteGuard).interfaceId)`. An affirmative response selects
  signed mode. An absent guard, unsupported interface or failed discovery selects plain mode.
  The deployment records its mode. A signed transmitter still consumes a fresh staged record
  from the current compatible guard on every signed owner operation and reverts if that record
  is unavailable. Installing or removing a guard later does not change an existing conduit.
- **D21.** The destination transceiver uses `BOOTSTRAP` or `SIGNED_BOOTSTRAP` to select
  the bootstrap checks. The mode-specific conduit salt binds that choice to the source
  transmitter and receiver addresses (Q4.7). The receiver persists the verified mode before
  executing setup calls. A receiver in signed mode requires signed authorization for every
  dispatch.
- **D22.** A valid Safe quorum authorizes signed bootstrap at the destination within its
  signed window. Destination verification requires the complete authorization and configured
  provider delivery. It requires no proof of source execution or of source guard approval.
  Receiver creation and setup are atomic.
- **D23.** The Safe is responsible for choosing provider execution attributes appropriate
  to each leaf. The transmitter verifies and uses the approved attributes and records
  provider acceptance. Only the receiver records execution. #108 adds no separate
  signed minimum-gas field or receiver gas-floor check (O7).

## Conflicts to resolve first

- **C1. Duplicate acknowledgment after an authority change.** A duplicate still requires
  the receiver's applied authority. #109 owns duplicate and retry behavior across applied
  updates.
- **C2. #109 fields in the bootstrap snapshot.** #109 owns the fields and rules for
  later authority changes, including per-Safe counters.
- **C3.** Deferred to #109. Specify how standalone sends and cached approvals bind the
  source authority counter once rotations are supported.
- **C4. One tree cannot span providers.** D3 binds the signed `to` to one transmitter. Each
  provider has its own transceiver and so its own transmitter and conduit address. Receivers of
  a LayerZero conduit and a CCIP conduit cannot share a signed Safe transaction. *Proposed:*
  state the limit; accepting a set of transmitters is a larger change.
- **C5. Source-side policy does not gate destination effects.** Accepted. Under D19 and
  D22, valid Safe authorization is sufficient for destination execution even if the source
  transaction has yet to execute. Source guard policy and delays apply to source execution.
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
- **Q1.8** The leaf supplies the exact attributes for both quote and send. The relayer
  funds the full fee in that call. Record `balanceBefore = address(this).balance - msg.value`
  at entry. Require `msg.value >= fee` and send only the quoted fee to the provider. Where the
  adapter takes a provider refund address, use the relayer. Refund `msg.value - fee` and
  any synchronous provider refund returned to the transmitter to the relayer. Require
  `address(this).balance == balanceBefore` after settlement. Protect settlement against reentrancy. A failed refund or balance mismatch
  reverts the relay, including the used mark. Direct submission proves membership using
  the full leaf and executes without applying its provider attributes.
- **Q1.9** *Open:* measure cache writes and provider envelope costs, including nested evidence,
  and define bounds. Leaf data, proofs and attributes are variable length because the
  number of calls, tree depth and provider options vary.
- **Q1.10** A repeat `registerRoot` reverts with `RootAlreadyRegistered(root)`, including
  when the Safe signs it at a new nonce. The original approval and used-leaf records
  stay intact. New leaf attributes require a new root.

### Q2. Leaf and tree encoding

What fields and byte encoding define an execution leaf? How does it commit to the ordered
calls with the existing EVM `Call[]` codec, and how are leaves and internal nodes hashed? Specify proof ordering and the single-leaf tree.

Frame the leaf with
`abi.encode(destination, localNonce, validAfter, deadline, callPayload, attributes)`.
The leaf hash is the double Keccak-256 of those bytes. The execution ID is the double
Keccak-256 of the same fields through `callPayload`. Double hashing means hashing the
32-byte digest again. The destination and call payload are `bytes`, the nonce and timestamps
are `uint256`, and the attributes are `bytes[]`. An empty attribute array adds 64 ABI bytes
for the offset and length. Each entry adds an offset, a length and its padded bytes.
EVM call payloads retain `abi.encode(Call[])`. Internal nodes hash sorted sibling pairs.
Carry an unpaired hash to the next level unchanged.

Cases:

- **Q2.1** #109 owns authority counter binding for root registration. Reapproving identical
  fields preserves both hashes. Changing only the attributes changes the leaf hash and
  preserves the execution ID.
- **Q2.2** An empty replacement leaf carries the normal encoding of an empty `Call[]`.
- **Q2.3** The leaf hash includes the exact encoded call payload bytes. A call to `commit`
  still takes the existing commitment hash for the batch to be finalized later.
- **Q2.4** The destination is ERC-7930 bytes: `Erc7930.parseStrict`, eip155 only, a 20-byte
  address. The full destination bytes are included in the leaf encoding.
- **Q2.5** The signed `registerRoot` selector identifies Merkle execution. #109 owns
  separation of management authorizations. A locked receiver uses its deployed format.
- **Q2.6** Double hashing keeps a 64-byte internal node from decoding as a leaf.
- **Q2.7** Sorted pairs carry no index; duplicate leaves are harmless.
- **Q2.8** A single-leaf tree has the leaf node as its root and an empty proof.
- **Q2.9** Proof verification has no separate length cap (Q7).
- **Q2.10** D13 preserves `commit`, `cancel`, and `revokeGateway` self-calls after
  authorization. A self-call to #109's update entry point would combine update and
  execute and must be blocked. The dispatch entry points use the reentrancy lock.
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
- **Q3.4** For #108, bootstrap carries the fixed creation authority records. Authority
  counters for later changes are #109 scope.
- **Q3.5** Reject invalid thresholds, zero and sentinel owners, duplicate owners, duplicate
  or unreachable records, and inconsistent owner kinds.
- **Q3.6** Classify empty code and the EIP-7702 delegation indicator as EOA. For other
  owner addresses, require valid Safe owner and threshold data.
- **Q3.7** Hash the canonical creation records as
  `graphHash = keccak256(abi.encode(authorityRecords))`. Include `graphHash` in the outer
  signed conduit salt preimage in Q4.7.
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

Signed bootstrap uses the configured authenticated provider path and the full authorization
for `bootstrap(bytes,bytes[])`. The bootstrap leaf commits to the receiver, execution window
and exact setup calls. It omits the execution nonce. The provider can deliver a valid
authorization before source execution (D22).

- **Q4.1** For #108, use the creation authority commitment and registered source
  deployment inputs to verify the signed source transmitter address. Q4.7 covers
  how the receiver binds the source mode into bootstrap and address derivation.
- **Q4.2** The EIP-155 source chain ID in the Safe domain must match the authenticated
  origin and source chain key.
- **Q4.3** The signed envelope carries
  `(SIGNED_BOOTSTRAP, owner, userSalt, sourceTransmitter, body)`, with
  `body = abi.encode(SignedBootstrap)` using a single struct with the `SignedDelivery`
  followed by the canonical creation authority records. The transmitter retains the original
  `userSalt` and records from creation and forwards them automatically. The signed Safe
  bootstrap call needs no separate salt or graph argument. The destination validates the
  records, including that the root Safe is `owner`, and recomputes `graphHash` from them.
  It verifies the source and destination bindings, Safe quorum, leaf proof and execution
  window before setup. It stores the records and starts the Merkle nonce at zero.
  #109 covers rotations.
- **Q4.4** PR #117 stages only the top-level `sendMessage` selector today. Before signed
  bootstrap can use `consume`, the guard must also stage the bootstrap selector for
  owner transactions and reject it in the installed module guard.
- **Q4.5** An initialized receiver can accept direct ordinary dispatch before the source
  receives a readiness report. An authenticated repeat of the same bootstrap leaf within
  its window succeeds silently.
- **Q4.6** Bootstrap carries no historical authority updates. Initialized receivers apply
  later updates in sequence under #109.
- **Q4.7** The envelope kind selects one of these outer CREATE2 salt preimages.

  ```solidity
  plainSalt = keccak256(abi.encode(owner, userSalt, homeChainKey));
  signedSalt = keccak256(abi.encode(owner, userSalt, homeChainKey, graphHash));
  ```

  The fourth field separates the two preimages. The envelope needs no additional mode
  tag or graph hash field. Use the authenticated home chain key and the registered source
  transceiver and deployment inputs to derive the expected source transmitter. Check it
  against the envelope before initialization. Signed mode requires a derivable source.
  Derive the receiver with the same mode-specific salt and the destination's deployment
  inputs, and require the signed bootstrap leaf to name that receiver. Both modes use the
  shared implementation. Plain address predictions retain the existing formula when the
  deployer and initcode are unchanged.
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

For a source send or root registration, collect evidence using live source Safe authority.
The receiver applies its own stored quorum on delivery. Look up the child's current
transaction guard with `GuardDiscovery`, then `getApproval(child, messageHash)`. The current guard returns `ICrossecuteGuard.SignedSafeTx`
with the full approval calldata and the child's signatures with its policy extension removed.
Wrap it in a `NestedApproval` keyed by child Safe and message hash. Carry one item per key
in an unsorted flat array and look it up by linear scan.

Cases:

- **Q6.1** For an empty nested signature, the child Safe must have a Crossecute guard installed
  with the matching cached signed approval. If its current guard cannot supply the evidence,
  revert during source evidence collection, before paying the provider. An approval cached on
  a previous guard stays there. The child can reapprove on its current Crossecute guard or
  provide an inline signature. Anyone with complete signed evidence can still submit directly
  to the receiver for independent verification.
- **Q6.2** The child Safe approves by calling `signMessage(bytes)` with
  `abi.encode(parentDataHash)`. Its guard computes the child-domain Safe message digest
  from those bytes and caches the signed approval under the child Safe and that digest.
  The transmitter derives the same digest and passes it to `getApproval(childSafe, childMessageHash)`.
- **Q6.3** Follow Safe's digest at each nested verification step. For an inline child
  signature, recurse with the child's Safe message digest. For a cached child approval,
  recurse into the approval's signatures with the child Safe transaction digest. Use that
  transaction digest as the input to Q6.2 for any empty nested signature in the approval.
- **Q6.4** Reject `v = 1` in every signature entry used for authorization, including entries
  in cached approvals. Validate this during source evidence collection, before registering
  a root or paying the provider. The receiver also rejects these entries, since the original
  caller and source Safe's approved-hash state cannot be verified from the signed bundle.
- **Q6.5** The receiver rebuilds the child transaction hash with `operation = DELEGATECALL` and
  the child domain, verifies its signatures under the current child node, checks the
  `signMessage(bytes)` selector and exact decoded message `abi.encode(parentHash)`. The
  signed target is part of the digest. There is no signing-library allowlist.
- **Q6.6** Missing required evidence reverts. The receiver ignores unused approval records.
  An approval can contribute to quorum only when an empty nested signature requires its
  exact child Safe and message digest and the approval verifies.
- **Q6.7** Use one approval record per `(childSafe, messageHash)`. If multiple
  verification paths reach the same child Safe and message hash, reuse that record.
  Different message hashes for the same child Safe require separate records.
- **Q6.8** Reapproval replaces the guard's record for the same child Safe and message hash
  for future lookups. A provider bundle already sent and a root registration already cached
  retain the evidence they captured. A direct submitter can attach replacement evidence to
  the original signed dispatch if it matches the same child Safe and digest and meets the
  receiver's stored quorum.
- **Q6.9** Direct submission can use a fully signed child approval before that transaction
  executes on the source chain. The receiver verifies the exact approval calldata and
  signatures against its stored authority. A submitter can obtain evidence from
  `getApproval`, the signed child transaction (including confirmations from the Safe
  Transaction Service), or a prior provider payload.
- **Q6.10** Size the full encoded provider payload, including the signed authorization,
  any leaf and proof, and the nested evidence with its lookup keys and array framing.
  Quote and send with the same encoded bytes, destination and provider attributes. Pay
  the provider the fee returned by the quote for that send. The [guard measurements](https://github.com/crossecute/protocol/blob/6be68a278b6594390c0be67a9671d54c8e2f443d/docs/safe-approval-evidence-sizing.md)
  cover guard return data.

### Q7. Resource limits

Which limits come from the provider or chain, and what should be measured?

Cases:

- **Q7.1** The receiver adds no resource caps on gas, owner counts, graph depth, proof
  length, call batch size, signature blobs or nested evidence. Normal chain execution
  limits apply.
- **Q7.2** At `createTransmitter` and receiver bootstrap, use the same authority graph
  validity rules so a signed transmitter cannot commit to an invalid graph.
- **Q7.3** The provider enforces its payload size limit. Quote and send the full encoded
  payload under Q6.10.
- **Q7.4** The transmitter adds no payload size cap, including for standalone sends (O3).
- **Q7.5** Measurements needed before choosing numbers: gas per signature entry, per nested
  level and per evidence item; memory expansion for large blobs; bootstrap storage gas against
  owners and nodes; receiver code size against EIP-170; each provider's maximum message size
  and destination gas cap per route (not yet verified).

### Q8. Permissionless bundle availability

What does proposal tooling export so an independent submitter can obtain the signed Safe
transaction, signatures, leaves and proofs, and nested evidence? How does that work before
source execution and when the provider is unavailable?

Cases:

- **Q8.1** Export an off-chain bundle with a schema version, all Safe transaction fields,
  the Safe address and home chain ID, signatures, and recursive approval evidence. For Merkle
  dispatch, include the root, each receiver's Merkle nonce at build time, and the full leaf
  data, including calls and attributes, with proofs or the ordered tree data needed to
  reconstruct them. A versioned package generates the Merkle leaves and root using the
  protocol's encoding and hashing rules. D4 applies to the on-chain payload.
- **Q8.2** Before source execution, signatures exist only with signers or in the Safe
  Transaction Service. A partial set is useless until it meets the receiver's thresholds.
- **Q8.3** The transmitter caches the original Safe transaction, signatures and nested
  evidence by root. `relayLeaf` reads the cached authorization. The cache itself does not
  contain the tree's leaf data.
- **Q8.4** Publish every leaf's full encoded fields, including calls and attributes, with its proof, or publish the
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

- **O1.** Resolved in D9. Signed receivers derive execution authority from verified
  Safe authorization, including previously approved commitments. Equality with the
  source transmitter address grants no authority to a bare destination call.
- **O2.** Resolved in D9. Signed provider delivery retains the existing gateway, origin
  and sender checks and always routes to the signed verifier.
- **O3.** Standalone send fee drain. Whoever executes a fully signed Safe transaction
  controls the bytes after the threshold entries (#117). LayerZero and CCIP price the
  byte-exact parent blob. The provider enforces its payload cap (Q7.3). Permissionless
  `relayLeaf` is caller-funded.
- **O4.** Quote and send parity is resolved in Q6.10.
- **O5.** `MessageSent` reports the signed recipient for a standalone send and the leaf
  destination for `relayLeaf`. Root registration creates no provider message.
- **O6.** One reentrancy lock covers `receiveMessage`, direct submission, `finalize`, `execute`
  and #109's update entry point. A leaf calling `finalize` reverts; document it.
- **O7.** Resolved in D23. `Executor` reverts the batch if a top-level call fails. A
  target that handles an internal failure and returns successfully is treated as a
  successful call. Signers account for that behavior when reviewing calls and sizing
  provider execution gas.
- **O8.** Deadlines must cover provider latency (OP Stack L2 to L1 waits out the challenge
  period). The window does not bound `finalize` of a commitment. Anyone chooses the execution
  moment within the window, so narrow windows limit MEV on parameter changes.
- **O9.** Resolved in D18. Source owner changes remain allowed. Receivers continue using
  their creation graph until an authority update is supported and applied under #109.
- **O10.** #109 owns applying parent and child authority changes before retrying pending
  messages, including the counter and validity rules for that retry.
- **O11.** No atomicity across destinations: a two-chain upgrade can stay half applied.
- **O12.** EVM destinations only in the first release. No leaf can target the home chain.
- **O13.** Receiver code size: the verifier, codec and Merkle code likely exceed EIP-170 and
  need an extension or libraries, fixed with the receiver.
- **O14.** The receiver deduplicates, so the exactly-once transport requirement
  ([P7](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist),
  [R3.5](provider-spec.md#r3-receive)) can be relaxed for signed mode. Check each provider's retry path for
  failed deliveries; the CCIP ordering preflight is
  [#118](https://github.com/crossecute/protocol/issues/118).
- **O15.** Direct submission: nonpayable, or treat value as a top-up.

## Receiver check order

The proposed sequence for standalone and Merkle delivery. "Retryable" means the same bytes can succeed
later; "permanent" means a replacement leaf or new signatures are needed.

| # | Check | On failure |
| --- | --- | --- |
| R1 | Entry: enabled gateway with the configured source chain and transmitter, or direct submission | revert |
| R2 | Reentrancy lock | revert |
| R3 | Rebuild the Safe digest from exact calldata and check the expected signed selector | revert, permanent |
| R4 | Decode the signed standalone recipient and payload, or the registered root and supplied leaf | revert, permanent |
| R5 | Destination is (`block.chainid`, `address(this)`) | revert, permanent |
| R6 | Merkle only: verify the leaf proof against the root in signed registration calldata | revert, permanent |
| R8 | Authority counter checks are deferred to #109 | |
| R9 | Verify signatures and nested evidence | revert, permanent |
| R10 | Standalone digest or Merkle execution ID at the nonce already executed | succeed silently for Merkle, emit `DuplicateMessage()` for standalone |
| R11 | Merkle only: nonce already used by a different execution ID | revert, conflicting batch, permanent |
| R12 | Merkle only: require the next nonce and check the signed execution window | revert |
| R15 | Record the standalone digest or Merkle execution ID. For a new batch, increment `nextNonce`, rejecting overflow | revert, permanent |
| R16 | Execute the calls atomically; an empty batch is allowed | revert undoes R15, retryable |

A nonce below `nextNonce` always has a record, because nonces advance only through execution,
so R10 to R12 cover every case and a lower nonce with no record is an invariant failure.

## Transmitter send and relay order

| # | Check |
| --- | --- |
| T1 | Only the owner Safe may call `sendMessage` or `registerRoot`. Anyone may call `relayLeaf` |
| T2 | For either Safe call, consume the staged guard record and restore `safeTx.data` from `msg.data` |
| T3 | For `sendMessage`, validate the normal recipient and payload, and wrap the signed authorization |
| T4 | For `registerRoot`, reject an existing root with `RootAlreadyRegistered(root)`; otherwise cache the signed authorization and evidence |
| T5 | For `relayLeaf`, require a cached registration, verify the proof, require an unused leaf hash, and validate the destination route |
| T6 | Validate the signature and evidence format before paying for provider relay |
| T7 | Build the Merkle wire message from the cache, root, leaf and proof |
| T8 | Quote using the final wire message, destination and verified leaf attributes. Use those same inputs for send and require the quoted fee from this call's `msg.value` |
| T9 | Mark the leaf hash used, send, refund excess to the relayer, and assert the transmitter's final native balance equals its pre-call balance |

## Tests

#108's acceptance criteria list the required tests. These cases follow from the items above
and are not in them yet:

- the transceiver selects signed mode for a compatible installed guard and plain mode
  for an absent or incompatible guard. Both modes use the same implementation.
  Installing or removing the guard later does not flip mode or allow a signed
  transmitter to send without fresh staged authorization;
- standalone signed sends use the plain recipient and application payload, execute once
  across both delivery routes, and never read the root cache;
- after a source owner change, a live-quorum standalone send or root registration succeeds
  on the source. A delivery that fails the stored receiver quorum leaves its execution
  record and nonce unchanged. Applying the update and retrying belong to #109;
- only the owner can register a root. Anyone can relay two leaves from the same root in two
  calls using the cached authorization;
- a second registration at a new Safe nonce reverts with `RootAlreadyRegistered(root)`
  and preserves the approval and used marks. Cover a registered zero root as well;
- source relay and destination execution each reject altered calls or a proof from another
  root. A standalone authorization cannot serve as root approval or vice versa;
- altering only the attributes invalidates the proof. Quote and send use the exact verified
  attributes, and underpayment reverts even when the transmitter is funded;
- exact payment and overpayment preserve a prefunded transmitter's native balance.
  Overpayment and any synchronous provider fee refund go to the relayer. A rejected
  refund or balance mismatch reverts both the provider send and source used mark;
- new attributes under a newly approved root allow another relay. If the first batch
  succeeded, the second delivery is silent. If it failed, the new delivery can execute it;
- failed provider sends roll back the source mark. Successful sends reject another relay
  of the same leaf. Destination failure leaves the receiver unmarked, and a retry succeeds
  once without another source send;
- direct Merkle execution leaves the source unused. A later `relayLeaf` marks it used on
  the transmitter and delivers successfully, with no destination event, calls or nonce
  advance, including after the deadline;
- a forged or invalid proof still rejects after the leaf has already executed;
- a valid signed bundle delivered through an enabled gateway with the wrong origin or
  sender reverts without writing receiver state. The same bundle can execute through
  direct submission;
- bare calls to `execute`, `commit`, `cancel`, and `revokeGateway` from the matching local
  transmitter address revert and leave receiver state unchanged. Verified signed execution
  and finalization of a signed commitment retain their existing effects;
- a signed DELEGATECALL dispatch rejects (Q1.1);
- replay through the same Safe and transmitter addresses on another chain (Q4.2);
- non-canonical calldata and ERC-7930 encodings (Q1.4, Q2.4);
- `v = 1` executor signatures in the parent blob and in cached evidence (Q5.3, Q6.4);
- signature blob padding by the Safe executor and its fee effect (O3);
- a forged bootstrap with the correct graph and a wrong transmitter or home (Q4.1, Q4.2);
- a plain bootstrap naming a signed transmitter arrives first, fails before setup, and leaves
  the signed receiver address available for the genuine bootstrap;
- a threshold-signed bootstrap initializes the intended receiver through the provider before
  the Safe transaction executes on the source. Altered authority records, receiver address,
  or setup calls fail, and reverting setup rolls back receiver creation;
- verified standalone messages and Merkle leaves self-call `commit`, `cancel`, and
  `revokeGateway` through provider and direct delivery. Invalid signatures leave
  commitments and gateway roles unchanged. Anyone can finalize an outstanding commitment
  under the existing rules. A revoked gateway fails delivery even with valid signatures,
  and the same authorization can still be submitted directly;
- leaves calling #109's update entry point and `finalize` (Q2.10, O6);
- a provider accepts a relay whose destination call later runs out of gas. The source
  used mark persists, the destination execution ID and nonce roll back, and an authorized
  retry can execute the batch once;
- a tree spanning two providers' conduits rejects (C4);
- for large blobs, quote and send use identical encoded payloads, destinations and attributes,
  and the provider receives the quoted fee (Q6.10);
- a duplicate submitted after a parent rotation and after a child rotation (C1).
