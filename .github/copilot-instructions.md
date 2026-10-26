# Code review instructions

These are for Copilot code review. `.claude/CLAUDE.md` covers how code here is written;
this file covers what a review should look for.

## What this repo is

Cross-chain conduit contracts under `contracts/evm/`. A conduit's address is derived from
`CrossProxy`'s initcode and must be identical on every chain. Messages move between chains
through provider bindings (LayerZero, CCIP, Hyperlane, Wormhole, OP Stack) under
`src/protocols/`. Most configuration is write-once and the transceivers cannot be upgraded,
so a bug that ships cannot be patched in place. `docs/provider-spec.md` is the normative
spec; rules are cited as R1.1 to R9.3, prohibitions as §7, and compliance tests as C1 to C32.

Every PR here gets a human review. Base the verdict on what you found: without a Medium or
higher finding, do not mark a PR as needing a closer look. Touching security-sensitive code is
not a reason, since all of `src/` is. Neither is a claim you could not check here, such as a
measurement taken outside CI; list it with the checks you did not reach.

## Budget

A review has a fixed budget and stops when it runs out. Spend it on `src/` first, in the
order below, and stop a pass when you have a finding or have cleared it. CI already builds,
runs the full test suite, checks sizes, and runs fmt and lint, so do not repeat any of that.
To check a test count or whether a named test passes, read
`contracts/evm/out/copilot-forge-test.txt`, which the setup steps wrote from `forge test` on
the PR head. Forge counts all the `invariant_` functions of one contract as a single test.

End every summary, whatever the PR touches, with the checks you did not reach, named by their
number or heading below, so the human reviewer knows what is left. If you reached them all,
say so.

## What to report

Report a finding only when you can name a concrete caller, input or chain state, and the
wrong outcome. "Consider adding validation" without a failing case is not a finding.

Post only Medium and higher findings as inline comments. Collect Low findings in one list in
the review summary.

Write a Foundry test only when you suspect a specific bug, not to confirm that code works.
Run just that test with `forge test --match-test <name>` from `contracts/evm/`, and include
it in the comment. If you could not write or run one, say so.

## Checks on `src/`, highest priority first

Read the shared code before the bindings: `src/messaging/` and `src/conduit/`, then the
shared files in `src/protocols/`, then each provider. When the same change repeats across
bindings or across a provider's plain, zkSync, and Tron variants, review one copy in full and
compare the rest against it.

1. **Address parity and storage.** No change to `CrossProxy`'s initcode or constructor, to
   `CROSS_PROXY_INIT_CODE_HASH`, or to compiler settings in `foundry.toml` (R8). No storage
   appended to a base's sequential layout, and contracts that share storage by `DELEGATECALL`
   must have the same layout. A mistake here moves every conduit address or corrupts state,
   and cannot be fixed after deployment.
2. **Inbound authentication.** Each binding authenticates the origin in its transport's own
   naming before `_onInbound` or `_onMessageFrom` runs. Look for an origin, sender, or emitter
   that is read but not compared, compared at the wrong width, or truncated (R3, R4, §7.11).
3. **Roles and initializers.** Who can reach `grantRole`, `_grantInitialRole`, and anything
   `onlyInitializing` while an initializer runs a bootstrap payload. A call out to untrusted
   code during initialization is a re-entry point.
4. **Write-once values.** No new setter for a value the base makes write-once, and no path
   that writes one twice or before its prerequisites are set (R9).
5. **Send and quote parity.** A `quote` must accept and reject exactly what its `send`
   accepts and rejects, and price the exact bytes `send` would put on the wire (R2, §7.13).
   Trace any change to one into the other.
6. **Fees and value.** Who pays, who is refunded, and where `msg.value` can be stranded or
   double-counted (R7). A payload size change is a cost change on LayerZero, CCIP, and
   Hyperlane.
7. **Variant drift.** A check added to one of a provider's plain, zkSync, or Tron variants
   must be in the others, ideally through a shared base. Same for a check added to one
   provider that the spec requires of all of them.
8. **Cross-chain agreement.** Values that must match across chains (a route and its chainKey,
   a home key and a provider id, one provider's transceiver addresses) must come from one
   source, not be set independently in two places.
9. **Tests.** A behavior change to a binding needs a test in the shared spec
   (`test/protocols/ProviderBindingSpec.t.sol`) so every binding runs it. Flag a fixture that
   sets up a state production could never reach.

## After `src/`, if budget remains

- If the code and `docs/provider-spec.md` disagree, report it and say which one you think is
  wrong and why. Same for `docs/message-flow.md` and `docs/encoding.md`.
- Check that the PR description's claims match the diff: "no behavior change", "mechanical",
  which files or bindings are covered, which tests were added, and any counts it states.

## Large PRs

A PR is large when it changes more than 20 files or more than 800 lines. For a large PR, do
only the `src/` checks. Skip the docs and PR-description checks, and read test files only
to check a suspected bug or item 9.

## PRs that only touch docs or tests

A change under `src/` that touches only comments or NatSpec counts as docs: with
`bytecode_hash = "none"` and no CBOR metadata, it cannot change bytecode.

Skip the `src/` checklist. Report only claims that are wrong against the code, citations
that point at something that no longer says what the text claims, counts the PR description
states (check a test count against `contracts/evm/out/copilot-forge-test.txt`), and tests
that cannot fail (an assertion that holds whatever the code does, or a fixture that never
reaches the path under test).

## What not to report

- Formatting and lint. CI runs `forge fmt --check` and `forge lint`.
- Comment style or density, unless a comment states something the code does not do.
- Gas micro-optimizations that change bytecode for under a few hundred gas.
- Anything under `contracts/evm/lib/`. It is vendored upstream code kept byte-identical to
  its recorded source.
