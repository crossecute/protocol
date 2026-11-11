# Safe guard

`CrossecuteGuard`, the Safe 1.5.0 guard described in
[`docs/safe-guard-design.md`](../../docs/safe-guard-design.md), with its tests. This is a separate
Foundry project from [`contracts/evm/`](../evm/), which nothing here changes.

## Layout

| Path | What it holds |
| --- | --- |
| `src/CrossecuteGuard.sol` | The guard: `sendMessage` and `bootstrap` staging, consumption and cleanup, module rejection of both selectors and of `registerRoot`, child approval cache, Merkle leaf publication and the published-root check on `registerRoot` |
| `src/ICrossecuteGuard.sol` | What a transmitter, relayer or publisher calls: `consume`, `getApproval`, `publishLeaves`, `isPublished`, their events and errors; above it, the file-level `SafeTx` and `SignedSafeTx` structs the guard, transmitter and receiver share |
| `src/GuardDiscovery.sol` | How a transmitter reads its owner Safe's transaction guard |
| `src/SafeHashes.sol` | Safe 1.5.0's transaction hash, message hash and domain separator, computed without calling the Safe, for the guard and the receiver |
| `src/SafeBatchExecutor.sol` | Runs several separately signed Safe transactions in one outer transaction, all or nothing: #108's atomic source batch |
| `test/SafeFixture.sol` | Real Safe 1.5.0 proxies, owner signing (EOA and nested Safe owners), owner-signed installation |
| `test/TestTransmitter.sol` | The minimal consumer and the helper contracts the tests drive |
| `test/Batch.sol` | Runs several calls in one transaction, so tests can observe transient state across executions |
| `test/*.t.sol` | `sendMessage` lifecycle, rerun for `bootstrap` in `Bootstrap.t.sol`, leaf publication and `registerRoot`, module restrictions, approval evidence, installation, hash parity with Safe, gas measurements |

`ICrossecuteGuard`, `GuardDiscovery`, `SafeHashes` and `SafeBatchExecutor` import nothing from the policy engine and
declare `pragma ^0.8.28`, so `contracts/evm/` can import them under its own compiler settings.

## Pins

| Dependency | Source | Commit |
| --- | --- | --- |
| Safe | [safe-fndn/safe-smart-account](https://github.com/safe-fndn/safe-smart-account) `v1.5.0` | `dc437e8` |
| Policy engine | [crossecute/policy-engine](https://github.com/crossecute/policy-engine) `crossecute/extension-hooks` | `f6805df` |
| forge-std | shared with `contracts/evm/lib/forge-std` | |
| OpenZeppelin `MerkleProof` (tests only) | shared with `contracts/evm/lib/openzeppelin-contracts` | |

The policy-engine fork is upstream
[safe-research/policy-engine](https://github.com/safe-research/policy-engine) at `8ee68a8` plus two
commits on `SafePolicyGuard`: internal callbacks after the owner policy check, after the module
policy check and after owner execution, and a helper that strips the policy context extension
from a signature blob. Its `main` branch mirrors upstream.

The staged selectors are `sendMessage(bytes,bytes,bytes[])` and `bootstrap(bytes,bytes[])`.
The first is `IERC7786GatewaySource.sendMessage.selector`, imported from
`contracts/evm/src/messaging/IErc7786.sol`, so the guard and the protocol cannot disagree on it.
The second, and the checked `registerRoot(bytes32)`, come from `ISignedTransmitter` in
`contracts/evm/src/messaging/outbound/ISignedTransmitter.sol`, which the signed transmitter
implements (#108). The plain `bootstrap(uint256,Call[],bytes[])` and `bootstrapTo` overloads
have other selectors and are not staged.

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

`test/SendMessageGas.t.sol` measures what staging and clearing the record of one `sendMessage` adds
to an owner transaction, against the same Safe and policy under an unmodified `SafePolicyGuard`. The
signatures are two EOA signatures (130 bytes) plus a policy extension of the given size:

| Extension bytes | Staging and cleanup |
| ---: | ---: |
| 0 | 10,446 gas |
| 1,024 | 25,748 gas |
| 10,240 | 163,033 gas |
| 102,400 | 1,464,974 gas |

The calldata is not staged, but the guard copies it into memory to build the `SafeTx` and
hashes it. With the same two signatures and a `sendMessage` payload of the given size:

| Payload bytes | Staging and cleanup |
| ---: | ---: |
| 1,024 | 10,716 gas |
| 10,240 | 13,340 gas |
| 102,400 | 39,487 gas |

A `bootstrap` takes the same staging and cleanup path. There is no byte cap, so the submitter pays this cost and a blob too large for the block
limit cannot be executed. Child approval caching is measured in
[`docs/safe-approval-evidence-sizing.md`](../../docs/safe-approval-evidence-sizing.md).

`test/LeafPublicationGas.t.sol` measures `publishLeaves` execution for 448-byte execution leaves.
The figures exclude the transaction's intrinsic and calldata cost, which grows by 512 bytes of
calldata per leaf of this size (the leaf, its offset and its length):

| Leaves | Publication |
| ---: | ---: |
| 1 | 56,011 gas |
| 3 | 69,320 gas |
| 16 | 152,876 gas |
| 256 | 1,848,419 gas |

```bash
forge test --match-contract 'SendMessageGasTest|ApprovalGasTest|LeafPublicationGasTest' -vv
```

## Signed protocol integration

`test/SignedDispatchIntegration.t.sol` runs real Safe 1.5.0 proxies, the actual guard and
actual signed Hyperlane transceivers/conduits with a mock transport. Context-specific
remappings import EVM sources into this Cancun test project; the production Paris
compiler settings remain unchanged. See
[the measured gas, sizes and test boundaries](../../docs/safe-signed-dispatch-measurements.md).

```bash
forge test --match-contract SignedDispatchIntegrationTest -vv
python3 script/lint.py -D notes
FOUNDRY_PROFILE=lint-src python3 script/lint.py -D notes src
```

The lint wrapper canonicalizes external import paths for Forge 1.8.1's Solar frontend,
which otherwise reports duplicate declarations under relative/absolute paths. It preserves
all lint rules and accepts normal `forge lint` arguments. CI uses it for both profiles.

## Licenses

Sources under `src/` and `test/` are MIT, like `contracts/evm/src/`. The vendored policy-engine
files under `lib/policy-engine/` keep their upstream `LGPL-3.0-only` headers, and Safe's keep
theirs.
