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

## When a fact changes, find every place that states it

Moving, deleting, or renumbering a doc section, resolving a todo item, or changing what the
code does (a status, a default, a check) invalidates every other place that states or cites
the old fact. Before committing such a change:

1. Grep the whole repo for each form a reference can take: the markdown anchor
   (`todo.md#2-...`), the prose section number (`todo.md §2`, `` `todo.md` §2 ``, `todo §2`),
   and the old claim's own wording (`SendNotImplemented`, "placeholder", "template", "not
   wired", "three bindings", a test count). Search `docs/`, `README.md`, NatSpec in `src/`
   and `test/`, `script/`, the provenance headers of vendored files under `lib/`,
   `foundry.toml`, `.gitignore`, and the tracking PR's description.
2. Open every hit and confirm the target still says what the citation claims. An anchor that
   resolves is not enough: a renumbered section can resolve to text that no longer contains
   the cited item. If the item was deleted, repoint the citation to where the fact now lives
   (README, `provider-research.md`, the implementing contract) or drop it.
3. Run `forge lint` on the changed files and clear `unused-import`, which appears when an
   import's only user moves elsewhere.

A citation that was already wrong before your change still gets fixed when you find it.

## Generalize before duplicating

When the same logic appears, or is about to appear, in two or more contracts, put it in one
place and inherit or call it: a base contract under `src/messaging/`, a shared `<P>Message`
library within a provider, or a cross-provider file under `src/protocols/` (for example
`ProviderAttribute`, which replaced five per-provider copies of attribute parsing, and
`ProviderChainId`). Hub, spoke, and zkSync/Tron divergent variants of one provider are the
usual place this shows up: a check added to one must not be pasted into the other two.
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
