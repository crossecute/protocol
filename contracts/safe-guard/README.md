# Safe guard

`CrossecuteGuard`, the Safe 1.5.0 guard described in
[`docs/safe-guard-design.md`](../../docs/safe-guard-design.md), with its tests. This is a separate
Foundry project from [`contracts/evm/`](../evm/), which nothing here changes.

## Layout

| Path | What it holds |
| --- | --- |
| `src/CrossecuteGuard.sol` | The guard: dispatch staging, consumption and cleanup, module dispatch rejection, child approval cache |
| `src/ICrossecuteGuard.sol` | What a transmitter or relayer calls: `consume`, `getApproval`, their structs and errors; the `SafeTx` struct the guard, transmitter and receiver share |
| `src/GuardDiscovery.sol` | How a transmitter reads its owner Safe's transaction guard |
| `src/SafeHashes.sol` | Safe 1.5.0's transaction hash, message hash and domain separator, computed without calling the Safe, for the guard and the receiver |
| `test/SafeFixture.sol` | Real Safe 1.5.0 proxies, owner signing (EOA and nested Safe owners), owner-signed installation |
| `test/TestTransmitter.sol` | The minimal consumer and the helper contracts the tests drive |
| `test/Batch.sol` | Runs several calls in one transaction, so tests can observe transient state across executions |
| `test/*.t.sol` | Dispatch lifecycle, module restrictions, approval evidence, installation, hash parity with Safe, gas measurements |

`ICrossecuteGuard`, `GuardDiscovery` and `SafeHashes` import nothing from the policy engine and
declare `pragma ^0.8.28`, so `contracts/evm/` can import them under its own compiler settings.

## Pins

| Dependency | Source | Commit |
| --- | --- | --- |
| Safe | [safe-fndn/safe-smart-account](https://github.com/safe-fndn/safe-smart-account) `v1.5.0` | `dc437e8` |
| Policy engine | [crossecute/policy-engine](https://github.com/crossecute/policy-engine) `crossecute/extension-hooks` | `f6805df` |
| forge-std | shared with `contracts/evm/lib/forge-std` | |

The policy-engine fork is upstream
[safe-research/policy-engine](https://github.com/safe-research/policy-engine) at `8ee68a8` plus two
commits on `SafePolicyGuard`: internal callbacks after the owner policy check, after the module
policy check and after owner execution, and a helper that strips the policy context extension
from a signature blob. Its `main` branch mirrors upstream.

The dispatch selector is `IERC7786GatewaySource.sendMessage.selector`, imported from
`contracts/evm/src/messaging/IErc7786.sol`, so the guard and the protocol cannot disagree on it.

## Build and chain support

The guard uses EIP-1153 transient storage (`TSTORE`/`TLOAD`), so it targets Cancun
(`evm_version = "cancun"`). Every owner transaction reads transient storage in the pre-hook, so
installing the guard on a chain without EIP-1153 would make every owner transaction revert,
including one that tries to remove it. Check that the chain has activated Cancun before installing.
There is no persistent-storage fallback.

Compiler settings follow the policy-engine: Solidity 0.8.30, which `SafePolicyGuard` pins exactly,
and via-IR, without which it does not compile. The output and cache directories are this project's
own. `contracts/evm/` keeps Solidity 0.8.28 and Paris, and its bytecode does not depend on
anything in this directory.

```bash
forge fmt --check
forge build --sizes src
forge lint -D notes
FOUNDRY_PROFILE=lint-src forge lint -D notes src
forge test
```

Forge warns that `../evm/lib/*` is missing from this project's `foundry.lock`. Those submodules
are pinned by `contracts/evm/foundry.lock`; the warning does not affect the build.

## Gas

`test/SendMessageGas.t.sol` measures what staging and clearing one dispatch adds to an owner
transaction, against the same Safe and policy under an unmodified `SafePolicyGuard`. The
signatures are two EOA signatures (130 bytes) plus a policy extension of the given size:

| Extension bytes | Staging and cleanup |
| ---: | ---: |
| 0 | 10,401 gas |
| 1,024 | 25,703 gas |
| 10,240 | 162,988 gas |
| 102,400 | 1,464,929 gas |

The calldata is not staged, but the guard copies it into memory to build the `SafeTx` and
hashes it. With the same two signatures and a `sendMessage` payload of the given size:

| Payload bytes | Staging and cleanup |
| ---: | ---: |
| 1,024 | 10,671 gas |
| 10,240 | 13,295 gas |
| 102,400 | 39,442 gas |

There is no byte cap, so the submitter pays this cost and a blob too large for the block
limit cannot be executed. Child approval caching is measured in
[`docs/safe-approval-evidence-sizing.md`](../../docs/safe-approval-evidence-sizing.md).

```bash
forge test --match-contract 'SendMessageGasTest|ApprovalGasTest' -vv
```

## Licenses

Sources under `src/` and `test/` are MIT, like `contracts/evm/src/`. The vendored policy-engine
files under `lib/policy-engine/` keep their upstream `LGPL-3.0-only` headers, and Safe's keep
theirs.
