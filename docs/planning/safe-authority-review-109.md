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
| Y2 | Removed old quorum can capture a lagging destination before its legitimate update arrives. | D96 accepts stale-quorum authority and requires receiver updates before further signing. The stronger compromise/capture consequence must be explicit before production: linked heads cannot prove source execution or repair a losing branch automatically. No recovery bypass has been authorized. |
| Y3 | Late destinations anchor genesis; retired keys can compete and lost lineage blocks bootstrap. | Universal update evidence and deterministic genesis permit replay on future chains. Preserve durable full linked witnesses. Winner/freshness/recovery for competing genesis branches remains unresolved; no source-state proof or trusted latest-state shortcut is implied. |
| Y4 | Rejecting/replacing a Safe transaction on source does not revoke portable signed updates. | Existing destination-first model retains this consequence. Expiry was proposed by review, not adopted; no silent validUntil field is added. Tooling must distinguish source rejection from destination revocation. |
| Y5 | Destination binding changes cross-chain reuse and bootstrap. | Resolved: authority updates have no destination chain/provider/registry binding. Source identity/recognized guard/domain remain authenticated. Transport and ordinary application dispatch routing stay destination-specific. |
| Y6 | Existing generic SafeBatchExecutor cannot enforce registration/mutation pairing. | Architecture requires invocation-scoped completion through an enforcing executor/wrapper, exact next MultiSendCallOnly batch, and full rollback. Source template intentionally reverts until implemented. Pinning existing executor alone is not a fix. |
| Y7 | Child genesis-to-current lineage grows and missing witnesses block adoption. | Exact authenticated content cache may anchor later lineage. Specify durable full source registration evidence and checkpoint interfaces before production; no numeric evidence/depth/work cap is added. |
| Y8 | Hash-only graph storage can make execution unavailable if graph data is lost. | Draft registry caches complete graph on installation and exposes it by hash. Actual receiver use/publication/recovery still need integration; witnesses are not automatically recoverable from a hash. |
| Y9 | Removed signers can permissionlessly finalize accepted work before cancellation. | Accepted consequence of D92. Existing explicit cancellation remains; ownership changes are not cancellation and there is no promised cancellation priority. |
| Y10 | EIP-7702 EOA-kind owner may use a source contract signature not portable to receiver. | Guard portability validation must reject v=0 for EOA-kind owners before staging. Delegated-owner real-Safe fixture remains required. |

## Round 1 retained items

| IDs | Status |
| --- | --- |
| X1 | Portable registration signature validation remains mandatory before recording source pending state. |
| X2 | Atomic pair completion is required, not implemented by the current executor; see Y6. |
| X3/X5/X8/X9/X12 | Former global-history/refresh/counter mechanisms removed; no such active requirements remain. |
| X4/X14 | Updated selections authenticate their current quorum; lagging/new-chain risks are Y2/Y3 and accepted snapshot staleness is D94/D96. |
| X6/X7 | Old commitment invalidation questions superseded by D92 permanent accepted authorization subject to explicit cancellation/consumption. |
| X10 | Same-Safe nested execution/staging overwrite: enforce invocation-scoped reentrancy boundaries before source integration. |
| X11 | Activation must name/verify singleton, both guards, handler and enabled modules; slot installation alone is insufficient. |
| X13 | Default/helper/configuration governance must not gain an unreviewed way to replace authenticated owner authority. Final immutability/override enforcement is production work. |

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
