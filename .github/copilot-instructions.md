# Code review instructions

These are for Copilot code review. `CLAUDE.md` covers how code here is written; this file
covers what a review should look for.

## What this repo is

Cross-chain account contracts under `contracts/evm/`. An account's address is derived from
`CrossProxy`'s initcode and must be identical on every chain. Messages move between chains
through provider bindings (LayerZero, CCIP, Hyperlane, Wormhole, OP Stack) under
`src/protocols/`. Most configuration is write-once and the transceivers cannot be upgraded,
so a bug that ships cannot be patched in place. `docs/provider-spec.md` is the normative
spec; rules are cited as R1.1 to R9.3, prohibitions as §7, and compliance tests as C1 to C32.

Every PR here gets a human review. Do not mark a PR as needing a closer look only because it
touches security-sensitive code; all of `src/` is. Base the verdict on what you found.

## What to report

Report a finding only when you can name a concrete caller, input or chain state, and the
wrong outcome. "Consider adding validation" without a failing case is not a finding.

Post only Medium and higher findings as inline comments. Collect Low findings in one list in
the review summary.

Before reporting a bug in `src/`, write a Foundry test that fails because of it, if one can
be written, and run it with `forge test --match-test <name>` from `contracts/evm/`. Include
the test in the comment. If you could not write or run one, say so.

If the code and `docs/provider-spec.md` disagree, report it as a finding and say which one
you think is wrong and why. Same for `docs/message-flow.md` and `docs/encoding.md`.

Check that the PR description's claims match the diff: "no behavior change", "mechanical",
which files or bindings are covered, which tests were added, and any counts it states.

Check these on every PR that touches `src/`:

- **Send and quote parity.** A `quote` must accept and reject exactly what its `send`
  accepts and rejects, and price the exact bytes `send` would put on the wire (R2, §7.13).
  Trace any change to one into the other.
- **Inbound authentication.** Each binding authenticates the origin in its transport's own
  naming before `_onInbound` or `_onMessageFrom` runs. Look for an origin, sender, or emitter
  that is read but not compared, compared at the wrong width, or truncated (R3, R4, §7.11).
- **Roles and initializers.** Who can reach `grantRole`, `_grantInitialRole`, and anything
  `onlyInitializing` while an initializer runs a bootstrap payload. A call out to untrusted
  code during initialization is a re-entry point.
- **Write-once values.** No new setter for a value the base makes write-once, and no path
  that writes one twice or before its prerequisites are set (R9).
- **Address parity.** No change to `CrossProxy`'s initcode or constructor, to
  `CROSS_PROXY_INIT_CODE_HASH`, or to compiler settings in `foundry.toml` (R8). No storage
  appended to a base's sequential layout.
- **Variant drift.** A check added to one of a provider's plain, zkSync, or Tron variants
  must be in the others, ideally through a shared base. Same for a check added to one
  provider that the spec requires of all of them.
- **Cross-chain agreement.** Values that must match across chains (a route and its chainKey,
  a home key and a provider id, one provider's transceiver addresses) must come from one
  source, not be set independently in two places.
- **Fees and value.** Who pays, who is refunded, and where `msg.value` can be stranded or
  double-counted (R7). A payload size change is a cost change on LayerZero, CCIP, and
  Hyperlane.
- **Tests.** A behavior change to a binding needs a test in the shared spec
  (`test/protocols/ProviderBindingSpec.t.sol`) so every binding runs it. Flag a fixture that
  sets up a state production could never reach.

## PRs that only touch docs or tests

Skip the `src/` checklist. Report only claims that are wrong against the code, citations
that point at something that no longer says what the text claims, and tests that cannot
fail (an assertion that holds whatever the code does, or a fixture that never reaches the
path under test).

## What not to report

- Formatting and lint. CI runs `forge fmt --check` and `forge lint`.
- Comment style or density, unless a comment states something the code does not do.
- Gas micro-optimizations that change bytecode for under a few hundred gas.
- Anything under `contracts/evm/lib/`. It is vendored upstream code kept byte-identical to
  its recorded source.
