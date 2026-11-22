# Safe guard

The Safe guard a conduit owner installs so that its transmitter can attach the owners'
signatures to a `sendMessage` and accept a signed `bootstrap` only from an owner transaction, and so that a child Safe's approval of a parent transaction
leaves evidence a receiver can check. Tracked in
[issue #107](https://github.com/crossecute/protocol/issues/107).

**Status.** Implemented and tested in [`contracts/safe-guard/`](../../contracts/safe-guard/), a
separate Foundry project, against real Safe 1.5.0 proxies. The protocol's signed transmitters
consume it and its receivers verify what it hands out
([#108](https://github.com/crossecute/protocol/issues/108),
[`safe-signed-dispatch.md`](safe-signed-dispatch.md)); the guard's own tests drive a minimal
test transmitter, and an end-to-end test joining the two is
[#134](https://github.com/crossecute/protocol/issues/134). Authority updates are
[#109](https://github.com/crossecute/protocol/issues/109).

**Where the reasoning lives.** As in [`message-flow.md`](../architecture/message-flow.md), each decision is
argued in the NatSpec of the contract that implements it. This file says what the pieces are
and how they connect. Where the two disagree, the contract is right.

## Authority updates (#109)

[`SourceAuthorityGuard`](../../contracts/safe-guard/src/authority/SourceAuthorityGuard.sol)
handles Safe activation and ownership mutations for `CrossecuteGuard`. See the
[authority design](safe-authority-updates.md#source-guard-and-mutation-batch) for graph
witnesses, deployment pins, and the ownership batch, and
[activation](safe-authority-updates.md#activation) for setup and guard-slot requirements.

## Decisions

These are settled. The sections below describe each in full.

- **Safe version.** Safe 1.5.0 only. Earlier versions have no module guard.
- **One guard.** A single shared `CrossecuteGuard` extends `SafePolicyGuardBase` and reuses its
  `PolicyEngine`, with all state keyed by Safe. `SafenetPolicy` is a policy a Safe may select,
  not part of the guard. The guard registers, forwards to, and delegatecalls no other guard.
- **Guard slots (#107 baseline).** The transaction guard slot is required. The module guard slot is the
  multisig's choice; leaving it empty trusts enabled modules with their Safe permissions.
- **Staging.** An owner transaction whose top-level selector is `sendMessage(bytes,bytes,bytes[])`
  or `bootstrap(bytes,bytes[])` is staged, whatever its target or operation. Both write the same
  staged record. The complete signature blob is staged, with no size cap. Unsigned protocol
  transmitters use the same bootstrap selector and leave the record for the post-hook to clear.
- **Leaf publication.** Anyone can publish a Merkle tree's ordered, encoded leaves to the guard,
  which records the root and emits one event per leaf. The owner pre-hook checks publication
  when `registerRoot(bytes32)` is the top-level Safe call. It stages nothing for registration.
- **Consumption.** `consume(address safe)` is callable only by the signed target, once. The
  transmitter does not compare calldata or value with the record; the direct call from the Safe
  delivers what the owners signed.
- **Guard discovery.** The transmitter reads its owner Safe's transaction guard slot on every
  `sendMessage` and `bootstrap`. It pins no guard address and never falls back to an unsigned send.
- **Unconsumed records.** A staged call that nobody consumes succeeds and is cleared in the
  post-hook, including a call to an unrelated contract that shares the selector.
- **Nesting.** Every owner execution holds a per-Safe lock until its matching post-hook,
  even if it stages no record. Same-Safe owner and guarded module reentry rejects.
- **MultiSend.** The pinned executor is accepted only for a recognized authority-change
  batch. Ordinary owner batches and module batches reject, including before activation.
- **No other staging paths.** Module transactions stage nothing. With the module guard installed, a module transaction with either
  staged selector, or with `registerRoot(bytes32)`, is rejected for every target.
- **Approval capture.** A child's direct delegatecall with the `signMessage(bytes)` selector is
  cached after the authority protected-call checks. Before activation the candidate matches
  operation and selector alone; an activated Safe must use the pinned signing library. One
  record per child and message hash; a later approval replaces it; no size cap; `getApproval`
  reads without consuming.
- **Installation.** Fresh and already-guarded Safes install through the standard entry points
  in one owner-approved batch, with no migration-specific API.
- **Chains and build.** Cancun is required for EIP-1153 and is documented, with no installation
  preflight. The guard is a separate Foundry project; `contracts/evm/` keeps its Paris
  target and legacy compiler pipeline.
- **Dependencies and license.** The patched policy engine is vendored from the
  `crossecute/policy-engine` fork, not applied as a patch at build time. Crossecute's guard
  sources are MIT; vendored policy-engine files keep their `LGPL-3.0-only` headers.
- **Out of scope here.** Receiver checks on what the guard hands out, including approved-hash
  (`v = 1`) entries and signing modes, are [#108](https://github.com/crossecute/protocol/issues/108).
  The guard advertises `ICrossecuteGuard` for transmitter mode selection, as well as the
  source-authority, policy and Safe guard interfaces. Authority updates also run the portable
  signature check in the source pre-hook (#109).

## Shape

There is one guard contract, `CrossecuteGuard`. It extends `SafePolicyGuardBase` from
[safe-research/policy-engine](https://github.com/safe-research/policy-engine), vendored from
the [`crossecute/policy-engine`](https://github.com/crossecute/policy-engine) fork. The fork
adds internal callbacks after the owner policy check, after the module policy check, and
after owner execution. The external hooks keep their checks and selectors.

- **Target.** Safe 1.5.0. Earlier versions have no module guard and are not supported.
- **Shared.** One deployment serves any number of Safes. Policy assignments, configuration timing,
  pending configuration, transient staged records and cached approvals are all keyed by Safe.
  Published roots are shared by every Safe on the guard.
- **Policy.** The inherited `PolicyEngine` governs every owner and module transaction.
  `SafenetPolicy` is one policy a Safe may select, not part of the guard.
- **Slots.** Crossecute requires the guard in the Safe's transaction guard slot. Putting the
  same contract in the module guard slot is optional before activation; activation requires
  both slots and no enabled modules (see [Module execution](#module-execution)).
- **No composition.** The guard does not register, forward to, or delegatecall other guards.
  A Safe uses exactly this guard.

The inherited checks still apply: `safeTxGas` and `gasPrice` must be zero, so a failed inner
call reverts the whole Safe transaction, and a Safe transaction may not target the guard
except for the owner configuration and source authority entry points.

## Owner execution

Safe 1.5.0 increments the nonce and checks signatures, then calls the transaction guard's
`checkTransaction`, executes, and calls `checkAfterExecution(txHash, success)` on the guard
it read before execution. After the inherited policy check, `CrossecuteGuard`:

1. Requires no live owner execution for this Safe, then holds its transaction hash
   until the matching post-hook.
2. Runs authority recognition and protected-call checks. A recognized activation or
   update verifies its staged witness and writes its selection and executed head. A successor
   also publishes its submission. The pre-hook stores the transient expected final ownership hash.
3. For other calls, checks publication when the top-level selector is `registerRoot(bytes32)`;
   otherwise stages a `sendMessage`/`bootstrap` record or captures a `signMessage` approval
   according to selector and operation.

The post-hook checks the execution hash and, for an authority operation, final ordered
owners and threshold. It then clears transient records and releases the lock. Any failure
reverts the pre-hook writes with the Safe transaction.

## Transient staged record

Staging matches on the selector alone. It does not check the target, the operation, or the
arguments. The record holds, for the calling Safe:

| Field | Source |
| --- | --- |
| Safe transaction hash | computed with `SafeHashes` from the hook arguments and `nonce() - 1` |
| Signed target | `to` |
| Consumed flag | set by `consume` |
| Value, operation | hook arguments |
| `baseGas`, `gasToken`, `refundReceiver`, nonce | hook arguments and the Safe |
| Signature blob | the hook's `signatures`, byte for byte |

`safeTxGas` and `gasPrice` are not stored: the inherited check requires both to be zero, and
`consume` returns them as zero. The calldata is not stored either: `consume` returns the
transaction as a `SafeTx` with `data` empty, and the signed target fills it from its own
calldata, which the Safe passed it. The signature blob is the complete original `signatures`
argument: owner signatures, any nested contract-signature data with its offsets, and the policy
extension if present. There is no byte cap. Staging, cleanup and the owner-execution lock
cost 16,263 gas for the two-EOA-signature fixture without an extension. Larger blobs add
copying and transient-storage costs; the measured sizes are in
[`contracts/safe-guard/README.md`](../../contracts/safe-guard/README.md#gas). The record lives in
EIP-1153 transient storage starting at a per-Safe id, `keccak256(abi.encode(safe, NAMESPACE))`.

**Not all of the blob is signed.** Safe checks the first threshold-many signatures and ignores
the rest. Whoever submits the transaction can append or change the policy extension, add
further signatures, or add other trailing bytes without invalidating it. The guard stages
those bytes as submitted. A consumer must treat only what it verifies against the owners and
threshold as authorized; the policy extension in particular is executor-supplied context, not
owner-signed content ([#108](https://github.com/crossecute/protocol/issues/108)).

**Consumption.** `consume(address safe)` returns the signed transaction and signature blob for
`safe` when the record is live, not yet consumed, and `msg.sender` is the signed target. It
marks the record consumed and leaves it live. A second call reverts. The stored transaction
hash is not returned: the receiver recomputes it, and a transmitter that needs it can ask the
Safe's `getTransactionHash`.

**Cleanup.** The post-hook clears the record only when its stored transaction hash matches
the hook's `txHash`, then zeroes every slot it used, consumed or not. A successful
selector-matched call that nobody consumed stands, including one to an unrelated contract
that shares the selector. Cleanup does not rely on the end-of-transaction reset, so a second
Safe execution in the same parent transaction starts clean.

**No batch or module staging path.** The pinned MultiSendCallOnly accepts only recognized
authority-change batches, which contain no application sends. Other delegatecalls reject
after activation, and no inner `sendMessage`/`bootstrap` runs the owner pre-hook. Module
transactions never stage a record and the installed module guard rejects both selectors.

## Merkle leaf publication

For a Merkle dispatch ([#108](https://github.com/crossecute/protocol/issues/108)) the Safe signs
only `registerRoot(bytes32)`. Each relay or direct submission carries one leaf and its proof,
so the leaves must be available separately. The ordered leaves are in the input of the
earlier `publishLeaves(bytes[] leaves)` call.

**Publication.** Anyone can call `publishLeaves`, any number of times. Each element is one leaf's
`abi.encode`d fields; the guard does not decode them. The guard hashes each leaf as
`keccak256(abi.encode(keccak256(leaf)))`, builds the tree with #108's rules (an internal node
hashes its children smaller first, a level's unpaired last hash moves up unchanged, and one
leaf is its own root), records the root, and emits `LeafPublished(root, leafHash, index)` for
each leaf in order. An empty list reverts with `NoLeaves`. Records are keyed by root alone, so
one publication serves every Safe on the guard.

**Indexing.** Use the receipt events to find the publication transaction. For a direct call to
the guard, decode the transaction input. For a publication through another contract, use a
transaction trace that exposes the input of the guard call that emitted the events. Match
events to their call if the transaction publishes more than once. Recompute the leaf hashes
and root from that call's ordered leaves before building proofs. A publisher can call the
guard directly to make the leaves recoverable with standard transaction and receipt data.

**Registration check.** In the pre-hook, an owner transaction with the top-level `registerRoot` selector
reverts with `RootNotPublished(root)` unless the guard has recorded the root. The root is the
first word after the selector, as the transmitter's ABI decoder reads it. The revert undoes the
whole Safe execution, so the nonce does not advance and the same signatures can execute after
publication. The guard applies this check to every target with that top-level selector.
The inherited policy governs batched calls.

**Nothing is staged.** The guard keeps no record of a registration's signatures. They are in the
source `execTransaction` calldata, and whoever relays a leaf through the transmitter or submits
it to the receiver supplies them from there.

The signed transmitter in #108 checks its owner Safe's installed guard for publication when
`registerRoot` executes, including when the call is inside a batch. Provider leaf relays use
that source registration. Direct receiver submission verifies the registration's quorum
signatures against stored authority and can proceed without source registration or publication.

**Cost.** Publication execution costs about 56,000 gas for one leaf and about 6,600 gas per
further leaf, plus the leaves' calldata
([`contracts/safe-guard/README.md`](../../contracts/safe-guard/README.md#gas)). The check adds one
storage read to `registerRoot`.

## Transmitter side

A signature-enabled transmitter, called directly by its owner Safe through `sendMessage` or
`bootstrap`:

1. checks that `msg.sender` is its owner Safe;
2. reads the Safe's transaction guard slot with `getStorageAt(slot, 1)`, decoding the reply
   strictly;
3. calls `consume(msg.sender)` on that guard before any other external call;
4. for `sendMessage`, sets the returned transaction's `data` to its own calldata and uses it and
   the signature blob in memory; for `bootstrap`, uses nothing from the record, since consuming it
   is the check that an owner transaction made the call. Either rejects if discovery or
   consumption fails.

It never pins a guard address and never falls back to an unsigned send. It does not compare
calldata or value with the record: the direct call from the Safe already delivers what the
owners signed, and the guard only lets the signed target consume. The minimal transmitter in
`contracts/safe-guard/test/` exercises this flow, and `SignedTransmitter` in `contracts/evm/`
follows it. `ICrossecuteGuard`, `GuardDiscovery` and `SafeHashes` import nothing from the policy
engine and compile under the protocol's Solidity 0.8.28 and Paris settings, so a protocol
transmitter or receiver can import them.

## Nesting

Every owner execution holds a per-Safe transient lock, including calls that stage no
message or authority record. Same-Safe owner and guarded module reentry and stageUpdate
reject until the matching post-hook clears the lock. A post-hook without a live execution
or with another transaction hash rejects. A separately signed execution after cleanup in
the same parent transaction proceeds. Verifying
a nested Safe owner's signature calls that Safe's signature validator, not
`execTransaction`, so it never reaches the owner hook. Execution by a different Safe is
subject to that Safe's own lock and the inherited policy check.

## Module execution

When the Safe puts the guard in its module guard slot, the module callback rejects any
module transaction whose top-level selector is `sendMessage(bytes,bytes,bytes[])` or
`bootstrap(bytes,bytes[])`, whatever the target, and likewise `registerRoot(bytes32)`, which
would otherwise skip the owner hook's publication check. It also rejects the pinned MultiSend
executor and same-Safe module reentry while an owner execution is live. Other module transactions go
through the inherited policy engine, whose
configuration must deny module self-calls and delegatecalls. The policy engine already
refuses configuration changes from modules and any call that targets the guard. Together
these keep a module from changing the transaction guard, the module guard, owners,
threshold, handler, or policy.

Before activation, a multisig may leave the module guard slot empty and keep modules enabled. It then trusts
those modules with their Safe permissions, including any ability to bypass Crossecute's
authority checks. Activation requires both guard slots and no enabled modules; protected
self-call rules keep that configuration fixed afterwards.

## Persistent child approval evidence

A nested parent Safe can accept an empty contract signature from a child owner because the
child's compatibility fallback handler reads the child's `signedMessages` flag. The flag
holds no signatures. To let a receiver check the child's authorization without light clients,
the child's guard keeps the signed transaction that set the flag.

**Capture.** In the child's pre-hook, after policy checks, a `DELEGATECALL` whose selector is
`signMessage(bytes)` is an approval candidate. Before activation the capture check matches
operation and selector without attesting target code. After activation the protected-call
check requires the pinned SignMessageLib target. Safe itself has no built-in allowlist, so an authorized delegatecall
can write any hash, and the handler does not check who wrote it. A cached candidate does not
establish what the delegatecall wrote. A candidate whose calldata does not decode as
`signMessage(bytes)` reverts.

**Key.** The child Safe and the message hash `SignMessageLib.signMessage` writes into
`signedMessages`: the child's EIP-712 hash of `SafeMessage(bytes message)` under the child's
domain separator. A reader can compare it with `signedMessages` on the child.

**Record.** The approval transaction as a `SafeTx` (`to`, `value`, `data`, `operation`,
`safeTxGas`, `baseGas`, `gasPrice`, `gasToken`, `refundReceiver`, nonce) and the child owners'
signatures. `safeTxGas` and `gasPrice` are always zero and are not written. The signatures keep
nested data and offsets and drop the child's policy extension. There is no size cap. The
extension is recognized by its trailing type hash, the same rule the policy engine uses to read
it. Before stripping it, the guard requires the retained prefix to contain every threshold
signature entry and every referenced contract signature's length word and complete payload.
An overlapping extension reverts the approval, preserving the nonce and any earlier evidence.
This also rejects contract signatures whose own suffix resembles an overlapping extension.

**Lifetime.** One record per child and message hash. A later approval for the same pair
replaces it unconditionally, as #107 requires, even when the earlier record was easier to
verify: a re-approval signed partly through approved hashes (`v = 1`) replaces one signed
entirely by EOAs. Reads and post-hook cleanup leave it in place. A containing revert rolls
back the write, including a replacement, and running out of gas while writing reverts the
approval with it.

**Read.** `getApproval(address childSafe, bytes32 messageHash)` returns the record without
consuming it, and reverts when none exists. A transmitter consumes its parent's staged
record and reads children's cached evidence to attach to the message it sends. A relayer can
read the same evidence for direct submission. The receiver verifies authorization independently
([#108](https://github.com/crossecute/protocol/issues/108)).

Approval signatures sign the approval transaction, not the handler's message digest, so they
cannot stand in for the empty child payload. A child signature set may contain approved-hash
entries (`v = 1`) that a receiver cannot verify offchain, so the transmitter and receiver
reject them at every level (#108).

The [child approval benchmark](../../contracts/safe-guard/README.md#child-approval-evidence-sizing)
measures the size and storage cost of this evidence for one nested Safe shape.

## Installation

A fresh Safe and a Safe that already has a transaction guard use the same entry points,
with no migration-specific API. Submit the following calls in one owner-approved MultiSend batch.

1. Call `configureImmediately` on `CrossecuteGuard` with its policies and, if desired,
   `configureTimingImmediately(delay, expiry)` with its configuration timing, before this
   guard occupies either of the Safe's guard slots.
2. Call `setGuard(CrossecuteGuard)`.
3. Optionally call `setModuleGuard(CrossecuteGuard)`.

On an already guarded Safe, the batch runs under the existing guard, which must permit it.
Safe 1.5.0 calls the post-hook on the guard it read before execution, so the old guard
receives the post-hook for the installing transaction and `CrossecuteGuard` sees no unmatched
post-hook. Once installed, owner calls use `requestConfiguration`, then
`applyConfiguration` for policies or `applyConfigurationTiming` for timing. Both apply paths
honor the maturity and expiry captured at request time. The default is zero delay with
no expiry. See [policy configuration timing](../../contracts/safe-guard/README.md#policy-configuration-timing)
for the root calculation and read methods.

## Build and chain support

The guard needs EIP-1153 (`TSTORE`/`TLOAD`), so it targets Cancun. The owner pre-hook reads
transient storage on every transaction, so on a chain without EIP-1153 every owner transaction
would revert, including one that removes the guard. Install it only where Cancun is active. It is compiled with Solidity 0.8.30 and via-IR, matching the
policy-engine. The project keeps its own configuration, output and cache; `contracts/evm/`
retains its Paris target and legacy compiler pipeline. [`contracts/safe-guard/README.md`](../../contracts/safe-guard/README.md)
has the pins and commands.

## Earlier work

An earlier draft of this design kept a risk register (E01-E25) and open questions (Q1-Q11).
They are kept for reference
[at commit `1cec3e0`](https://github.com/crossecute/protocol/blob/1cec3e051426c7f9a3336fc39775e07cb8ac1b8e/docs/safe-guard-design.md#running-edge-case-and-risk-register).
Where they disagree with issue #107 or this file, #107 and this file are right.
