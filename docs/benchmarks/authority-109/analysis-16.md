# Transfer wire sizing with 16 owners per Safe

Measured 2026-11-13. D87 selects 16 immediate owners per Safe, with no aggregate
entry cap; this analysis is retained with the 32-owner comparison. Same existing
standalone signed wire ABI, Base/EVM destination,
initialized receiver, empty provider attributes, one ERC-20 transfer, unique EOA
fixture keys and inline nested signatures as the [32-owner analysis](analysis-32.md).
Each Safe requires all its owners. At root A, K of its 16 owners are nested Safes
and 16-K are direct EOAs. Each child requires 16 EOA signatures. EOA signature
count is `16 + 15*K`. Gas is cold verification only, not a complete transaction.

| Nested owners at A | EOA signatures | Signature blob bytes | Native transfer wire bytes | ERC-20 transfer wire bytes | ERC-20 under 10,000 bytes? | Cold verification gas |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| 0 | 16 | 1,040 | 2,144 | 2,240 | Yes | 116,097 |
| 1 | 31 | 2,112 | 3,200 | 3,296 | Yes | 230,169 |
| 2 | 46 | 3,184 | 4,288 | 4,384 | Yes | 342,724 |
| 3 | 61 | 4,256 | 5,344 | 5,440 | Yes | 455,373 |
| 4 | 76 | 5,328 | 6,432 | 6,528 | Yes | 568,629 |
| 6 | 106 | 7,472 | 8,576 | 8,672 | Yes | 796,076 |
| 7 | 121 | 8,544 | 9,632 | 9,728 | Yes | 910,216 |
| 8 | 136 | 9,616 | 10,720 | 10,816 | No | 1,024,989 |
| 16 | 256 | 18,192 | 19,296 | 19,392 | No | 1,957,554 |

For this exact one-level, full-quorum fixture, seven child Safes fit at 9,728 bytes
with only 272 bytes of headroom; eight do not fit at 10,816 bytes. With 32 owners
per Safe, three such full children fit at 9,600 bytes and four do not at 11,712.
A 16-owner cap makes these full-width examples smaller but still cannot guarantee
relayability without checking the exact message and pathway configuration.

These are actual ABI-serialized lengths; existing verifier-call calldata lengths
in results.csv are different. Proofs used for size serialization authenticate the
benchmark digest, not the separately encoded transfer; real signatures over the
transfer digest have the same encoded length. Native/token transfers execute from
the destination receiver's balance; this is not signed OFT bridging work.
Separate signMessage evidence, larger call batches, signed provider attributes,
bootstrap/authority registration and future #109 fields can increase payload size.
The unimplemented #109 counter-bearing wire ABI is not sized here. A 10,000-byte
pathway budget is an example, not a claim about every LayerZero route.

All 43 benchmark configurations pass verification and wrong-digest controls.
Reproduce using [run.py](run.py); see [methodology](README.md), [wire sizes](wire-sizes.csv)
and [gas results](results.csv). No production contract changes, commits or pushes.
