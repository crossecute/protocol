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
`forge test --match-contract ApprovalGasTest -vv`.

## What a child approves

Safe 1.5.0 asks a contract owner to validate `abi.encode(parentTxHash)`, 32 bytes. The child
approves it with a direct delegatecall to `SignMessageLib.signMessage(bytes)`, whose calldata is
100 bytes: selector, offset, length and one padded word.

The parent then carries an empty payload for each child: two 65-byte contract-signature headers
and two zero length words, 194 bytes. The child evidence travels next to that blob, not inside it.

## Stored record

`CrossecuteGuard` stores each approval as an `ApprovalEvidence` struct in persistent storage:

| Slots | Field |
| ---: | --- |
| 1 | `to` and `operation`, packed |
| 1 | `value` |
| 5 | `data`: one length slot and four data slots for 100 bytes |
| 6 | `safeTxGas`, `baseGas`, `gasPrice`, `gasToken`, `refundReceiver`, `nonce` |
| 1 + ⌈n / 32⌉ | `signatures`, n bytes |

| | 10-of-13 child | 5-of-7 child | Total |
| --- | ---: | ---: | ---: |
| Owner signatures | 650 bytes | 325 bytes | 975 bytes |
| Storage slots | 35 | 25 | 60 |
| `getApproval` return, ABI-encoded | 1,248 bytes | 928 bytes | 2,176 bytes |
| Measured cache cost | about 665,000 gas | about 443,000 gas | about 1,108,000 gas |
| At 1 gwei and $2,000/ETH | $1.33 | $0.89 | $2.22 |

The measured cost covers the storage writes, computing the message hash, and the extra calls back
to the Safe for its nonce and domain separator. It is close to the slot arithmetic: under the
EIP-2929 schedule a fresh nonzero slot costs 22,100 gas and a zero written over zero costs 2,200,
and in this shape `value` and the five payment and gas fields are zero. Measured amounts vary by a
few gas between runs because addresses differ. A replacement for the same child and message
writes over existing slots and costs less.

Reading a record back with `getApproval` costs 2,100 gas per cold slot onchain, about 126,000 gas
for both records. An offchain `eth_call` costs the caller nothing.

## Relation to the figures in #107

Issue #107 quotes 2,432 bytes, 78 slots, 1,723,800 gas and $3.45 for this shape. Those figures came
from an earlier working note that assumed the older Safe contract-signature path, where the message
is the parent's 66-byte EIP-712 preimage, and a 14-field ABI-encoded blob stored as one `bytes`
value with every slot written nonzero. Safe 1.5.0's 32-byte message, the struct layout above and
the zero fields account for the difference.
