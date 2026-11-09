# Child approval evidence: size and cost

What caching one child Safe approval costs, for the nested shape issue
[#107](https://github.com/crossecute/protocol/issues/107) uses as sizing input: a 2-of-2 parent
whose owners are a 10-of-13 child and a 5-of-7 child, each approving with exactly its threshold
of EOA signatures. The thresholds are an input to this note, not a claim about any deployed Safe.
[`safe-guard-design.md`](safe-guard-design.md#persistent-child-approval-evidence) describes the
record itself.

**Measured.** The gas figures come from `test/ApprovalGas.t.sol` in
[`contracts/safe-guard/`](../contracts/safe-guard/), which runs the child's `signMessage`
transaction under `CrossecuteGuard` and again under an unmodified `SafePolicyGuard` with the same
policy, and reports the difference. Run it with
`forge test --match-contract ApprovalGasTest -vv`. Repeated runs of the same code give the same
figures.

## What a child approves

Safe 1.5.0 asks a contract owner to validate `abi.encode(parentTxHash)`, 32 bytes. The child
approves it with a direct delegatecall to `SignMessageLib.signMessage(bytes)`, whose calldata is
100 bytes: selector, offset, length and one padded word.

The parent then carries an empty payload for each child: two 65-byte contract-signature headers
and two zero length words, 194 bytes. The child evidence travels next to that blob, not inside it.

## Stored record

`CrossecuteGuard` stores each approval as an `ApprovalEvidence` struct in persistent storage. It
writes these slots:

| Slots | Field |
| ---: | --- |
| 1 | `to` and `operation`, packed |
| 1 | `value` |
| 5 | `data`: one length slot and four data slots for 100 bytes |
| 4 | `baseGas`, `gasToken`, `refundReceiver`, `nonce` |
| 1 + ⌈n / 32⌉ | `signatures`, n bytes |

The struct also has `safeTxGas` and `gasPrice` slots. The guard never writes them, since the
inherited policy check requires both to be zero, so they always read as zero.

| | 10-of-13 child | 5-of-7 child | Total |
| --- | ---: | ---: | ---: |
| Owner signatures | 650 bytes | 325 bytes | 975 bytes |
| Slots written | 33 | 23 | 56 |
| `getApproval` return, ABI-encoded | 1,248 bytes | 928 bytes | 2,176 bytes |
| Measured cache cost | 660,984 gas | 439,221 gas | 1,100,205 gas |
| At 1 gwei and $2,000/ETH | $1.32 | $0.88 | $2.20 |

The measured cost covers the storage writes, computing the message hash, and the extra calls back
to the Safe for its nonce and domain separator. It is close to the slot arithmetic: under the
EIP-2929 schedule a fresh nonzero slot costs 22,100 gas and a zero written over zero costs 2,200,
and in this shape `value` and the three payment fields are zero. A replacement for the same child
and message writes over existing slots and costs less. These measurements use no policy
extension. Approvals with an extension additionally read the Safe's threshold and check each
required signature's bounds before stripping it. The stored and returned formats are unchanged.

Reading a record back with `getApproval` loads every slot of the struct, the two unwritten ones
included: 60 slots for both records, about 126,000 gas onchain at 2,100 per cold slot. An offchain
`eth_call` costs the caller nothing.
