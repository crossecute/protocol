# Safe-signed dispatch design

Design for [#108](https://github.com/crossecute/protocol/issues/108). The
related work is tracked in [#109](https://github.com/crossecute/protocol/issues/109)
and the source guard in [#107](https://github.com/crossecute/protocol/issues/107).

These are design requirements and open questions. Implementation and runtime
verification are tracked in the issues.

## Scope

Define the versioned dispatch envelope and a leaf binding the destination chain, conduit, nonce, timing, and exact ordered calls. Use the normal queued Safe transaction as the signed envelope. Specify which bytes the Safe signs, how the transmitter receives leaves and proofs without a hosted service, and how a receiver reconstructs the exact Safe transaction hash. If the Safe signs full calldata, account for sending its preimage to the receiver. A Merkle proof alone does not reconstruct arbitrary Safe calldata.

## Owner and nested-Safe composition

Also design the owner/Safe composition transmitted to receivers and stored there to verify future messages. The deployment commitment alone does not give the receiver the owners, nested structure or thresholds needed to check signatures. Nested Safe ownership is required in the first signature-enabled release, not a later extension.

- Define a versioned composition format describing the root Safe, every supported nested Safe, each Safe's immediate owner addresses and threshold, and the references connecting those groups. Preserve nested thresholds: a satisfied child Safe counts as one owner of its parent, not as several flattened EOA owners. Specify source-chain identity and the Safe version/handler/signing rules needed for recursive validation.
- Specify canonical encoding and traversal for the owner and threshold commitments. The current design direction uses separate owner and threshold hashes over the same composition, combined into the initial signer-policy commitment used for deployment. Bind thresholds to their owner groups and make nesting boundaries unambiguous. Decide whether owner kind is explicit or inferred from node references; missing nested records must not silently turn a contract owner into an EOA. Final byte layout and traversal order remain to be specified.
- Carry the full initial composition, original creation salt and initial policy commitment in receiver bootstrap. Recompute the commitment and verify its binding to the intended signed conduit address and implementation before accepting authority or executing bootstrap calls. An untrusted bridge must not choose a different starting signer composition, including through a plain-conduit deployment path.
- Define receiver storage for the normalized owner/Safe composition and thresholds used for subsequent messages, plus the initial policy commitment and current authority version/commitment. Specify node indexing, nested references, lookup rules, storage costs and bounded initialization. Storing only an opaque hash does not provide the requested stored composition; explain any additional witness data required by the verification algorithm.
- Use the stored composition to verify complete Safe signature bundles recursively, including contract-signature headers, offsets, lengths and dynamic nested signature payloads. Reconstruct the correct signed message/domain at every supported Safe level. Distinguish EOA signing modes from nested contract-signature validation; source acceptance alone is not destination authority.
- Validate node completeness, duplicate/conflicting node declarations, duplicate owners within a group, threshold ranges, reference consistency, cycles, shared children and depth/size limits. Define whether multiple parent references share one canonical child record and how the verifier avoids counting invalid or repeated authorizations.
- Specify bootstrap payload size, storage and verification gas as owner count and nesting grow, and apply explicit bounds. Transmitter and receiver must agree on one shared codec and commitment calculation. Bind the initial policy to the address while keeping current policy updates separate from the initial commitment.

A compromised bridge or relayer must not be able to forge an executable message or an authority update. Both provider delivery and direct submission must verify against the same independently anchored authority. Coordinate owner/threshold updates, nested changes and receiver storage transitions with [issue #109](https://github.com/crossecute/protocol/issues/109); #108 owns composition, bootstrap storage and dispatch verification, while #109 owns the authenticated change protocol and update guards.

## Agreed receiver identity and nonce-only replay protection

One receiver is bound to one parent Safe and source chain. At most one transaction may execute on that receiver for each parent Safe transaction nonce. Store a local `minimumNonce` and require the supplied parent nonce N >= minimumNonce; do not store an execution-data hash for replay protection and do not key replay by a hash of nonce plus calldata. Different quorum-signed transactions at the same parent nonce must not both execute.

The caller supplies the parent nonce as part of the complete signed transaction context. Reconstruct the Safe digest and verify signatures against that nonce; the nonce is not recoverable from signature bytes alone. Provider delivery and permissionless direct submission share the same verifier and minimumNonce. Set minimumNonce = N + 1 before external effects and roll back on atomic execution failure. Gaps are allowed because unrelated source transactions need not reach the receiver; after accepting a higher nonce, all lower nonces reject. This is the receiver-local minimum, not the source Safe live nonce. Initialize minimumNonce to zero at receiver bootstrap and reject overflow. This supersedes the earlier used-nonce mapping decision. Authority-transition validity remains a separate check.

Quorum-authorized transactions may execute independently at destination without source execution or bridge delivery. Anyone supplying complete valid evidence may submit them, subject to the remaining verification and execution checks. Child approval evidence is retained indefinitely on the shared source guard, with no pruning or deletion on use; its retention is separate from receiver replay state. The selected nested approval route uses complete signed direct approval transactions as supplemental evidence for empty nested payloads, excluding child policy extensions while retaining the parent's full original signature blob. Exact proof encoding remains open. Verify ordinary nested approvals against the current receiver-stored child composition. No light clients are permitted.

## Authority-change counter coordination with #109

Ordinary quorum-signed Merkle trees commit to an incremental authority-change counter, covering threshold and owner changes. Verify source counter consistency and require exact equality with the receiver's local counter; reject mismatches. This counter is distinct from the parent Safe transaction nonce used for execution replay protection.

Issue #109 owns the update-first transition: current owners authorize and record an exact update before the separate source mutation, which must cross-check the guard record. Receiver verification uses pre-change authority and may advance before source execution. Accept one successor per counter, with no duplicates, replacements or overrides; enforce first accepted onchain under the assumption that the first quorum-approved proposal is the one executed. Nested approvals use current receiver-stored composition as specified below; receivers use the authority they have applied. A removed signer can count until the signed removal is applied, subject to the signed execution window.

## Nested authorization

The receiver counts a nested Safe as one owner when that child meets its own
threshold. For ordinary dispatch, verify direct and cached child approval
signatures against the child's currently applied receiver composition. Only
inspect children whose authorizations contribute to the parent's quorum.
An unused child's authority change leaves the parent's counter and other
owners' ability to reach quorum intact. An earlier signature can still count
if it satisfies the current composition.

For an empty contract-signature payload, verify the complete child approval
transaction digest and its owner signatures, then confirm that the signed
transaction directly delegatecalls a supported signing library to approve
the exact message expected by the parent handler. Keep that evidence separate
from the original parent signature blob. Preserve nested offsets and omit
the child's policy extension. Source approval storage alone cannot authorize
receiver execution. The verifier must reject recursive `v = 1` entries.

The receiver uses the authority it has applied when the dispatch executes.
See [#109](https://github.com/crossecute/protocol/issues/109) for sequential,
permissionless authority updates and the separate update function.

## Agreed signed execution window

Each Merkle execution leaf commits to `validAfter` and `deadline` alongside the authorized execution and parent nonce. The complete tree/root is bound by owner signatures. The receiver requires validAfter <= deadline and validAfter <= block.timestamp <= deadline using destination block time, inclusively. Reject early, expired, inverted or altered windows without consuming nonce state. Keep authority-update and dispatch-execution functions separate; no combined update-and-execute function.

Add vectors for accepted endpoint timestamps, just-before/after rejection, changed signed window data, inverted ranges, gaps and lower nonce rejection after a higher accepted nonce, shared direct/provider replay state, reentrancy and retry after atomic failure. Format widths and final encoding remain to be specified; account for added bytes in fee/payload sizing.

## Open format and integration questions

- Define canonical owner traversal, explicit owner kinds or safe inference,
  domain-separated salt, normalized graph storage and authenticated bootstrap.
- Specify the parent preimage, exact Merkle leaf and proof formats, timestamp
  widths and bounds, replay overflow handling and the supported Safe 1.5
  fallback handler rules.
- Define recursive signature parsing, EOA ordering, dynamic-offset and extension
  boundaries, and policy evidence requirements if destination policy checks
  are introduced.
- Specify child evidence format, lookup keys, discovery across guard deployments
  and recursion and payload limits. Measure quote/send parity and provider fees.

## Acceptance criteria

- The transmitter consumes the guard-staged Safe context and sends a destination bundle through the existing transport. Document per-destination fee and payload sizing, and how the proposal and proof data are made available for direct submission.
- The receiver accepts a provider delivery or a direct submission through one shared verifier. Recompute the home Safe digest, verify EOA and nested Safe signatures against the receiver-stored authority composition with thresholds/domains preserved, verify the Merkle proof and calls, and enforce destination, expiry, and replay rules. Reject unsupported home-state-dependent approvals. Support empty nested Safe payloads only with independently verified signed direct-approval evidence; specify its exact format. Support direct EOA signatures (`v = 27/28`) and Ethereum-prefixed signatures (`v = 31/32`), including mixed sets. Reject `v = 1` recursively.
- Both delivery routes share the parent-nonce replay state above. Advance minimumNonce to N + 1 before external calls and roll back on atomic execution failure. Pin genesis authority independently of provider-supplied bootstrap data.
- Document discovery from existing Safe API and public home publication, an exportable bundle, and which failures are retryable. Keep optional relay incentives out of the MVP and record them as follow-up scope.
- Add shared builder and Solidity vectors and an end-to-end test showing that a user can deliver while the provider is unavailable. Cover altered calls, wrong destination, invalid signatures, conflicting quorum-signed transactions at the same parent nonce, reentrancy, duplicates across routes, and retry after atomic execution failure.

- Deliver shared composition/commitment vectors and receiver-storage readback tests for EOA-only, mixed EOA/nested, multilevel and shared-child structures. Cover malformed/missing nodes, duplicate/conflicting records, invalid thresholds, cycles, depth/size limits, truncated or overlapping dynamic signatures and mismatched initial commitments.
- Add an end-to-end nested-Safe dispatch test through both delivery routes using the same stored composition. A malicious provider cannot substitute genesis owners, alter nested thresholds, redirect a message or forge execution. Link authority-update and nested-only owner-change tests to #109 without accepting bridge assertions as authority.

Start with a fixed signer policy that includes nested Safes. Rotation, generalized management leaves and ownership-change transaction guards are tracked in [#109](https://github.com/crossecute/protocol/issues/109).

Prior work: [signed dispatch design](https://github.com/crossecute/protocol-v2/pull/2) and [permissionless relay](https://github.com/crossecute/protocol-v2/issues/1).
