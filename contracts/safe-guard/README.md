# Safe transaction guard development

Status: interface compatibility foundation for [issue #107](https://github.com/crossecute/protocol/issues/107).
The staging MVP and production policy integration are not implemented.

Agreed retrieval design: the signature-enabled transmitter checks its owner,
reads that Safe's installed transaction guard through `getStorageAt(slot, 1)`,
and calls the guard to consume signatures held in the guard's transient storage.
It does not store a guard address during creation or accept a transient guard
pointer from the hook. Discovery and transient consumption are not implemented
by the current interface observer. See the
[guard discovery decision](../../docs/safe-guard-design.md#guard-discovery-from-the-owner-safe).

## Agreed dependency boundary

Use `ITransactionGuard` and its `BaseTransactionGuard` implementation from Safe
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
DELEGATECALL is exercised to verify the interface, not to approve staging it.

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
