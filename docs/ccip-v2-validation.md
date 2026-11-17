# CCIP 2.0 local validation

Recorded 2026-11-17 for PR #149 and issue #150. All production V3 lane flags remain
disabled by default. Local tests and compilation do not establish live-lane readiness;
that work is tracked in [deployment issue #118](https://github.com/crossecute/protocol/issues/118).

## Tests

The complete suite passed: 1,077 tests across 122 suites, with 3 existing skips and no
failures. Formatting, both Forge lint profiles, EVM sizes, selector collisions, npm
consumer compilation and pinned-artifact reproduction also passed.

`forge test` includes shared option tests against the actual user transmitter and the
transceiver sending path. They check omitted and explicit defaults, V3 enable/disable
and re-enable behavior, shared lane reads, no provider-error fallback, gas/finality
round trips, exact wire bytes and fees, custom verifier/executor/No Exec options,
malformed/mixed attributes, narrowing and codec limits, and owner-only enablement.
Policies and proxy interfaces are checked on the receiver and all three transceiver
variants, including V3 quotes on every variant. Source/sender isolation, authorization,
self-call configuration, policy reset, invalid settings, the ERC-7201 location, unchanged
sequential slots, and the implementation slot are covered.

`CcipOffRamp.t.sol` deploys the exact OffRamp 2.0.0 and packaged Router creation binaries
from the pinned npm package, verifies artifact hashes, and uses their public entry points.
The RMN is a local uncursed dependency. Two local verifiers check distinct signing keys'
attestations over the exact encoded message hashes. These controlled verifier dependencies
are not production CCV services. No OffRamp enforcement logic is mocked.

The integration tests cover default-CCV resolution, required and optional verification,
invalid attestations, finality acceptance/rejection, policy changes with pending messages,
wrong senders, gateway revocation, reentrancy rejection, gas overrides, receiver funding,
failed execution and retry, replay rejection, custom execution and permissionless later
execution of a No Exec message. They do not simulate source consensus reorganizations,
production proof generation, executor scheduling, or live source-side fee services.

The protocol's 200,000-gas payload callback succeeded through the actual Router with one
state-changing application call. The measured local OffRamp execution used 219,125 gas,
including test proof preparation and OffRamp/verifier/router overhead outside the
callback. This is an EVM observation, not an EraVM/TVM measurement or a production fee.
The suite selects Cancun execution for the upstream binaries; protocol compilation
remains Paris.

Artifact provenance, package archive and file checksums, and reproduction instructions
are in [the fixture directory](../contracts/evm/test/fixtures/ccip-v2/README.md).

## Native compilation

Run the standalone native compilation helper with explicit compiler paths:

```sh
python3 contracts/evm/test/protocols/ccip/native-compile.py \
  --kind eravm --compiler "$ZKSOLC" --solc "$ZKSYNC_SOLC"
python3 contracts/evm/test/protocols/ccip/native-compile.py \
  --kind tron --compiler "$TRON_SOLC"
```

It resolves the real transitive production sources and repo remappings, uses the pinned
Paris target/optimizer settings, and writes input, output, diagnostics and a summary to
`contracts/evm/out/ccip-native/<kind>/`. Summaries include compiler hashes, the source
manifest hash, bytecode hashes and sizes. The native compiler's own bytecode format and
metadata handling apply; these are not interchangeable deployment artifacts or hashes.

Both runs used source manifest SHA-256
`aaec92753b7b3668128933c3b36813f29f92ed3b83c58fcb71c0a68690fbf000`.

| Compiler | SHA-256 |
| --- | --- |
| zksolc 1.5.15 (LLVM fa0fc0bc9caa7884f9f485735b537cb1ac441fe7) | `b52df6ae7e64903deb4972f8a41c9c666a7ce1dfdce38680f387df01afe51b4b` |
| Tron Solidity 0.8.28+commit.9c4253d2 | `0eba121b08e9fbc1019e71bb6d36467a7f653929af9f51a793a17688d859f856` |

The Tron compiler was fetched from the official `tronprotocol/solidity` release
`tv_0.8.28` and checked against its published `shasum.txt`.

| Native build | Creation bytes | Runtime bytes where reported |
| --- | ---: | ---: |
| EraVM CcipZkSyncTransceiver | 118,688 | Not a separate EVM runtime artifact |
| EraVM CcipReceiver | 59,168 | Not a separate EVM runtime artifact |
| EraVM CcipTransmitter | 109,600 | Not a separate EVM runtime artifact |
| TVM CcipTronTransceiver | 27,491 | 25,271 |
| TVM CcipReceiver | 14,770 | 14,481 |
| TVM CcipTransmitter | 22,845 | 22,618 |

Both compilers produced the requested bytecode without errors. The Tron compiler reports
a generic EVM-size warning for the 25,271-byte runtime. This report does not equate that
warning with an enforced TVM limit or claim successful native deployment. Actual native
deployment, derived addresses, execution/energy measurements and gas budgets remain
explicit rollout gates in deployment issue #118. The separate standard-solc EVM size check passes; the
zkSync variant's EVM runtime is 24,437 bytes, with 139 bytes below EIP-170.
