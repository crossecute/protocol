# Safe authority updates

Design and draft interfaces for [#109](https://github.com/crossecute/protocol/issues/109).
Stacks on the fixed-authority [signed dispatch](safe-signed-dispatch.md) and
[Safe guard](safe-guard-design.md). This file owns architecture and normative behavior;
[verification](safe-authority-verification-review.md) owns implementation gates/tests,
[review findings](planning/safe-authority-review-109.md) own security disposition, and
[benchmarks](benchmarks/authority-109/README.md) own measurements/reproduction.

**Status:** design plus non-deployable scaffold. Current receivers/guards are not
wired to the new interfaces. The source template reverts; the registry template
requires abstract security hooks. No production rotation or deployment is claimed.

## One selected graph per source Safe

A destination registry shares this state across all providers/direct paths:

```solidity
mapping(uint256 sourceChainId => mapping(address sourceSafe => AuthoritySelection)) selections;

struct AuthoritySelection {
    bytes32 updateHead;
    bytes32 authorityHash;
}
```

Zero authorityHash means unregistered. Initial and replacement hashes must be
nonzero; no separate initialized boolean is needed. updateHead identifies the last
accepted signed update, not the owner graph. There is no independently advancing
global child authority, authority counter or mandatory on-chain version history.

The source identity is (source chain, Safe). Each graph has one root Safe, ordered
Safe records and each node's owners/kinds/threshold. Canonical depth-first traversal
emits each reachable Safe once in owner order; cycles stop enumeration at visited
nodes. SafeOwner and SafeAuthorityRecord reuse existing signed-dispatch types, and
Call reuses messaging/Call.sol. RootSafe identifies the graph owner, not the current
node while recursively checking signatures.

For A -> B -> C -> B, A's graph has root A and records A/B/C. C points back to the
same B record. B's own selected graph and C's own selected graph are independent
entries; their B snapshots can differ from A's authenticated B snapshot. No dynamic
lookup of B's root selection may change B inside A. Provider receivers for A share
A's selected hash on that destination, not independent local branches.

Graph data can be supplied against the selected hash or read from an exact-content
cache. The draft registry writes the full graph on initial/update installation and
exposes graph(hash), avoiding repeated graph bytes on ordinary cached execution.
Caches of authenticated child states may anchor later transition proofs; a cache
entry never chooses a parent's authority. Lost source lineage and late bootstrap
still need durable witnesses; see review Y3/Y7/Y8.

## Linked, universally reusable updates

```solidity
struct AuthorityUpdate {
    bytes32 previousUpdateHash;
    bytes32 previousAuthorityHash;
    bytes32 newAuthorityHash;
}
```

A's currently selected full quorum signs the exact recognized source guard call.
The SafeTx binds the source Safe/source EIP-155 chain, target guard, selector,
arguments and ordinary SafeTx fields. No destination chain ID, destination registry
address or provider is in the authority-update payload. The same evidence is valid
on current and future destination chains for that source identity, subject to their
own predecessor, registration and quorum checks. Universal evidence is not automatic
delivery, source execution proof or universal branch convergence.

A new update follows the stored updateHead and previousAuthorityHash exactly.
Its update identifier is the registration/selectAuthority SafeTx hash, not a receipt,
outer executor hash, mutation SafeTx hash or hash of signatures. The next update
signs that identifier as previousUpdateHash. Initial registration instead derives a
stable domain-separated genesis head from source identity and initial graph hash.
The draft encoding is in the scaffold; exact genesis authentication remains a hook.

This linked chain supersedes D93's numeric management nonce watermark. There is no
maximum-forward-gap rule: the proposed 2^16 gap was paused before adoption and is
unnecessary for linked ordering. Safe nonces remain signed and enforced on source,
but destination ordering compares predecessor hashes, not numeric magnitudes. A
very large signed nonce cannot numerically freeze subsequent lower-nonce linked
updates. A graph returning to an earlier hash has a different update head.

To accept a destination update:

1. Load the source identity's registered selection and require an idle shared context.
2. Decode the actual signed source guard calldata, recognize its target/function and
   validate its portable signatures/nested quorum against the current selected graph.
3. Check signed previousUpdateHash == stored updateHead and previousAuthorityHash ==
   stored authorityHash. Reject a wrong predecessor even if old/new owners overlap.
4. Recompute the complete new graph hash and authenticate canonical structure,
   thresholds, owner kinds and introduced descendant-state evidence.
5. Atomically cache the graph, record the exact accepted update receipt and set the
   new hash/head. Validation failure must leave no head, receipt or pending state.

U2 cannot precede U1 if it names hash(U1). Consecutive handoffs may be submitted in
one batch, but each is independently verified. Exact duplicates reject in the draft
scaffold; provider integrations may later add authenticated no-op acknowledgments.
Conflicting signed successors of one head are possible. Each destination can accept
only one; the losing successor cannot overwrite it. The chain does not prove which
successor executed on source. Restoration requires valid authorization under the
currently selected branch, not a special old-owner override.

## Source guard and mutation batch

Both operations belong to the shared deterministic guard, not a separate authority
manager. Infrastructure defaults use CREATE2 with explicit source-chain exceptions.
Equal factory address, salt and initcode yield equal compatible-EVM addresses;
constructor arguments affect initcode. Verify actual helper deployments/code.

```solidity
registerOwnershipChange(AuthorityUpdate update, Call[] mutations)
selectAuthority(AuthorityUpdate update)
selection(address sourceSafe) -> AuthoritySelection
```

selectAuthority changes A's tracked graph (for example its B snapshot), without a
source owner mutation. It must be signed and validated under A's current source
Safe rules and portable selected authority, then advance the same linked source
head. No private key belongs to a Safe contract; owners sign the SafeTx digest.

registerOwnershipChange is the first of two signed Safe transactions:

| Step | Required behavior |
| --- | --- |
| Registration at Safe nonce m | CALL guard; sign predecessor/new graph and exact ordered mutations; validate source state, guard readiness and portable evidence; stage pending pair. |
| Mutation at m+1 | DELEGATECALL the pinned MultiSendCallOnly helper, value zero, with exact packed CALLs derived from mutations. Use this path even for a single-element batch. |
| Inner mutation calls | Each targets the signing Safe, value zero, and one of addOwnerWithThreshold/removeOwner/swapOwner/changeThreshold. No inner delegatecall, external target or configuration change. |
| Post-hook | Require batch success and actual ordered owners/threshold matching the signed final graph; update source selection/head and clear pending state. |
| Outer executor completion | Every registered pair in that invocation must finish before return; no registration-only persistent lock. Any failure rolls back both Safe transactions and nonce advances. |

The outer Safe transaction explicitly signs operation=DELEGATECALL and the helper
target. MultiSendCallOnly's inner CALLs originate from the Safe context, satisfying
Safe's self-call requirement. The initial source quorum is checked before the
mutation batch; intermediate threshold changes do not request new signatures.
Validate every intermediate Safe mutation's predecessor/sentinel, insertion order,
threshold and 16-owner constraint, then verify final state. One ordered mutation
batch advances the linked authority head once. Multiple complete pairs may share
one outer transaction, with one pending pair per Safe at a time.

The current SafeBatchExecutor does not enforce completion. Source implementation
must add invocation-scoped completion checks or a dedicated enforcing wrapper;
pinning its address alone is insufficient. Guard hooks must bind the next exact
helper calldata and allow this registered ownership-only batch as an exception to
the existing ordinary MultiSendCallOnly self-call ban. Unregistered batches remain
blocked. No generic allowance for arbitrary Safe self-targets is implied.

Mutation SafeTx signatures are not an additional destination requirement; portable
registration evidence authorizes the exact result before source execution. Source
installation, execution, cancellation and nonce consumption do not revoke that
portable authorization. A helper's ability to execute batches does not itself
validate the linked authority update.

## Parent responsibility and accepted authorization

Only A's explicitly signed graph update changes A's tracked children. Independent
B source changes or B's own selected entry do not. A must adopt authenticated stricter
child snapshots before authorizing further A transactions (D94). A must likewise
install its own authority changes on relevant receivers before signing further
application transactions (D96). These are operational responsibilities, not automatic
source freshness checks. Until installation, old stored owners/thresholds remain
eligible, including lower thresholds. This stale-authority risk is accepted.

All fresh approvals use the selected graph, with native per-node thresholds and
child-domain SafeMessage hashing. No global/local fallback or opportunistic child
adoption is permitted. Child records need independently authenticated genesis or
transition witnesses; A selects authentic states, not invented child owners.
Source signatures prove authorization, not source execution/time/deployment. A may
select an authenticated unexecuted child state. Removed keys cannot authorize a
new branch after the receiver replaces them unless they still satisfy its selected
quorum. Lagging/new destinations have the additional review risks in Y2/Y3.

Accepted receiver commitments survive root and nested ownership changes (D92).
Finalize uses the recorded exact-call authorization without a fresh signature check
or hash/head equality requirement. Preserve explicit cancellation, repeat approval
accounting, atomic whole-array execution and consumption/replay checks. Anyone may
finalize before a later cancellation; survival does not promise target-call success.
Unaccepted off-chain signatures still face current selected-authority checks on first
submission. Returning to an old graph may restore old unexecuted approvals if their
normal nonce/window checks pass, but never restores consumed/cancelled work.

## Initialization, invariants and resource behavior

Recognized Safe creation proof anchors initial authority: verify source factory,
Safe/SafeL2 singleton, proxy creation code, full initializer and salt derivation.
Predetermined addresses do not reveal initializer/owner preimages. Supported setup
semantics must exclude hidden bypasses. A creation witness proves a starting
configuration, not source deployment, current authority or guard activation.
Initial graph closure and late-chain lineage are independently verified; do not
trust a claimed latest-owner list. Chain-specific derivation variants need explicit
support, not substitution into the ordinary CREATE2 formula.

Source guard activation is explicit one-time readiness plus validated authority,
not merely writing a guard slot. Require transaction and module guards, recognized
singleton/handler/module configuration, supported actual starting authority, and
child readiness/handler matching. Destination registration cannot fabricate native
source readiness. Block unregistered owner changes, guard/handler replacement,
module self-calls/delegatecalls and protected-configuration bypasses. Pin approved
helper code/configuration; mutable pins remain review X13 work.

Canonical graph enumeration allows cycles, but authorization must be a finite valid
proof. A repeated Safe at a different nested message digest is not automatically a
circular proof. Track unresolved/completed exact claims and never permit circular
self-support. Reject portable v=1 and contract signatures for EOA-kind owners,
including EIP-7702 delegated EOAs. Do not flatten quorums or count a signer twice
within one Safe's threshold. Cache only fully verified exact-message claims.

Each Safe has at most 16 immediate owners. No aggregate owner cap, nesting-depth
cap, evidence-size cap or verification-work/gas budget is added (D95). VM/chain/provider
limits still determine completion and relayability. Preserve terminating traversal
and atomic failure; no promise of unlimited practical execution or data availability.

Keep immutable conduit creation identity, routing and application replay records
through every authority update/cache cleanup. Freeze the shared authority context
during application verification/execution across all provider and direct entry
points. Application leaves/callbacks cannot act as management bypasses. Ordinary
execution never refreshes child snapshots or advances updateHead. Emergency/admin
recovery, guard migration, custom validators, zkSync/Tron and signed OFT are outside
this scaffold; other home-contract authority adapters require separate portable proof
support and must reject unsupported paths rather than trust a bridge assertion.
