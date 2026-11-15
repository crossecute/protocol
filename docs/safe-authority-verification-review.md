# Authority implementation and verification plan

This file owns concrete implementation gates and acceptance coverage for the
[#109 design](safe-authority-updates.md). It is not an independent policy spec.
[Review findings](planning/safe-authority-review-109.md) track security questions;
[baseline vectors](vectors/safe-authority-updates-109.json) and
[benchmarks](benchmarks/authority-109/README.md) have separate purposes.

## Scaffold coverage and remaining work

| Area | Present in draft | Required before production |
| --- | --- | --- |
| Types/interfaces | The design's encodings: AuthoritySelection, AuthorityUpdate (previousUpdateHash, newAuthorityHash), SafeCreationProof, AuthorityNode/AuthorityGraph/AuthorityEntry, ChildUpdate; guard activate(authorityHash, creation), registerOwnershipChange(update), selectAuthority(update), stageUpdate(sourceSafe, newGraph, childUpdates, portableSignatures, nestedApprovals), executed; registry submitAuthority(sourceChainId, sourceSafe, evidence, newGraph, childUpdates), graph, record. | Freeze the ABI once the hooks are implemented. No migration from #108 fixed authority: nothing is deployed. |
| Linked registry state machine | One submitAuthority for activations and updates: activation only while unregistered, predecessor head check otherwise (which also rejects replays, as heads never repeat), root as first node at position zero, graph hash check, atomic per-record and graph writes. The activation SafeTx hash is the first head. | Implement canonical/creation/descendant/signature verification; wire actual receivers. Prove positions in one flat pass over child updates, with a table of proven (Safe, position) records; derive each moved record from its signed mutations; count descendants under named positions and nested voters under the positions their child update's new graph names. |
| Source guard | Two-function fail-closed abstract template. | Implement activation (creation proof, creation-state and owner-activation checks), native caller/guard configuration validation, stageUpdate staging under the per-Safe nesting lock, head tracking, and recognition of the one-SafeTx ownership batch. Record every executed head per Safe, require named descendant positions to be executed heads at or after the stored ones, and verify and emit a separately supplied portable set. No production function is enabled by this draft. |
| Mutation encoding | ownershipBatchData packs the guard's registerOwnershipChange(update) call and then zero-value supported self-CALLs into MultiSendCallOnly calldata; decodeOwnershipBatch inverts it and accepts only data that re-encodes exactly. AuthorityMutations.applyMutations derives every intermediate owner list in Safe 1.5.0 order, checks predecessor/sentinel, threshold and the 16-owner cap at each step, and requires the result to equal the expected record; added owners take their kind from it. A differential fuzz test checks each step against a real Safe 1.5.0. | Call applyMutations from the guard pre-hook and the registry; enforce both guard slots and bypass matrix. |
| Transport | Source-safe/source-chain identity and signed source call; no destination fields or numeric nonce watermark. | relayAuthority/quote/direct adapters, authenticated duplicate response, publication and durable evidence availability. |
| Initial registration | submitAuthority accepts an activation for an unregistered Safe; the creation proof check is part of the abstract graph hook. | Creation proof checks with both salts and the pinned factory, singleton and creation code; late-chain full-chain bootstrap with off-chain archive of update evidence (Y3). |
| Caches | Each record stored once under its hash and each graph as its entry list; graph(hash) and record(hash) read them back. | Authenticated descendant checkpoint API, graph publication/recovery and cache integration with current execution verifier. |
| Execution isolation | Registry submission lock and abstract idle-context requirement. | Shared execution lock/lease across every provider and callback, including bootstrap/finalize integration. |
| Commitments | D92 lifetime specified; existing implementation untouched. | Explicit repeat/cancel/consume accounting and integration regression tests. No authority-based invalidation. |
| Resource behavior | No extra caps; encoding loops operate on supplied data. | Acyclic canonical traversal shared with SafeAuthorityGraph, finite exact-message proof tracking, malformed input/out-of-gas atomicity and actual provider sizing. |

The graph hash is keccak256(abi.encode(keccak256("Crossecute.AuthorityGraph.v1"),
sourceChainId, entries)), where entries holds one AuthorityEntry(recordHash,
position) per node in canonical order; entries[0] commits to the root and recordHash is
keccak256(abi.encode(SafeAuthorityRecord)). The v1 label is kept because no earlier
encoding was deployed. Every update head, the first included, is the SafeTx hash of
the activation, ownership change or selectAuthority transaction, computed with
existing SafeHashes. These are not hashes deployed by #108. Canonicality and
authentication are mandatory before using either hash.

## Acceptance matrix

| ID | Scenario | Expected result / coverage |
| --- | --- | --- |
| T1 | U2 names U1 but arrives first. | Reject without changing the head; ordered U1/U2 succeeds. Scaffold test. |
| T2 | Update signed at uint256 max; next valid linked update has a smaller Safe nonce. | No destination numeric lockout. Scaffold test; source Safe nonce enforcement is a separate domain. |
| T3 | Same evidence on two destination registries. | Identical head/result, independently verified; no destination-specific signature. Scaffold test. |
| T4 | X -> Y -> X then replay an accepted old update. | The predecessor check rejects: a returned graph does not return the old head. A duplicate of the current head also rejects. Scaffold test. |
| T5 | Competing signed successors of one head. | First branch wins locally; second cannot overwrite. Scaffold test. No universal/source-finality claim. |
| T6 | Proposed new owners sign their own installation; an activation signed by keys other than the creation owners. | Current quorum (or creation record) check rejects. Scaffold uses real ECDSA/SafeTx hashing with one-EOA fixture. |
| T7 | Altered graph, wrong source chain, wrong guard/selector, malformed signature. | Reject without partial changes. Scaffold covers graph/source-chain binding, root placement and strict ownership-batch decoding (wrong guard, trailing bytes, no mutation); expand real verifier cases. |
| T8 | Shared context busy during application work. | Management blocked across provider paths. Scaffold tests required hook; actual multi-provider locking remains integration work. |
| T9 | Repeat initialization or a second activation. | Reject without resetting authority or replay state. Scaffold test; activation and creation proof remain hooks. |
| T10 | Ordered ownership batch vs external target/value/configuration selector. | Exact MultiSendCallOnly encoding; reject disallowed calls. Scaffold encoding tests. |
| T11 | Ownership-change SafeTx whose batch lacks the guard call or the mutations, a mutation failure, a post-state mismatch, or a plain execTransaction with nothing staged. | The whole SafeTx reverts with its nonce; no staged state survives. Must test the actual guard. |
| T12 | Batch changes threshold halfway through its mutations. | One pre-batch source quorum, final graph checked; preserve intermediate native Safe constraints. Derivation covered by unit tests and the real-Safe differential fuzz; the guard's single quorum check needs the actual guard. |
| T13 | B rotates/raises threshold but A does not update. | A's selected B snapshot persists; D94/D96 operational responsibility, no implicit update. Nested #109 end-to-end: after B rotates, A's selectAuthority carrying B's child updates is required before A dispatches under B's new owners. |
| T14 | B's own registry entry advances. | A's embedded B snapshot unchanged; shared provider A contexts still agree. |
| T15 | Root changes graph after commitment acceptance; removed actor finalizes first. | D92 accepted work remains executable; explicit cancel can lose a timing race (Y9). |
| T16 | Shared child (A -> B -> C, A -> C) and a cyclic graph (A -> B -> C -> B), on source and destination. | Shared child enumerated once with individual thresholds/message domains; the cyclic graph rejects on both sides. An owner added with no code and later deployed as a Safe stays EOA-kind and its contract signature does not count. Actual verifier work remains. |
| T17 | Malformed offsets, repeated signers, wrong child hash, v=1, delegated EOA contract signature. | Portable verification rejects before source execution or destination writes. |
| T18 | 16 versus 17 immediate owners, 80 aggregate entries, deep/large finite proof. | Enforce only immediate-owner cap; VM/provider resource failures remain atomic. The cap at each mutation step has a unit test; the stored-graph cap remains. |
| T19 | New destination after rotations; a retired compromised creation-owner key competes. | Full linked chain from the activation, no latest-state shortcut; first accepted successor wins and a retired key that submits first captures that destination (documented limitation, Y3). |
| T20 | Cache loss, checkpoint reuse, missing child update or interrupted catch-up batch. | Never invent authority; validated checkpoints can anchor proofs, missing data fails cleanly. Recovery/publication API remains work. |
| T21 | Same-Safe nested execution or callback attempts to overwrite staged update. | Invocation-scoped staging/lock rejects; no transient/persistent contamination. Review X10. |
| T22 | All existing application, cancel/finalize and duplicate flows after graph changes. | Preserve conduit identity, exact-message approvals and replay consumption; unsupported management-as-application path rejects. |
| T23 | A moves B forward by one child update and by several in one update; an update names B behind or off the stored position. | Forward accepts with B's record equal to the result of the signed mutations; anything else rejects without writes. |
| T24 | Adoption of B's rotation X to Y signed by Y for B; same adoption signed by X for B; new root owners sign their own installation. | Y counts, X does not, and the root case still rejects (T6). |
| T25 | B goes X, Y, X; the first X-to-Y link is replayed against the second X. | Reject: the link names an earlier position. |
| T26 | A's adoption names a B update that B signed and never executed on source. | Source guard rejects. A destination accepts it if A's quorum signed; documented trust in A's signers. |
| T27 | A's adoption names executed position p+1; B executes p+2 before A executes. | Source accepts. A stays one position behind and a later adoption of p+2 is voted by B's live owners. |
| T28 | B votes on A's update through X, rotates to Y, then A reaches quorum. | Source executes with Y's live signatures; the guard verifies and emits the X set; destinations accept the same evidence. Without the X set, source rejects. |
| T29 | B's own registry entry on a destination sits on an abandoned branch. | A's adoption of B's executed position still verifies there; B's entry is not read. |
| T30 | A adds Safe D: D activated; D never activated; D changed owners before activating; D added at a position some updates past its activation; D removed, then re-added at an earlier executed position. | An activated D is added from its activation, with child updates when past it. Source rejects a D whose named position is not executed. Activation rejects a Safe no longer at its creation owners and threshold. Re-adding at an earlier executed position accepts. |
| T31 | B's update needed a vote from B's Safe owner C at position q; A already holds C at a later position; A adopts B's update. | Accept: C's vote counts under q, proven in the flat pass from C's activation or an earlier proven position. A retained Safe named at a position reached only from a supplied activation, not from its stored position, rejects. |
| T32 | Creation proofs: plain salt, chain-specific salt, setupToL2 with the pinned L2 singleton, another setup delegatecall, an unpinned factory or singleton. | The first three prove the creation record; the last two reject. |

## Validation boundaries

The scaffold tests use a one-EOA fixture for abstract verification hooks. They test
linked state-machine behavior and genuine SafeTx digest signatures, not production
nested verification, actual Safe creation, source execution pairing or live providers.
No empty/default-success production verification hooks exist. The source template
always reverts for mutating operations and remains abstract. T23 to T32 have no
scaffold coverage: the fixture supports a root with one EOA owner and rejects any
child update.

Authority code under src/messaging/authority compiles via-IR through a path
restriction in contracts/evm/foundry.toml, because its nested types exceed the legacy
code generator's stack limit. The default profile stays legacy: via-IR changes
Proxy's initcode. Files that import the authority code compile via-IR too. After a
change that adds such an importer, compare the bytecode of untouched contracts from
a clean build.

The offline vector generator checks existing Safe hash/signature bytes plus labels
for semantic cases. It is not a Solidity acceptance runner and does not freeze the
future child-update ABI. Historical 43-case gas/wire benchmarks remain unchanged
measurements of the existing verifier. They do not price linked registry/source batch
execution. Run relevant source/receiver integration, both lint profiles, formatting,
size/selector checks and real Safe 1.5.0 fixtures before enabling any deployment.
