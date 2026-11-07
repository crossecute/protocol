# Nested Safe approval evidence: worked sizing example

Working reference from the design discussion on 2026-11-06. This note is for
later review and cleanup. It does not authorize implementation or establish
runtime compatibility. Support for cached approval evidence is decided. Empty nested
signature payloads require supplemental independently verifiable approval evidence;
capture, storage, encoding and verification remain unimplemented and partly unspecified.

Agreed storage choice: persist the full approval evidence blob on the shared guard,
scoped by approving Safe, including signed
transaction context and complete owner-signature encoding without the child's policy
extension. A stored commitment alone is not the selected retrieval model. Storage
layout, limits and retrieval remain open. Direct submission of complete
quorum-signed evidence remains supported without requiring source execution.

Agreed capture timing: the pre-hook stores evidence after inherited policy checks,
without waiting for post-hook confirmation. Post-hooks clear temporary execution context,
not the persistent approval record. Retain published evidence indefinitely, with no
pruning or deletion on use. A containing
revert rolls back the storage write; direct signed-evidence submission remains a required
route when no source cache record exists.

Agreed receiver submission is permissionless: anyone may execute with complete valid
evidence once the parent transaction's remaining authorization and execution checks pass,
without bridge delivery. Published approval evidence remains available indefinitely.
Cache deletion is not a revocation mechanism. This does not permit repeated execution of
the same dispatch; receiver replay protection and authority-transition rules remain required.

Agreed receiver replay storage (#108): one receiver is bound to one parent Safe and
source chain. Store minimumNonce without an execution-data hash. Direct and provider
routes require N >= minimumNonce and advance it to N + 1 before external effects,
rolling back on atomic failure. This supersedes the earlier used-nonce mapping; gaps
are allowed, but later acceptance excludes all lower nonces. Verify N in the signed
transaction context. Signed leaves also commit validAfter/deadline, with inclusive
destination block.timestamp checks and validAfter <= deadline. This state is separate
from reusable child approval evidence. Initialize minimumNonce to zero at bootstrap.
Overflow and authority-transition
details still require specification. The sizing totals below do not include the new
window fields or a finalized dispatch envelope.

## Purpose and approval model

A parent Safe A has two contract owners, Safes B and C. Each child previously
executed an owner-authorized transaction approving the message required by A's
transaction. The child's compatibility handler can later accept an empty dynamic
signature payload by reading its `signedMessages` approval flag.

That flag contains no signature bytes. To verify authorization independently at a
receiver without light clients or trusting bridge assertions, the agreed route
captures or directly accepts each child's complete signed approval transaction context and
owner signatures. It forwards that evidence separately from A's unchanged original
signature blob. Child policy extensions are excluded; A's extension is retained
when present.

The receiver would verify the approval transaction's signatures and establish that
its signed action approves the exact required message. This proves signed intent,
not successful source execution. Quorum-signed authorization is agreed to be sufficient
without source execution or bridge delivery. Only direct approval delegatecalls are
supported, not approvals inside one signed MultiSend batch. Separately signed direct
approvals at consecutive nonces may execute within one parent transaction, each with its
own guard lifecycle. Ordinary nested approvals use the current receiver-stored child
composition, including cached approvals; old signatures remain usable only if they
satisfy that composition. No separate child-counter signature is required. The shared
guard tracks each Safe's own counter, while a transmitter stores only its parent's.
Child-only changes do not advance the parent counter or block execution by other
owners reaching parent quorum. Per-node counters order authenticated authority updates.
Replay details and capture APIs remain open.
One update authorized by a child's pre-change quorum may be submitted permissionlessly
to every receiver already storing that authenticated child, without separate parent
authorization or parent counter changes. Each receiver verifies its own prior child
node/counter; reuse across receivers is intentional, duplicate application locally is not.
Cached approval signatures cannot simply replace an empty child payload: they sign
an approval transaction, not the handler's message digest.

## Optimism reference and verification limits

Authority catch-up requires sequential verification under each preceding authority.
Multiple consecutive updates can be submitted together, without skipping counters or
intermediate checks. Update-batch size and costs are not included in this sizing example.

Optimism's [proposer rotation proposal](https://gov.optimism.io/t/maintenance-upgrade-proposal-op-mainnet-proposer-rotation/10939)
identifies the L1 ProxyAdmin owner Safe as a nested 2/2 of the Foundation Upgrade
Safe and Security Council Safe:

- Parent: `0x5a0Aae59D09fccBdDb6C6CcEB07B7279367C3d2A`.
- Foundation Upgrade Safe: `0x847B5c174615B1B7fDF770882256e2D3E95b9D92`.
- Security Council Safe: `0xc2819DC788505Aac350142A7A707BF9D03E3Bd03`.

The [Security Council threshold upgrade](https://gov.optimism.io/t/final-protocol-upgrade-8-guardian-security-council-threshold-and-l2-proxyadmin-ownership-changes-for-stage-1-decentralization/8157)
specifies 10/13. A [published external description](https://llamarisk.com/research/2025-03-04t22-13-55-000z)
describes the nested structure as Council 10/13 and Foundation 5/7, but the current
Foundation Upgrade Safe's live threshold and owner composition were not verified
in this discussion. Use 5/7 as an assumption here, not a current onchain assertion.
The live Council state was not queried either. Do not conflate other Foundation
Safes with the Foundation Upgrade Safe.

This note borrows the owner counts for sizing. It does not claim that Optimism
uses this ERC-20 transfer, direct approval action, empty-payload route, or proposed
evidence encoding.

```text
Parent Safe: 2/2
├── Security Council Safe: 10/13
│   └── Requires 10 EOA signatures in this example
└── Foundation Safe: 5/7, assumed
    └── Requires 5 EOA signatures in this example
```

There are 20 child owner positions and 15 required signature entries, assuming
all child owners are EOAs. This does not establish 20 distinct people or keys.
The thresholds remain separate: ten Council signatures and five Foundation
signatures, not an unrestricted 15/20. Each child counts as one parent owner.

## Encoding assumptions

- A executes one ERC-20 `transfer(address,uint256)`.
- A uses the Safe 1.3/1.4 legacy contract-signature path. The message passed to
  each child handler is A's 66-byte EIP-712 transaction preimage.
- Each child directly delegatecalls a supported `SignMessageLib.signMessage(bytes)`
  approval action, without MultiSend.
- Each child supplies exactly its threshold of 65-byte EOA signatures.
- No policy extensions are included in the numerical example. The child extension
  is excluded by the proposed evidence rule; any A extension increases the total.
- All transaction fields are retained, even where a future format might reconstruct
  constants. This is illustrative standard ABI encoding, not a final wire format.

The 66-byte parent preimage is the two-byte EIP-712 prefix, 32-byte domain
separator and 32-byte transaction struct hash. It is not the complete transaction
calldata. See the pinned [Safe transaction encoding](../contracts/safe-guard/lib/safe-smart-account-1.3.0/contracts/GnosisSafe.sol).
Safe 1.5 and mixed-version handler paths require separate sizing and verification.

## Parent transfer and child approval calldata

| Parent transfer component | Bytes |
| --- | ---: |
| Function selector | 4 |
| Recipient | 32 |
| Amount | 32 |
| Total transfer calldata | 68 |

Each child approves the same 66-byte parent message. Their own domain-wrapped
message digests differ because the child Safe addresses differ.

| Child `signMessage(bytes)` calldata component | Bytes |
| --- | ---: |
| Function selector | 4 |
| Offset to message | 32 |
| Message length | 32 |
| 66-byte message padded to 96 bytes | 96 |
| Total approval calldata | 164 |

## Illustrative cached record encoding

Each record is encoded as these fourteen top-level ABI fields:

```solidity
abi.encode(
    chainId, childSafe, approvedMessageDigest,
    to, value, data, operation,
    safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, nonce,
    signatures
)
```

The head contains fourteen 32-byte words, including offsets for `data` and
`signatures`. Each dynamic tail contains a length word and its padded bytes.
`approvedMessageDigest` is redundant verification metadata, not a trusted claim;
the verifier must derive and compare it. The encoding has no authority epoch or
handler identifier yet; such fields or authenticated external references are
required by the eventual verification design and may add bytes.

| Component | Council | Foundation |
| --- | ---: | ---: |
| Required signatures | 10 | 5 |
| Raw owner signatures | 650 | 325 |
| ABI head, 14 × 32 | 448 | 448 |
| Data tail, 32 + ceil(164 / 32) × 32 | 224 | 224 |
| Signature tail, 32 + ceil(signature bytes / 32) × 32 | 704 | 384 |
| Encoded evidence | **1,376** | **1,056** |

Combined cached evidence: **2,432 bytes**.

## Parent signature blob with empty child payloads

| Component | Bytes |
| --- | ---: |
| Two contract-owner headers, 2 × 65 | 130 |
| Two zero-length dynamic payload words, 2 × 32 | 64 |
| Parent signature blob | **194** |

The headers identify the child owners with `v = 0`; their `s` fields point to
the corresponding zero-length payload words. There are no child EOA signatures
inside those empty payloads.

| Forwarded component | Bytes |
| --- | ---: |
| Council cached evidence | 1,376 |
| Foundation cached evidence | 1,056 |
| Parent original signature blob | 194 |
| Subtotal | **2,626** |

This subtotal excludes A's transaction context, A's policy extension, authority
composition, authority references and outer ABI/transport framing. It is not the
size of a complete executable protocol message. For A's extension payload of N
bytes, its raw signature blob gains N + 64 bytes before outer encoding padding.

## Persistent storage and direct-signature comparison

If each encoded approval record is stored as a Solidity `bytes` value:

| Record | Data slots | Length slot | Total slots |
| --- | ---: | ---: | ---: |
| Council, 1,376 bytes | 43 | 1 | 44 |
| Foundation, 1,056 bytes | 33 | 1 | 34 |
| Total | 76 | 2 | **78** |

This excludes indexing and lifecycle metadata. Other storage layouts have different
overhead. Persistent storage is required across separate blockchain transactions;
transient staging alone cannot retain earlier approvals. No storage gas benchmark
has been performed.

If the same fifteen EOA signatures instead directly authorize the child handler
messages and appear inside A's contract-signature payloads, the packed Safe blob is:

```text
Parent contract-owner headers     130 bytes
Child payload length words        64 bytes
Council owner signatures         650 bytes
Foundation owner signatures      325 bytes
                               -----------
Total                          1,169 bytes
```

The illustrative cached route subtotal is **1,457 bytes larger** than that direct
signature blob. Both comparisons omit parent transaction context and policy
extensions. Direct child signatures sign different digests from cached approval
transaction signatures; one cannot be substituted for the other.

## Storage gas and illustrative dollar costs

These are storage-operation estimates, not measurements of an implemented guard.
Assume the Ethereum EIP-2200/EIP-2929 gas schedule, no access list, initially cold
slots, and fresh zero-to-nonzero writes. A fresh cold write costs 20,000 + 2,100 =
22,100 gas per slot. A first read costs 2,100 gas per slot; subsequent reads of
the same slot in the same transaction cost 100 gas. Sources:
[Ethereum gas constants](https://github.com/ethereum/go-ethereum/blob/master/params/protocol_params.go)
and [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929).

For a Solidity `bytes` value, both 1,000 and 1,024 payload bytes occupy 32 data
slots plus one length slot. A single `bytes32` commitment occupies one slot.
See [Solidity storage layout](https://docs.soliditylang.org/en/v0.8.0/internals/layout_in_storage.html).

The commitment figures below are retained only for comparison; full-blob storage
is the selected approach.

Dollar estimates use the user's hypothetical **1 gwei gas price and $2,000/ETH**,
not current market prices:

```text
USD cost = gas × 1e-9 ETH/gas × 2,000 USD/ETH
         = gas × 0.000002 USD
```

| Stored data | Slots | Fresh cold writes, gas | Write cost | Full cold reads, gas | Read cost |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 KB blob | 33 | 729,300 | $1.46 | 69,300 | $0.14 |
| One bytes32 commitment | 1 | 22,100 | $0.0442 | 2,100 | $0.0042 |
| Council evidence | 44 | 972,400 | $1.94 | 92,400 | $0.18 |
| Foundation evidence | 34 | 751,400 | $1.50 | 71,400 | $0.14 |
| Combined child evidence | 78 | 1,723,800 | $3.45 | 163,800 | $0.33 |

Each displayed dollar amount is rounded independently. Write figures assume every
slot becomes nonzero. Zero-filled ABI words cost less; the illustrative approval
records contain zero-valued fields, so the all-nonzero write budget overstates their
storage writes. Overwriting existing records has different metering.

The figures exclude transaction intrinsic gas, calldata, hashing, memory allocation,
copying, return data, contract calls, indexing/lifecycle metadata, signature verification
and the remainder of Safe execution. Reading a commitment also requires supplying and
hashing the evidence, so its one-slot read cost is not a complete retrieval estimate.
Offchain `eth_call` reads do not charge the caller an onchain transaction fee.
Chain-specific pricing and additional L2 data fees are not modeled.

## Follow-up before implementation

- Verify the live owner counts, thresholds, implementations and handlers at a
  specified source block before treating this as a deployment-specific example.
- Specify exact supported library identities for direct approval delegatecalls and
  authenticated current authority references,
  nested evidence recursion, reuse and replay rules, preserving indefinite retention
  without pruning and permissionless receiver submission.
- Choose a canonical encoding, reconstructible constants, size limits and storage
  layout; then benchmark staging, persistent writes, reads and forwarding.
- Test direct versus cached authorization, exact message binding, changed context,
  nested signatures, authorization without source execution, sequential direct approvals,
  batch-approval rejection and policy-extension exclusion.
