# Authority implementation and verification plan

This file owns concrete implementation gates and acceptance coverage for the
[#109 design](safe-authority-updates.md). It is not an independent policy spec.
[Review findings](planning/safe-authority-review-109.md) track security questions;
[baseline vectors](vectors/safe-authority-updates-109.json) and
[benchmarks](benchmarks/authority-109/README.md) have separate purposes.

## Implementation coverage and remaining work

| Area | Present in draft | Required before production |
| --- | --- | --- |
| Types/interfaces | The design's encodings: AuthoritySelection, AuthorityUpdate (previousUpdateHash, newAuthorityHash), AuthorityNode/AuthorityGraph/AuthorityEntry, ChildUpdate; guard activate(authorityHash), registerOwnershipChange(update), selectAuthority(update), stageUpdate(sourceSafe, newGraph, childUpdates, portableSignatures, nestedApprovals), executed; receiver submitAuthority(evidence, newGraph, childUpdates), submitAuthorityBatch(bytes[]), selection, graph, record. | Freeze the final ABI after the checkpoint/recovery surface is settled. No migration from #108 fixed authority: nothing is deployed. |
| Receiver authority | SignedReceiver uses ReceiverAuthorityTemplate and the linked ReceiverAuthority library over ERC-7201 storage: one seed from the bootstrap's head and selected graph (root first at position zero, canonical, nonzero descendant positions), then submitAuthority for successors only, with activations rejected. AuthorityRecognition recognizes root and child source calls against constructor pins. Predecessor and graph hash checks precede atomic record and graph writes. Authentication checks canonical acyclic structure, the 16-owner cap, the root record per update kind and a flat pass over child updates from proven (Safe, position) records. Unused, repeated and activation child updates reject; an added Safe is taken as named. SafeQuorum checks root and child votes under the positions each update names. | Live provider validation and durable evidence/checkpoint tooling. Atomic direct catch-up batches are implemented. |
| Source guard | `SourceAuthorityGuard`, inherited by CrossecuteGuard: a `ReceiverAuthority` state and executed-head record per Safe, `selection` and `executed`, `stageUpdate` into transient storage under the per-Safe nesting lock (X10), activation (both guard slots, pinned singleton and handler, no module, live owners and threshold, executed named positions: X11), ownership changes and selectAuthority verified in the pre-hook with the receivers' library and checked against the Safe's final owners in the post-hook, the portable set emitted, the protected-call rules, and constructor pins (X13). Runtime 22,129 bytes of 24,576. | Automatic activation remains unadopted. Add SDK multicall tooling. Deploy with the pins on each chain. Review the protected-call rules against every Safe 1.5.0 owner-changing path before enabling. |
| Mutation encoding | ownershipBatchData packs the guard's registerOwnershipChange(update) call and then zero-value supported self-CALLs into MultiSendCallOnly calldata; decodeOwnershipBatch inverts it and accepts only data that re-encodes exactly. AuthorityMutations.applyMutations derives every intermediate owner list in Safe 1.5.0 order, checks predecessor/sentinel, threshold and the 16-owner cap at each step, and requires the result to equal the expected record; added owners take their kind from it. A differential fuzz test checks each step against a real Safe 1.5.0. The receiver authority library calls it for root and child ownership changes. SourceAuthority.t.sol covers a threshold change before later mutations under one pre-batch quorum, and fault-injects a post-state mismatch to check rollback of owners, nonce, head and publication. | Live source validation. |
| Transport | relayAuthority and quoteAuthority share exact publication checks, route validation and wire construction. Guard publication commits to the verified portable submission and emits its full bytes. Provider and direct submission share verification and replay state. Only the exact current accepted submission gets a provider no-op acknowledgment; a head match alone grants nothing. Caller-funded relay accounting, refunds and locking are shared with leaf relay. | Live provider validation and durable evidence archives. |
| Initial authority | Signed bootstrap carries the source guard, current selection head, encoded selected graph and setup calls. Quote and send check the same guard selection; an unactivated Safe cannot bootstrap. The receiver checks its immutable guard pin and seeds once before setup. | Verify configured pins and bootstrap contents on each deployment. |
| Caches | Each record is stored once under its hash and each graph as its entry list; receiver graph(hash)/record(hash) and source graph(sourceSafe, hash) provide authenticated readback. Source tests retain old graphs without selecting them and preserve the parent's old child snapshot after that child rotates. Fresh dispatch verification reads only the selected graph. | Authenticated descendant checkpoint API and graph publication/recovery. |
| Execution isolation | Authority submission, signed initialization, direct and provider message/leaf execution, and finalize use ReceiverBase's shared nonReentrant lock. Reentry tests cover all these application routes against authority submission. | Live provider/callback validation. |
| Commitments | Root-rotation tests preserve repeat approvals, permissionless finalization, explicit cancellation and consumption; accepted work has no authority-based invalidation. Real-Safe nested adoption additionally preserves two approvals, permissionless consumption and explicit cancellation. | Live-provider validation. |
| Resource behavior | No extra caps; encoding loops operate on supplied data. | Acyclic canonical traversal shared with SafeAuthorityGraph, finite exact-message proof tracking, malformed input/out-of-gas atomicity and actual provider sizing. |

The graph hash is keccak256(abi.encode(keccak256("Crossecute.AuthorityGraph.v1"),
sourceChainId, entries)), where entries holds one AuthorityEntry(recordHash,
position) per node in canonical order; entries[0] commits to the root and recordHash is
keccak256(abi.encode(SafeAuthorityRecord)). The v1 label is kept because no earlier
encoding was deployed. Every update head, the first included, is the SafeTx hash of
the activation, ownership change or selectAuthority transaction, computed with
existing SafeHashes; a receiver's first head is the one its bootstrap carries. These are
not hashes deployed by #108. Canonicality and
authentication are mandatory before using either hash.

## Acceptance matrix

| ID | Scenario | Expected result / coverage |
| --- | --- | --- |
| T1 | U2 names U1 but arrives first. | Reject without changing the head; ordered U1/U2 succeeds. Scaffold test. |
| T2 | Update signed at uint256 max; next valid linked update has a smaller Safe nonce. | No destination numeric lockout. Scaffold test; source Safe nonce enforcement is a separate domain. |
| T3 | Same evidence on two receivers. | Identical head/result, independently verified; no destination-specific signature. Scaffold test. |
| T4 | X -> Y -> X then replay an accepted old update. | The predecessor check rejects: a returned graph does not return the old head. Direct duplicates reject. A provider retry of the exact current accepted submission is acknowledged; changed evidence and older submissions reject. SignedReceiver tests. |
| T5 | Competing signed successors of one head. | First branch wins locally; second cannot overwrite. Scaffold test. No universal/source-finality claim. |
| T6 | Proposed new owners sign their own installation. | Stored-record check rejects. Receiver tests with real Safe signature blobs over SafeTx hashes: a one-EOA root, and a new Safe owner of a root voting its own installation. |
| T7 | Altered graph, wrong source chain, wrong guard/selector, malformed signature. | Reject without partial changes. SignedReceiver.t.sol runs 14 faults through direct, provider and batch entry points against a stored 2-of-3 quorum: wrong helper/embedded guard/selector, nonzero value, wrong operation, wrong source chain/Safe signature domain, altered graph, proposed-owner signatures, repeated signer, short or missing signatures, v=1 and an EOA-kind contract signature. All 42 cases check the expected error, unchanged authority/replay/application state, absent rejected graph/record caches and successful valid provider retry. Scaffold tests separately cover root placement and strict batch decoding. |
| T8 | Shared context busy during application work. | Management blocked across provider paths. Scaffold tests required hook; actual multi-provider locking remains integration work. |
| T9 | Repeat seeding, or an activation submitted as an update or child update. | Reject without resetting authority or replay state. Scaffold tests. |
| T10 | Ordered ownership batch vs external target/value/configuration selector. | Exact MultiSendCallOnly encoding; reject disallowed calls. Scaffold encoding tests. |
| T11 | Ownership-change SafeTx whose batch lacks the guard call or the mutations, a mutation failure, a post-state mismatch, or a plain execTransaction with nothing staged. | The whole SafeTx reverts with its nonce; no staged state survives. Covered on the actual guard (`SourceAuthority.t.sol`): an unstaged execTransaction, a wrong predecessor, a graph that is not the mutation result and a marker call outside a recognized transaction revert, leaving the head and nonce unchanged. A batch without the guard call or mutations does not decode. A post-hook fault-injection test independently checks rollback of owners, nonce, executed head and publication, followed by a successful retry. |
| T12 | Batch changes threshold halfway through its mutations. | One pre-batch source quorum, final graph checked; preserve intermediate native Safe constraints. Derivation covered by unit tests and the real-Safe differential fuzz; SourceAuthority.t.sol raises the threshold mid-batch, then removes and adds an owner under the original pre-batch quorum. |
| T13 | B rotates/raises threshold but A does not update. | A's selected B snapshot persists; D94/D96 operational responsibility, no implicit update. Nested #109 end-to-end: after B rotates, A's selectAuthority carrying B's child updates is required before A dispatches under B's new owners. |
| T14 | B's own receivers advance. | A's embedded B snapshot unchanged; each of A's receivers holds its own copy. |
| T15 | Root changes graph after commitment acceptance; removed actor finalizes first. | D92 accepted work remains executable; explicit cancel can lose a timing race (Y9). |
| T16 | Shared child (A -> B -> C, A -> C) and a cyclic graph (A -> B -> C -> B), on source and destination. | Shared child enumerated once with individual thresholds/message domains; the cyclic graph rejects on both sides. An owner added with no code and later deployed as a Safe stays EOA-kind and its contract signature does not count. Actual verifier work remains. |
| T17 | Malformed offsets, repeated signers, wrong child hash, v=1, delegated EOA contract signature. | Portable verification rejects before source execution or destination writes. The shared walk's cases are in SafeAuthority.t.sol. Through submitAuthority: a repeated signer, a short blob, an EOA-kind owner's contract signature, and a missing or duplicated nested approval. AuthorityDelegatedOwner.t.sol uses a real Prague EIP-7702 delegation: Safe accepts its contract signature, the guard rejects it for an EOA-kind owner, and ECDSA remains valid. The compiler target stays Cancun. On source, a quorum signer outside the stored owners and a nested voter outside its stored position's owners reject (`SourceAuthority*.t.sol`). |
| T18 | 16 versus 17 immediate owners, 80 aggregate entries, deep/large finite proof. | Enforce only immediate-owner cap; VM/provider resource failures remain atomic. The cap at each mutation step has a unit test; the stored-graph cap has a 17-owner rejection test; a canonical 80-owner graph across 17 nodes is accepted. |
| T19 | New destination after rotations; a retired compromised creation-owner key competes. | The new receiver starts from its bootstrap's head and selected graph, so the retired key can neither seed it nor capture it first; later successors of that head follow first-accepted (T5). |
| T20 | Cache loss, checkpoint reuse, missing child update or interrupted catch-up batch. | Never invent authority; validated checkpoints can anchor proofs, missing data fails cleanly. Publication emits full authenticated submissions. Durable archives and checkpoint/recovery APIs remain work. |
| T21 | Same-Safe nested execution or callback attempts to overwrite staged update. | Invocation-scoped staging/lock rejects; no transient/persistent contamination. Review X10. Every owner execution holds a per-Safe lock through its matching post-hook, including ordinary calls. Tests cover nested owner execution and rollback, guarded module reentry, stage overwrite, incorrect or missing post-hook records, sequential cleanup and different-Safe nesting. Ordinary pinned MultiSend calls reject before and after activation; recognized authority batches remain covered by the mutation tests. See #153. |
| T22 | All existing application, cancel/finalize and duplicate flows after graph changes. | Preserve conduit identity, exact-message approvals and replay consumption; unsupported management-as-application path rejects. |
| T23 | A moves B forward by one child update and by several in one update; an update names B behind or off the stored position. | Forward accepts with B's record equal to the result of the signed mutations; anything else rejects without writes. |
| T24 | Adoption of B's rotation X to Y signed by Y for B; same adoption signed by X for B; new root owners sign their own installation. | Y counts, X does not, and the root case still rejects (T6). An update that keeps B's position counts B's stored owners only. AuthorityGraphPass.t.sol. |
| T25 | B goes X, Y, X; the first X-to-Y link is replayed against the second X. | Reject: the link names an earlier position. |
| T26 | A's adoption names a B update that B signed and never executed on source. | Source guard rejects (`SourceAuthorityNested.t.sol`). A destination accepts it if A's quorum signed; documented trust in A's signers. |
| T27 | A's adoption names executed position p+1; B executes p+2 before A executes. | Source accepts (an adoption of an earlier executed position after B moves on is tested). A stays one position behind and a later adoption of p+2 is voted by B's live owners. |
| T28 | B votes on A's update through X, rotates to Y, then A reaches quorum. | Source executes with Y's live signatures; the guard verifies and emits the X set; destinations accept the same evidence. Without the X set, source rejects (`SourceAuthorityNested.t.sol`). |
| T29 | B's own receiver on a destination sits on an abandoned branch. | A's adoption of B's executed position still verifies; B's receiver is not read. Scaffold test. |
| T30 | A adds Safe D: D activated at the named position; D never activated; D at zero position or with an invalid record; D removed, then re-added at an earlier executed position. | A destination takes D as named; zero positions and invalid records reject. Source rejects a D whose named position is not executed or whose record is not D's there (tested at activation; the adding update shares the check). Re-adding at an earlier executed position accepts; SourceAuthorityNested.t.sol covers removal after adoption and re-addition at an older executed head. |
| T31 | B's update needed a vote from B's Safe owner C at position q; A holds C at q, or at a later position. | At q: accept, C counts under q. Later: reject, since positions are proven only forward from A's stored ones; B signs a fresh update, or A removes and re-adds B. |

## Validation boundaries

The receiver authority tests use a fixture for the abstract hooks: recognition against
placeholder guard and MultiSend addresses, a fixed source identity, and a seed entry
point standing in for the bootstrap. Votes are the template's own check, and
the tests sign Safe 1.5.0 signature blobs: ECDSA entries, inline nested signatures to
depth two and a signed approval behind an empty one. AuthorityGraphPass.t.sol covers
T23 to T25 and T29 to T31 through submitAuthority; T26 to T28 and T30's source rule run in
`SourceAuthorityNested.t.sol` against the real guard. They do not test live providers. No
empty/default-success production verification hooks exist. SourceAuthorityGuard implements
the source operations. SignedDispatchIntegration.t.sol covers source activation, EOA
rotation, receiver catch-up and nested child rotation/adoption against real Safes and
provider conduits, including published authority relays, exact retries and direct/provider catch-up. The transport is mocked. Receiver tests additionally cover threshold
updates, replay rejection, old-key rejection and accepted commitment finalization after
rotation. Deployment tests check immutable pins across all six provider receivers.

The EVM project, including authority code, uses its existing legacy compiler pipeline.
Linked library calls bundle request context to stay within the compiler's stack limit.
Bootstrap encodes its graph separately for the same reason. No authority path restriction
changes a deployment helper to via-IR, which would change Proxy initcode and the factory's
address. Clean-build comparisons keep Proxy, ProxyDeployer and transceiver artifacts
unchanged; receiver and authority library changes are expected.

The offline vector generator checks existing Safe hash/signature bytes plus labels
for semantic cases. It is not a Solidity acceptance runner and does not freeze the
future child-update ABI. Historical 43-case gas/wire benchmarks remain unchanged
measurements of the existing verifier. Current source update execution and receiver
measurements are documented in [the current benchmark report](benchmarks/authority-109/updates.md). Run relevant source/receiver integration, both lint profiles, formatting,
size/selector checks and real Safe 1.5.0 fixtures before enabling any deployment.
