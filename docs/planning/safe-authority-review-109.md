# Authority review findings and disposition

Security review register for [#109](../safe-authority-updates.md). This file owns
finding status and unresolved choices, not duplicate design text or implementation
instructions. [Acceptance coverage](../safe-authority-verification-review.md) maps
requirements to tests. The original reviews are preserved in Git commits 9181da8
(round 1) and 5a18cd6 (round 2); superseded worksheets and the long conversation
tracker are removed from the current tree.

## Round 2

| ID | Finding | Current disposition |
| --- | --- | --- |
| Y1 | A huge signed Safe nonce can exhaust a numeric destination ordering watermark. | Addressed by linked update heads. No numeric watermark/max-gap rule; max-nonce then smaller-nonce linked handoff has a scaffold regression. Source execution divergence remains Y2, not solved by the hash. |
| Y2 | Removed old quorum can capture a lagging destination before its legitimate update arrives. | Decided: accepted, no recovery. D96 accepts stale-quorum authority and requires receiver updates before further signing. Linked heads cannot prove source execution or repair a losing branch; a destination captured by a retired quorum stays on that branch. No recovery bypass exists. Stated in the design's "Parent responsibility" section. |
| Y3 | Late destinations anchor genesis; retired keys can compete and lost lineage blocks bootstrap. | Universal update evidence and deterministic genesis permit replay on future chains. Decided: first accepted successor wins, with no freshness rule and no latest-state shortcut. A new destination applies the full chain from genesis, possibly in one batch. Witnesses are archived off-chain (calldata and registry events); the registry stores receipts and the graph cache only. Y7/Y8 checkpoint and graph publication work remains. |
| Y4 | Rejecting/replacing a Safe transaction on source does not revoke portable signed updates. | Decided: no expiry and no validUntil field; updates are nonexpiring as in protocol-v2#2. The destination-first model retains this consequence. Tooling must distinguish source rejection from destination revocation. The root is assumed to execute any update that has a destination quorum (see "Other decisions"); a child is not. |
| Y5 | Destination binding changes cross-chain reuse and bootstrap. | Resolved: authority updates have no destination chain/provider/registry binding. Source identity/recognized guard/domain remain authenticated. Transport and ordinary application dispatch routing stay destination-specific. |
| Y6 | Existing generic SafeBatchExecutor cannot enforce registration/mutation pairing. | Architecture requires invocation-scoped completion through an enforcing executor/wrapper, exact next MultiSendCallOnly batch, and full rollback. Source template intentionally reverts until implemented. Pinning existing executor alone is not a fix. |
| Y7 | Child genesis-to-current lineage grows and missing witnesses block adoption. | A's graph stores each descendant's position, so an adoption needs links from that position only, not from the child's genesis. A newly added Safe starts from its creation proof and needs links from its genesis head. Exact authenticated content cache may anchor later lineage. Specify durable full source registration evidence and checkpoint interfaces before production; no numeric evidence/depth/work cap is added. |
| Y8 | Hash-only graph storage can make execution unavailable if graph data is lost. | Draft registry caches complete graph on installation and exposes it by hash. Actual receiver use/publication/recovery still need integration; witnesses are not automatically recoverable from a hash. |
| Y9 | Removed signers can permissionlessly finalize accepted work before cancellation. | Accepted consequence of D92. Existing explicit cancellation remains; ownership changes are not cancellation and there is no promised cancellation priority. |
| Y10 | EIP-7702 EOA-kind owner may use a source contract signature not portable to receiver. | Guard portability validation must reject v=0 for EOA-kind owners before staging. Delegated-owner real-Safe fixture remains required. |

## Round 1 retained items

| IDs | Status |
| --- | --- |
| X1 | Portable registration signature validation remains mandatory before recording source pending state. |
| X2 | Atomic pair completion is required, not implemented by the current executor; see Y6. |
| X3/X5/X8/X9/X12 | Former global-history/refresh/counter mechanisms removed; no such active requirements remain. |
| X4/X14 | The root authenticates an update under its stored record; each descendant votes under the position the update names, proven by links from the stored position. Lagging/new-chain risks are Y2/Y3 and accepted snapshot staleness is D94/D96. |
| X6/X7 | Old commitment invalidation questions superseded by D92 permanent accepted authorization subject to explicit cancellation/consumption. |
| X10 | Same-Safe nested execution/staging overwrite: enforce invocation-scoped reentrancy boundaries before source integration. |
| X11 | Activation must name/verify singleton, both guards, handler and enabled modules; slot installation alone is insufficient. |
| X13 | Default/helper/configuration governance must not gain an unreviewed way to replace authenticated owner authority. Decided: helper, executor, singleton and handler pins are fixed at guard deployment, with no setter and no owner or governance override. Changing one means a new guard; guard migration is out of scope. Enforcement is production work. |

## Other decisions

| Topic | Decision |
| --- | --- |
| Freeze and equivocation (#109 criterion) | Rejected. No freeze leaf, equivocation-evidence submission or unfreeze role. A freeze below the selected quorum is a new authority, on a lagging destination the freezing quorum may be a retired one, and unfreezing needs a recovery role that is out of scope. Conflicting successors are handled by first-accepted. |
| Nested example (#109) | A alone updates its authority regarding its children. B has no global identity inside A and there is no default to B's state. After B rotates, A's selectAuthority carrying B's witness is required before A dispatches under B's new owners; the issue's "A executes no transaction" wording is reconciled in the task list. |
| Other home-contract authority (DAO) | Rejected at registration; no adapter in this PR. A later one needs portable proof support, not a bridge assertion. |
| Ordered child positions | Decided. A's graph stores each descendant's position: the head hash of that Safe's own update list. A new graph keeps a position or moves it forward through that Safe's signed links, verified against the descendant's record in A's graph and never against the descendant's own registry entry. A height is not an identity, because a child can sign two updates after one head. |
| Whose owners vote | Decided. A descendant's signatures on an update count under the position that update names for it. The root votes under its stored record. Adoption never depends on a child's removed owners. |
| Unexecuted child update | Decided: A must not adopt a child position the child signed but did not execute on source. The source guard enforces it against the set of heads the child executed, accepting any executed head at or after A's stored position. A destination cannot check execution, so there the rule is trust in A's signers. Breaking it is permanent for that child. |
| Root executes at quorum | Accepted assumption for the root only: once an update has a quorum destinations would accept, A executes it on source and does not reject or replace it. A root that breaks this is a broken multisig. A child's earlier vote counts toward that quorum even after the child rotates. |
| Adversarial child | Nothing is assumed of a child. B may sign and abandon an update or sign two at one nonce. B gains no more than its native veto: it cannot reach a destination quorum alone, and its own forked registry entry is never read for A. |
| First position of an added Safe | Decided. A Safe installs the guard before any parent adds it, and the guard accepts installation only while the Safe has its creation owners and threshold. Its first position is the genesis head of its creation-state graph, proven by the Safe creation proof a root uses, followed by links. Source records the genesis head as executed at installation. A destination cannot see installation; that is covered by the unexecuted-update rule. |
| Two signature sets on source | Decided. Safe's check counts live child owners; the guard's portable check is the destination check. When a child rotates between its vote and A's quorum, live owners execute and the earlier set is handed to the guard outside the signed SafeTx. The guard must verify and emit it. |

## Open

| Topic | What is missing |
| --- | --- |
| Removed and re-added Safe | Whether it may be named at an earlier executed position. No stored position exists to compare against after removal. |
| Portable-set channel | The draft interface stages it with stageUpdate beside the witness. Not frozen. |
| Creation proof format | ChildGenesis carries it as opaque bytes, the same as a root's initial registration. |
| Scaffold | Types and interfaces carry positions, introduced genesis entries, links, stageUpdate and executed. Every check on them is still an abstract hook, and the test fixture rejects any witness that has them. |

## Decision lineage

D79 keeps registration/mutation atomic, D87 fixes 16 immediate owners without an
aggregate cap, D90 makes the root control its selected descendants, D91 chooses
Safe-scoped shared selections, D92 preserves accepted commitments, D94/D96 assign
freshness responsibility to A, and D95 adds no depth/evidence/work caps.
D93 numeric nonce ordering is superseded by the linked-head design. The paused
2^16 forward-gap proposal was not adopted. Final interface discussion selects
universal source-signed evidence, two guard operations, Call[] ownership batches
through pinned MultiSendCallOnly, and a zero-hash registration sentinel. Historical
global authority/counter/pinning and implicit-child-adoption alternatives are not
active requirements.
