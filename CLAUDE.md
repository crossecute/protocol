# Repo conventions

## Code comment density

Write code comments at auditor-spec density, not narrative density. A comment block
explains a non-obvious invariant, a security assumption, or a reason a reader couldn't
derive from the code itself — it does not restate what the code already says, walk through
alternatives that weren't chosen, or use rhetorical/all-caps emphasis (no "NOT OPTIONAL",
no "THE WHOLE POINT", no capitalizing a word for emphasis). Say the load-bearing fact once,
plainly, and stop.

As a hard ceiling, total comment volume in a file should stay under ~3x the code volume
it's attached to; in most files it should be far less. When trimming, cut duplicated
rationale (the same point made in two places), cut restated code, and cut hedging — keep
the one sentence that would actually save an auditor time.

This applies to every `.sol` file in `contracts/evm/`, including new provider bindings and
their tests, not just files already in this style. Before committing a new file, check it
against this rule the same way you'd check it builds.

## When something changes, check everything that depends on it

A change is not finished when the changed code is right. It is finished when everything that
depends on it still holds. Before committing, name what the change alters (a value's role, a
check, a signature, a data format, a stated fact) and find each kind of dependent:

- **What reads or derives from it.** If a value now feeds an identity, an authorization, or
  anything that cannot be changed later, list every other value that must agree with it and
  every place each is set. Add a check or a test for a mismatch.
- **What calls it.** If shared code now rejects or accepts something new, trace every
  caller. Where two operations must agree (an action and its preview, a write and its
  validation), test both with the new input, and compute the value they share in one place.
- **What constrains it.** Re-read the plans, specs, and recorded decisions that cover the
  code being touched. Apply them in the same change, or record why not.
- **What states or names it.** Search the whole repo for the old claim's wording and for
  each changed name or signature: docs, READMEs, comments and docstrings in source and
  tests, scripts, config files, provenance headers of vendored code, and the tracking PR's
  description. A stale claim may only be implied, so also reread every doc that describes
  what changed. Open every hit and confirm it still says what the citation claims; a
  reference that resolves is not enough. If the cited item was deleted, repoint the citation
  to where the fact now lives or drop it. A citation that was already wrong before your
  change still gets fixed.
- **What tests it.** Fixtures must satisfy the same invariants as production, or say why
  not. A fixture that could never occur in production can hide the bug a change introduces.
- **What pays for it.** A change to a data format or protocol states its size or cost
  change, and a variable-size field needs a reason.

Then run the project's linter on the changed files and clear unused-import warnings, which
appear when an import's only user moves elsewhere.

In this repo:

- Search `docs/`, `README.md`, NatSpec in `src/` and `test/`, `script/`, the provenance
  headers of vendored files under `lib/`, `foundry.toml`, `.gitignore`, and the tracking
  PR's description. A doc reference can be a markdown anchor (`todo.md#2-...`) or a prose
  section number (`todo.md §2`, `` `todo.md` §2 ``, `todo §2`).
- Values that must agree across chains depend on each other: a route and its chainKey, a
  home key and a provider id, the addresses of one provider's transceivers.
- A send and its quote are the paired operations most likely to drift.
- LayerZero, CCIP, and Hyperlane price a payload per byte, so a change to a payload's size is a
  cost change on those three; Wormhole's Executor and the two OP Stack providers do not.
- Lint with `forge lint`; for files under `src/`, also run it with
  `FOUNDRY_PROFILE=lint-src`, which is what CI enforces there.
- Run `forge build --sizes src` after a change to a deployed contract: CI fails any over
  EIP-170, and `forge test` does not check it.

## Generalize before duplicating

When the same logic appears, or is about to appear, in two or more contracts, put it in one
place and inherit or call it: a base contract under `src/messaging/`, a shared `<P>Message`
library within a provider, or a cross-provider file under `src/protocols/` (for example
`ProviderAttribute`, which replaced five per-provider copies of attribute parsing, and
`ProviderChainId`). The plain, zkSync, and Tron variants of one provider's transceiver are
the usual place this shows up: a check added to one must not be pasted into the other two.
Tests follow the same rule. A property every binding must satisfy goes in
`ProviderBindingSpec.t.sol` behind a virtual hook, not into five suites.

It is reasonably possible unless one of these holds:

- it would change `CrossProxy`'s initcode or add storage to a base's sequential layout
  (R8.1, R8.2 in `docs/provider-spec.md`);
- the "shared" code would need a flag or branch per caller to preserve each caller's
  behavior, which is two functions pretending to be one;
- it adds a `virtual` hook with a single implementer and no second one in sight.

Before writing a new function, look for an existing one in the bases and shared libraries
that does it or nearly does it, and extend that instead.
