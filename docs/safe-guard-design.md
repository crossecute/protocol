# Safe guard

The Safe guard a conduit owner installs so that its transmitter can attach the owners'
signatures to a dispatch, and so that a child Safe's approval of a parent transaction leaves
evidence a receiver can check. Tracked in
[issue #107](https://github.com/crossecute/protocol/issues/107).

**Status.** Design. The guard and its tests live in
[`contracts/safe-guard/`](../contracts/safe-guard/), a separate Foundry project. Nothing in
`contracts/evm/` depends on it yet. Receiver verification of what the guard hands out is
[#108](https://github.com/crossecute/protocol/issues/108); authority updates are
[#109](https://github.com/crossecute/protocol/issues/109).

**Where the reasoning lives.** As in [`message-flow.md`](message-flow.md), each decision is
argued in the NatSpec of the contract that implements it. This file says what the pieces are
and how they connect. Where the two disagree, the contract is right.

## Shape

There is one guard contract, `CrossecuteGuard`. It extends `SafePolicyGuard` from
[safe-research/policy-engine](https://github.com/safe-research/policy-engine), vendored from
the [`crossecute/policy-engine`](https://github.com/crossecute/policy-engine) fork. The fork
adds internal callbacks after the owner policy check, after the module policy check, and
after owner execution. The external hooks keep their checks and selectors. Everything
Crossecute adds runs in those callbacks.

- **Target.** Safe 1.5.0. Earlier versions have no module guard and are not supported.
- **Shared.** One deployment serves any number of Safes. Policy assignments, pending
  configuration, transient dispatch records and cached approvals are all keyed by Safe.
- **Policy.** The inherited `PolicyEngine` governs every owner and module transaction.
  `SafenetPolicy` is one policy a Safe may select, not part of the guard.
- **Slots.** Crossecute requires the guard in the Safe's transaction guard slot. Putting the
  same contract in the module guard slot is the multisig's choice (see
  [Module execution](#module-execution)).
- **No composition.** The guard does not register, forward to, or delegatecall other guards.
  A Safe uses exactly this guard.

The inherited checks still apply: `safeTxGas` and `gasPrice` must be zero, so a failed inner
call reverts the whole Safe transaction, and a Safe transaction may not target the guard
except for the three configuration entry points.

## Owner execution

Safe 1.5.0 increments the nonce and checks signatures, then calls the transaction guard's
`checkTransaction`, executes, and calls `checkAfterExecution(txHash, success)` on the guard
it read before execution. After the inherited policy check, `CrossecuteGuard` does three
things in the pre-hook, in this order:

1. **Nesting.** If the calling Safe has a live dispatch record, revert. See
   [Nesting](#nesting).
2. **Dispatch staging.** If the top-level calldata selector is
   `sendMessage(bytes,bytes,bytes[])`, write a transient dispatch record for the calling Safe.
3. **Approval capture.** If the operation is `DELEGATECALL` and the selector is
   `signMessage(bytes)`, write the persistent approval record for the calling Safe.

The two selectors differ, so one transaction triggers at most one of steps 2 and 3. The
post-hook clears the calling Safe's dispatch record if one exists.

## Transient dispatch record

Staging matches on the selector alone. It does not check the target, the operation, or the
arguments. The record holds, for the calling Safe:

| Field | Source |
| --- | --- |
| Safe transaction hash | recomputed from the hook arguments and `nonce() - 1` |
| Signed target | `to` |
| Consumed flag | set by `consume` |
| Operation, value, calldata hash | hook arguments |
| `safeTxGas`, `baseGas`, `gasPrice`, `gasToken`, `refundReceiver`, nonce | hook arguments and the Safe |
| Signature blob | the hook's `signatures`, byte for byte |

The signature blob is the complete original `signatures` argument: owner signatures, any
nested contract-signature data with its offsets, and the policy extension if present. There
is no byte cap. The record lives in EIP-1153 transient storage under a per-Safe base slot.

**Consumption.** `consume(address safe)` returns the record for `safe` when the record is
live, not yet consumed, and `msg.sender` is the signed target. It marks the record consumed
and leaves it live. A second call reverts.

**Cleanup.** The post-hook clears the record only when its stored transaction hash matches
the hook's `txHash`, then zeroes every slot it used, consumed or not. A successful
selector-matched call that nobody consumed stands, including one to an unrelated contract
that shares the selector. Cleanup does not rely on the end-of-transaction reset, so a second
Safe execution in the same parent transaction starts clean.

**No staging path.** A single signed MultiSend dispatch has the `multiSend` selector at top
level, and module transactions never enter the owner hook. Neither stages a record, so a
protected transmitter reached that way finds nothing to consume and rejects.

## Transmitter side

A signature-enabled transmitter, called directly by its owner Safe:

1. checks that `msg.sender` is its owner Safe;
2. reads the Safe's transaction guard slot with `getStorageAt(slot, 1)`, decoding the reply
   strictly;
3. calls `consume(msg.sender)` on that guard before any other external call;
4. uses the returned blob in memory and rejects if discovery or consumption fails.

It never pins a guard address and never falls back to an unsigned send. It does not compare
calldata or value with the record: the direct call from the Safe already delivers what the
owners signed, and the guard only lets the signed target consume. The minimal transmitter in
`contracts/safe-guard/test/` exercises this flow; the protocol's own transmitters are
unchanged.

## Nesting

While a Safe has a live dispatch record, the guard rejects any nested owner execution by
that same Safe, before and after consumption, until the post-hook clears the record. A
separately signed execution after cleanup in the same parent transaction proceeds. Verifying
a nested Safe owner's signature calls that Safe's signature validator, not
`execTransaction`, so it never reaches the owner hook. Execution by a different Safe is
subject to that Safe's own record and the inherited policy check.

## Module execution

When the Safe puts the guard in its module guard slot, the module callback rejects any
module transaction whose top-level selector is `sendMessage(bytes,bytes,bytes[])`, whatever
the target. Every other module transaction goes through the inherited policy engine, whose
configuration must deny module self-calls and delegatecalls. The policy engine already
refuses configuration changes from modules and any call that targets the guard. Together
these keep a module from changing the transaction guard, the module guard, owners,
threshold, handler, or policy.

A multisig may leave the module guard slot empty and keep modules enabled. It then trusts
those modules with their Safe permissions, including any ability to bypass Crossecute's
authority checks. The authority-change path is [#109](https://github.com/crossecute/protocol/issues/109).

## Persistent child approval evidence

A nested parent Safe can accept an empty contract signature from a child owner because the
child's compatibility fallback handler reads the child's `signedMessages` flag. The flag
holds no signatures. To let a receiver check the child's authorization without light clients,
the child's guard keeps the signed transaction that set the flag.

**Capture.** In the child's pre-hook, after policy checks, a `DELEGATECALL` whose selector is
`signMessage(bytes)` is an approval candidate. The guard does not check the target address or
its code hash. Safe has no built-in `SignMessageLib` allowlist, so an authorized delegatecall
can write any hash, and the handler does not check who wrote it. A cached candidate does not
establish what the delegatecall wrote. A candidate whose calldata does not decode as
`signMessage(bytes)` reverts.

**Key.** The child Safe and the message hash `SignMessageLib.signMessage` writes into
`signedMessages`: the child's EIP-712 hash of `SafeMessage(bytes message)` under the child's
domain separator. A reader can compare it with `signedMessages` on the child.

**Record.** The approval transaction's signed fields (`to`, `value`, `data`, `operation`,
`safeTxGas`, `baseGas`, `gasPrice`, `gasToken`, `refundReceiver`, nonce) and the child owners'
signatures. The signatures keep nested data and offsets and drop the child's policy
extension. There is no size cap.

**Lifetime.** One record per child and message hash. A later approval for the same pair
replaces it. Reads and post-hook cleanup leave it in place. A containing revert rolls back
the write, including a replacement, and running out of gas while writing reverts the
approval with it.

**Read.** `getApproval(address childSafe, bytes32 messageHash)` returns the record without
consuming it, and reverts when none exists. A transmitter consumes its parent's dispatch
record and reads children's cached evidence to attach to the dispatch. A relayer can read the
same evidence for direct submission. The receiver verifies authorization independently
([#108](https://github.com/crossecute/protocol/issues/108)). This ABI is not final.

Approval signatures sign the approval transaction, not the handler's message digest, so they
cannot stand in for the empty child payload. A child signature set may contain approved-hash
entries (`v = 1`) that a receiver cannot verify offchain; how the receiver treats them is
part of #108.

[`safe-approval-evidence-sizing.md`](safe-approval-evidence-sizing.md) works through the size
and storage cost of this evidence for one nested Safe shape.

## Installation

A fresh Safe and a Safe that already has a transaction guard use the same entry points,
with no migration-specific API. In one owner-approved MultiSend batch, the Safe:

1. calls `configureImmediately` on `CrossecuteGuard` with its policies, which works only
   before the guard is installed on that Safe;
2. calls `setGuard(CrossecuteGuard)`;
3. optionally calls `setModuleGuard(CrossecuteGuard)`.

On an already guarded Safe, the batch runs under the existing guard, which must permit it.
Safe 1.5.0 calls the post-hook on the guard it read before execution, so the old guard
receives the post-hook for the installing transaction and `CrossecuteGuard` sees no unmatched
post-hook. After installation, configuration changes go through `requestConfiguration` and
`applyConfiguration` with the inherited delay.

## Build and chain support

The guard needs EIP-1153 (`TSTORE`/`TLOAD`), so it targets Cancun and installs only on chains
that have activated it. It is compiled with Solidity 0.8.30 and via-IR, matching the
policy-engine. The project keeps its own configuration, output and cache, and does not change
the Paris build of `contracts/evm/`. [`contracts/safe-guard/README.md`](../contracts/safe-guard/README.md)
has the pins and commands.

## Earlier work

[PR #112](https://github.com/crossecute/protocol/pull/112) explored this design first. Its risk
register (E01-E25) and open questions (Q1-Q11) are kept for reference
[at commit `1cec3e0`](https://github.com/crossecute/protocol/blob/1cec3e051426c7f9a3336fc39775e07cb8ac1b8e/docs/safe-guard-design.md#running-edge-case-and-risk-register).
Where they disagree with issue #107 or this file, #107 and this file are right.
