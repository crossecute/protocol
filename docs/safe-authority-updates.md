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
The scaffold predates the activation, one-transaction ownership change, per-record
graph hash and flat child-update witness below; the
[verification plan](safe-authority-verification-review.md#scaffold-coverage-and-remaining-work)
lists where it still differs.

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
global child authority and no authority counter. A destination registry keeps no
version history. The source guard keeps the set of update heads each Safe has
executed, as hashes only, to check [child positions](#child-positions).

The source identity is (source chain, Safe). Each graph has one root Safe, ordered
Safe records and each node's owners/kinds/threshold. Canonical depth-first traversal
emits each reachable Safe once in owner order and rejects cycles, the same rule and
traversal as #108's SafeAuthorityGraph. SafeOwner and SafeAuthorityRecord
reuse existing signed-dispatch types, and Call reuses messaging/Call.sol. RootSafe
identifies the graph owner, not the current node while recursively checking signatures.

For A -> B -> C with A -> C, A's graph has root A and records A/B/C. B and A point to
the same C record. B's own selected graph and C's own selected graph are independent
entries; their B snapshots can differ from A's authenticated B snapshot. No dynamic
lookup of B's root selection may change B inside A. Next to each descendant record,
A's graph stores that Safe's [position](#child-positions). Provider receivers for A share
A's selected hash on that destination, not independent local branches.

The graph hash covers one entry per Safe: the hash of that Safe's SafeAuthorityRecord
and its position. The registry stores each record once under its hash and each graph
as its entry list, so an update writes only the records it changes plus 64 bytes per
Safe, and graph(hash) returns the graph. Graph data can also be supplied against the
selected hash. Caches of authenticated child states may anchor later transition
proofs; a cache entry never chooses a parent's authority. Lost source lineage and late
bootstrap still need durable witnesses; see review Y3/Y7/Y8.

## Linked, universally reusable updates

```solidity
struct AuthorityUpdate {
    bytes32 previousUpdateHash;
    bytes32 previousAuthorityHash;
    bytes32 newAuthorityHash;
}
```

A's currently selected full quorum signs the exact recognized source transaction: a
guard call, or for an ownership change the pinned MultiSendCallOnly batch that starts
with one. The SafeTx binds the source Safe/source EIP-155 chain, target, selector,
arguments and ordinary SafeTx fields. No destination chain ID, destination registry
address or provider is in the authority-update payload. The same evidence is valid
on current and future destination chains for that source identity, subject to their
own predecessor, registration and quorum checks. Universal evidence is not automatic
delivery, source execution proof or universal branch convergence.

A new update follows the stored updateHead and previousAuthorityHash exactly.
Its update identifier is the SafeTx hash of the signed activation, ownership change
or selectAuthority transaction, not a receipt, outer executor hash or hash of
signatures. The next update signs that identifier as previousUpdateHash. A Safe's
first head is its [activation](#activation-and-creation-proof) SafeTx hash; the
activation signs zero for both previous hashes.

This linked chain supersedes D93's numeric management nonce watermark. There is no
maximum-forward-gap rule: the proposed 2^16 gap was paused before adoption and is
unnecessary for linked ordering. Safe nonces remain signed and enforced on source,
but destination ordering compares predecessor hashes, not numeric magnitudes. A
very large signed nonce cannot numerically freeze subsequent lower-nonce linked
updates. A graph returning to an earlier hash has a different update head.

To accept a destination update:

1. Load the source identity's registered selection and require an idle shared context.
2. Decode the actual signed source calldata and recognize its target/function.
3. Check signed previousUpdateHash == stored updateHead and previousAuthorityHash ==
   stored authorityHash. Reject a wrong predecessor even if old/new owners overlap.
4. Recompute the complete new graph hash and authenticate canonical structure,
   thresholds, owner kinds, the root's new record (its stored record after any signed
   mutations) and every descendant [position](#child-positions): kept, or reached
   from the stored one through the supplied child updates.
5. Validate the portable signatures/nested quorum. The root votes under its stored
   record. Each descendant votes under the position the new graph names for it.
6. Atomically store new records and the graph, record the exact accepted update
   receipt and set the new hash/head. Validation failure must leave no head, receipt
   or other state.

U2 cannot precede U1 if it names hash(U1). Consecutive handoffs may be submitted in
one batch, but each is independently verified. Exact duplicates reject in the draft
scaffold; provider integrations may later add authenticated no-op acknowledgments.
Conflicting signed successors of one head are possible. Each destination can accept
only one; the losing successor cannot overwrite it. The chain does not prove which
successor executed on source. Restoration requires valid authorization under the
currently selected branch, not a special old-owner override.

Updates carry no expiry. A signed update stays valid until its predecessor is
superseded, even if its SafeTx is rejected or replaced on source (Y4). Tooling must
tell source rejection apart from destination revocation.

## Child positions

Every Safe with the guard has its own linked update list. Each of its update heads
is a position in that list. A's graph stores, next to each descendant Safe's record,
the position of that Safe that A last adopted. A position is the head hash. A height
cannot identify it: a Safe can sign two different updates after the same head, so
two positions can share a height away from source.

A new graph must keep each retained descendant at its stored position or move it
forward. Forward means reached from the stored position through that Safe's own
signed updates, each naming the one before it. These child updates travel with A's
update. They are verified against records proven from A's graph, never against the
descendant's own registry entry, which can lag or sit on another branch. An
ownership-change update changes the descendant's record to the result of its signed
mutations. A selectAuthority update moves the position only. One A update may move a
descendant forward by several child updates. An update that keeps a position needs
none.

A descendant's signatures on an update count under the position that update names
for it. An update that keeps B's position is voted by B's stored owners. One that
moves B forward is voted by the owners the child updates prove. The root always votes
under its stored record (T6). Adopting B's rotation therefore never needs B's removed
owners. A returning owner set (X, Y, X) is a new position, so an old child update
cannot be replayed.

The same rule applies inside a child update. If B's update needed a vote from B's
own Safe owner C, C counts under the position B's new graph names for C, as B's guard
counted it on source. A's verifier therefore proves positions in one flat pass over
child updates at any depth. It keeps a table of proven (Safe, position) records,
seeded with A's stored entries and with the activations of Safes A adds. Each child
update, in witness order, needs its predecessor and every nested voter's position
already in the table, then adds its own result. Each carries its new graph's entry
list, checked against the newAuthorityHash it signs, so the verifier can read its
voters' positions; only Safes that vote need full records. Every entry of A's new
graph must end in the table, and a retained Safe's entry must descend from its stored
position, not from an activation supplied for a voter. An order always exists,
because each child update executed on source after the positions it relied on.
Counting C under A's own record for C instead could leave A unable to adopt an
executed B update once A had moved C past the position B used.

A Safe [activates](#activation-and-creation-proof) the guard before any parent adds
it, and its activation head is its first position. A new graph that adds a Safe, or
re-adds one it removed earlier, supplies that Safe's signed activation as its first
child update, then child updates to the position it names. A re-added Safe has no
stored position to compare against, so any executed position may be named, including
one earlier than where it was removed. A Safe's executed heads form one list, so any
of them still leads to its later positions. On source the guard requires the named
position to be executed, so a Safe that never activated cannot be added. A
destination sees the signed activation, not its execution; that falls under the rule
that A adopts only executed positions.

The update's supporting data is one witness, the same on source and destinations:

```solidity
struct UpdateWitness {
    AuthorityGraph newGraph;  // records and one position per record
    ChildUpdate[] updates;    // signed child updates at any depth, in proof order
}

struct ChildUpdate {
    address safe;
    SafeTxEvidence evidence;  // the child's activation, ownership change or selectAuthority
    GraphEntry[] newEntries;  // its new graph's entries; hash == its signed newAuthorityHash
}

struct GraphEntry {
    bytes32 recordHash;
    bytes32 position;
}
```

A descendant kept at its stored position needs no child update. One moved forward has
child updates from the stored position. One added starts with its activation. Voters
that child updates need are proven the same way.

## Source guard and mutation batch

The operations belong to the shared deterministic guard, not a separate authority
manager. Infrastructure defaults use CREATE2 with explicit source-chain exceptions.
Equal factory address, salt and initcode yield equal compatible-EVM addresses;
constructor arguments affect initcode. Verify actual helper deployments/code.

```solidity
activate(AuthorityUpdate update, SafeCreationProof creation)
registerOwnershipChange(AuthorityUpdate update)
selectAuthority(AuthorityUpdate update)
stageUpdate(address sourceSafe, UpdateWitness witness, PortableEvidence portable)
selection(address sourceSafe) -> AuthoritySelection
executed(address sourceSafe, bytes32 updateHead) -> bool

struct PortableEvidence {
    bytes signatures;                // empty when the executing signatures are portable
    NestedSafeApproval[] approvals;  // signMessage evidence for empty nested signatures
}
```

The signed calls carry hashes only. stageUpdate, called earlier in the same outer
transaction, supplies the witness those hashes commit to and the portable evidence.
Anyone may call it. The guard holds it in transient storage for that Safe's next
guarded transaction, under its per-Safe nesting lock (X10). The witness does not ride
in Safe's signatures argument: that tail belongs to the policy engine's context
extension, which allows one extension per blob. On execution the guard emits the
portable evidence; destinations receive that and the witness, not Safe's executing
signatures. Updates therefore execute as multicall([stageUpdate, execTransaction])
through any multicall contract. It is not pinned: skipped or wrong staging only makes
the guard revert, and transient data ends with the transaction. A plain
execTransaction, as the Safe UI sends it, reverts for lack of staged data; owners can
still sign there.

selectAuthority changes A's tracked graph (for example its B snapshot), without a
source owner mutation. It is a normal Safe transaction, executed on source, and it
advances the same linked source head. No private key belongs to a Safe contract;
owners sign the SafeTx digest.

Every operation passes two signature checks on source. Safe's own check counts each
child's live owners. The guard's portable check is the destination check: A's
selected graph, with each descendant counted under the position the update names.
One signature set normally passes both. They differ when a child rotates between
its vote and A's quorum. Then the child's live owners sign for execution, and the
earlier set is staged as portable evidence outside the signed SafeTx. The guard
verifies that set and emits it as the evidence destinations receive. This keeps
source able to execute whatever destinations would accept.

For every descendant position an update names, the guard requires a head that Safe
executed on source, at or after the position A stores. The guard records a head
only when that Safe's update executes, so the executed list on source has no
forks. The check covers any executed head, not only the descendant's current one:
a later rotation by B does not revert A's adoption of an earlier executed position.

An ownership change is one signed Safe transaction:

| Part | Required behavior |
| --- | --- |
| Outer SafeTx | DELEGATECALL the pinned MultiSendCallOnly, value zero. Its SafeTx hash is the new head. |
| First packed call | CALL guard.registerOwnershipChange(update). |
| Remaining packed calls | At least one ordered owner mutation: each a zero-value CALL to the signing Safe of addOwnerWithThreshold/removeOwner/swapOwner/changeThreshold. No inner delegatecall, external target or configuration change. |
| Pre-hook | Recognize this exact shape; verify the staged witness and portable evidence; derive every intermediate owner list and check its predecessor/sentinel, insertion order, threshold and 16-owner cap; require the result to equal the root record of the new graph. |
| Post-hook | Require actual ordered owners/threshold to equal that record; set the source selection/head and record the head as executed. |

MultiSendCallOnly's inner CALLs originate from the Safe context, satisfying Safe's
self-call requirement. The source quorum is checked once, before the batch;
intermediate threshold changes do not request new signatures. One batch advances the
linked head once. Because registration and mutation are one SafeTx, a failure reverts
both together with the nonce, and nothing spans two transactions. Updates of several
Safes may share one outer transaction. The pre-hook allows this exact ownership batch
as the only exception to the existing MultiSendCallOnly self-call ban; other batches
stay blocked, and no generic allowance for Safe self-targets is implied.

Source execution, cancellation and nonce consumption do not revoke a signed update's
portable authorization. A helper's ability to execute batches does not itself
validate a linked authority update.

## Parent responsibility and accepted authorization

Only A's explicitly signed graph update changes A's tracked children. Independent
B source changes or B's own selected entry do not. B has no global identity inside A
and there is no default to B's state: nothing B does reaches A's graph. To adopt B's
new owners, A's quorum signs selectAuthority for a graph holding B's new record and
position. B's own updates ride in that update as the child updates proving the
position; A may equally keep B where it is or drop B. Anyone may carry A's
signed update to a destination, but acceptance needs A's selected quorum. In the
#109 nested example (B rotates while A executes nothing, then A dispatches), A signs
selectAuthority before dispatching under B's new owners. A must adopt authenticated stricter
child snapshots before authorizing further A transactions (D94). A must likewise
install its own authority changes on relevant receivers before signing further
application transactions (D96). These are operational responsibilities, not automatic
source freshness checks. Until installation, old stored owners/thresholds remain
eligible, including lower thresholds. This stale-authority risk is accepted.

All fresh approvals use the selected graph, with native per-node thresholds and
child-domain SafeMessage hashing. No global/local fallback or opportunistic child
adoption is permitted. Child records need authenticated activation or child-update
witnesses; A selects authentic states, not invented child owners.
Removed keys cannot authorize a new branch after the receiver replaces them unless
they still satisfy its selected quorum.

A must not adopt a child position the child signed but did not execute on source.
A's owners sign an adoption only after the child's update has executed there. The
source guard enforces this. A destination cannot: source signatures prove
authorization, not source execution/time/deployment, so both a child's abandoned
update and A's adoption of it would verify. On destinations the rule rests on A's
signers, and the registry treats every position in A's graph as executed. Breaking
it is permanent for that child: its real later positions do not descend from the
abandoned one, so A could never reach them.

Two trust assumptions follow, and they differ by role. For the root: once an update
has a quorum destinations would accept, A executes it on source and does not reject
or replace it. A root that breaks this is a broken multisig, which the design does
not protect. A child's earlier vote counts toward that quorum even if the child has
since rotated, so A cannot withdraw an update after a child misbehaves. A executes
it and corrects with a new update. For a child: nothing is assumed. B may sign an
update and abandon it, or sign two at one nonce. That gives B no more than its
native veto. B can make its own vote unusable on source, which blocks A only when A
cannot reach threshold without B. B cannot reach a destination quorum alone, and
forking its own registry entry harms only B as a root.

A lagging or new destination accepts any valid successor of its stored head,
including one signed by a retired quorum; the first accepted wins (T5) and the loser
cannot overwrite it. A destination cannot know what executed on source, so one
captured this way stays on that branch and no recovery bypass exists (Y2, Y3). A new
destination starts from the signed activation and applies the full linked chain,
possibly in one batch; there is no latest-state shortcut. Update calldata and
registry events are archived off-chain so late destinations can bootstrap; the
registry stores only receipts and the graph cache.

Accepted receiver commitments survive root and nested ownership changes (D92).
Finalize uses the recorded exact-call authorization without a fresh signature check
or hash/head equality requirement. Preserve explicit cancellation, repeat approval
accounting, atomic whole-array execution and consumption/replay checks. Anyone may
finalize before a later cancellation; survival does not promise target-call success.
Unaccepted off-chain signatures still face current selected-authority checks on first
submission. Returning to an old graph may restore old unexecuted approvals if their
normal nonce/window checks pass, but never restores consumed/cancelled work.

## Activation and creation proof

A Safe's authority starts from its Safe creation proof:

```solidity
struct SafeCreationProof {
    address factory;
    address singleton;
    bytes initializer;
    uint256 saltNonce;
}
```

The factory, the singleton and the proxy creation code hash must be pinned for the
source chain. The verifier recomputes the Safe's CREATE2 address with both Safe 1.5.0
factory salts, keccak256(keccak256(initializer), saltNonce) and the chain-specific
keccak256(keccak256(initializer), saltNonce, sourceChainId); a match on either proves
the initializer. The initializer must be Safe's setup with to and data either empty
or exactly SafeToL2Setup.setupToL2 with the pinned L2 singleton, because setup's
delegatecall could otherwise change owners, modules or the guard. The creation record
is setup's owners and threshold, with owner kinds from the graph. The fallback handler
and payment fields carry no authority and are not checked here. A creation proof
proves a starting configuration, not deployment, current authority or activation.
Other chain-specific derivations need explicit support, not substitution into these
formulas.

Activation takes two guarded steps, which may share one outer transaction. The Safe
first sets the guard; the guard cannot hook the transaction that installs it, and
until activation it allows only activate. The creation quorum then signs and executes
activate(update, creation) with update = (0, 0, initialGraphHash). The guard requires:

- transaction and module guards, recognized singleton/handler/module configuration
  and handler matching (X11);
- live owners and threshold equal to the creation record, so a Safe that has changed
  owners cannot activate;
- every Safe owner already activated, and the initial graph naming each descendant at
  a position that Safe executed, with its record proven by the staged witness;
- the portable check under the creation record, each descendant counted under the
  position the initial graph names.

The activation's SafeTx hash is the Safe's first head, recorded as executed. The
initial graph can therefore name each Safe owner at its current position, not its
creation state, and every destination registers the same graph because the creation
quorum signed it. Two activations signed at one nonce compete like any successors;
the first accepted wins on each destination (T5).

A destination registers a root with its signed activation and witness, verified like
an update whose old graph is empty and whose root votes under the creation record. A
parent adds a Safe with the same activation as that Safe's first child update.
Destination registration cannot fabricate native source readiness.

## Invariants and resource behavior

Block unregistered owner changes, guard/handler replacement, module
self-calls/delegatecalls and protected-configuration bypasses. Pin approved helper
code/configuration: helper, singleton and handler pins are fixed at
guard deployment, with no setter and no owner or governance override (X13). Changing
one means a new guard, and guard migration is outside this design.

Every stored graph is acyclic. The guard checks each activation and update graph on
source and the registry checks it on every destination, using the stored owner kinds.
A graph changes only when its root signs an update, so no stored graph holds a cycle
whatever live ownership does; a live cycle only blocks the adoption that would store
it. Acyclic graphs make every nested proof finite. A shared child may still sign
several digests, each verified separately, and no unresolved claim counts as an
approval.

An owner added while its address has no code can only be EOA-kind: a Safe-kind owner
needs an activated record. If a Safe is later deployed at that address, stored records
keep it EOA-kind until its Safe swaps it out, so its contract signatures never count
for that Safe on source or destinations (Y10). The guard cannot tell an undeployed
address from an EOA. Tooling should warn signers who add an address that may be an
undeployed Safe.

Reject portable v=1 and contract signatures for EOA-kind owners,
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
this scaffold. Other home-contract authority (such as a DAO) is rejected at
registration and no adapter is added; a later one needs separate portable proof
support, not a bridge assertion. Nothing from #108 is deployed, so receivers adopt the
shared registry directly with no migration from fixed creation authority.

No freeze, equivocation-evidence submission or unfreeze role is designed. A freeze
below the selected quorum is a new authority, on a lagging destination the freezing
quorum may be a retired one, and unfreezing needs a recovery role this design does
not have. Conflicting successors are handled by first-accepted.
