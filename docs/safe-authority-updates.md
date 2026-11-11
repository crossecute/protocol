# Safe authority update design

Design for [#109](https://github.com/crossecute/protocol/issues/109). The
related work is tracked in [#108](https://github.com/crossecute/protocol/issues/108)
and the source guard in [#107](https://github.com/crossecute/protocol/issues/107).

These are design requirements and open questions. Implementation and runtime
verification are tracked in the issues.

## Required security and first-release support

A bridge or relayer must not be able to forge an executable message or an authority update. Receiver acceptance must depend on independently authenticated signer authority, exact signed content and replay protection, not a bridge assertion that the source Safe accepted something. Protect the initial authority commitment as well as subsequent updates. This requirement applies to EOA-only and nested-Safe ownership alike.

Nested Safe owners are required in the first signature-enabled release, not an EOA-only release followed by deferred nested support. Preserve nested thresholds and complete contract-signature data; flattening all nested EOA keys into one list does not preserve authorization. The standalone transient-storage MVP in #107 still does not claim destination verification.

## Scope

Design ownership and authority changes in general: owner addition, removal and replacement; signer/key rotation; threshold and signer-policy changes; and authenticated updates to destination receivers. Cover direct Safe owner changes, changes inside nested Safe owners, and DAO or other home-contract authority changes. Nested-Safe guards are a required part of this broader work, not the whole issue.

Extend the Merkle authorization format to support both execution leaves and typed signer-management leaves. Define the separate signer policy tree that represents keys and nested thresholds, and how its commitment becomes the authority for subsequent dispatches. A management proof must never be accepted as an execution proof or vice versa.

## Ownership-change transaction guards, including nested Safes

Design transaction-guard hooks that construct authenticated signer-management messages when a Safe changes the authority that receivers use, analogous to the crossecute Safe guard in #107 and PR #112. This includes ordinary changes to the source Safe's own owners/threshold and changes inside nested Safe owners. A change inside nested Safe B does not invoke parent Safe A's guard, so nested support must observe B directly and identify all receiver authority records affected by B. Other home-contract authority mechanisms need their own authenticated update path under the same rotation protocol.

- Specify installation on source and participating nested Safes, shared versus separate guard composition, policy compatibility, configuration and migration. This is an additional authority-update hook path, not an implicit change to #107's agreed selector-only sendMessage signature staging.
- Capture the original signed transaction and complete nested signature encoding in the pre-hook, together with the prior authority commitment/epoch. Use the agreed update-first sequence below. Receiver authorization depends on the pre-change quorum-signed update tree, not proof that the later source mutation executed. A failed source mutation rolls back its active-counter change.
- Define coverage for owner addition/removal/replacement, threshold changes and changes to contract-signature validation behavior. Analyze batches, delegatecalls, approved-hash/state-dependent authorization, guard replacement/removal and module-driven changes. Production targets Safe 1.5.0 with both guard slots installed. Modules may make configured external calls. Block module Safe self-calls and delegatecalls, and protect guard and module policy configuration.
- Define the typed update message, signature/proof witness and receiver verification algorithm. The receiver must independently verify authorization under the previously trusted applicable authority policy and verify how that authorized mutation yields the next commitment. A guard-emitted event, observed post-state or bridge certificate is not by itself sufficient authority.
- Bind updates to the changing Safe and source chain, prior and next commitments, counters, predecessor and replay domain. Specify destination scope for parent-specific updates. Use the reusable child-update domain below for shared children. Cover multiple nesting levels, cycles and bounded depth/size.
- Specify construction, publication, transport and retries separately. Determine whether the hook emits a relayable signed bundle or calls transport directly, who pays, and what happens on publication/delivery failure. Do not presume a guard can create a new owner signature over a message the owners never signed. New owners do not self-authorize their installation.

## Agreed update-first sequence and change counter

1. Current owners authorize an authority-update Merkle tree before source ownership changes. Bind the current change counter n, next counter n + 1, exact source mutation calldata, resulting authority and applicable domains/identities.
2. The first source transaction records the pending update on the shared guard. A separate later source transaction changes ownership/threshold only if its actual mutation matches the recorded update. Pending authorization is separate from active authority; advance the transmitter counter with the actual source change and roll back on failure.
3. The receiver independently verifies the update against its stored pre-change authority at n, applies the new authority and advances to n + 1. It may do so before the source change executes. This timing difference is accepted; the operating assumption is that the later source change executes once the first transaction reaches quorum. Source execution and bridge delivery are not prerequisites for destination authorization. No light clients.
4. Ordinary signed Merkle trees carry the change counter; receiver execution requires exact equality with its current local counter. Revert on mismatch. A child change updates its own node/counter in each affected receiver without advancing parent counters; preserve nested thresholds.
5. Accept one update per current counter, with no duplicates, replacements or overrides. Contracts enforce first accepted onchain. They cannot establish when an offchain proposal first reached quorum; the explicit operating assumption is that the first quorum-approved proposal is the one executed. Do not claim this rule resolves different chains accepting conflicting quorum-signed proposals.

Support exact authority mutations through direct, separately signed Safe self-calls. Multiple consecutive-nonce owner transactions may share one parent blockchain transaction. A mutation inside a single signed MultiSend is outside the supported path. Enforce source configuration requirements that prevent modules, delegatecalls and other paths from bypassing these checks.

## Selected address identity

Conduit identity commits to the initial signer policy; authenticated rotations keep addresses stable. The exact domain-separated salt formula and canonical composition encoding remain open. Preserve receiver bootstrap binding to the initial commitment and replay continuity through authority changes.

## Agreed per-Safe counters and current-composition nested verification

The shared guard stores a change counter for each Safe using it. Each transmitter stores only its parent Safe's counter. A counter versions that Safe's own authority; a child-only threshold or owner change does not advance ancestor counters. Receivers keep per-node counters for ordering authenticated authority updates. Ordinary parent execution does not require a signed snapshot of every child counter.

Verify ordinary nested signatures, including supplemental cached direct-approval evidence, against the child's current receiver-stored owner composition and threshold. No separate child-counter signature is required. Earlier evidence can remain valid if its signatures satisfy the current composition; indefinite storage does not guarantee perpetual validity. Traverse only children used to satisfy parent quorum. An unused child's change must not block other parent owners from reaching quorum. Example: A at 2/3 with owners B/C/D remains executable with C+D after B changes; B+C must satisfy current B authority.

Authority updates themselves retain pre-change authorization and sequential per-Safe counters. Define authenticated child-node update publication to every affected receiver, including shared children and multiple nesting levels, without incrementing ancestor counters. Initialize authority counters at zero with authenticated genesis. Late receivers catch up sequentially. Each receiver uses the authority it has applied until it applies the next signed update. A removed signer may still count before application, subject to the signed execution window. Tests must cover child changes with alternate parent quorum, required-child current quorum, threshold increases/decreases, removed owners, retained valid signatures, recursive cached approvals and per-node update ordering.

## Agreed reusable child-authority updates

One update authorized by B's pre-change quorum may be submitted by anyone to every receiver that already stores B as an authenticated authority node. Bind B's source-chain identity, prior authority commitment/counter, next counter, exact mutation and resulting authority. Parent signatures are not required and parent counters remain unchanged. Each receiver independently verifies its existing B record and sequential transition; intentional reuse across receivers must not permit repeated application within a receiver. An update cannot introduce B into a parent graph or mutate unrelated nodes. Specify the reusable cross-receiver authorization domain separately from destination-bound dispatch leaves.

Test one B update delivered by arbitrary callers to two receivers with different parent Safes, no additional parent signatures, unchanged parent counters, duplicate rejection, prior-counter/authority mismatch, wrong source identity, missing child and attempted unrelated-node mutation. Publication and discovery must support permissionless direct delivery without bridge dependence. Detailed encoding remains open.

## Agreed sequential catch-up verification

Receivers must verify every consecutive authority transition. A receiver storing B at counter 3 must verify 3 -> 4 -> 5 -> 6, each under the authority resulting from the preceding step. No skipped counters or jump directly to a latest-owner composition is permitted. Anyone may submit multiple consecutive updates in one receiver transaction, but every intermediate signature, prior commitment and counter check still applies. This is receiver update batching, not support for approval extraction from a signed source MultiSend.

Keep update and execution entry points separate. Test catch-up through changing owners and thresholds, missing/reordered updates, invalid intermediate authorization, duplicate transitions and attempted latest-owner self-authorization. Specify batch bounds and failure/atomicity behavior separately. Preserve existing parent execution replay state through all transitions.

## Open format and enforcement questions

- Specify update leaf encoding, the reusable child authorization domain, pending
  update storage and synchronization with each transmitter's active counter.
- Define the full set of authority mutations, including which guard or handler
  changes count. Specify the source protections for each supported Safe 1.5
  configuration and how to authenticate any newly introduced nested node.
- Specify publication and discovery for late receivers, batch bounds and failure
  behavior for update-only catch-up, plus any recovery or emergency controls.

## Acceptance criteria

- Bind each management leaf to the intended conduit and destination scope, current and next epoch, prior rotation commitment, and full next signer policy commitment. Prove the leaf under a root authorized by the configured rotation authority. Define any stricter rotation quorum at genesis. Validate the new tree, including duplicate keys, invalid thresholds, and depth and size bounds.
- Enforce sequential handoffs, preserve dispatch replay state through rotation, and reject dispatches under a superseded epoch after the handoff lands. Specify late destination bootstrap, update ordering, rejection of conflicting successors without replacement or override, and what bounds the period during which a lagging destination still accepts old keys.
- Specify how Safe owner changes stay aligned with the portable signer policy. If a DAO or other home contract can change the policy without portable signatures, define independently verifiable signed authorization or explicitly reject the path; bridge assertions and light clients are not acceptable substitutes.
- Decide whether to support a separately authorized freeze or unfreeze, and specify any quorum and equivocation evidence rules. Consider the signed execution windows and the period before a receiver applies an authority update.
- Add shared vectors and tests for wrong authority, skipped epochs, conflicting successors, cross-type replay, and delivery of rotations and dispatches out of order.

- Deliver the general ownership-change/rotation protocol and receiver-update specification, with end-to-end cases for an EOA-owner change, a threshold change, and a nested-Safe change. Include the nested guard example where Safe B changes its owners while parent Safe A executes no transaction, then A dispatches under the updated nested authority.
- Add shared vectors for EOA-only and nested-Safe trees, mixed owners, multilevel/shared children, dynamic signature offsets, stale nested configurations, wrong nested/parent identity and threshold changes. Test forged execution and forged authority updates from a malicious bridge, including chosen genesis roots, altered transaction/update payloads, redirected updates, malformed signatures and new-key self-authorized rotations.
- Reconcile #107's signature extraction and shared-guard lifecycle with the full nested signature encoding and this authority protocol. Keep proof-of-source execution, bridge assertions and independent owner-signature verification distinct.

Prior work: [protocol-v2 signed dispatch and rotation design](https://github.com/crossecute/protocol-v2/pull/2) and [permissionless relay and freeze discussion](https://github.com/crossecute/protocol-v2/issues/1).
