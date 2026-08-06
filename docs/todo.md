# Outstanding

Everything known to be missing, undecided, or wrong, in one place. Ordered by what blocks
what rather than by size.

[`message-flow.md`](message-flow.md) and [`encoding.md`](encoding.md) describe the design;
this file is the gap between that design and the tree.

---

## 1. The transport is not built

**This is the headline.** The destination half is real — account creation, the approval
queue, cancellation, execution, the commitment schemes — and nothing can reach it, because
no message can cross.

| Missing | Where |
| --- | --- |
| `_sendMessage(bytes32 chainKey, bytes payload)` | `OutboundBase` still has `_send(bytes32, bytes32)`, which reverts `SendNotImplemented` |
| `send` / `sendTo` / `bootstrap` | `TransmitterBase` has only `commit` / `commitTo` / `execute` |
| `bootstrap(chainKey, calls)` outbound half | `TransceiverBase` has `bootstrapInbound` and no way to send one |
| The spoke → hub report | `reportSelf` does not exist; `Envelope.encodeReceiverReport` has no caller |
| `ReentrancyGuardUpgradeable` on `ReceiverBase` | Referenced in a comment, not inherited |

**`Payload.sol` has no caller in `src/`.** It is a finished, tested codec waiting for the
rewrite to wire it in — as is `Commitment.hashElements`. Expected, but it means the
encoding work is not load-bearing yet.

## 2. No message provider is integrated

`_send` reverts. `LzTransmitter`, `LzReceiver`, `LzHubTransceiver`, and `LzSpokeTransceiver`
inherit no LayerZero code — no `OApp`, no endpoint, no `@layerzerolabs` in `lib/` or in the
remappings. **Nothing has ever crossed a bridge.**

The claim the whole redesign rests on — that a transmitter can be its own provider
endpoint, and that a *proxy* can hold one — is untested.

## 3. Blockers on specific paths

- **Funding the return report.** `reportSelf` fires from inside the destination's inbound
  callback, and putting a message on the wire costs native currency there. Either the spoke
  carries a msig-funded balance per chain, or the bootstrap message drops value across.
  Without one, bootstrap reverts on the return leg. **Top blocker on the report path.**
- **Starknet bytes↔felt packing.** Bridges deliver Starknet payloads as `Array<felt252>`,
  not bytes. Before any container format can be parsed there has to be an agreed packing
  rule. Unspecified, needed in either container format, and the kind of value that is wrong
  once and wrong forever.
- **A Move receiver model.** Move has no general dynamic dispatch, so a receiver can verify
  a commitment perfectly and have no way to perform the approved calls. It also has no
  per-owner deployment, so the one-account-per-owner model and its single address do not
  survive. The largest unresolved piece of non-EVM support — see
  [`encoding.md`](encoding.md#commitments-off-the-evm).
- **A Cardano receiver model, or a decision that Cardano is out of scope.** eUTxO
  validators approve spending; they do not execute.
- **Poseidon for Starknet commitments.** `Scheme.Poseidon` is declared and reverts
  `SchemeNotComputable`. Porting it needs the exact round constants and MDS matrix over the
  Starknet field — a vector-checked task, not one to write from memory. Until then a
  Starknet commitment is computed off-chain and approved through `commitTo(bytes,bytes32)`.

## 4. Decisions taken that deserve a second look

None of these are bugs. Each is a deliberate choice with a cost worth confirming before
mainnet.

- **Write-once has no recovery path.** `setTransceiverId`, `setProviderDeployment`, and a
  reported ref slot all refuse a second write. A route declared wrong is permanent; a
  receiver slot written wrong has no fix at all. The alternative is a timelocked repoint
  rather than an outright refusal.
- **`Provenance.Committed` has no producer.** It survives only as a cap value. Chains
  configured at that cap now effectively mean "`Attested` or nothing".
- **Ordered execution blocks the queue.** Strict FIFO means a permanently-failing payload
  stalls everything behind it until `cancel`. Ordering and cancellation are load-bearing for
  each other; neither should be removed alone.
- **Two `isAuthorizedCommitter` arms are the same address.** A receiver's peer is its own
  address, so `sourceTransmitter` and `address(this)` coincide. Collapse them, or keep them
  distinct against a future where they diverge?
- **A blank `XSafeProxy` delegates to `address(0)` and succeeds silently.** Only safe
  because deploy, arm, and lock are one function. It becomes a real hole if those are ever
  split.
- **Self-replaying payloads.** `finalize` clears an approval before executing, so a payload
  containing a self-call to `commit` with its own hash re-arms itself indefinitely.
  Owner-approved either way, so not an escalation — but "approvals are single-use" stops
  being true. Disallowing it costs plumbing; allowing it is strictly cheaper.
- **Who authenticates the receiver's inbound message.** A provider's own peer check runs
  before any of our code, which contradicts the rule stated for the transceiver. For a 1:1
  pairing there is nothing extra to verify, so accepting it is defensible — but it should be
  a written exception rather than an omission.

## 5. Smaller open questions

- **The opaque container off the EVM** — ABI framing or a length-prefixed one. Not blocking
  until a non-EVM receiver exists, because the commitment never sees the container.
- **The Solana account list belongs inside the committed element.** Argued in
  [`encoding.md`](encoding.md); worth marking settled when the first vector is written.
- **Empty-array commitments.** `execute` refuses one; `finalize` accepts. Pick one.
- **Registry `slot` namespacing.** Raw `transceiverId`, so two callers choosing the same
  bytes32 collide; only the monotonic provenance rule limits the damage.
- **Owner-writable non-EVM locations** — allowed directly, or only through the graded
  resolution paths?
- **What else a self-call may reach.** Today `commit` / `cancel` / `finalize` / `execute`.
  When a merkle-root setter lands, a self-call could rotate the policy — probably right,
  but it should be deliberate.
- **Whether bootstrap may carry a full payload**, or only enough to stand the account up.
- **Refund plumbing.** `bootstrap` should take a refund address and the transmitter should
  pass its owner.
- **No storage gaps anywhere.** The transceiver is UUPS until `lockUpgrades()`.
- **`renounceOwnership` bricks a transmitter.** Recorded rather than prevented; disabling it
  is a separate decision.
- **Tron CREATE2 against a Shasta deployment**, to resolve the 0x41-vs-0xff docs
  contradiction. A one-afternoon empirical check that de-risks a whole chain family.
- **Merkle-verified calls** as an opt-in policy, replacing the `(target, selector)`
  predicate. `isAllowed` defaults open, so this is an owner's restriction rather than a
  safety baseline.

## 6. Infrastructure — none of it exists

- **The repo has zero commits and no `.gitignore`.** `out/`, `cache/`, and a vendored
  (not submoduled) `lib/` are untracked; the first commit swallows all of it. **Highest
  value per minute of anything on this page** — the tree is currently unrecoverable.
- **No `script/`.** The Assumptions section specifies an elaborate deploy story — Arachnid's
  factory, proxy with deployer-as-owner, immediate upgrade, ProxyAdmin under the msig — with
  no code behind it. The CREATE2 parity argument stands or falls on that initcode being
  byte-identical, and nothing pins it.
- **No CI.** No `.github/`.
- **No `test/vectors/`.** [`encoding.md`](encoding.md) specifies the corpus and the
  "assert fields, not bytes" rule. Foundry can verify the commitment half for every VM with
  no non-EVM tooling — cheap, and the only defence on the execute-on-arrival path where
  there is no commitment at all.
