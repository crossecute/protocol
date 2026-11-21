# Safe guard

`CrossecuteGuard`, the Safe 1.5.0 guard described in
[`docs/safe/safe-guard-design.md`](../../docs/safe/safe-guard-design.md), with its tests. This is a separate
Foundry project from [`contracts/evm/`](../evm/); the two projects share compatible
interfaces, types and verification libraries.

## Layout

| Path | What it holds |
| --- | --- |
| `src/CrossecuteGuard.sol` | Owner staging, consumption and cleanup, module selector checks, child approval caching, Merkle leaf publication and the publication check for top-level owner `registerRoot` calls |
| `src/authority/SourceAuthorityGuard.sol` | #109's source half, inherited by the guard: per-Safe selection hashes, executed-head record hashes, publication hashes, witness staging, activation, ownership changes, `selectAuthority`, full portable submission events and protected-call rules. Shared ReceiverAuthority verification authenticates the supplied current graph; receivers retain full authority records. |
| `src/authority/ISourceAuthorityGuard.sol`, `AuthorityUpdateTypes.sol` | The source authority interface and its selection and update types |
| `src/ICrossecuteGuard.sol` | What a transmitter, relayer or publisher calls: `consume`, `getApproval`, `publishLeaves`, `isPublished`, their events and errors; above it, the file-level `SafeTx` and `SignedSafeTx` structs the guard, transmitter and receiver share |
| `src/GuardDiscovery.sol` | How a transmitter reads its owner Safe's transaction guard |
| `src/SafeHashes.sol` | Safe 1.5.0's transaction hash, message hash and domain separator, computed without calling the Safe, for the guard and the receiver |
| `src/SafeBatchExecutor.sol` | Runs several separately signed Safe transactions in one outer transaction, all or nothing: #108's atomic source batch |
| `test/SafeFixture.sol` | Real Safe 1.5.0 proxies, owner signing (EOA and nested Safe owners), owner-signed installation |
| `test/TestTransmitter.sol` | The minimal consumer and the helper contracts the tests drive |
| `test/Batch.sol` | Runs several calls in one transaction, so tests can observe transient state across executions |
| `test/SourceAuthority*.sol` | Activation, ownership changes, selectAuthority, portable publication, protected calls and nested-Safe adoption against real Safe 1.5.0 proxies |
| `test/SignedDispatchIntegration.t.sol`, `test/SignedOftIntegration.t.sol` | Real Safe/guard/conduit bootstrap and dispatch, direct/provider replay and authority updates over mock Hyperlane and OFT transport |
| `test/*.t.sol` | `sendMessage` lifecycle, rerun for `bootstrap` in `Bootstrap.t.sol`, leaf publication and `registerRoot`, module restrictions, approval evidence, installation, hash parity with Safe, gas measurements |

`ICrossecuteGuard`, `GuardDiscovery`, `SafeHashes` and `SafeBatchExecutor` import nothing from the policy engine and
declare `pragma ^0.8.28`, so `contracts/evm/` can import them under its own compiler settings.

## Pins

| Dependency | Source | Commit |
| --- | --- | --- |
| Safe | [safe-fndn/safe-smart-account](https://github.com/safe-fndn/safe-smart-account) `v1.5.0` | `dc437e8` |
| Policy engine | [crossecute/policy-engine](https://github.com/crossecute/policy-engine) `crossecute/safe-policy-timing-171` | `91bd2b8` |
| forge-std | shared with `contracts/evm/lib/forge-std` | |
| OpenZeppelin `MerkleProof` (tests only) | shared with `contracts/evm/lib/openzeppelin-contracts` | |

The policy-engine fork is upstream
[safe-research/policy-engine](https://github.com/safe-research/policy-engine) at `8ee68a8`.
The fork provides owner and module guard callbacks, a signature helper that strips policy context,
and the shared configuration request logic in `SafePolicyGuardBase`.

The staged selectors are `sendMessage(bytes,bytes,bytes[])` and `bootstrap(bytes,bytes[])`.
The first is `IERC7786GatewaySource.sendMessage.selector`, imported from
`contracts/evm/src/messaging/IErc7786.sol`, so the guard and the protocol cannot disagree on it.
The second, and the checked `registerRoot(bytes32)`, come from `ISignedTransmitter` in
`contracts/evm/src/messaging/outbound/ISignedTransmitter.sol`, which the signed transmitter
implements (#108). A plain-mode transmitter's `bootstrap` has the same selector, so the guard
stages it too and the post-hook clears the unconsumed record.

Every owner execution holds a per-Safe lock until its matching post-hook, even when no
message is staged. Same-Safe owner and guarded module reentry and stageUpdate reject
during that execution. Separate executions after cleanup and other Safes remain usable.
The pinned MultiSendCallOnly executor is accepted only for recognized authority-change
batches, including before activation; ordinary owner batches and module batches reject.
Signed `sendMessage` calls inside MultiSend are unsupported.

See the [publication and registration rules](../../docs/safe/safe-guard-design.md#merkle-leaf-publication)
for indexer inputs and the scope of the pre-hook check.

## Policy configuration timing

The `CrossecuteGuard` constructor takes only the [authority pins](../../docs/safe/safe-authority-updates.md#source-guard-and-mutation-batch).
The default for every Safe is zero delay and no expiry. Read a Safe's effective settings in
seconds with `configurationTiming(safe)`. A Safe can call `configureTimingImmediately(delay, expiry)`
before this guard occupies either of its guard slots. Include the call before setting either slot
in the owner-approved [installation batch](../../docs/safe/safe-guard-design.md#installation).
Initial setup and later changes accept a delay from zero through `MAX_CONFIGURATION_DELAY`
(365 days).

Once installed, a timing change takes two Safe owner calls to the guard.

1. Compute `timingConfigurationRoot(delay, expiry)` and pass it to `requestConfiguration(root)`.
2. Once the request matures, call `applyConfigurationTiming(delay, expiry)` with the same values.
   The guard emits `ConfigurationTimingSet` when it stores the override.

Policy changes use the same `requestConfiguration` entry point and still apply with
`applyConfiguration(configurations)`. Both kinds of requests capture the Safe's delay and expiry
when requested. Each request stores two 32-byte words. `rootConfigured(safe, root)` returns
the maturity timestamp. `rootExpiry(safe, root)` returns the captured expiry in seconds or zero
for an absent request. The request can be applied from maturity through the last second before
its window closes. Use `type(uint256).max` for a window that never closes. Zero expiry is rejected.
The Safe can call `invalidateRoot(root)` to discard a request. An expired root can be requested
again under the Safe's current timing.

## Build and chain support

The guard uses EIP-1153 transient storage (`TSTORE`/`TLOAD`), so it targets Cancun
(`evm_version = "cancun"`). Every owner transaction reads transient storage in the pre-hook, so
installing the guard on a chain without EIP-1153 would make every owner transaction revert,
including one that tries to remove it. Check that the chain has activated Cancun before installing.
There is no persistent-storage fallback.

Compiler settings follow the policy-engine: Solidity 0.8.30, which `SafePolicyGuardBase` pins exactly,
and via-IR, without which it does not compile. The output and cache directories are this project's
own. `contracts/evm/` keeps Solidity 0.8.28, Paris and the legacy compiler pipeline, importing
only the compatible interfaces, types and hash helpers from this directory.

```bash
forge fmt --check
forge build --sizes src
python3 script/lint.py -D notes
FOUNDRY_PROFILE=lint-src python3 script/lint.py -D notes src
forge test
```

Forge warns that `../evm/lib/*` is missing from this project's `foundry.lock`. Those submodules
are pinned by `contracts/evm/foundry.lock`; the warning does not affect the build.

## Gas

### Signature staging and cleanup

`test/SendMessageGas.t.sol` measures what staging and clearing the record of one `sendMessage` adds
to an owner transaction, against the same Safe and policy under an unmodified `SafePolicyGuard`. The
signatures are two EOA signatures (130 bytes) plus a policy extension of the given size:

| Extension bytes | Staging and cleanup |
| ---: | ---: |
| 0 | 16,263 gas |
| 1,024 | 31,526 gas |
| 10,240 | 168,827 gas |
| 102,400 | 1,471,173 gas |

The calldata is not staged, but the guard copies it into memory to build the `SafeTx` and
hashes it for the execution lock and staged record. With the same two signatures and a
`sendMessage` payload of the given size:

| Payload bytes | Staging and cleanup |
| ---: | ---: |
| 1,024 | 16,723 gas |
| 10,240 | 21,118 gas |
| 102,400 | 64,973 gas |

A `bootstrap` takes the same staging and cleanup path. There is no byte cap, so the submitter pays this cost and a blob too large for the block
limit cannot be executed.

### Child approval evidence sizing

The sizing fixture from [issue #107](https://github.com/crossecute/protocol/issues/107)
uses a 2-of-2 parent Safe with a 10-of-13 child and a 5-of-7 child. Each child
approves with exactly its threshold of EOA signatures. See the
[guard design](../../docs/safe/safe-guard-design.md#persistent-child-approval-evidence)
for how the guard records and retrieves child approvals.

[`ApprovalGas.t.sol`](test/ApprovalGas.t.sol) runs each child's `signMessage` transaction
under `CrossecuteGuard` and under an unmodified `SafePolicyGuard` with the same policy.
The difference measures the cost of caching the approval.

#### Approval calldata

Safe 1.5.0 asks a contract owner to validate `abi.encode(parentTxHash)`, 32 bytes. The child
approves it with a direct delegatecall to `SignMessageLib.signMessage(bytes)`, whose calldata is
100 bytes: selector, offset, length and one padded word.

The parent then carries an empty payload for each child: two 65-byte contract-signature headers
and two zero length words, 194 bytes. The child evidence travels next to that blob, not inside it.

#### Storage and gas costs

`CrossecuteGuard` stores each approval as a `SignedSafeTx` struct, a `SafeTx` followed by the
signatures, in persistent storage. It writes these slots:

| Slots | Field |
| ---: | --- |
| 1 | `to` |
| 1 | `value` |
| 5 | `data`: one length slot and four data slots for 100 bytes |
| 1 | `operation` |
| 4 | `baseGas`, `gasToken`, `refundReceiver`, `nonce` |
| 1 + ⌈n / 32⌉ | `signatures`, n bytes |

The struct also has `safeTxGas` and `gasPrice` slots. The guard never writes them, since the
inherited policy check requires both to be zero, so they always read as zero.

| | 10-of-13 child | 5-of-7 child | Total |
| --- | ---: | ---: | ---: |
| Owner signatures | 650 bytes | 325 bytes | 975 bytes |
| Slots written | 34 | 24 | 58 |
| `getApproval` return, ABI-encoded | 1,280 bytes | 960 bytes | 2,240 bytes |
| Measured cache cost | 687,294 gas | 465,531 gas | 1,152,825 gas |
| At 1 gwei and $2,000/ETH | $1.37 | $0.93 | $2.31 |

The measured cost includes the storage writes, message hashing and the per-Safe execution
lock, including its Safe transaction hash and nonce read. It is close to the slot arithmetic:
under the EIP-2929 schedule a fresh nonzero slot costs 22,100 gas and a zero written over zero costs 2,200,
and in this shape `value` and the three payment fields are zero. A replacement for the same child
and message writes over existing slots and costs less. These measurements use no policy
extension. Approvals with an extension additionally read the Safe's threshold and check each
required signature's bounds before stripping it. The stored and returned formats are unchanged.

Reading a record back with `getApproval` loads every slot of the struct, the two unwritten ones
included: 62 slots for both records, about 130,200 gas onchain at 2,100 per cold slot. An offchain
`eth_call` costs the caller nothing.

### Leaf publication

`test/LeafPublicationGas.t.sol` measures `publishLeaves` execution for 448-byte execution leaves.
The figures exclude the transaction's intrinsic and calldata cost, which grows by 512 bytes of
calldata per leaf of this size (the leaf, its offset and its length):

| Leaves | Publication |
| ---: | ---: |
| 1 | 56,232 gas |
| 3 | 69,545 gas |
| 16 | 153,121 gas |
| 256 | 1,849,034 gas |

```bash
forge test --match-contract 'SendMessageGasTest|ApprovalGasTest|LeafPublicationGasTest' -vv
```

## Signed protocol integration

`test/SignedDispatchIntegration.t.sol` runs real Safe 1.5.0 proxies, the actual guard and
actual signed Hyperlane transceivers/conduits with a mock transport. Context-specific
remappings import EVM sources into this Cancun test project; the production Paris
compiler settings remain unchanged. See
[the measured gas, sizes and test boundaries](../../docs/benchmarks/safe-signed-dispatch-measurements.md).

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
