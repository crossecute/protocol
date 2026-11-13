# Authority implementation and verification plan

This file owns concrete implementation gates and acceptance coverage for the
[#109 design](safe-authority-updates.md). It is not an independent policy spec.
[Review findings](planning/safe-authority-review-109.md) track security questions;
[baseline vectors](vectors/safe-authority-updates-109.json) and
[benchmarks](benchmarks/authority-109/README.md) have separate purposes.

## Scaffold coverage and remaining work

| Area | Present in draft | Required before production |
| --- | --- | --- |
| Types/interfaces | AuthoritySelection/AuthorityUpdate, graph wrapper, source guard and shared registry interfaces; reuse existing Call/owner/evidence types. | Freeze selector/witness ABI and migration from baseline fixed-authority fields. |
| Linked registry state machine | Hash predecessor checks, current-graph hook, exact receipts, atomic graph/head/cache writes, zero sentinel and deterministic draft genesis head. | Implement independent canonical/genesis/descendant/signature verification hooks; wire actual receivers. |
| Source guard | Two-function fail-closed abstract template. | Implement native caller/guard configuration validation, portable signature staging, head tracking, exact next batch and invocation-scoped completion. No production function is enabled by this draft. |
| Mutation encoding | Pack zero-value supported self-CALLs into MultiSendCallOnly calldata, including a one-element batch. | Derive/validate actual Safe intermediate and final ordered authority; enforce both guard slots and bypass matrix. |
| Transport | Source-safe/source-chain identity and signed source call; no destination fields or numeric nonce watermark. | relayAuthority/quote/direct adapters, authenticated duplicate response, publication and durable evidence availability. |
| Initial registration | Internal initialization building block with mandatory abstract genesis hook; not a public bootstrap API. | Factory/initializer witness ABI, module/singleton/handler checks and late-chain lineage/branch procedure (Y3). |
| Caches | Template stores full encoded graph by content hash. | Authenticated descendant checkpoint API, graph publication/recovery and cache integration with current execution verifier. |
| Execution isolation | Registry submission lock and abstract idle-context requirement. | Shared execution lock/lease across every provider and callback, including bootstrap/finalize integration. |
| Commitments | D92 lifetime specified; existing implementation untouched. | Explicit repeat/cancel/consume accounting and integration regression tests. No authority-based invalidation. |
| Resource behavior | No extra caps; encoding loops operate on supplied data. | Terminating cycle enumeration, finite exact-message proof tracking, malformed input/out-of-gas atomicity and actual provider sizing. |

The template graph hash is keccak256(abi.encode(keccak256("Crossecute.AuthorityGraph.v1"),
sourceChainId, graph)). Its genesis head uses the analogous AuthorityGenesis.v1
label, source chain, Safe and initial graph hash. These are draft executable encoding
choices, not hashes deployed by #108. Canonicality/authentication is mandatory before
using either hash. Every update head after genesis is the source registration or
selectAuthority SafeTx hash, computed with existing SafeHashes.

## Acceptance matrix

| ID | Scenario | Expected result / coverage |
| --- | --- | --- |
| T1 | U2 names U1 but arrives first. | Reject without changing head/receipts; ordered U1/U2 succeeds. Scaffold test. |
| T2 | Update signed at uint256 max; next valid linked update has a smaller Safe nonce. | No destination numeric lockout. Scaffold test; source Safe nonce enforcement is a separate domain. |
| T3 | Same evidence on two destination registries. | Identical head/result, independently verified; no destination-specific signature. Scaffold test. |
| T4 | X -> Y -> X then replay an accepted old update. | Exact receipt rejects; returned graph does not return old head. Scaffold test. |
| T5 | Competing signed successors of one head. | First branch wins locally; second cannot overwrite. Scaffold test. No universal/source-finality claim. |
| T6 | Proposed new owners sign their own installation. | Current quorum check rejects. Scaffold uses real ECDSA/SafeTx hashing with one-EOA fixture. |
| T7 | Altered graph, wrong source chain, wrong guard/selector, malformed signature. | Reject without partial changes. Scaffold covers graph/source-chain binding; expand real verifier cases. |
| T8 | Shared context busy during application work. | Management blocked across provider paths. Scaffold tests required hook; actual multi-provider locking remains integration work. |
| T9 | Repeat initialization. | Reject without resetting authority or replay state. Scaffold test; actual creation proof remains a hook. |
| T10 | Ordered ownership batch vs external target/value/configuration selector. | Exact MultiSendCallOnly encoding; reject disallowed calls. Scaffold encoding tests. |
| T11 | Source registration-only batch or mutation failure/post-state mismatch. | Whole pair reverts, no persistent pending lock. Must test actual enforcing executor/guard. |
| T12 | Batch changes threshold halfway; nonce m+1 executes all mutations. | One pre-batch source quorum, final graph checked; preserve intermediate native Safe constraints. Real Safe test required. |
| T13 | B rotates/raises threshold but A does not update. | A's selected B snapshot persists; D94/D96 operational responsibility, no implicit update. |
| T14 | B's own registry entry advances. | A's embedded B snapshot unchanged; shared provider A contexts still agree. |
| T15 | Root changes graph after commitment acceptance; removed actor finalizes first. | D92 accepted work remains executable; explicit cancel can lose a timing race (Y9). |
| T16 | Shared child, A -> B -> C -> B and finite nested Safe proofs. | Enumerate identities once; retain individual thresholds/message domains; no unresolved circular approval premise. Actual verifier work remains. |
| T17 | Malformed offsets, repeated signers, wrong child hash, v=1, delegated EOA contract signature. | Portable verification rejects before source pending state or destination writes. |
| T18 | 16 versus 17 immediate owners, 80 aggregate entries, deep/large finite proof. | Enforce only immediate-owner cap; VM/provider resource failures remain atomic. |
| T19 | New destination after rotations; retired compromised genesis key competes. | Follow explicit genesis/lineage procedure and document competing-branch limitation; Y3 remains open. |
| T20 | Cache loss, checkpoint reuse, missing transition witness or interrupted catch-up batch. | Never invent authority; validated checkpoints can anchor proofs, missing data fails cleanly. Recovery/publication API remains work. |
| T21 | Same-Safe nested execution or callback attempts to overwrite staged update. | Invocation-scoped staging/lock rejects; no transient/persistent contamination. Review X10. |
| T22 | All existing application, cancel/finalize and duplicate flows after graph changes. | Preserve conduit identity, exact-message approvals and replay consumption; unsupported management-as-application path rejects. |

## Validation boundaries

The scaffold tests use a one-EOA fixture for abstract verification hooks. They test
linked state-machine behavior and genuine SafeTx digest signatures, not production
nested verification, actual Safe creation, source execution pairing or live providers.
No empty/default-success production verification hooks exist. The source template
always reverts for mutating operations and remains abstract.

The offline vector generator checks existing Safe hash/signature bytes plus labels
for semantic cases. It is not a Solidity acceptance runner and does not freeze the
future child-witness ABI. Historical 43-case gas/wire benchmarks remain unchanged
measurements of the existing verifier. They do not price linked registry/source batch
execution. Run relevant source/receiver integration, both lint profiles, formatting,
size/selector checks and real Safe 1.5.0 fixtures before enabling any deployment.
