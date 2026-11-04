# Safe signature staging guard: requirements and proposed design

Status: design draft for [issue #107](https://github.com/crossecute/protocol/issues/107).
This document proposes implementation choices for review. The standalone MVP and
production integration are not implemented by this change. Open decisions are listed
below; recommendations are not accepted decisions.

## Scope and acceptance boundaries

The issue has two deliverables:

1. A production design for one installed transaction guard that preserves the selected
   Safenet policy, sees original Safe signature bytes, and stages portable owner signatures
   before the signed inner call dispatches through a transmitter.
2. A standalone MVP installed through a normal owner-authorized Safe `setGuard` transaction.
   It only stages, reads or consumes, and clears transient data. A real Safe fixture and
   minimal consumer exercise it. It performs no policy checks, bridge sends, or destination
   execution and must not be presented as a production policy guard.

The MVP proves source-side transport and lifecycle, not cross-chain signature validity.
Production portability needs a separate verifier agreement on signature kinds, Safe domain,
owner-set authority, threshold, nonce, and replay protection. Staging alone proves none of
those destination-side properties.

## Verified baseline

- Protocol baseline: `1a223df`. [Foundry configuration](../contracts/evm/foundry.toml)
  pins Solidity 0.8.28 and Paris. Its bytecode settings protect deterministic addresses.
  [OwnableTransmitter](../contracts/evm/src/messaging/outbound/OwnableTransmitter.sol)
  authenticates the owner through the existing shared ownership check. There is no signature
  staging integration in that contract. Existing owner authorization must remain required.
- [Safe v1.5.0](https://github.com/safe-fndn/safe-smart-account/blob/v1.5.0/contracts/Safe.sol)
  computes the transaction hash using `nonce++`, checks signatures, then invokes the
  transaction guard with the original signatures. At that pre-hook, the signed nonce is
  `Safe.nonce() - 1`. The post-hook receives the transaction hash and execution success.
  Treat 1.5.0 as the proposed first supported version, not a claim about other versions.
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
| R3 | Stage only an approved target and selector under plain `CALL` | Wrong target, short calldata, selector, and `DELEGATECALL` cases |
| R4 | Bind exact calldata, value, Safe, target, signed nonce, and Safe digest | Mutate each bound field independently and reject consumption |
| R5 | Bound the staged blob; use length plus 32-byte words | Empty, limit, limit-plus-one, and partial final-word cases |
| R6 | Consume once, before external effects; never overwrite a live context | Duplicate consume and reentrancy attempts |
| R7 | Clear an unconsumed context only for its matching transaction | Matching and wrong-hash post-hooks; skipped consume; failure rollback |
| R8 | Isolate Safes and permit sequential completed calls in one transaction | Two registered Safes and repeated calls in an outer harness |
| R9 | Keep production policy semantics and owner authorization | Production differential policy tests and owner-gate tests, beyond MVP |
| R10 | Isolate Cancun artifacts from the Paris protocol build | Separate build/test configuration and unchanged protocol artifact hashes |

## Proposed architecture

### Trust and configuration

Recommendation: a guard instance bound to one Safe and one consumer for the first MVP.
Record these addresses explicitly at deployment; do not accept an arbitrary caller merely
because it reports a Safe version or answers a storage query. The fixture deploys a real
Safe proxy, deploys the guard for that address, then installs it through the Safe. Production
registration must verify the supported singleton/proxy deployment and installed guard;
version-string checks alone are not authentication.

Bind dispatch configuration to the Safe: target address, selector, allowed operation,
signature format/version, and size limits. The runtime binds the full signed calldata and
value, not merely the configured selector. A valid non-dispatch transaction follows normal
policy evaluation and stages nothing. A configured dispatch selector with an unsupported
operation or malformed data fails closed. No MultiSend or module dispatch in the first MVP.

For production, use one combined transaction guard with direct access to the Safe hook.
Run the selected policy first, then extract and stage signatures, then return to Safe.
Safe executes the originally signed inner call; the guard must never send on its behalf.
Do not forward the transaction hook to an existing deployed guard: doing so changes
`msg.sender`, which the referenced guard uses as the Safe configuration key. Prefer a
shared internal policy path in the combined guard, with a pinned upstream revision and
explicit compatibility tests. The referenced external hooks are not virtual, so simple
subclass overrides are not an implementation plan without an upstream refactor or fork.

### Slot ownership and consumer interface

Recommendation: the guard owns all transient slots. A trusted consumer calls its guard
through an external interface; it never attempts to load another contract's slots.
Proposed conceptual operations, with final ABI left open:

- `readContext(safe)`: return metadata and bounded signature bytes without mutation.
- `consume(safe, callValue, callDataHash)`: require the configured consumer as caller,
  compare the active context, return its metadata and signatures, and mark it consumed.

The consumer requires its caller to be the configured Safe (production: also preserve the
transmitter's owner check). It derives the value and data hash from its own `msg.value` and
`msg.data`, never from caller-supplied assertions. It verifies returned Safe, target,
selector and context identifier before using the signatures. Nonce and digest originate
from the authenticated pre-hook, not untrusted dispatch parameters. The consumer is trusted
to report its own call accurately; an arbitrary registered target is not a generic proof of
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
3. Consumer checks its actual Safe call and calls `consume` before any external effects.
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
wrong Safe/consumer/value/calldata/selector, wrong cleanup digest, oversized blobs, partial
words, same-Safe nesting before and after consumption, and sequential calls in one outer
transaction. Include two-Safe isolation if shared instances are chosen.

Failure fixtures must distinguish a returned inner failure followed by cleanup from a whole
Safe revert. After each outcome, perform another call in the same outer transaction where
possible to detect stale context. Also verify a fresh transaction cannot read old state.
Fuzz blob sizes and context mismatches; test maximum-size cleanup with realistic gas limits.
A minimal consumer records a hash or emits test evidence only, and makes no bridge calls.

Production tests additionally compare policy allow/deny behavior with the pinned upstream
for owner and module paths, extension parsing, policy configuration, refund restrictions,
installation, removal and migration. Confirm the original owner gate remains necessary.
Measure staging/consumption/cleanup gas and enforce agreed limits. Run each project's
formatter, build, lint and tests; compare existing protocol artifacts before and after
adding the isolated build. None of these runtime tests is claimed by this design-only PR.

## Open questions for joint decisions

| Question | Recommendation to discuss | What it blocks |
| --- | --- | --- |
| Q1. Which Safe versions and deployments are supported? | Start with a pinned 1.5.0 proxy/singleton; enumerate supported factories/singletons | Authentication and nonce compatibility |
| Q2. Which exact Safenet policy revision and policies must be preserved? Is an upstream refactor or maintained fork acceptable? | Use the reviewed revision as a baseline, then pin the agreed production dependency | Policy composition and compiler choice |
| Q3. One guard per Safe or a shared registered guard? Who may change consumer configuration? | Immutable Safe and consumer for MVP; Safe-authorized changes need a production design | Deployment and configuration model |
| Q4. Which dispatch selectors and call shapes are supported? Are batches or modules required? | One direct consumer selector, plain CALL; no batching/modules initially | Context matching and integration API |
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
