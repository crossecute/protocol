# #109 authority adversarial review

Dated 2026-11-12. Also kept as a Claude Doc for review.

## Scope

The consolidated #109 authority design has 14 ways it can be broken or steered by an
outsider, a relayer, a former owner set or a child Safe. Five are high impact. This is
a review only; nothing here is adopted. It covers
[`safe-authority-updates.md`](../safe-authority-updates.md),
[`safe-authority-verification-review.md`](../safe-authority-verification-review.md)
and the [planning archive](safe-authority-updates-109.md) (D1–D78).

Facts checked against code:

- Safe 1.5.0 accepts `v == 1` when the executor is that owner, which is how the Safe UI encodes the executing owner's signature.
- Safe 1.5.0 increments the nonce before executing, captures the guard address before execution, and has no reentrancy guard on `execTransaction`.
- In this checkout only the receiver (`SafeSignaturesUtils`) rejects `v == 1`; `CrossecuteGuard` does not.
- #107 transient staging is keyed by Safe address only.

"Touches" lists the archive decisions or gates each finding affects. Where a decision
already accepted a risk, the finding asks whether the scenario shown was part of that
choice.

## High impact: X1 to X5

X1 and X2 are guard-side checks that reopen nothing. X3 to X5 challenge D66 to D68,
which are already confirmed, so they need a decision before more is built on the
registry rules.

| ID | Finding | Scenario | Proposed treatment | Touches |
| --- | --- | --- | --- | --- |
| X1 | Registration evidence can be valid on source but unverifiable on every receiver. | The executing owner signs as `v == 1`. Safe accepts it; the guard records pending; the mutation runs. Receivers reject `v == 1`, so none ever advance. New owners' dispatches fail on the counter while removed owners keep destination authority. Same for a nested contract signature from an uninitialized child. | At registration the guard applies the receivers' portability rules to the registration's own signatures (no `v == 1` at any level; contract signatures only from initialized Safe owners with full nested evidence) and rejects before recording pending state. | D3, D15, Q1.5, G1 |
| X2 | The pending lock can freeze the Safe permanently, assets included. | Quorum records a registration. Before the next-nonce mutation reaches quorum, a signer loses a key or leaves. D15 blocks every other transaction and D20 forbids cancellation, so funds never move again. Archive Q3.6 leaves approval readiness open. | Require the complete mutation signature bundle at registration, verify it with Safe's `checkNSignatures` against the mutation tx hash at nonce m+1, and emit it so anyone can execute. Or require registration and mutation in one outer transaction. | D15, D19, D20, Q3.6 |
| X3 | Anyone can toggle a receiver between two authenticated same-counter branches. | Both branches' evidence is public and `submitAuthority` is permissionless (D67, D68). An observer flips a receiver's B back and forth, so work signed under either branch fails whenever they choose. Post-success sync ("equal counter, differing content: adopt registry") also undoes any locally chosen branch. | Make local selection an act of the receiver's own authority (A's quorum signs it), or make a selected alternative stick until A replaces it. Define precedence between a selection and post-success sync. | D66, D67, D68, D59, D64 |
| X4 | A former owner set can rewrite current authority indefinitely. | B rotates 1 -> 2 to move custody to all-new keys. Until B rotates again, a quorum of the counter-1 owners can sign a different counter-2 alternative and install it on any receiver, including where B is root. D68 accepted either branch as eligible; this scenario makes that a takeover path. | Refuse an alternative at a counter the receiver already applied; or require the current authority's quorum to approve a switch; or allow alternatives only while the receiver is behind. | D66, D68, D17 |
| X5 | Any observer can pin a destination registry to a branch the source never runs. | The Safe Transaction Service publishes collected signatures, and teams often sign a replacement at the same nonce. An observer executes one on source and pushes the other to every destination registry first, so the global first record (D66) is the dead branch. A draft with an unmeetable threshold freezes B's global entry on that chain. | Decide what happens when B's next real transition names a predecessor that differs from the global record: global stuck, non-linear history, or per-content records with lineage. Add a signer-tooling rule never to collect quorum on two registrations at one counter. | D5, D21, D62, D66 |

## Medium: X6 to X10

| ID | Finding | Scenario | Proposed treatment | Touches |
| --- | --- | --- | --- | --- |
| X6 | A same-counter root alternative keeps commitments valid under the other branch. | A commitment is accepted under root branch Bob at counter n; a Carol alternative at n is then selected. Revised D22 compares only the root counter, so Bob-authorized work still finalizes under Carol. | Store the root authority content hash with the counter at acceptance and compare both at finalization (G4 notes a counter does not identify content). | D22, D23, G3, G4 |
| X7 | Anyone controls when a rotation invalidates in-flight work. | Once signed, an update can be applied destination-first by anyone (D4). An observer pushes it ahead of pending dispatches and commitments, which then fail on the root counter. | Document an operational order (sign rotations after in-flight work lands), or add an optional signed `notBefore` to update leaves. | D4, D13, D22 |
| X8 | The submitter chooses which children get refreshed. | When several valid proofs exist, the relayer picks the threshold entries, so it decides which children count (D54) and get synchronized to the registry, possibly to the X5 branch. | Accept and document, or refresh deterministically from the verified entries regardless of which proof was supplied. | D52, D53, D54 |
| X9 | A child Safe can stop its parent's executions through refresh cost. | B is a third-party Safe owning part of A. Anyone can register arbitrary Safes' genesis, so B's quorum can add many registered children or cycles. The next A execution counting B must adopt B's latest record with authenticated closure (G6); gas grows until A's executions needing B always fail. Removal traversal grows too. | Bound adoption per refresh (G5). When a refresh exceeds its bound, skip it and emit an event rather than reverting the successful execution, consistent with D45. | D45, D53, D78, G5, G6 |
| X10 | The same Safe's transactions can nest inside each other. | Safe 1.5.0 has no reentrancy guard and bumps the nonce first. A CALL from tx m reaches an attacker contract that executes the public, fully signed tx m+1 (or m+1 and m+2) of the same Safe. Inner post-hooks run before outer ones and #107 transient staging is keyed by Safe only, so pending markers and staged signatures can be overwritten or attributed to the wrong tx. | Reject `checkTransaction` for a Safe that already has a tx between its hooks (per-Safe depth lock), or key transient state by Safe and txHash. Sequential txs in one outer tx (D19) stay allowed. | D19, G7 |

## Remaining: X11 to X14

| ID | Finding | Scenario | Proposed treatment | Touches |
| --- | --- | --- | --- | --- |
| X11 | Activation checks owners and threshold but not the current configuration. | A Safe created at 1.5.0 changes its singleton (storage slot 0), fallback handler or modules before installing the guard. Owners still match the creation commitment, so activation passes on a Safe whose code or handler receivers do not emulate. | At activation also check the singleton is the recognized variant, the handler is acceptable, both guard slots are set and the module list fits policy. | D70, D74, D27 |
| X12 | A local registry write that can revert becomes a permanent lock. | The post-hook writes the local-source registry at n+1. If that write can revert (a bound, an unexpected registry state), the mutation reverts and, with X2, the Safe stays locked. | Make the guard's registry write bounded and unable to fail for valid post-states; test it at the graph limits. | D18, D56, V5 |
| X13 | Governance-mutable inputs can reach guard protections. | If the D36 helper pins or the universal-to-EIP-155 chain mapping come from a ChainRegistry override the owner can change, governance can repoint SignMessageLib to arbitrary code (an owner delegatecall then bypasses every protection) or change which chain's Safe domain an identity resolves to. | Make helper pins immutable guard constructor arguments. Confirm the chain-id mapping used in Safe domains is write-once. | D36, D75, D76 |
| X14 | Lagging receivers let removed keys mint durable approvals. | A receiver still on B's old authority verifies and persists exact-message approvals (D47) signed by removed keys; T21 keeps them after sync. The stale-key window is accepted, but persistence outlives it. | Optionally refuse to persist an approval verified under a B counter older than the registry's latest. | D46, D47 |

## Acceptance tests to add

| ID | Case | Expected result |
| --- | --- | --- |
| X1-T | Registration executed by an owner whose signature is `v == 1`; registration with a nested contract signature from an uninitialized child. | Guard rejects before recording pending state. |
| X2-T | Registration recorded, then mutation signers fall below threshold. | Under the chosen treatment: a registration without a valid mutation bundle is rejected, or the Safe can still reach a defined state. |
| X3-T | Two valid same-counter B alternatives submitted alternately by an unrelated caller; then A executes counting B. | Selection changes only under the chosen authorization rule; sync precedence matches the spec. |
| X4-T | B rotates every key 1 -> 2; old quorum signs a counter-2 alternative and submits it where B is root and where B is a child. | Rejected under the chosen rule. |
| X5-T | Two quorum-signed registrations at one counter; the non-executed one reaches the destination registry first; then B's next real transition arrives. | Registry follows the chosen predecessor rule; no silent fork. |
| X6-T | Commitment accepted at root counter n under branch Bob; Carol alternative selected at n; finalize. | Rejected if the content hash is stored. |
| X9-T | Counted child B adds N registered children; A executes. | Execution succeeds; refresh is skipped or bounded with an event. |
| X10-T | Tx m makes an external CALL that executes the same Safe's signed m+1 registration and m+2 mutation. | Rejected by the depth lock, or state stays correctly attributed. |
| X11-T | Singleton slot, handler or module list changed before guard installation; owners unchanged. | Activation rejects. |
