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
