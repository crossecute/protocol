# #109 authority adversarial review, round 2

Dated 2026-11-13. Reviews the [current design](../safe-authority-updates.md) and
[acceptance plan](../safe-authority-verification-review.md) as reconciled through
D96, plus archive decisions D79–D96. Round 1 is
[safe-authority-adversarial-review-109.md](safe-authority-adversarial-review-109.md).
Review only; nothing here is adopted.

Facts checked against code in this checkout:

- `SafeBatchExecutor.execute` is permissionless and runs any list of signed Safe transactions; it has no notion of pairing.
- `ReceiverBase.finalize` has no delay and no caller gate; `cancel` and `commit` are gated by `onlySourceTransmitter`, so cancelling needs a signed dispatch under the selected graph.
- `SafeAuthorityGraph._isEoa` classifies a 23-byte `0xef0100` (EIP-7702 delegated) account as an EOA.

## Round 1 status

| Round 1 | Status under D96 |
| --- | --- |
| X1 non-portable registration signatures | Addressed by D79 (stage and verify portable registration evidence). |
| X2 permanent pending lock | Addressed by D79 in intent; Y6 below shows the existing executor cannot enforce it. |
| X3, X5, X8, X9 | Retired: no global child records, alternatives or automatic refresh (D90, D91). |
| X4 old quorum rewrites current authority | Retired for updated destinations (management verifies under the current graph). Reappears on lagging and new destinations as Y2 and Y3. |
| X6 commitments under another branch | Superseded by D92 (accepted commitments survive all ownership changes). |
| X7 anyone times invalidation | Retired with commitment invalidation. |
| X10 nested same-Safe execution | Still open; G1 names reentrancy tracking but no rule. |
| X11 activation configuration | Partly addressed ("recognized creation/configuration"); singleton slot, handler and module list are not named. |
| X12 registry write in post-hook | Largely retired: the source guard stores its own content/hash, not destination state. |
| X13 governance-mutable pins | Partly addressed ("pin helper deployment configuration"); immutability is not stated. |
| X14 stale-key approvals | Accepted under D96. |

## New findings

| ID | Finding | Scenario | Proposed treatment | Touches |
| --- | --- | --- | --- | --- |
| Y1 | One signed management nonce can freeze a destination's authority forever. | D93 accepts any strictly higher signed nonce. The nonce is a field the signers choose, not proof of source execution. An update signed at nonce `2^256 - 1` (by mistake, a tooling bug, or a malicious but valid quorum) is accepted, and no later update can ever exceed it. | Reject nonces above a bound (for example `last + 2^32`, or below `2^64`), or require the management SafeTx to carry a nonce no greater than a value the destination can check. Add a test at the maximum. | D93, G2 |
| Y2 | Removed owners can permanently capture a destination that has not installed the rotation. | A rotates X -> Y on source; destination Q still holds X. The removed X quorum signs a new management update at a high nonce selecting their own graph W. Q accepts it; the legitimate X -> Y update now has a lower nonce and is stale forever, and W's owners control every later update on Q. D96 accepted that a stale quorum may still authorize work; this turns it into irreversible loss of the destination. | Accept explicitly and document the operational rule: for a compromise-driven rotation, treat any destination not yet updated as lost. Or add a signed expiry so only recently signed updates apply (does not stop fresh X signatures). No on-chain rule can tell the two quorums apart without a freshness proof. | D93, D96 |
| Y3 | Every new destination starts from the genesis owners. | The first selection on a destination comes from the creation witness, which is the genesis graph. Reaching the current graph needs management updates signed under genesis and each later quorum, in order. If genesis keys were retired because they were compromised, their holder can be first on any new destination and install their own graph. If historical updates were not kept, legitimate owners can never bootstrap a new destination. | Specify late-destination bootstrap for the root: either replay the full chain of historical management updates (then they must be stored durably), or anchor the root like a child, from genesis plus A's own authenticated source transitions, and say which wins when both arrive. | D91, D96, G9 |
| Y4 | Safe's normal "reject" flow does not cancel a management update. | Signers queue an update at nonce 12, change their minds and execute Safe's standard rejection (an empty tx at nonce 12). The signed update stays valid on every destination (D93 ignores source execution). Signers also often queue alternatives at different nonces; any relayer chooses which arrives first, and the highest valid nonce wins on each destination independently. | Add a signed `validUntil` to management updates so an unwanted update can be left to expire. Document that source rejection has no effect, and have tooling warn. | D20, D93 |
| Y5 | Destination binding of management updates is undecided and has security weight either way. | If an update is not bound to a destination chain, anyone can apply it on every chain, so A cannot keep a B snapshot on one chain and not another, and Y2 and Y3 spread automatically. If it is bound, historical updates cannot bootstrap new destinations (Y3) and A signs once per chain. | Decide in G9 and record which of these consequences is accepted. | G9 |
| Y6 | The existing batch executor cannot enforce "registration and mutation together". | The registration SafeTx is public once signed. Anyone can call `SafeBatchExecutor.execute` with only the registration, which passes D79's executor-identity check. If pending state is in persistent storage, the Safe is locked again (round 1 X2). | Keep pending state only in transient storage so it cannot outlive the outer transaction, and have the mutation's hooks require it. Or deploy a dedicated executor that validates the pair. | D79, G1 |
| Y7 | Child lineage has no checkpoint, so B's history can make B unusable. | Selecting B's latest state needs authenticated lineage from B's genesis. D95 sets no size limit. Every B rotation lengthens the proof, a third-party B can rotate many times to price A out, and one missing historical B registration witness makes every later B state unauthenticatable without a cache. | State that an exact-content cache entry of an authenticated B state is a valid anchor for later lineage, and require the guard to emit full registration evidence so witnesses stay recoverable. | D90, D95, G6 |
| Y8 | Graph data availability decides whether A can execute at all. | The registry stores only a hash. Each execution must supply the full canonical graph or find it in the cache. If installation does not write the cache and the data is lost, A cannot execute anywhere it was installed. Supplying the graph each time also adds bytes to every LayerZero or CCIP message, which price per byte. | Require installation to write the content-addressed cache (or emit the full graph), and state the per-message size cost if graphs are sent inline. | D91, G6 |
| Y9 | D92 lets removed signers finalize work they already know about. | `finalize` is ungated and has no delay. A signer removed for cause who knows an accepted commitment's call array can finalize it at any time; the new quorum's `cancel` is a dispatch that can be front-run. | Accept and document; signers needing to stop accepted work cancel before or with the rotation. | D92 |
| Y10 | EIP-7702 owners can produce signatures source accepts and receivers do not. | `_isEoa` keeps delegated accounts as EOA kind, which is right for receivers. On source, Safe 1.5.0 will accept a `v = 0` contract signature from that owner through its delegate's `isValidSignature`. A registration using one passes on source but is not portable. | Confirm D79's portability check rejects contract signatures from EOA-kind owners; add a fixture with a delegated owner. | D79, Q1.5 |

## Tests to add

| ID | Case | Expected result |
| --- | --- | --- |
| Y1-T | Management update at nonce `2^256 - 1`, then a valid later update. | Rejected by the chosen bound; the later update still applies. |
| Y2-T | Destination at X receives a removed-quorum update at a high nonce before the legitimate X -> Y update. | Behavior matches the recorded decision; document if capture is accepted. |
| Y3-T | New destination initialized after three rotations; both a genesis-quorum update and the current lineage are submitted. | Bootstrap follows the chosen rule. |
| Y4-T | Update queued at nonce 12, then rejected on source; update relayed after `validUntil`. | Rejected after expiry. |
| Y6-T | `SafeBatchExecutor.execute` called with only a signed registration. | No pending state remains after the transaction. |
| Y7-T | B with 50 rotations; A selects B's latest with and without a cached anchor. | Succeeds from the anchor; fails cleanly without the witnesses. |
| Y10-T | Registration signed with a `v = 0` signature from an EIP-7702 delegated owner. | Guard rejects before recording pending state. |
