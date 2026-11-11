# Safe-signed dispatch measurements

Measured 2026-11-11 at code commit `c598ef99da5453590a08d7329183b0106bcdc7f1`
(Forge 1.8.1). This completes #134's reproducible local measurements and real-Safe
integration tests. These are execution-gas observations, not live provider fee quotes.
No fork RPC was configured; no transaction was broadcast.

## Production Paris receiver

`contracts/evm/test/signed/SignedDispatchGas.t.sol` compiles the real Hyperlane receiver
and shared authority verifier with production Solidity 0.8.28, Paris, optimizer 200,
without via-IR or metadata. Owner signatures are genuine ECDSA signatures. Child
approval evidence is independently signed. The real-Safe source integration is measured
separately below because its guard needs a different compiler/EVM target.

Before each sample, `vm.cool` resets account and storage access warmth for the receiver,
its implementation, the authority library and the application target. Figures include
an external call and ABI encoding/decoding, but exclude transaction intrinsic/calldata
charges, transport verification and relayer transaction overhead. `initializeSigned`
excludes CREATE2, the plain initializer, transceiver graph/address validation and setup
application calls. Its bootstrap body size excludes the 192-byte outer signed envelope.
Standalone/Merkle sizes are complete protocol wire bundles, including evidence.

All baseline cases use one application call and an empty proof/attribute list. The
large parent is 2-of-2, owning a 10-of-13 child and a 5-of-7 child. The combined case adds
ten application calls, eight proof siblings and one 256-byte attribute. Other variants
change only the named dimension. Merkle is measured after standalone, so the sink's
state is already nonzero: the two gas columns are not an isolated comparison of formats.

| Graph / variant | initializeSigned gas | Standalone gas | Merkle gas | Bootstrap body bytes | Standalone bytes | Merkle bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2-of-3 EOA | 306,208 | 168,011 | 158,130 | 1,792 | 1,376 | 1,600 |
| One inline child | 387,931 | 176,859 | 167,027 | 2,112 | 1,472 | 1,696 |
| One cached approval | 402,873 | 191,845 | 181,977 | 2,848 | 2,208 | 2,432 |
| Two nested levels | 470,161 | 185,974 | 176,115 | 2,432 | 1,568 | 1,792 |
| Shared child | 595,644 | 213,497 | 203,724 | 3,040 | 1,888 | 2,112 |
| 10-of-13 + 5-of-7 inline | 1,011,348 | 288,812 | 279,145 | 4,352 | 2,400 | 2,624 |
| 10-of-13 + 5-of-7 cached | 1,040,412 | 317,857 | 308,316 | 5,824 | 3,872 | 4,096 |
| 2-of-10 EOA | 495,410 | 168,025 | 158,146 | 2,240 | 1,376 | 1,600 |
| EOA, proof depth 8 | 306,208 | 168,011 | 165,516 | 1,792 | 1,376 | 1,856 |
| EOA, 10 calls | 306,208 | 231,947 | 222,593 | 1,792 | 3,968 | 4,192 |
| EOA, 256-byte attribute | 306,208 | 172,091 | 161,768 | 1,792 | 1,696 | 1,920 |
| Large cached, 10 calls, depth 8, attribute | 1,040,412 | 386,526 | 384,971 | 5,824 | 6,784 | 7,264 |

An eight-sibling proof adds 256 wire bytes; ten calls add 2,592 bytes in this fixture.
A 256-byte attribute adds 320 bytes including array/element framing. Increasing the
stored EOA owner count from 3 to 10 adds 448 bootstrap bytes and about 189k initialization
gas while keeping the 2-signature quorum; it barely changes subsequent verification.
Nesting adds stored records and message-domain checks. Cached approvals replace inline
child payloads with complete signed Safe transactions, increasing the wire size.

## Source integration with Safe 1.5.0

`contracts/safe-guard/test/SignedDispatchIntegration.t.sol` uses actual Safe proxies,
the actual Crossecute guard (its existing inspection harness adds no overrides), actual
Hyperlane transceivers, transmitters and receivers, and a mock mailbox only. Source chain
10 and destination chains 8453/42161 use separately registered deployers so all three
chains' contract state can coexist in one test EVM. The stateless deployer is copied to
its canonical address for this test build; this does not assert production deployment
bytecode parity. Each endpoint derives real signed conduit addresses from its registry.

The guard project uses Solidity 0.8.30, Cancun, via-IR, optimizer 200. Source numbers
include Safe signature checks, guard staging/consumption, nested-evidence collection,
and the mock mailbox's persistent journal of every payload byte. They exclude intrinsic
transaction gas, prior leaf publication/child approvals, and real provider infrastructure.
They are reproducible fixture observations with ordinary within-test access warmth,
not production provider gas budgets. The source fixture's sink calldata is shorter than
the Paris fixture's, hence its standalone bundles differ by 96 bytes.

| Graph | Safe bootstrap gas | Safe send gas | Safe register gas | relayLeaf gas | Full bootstrap envelope bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2-of-3 EOA | 1,868,392 | 1,119,977 | 128,653 | 1,261,194 | 1,984 |
| One inline child | 2,125,763 | 1,197,160 | 151,316 | 1,336,098 | 2,304 |
| One cached approval | 2,575,321 | 1,637,270 | 135,726 | 1,781,793 | 3,040 |
| Two nested levels | 2,400,940 | 1,292,131 | 171,590 | 1,428,802 | 2,624 |
| Shared child | 2,938,028 | 1,596,429 | 213,401 | 1,725,542 | 3,232 |

Integration assertions cover: one-transaction staging/consumption/delivery and replay;
real cached `signMessage` approval collection and destination verification; nested/shared
child message domains; published two-destination tree parity and independent relay;
Safe nonces 42/43 in one batch, destination binding, and complete rollback on the second
source failure; bootstrap before source execution; direct standalone and leaf submission
without source execution/publication; and source acceptance followed by destination
out-of-gas, unchanged destination nonce and a successful exactly-once direct retry.
The existing `SafeBatchExecutorTest` separately covers Safe's `false` return path; the
installed guard refuses the nonzero payment-gas setting required to reach that path.

## Delivery gas decision

**The inherited 200,000 payload and 1,000,000 bootstrap defaults are unsuitable as
general signed-delivery defaults. Always supply an explicit gas attribute for signed
provider delivery.** The shared-child sample exceeds 200k, and the large graph exceeds
1m for `initializeSigned` alone, before deployment and transceiver work. An unbounded
authority graph and arbitrary application calls admit no universally sufficient constant.
#108 intentionally adds neither resource caps nor a minimum gas floor.

Simulate the exact bundle against the destination's provider entry point and current
state. For bootstrap, simulate the entire destination transceiver call, not just
`initializeSigned`. Budget a margin for provider framing, chain-specific costs and the
application, and recheck the provider's own lane gas cap. A limit such as 500,000 covers
the measured Paris payload samples with some margin, but is not a guarantee for another
application or provider. Use `GasAttribute.forMultisig(provider, estimatedGas)` from
`contracts/evm/script/deploy/GasAttribute.sol`:

| Binding | Explicit gas input |
| --- | --- |
| LayerZero | `GasAttribute.layerZero(gas)`; Type-3 lzReceive options |
| CCIP | `GasAttribute.ccip(gas)`; EVMExtraArgsV2 gasLimit |
| Hyperlane | `GasAttribute.hyperlane(gas)`; hook gas-limit metadata |
| OP Stack L1/L2 | `GasAttribute.opStack(gas)`; messenger minimum gas |
| Wormhole | Signed executor quote plus gas in its execution attribute, or publish-only and manually deliver with enough gas |
| OP Stack L2/L2 | Relayer selects execution gas; this binding accepts no gas attributes |

For Merkle delivery these attributes must be committed in the leaf before signing the
root; changing them requires a new leaf/root authorization. Direct submission ignores
provider options and is the bridge-independent retry path. Reverting destination
execution rolls back its replay state, but a successful source send stays marked used.

## Provider size and per-byte fee checks

The largest tested Merkle wire is 7,264 bytes, its standalone wire 6,784 bytes, and the
large bootstrap envelope is 6,016 bytes (5,824 + 192). These are a concrete realistic
sizing case, not upper bounds. There is no Crossecute payload cap. Further nesting,
approvals, signatures, calls or proofs can exceed any provider's configured limits.

| Provider | Size check against the measured case | Per-byte pricing / additional framing |
| --- | --- | --- |
| LayerZero V2 | 7,264 fits a lane configured for 10,000 bytes; query the actual send library's `getExecutorConfig(oapp, dstEid).maxMessageSize` before sending | Executor `getFee` takes message size. Pricing depends on lane/executor/options and treasury; no universal wei-per-byte rate. Use Endpoint `quote` with the exact bundle. |
| CCIP V1 EVM | 7,264 is below the documented 30-kilobyte service limit; the lane's actual `maxDataBytes` is authoritative | FeeQuoter uses destination payload-byte gas rates (including a high-rate threshold in v1.6.3), DA-byte gas, gas/token prices and multipliers. Call Router `getFee` on the exact `EVM2AnyMessage`. |
| Hyperlane EVM | Current upstream Mailbox has no universal body-size cap; deployed hooks, ISM and relayer policy can impose one. The 2-KiB cap in the Fuel implementation is not an EVM limit | The packed Hyperlane header adds 77 bytes; hook metadata is separate. Query `quoteDispatch` with the exact body and refund metadata. |
| Wormhole Core + Executor | No universal cap asserted for all Core/executor deployments; validate the selected route and relay provider's acceptance of the complete payload | Binding adds 34 destination bytes. A VAA adds 57 header bytes plus 66 per guardian signature; executor quote and Core messageFee determine price. |
| OP Stack L1/L2 | Check the deployed portal/messenger's transaction/resource limits; no single cross-chain byte cap is assumed | Recipient calldata is 68 bytes plus the 32-byte-padded wire; L1 data/resource metering contributes to source gas. Binding's native fee quote is zero. |
| OP Stack L2/L2 | Check the chain's actual interop configuration, transaction limit and relayer acceptance; not asserted deployed | Same 68-byte recipient-call framing. Binding quote is zero; relayer transaction costs remain. |

A provider cap is a configuration/deployment property. This local run does not certify
any live lane. To obtain a **numeric marginal fee per byte**, quote the same lane/options
at wire lengths `n` and `n + 32` in one block and compute `(fee(n+32)-fee(n))/32`, in source
native wei. Account for step thresholds and re-quote at each actual size. No fixed
numeric LayerZero or CCIP fee is invented from mock fees or from an unspecified lane.

Primary references checked 2026-11-11:

- [LayerZero SendLibBase: configured size cap and size-dependent executor quote](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/messagelib/contracts/SendLibBase.sol).
- [CCIP V1 EVM service limits](https://docs.chain.link/ccip/v1/evm/service-limits) and [v1.6.3 FeeQuoter configuration](https://docs.chain.link/ccip/v1/evm/api-reference/v1.6.3/fee-quoter).
- [Hyperlane EVM Mailbox](https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/Mailbox.sol).
- OP Stack/Wormhole framing above follows the pinned local `OpStackMessage`,
  `OpStackInteropMessage` and `WormholeMessage` implementations.

## Sizes and reproduction

| Production contract | Runtime bytes | EIP-170 headroom |
| --- | ---: | ---: |
| CcipTransmitter | 24,041 | 535 |
| LzTransmitter | 23,934 | 642 |
| HyperlaneTransmitter | 23,632 | 944 |
| SignedTransmitterLib | 13,943 | 10,633 |
| CrossecuteGuard (Cancun) | 9,880 | 14,696 |
| SafeBatchExecutor (Cancun) | 699 | 23,877 |

All production contracts pass `forge build --sizes src`. No deployment inputs, compiler
settings or proxy bytecode changed in the Paris project. The guard project's contextual
remappings allow integration imports without changing the production build. Its
`script/lint.py` canonicalizes external dependency paths for Forge 1.8.1's Solar linter,
which otherwise treats relative and absolute paths as separate declarations. CI runs it
for both the default and source-only lint profiles; no rule is disabled by the wrapper.

```bash
# Run each group from the repository root.
(cd contracts/evm && forge test --match-contract SignedDispatchGasTest -vv)
(cd contracts/evm && forge build --sizes src)
(cd contracts/safe-guard && forge test --match-contract SignedDispatchIntegrationTest -vv)
(cd contracts/safe-guard && python3 script/lint.py -D notes)
(cd contracts/safe-guard && FOUNDRY_PROFILE=lint-src python3 script/lint.py -D notes src)
```
