# Safe authority signature gas benchmark

Measured 2026-11-13 using the existing #107/#108 destination verifier in the #109
planning checkout. This does not implement #109 contracts or select graph bounds.
All 43 configurations passed verification and wrong-digest rejection controls.

For the [16-owner transfer-size comparison](analysis-16.md), see its separate table.
For the expanded 32-owner measurements, exact transfer wire sizes and transport
implications, see [32-owner analysis](analysis-32.md). The tables below retain the
16/24-signer comparisons; raw results include all 43 cases.

## Fixed total EOA signatures

All owners at every Safe must sign. EOAs use unique public fixture private keys.
Sibling cases distribute all EOAs evenly among the listed direct children; the
root owns those children only. Chains have one Safe owner per intermediate Safe,
with all EOA owners at the deepest Safe. Root depth is zero; child counts exclude
root. Every nested signature is inline, not cached signMessage approval evidence.

| Shape | Nested Safes | Depth | 16 EOAs: cold gas | 16 EOAs: warm gas | 24 EOAs: cold gas | 24 EOAs: warm gas |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Flat | 0 | 0 | 116,097 | 79,858 | 170,279 | 117,810 |
| Sibling children | 1 | 1 | 128,573 | 86,293 | 183,959 | 125,426 |
| Sibling children | 2 | 1 | 136,768 | 90,465 | 192,086 | 129,567 |
| Sibling children | 4 | 1 | 153,038 | 98,676 | 208,442 | 137,854 |
| Sibling children | 8 | 1 | 185,710 | 115,165 | 241,130 | 154,306 |
| Single-owner chain | 2 | 2 | 139,313 | 92,988 | 195,895 | 133,294 |
| Single-owner chain | 4 | 4 | 161,557 | 107,128 | 220,631 | 149,874 |
| Single-owner chain | 8 | 8 | 208,857 | 138,160 | 272,943 | 185,801 |

## Fixed immediate owner count per Safe

Here each Safe has N owners and an N-of-N threshold. The root has K child Safes
and N-K direct EOAs. Each child has N EOA owners. Actual EOA signature count is
`N + K * (N - 1)`; these are not fixed-total-signer comparisons.

| Owners per Safe | Nested Safes | EOA signatures | Total owner entries | Cold gas | Warm gas |
| --- | ---: | ---: | ---: | ---: | ---: |
| 16 | 1 | 31 | 32 | 230,169 | 157,461 |
| 16 | 2 | 46 | 48 | 342,724 | 235,275 |
| 16 | 4 | 76 | 80 | 568,629 | 390,881 |
| 24 | 1 | 47 | 48 | 340,330 | 234,782 |
| 24 | 2 | 70 | 72 | 509,060 | 351,760 |
| 24 | 4 | 116 | 120 | 848,731 | 585,966 |

## Interpretation and exclusions

- Cold verification ranges from 116,097 to 208,857 gas for the fixed-total 16-EOA
  shapes, and 170,279 to 272,943 gas for fixed-total 24-EOA shapes.
- With 24 owners per Safe and four nested owners, 116 EOA recoveries cost 848,731
  gas for cold verification. Immediate-owner limits alone do not cap total work.
- These are measurements of the external harness verification call, including ABI
  decoding/copying, its call boundary, linked-library dispatch, storage owner and
  threshold reads, nested hashing, ordering checks and ECDSA verification. They are
  not whole receiver execution or transaction-receipt measurements.
- Setup, graph installation, signature generation, source Safe execution, transport,
  dispatch decoding, Merkle proofs, application calls, commitment/replay writes and
  linked authority updates/descendant authentication are excluded. This harness
  does not implement the proposed #109 registry or source mutation batches.
- Cold measurements explicitly cool harness storage and harness/library accounts
  after graph installation. Warm measurements immediately repeat the same proof.
  Foundry `isolate=false` is explicit: isolated calls otherwise reset warming.
- `results.csv` also reports signature/calldata sizes and **calculated** transaction
  intrinsic plus calldata gas using Paris rules (21,000 base; 4/16 per zero/nonzero
  calldata byte). Its cold-plus-intrinsic sum is an illustrative metric, not a mined
  transaction estimate; call-wrapper overhead and modern fork/chain data pricing
  differ. No ETH/USD or L2 fee claim is made.
- This is the optimized existing verifier, not native Safe execTransaction and not
  a benchmark of future #109 linked updates, lineage, graph caching or finite-proof tracking.
  Trees only: shared-child repeated proofs, cyclic stored state, cache/reference
  proofs, low-threshold wide graphs and adversarial maximum payloads are unmeasured.
- D87 selects 16 immediate owners per Safe, with no aggregate entry cap. The
  benchmark harness does not implement production enforcement of that limit.

## Reproduce

Solidity 0.8.28, Paris target, optimizer 200 runs, no via-IR; Foundry 1.8.1.
Uses repository source in place, without changing production contracts or fetching
network dependencies. Set `FORGE_STD_SRC` if forge-std is not populated locally;
the runner also recognizes the existing sibling `protocol` checkout's dependency.

```bash
FORGE=/home/carter/.foundry/bin/forge python3 docs/benchmarks/authority-109/run.py
```

The runner writes `results.csv`, `wire-sizes.csv` and `run.log` beside this report. Test setup and
fixture signing are outside timed regions. Each case also checks that changing the
root digest rejects its signature proof, and the runner checks cold > warm gas.

## Source identity

Checkout HEAD: `9181da8b3cb3b8e8433b987ed19322203fa1ce0f`. Existing uncommitted work was preserved.

- `contracts/evm/src/messaging/signed/SafeAuthority.sol` SHA-256: `869188ec78fc06a9cd6e3469a2fb6eb6406a16153688907fea45d26c6dfc64e1`
- `contracts/evm/src/messaging/signed/SafeSignaturesUtils.sol` SHA-256: `6cb33e11975eb035b1254aabc84b4a121c39b8f797c0902abe4b40110519d658`
- `contracts/evm/src/messaging/signed/NestedOwnerManagerLib.sol` SHA-256: `293f465ab6e5c4b7d121ec3c8ee1b5b37ac4e90ad1e23d736d453b0de38b3c60`
- `contracts/evm/src/messaging/signed/SafeAuthorityGraph.sol` SHA-256: `0a9dd604422703d575d95b678db993077571970342cf9df6fddf8c01983209bf`
- `contracts/evm/test/signed/SignedFixtures.sol` SHA-256: `ac011921e28556b594d5c12ee5345efb956892aad789b6c418cccb17c38c47ce`
