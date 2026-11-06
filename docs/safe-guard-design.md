# Safe signature staging guard: requirements and proposed design

Status: design draft for [issue #107](https://github.com/crossecute/protocol/issues/107).
This document proposes implementation choices for review. The interface and real Safe
fixture foundation are implemented; the standalone staging MVP and production integration
are not. Decisions explicitly marked agreed below include the interface/fixture boundary,
guard discovery, staging eligibility and production inheritance. Other recommendations
are not accepted decisions.

The [execution plan](safe-guard-build-plan.md) builds on this draft with ordered
tasks, decision gates, proposed artifacts, and completion evidence for issue #107.
Decision evidence is linked below; the plan alone does not close risks.

## Scope and acceptance boundaries

The issue has two deliverables:

1. A production design for one installed transaction guard that preserves the selected
   Safenet policy, sees original Safe signature bytes, and stages portable owner signatures
   before the signed inner call dispatches through a transmitter.
2. A standalone MVP installed through a normal owner-authorized Safe `setGuard` transaction.
   It only stages, reads or consumes, and clears transient data. A real Safe fixture and
   minimal test transmitter exercise it. It performs no policy checks, bridge sends, or destination
   execution and must not be presented as a production policy guard.

The MVP proves source-side transport and lifecycle, not cross-chain signature validity.
Production portability needs a separate verifier agreement on signature kinds, Safe domain,
owner-set authority, threshold, nonce, and replay protection. Staging alone proves none of
those destination-side properties.

A conduit is a transmitter on its source chain and a receiver on a destination chain.
Here, the transmitter retrieves staged signatures from the guard before dispatch.
The standalone MVP uses a minimal test transmitter with no bridge sends.

## Verified baseline

- Protocol baseline: `1a223df`. [Foundry configuration](../contracts/evm/foundry.toml)
  pins Solidity 0.8.28 and Paris. Its bytecode settings protect deterministic addresses.
  [OwnableTransmitter](../contracts/evm/src/messaging/outbound/OwnableTransmitter.sol)
  authenticates the owner through the existing shared ownership check. There is no signature
  staging integration in that contract. Existing owner authorization must remain required.
- [Safe v1.3.0 at 186a21a](https://github.com/safe-fndn/safe-smart-account/blob/186a21a74b327f17fc41217a927dea7064f74604/contracts/GnosisSafe.sol)
  is the agreed MVP singleton/proxy source fixture. It increments nonce, checks signatures,
  then invokes the pre-hook with original signatures. The ECDSA fixture observes signed
  nonce `Safe.nonce() - 1`; the post-hook receives the digest and execution success.
- The compatibility observer uses [ITransactionGuard and BaseTransactionGuard at dc437e8](https://github.com/safe-fndn/safe-smart-account/blob/dc437e8fba8b4805d76bcbd1c668c9fd3d1e83be/contracts/base/GuardManager.sol)
  from Safe 1.5.0. The 1.3.0, 1.4.1 and 1.5.0 transaction hooks have identical canonical
  ABIs and call arguments; no version branches or duplicate interfaces are required.
  The newer base supplies ERC-165 support, which 1.3 does not check at installation.
  [Compatibility tests](../contracts/safe-guard/test/TransactionGuard.t.sol) exercise
  installation and signed owner calls with the newer base on the 1.3.0 source fixture.
  Tested runtime support is limited to that fixture, not 1.4/1.5 or deployed bytecode.
  Module policy compatibility remains a separate production decision: 1.3 has no module guard.
- [SafePolicyGuard at 8ee68a8](https://github.com/safe-research/policy-engine/blob/8ee68a8cdac65b4aba5d9a10e9f9018c2efb10b3/contracts/SafePolicyGuard.sol)
  implements transaction and module hooks. The transaction hook decodes an extension into
  policy context; that context is not the original owner-signature blob. It requires zero
  `safeTxGas` and `gasPrice`, and its post-hooks require success. Its source pins Solidity
  0.8.30, which is also an integration constraint separate from Cancun.
- [SignatureExtension at the same revision](https://github.com/safe-research/policy-engine/blob/8ee68a8cdac65b4aba5d9a10e9f9018c2efb10b3/contracts/libraries/SignatureExtension.sol)
  describes one terminal typed extension, with payload followed by a length word and type
  hash. The envelope adds 64 bytes. It does not support nested extensions.
- [EIP-1153](https://eips.ethereum.org/EIPS/eip-1153) makes transient state contract-owned,
  reverts its writes with the containing call frame, and discards it at transaction end.
  A separate contract cannot directly load the guard's slots. A read may use `STATICCALL`;
  consumption must use a normal call because it writes transient state.

## Requirements

| ID | Required behavior | Evidence required before MVP completion |
| --- | --- | --- |
| R1 | Install through Safe `setGuard`, with the required interface support | Real proxy and singleton fixture; signed installation transaction |
| R2 | Authenticate the configured Safe on both hooks | Other Safe, EOA, and Safe-shaped impostor cannot stage or clear its context |
| R3 | Stage when the first four calldata bytes match `sendMessage(bytes,bytes,bytes[])`, without a target or operation filter | Matching selector stages for different targets and both operations; short/nonmatching calldata stages no signatures |
| R4 | Bind exact calldata, value, Safe, target, signed nonce, and Safe digest | Mutate each bound field independently and reject consumption |
| R5 | Bound the staged blob; use length plus 32-byte words | Empty, limit, limit-plus-one, and partial final-word cases |
| R6 | Consume once, before external effects; never overwrite a live context | Duplicate consume and reentrancy attempts |
| R7 | Clear an unconsumed context only for its matching transaction | Matching and wrong-hash post-hooks; skipped consume; failure rollback |
| R8 | Isolate Safes and permit sequential completed calls in one transaction | Two registered Safes and repeated calls in an outer harness |
| R9 | Keep production policy semantics and owner authorization | Production differential policy tests and owner-gate tests, beyond MVP |
| R10 | Isolate Cancun artifacts from the Paris protocol build | Separate build/test configuration and unchanged protocol artifact hashes |

## Proposed architecture

### Trust and configuration

Recommendation: a guard instance bound to one Safe for the first MVP. Transmitter addresses
are not a staging allowlist: the signed target identifies who may consume each record.
Do not accept an arbitrary Safe caller merely because it reports a Safe version or answers
a storage query. The fixture deploys a real
Safe proxy, deploys the guard for that address, then installs it through the Safe. Production
registration must verify the supported singleton/proxy deployment and installed guard;
version-string checks alone are not authentication.

Agreed staging trigger: calldata has at least four bytes and its selector equals the
transmitter's `sendMessage(bytes,bytes,bytes[])` selector. Do not validate target identity
or filter CALL versus DELEGATECALL to decide whether to stage. This supersedes the issue's
original target/plain-CALL staging filter. Independent signature bounds/format rules and
Safenet policy checks still apply. A selector collision on another contract also stages;
selector matching is not proof that a transmitter will execute or consume the context.
Do not decode the send arguments as an additional staging eligibility check.

Record the actual signed target and operation as transaction context. Consumption requires
`msg.sender` to equal that recorded target, plus the agreed exact calldata/value and Safe
binding. Nonmatching or short calldata stages no signature blob, while production still
runs Safenet policy. No inspection of nested MultiSend calldata or module-signature staging
is added by this decision.

### Production inheritance and policy integration

Agreed: our installed production guard extends `SafePolicyGuard`, reusing its inherited
`PolicyEngine`, policy configuration and enforcement. It adds crossecute's transient
signature staging, target-bound consumption and cleanup. It is separate from transmitters
and receivers. `SafePolicyGuard` is the general policy guard; `SafenetPolicy` is a separate
configurable policy contract that verifies Safenet attestations. Selecting the base guard
does not make Safenet attestation mandatory for every action.

```text
PolicyEngine
  -> SafePolicyGuard (refactored pinned dependency)
       -> our combined policy and signature-staging guard
```

The reviewed base revision is `8ee68a8cdac65b4aba5d9a10e9f9018c2efb10b3`. Its external hooks
are not virtual. Before deriving the combined implementation, obtain an upstream refactor
or maintain a minimal fork that exposes virtual hook wrappers and reusable internal policy
paths. Preserve the Safe caller identity and existing policy semantics. Do not forward
hooks to a separately deployed guard, and do not attempt an external self-call to reuse a
hook: both change `msg.sender`. An external hook is not an internal `super` entry point.

Use one canonical transaction-hook implementation and reconcile Solidity operation/interface
types between the policy dependency and Safe's newer interface. The agreed
`ITransactionGuard` ABI/ERC-165 compatibility requirement remains. Directly inheriting
`BaseTransactionGuard` as a second independent production hook base is not required;
the existing test observer may continue using it to establish compatibility.

Pre-hook order: authenticate and reserve the staging lifecycle, capture signed context,
execute the inherited policy checks, then stage on the agreed selector. Safe executes its
originally signed inner call; the guard never sends on its behalf. The post-hook preserves
inherited policy postconditions and clears the matching staging record. Preserve module
policy hooks without adding owner-signature staging to them.

Still required: pin the refactored dependency and provenance, resolve the upstream Solidity
0.8.30 requirement in the isolated build, reconcile hook types, and run differential policy
tests before claiming production parity. No policy-engine integration is implemented by
the existing interface observer, and the standalone MVP remains policy-free.

### Slot ownership and transmitter interface

Agreed: the guard owns the staged signatures in its transient storage. The
signature-enabled transmitter discovers the guard from its owner Safe and calls
it to consume the matching signatures. Returned bytes live in transmitter memory;
the transmitter does not need its own transient signature copy.

### Guard discovery from the owner Safe

Agreed: on each protected dispatch, first enforce the existing owner check. Then
read one word from that owner Safe using `getStorageAt(GUARD_STORAGE_SLOT, 1)`:

```text
GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8
```

The external storage-reading ABI and transaction guard slot agree in reviewed Safe
1.3.0, 1.4.1 and 1.5.0 sources. Storage-reading sources:
[1.3.0](https://github.com/safe-fndn/safe-smart-account/blob/v1.3.0/contracts/common/StorageAccessible.sol),
[1.4.1](https://github.com/safe-fndn/safe-smart-account/blob/v1.4.1/contracts/common/StorageAccessible.sol),
[1.5.0](https://github.com/safe-fndn/safe-smart-account/blob/v1.5.0/contracts/common/StorageAccessible.sol).
The existing runtime fixture remains 1.3.0 only.
Call the discovered guard's consume API before bridge effects, passing actual
call value and calldata hash, and validate its returned context. The guard must
authenticate the Safe on staging and the staged target transmitter on consumption.
Reading the slot does not give direct access to the guard's transient storage.

The Safe's installed transaction guard is the selected trust authority. The
transmitter does not pin a guard address at deployment, accept a guard address
from dispatch arguments, or accept a hook that pushes a transient guard pointer.
Reject missing/malformed storage responses, a zero or code-less guard, incompatible
consume responses and absent or mismatched context. Interface support alone does
not prove correct staging or portable owner authorization. Do not fall back to
unsigned dispatch when discovery or consumption fails.

Transmitter creation remains atomic: deploy, initialize and lock within the
creation call. No later guard-address initialization is needed. Deploy/configure
and install a compatible guard before the first protected dispatch; this discovery
choice does not require a fixed guard/transmitter deployment order. Guard replacement
follows Safe/Safenet authorization and migration rules. Test a replacement before
a later dispatch, removal, and a guard change between pre-hook and consumption;
the new guard must not be assumed to possess the old guard's staged context.
No transmitter registration is needed for staging eligibility or target-bound consumption.
The number of Safes per guard and Safe authentication/configuration remain Q3 decisions.

### Signature retrieval

Proposed conceptual operations, with final ABI left open:

- `readContext(safe)`: return metadata and bounded signature bytes without mutation.
- `consume(safe, callValue, callDataHash)`: require the staged transaction target as caller,
  compare the active context, return its metadata and signatures, and mark it consumed.

The transmitter requires its caller to be the configured Safe and preserves its existing
owner check in production. It derives the value and data hash from its own `msg.value` and
`msg.data`, never from caller-supplied assertions. It verifies returned Safe, target,
selector and context identifier before using the signatures. Nonce and digest originate
from the authenticated pre-hook, not untrusted dispatch parameters. The transmitter is trusted
to report its own call accurately; an arbitrary signed target is not a generic proof of
execution. Keep this interface out of provider-specific duplicates.

Use a versioned namespace and a Safe-keyed record containing phase, target, selector,
value, calldata hash, signed nonce, Safe transaction digest, blob length, and blob words.
Define the context identifier as a domain-separated hash of chain ID, guard address, Safe,
target, operation, value, calldata hash, nonce and digest, using unambiguous ABI encoding.
The digest includes all signed Safe fields, including gas and refund fields. Compute it
through the supported Safe's `getTransactionHash` using hook arguments and the recovered
signed nonce. Share this derivation between staging and test expectations where appropriate,
and independently compare against the real Safe transaction hash.

### Lifecycle and reentrancy

Proposed phases: `Idle -> Checking -> Staged -> Consumed -> Idle`. Keep a live marker until
the matching post-hook even after consumption. Clearing the marker at consumption would
permit a nested execution to overwrite the outer transaction's cleanup context.

1. Pre-hook authenticates Safe, rejects an already-live execution, and reserves `Checking`
   before any external policy call. Capture nonce/digest before reentrant work. Production
   runs the policy for all transactions. Any rejection reverts reservation and policy writes.
2. A matching dispatch validates bounds and format, writes metadata and padded words, then
   publishes `Staged`. Non-dispatch executions retain only the matching cleanup record.
3. Transmitter checks its actual Safe call and calls `consume` before any external effects.
   Guard checks all context fields, copies the bounded bytes, and marks `Consumed` before
   returning. It may zero blob words here, but retains metadata needed for cleanup.
4. Post-hook authenticates Safe and matches the digest. It clears all recorded words,
   length, metadata and phase, whether the blob was consumed or not. Wrong-hash cleanup
   reverts. Production also preserves policy postconditions; a failure reverts everything.

Recommendation: reject all same-Safe nested guarded executions until the outer post-hook,
including nested non-dispatch transactions. Different Safes need separate records if a
shared guard is later supported. This conservative restriction needs explicit agreement.
Sequential executions after cleanup remain allowed within one outer transaction.

If the inner call consumes and then reverts, its consumption writes roll back. When Safe
returns failure without reverting, the post-hook sees the restored staged context and clears
it. The standalone MVP must allow a fixture with nonzero `safeTxGas` to exercise this path.
The pinned production policy forbids that mode: an inner failure instead reverts the whole
Safe transaction. Test both cases in their respective suites. A whole-transaction revert
undoes the pre-hook too; transaction-end reset is a final backstop, not a replacement for
cleanup between sequential Safe executions.

## Owner signatures and extension bytes

Keep raw hook signatures, decoded policy context, and staged owner signatures as distinct
values. Executor-supplied context is not owner authorization simply because it was appended
to signatures that Safe accepted. Run the policy's own validation on that context.

Recommendation for initial portability: only the threshold-required, sorted ECDSA owner
signatures, with explicitly selected signing modes. Do not treat `threshold * 65` as a
universal parser: contract signatures use dynamic offsets and data, and approved-hash
signatures depend on source state or executor identity. Reject unsupported signature modes
on matching dispatches; ordinary transactions still retain the policy's existing behavior.

For the recognized extension, validate envelope bounds, derive its start, and ensure the
owner region does not overlap it. Never copy policy payload or trailer into the portable
blob. Unknown tails, extra owner signatures, multiple envelopes, contract-signature offsets,
and malformed recognized trailers need explicit rules and negative tests. Do not silently
label the full original signature blob portable. The MVP can prove byte transport without
claiming to implement production parsing, but its selected byte format must be documented.

A bound is required because staging and clearing are linear in blob length. For L bytes,
the payload occupies `ceil(L / 32)` transient words plus one length word and fixed metadata;
zero-pad the final word and return exactly L bytes. No protocol wire format changes in the
MVP. Future bridge encoding and fee impact require separate design and measurements.

## Optional signature add-ons: production integration boundary

Agreed constraint: the protocol must remain usable with or without signature handling.
Keep existing plain transmitter and receiver contracts, storage and entry behavior as-is
where possible. Do not add mandatory signature fields, opcode requirements, runtime mode
branches or verification calls to those contracts. The standalone MVP changes neither.

Proposed structure, with names illustrative until Q4/Q5 define the production API:

| Component | Responsibility and state | Reuse boundary |
| --- | --- | --- |
| Safe guard | Extend refactored `SafePolicyGuard`; reuse policy enforcement and own transient context/signature words | Standalone installed contract, not a transmitter/receiver parent |
| Signature interfaces and codec | Declare transmitter/verifier APIs and versioned encoding; no storage | One shared declaration/codec per format, outside provider bindings |
| Source signature add-on | Authenticate Safe owner, discover its installed guard, consume exact guarded context, construct signed envelope before transport; no stored guard address | One shared abstract component used by optional signature transmitter variants |
| Destination signature add-on | Verify authority, domain, calls and replay before execution; own verifier configuration and replay records | One shared abstract component used by optional signature receiver variants |
| Optional concrete variants | Compose the shared signature component with provider transport behavior | Thin provider declarations resolve inheritance; no copied parsers or verification logic |
| Existing plain variants | Preserve current owner/transport authorization and wire behavior | Deploy independently without the signature components |

Only the Safe guard implements the transaction-guard ABI through its policy base. The source
add-on calls a minimal consume interface; receivers do not import Safe hook interfaces.
Signature state exists only in opt-in variants. Configuration and replay state belong to
each conduit proxy and are initialized before bootstrap execution; do not put per-conduit
state into implementation immutables. Keep transient opcodes in the source guard so they
do not impose source-chain opcode requirements on plain conduits or destination receivers.

This is a composition plan, not proof that all current concrete bindings can be subclassed
without edits. `TransmitterBase.sendMessage` and several concrete transport overrides are
not virtual. A normal external wrapper also changes the caller and fails the existing owner
gate if the Safe remains owner. Do not transfer ownership, bypass that gate, or duplicate the
send implementation merely to make a wrapper work. Before implementation, choose the
smallest extension points or transport refactor that allow optional variants to reuse the
current logic. Any necessary core edit gets its own review and must preserve plain behavior,
storage, ABI and deterministic artifacts, or explicitly document a required migration.

For signature-enabled variants, every effectful entry path must enforce the chosen signature
rule. Adding only `sendSigned` or `executeSigned` while inherited plain paths remain usable
would leave a bypass. Review send, bootstrap, local execution, direct delivery, commitment
approval/finalization, cancellation and initialization paths. Define allowed management
operations separately. Share signed-envelope construction between send and quote, account
for signature byte length and bridge fees, and test both with the same inputs.

Optional variants must not be represented as runtime upgrades of locked conduits. Review
factory/initializer selection, parity of transmitter and receiver addresses, and the
identity inputs that distinguish plain and signature-enabled deployments. Q5 still blocks
destination owner-set authority and replay semantics. Q4 still blocks the exact extension
API. A separate architecture change must resolve those details and test plain and signed
variants through shared suites before any production add-on is implemented.

## Installation, migration, and module guard coexistence

For a fresh production installation, prepare the combined guard configuration, verify
policy parity, and install it through the Safe's authorized `setGuard` call. Configuration
must be in place before it can govern subsequent transactions. The standalone MVP has no
policy configuration and must use a test Safe only.

For an existing policy guard, inventory exact-match policies, operation fallbacks, policy
data, delay/expiry settings, and pending changes. New guard storage does not inherit old
guard storage. Prepare and verify the new configuration under the Safe's authority, then
replace the transaction guard only through the old guard's allowed policy and timing rules.
Do not introduce a temporarily unguarded transaction or bypass the old removal restrictions.
The exact migration transaction sequence and handling of pending roots remain open.

Transaction guard replacement does not itself migrate the module guard. Recommendation:
retain the existing module guard initially; module calls cannot stage or consume owner
signatures. If both guard slots later point to the combined contract, preserve independent
module authentication and policy checks, and keep module paths outside owner-signature
staging. Separate guard instances also have separate policy configuration, so configuration
drift must be addressed before production use. Test guard replacement/removal itself,
including that the old transaction guard may still receive the current transaction's
post-hook. Never assume the newly installed guard received a pre-hook for installation.

## Build and chain support

Recommendation: a standalone `contracts/safe-guard/` Foundry project with its own Cancun
compiler settings, dependency pins, output/cache directories, and CI job. Pin the real Safe
fixture revision. Keep the current `contracts/evm/` Paris settings, deployment configuration,
and deterministic initcode unchanged. Do not enable Cancun globally to compile this MVP.
Production policy integration must separately resolve the upstream Solidity 0.8.30 pin.

Only deploy/install the staging guard on source chains verified to support EIP-1153.
Deployment tooling should reject unsupported sources before installation; constructor or
preflight opcode probes can support that check. There is no silent persistent-storage
fallback in the proposed MVP. Existing Paris-based protocol paths remain separate from
this optional feature. The source-chain support list and UX for unavailable staging are
open decisions, not inferred from whether a chain is EVM-compatible.

## Validation plan and remaining implementation

Use a real Safe proxy/singleton and valid owner signatures, not a hook-only mock. Assert
installation and normal non-dispatch behavior as well as rejection cases. The shared lifecycle
suite should cover read-without-consume, exact byte roundtrip, duplicate consumption,
wrong Safe/transmitter/value/calldata/selector, wrong cleanup digest, oversized blobs, partial
words, same-Safe nesting before and after consumption, and sequential calls in one outer
transaction. Include two-Safe isolation if shared instances are chosen.

Failure fixtures must distinguish a returned inner failure followed by cleanup from a whole
Safe revert. After each outcome, perform another call in the same outer transaction where
possible to detect stale context. Also verify a fresh transaction cannot read old state.
Fuzz blob sizes and context mismatches; test maximum-size cleanup with realistic gas limits.
A minimal test transmitter records a hash or emits test evidence only, and makes no bridge calls.

Production tests additionally compare policy allow/deny behavior with the pinned upstream
for owner and module paths, extension parsing, policy configuration, refund restrictions,
installation, removal and migration. Confirm the original owner gate remains necessary.
Measure staging/consumption/cleanup gas and enforce agreed limits. Run each project's
formatter, build, lint and tests; compare existing protocol artifacts before and after
adding the isolated build. The [interface suite](../contracts/safe-guard/README.md#evidence-and-limits)
covers installation and hook compatibility only; staging, policy and resource-bound tests remain.

## Running edge-case and risk register

Seeded 2026-11-05. These are potential failure modes and review obligations, not confirmed
implementation bugs. No entry is verified or accepted; E03, E15 and E25 record agreed approaches
with implementation evidence pending. The interface/fixture tests provide partial
evidence, not a tested staging mitigation. Scope names the delivery that needs evidence,
not where the risk first appears.

Keep stable `E` identifiers as the design develops. When answering a question below, update
every affected entry in the same change with the decision, remaining exposure, and test or
review evidence. Add newly discovered cases rather than replacing old ones. Use `Open`,
`Decided` (approach agreed, evidence pending), `Verified` (linked evidence satisfies the
closure condition), or `Accepted` (explicit decision records the remaining risk and why).
Do not mark a risk verified merely because a question was answered. Retain closed entries
and reopen them if assumptions, dependencies, configuration, or supported versions change.

### Authentication and call binding

| ID / scope / status | Trigger and potential consequence | Proposed mitigation and closure evidence | Related decisions |
| --- | --- | --- | --- |
| E01 / Both / Open | Another Safe, an EOA, or a Safe-shaped contract invokes a hook or cleanup and impersonates the configured Safe | The interface observer binds the fixture Safe and rejects direct pre/post-hook calls in `testRejectsDirectHookCalls`. Remaining: staging isolation, other-Safe/impostor cases and supported production deployment validation | Q1, Q3; R2 |
| E02 / Both / Open | A supported-version assumption is wrong, or nonce capture occurs after reentrant work, producing the wrong signed digest | Q1 pins the newer interface and 1.3.0 fixture. `testSignedCallPreservesHookArgumentsAndDigest` compares nonce and pre/post digest through the real Safe, including gas/refund fields. Remaining: staging implementation, independent field mutations, reentrancy and deployment validation | Q1; R4 |
| E03 / Both / Decided | A matching selector on another target or under DELEGATECALL stages a record; an unrelated caller attempts to consume it | Agreed: selector-only staging, no target/operation filter; retain actual signed target and require it as consume caller with exact context binding. Remaining: tests for matching selectors across targets/operations, wrong-caller rejection, malformed/short calldata, cleanup without consumption and signed-field mutations | Q4; R3, R4 |
| E04 / Production / Open | A signed target reports invented call context, or its implementation changes | Target-bound consumption authenticates the address, not its code or claims. Treat transmitter code and any upgrade authority as part of the trust model; test direct calls and loss of Safe ownership cannot bypass the existing owner gate | Q3, Q4; R9 |

### Lifecycle, nesting, and resource bounds

| ID / scope / status | Trigger and potential consequence | Proposed mitigation and closure evidence | Related decisions |
| --- | --- | --- | --- |
| E05 / Both / Open | A policy callback reenters before staging, or a transmitter reenters after consumption and overwrites outer cleanup metadata | Reserve before policy calls and retain a live marker through post-hook. Test nesting in Checking, Staged and Consumed, including non-dispatch nesting; confirm sequential completed calls still succeed | Q7; R6, R8 |
| E06 / Both / Open | Consumption succeeds but the inner frame later reverts, restoring a usable staged blob | Exercise returned inner failure followed by cleanup in MVP and whole-Safe revert under production policy. Verify a subsequent execution cannot consume the old blob in either case | Q2; R7 |
| E07 / Both / Open | Cleanup is skipped, uses the wrong digest, or clears only the marker, leaving stale words available to later calls | Match the post-hook record and clear metadata, length and words. Test wrong-hash cleanup, no consumption, repeated calls in one transaction, and a shorter blob after a longer one | Q8; R5, R7, R8 |
| E08 / Both / Open | A second consume or a read after consumption exposes bytes that downstream code treats as fresh authorization | Define read behavior for every phase and make consumption single-use. Test duplicate consume, read-before-consume, read-after-consume, and read-after-cleanup; reads must never authorize external effects | Q8, Q11; R6 |
| E09 / Both / Open | Unbounded input, excessive extension bytes, or maximum-size cleanup exhausts gas and prevents execution or recovery | Agree owner and total-input caps and apply them before avoidable copying. Benchmark staging and cleanup at limits; test limit-plus-one, zero length, and realistic post-hook gas budgets | Q6; R5 |
| E10 / Both / Open | Partial-word copying, slot namespace overlap, or shared-instance keying mixes signature bytes between records | Specify slot derivation and exact-length return rules. Fuzz boundary lengths and long-to-short reuse; test independent guard instances and, if selected, two Safes sharing one guard | Q3, Q6; R5, R8 |
| E11 / Both / Open | Installation or removal routes a post-hook to a guard whose state differs from the newly installed guard; an idle cleanup assumption locks the Safe | Interface suite tests signed installation, replacement and removal on 1.3.0 and confirms the original guard receives the post-hook. Remaining: staging cleanup, failed replacement and policy-compliant recovery | Q1, Q9; R1, R7 |

### Signatures and policy compatibility

| ID / scope / status | Trigger and potential consequence | Proposed mitigation and closure evidence | Related decisions |
| --- | --- | --- | --- |
| E12 / Production / Open | Extension bounds overlap owner signatures, or unknown/extra tails are interpreted differently by Safe, policy and staging parsers | Define one accepted encoding and reject ambiguous dispatch inputs. Test malformed lengths, recognized/unknown types, multiple trailers, extra signatures and overlap; ordinary policy transactions must retain their agreed behavior | Q5, Q6, Q11; R9 |
| E13 / Production / Open | Approved-hash or contract signatures are copied as though they were portable ECDSA authorization | Decide supported signing modes and verifier semantics. Test each supported mode and rejection of unsupported modes, dynamic offsets, duplicate signers and threshold boundaries using valid Safe fixtures | Q5, Q11; R9 |
| E14 / Production / Open | Executor-supplied policy context is mistaken for owner-signed content, allowing altered context to authorize a different effect | Keep context separate from owner bytes and require the selected policy to establish its own binding. Mutate extension payload while retaining owner signatures and verify the policy rejects unauthorized effects | Q2, Q5, Q6; R9 |
| E15 / Production / Decided | Composition changes the Safe identity, fallback selection, allowed configuration calls, refund checks, or failure atomicity | Agreed: extend refactored SafePolicyGuard, reuse inherited internal policy paths, preserve one hook ABI and Safe caller identity. Remaining: upstream refactor/fork pin, compiler/type integration and differential owner/module/configuration/failure tests; migration remains Q9. No production parity is verified | Q2, Q9; R9 |
| E16 / Production / Open | A module call bypasses owner-signature staging rules or reaches a staged transmitter while an owner transaction is active | Keep module authorization independent and require matching owner-call context at the transmitter. Test module dispatch both with no active context and during an active owner execution, including module-triggered reentrancy | Q4, Q7, Q9; R6, R9 |
| E17 / Production / Open | Migration omits policies or pending roots, resets a delay, or leaves transaction and module policy configurations inconsistent | Review a concrete migration inventory and authorized sequence. Test before/after policy parity, pending-root treatment, timing boundaries, failed migration, and removal without an unguarded interval | Q2, Q9; R9 |

### Portability, deployment, and assurance

| ID / scope / status | Trigger and potential consequence | Proposed mitigation and closure evidence | Related decisions |
| --- | --- | --- | --- |
| E18 / Production / Open | A staged source signature is replayed on another destination, or verified against the wrong owner set after rotation | Define destination domain, replay key, owner-set authority and timing before bridge integration. Test duplicate delivery, different destinations and owner/threshold changes; source nonce and transient consumption alone are insufficient acceptance evidence | Q5; R9 |
| E19 / Both / Open | A guard is installed on a source without the required opcodes and guarded transactions become unusable | Verify source support before installation and fail closed in tooling. Exercise an unsupported execution environment and the installation preflight; document availability behavior and recovery assumptions | Q10; R10 |
| E20 / Both / Open | Cancun/compiler changes leak into Paris artifacts and alter deterministic addresses, or an upstream update changes hook/parser behavior | Interface and fixture submodules are pinned independently in the isolated Cancun project. No protocol source or compiler settings change. Remaining: reproducible before/after artifact manifest and upstream review for later pin changes | Q1, Q2, Q10; R10 |
| E21 / Both / Open | Mock hooks or impossible signature fixtures pass tests while real Safe execution, rollback or transaction boundaries fail | The interface suite uses a real 1.3.0 proxy/singleton and ECDSA owner signatures for installation, execution and both failure modes. Remaining: actual transient transport, consumption rollback and transaction-end reset; the observer uses persistent storage only | Q1, Q11; R1, R7 |
| E22 / Production / Open | A successful call does not consume, but is reported as using portable authorization; a selector collision is incorrectly treated as a mandatory transmitter dispatch | Resolve Q8 with selector-only staging: applying mandatory consumption to every matching selector also affects unrelated targets and DELEGATECALL. Test the chosen rule and preserve the MVP's unconsumed-cleanup case | Q4, Q8; R7, R9 |
| E23 / Production / Open | An optional signature variant inherits a plain send, bootstrap, execution or finalize path that bypasses verification | Enumerate all entry paths and test signed-mode bypass rejection as a shared property across providers; retain independent plain-mode tests | Q4, Q5; R9 |
| E24 / Production / Open | Optional variants collide with plain conduit identities, misconfigure one side, or run bootstrap before signature configuration exists | Specify factory/initializer selection and all identity inputs; test plain/signed coexistence, matched deployments, per-proxy state isolation and atomic configuration before bootstrap | Q3, Q4; R9, R10 |
| E25 / Both / Decided | Guard discovery reads the wrong Safe/slot, accepts a missing or incompatible guard, or uses stale context across guard replacement | Agreed: preserve owner authentication, read its Safe's fixed transaction guard slot on each protected dispatch, then consume exact context without unsigned fallback. Remaining: implementation and tests for malformed reads, missing/incompatible guards, replacement/removal and changed guard during an active call. The Safe selects its trusted guard; interface support is not verification of owner authorization | Q1, Q3, Q4, Q9; R2, R4, R6, R9 |

No entry is closed in this revision. Partial interface evidence above refers to the
[compatibility suite](../contracts/safe-guard/test/TransactionGuard.t.sol). Further updates
must record affected decisions and evidence while retaining what remains unverified.
This register is not an exhaustive security review.

## Open questions for joint decisions

| Question | Recommendation to discuss | What it blocks |
| --- | --- | --- |
| Q1. Which Safe versions and deployments are supported? | Agreed: newer transaction-hook ABI/ERC-165 compatibility and pinned 1.3.0 singleton/proxy fixture. The current observer inherits pinned 1.5.0 BaseTransactionGuard; production extends SafePolicyGuard with one reconciled hook implementation. Runtime claim remains limited to the fixture | Production deployment authentication; MVP compatibility boundary resolved |
| Q2. Which policy base and exact revision should production preserve? | Agreed: extend SafePolicyGuard and reuse its PolicyEngine/configuration/enforcement; SafenetPolicy remains a separately selectable policy. Reviewed base is 8ee68a8. Refactored upstream/fork pin, exact required policies, compiler and hook-type reconciliation remain open | Inheritance choice resolved; dependency preparation and policy-parity evidence pending |
| Q3. One guard per Safe or a shared registered guard? Who controls Safe registration/configuration? | Agreed discovery: transmitter reads its owner Safe's installed guard; no pinned/pushed guard address or later setter. Selector-only staging and target-bound consumption need no transmitter allowlist. Single/shared Safe model and Safe configuration authority remain open | Guard discovery and target selection resolved; Safe registration/configuration remains open |
| Q4. Which dispatch selectors and call shapes are supported? Are batches or modules required? | Agreed: stage on `sendMessage(bytes,bytes,bytes[])` selector only, without target/operation filtering. Only the actual signed target may consume. No nested batch parsing or module staging; final retrieval ABI remains open | Staging eligibility resolved; integration ABI remains open |
| Q5. Which signatures are portable, and who verifies them where? | Begin with threshold ECDSA signatures; decide typed-data versus eth_sign explicitly | Parser, destination authority and replay design |
| Q6. What are the size bounds and tail rules? | Agree separate owner-blob and total-input caps; reject unsupported tails on dispatch | Bounded cost, extension parser and fixtures |
| Q7. Is rejecting all same-Safe nested guarded execution acceptable? | Yes for MVP; keep the live marker until post-hook | Reentrancy semantics |
| Q8. Should a successful dispatch that never consumes revert in production? | Permit cleanup in MVP; require consumption for production dispatch | Post-hook success criteria |
| Q9. How are existing policy configurations and pending roots migrated? Must module policy stay synchronized? | Review a concrete existing Safe configuration before choosing the sequence | Safe rollout without a policy gap |
| Q10. Which source chains support this feature, and what happens in the product when unavailable? | Explicit verified allowlist; fail before installation, no storage fallback | Deployment tooling and user flow |
| Q11. Should the MVP transport raw bounded bytes or already enforce the proposed portable subset? Is a read-only API needed? | Small consume API plus test inspection; agree byte format before coding | MVP scope and ABI |

Start implementation after resolving Q1, Q3, Q4, Q6, Q7 and Q11 for the fixture. Production
integration also requires the remaining answers. Keep #107 open until the MVP, its tests,
and the agreed production design are delivered.
