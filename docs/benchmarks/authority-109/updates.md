# Authority update measurements

These measurements cover the implemented authority update paths. The historical
[43-case verifier benchmark](README.md) and its outputs remain unchanged. Reproduce
from the repository root:

```bash
FORGE=/home/carter/.foundry/bin/forge python3 docs/benchmarks/authority-109/measure-updates.py
```

The runner writes [updates.csv](updates.csv), [source hashes](updates-sources.json),
and the [source](updates-guard.log) and [receiver](updates-evm.log) logs. It rejects
failed tests, missing cases and source files changed during measurement.

Source tests compile with Solidity 0.8.30, Cancun, via-IR. They time the real
Safe 1.5.0 execution of `Batch.run([stageUpdate, execTransaction])`, including guard
verification, mutation, publication and post-hook checks. The EOA case raises the
root threshold. Each nested case adopts a leaf Safe's executed threshold change,
carrying that child's signed update. Setup, child rotation, signing and cached
approval preparation occur before timing. Calldata sizes describe the fixture's
batch ABI, which is an unpinned multicall, rather than a prescribed SDK ABI.
The guard persists only selection and verification hashes. Each source update supplies
the complete currentGraph witness, authenticated against its selected hash. This adds
512 bytes of source batch calldata for the EOA fixture, 800 for one-level adoption,
1,088 for two-level adoption and 1,440 for the shared-child fixture. Provider submission
sizes are unchanged: receivers retain full authority records and need no currentGraph
witness in update or application wire messages.

| Source case | Measured gas | Batch calldata bytes | Submission bytes | Provider body bytes |
| --- | ---: | ---: | ---: | ---: |
| EOA threshold change | 344,686 | 2,788 | 1,696 | 1,792 |
| Nested child adoption | 484,225 | 4,804 | 3,392 | 3,488 |
| Cached child approval | 517,409 | 5,476 | 4,128 | 4,224 |
| Two-level adoption | 563,916 | 5,572 | 3,776 | 3,872 |
| Shared child adoption | 698,679 | 6,788 | 4,384 | 4,480 |

Receiver tests compile the production code with Solidity 0.8.28, Paris and the
legacy compiler pipeline. They time receiver calls using portable Safe signatures.
An owner swap with a newly cached graph takes 469,979 measured gas and 1,764
calldata bytes. Two consecutive selection updates of an already cached graph take
260,592 measured gas and 3,012 calldata bytes through `submitAuthorityBatch`.
These different operations do not establish a batch-versus-single gas saving.

Timed regions use `gasleft()` differences inside Forge tests. They include call
boundaries, decoding, verification and writes, but exclude transaction intrinsic
and calldata gas. Accounts and storage can be warm from earlier fixture operations;
these are not cold-account bounds, mined receipts or delivery gas budgets. Provider
body sizes are exact, with 96 ABI bytes around each submission. Provider pricing,
verification, live lane limits and delivery gas remain separate validation work.
