# Safe transaction guard development

Status: interface compatibility foundation for [issue #107](https://github.com/crossecute/protocol/issues/107).
The staging MVP and production policy integration are not implemented.

Production must prevent a compromised bridge from forging execution or authority
updates and must support nested Safe owners from the first signature-enabled
release. Preserve full nested signature data. Authority synchronization and the
nested-Safe update guard are being designed in
[issue #109](https://github.com/crossecute/protocol/issues/109); the observer tests
do not establish destination verification or authenticated signer updates.

Agreed deployment model: share one guard across multiple Safes, following
`SafePolicyGuard`. Policy configuration and pending changes remain per Safe;
transient lifecycle and signature records must also be keyed by Safe. Each Safe
independently installs the guard. The current single-Safe observer is compatibility
evidence only; shared staging and two-Safe isolation tests remain unimplemented.

Agreed retrieval design: the signature-enabled transmitter checks its owner,
reads that Safe's installed transaction guard through `getStorageAt(slot, 1)`,
and calls the guard to consume signatures held in the guard's transient storage.
It does not store a guard address during creation or accept a transient guard
pointer from the hook. Discovery and transient consumption are not implemented
by the current interface observer. See the
[guard discovery decision](../../docs/safe-guard-design.md#guard-discovery-from-the-owner-safe).

Agreed staging trigger: match only the `sendMessage(bytes,bytes,bytes[])` selector,
without filtering the target or operation. Retain the actual signed target in the
context and allow only that address to consume it. Staging is not implemented yet.

## Agreed dependency boundary

The existing test observer uses `ITransactionGuard` and `BaseTransactionGuard` from Safe
1.5.0, pinned to `dc437e8fba8b4805d76bcbd1c668c9fd3d1e83be`. Use Safe 1.3.0,
pinned to `186a21a74b327f17fc41217a927dea7064f74604`, for the real singleton/proxy
fixture. Git submodules and `foundry.lock` record both commits. The test library
uses the protocol's existing forge-std pin in `../evm/foundry.lock`.

`safe-interface/` imports the newer guard interface and base. `safe-fixture/`
imports the older singleton, proxy and transaction types only for tests. There is
one concrete hook implementation, `test/TransactionGuardHarness.sol`, with no
version branches or copied interface declarations. Its conversion between the
two dependencies' Solidity enum types preserves the common ABI's `uint8` encoding.
The upstream base provides ERC-165 and transaction-guard interface support.

Agreed production inheritance: extend a minimally refactored `SafePolicyGuard`,
reusing its policy engine and configuration, then add signature staging and cleanup.
The [local fork patch](patches/safe-policy-guard-extension-hooks.patch) applies to
Safe Research `policy-engine` at `8ee68a8cdac65b4aba5d9a10e9f9018c2efb10b3`
(LGPL-3.0-only). It adds three internal callbacks and keeps the external hook
selectors fixed. Preserve the newer hook ABI and ERC-165
support without requiring a second independent production hook base. `SafenetPolicy`
remains a selectable policy called by the guard. This production inheritance is
documented, not implemented. See the
[integration decision](../../docs/safe-guard-design.md#production-inheritance-and-policy-integration).

To prepare a fork checkout, clone `safe-research/policy-engine`, check out the
revision above and run `git apply /absolute/path/to/safe-policy-guard-extension-hooks.patch`
from the fork root. Use its lockfile and Solidity 0.8.30 Cancun build settings.

The harness observes calls and rejects callers other than its configured Safe.
It is test-only: it records hook data in persistent storage, performs no policy
checks, and is not an installable staging product. No production guard is exposed
under `src/` until the remaining lifecycle and format decisions are resolved.

## Evidence and limits

`test/TransactionGuard.t.sol` verifies interface support, rejection of invalid
interface IDs, and selector agreement with Safe 1.3's `Guard`. The fixture installs
through an owner-signed `setGuard` transaction on an actual singleton and proxy.
Execution tests cover original signature bytes, nonce and pre/post digest
agreement, executor identity, value, gas/refund fields, CALL and DELEGATECALL
encoding, both failure paths, replacement, removal and direct-hook rejection.
DELEGATECALL is exercised to verify the interface; selector-only staging for both
operations still needs lifecycle tests.

Tested runtime compatibility is limited to the Safe 1.3.0 source fixture compiled
with the compiler below. These tests do not attest deployed singleton bytecode,
provide 1.4/1.5 runtime coverage, or demonstrate module-policy support. The older
Safe does not check ERC-165 at installation, so the suite tests those responses
directly. Module guards remain a separate production design decision.

## Reproduce

From the repository root:

```sh
git submodule update --init
cd contracts/safe-guard
forge fmt --check
forge build
forge lint -D notes
forge test -vvv
```

This project pins Solidity 0.8.28 and Cancun, with its own output/cache paths.
The existing Paris project configuration and artifacts are not imported or
changed. Adding actual transient storage still requires its gas, lifecycle,
unsupported-source and protocol-artifact checks from the
[build plan](../../docs/safe-guard-build-plan.md).
