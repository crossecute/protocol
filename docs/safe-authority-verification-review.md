# Authority implementation and verification plan

This file owns concrete implementation gates and acceptance coverage for the
[#109 design](safe-authority-updates.md). It is not an independent policy spec.
[Review findings](planning/safe-authority-review-109.md) track security questions;
[baseline vectors](vectors/safe-authority-updates-109.json) and
[benchmarks](benchmarks/authority-109/README.md) have separate purposes.

## Scaffold coverage and remaining work

| Area | Present in draft | Required before production |
| --- | --- | --- |
| Types/interfaces | The design's encodings: AuthoritySelection, AuthorityUpdate (previousUpdateHash, newAuthorityHash), AuthorityNode/AuthorityGraph/AuthorityEntry, ChildUpdate; guard activate(authorityHash), registerOwnershipChange(update), selectAuthority(update), stageUpdate(sourceSafe, newGraph, childUpdates, portableSignatures, nestedApprovals), executed; receiver submitAuthority(evidence, newGraph, childUpdates), selection, graph, record. | Freeze the ABI once the hooks are implemented. No migration from #108 fixed authority: nothing is deployed. |
| Receiver authority | The linked ReceiverAuthority library over ERC-7201 receiver storage, driven by ReceiverAuthorityTemplate: one seed from the bootstrap's head and selected graph (root first at position zero, canonical, nonzero descendant positions), then submitAuthority for successors only, with activations rejected; the predecessor head check (which also rejects replays, as heads never repeat), graph hash check and atomic per-record and graph writes. Graph authentication: #108's canonical acyclic check plus the 16-owner cap, the root record per update kind (applyMutations or unchanged), and one flat pass over child updates with a table of proven (Safe, position) records seeded from the stored graph, rejecting unused and repeated child updates and child activations; a Safe absent from the stored graph is taken as named. Each update's votes pass one check over Safe 1.5.0 signature blobs: #108's signature walk (SafeQuorum, shared with SafeAuthority), resolving nested Safe voters through the table under the positions that update's new graph names. | Implement source-call recognition against the pinned guard and MultiSendCallOnly; seed and wire actual receivers. |
| Source guard | Two-function fail-closed abstract template. | Implement activation (live-state, configuration and owner-activation checks), native caller/guard configuration validation, stageUpdate staging under the per-Safe nesting lock, head tracking, and recognition of the one-SafeTx ownership batch. Record every executed head per Safe, require named descendant positions to be executed heads at or after the stored ones and added Safes' records to be theirs there, and verify and emit a separately supplied portable set. Expose selection for the transmitter's bootstrap check. No production function is enabled by this draft. |
| Mutation encoding | ownershipBatchData packs the guard's registerOwnershipChange(update) call and then zero-value supported self-CALLs into MultiSendCallOnly calldata; decodeOwnershipBatch inverts it and accepts only data that re-encodes exactly. AuthorityMutations.applyMutations derives every intermediate owner list in Safe 1.5.0 order, checks predecessor/sentinel, threshold and the 16-owner cap at each step, and requires the result to equal the expected record; added owners take their kind from it. A differential fuzz test checks each step against a real Safe 1.5.0. The receiver authority library calls it for root and child ownership changes. | Call applyMutations from the guard pre-hook; enforce both guard slots and bypass matrix. |
| Transport | Source-safe/source-chain identity and signed source call; no destination fields or numeric nonce watermark. | relayAuthority/quote/direct adapters, authenticated duplicate response, publication and durable evidence availability. |
| Initial authority | ReceiverAuthority.seed stores the bootstrap's head and selected graph once. | The signed bootstrap carries the guard's current selection head and the selected graph, checked against the guard's selection hash by the transmitter and seeded into the receiver; signed bootstrap reverts before activation. |
| Caches | Each record stored once under its hash and each graph as its entry list; graph(hash) and record(hash) read them back. | Authenticated descendant checkpoint API, graph publication/recovery, and dispatch verification reading the selected graph in place of #108's stored records. |
| Execution isolation | Submission lock and abstract idle-context requirement. | Shared execution lock/lease across every provider and callback, including bootstrap/finalize integration. |
| Commitments | D92 lifetime specified; existing implementation untouched. | Explicit repeat/cancel/consume accounting and integration regression tests. No authority-based invalidation. |
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
| T4 | X -> Y -> X then replay an accepted old update. | The predecessor check rejects: a returned graph does not return the old head. A duplicate of the current head also rejects. Scaffold test. |
| T5 | Competing signed successors of one head. | First branch wins locally; second cannot overwrite. Scaffold test. No universal/source-finality claim. |
| T6 | Proposed new owners sign their own installation. | Stored-record check rejects. Receiver tests with real Safe signature blobs over SafeTx hashes: a one-EOA root, and a new Safe owner of a root voting its own installation. |
| T7 | Altered graph, wrong source chain, wrong guard/selector, malformed signature. | Reject without partial changes. Scaffold covers graph/source-chain binding, root placement and strict ownership-batch decoding (wrong guard, trailing bytes, no mutation); expand real verifier cases. |
| T8 | Shared context busy during application work. | Management blocked across provider paths. Scaffold tests required hook; actual multi-provider locking remains integration work. |
| T9 | Repeat seeding, or an activation submitted as an update or child update. | Reject without resetting authority or replay state. Scaffold tests. |
| T10 | Ordered ownership batch vs external target/value/configuration selector. | Exact MultiSendCallOnly encoding; reject disallowed calls. Scaffold encoding tests. |
| T11 | Ownership-change SafeTx whose batch lacks the guard call or the mutations, a mutation failure, a post-state mismatch, or a plain execTransaction with nothing staged. | The whole SafeTx reverts with its nonce; no staged state survives. Must test the actual guard. |
| T12 | Batch changes threshold halfway through its mutations. | One pre-batch source quorum, final graph checked; preserve intermediate native Safe constraints. Derivation covered by unit tests and the real-Safe differential fuzz; the guard's single quorum check needs the actual guard. |
| T13 | B rotates/raises threshold but A does not update. | A's selected B snapshot persists; D94/D96 operational responsibility, no implicit update. Nested #109 end-to-end: after B rotates, A's selectAuthority carrying B's child updates is required before A dispatches under B's new owners. |
| T14 | B's own receivers advance. | A's embedded B snapshot unchanged; each of A's receivers holds its own copy. |
| T15 | Root changes graph after commitment acceptance; removed actor finalizes first. | D92 accepted work remains executable; explicit cancel can lose a timing race (Y9). |
| T16 | Shared child (A -> B -> C, A -> C) and a cyclic graph (A -> B -> C -> B), on source and destination. | Shared child enumerated once with individual thresholds/message domains; the cyclic graph rejects on both sides. An owner added with no code and later deployed as a Safe stays EOA-kind and its contract signature does not count. Actual verifier work remains. |
| T17 | Malformed offsets, repeated signers, wrong child hash, v=1, delegated EOA contract signature. | Portable verification rejects before source execution or destination writes. The shared walk's cases are in SafeAuthority.t.sol. Through submitAuthority: a repeated signer, a short blob, an EOA-kind owner's contract signature, and a missing or duplicated nested approval. Not yet on source. |
| T18 | 16 versus 17 immediate owners, 80 aggregate entries, deep/large finite proof. | Enforce only immediate-owner cap; VM/provider resource failures remain atomic. The cap at each mutation step has a unit test; the stored-graph cap remains. |
| T19 | New destination after rotations; a retired compromised creation-owner key competes. | The new receiver starts from its bootstrap's head and selected graph, so the retired key can neither seed it nor capture it first; later successors of that head follow first-accepted (T5). |
| T20 | Cache loss, checkpoint reuse, missing child update or interrupted catch-up batch. | Never invent authority; validated checkpoints can anchor proofs, missing data fails cleanly. Recovery/publication API remains work. |
| T21 | Same-Safe nested execution or callback attempts to overwrite staged update. | Invocation-scoped staging/lock rejects; no transient/persistent contamination. Review X10. |
| T22 | All existing application, cancel/finalize and duplicate flows after graph changes. | Preserve conduit identity, exact-message approvals and replay consumption; unsupported management-as-application path rejects. |
| T23 | A moves B forward by one child update and by several in one update; an update names B behind or off the stored position. | Forward accepts with B's record equal to the result of the signed mutations; anything else rejects without writes. |
| T24 | Adoption of B's rotation X to Y signed by Y for B; same adoption signed by X for B; new root owners sign their own installation. | Y counts, X does not, and the root case still rejects (T6). An update that keeps B's position counts B's stored owners only. AuthorityGraphPass.t.sol. |
| T25 | B goes X, Y, X; the first X-to-Y link is replayed against the second X. | Reject: the link names an earlier position. |
| T26 | A's adoption names a B update that B signed and never executed on source. | Source guard rejects. A destination accepts it if A's quorum signed; documented trust in A's signers. |
| T27 | A's adoption names executed position p+1; B executes p+2 before A executes. | Source accepts. A stays one position behind and a later adoption of p+2 is voted by B's live owners. |
| T28 | B votes on A's update through X, rotates to Y, then A reaches quorum. | Source executes with Y's live signatures; the guard verifies and emits the X set; destinations accept the same evidence. Without the X set, source rejects. |
| T29 | B's own receiver on a destination sits on an abandoned branch. | A's adoption of B's executed position still verifies; B's receiver is not read. Scaffold test. |
| T30 | A adds Safe D: D activated at the named position; D never activated; D at zero position or with an invalid record; D removed, then re-added at an earlier executed position. | A destination takes D as named; zero positions and invalid records reject. Source rejects a D whose named position is not executed or whose record is not D's there. Re-adding at an earlier executed position accepts. |
| T31 | B's update needed a vote from B's Safe owner C at position q; A holds C at q, or at a later position. | At q: accept, C counts under q. Later: reject, since positions are proven only forward from A's stored ones; B signs a fresh update, or A removes and re-adds B. |

## Validation boundaries

The receiver authority tests use a fixture for the abstract hooks: recognition against
placeholder guard and MultiSend addresses, a fixed source identity, and a seed entry
point standing in for the bootstrap. Votes are the template's own check, and
the tests sign Safe 1.5.0 signature blobs: ECDSA entries, inline nested signatures to
depth two and a signed approval behind an empty one. AuthorityGraphPass.t.sol covers
T23 to T25 and T29 to T31 through submitAuthority; T26 to T28 and T30's source rule wait
for the guard. They do not test source-call
recognition against the real guard, source execution pairing or live providers. No
empty/default-success production verification hooks exist. The source template always reverts for mutating
operations and remains abstract.

Authority code under src/messaging/authority compiles via-IR through a path
restriction in contracts/evm/foundry.toml, because its nested types exceed the legacy
code generator's stack limit. The default profile stays legacy: via-IR changes
Proxy's initcode. Files that import the authority code compile via-IR too. After a
change that adds such an importer, compare the bytecode of untouched contracts from
a clean build.

The offline vector generator checks existing Safe hash/signature bytes plus labels
for semantic cases. It is not a Solidity acceptance runner and does not freeze the
future child-update ABI. Historical 43-case gas/wire benchmarks remain unchanged
measurements of the existing verifier. They do not price receiver authority updates
or source batch execution. Run relevant source/receiver integration, both lint profiles, formatting,
size/selector checks and real Safe 1.5.0 fixtures before enabling any deployment.
