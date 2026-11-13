# Analysis: 32 owners per Safe

2026-11-13. Retained comparison for D86's temporary 32-owner proposal. D87 selects
16 immediate owners per Safe with no aggregate entry cap; the 32-owner measurements
below remain useful comparison data, not the current design limit. Production
contracts have not been changed. All 43 baseline benchmark cases pass
valid-proof and wrong-digest rejection checks. See [methodology](README.md).

## Verification cost

Every owner is required in these examples; lower thresholds can require fewer
signatures. Gas below is the measured cold verification call, not whole receiver
execution or transport costs.

| Configuration | EOA signatures | Signature bytes | Cold verification gas |
| --- | ---: | ---: | ---: |
| 32 direct EOAs | 32 | 2,080 | 224,577 |
| A: 31 EOAs + B; B: 32 EOAs | 63 | 4,192 | 450,684 |
| A: 30 EOAs + 2 child Safes; each child: 32 EOAs | 94 | 6,304 | 676,211 |
| A: 29 EOAs + 3 child Safes; each child: 32 EOAs | 125 | 8,416 | 903,389 |
| A: 28 EOAs + 4 child Safes; each child: 32 EOAs | 156 | 10,528 | 1,132,013 |
| A: 24 EOAs + 8 child Safes; each child: 32 EOAs | 280 | 18,976 | 2,063,161 |
| A: 16 EOAs + 16 child Safes; each child: 32 EOAs | 528 | 35,872 | 4,016,027 |
| A: 32 child Safes; each child: 32 EOAs | 1,024 | 69,664 | 8,374,983 |
| 16 single-owner Safe layers above 32 EOAs | 32 | 3,632 | 467,310 |

32 direct signers cost about 1.93 times the 16-direct-signer verification case.
At fixed 32 EOAs, eight sibling Safes cost 296,739 cold gas, eight nested layers
338,015, and sixteen layers 467,310. These measured examples do not establish a
safe maximum for arbitrarily nested or repeated-message proofs.

## Exact standalone transfer wire sizes

The fixture encodes the existing source-to-destination wire format:
`abi.encode(WIRE_STANDALONE, SafeTxEvidence)`. One destination call is a native
transfer with empty data, or an ERC-20 transfer(address,uint256) with 68 calldata
bytes. Destination is an ERC-7930 Base/EVM address, provider attributes are empty,
and all nested approvals are inline signatures. The destination is already
initialized, so authority records are not resent. These are actual ABI-serialized
lengths, not the harness verification-call lengths from results.csv.

| Root owners and child configuration | EOA signatures | Native transfer wire bytes | ERC-20 transfer wire bytes | ERC-20 fits 10,000 bytes? |
| --- | ---: | ---: | ---: | --- |
| 32 direct EOAs | 32 | 3,168 | 3,264 | Yes |
| 31 EOAs + 1 child with 32 EOAs | 63 | 5,280 | 5,376 | Yes |
| 30 EOAs + 2 children with 32 EOAs each | 94 | 7,392 | 7,488 | Yes |
| 29 EOAs + 3 children with 32 EOAs each | 125 | 9,504 | 9,600 | Yes |
| 28 EOAs + 4 children with 32 EOAs each | 156 | 11,616 | 11,712 | No |
| 24 EOAs + 8 children with 32 EOAs each | 280 | 20,064 | 20,160 | No |
| 32 children with 32 EOAs each | 1,024 | 70,752 | 70,848 | No |

The current fixture overhead is 1,088 bytes plus the root signature blob rounded
up to a 32-byte boundary for a native transfer, or 1,184 plus padded signature bytes
for ERC-20. Every nested Safe contributes its 65-byte contract-signature entry and
32-byte dynamic length in addition to the child signatures. The fixture reuses
proofs valid over the benchmark digest for size serialization only: it does not
claim those exact proof bytes authorize this different transfer digest. Real
transfer signatures have the same fixed-length encoding.

A 10,000-byte message budget therefore fits the tested three-child ERC-20 fixture
at 9,600 bytes with only 400 bytes of headroom, but rejects four children at 11,712.
Larger call arrays, provider attributes embedded in signed calldata, separate
signMessage approval evidence, Merkle proofs and future #109 wire fields can change
these sizes. #109 counter-bearing wire ABI is not frozen, so these are baseline
sizes, not a promise of exact future #109 payload length. Bootstrap and authority
update messages require separate sizing. Transfers execute using destination
funds/tokens; this fixture is not an OFT bridge-transfer implementation.

For the current standard LZ transmitter, LzMessage passes this payload directly as
MessagingParams.message; options are separate. Actual pathway configuration must
be checked. LayerZero's official [configuration example](https://github.com/LayerZero-Labs/devtools/blob/main/examples/view-pure-read/README.md)
shows pathway executor maxMessageSize set to 10000; this is not a universal size
promise. No live pathway was queried. Signed OFT remains outside this analysis.

## Design implications

- A 32-owner width limit permits ordinary direct and modestly nested quorums, but
  does not guarantee a message fits a provider pathway or a verification gas budget.
- Full owner branching grows as 32^depth: two owner-list levels can require 1,024
  EOA signatures (measured above); three can require 32,768. Recovery precompile
  cost alone for 32,768 signatures is 98,304,000 gas, before all other work. This
  third-level case is arithmetic, not a measured benchmark.
- Graph traversal can deduplicate a Safe's stored owner list, while different
  message hashes may require verifying that Safe's signatures repeatedly. A graph
  visited set is not a universal proof-work bound.
- Refresh storage writes can dominate verification. Merely populating 32 new
  nonzero storage slots has 640,000 gas in base zero-to-nonzero SSTORE charges,
  before cold access and other work. Actual #109 layouts, replacement/deletion
  costs and authenticated descendant closure are not implemented or benchmarked.
- Check exact serialized message bytes and destination verification cost during
  build/quote, for the selected pathway. A transport payload limit need not become
  an aggregate authority-entry cap: some proofs/transactions may fit while others
  using the same authority do not. Do not silently fragment signed payloads or
  replace signatures with an unauthenticated bridge assertion.
- X9 refresh availability and G5 finite proof/data/work bounds remain unresolved.
  Selecting 32 does not approve a skipped-refresh fallback or guarantee that every
  valid graph is executable within a chosen pathway's limits.

[Gas CSV](results.csv) · [Wire-size CSV](wire-sizes.csv) · [Full test log](run.log)
