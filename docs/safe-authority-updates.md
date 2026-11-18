# Safe authority updates

Design and draft interfaces for [#109](https://github.com/crossecute/protocol/issues/109).
Extends [signed dispatch](safe-signed-dispatch.md) and the
[Safe guard](safe-guard-design.md). This file owns architecture and normative behavior;
[verification](safe-authority-verification-review.md) owns implementation gates/tests,
[review findings](planning/safe-authority-review-109.md) own security disposition, and
[benchmarks](benchmarks/authority-109/README.md) own measurements/reproduction.

**Status:** the source guard implements activation, ownership changes, selectAuthority and
the protected-call rules, tested against real Safe 1.5.0 proxies. The receiver authority
library, which the guard also runs, authenticates graphs, child updates and votes, and
source-call recognition is one library shared by both. Signed receivers seed their authority
from bootstrap, accept direct linked updates and verify application dispatch against the
selected graph. Quote and bootstrap check the supplied witness against the source guard.
Provider authority relay/quote adapters and exact authenticated provider retries are implemented.
SDK execution tooling, checkpoint/recovery tooling and deployment validation remain. No deployment is claimed. The
[verification plan](safe-authority-verification-review.md#scaffold-coverage-and-remaining-work)
lists what remains.

## Receiver authority, seeded by bootstrap

Each signed receiver holds its source Safe's authority in its own storage:

```solidity
struct AuthoritySelection {
    bytes32 updateHead;
    bytes32 authorityHash;
}
```

with the selected graph and the records it names. A Safe's receivers on one
destination, one per provider, share no state. Each starts from its own bootstrap and
applies the same portable updates independently; shared state would let the least
trusted provider seed every receiver (#148).

A receiver starts from its bootstrap. The Safe's transmitter sends the guard's current
selection: its updateHead and the selected graph. The bootstrap caller supplies the
graph, and the transmitter requires its hash to equal the guard's
selection(safe).authorityHash, so the graph matches the head without a guard graph-readback
entry point. A signed bootstrap reverts until the Safe has [activated](#activation). The
destination stores the head and graph on the provider's and source transceiver's
authentication: signatures cannot prove a carried graph. Owners confirm a receiver's
selection and graph before relying on it. The root's record equals its live owners,
since the guard keeps them equal; each descendant appears at the position the root
last adopted, which can lag that Safe's live state.

The signed bootstrap payload body is `abi.encode(SignedBootstrap(guard, updateHead,
abi.encode(authorityGraph), setupCalls))`, where setupCalls is `abi.encode(Call[])`.
Both quote and send require guard to be the Safe's installed transaction guard and
the head and graph hash to equal its selection. Destination initialization checks guard
against the receiver implementation's immutable pin. An encoded graph byte string keeps
the legacy compiler's bootstrap decoder within its stack limit; its extra 64 bytes avoid
changing the compiler pipeline and Proxy initcode. Relative to #108's record-only body,
the body grows by `160 + 64n` bytes for n graph nodes with the same records and setup calls.
The graph remains variable-size because every reachable Safe and selected child position
must be authenticated. Plain bootstrap encoding is unchanged.

updateHead identifies the last accepted signed update, not the owner graph. There is
no independently advancing global child authority and no authority counter. A
receiver keeps no version history. The source guard keeps the set of update heads
each Safe has executed, as hashes only, to check [child positions](#child-positions).

The source identity is (source chain, Safe). Each graph has one root Safe, ordered
Safe records and each node's owners/kinds/threshold. Canonical depth-first traversal
emits each reachable Safe once in owner order and rejects cycles, the same rule and
traversal as #108's SafeAuthorityGraph. SafeOwner and SafeAuthorityRecord
reuse existing signed-dispatch types, and Call reuses messaging/Call.sol. The first
node is the root: it identifies the graph owner, not the current node while
recursively checking signatures.

For A -> B -> C with A -> C, A's graph has root A and records A/B/C. B and A point to
the same C record. B's own selected graph and C's own selected graph are independent
entries; their B snapshots can differ from A's authenticated B snapshot. No dynamic
lookup of B's root selection may change B inside A. Next to each descendant record,
A's graph stores that Safe's [position](#child-positions). Each of A's receivers holds A's
selected hash on its own.

The graph hash covers one entry per Safe: the hash of that Safe's SafeAuthorityRecord
and its position. A receiver stores each record once under its hash and the graph as its
entry list, so an update writes only the records it changes plus 64 bytes per Safe.
Graph data can also be supplied against the selected hash. Caches of authenticated
child states may anchor later transition proofs; a cache entry never chooses a
parent's authority. A late receiver needs no past updates, since it starts from the
current head; lost source lineage still needs durable copies of past updates (Y7/Y8).

## Linked, universally reusable updates

```solidity
struct AuthorityUpdate {
    bytes32 previousUpdateHash;
    bytes32 newAuthorityHash;
}
```

previousUpdateHash is the predecessor's SafeTx hash, which commits to that update's
graph hash, so the previous graph hash is not signed again.

A's currently selected full quorum signs the exact recognized source transaction: a
guard call, or for an ownership change the pinned MultiSendCallOnly batch that starts
with one. The SafeTx binds the source Safe/source EIP-155 chain, target, selector,
arguments and ordinary SafeTx fields. No destination chain ID, receiver address or
provider is in the authority-update payload. The same evidence is valid
on current and future destination chains for that source identity, subject to their
own predecessor and quorum checks. Universal evidence is not automatic
delivery, source execution proof or universal branch convergence.

A new update follows the stored updateHead exactly.
Its update identifier is the SafeTx hash of the signed activation, ownership change
or selectAuthority transaction, not a receipt, outer executor hash or hash of
signatures. The next update signs that identifier as previousUpdateHash. A Safe's
first head is its [activation](#activation) SafeTx hash; the activation signs only its
initial graph hash, as it has no predecessor. Destinations never receive activations:
a receiver starts from the head its bootstrap carries.

This linked chain supersedes D93's numeric management nonce watermark. There is no
maximum-forward-gap rule: the proposed 2^16 gap was paused before adoption and is
unnecessary for linked ordering. Safe nonces remain signed and enforced on source,
but destination ordering compares predecessor hashes, not numeric magnitudes. A
very large signed nonce cannot numerically freeze subsequent lower-nonce linked
updates. A graph returning to an earlier hash has a different update head.

To accept a destination update:

1. Load the receiver's selection and require an idle shared context.
2. Decode the actual signed source calldata and recognize its target/function: an
   ownership change or a selectAuthority. An activation is rejected.
3. Check signed previousUpdateHash == stored updateHead, and reject a wrong predecessor
   even if old/new owners overlap.
4. Recompute the complete new graph hash and authenticate canonical structure, the
   16-owner cap, thresholds, owner kinds, the root's new record (its stored record after
   the signed mutations for an ownership change, its stored record unchanged for a
   selectAuthority) and every descendant [position](#child-positions): a retained one
   kept or reached from the stored one through the supplied child updates, an added one
   as the new graph names it.
5. Validate the portable signatures/nested quorum. The root votes under its stored
   record. Each descendant votes under the position the new graph names for it.
6. Atomically store new records and the graph and set the new hash/head. Validation
   failure must leave no head or other state.

U2 cannot precede U1 if it names hash(U1). Consecutive handoffs may be submitted in
one batch, but each is independently verified. The predecessor check also rejects
replays, so a receiver keeps no history of accepted updates: each head commits to its
predecessor, so heads never repeat and an accepted update never matches the stored
head again, even after the graph returns to an earlier hash. Direct duplicates reject.
A provider retry of the exact current accepted submission is an authenticated no-op,
as specified below. Conflicting signed successors of one head are possible. Each
destination can accept only one; the losing successor cannot overwrite it. The chain
does not prove which successor executed on source. Restoration requires valid
authorization under the currently selected branch, not a special old-owner override.

Updates carry no expiry. A signed update stays valid until its predecessor is
superseded, even if its SafeTx is rejected or replaced on source (Y4). Tooling must
tell source rejection apart from destination revocation.

## Authority transport and publication

The source guard emits `AuthorityPublished(sourceSafe, updateHead, submission)` for
an executed ownership change or selection, alongside `AuthorityUpdateExecuted`.
`submission` is exactly `abi.encode(SafeTxEvidence, AuthorityGraph, ChildUpdate[])`,
using the staged portable signatures and nested approvals, never the source execution
signature set. `publishedAuthority(sourceSafe, updateHead)` retains its keccak256 hash.
Activation publishes no relayable submission. Publication and all its writes revert if
source execution fails. Calldata and events provide archival inputs, but a durable
archive and checkpoint recovery tooling remain separate work.

Anyone may call `relayAuthority(recipient, submission, attributes)` on a signed
transmitter. `quoteAuthority` takes the same arguments. Both hash the carried SafeTx in
the creation Safe's source-chain domain and require its exact submission hash to be
published on the Safe's installed guard. They share route validation and wire building:
`abi.encode(WIRE_AUTHORITY, submission)`, with tag 3. The recipient must be this conduit's
reachable receiver. Destination and delivery attributes are unsigned routing choices;
they do not change the universally reusable authority evidence. No live-owner signature
check or nested-approval recollection replaces the published portable set. A caller may
relay the same update to several destinations or retry a failed delivery. Each relay is
caller-funded, preserves the transmitter's prior balance, refunds synchronous excess to
the caller and routes provider refunds to that caller under the shared leaf-relay lock.

Provider delivery first passes gateway, origin and source-transmitter authentication.
The authority adapter then runs the same recognition, graph, quorum and predecessor
verification as direct `submitAuthority`, under the receiver's shared execution lock.
Direct submission does not require source publication: portable authorization remains
distinct from source execution. Both paths store the hash of the exact accepted
submission in one receiver slot. A provider delivery whose submission equals that hash
emits `DuplicateMessage` without advancing authority. A matching head alone grants
nothing: changed signatures, approvals, graph or child updates must pass ordinary
verification and fail the predecessor check for an already accepted head. Bootstrap
stores no submission hash, so carrying its head does not authenticate a retry. Accepting
a successor replaces the hash; earlier accepted submissions reject. Direct replays
continue to reject. Application-message and leaf duplicates still verify against the
currently selected graph before their existing replay checks.

The guard adds one 32-byte hash per published source head. Each receiver adds one
32-byte current-submission hash, with no update history. The authority wire adds 96
ABI bytes around the standard submission tuple. The publication event carries that
whole tuple, including the variable-size graph, child updates and portable evidence,
because independent relayers must recover the exact bytes the guard verified. No new
size cap is added; provider and VM limits still apply.

### Atomic receiver catch-up

`submitAuthorityBatch(bytes[] submissions)` takes a nonempty list of standard authority
submission tuples, each `abi.encode(SafeTxEvidence, AuthorityGraph, ChildUpdate[])`.
It holds the same receiver lock for the whole list. Each entry extends the selection the
entry before it wrote and verifies under that predecessor's quorum. Any failed signature,
graph, predecessor, decode or out-of-gas failure reverts the whole batch, including new
cache entries, events and the exact-submission hash. Direct batch replays reject; a
provider retry of the exact last accepted entry follows the existing acknowledgment rule.
Both direct ABIs keep their nested decoders in the linked transport library, which also
handles provider submissions. No application or finalization call runs between entries.

The batch calldata costs `68 + 64n + sum(tuple lengths)` bytes for n entries, including
the selector. Separate direct calls cost `4n + sum(tuple lengths)` bytes but require n
transactions. The extra array offsets and lengths avoid repeating the verifier in each
receiver and keep the existing singular ABI. No batch-count or total-evidence cap is added;
callers must simulate the full catch-up against their receiver's selected head.

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
descendant's own receivers' state, which can lag or sit on another branch. An
ownership-change update changes the descendant's record to the result of its signed
mutations. A selectAuthority update moves the position only. A child update is never an
activation: a retained descendant's stored position is already at or after it. One A update may move a
descendant forward by several child updates. An update that keeps a position needs
none.

A descendant's signatures on an update count under the position that update names
for it. An update that keeps B's position is voted by B's stored owners. One that
moves B forward is voted by the owners the child updates prove. The root always votes
under its stored record (T6). Adopting B's rotation therefore never needs B's removed
owners. A returning owner set (X, Y, X) is a new position, so an old child update
cannot be replayed. A Safe owner that an update removes has no position in it, so its
signatures on that update do not count; a removed EOA owner still votes. To remove a
Safe owner whose vote it needs, a Safe first lowers its threshold.

The same rule applies inside a child update. If B's update needed a vote from B's
own Safe owner C, C counts under the position B's new graph names for C, as B's guard
counted it on source. A's verifier therefore proves positions in one flat pass over
child updates at any depth. It keeps a table of proven (Safe, position) records,
seeded with A's stored entries. Each child
update, in the order supplied, needs its predecessor and every nested voter's position
already in the table, then adds its own result. Each carries its new record and its
new graph's entry list. The list's first entry must be the record's hash and the list
must hash to the newAuthorityHash it signs, so the verifier can read its voters'
positions and the kinds of the owners it adds. An ownership change must turn the
predecessor record into the new record, and a selectAuthority must keep the
predecessor record. Every owner kind in a new record must be EOA or Safe. Every entry
of A's new graph for a retained Safe must end in the table, descending from its stored
position; an entry for an added Safe is taken as named. Every supplied
child update must be used, by A's new graph or as a later child update's predecessor
or voter, and none may repeat a position already in the table. Positions are proven
only forward from A's stored ones, so if C voted in B's update at a position behind
the one A now stores for C, A cannot adopt that B update: B signs a fresh update under
C's current owners, or A removes B and adds it again at the named position.

A Safe [activates](#activation) the guard before any parent adds it. A new graph that
adds a Safe, or re-adds one it removed earlier, names that Safe's record and position
directly. Destinations take it on A's signers, the same trust they place in A for
every executed position; the source guard requires the named position to be one that
Safe executed and the record to be its record there, so a Safe that never activated
cannot be added. A re-added Safe has no stored position to compare against, so any
executed position may be named, including one earlier than where it was removed. An
added Safe cannot vote on the update that adds it, since votes come from owners of the
root's stored record and positions already proven, so naming its record grants its
signers nothing on that update.

Each update travels with two unsigned arguments, the same on source and
destinations: newGraph, which must hash to the signed graph hash, and childUpdates,
which prove its positions.

```solidity
struct AuthorityNode {
    SafeAuthorityRecord record;
    bytes32 position;                  // zero for the root
}

struct AuthorityGraph {
    AuthorityNode[] nodes;             // canonical order; nodes[0] is the root
}

struct AuthorityEntry {                // the hashed form of one node
    bytes32 recordHash;
    bytes32 position;
}

struct ChildUpdate {
    address sourceSafe;
    SafeTxEvidence evidence;           // the child's ownership change or selectAuthority
    SafeAuthorityRecord newRecord;     // its new record; hash == newGraphEntries[0].recordHash
    AuthorityEntry[] newGraphEntries;  // its new graph; hash == its signed graph hash
}
```

A descendant kept at its stored position needs no child update. One moved forward has
child updates from the stored position. One added needs none. Voters that child
updates need are proven the same way. newRecord costs 32 x (5 + 2n) bytes for an
n-owner child; it carries the kinds of owners an ownership change adds, which hashes
alone do not.

## Source guard and mutation batch

The operations belong to the shared deterministic guard, not a separate authority
manager. The guard fixes its pins at deployment, with no setter (X13): MultiSendCallOnly,
SignMessageLib, the Safe and SafeL2 singletons and the fallback handler. Destination
implementations take the guard and MultiSendCallOnly addresses as constructor immutables,
with no setter. These pins apply to every receiver using that implementation. Both pins
unset permit plain mode only; setting just one is rejected. There is no destination registry
contract. A chain without the canonical MultiSendCallOnly is unsupported until a new
generation.

Each Safe's authority state is the receivers' own: the guard keeps a `ReceiverAuthority`
state per Safe and runs the receivers' verification on it, so source and destinations accept
the same updates. The guard adds the source-only facts: each Safe's executed heads with the
record at each, the Safe's live configuration, and the rules for its calls.

```solidity
activate(bytes32 authorityHash)
registerOwnershipChange(AuthorityUpdate update)
selectAuthority(AuthorityUpdate update)
stageUpdate(
    address sourceSafe,
    AuthorityGraph newGraph,
    ChildUpdate[] childUpdates,
    bytes portableSignatures,          // always the full set destinations verify
    NestedSafeApproval[] nestedApprovals
)
selection(address sourceSafe) -> AuthoritySelection
executed(address sourceSafe, bytes32 updateHead) -> bool
```

The signed calls carry hashes only. stageUpdate, called earlier in the same outer
transaction, supplies the new graph and child updates those hashes commit to and the
signatures destinations verify. portableSignatures is always supplied, even when it
equals the executing signatures; nestedApprovals are the signed signMessage
transactions behind empty nested signatures. Anyone may call it. The guard holds the
data in transient storage for that Safe's next guarded transaction, under its
per-Safe nesting lock (X10). It does not ride in Safe's signatures argument: that tail
belongs to the policy engine's context extension, which allows one extension per
blob. On execution the guard emits portableSignatures and nestedApprovals;
destinations receive those with newGraph and childUpdates, never Safe's executing
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
earlier set is staged as portableSignatures outside the signed SafeTx. The guard
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
| Pre-hook | Recognize this exact shape; verify the staged graph, child updates and portable signatures; derive every intermediate owner list and check its predecessor/sentinel, insertion order, threshold and 16-owner cap; require the result to equal the root record of the new graph. |
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

The guard does the work in the pre-hook, before the Safe executes: it recognizes the call,
takes the staged data, verifies it, writes the new selection and executed head, and sets a
live record for the Safe. activate, registerOwnershipChange and selectAuthority are markers
the Safe calls during execution; each reverts unless the pre-hook recognized the calling
Safe's transaction as that kind. The post-hook requires the executed hash to be the
recognized one and the Safe's final owners and threshold to equal the stored root record. A
failure anywhere reverts the whole SafeTx, so the selection, the head and the nonce move
together or not at all.

### Protected calls

Once a Safe has activated, the guard refuses these owner transactions whatever the Safe's
policies allow, so its owners, threshold, guards, handler, modules and singleton change only
through a recognized update:

- any call to the Safe itself;
- any delegatecall except to the pinned MultiSendCallOnly and SignMessageLib;
- a MultiSendCallOnly batch with a call to the Safe itself, other than the one ownership
  batch.

A Safe's own live record, authority or staged call, rejects any further owner transaction of
that Safe in the same outer transaction, and stageUpdate for it. A Safe that has not
activated is governed by its policies alone, as in #107.

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
adoption is permitted. A retained descendant moves only through its own signed child
updates; a Safe A adds is taken as A's new graph names it, on A's signers.
Removed keys cannot authorize a new branch after the receiver replaces them unless
they still satisfy its selected quorum.

A must not adopt a child position the child signed but did not execute on source.
A's owners sign an adoption only after the child's update has executed there. The
source guard enforces this. A destination cannot: source signatures prove
authorization, not source execution/time/deployment, so both a child's abandoned
update and A's adoption of it would verify. On destinations the rule rests on A's
signers, and a receiver treats every position in A's graph as executed. Breaking
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
forking its own receivers' state harms only B as a root.

A lagging receiver accepts any valid successor of its stored head, including one
signed by a retired quorum; the first accepted wins (T5) and the loser cannot
overwrite it. A destination cannot know what executed on source, so a receiver
captured this way stays on that branch and no recovery bypass exists (Y2, Y3). A new
receiver starts from the head and graph its bootstrap carried, so a retired quorum
can neither seed it nor capture it before it exists: only successors of that head
apply. Update calldata and guard events are archived off-chain for lagging receivers;
a receiver stores its selection, graph cache and one exact current-submission hash for provider retries.

Accepted receiver commitments survive root and nested ownership changes (D92).
Finalize uses the recorded exact-call authorization without a fresh signature check
or hash/head equality requirement. Preserve explicit cancellation, repeat approval
accounting, atomic whole-array execution and consumption/replay checks. Anyone may
finalize before a later cancellation; survival does not promise target-call success.
Unaccepted off-chain signatures still face current selected-authority checks on first
submission. Returning to an old graph may restore old unexecuted approvals if their
normal nonce/window checks pass, but never restores consumed/cancelled work.

## Activation

Activation takes two guarded steps, which may share one outer transaction. The Safe
first sets both guards; the guard cannot hook the transaction that installs it. The Safe's
quorum then signs and executes activate(initialGraphHash) with the initial graph staged.
Until then the Safe is governed by its policies alone, as in #107, and no authority rule
applies: activation reads live state, so an owner change before it cannot desynchronize the
guard. The guard requires:

- the guard in both the transaction and module guard slots, the singleton equal to a
  pinned Safe or SafeL2 singleton, the fallback handler equal to the pinned handler and no
  enabled module (X11). After activation a call to the Safe itself is refused, so no
  module can be enabled later;
- the initial graph's root record equal to the Safe's live owners, in `getOwners()` order,
  and threshold, so a Safe that has changed owners since creation can activate;
- every named descendant at a position that Safe executed, with its record there. A Safe
  owner that has not activated has no executed position, so this also requires every Safe
  owner to be activated;
- the portable check under the root's live record, each descendant counted under the
  position the initial graph names.

The activation's SafeTx hash is the Safe's first head, recorded as executed. The initial
graph names each Safe owner at its current position. No creation proof is checked:
destinations never receive an activation, since each receiver starts from the head and
graph its bootstrap carries.

Activating a Safe automatically on its first guarded transaction, with no signed step, was
evaluated (#148) and is not adopted. The guard would have to derive the initial graph. A Safe
owner that has not activated would either block the Safe's unrelated transaction or be
recorded EOA-kind, which silently drops that owner's contract signatures from every later
quorum. The first head would also be an arbitrary transaction's hash, and the portable check
would run on a transaction that was signed for something else. A separate activation costs
one transaction, makes the owners state the graph, and fails before any parent depends on
it.

## Invariants and resource behavior

Block unrecognized owner changes, guard/handler replacement, module
self-calls/delegatecalls and protected-configuration bypasses. Pin approved helper
code/configuration: helper, singleton and handler pins are fixed at
guard deployment, with no setter and no owner or governance override (X13). Changing
one means a new guard, and guard migration is outside this design.

Every stored graph is acyclic. The guard checks each activation and update graph on
source and every receiver checks it, using the stored owner kinds.
A graph changes only when its root signs an update, so no stored graph holds a cycle
whatever live ownership does; a live cycle only blocks the adoption that would store
it. Acyclic graphs make every nested proof finite. A shared child may still sign
several digests, each verified separately, and no unresolved claim counts as an
approval.

An owner added while its address has no code can only be EOA-kind: a Safe-kind owner
needs an activated record. If a Safe is later deployed at that address, stored
records keep it EOA-kind until its Safe removes or swaps it out, so its contract
signatures never count for that Safe on source or destinations (Y10). An owner
removed and added again, even within one ownership batch, takes the kind the new
record names. The guard cannot tell an undeployed address from an EOA. Tooling should
warn signers who add an address that may be an undeployed Safe.

Reject portable v=1 and contract signatures for EOA-kind owners,
including EIP-7702 delegated EOAs. Do not flatten quorums or count a signer twice
within one Safe's threshold. Cache only fully verified exact-message claims.

The portable check is #108's signature walk, shared with its receiver; only the
source of each Safe's owners and threshold differs. As there, two nested approvals
for the same child and message reject, and one that no empty nested signature needs
is ignored: it is never counted or stored, and a signature blob can carry unread
bytes in any case. A Safe with a zero threshold has no quorum.

Each Safe has at most 16 immediate owners: in every graph and child record and at
every step of an ownership change, so a Safe with more cannot activate. No
aggregate owner cap, nesting-depth cap, evidence-size cap or verification-work/gas
budget is added (D95). VM/chain/provider limits still determine completion and
relayability. Preserve terminating traversal and atomic failure; no promise of
unlimited practical execution or data availability.

Keep immutable conduit creation identity, routing and application replay records
through every authority update/cache cleanup. Freeze the shared authority context
during application verification/execution across all provider and direct entry
points. Application leaves/callbacks cannot act as management bypasses. Ordinary
execution never refreshes child snapshots or advances updateHead. Emergency/admin
recovery, guard migration, custom validators, zkSync/Tron and signed OFT are outside
this scaffold. Other home-contract authority (such as a DAO) has no signed mode
and no adapter is added; a later one needs separate portable proof support, not a
bridge assertion. Nothing from #108 is deployed, so receivers hold their authority
directly with no migration.

No freeze, equivocation-evidence submission or unfreeze role is designed. A freeze
below the selected quorum is a new authority, on a lagging destination the freezing
quorum may be a retired one, and unfreezing needs a recovery role this design does
not have. Conflicting successors are handled by first-accepted.
