# Safe guard execution plan for issue #107

Status: build plan, 2026-11-05. Interface compatibility and a real Safe fixture
are implemented. No complete staging implementation task is claimed.
Build on [PR #112](https://github.com/crossecute/protocol/pull/112), branch
`docs/safe-guard-design-107`, rather than replacing its design and risk register.
The reviewed starting commit is `5356c2d` on protocol baseline `1a223df`.

## Outcome and scope

[Issue #107](https://github.com/crossecute/protocol/issues/107) requires an agreed
production guard design and a tested standalone transient-storage MVP. The
[design draft](safe-guard-design.md) remains the source for requirements R1-R10,
questions Q1-Q11, and risks E01-E24. This plan orders the work and defines evidence
for completion. Q1's interface/fixture choice is agreed; other recommendations
remain proposals unless explicitly marked agreed.

Assumption: PR #112 remains the design and execution-plan review, followed by
focused implementation PRs on the same issue. Renaming the PR does not rename its
branch. No production deployment, policy implementation, bridge send, destination
execution, or destination signature verifier is part of the standalone MVP.

The issue can close when the production design is agreed and the standalone MVP
passes its acceptance checks. Production-only risks need an explicit design
disposition and linked follow-up work; they do not become Verified because the
MVP passes. A production release requires its own implementation evidence.

## What is already documented

The draft specifies guard-owned transient slots, exact Safe-call binding,
single-use consumption, a live marker through the post-hook, and full cleanup.
It distinguishes policy context from owner signatures and requires policy checks
before staging while leaving the signed Safe inner call responsible for sending.
It also covers migration, independent module policy, and an isolated Cancun build.

The existing code and configuration constrain implementation:

- [OwnableTransmitter](../contracts/evm/src/messaging/outbound/OwnableTransmitter.sol)
  retains the shared ownership check. Staged bytes cannot replace that authority.
- [Protocol Foundry settings](../contracts/evm/foundry.toml) pin Solidity 0.8.28,
  Paris, optimizer and metadata settings. Deterministic protocol artifacts must
  remain unchanged when the separate project is added.
- [Current CI](../.github/workflows/test.yml) runs the protocol formatter, builds,
  size check, selector check, lint, tests, and coverage. A separate guard project
  job runs its formatter, build, lint and interface compatibility suite.
- The agreed Safe 1.3.0 fixture increments the nonce before the pre-hook
  and caches the guard for the post-hook. The implementation inherits the pinned
  Safe 1.5.0 `BaseTransactionGuard`. The pinned policy requires zero
  `safeTxGas` and `gasPrice`, and uses Solidity 0.8.30. Preserve these distinctions
  when specifying fixtures, failure tests, migration, and production composition.

## Execution order

`T01 -> T02 -> T03 -> T04 -> T05 -> T06 -> T07 -> T08`

T09, the production design review, can proceed after T01 alongside the isolated
MVP work. T10, issue closure, requires both T08 and T09. Each task below names
proposed artifacts, dependencies, and the evidence needed to mark it complete.
The [guard project](../contracts/safe-guard/README.md) now contains the pinned
interface dependency and test fixture. Staging artifacts remain proposed.

### T01. Record the decisions needed before coding

Depends on: review of the existing draft and issue scope.

- [ ] Resolve fixture decisions Q1, Q3, Q4, Q6, Q7 and Q11 in the design, with
  rationale, reviewer agreement, and affected risk IDs. Keep unanswered items open.
- [x] Record Q1's agreed dependency boundary: newer `ITransactionGuard` and
  `BaseTransactionGuard`, Safe 1.3.0 singleton/proxy fixture, one implementation,
  no version branches, and tested runtime support limited to the 1.3.0 fixture.
- [ ] Remaining proposed starting assumptions: one guard
  per Safe, immutable Safe and transmitter, one direct plain-CALL selector, no module
  or MultiSend staging, and rejection of same-Safe nesting through the post-hook.
- [ ] Decide the MVP byte format: bounded raw hook bytes or a specified owner
  subset. Raw-byte transport must be labeled as such, with no portability claim.
  Distinguish valid signed Safe inputs from hook-only byte-storage unit inputs.
- [ ] Choose numerical staged-byte and total-input caps, zero-length behavior,
  supported read API, read behavior in each phase, and gas acceptance budgets.
  Record the supported owner count/signing modes for the real fixture.
- [ ] Resolve the R8 wording: one immutable guard per Safe can prove isolation
  between two Safe/guard pairs. A shared registered guard is a separate choice
  requiring same-instance two-Safe tests and registration rules.

Done when: a decision record replaces ambiguity with testable values and rules;
no implementation starts by silently selecting an unanswered option. Cover
R1-R8 and E01-E03, E05, E08-E10, E20-E21 as applicable.

### T02. Specify the ABI, context and transient layout

Depends on: T01.

- [ ] Add the chosen interfaces under `contracts/safe-guard/src/`, with a short
  ABI/layout specification in that project's README before implementation.
- [ ] Specify constructor configuration, guard interface support, hook signatures,
  transmitter access, read access, return fields, errors, and phase transitions.
- [ ] Define the versioned slot namespace, Safe key, phase, target, selector,
  operation, value, calldata hash, signed nonce, digest, length, and word slots.
  State which fields are fixed configuration versus staged data.
- [ ] Define the context ID's exact ABI encoding and domain. Identify every
  producer and reader: pre-hook, transmitter, consume API, post-hook and test oracle.
  Derive runtime context in one shared helper where both operations need it.
- [ ] Specify how the transmitter checks returned nonce/digest/context ID without
  requiring a digest inside the calldata that the same digest signs. Derive
  call hash/value from actual `msg.data`/`msg.value`, not dispatch arguments.
- [ ] Specify zero padding, exact-length returns, clearing of all occupied slots,
  non-dispatch cleanup records, and rejection of live-context overwrites.

Done when: each bound field has one definition and an explicit mismatch test;
layout and ABI implement R2-R8 without provider-specific copies. Cover E01-E03,
E05-E10. For L staged bytes, budget `ceil(L / 32)` payload slots, one length slot,
and enumerated fixed metadata. Staging and cleanup cost grow with L. The MVP
changes no protocol wire format or existing storage layout.

### T03. Add the isolated Cancun project and real Safe fixture

Depends on: T02.

- [ ] Add `contracts/safe-guard/foundry.toml`, separate output/cache/broadcast
  ignores, lock/provenance files, and explicit compiler/EVM/dependency pins.
  Verify compiler compatibility with the selected Safe sources. Reserve the
  policy's 0.8.30 requirement for the production design; do not import policy
  execution into the standalone MVP.
- [ ] Add `test/SafeGuardFixture.sol`: deploy the pinned singleton and real proxy,
  configure owners/threshold, sign actual Safe transactions, and install with
  owner-authorized `setGuard`. Do not replace signature validation with mocks.
  Partial evidence: that fixture and signed installation now exist in the
  interface suite; actual staging/consumption remains unimplemented.
- [ ] Use one shared signing/execution fixture for lifecycle suites. Compare the
  guard's captured nonce/digest with independently prepared signed transactions.
- [ ] Capture a reproducible baseline manifest of protocol creation/runtime
  bytecode hashes before adding the project, using identical compiler, dependency
  and optimizer inputs for the later comparison.

Done when: fresh installation and an ordinary signed non-dispatch transaction
pass, fixture pins are reproducible, and the Paris project still builds. Cover
R1, R2, R4, R10; E01-E02, E11, E20-E21.

### T04. Implement guard-owned staging, reads and cleanup

Depends on: T03.

- [ ] Implement authenticated hooks, nonce/digest capture, call-shape checks,
  bounded word copying, context publication and selected read behavior.
- [ ] Implement transmitter-only consumption and the phase marker retained until
  the matching post-hook. Reject repeated consumption and wrong-hash cleanup.
- [ ] Clear metadata, length and occupied words for consumed and unconsumed
  executions. Do not depend only on transaction-end reset.
- [ ] Exercise storage boundaries in unit tests, keeping direct hook tests
  explicitly separate from the signed Safe execution acceptance suite.

Done when: R2-R7 have positive and negative evidence, and a completed execution
leaves no readable record. Cover E01-E03, E05-E10. No policy or bridge logic.

### T05. Implement the minimal transmitter and signed execution path

Depends on: T04.

- [ ] Add a minimal test transmitter that requires the configured Safe caller,
  derives actual call context, consumes once, validates the result, then records
  a hash or other test evidence. Any external effect follows consumption.
- [ ] Add transmitter modes for no consumption, attempted duplicate consumption,
  reentrancy, and consume-then-revert, sharing the context checks across modes.
- [ ] Prove exact byte roundtrip and value-bearing plain CALL through the real
  Safe, alongside normal unrelated transactions that stage no signature blob.
- [ ] Reject wrong transmitter/Safe/target/selector/operation/value/calldata, short
  calldata and added trailing bytes. Mutate nonce, digest and all signed gas/refund
  fields in the appropriate oracle or hook tests, using valid Safe signatures
  whenever the case is presented as reachable through Safe.

Done when: R1-R6 pass end to end, including accepted dispatch and non-dispatch
behavior. Cover E01-E04, E08, E21. This transmitter sends no bridge messages.

### T06. Prove rollback, nesting and transaction boundaries

Depends on: T05.

- [ ] With a real Safe and nonzero `safeTxGas`, consume then revert the inner
  frame. Assert Safe returns failure, consumption rolls back, and the matching
  post-hook clears the restored staged record.
- [ ] With zero `safeTxGas` and `gasPrice`, prove whole-Safe revert and rollback
  of staging. Catch the failure in an outer harness and execute again to detect
  stale context. Production policy behavior is specified in T09, not simulated
  by adding policy checks to this MVP.
- [ ] Test same-Safe nesting in Staged and Consumed, including non-dispatch
  nesting, and prove completed sequential Safe executions remain allowed in
  one outer transaction. Checking-phase policy-callback nesting belongs to
  future production tests because the MVP performs no external policy call.
- [ ] Test skipped consumption, long-to-short reuse, read after consume/cleanup,
  wrong post-hook hash, guard replacement/removal and failed replacement.
  Assert which guard receives the post-hook and fresh installation has no
  assumed matching pre-hook on the newly installed guard.
- [ ] Test two configured Safe/guard pairs in the same outer transaction. If T01
  selects a shared guard instead, add two-Safe shared-record tests as well.
- [ ] Add an Anvil integration check using separate submitted transactions.
  A test probe observes deliberately uncleared transient state within the first
  transaction and its absence in the next, independently of post-hook cleanup.
  Keep that probe outside the installable MVP contract.

Done when: R6-R8 have evidence for each failure mode and transaction boundary.
Cover E05-E08, E10-E11, E21. Document unreachable hook-only negatives honestly.

### T07. Establish bounds and chain availability behavior

Depends on: T06.

- [ ] Fuzz lengths and mismatched context fields; include 0, 1, 31, 32, 33,
  chosen cap, cap-plus-one, partial final words and repeated long/short inputs.
  Apply the chosen byte-format rules to real Safe fixtures.
- [ ] Measure staging, read, consumption and both cleanup paths at the maximum
  accepted size. Record compiler, EVM, fixture and gas budgets; assert the
  agreed ceilings with enough post-hook gas under realistic execution limits.
- [ ] Specify and exercise installation preflight on a Cancun-capable local
  node and a pre-Cancun environment. Reject unsupported sources before signing
  installation; prove no persistent-storage fallback is used. Keep chain support
  unverified until chain-specific evidence exists.
- [ ] Document installation/removal, the test-only nature of the MVP, supported
  Safe pin, byte format, limits, opcode requirements and unavailable behavior in
  `contracts/safe-guard/README.md`.

Done when: R5 and R10 have bounded-cost and unsupported-environment evidence.
Cover E09-E10, E19-E21. No chain is declared supported merely for being EVM.

### T08. Add CI and prove the protocol is unchanged

Depends on: T07.

- [ ] Add a separate guard job in `.github/workflows/test.yml` with pinned tools
  and dependencies, formatter, build, size check, lint, unit/fuzz tests and the
  multi-transaction integration check. Clear unused imports and lint findings.
- [ ] Run the existing Paris job's formatter, build, size/selector checks, both
  lint modes and tests; run coverage as configured. Record skipped RPC tests.
- [ ] Compare the T03 manifest to the same protocol artifacts after the isolated
  build. Include every existing address-determining creation artifact and the
  resulting initcode hashes. Fail on any unexplained difference.
- [ ] Link actual test names, gas results, artifact comparison and CI run to
  R1-R8/R10 and the applicable register entries. Keep missing evidence open.

Done when: clean-checkout reproduction passes both projects, protocol hashes
agree, and the MVP acceptance matrix has no unexplained failures or omissions.
R9 remains a production design obligation with future implementation tests.

### T09. Finish the production design and follow-up boundaries

Depends on: T01; incorporates findings from T02-T08 before acceptance.

- [ ] Resolve Q2 and remaining production portions of Q1/Q3/Q4: exact policy
  revision, supported deployments/transmitters, configuration authority and shared
  internal policy composition. Choose an upstream refactor or maintained fork;
  specify licensing/provenance and the separate compiler decision. Forwarding
  to an existing deployed guard changes its Safe caller identity.
- [ ] Resolve Q5/Q6/Q11: accepted signing modes, threshold/signer ordering,
  total-input/owner caps, recognized extension bounds and exclusion, unknown or
  duplicate tails, extra signatures, dynamic contract-signature offsets and
  approved-hash rejection. Keep ordinary policy transactions' agreed behavior.
- [ ] Specify how policy validates executor context separately from owner bytes.
  Define differential test cases for policy fallback selection, configuration,
  refunds, failure atomicity and unchanged owner authorization. Put shared
  transmitter integration in optional shared add-ons, not in each provider.
- [ ] Preserve the agreed plain/signature deployment split from the
  [add-on architecture](safe-guard-design.md#optional-signature-add-ons-production-integration-boundary).
  Choose reusable extension points and thin concrete composition, enumerate all
  inherited bypass paths, specify per-proxy state and atomic initialization, and
  keep plain contracts free of mandatory signature state/checks. Trace quote/send
  parity, signed envelope costs, factory selection and deterministic identities.
  Track optional-path bypasses and deployment/state coupling as E23 and E24.
- [ ] Resolve Q7/Q8: nested-call restrictions and whether successful production
  dispatch requires consumption. Preserve the MVP no-consume cleanup case.
- [ ] Resolve Q9 against a concrete configuration inventory: policies, fallback
  operations, data, timing, pending roots, installation/removal permissions,
  transaction/module guard slots and synchronization. Specify authorized
  migration, failed migration and recovery without an unguarded interval.
- [ ] Specify module behavior without owner-signature staging, including a module
  calling the transmitter while an owner transaction is active.
- [ ] Resolve Q10's availability policy. Require verified chain evidence before
  production installation; record remaining support-list work explicitly.
- [ ] State destination verifier prerequisites: domain, replay key, authoritative
  owner set, threshold/rotation timing and signing-mode semantics. Link follow-up
  work before any bridge integration; source staging is not that verification.

Done when: reviewers agree the production design, each Q has an answer or an
explicitly accepted deferral with scope/owner, and E04/E12-E18/E22 plus production
parts of shared risks have design dispositions. Production implementation,
differential tests, migration rehearsals and destination verification stay in
linked follow-up issues. Do not label their risks Verified without evidence.

### T10. Review evidence and close the issue

Depends on: T08 and T09.

- [ ] Map every issue deliverable to accepted design text or passing MVP evidence.
  Update R8 wording if T01 chose isolated per-Safe instances.
- [ ] Update all 24 risk entries in place with decisions, evidence and remaining
  exposure. Preserve stable IDs and the Open/Decided/Verified/Accepted meanings.
- [ ] Update README, `docs/todo.md`, both guard documents and PR descriptions so
  each distinguishes agreed design, tested MVP and future production work.
  Check all changed names, local links and citations against their actual targets.
- [ ] Keep #107 open while either required deliverable is missing. Close it only
  after the agreed design and MVP evidence are reviewed and merged.

Done when: the issue's two deliverables are delivered, follow-up production work
is traceable, and no description presents the standalone MVP as a policy guard.

## Suggested implementation changes

Keep each change independently reviewable and use Conventional Commits:

1. `docs(safe): finalize guard decisions and context specification` (T01-T02).
2. `test(safe): add isolated Cancun project and real Safe fixture` (T03).
3. `feat(safe): implement transient staging lifecycle` (T04-T05 and core tests).
4. `test(safe): cover rollback nesting and transaction reset` (T06).
5. `test(safe): validate bounds and installation preflight` (T07).
6. `ci(safe): validate guard MVP and preserve Paris artifacts` (T08).
7. `docs(safe): finalize production design and delivery evidence` (T09-T10).

These are proposed changes, not commits already made. Pair behavior with its
tests; split further when review size warrants it. Record any real bug discovered
in existing code as an issue and fix it in its own change.
