# Outstanding

Everything known to be missing, undecided, or wrong, in one place. Ordered by what blocks
what rather than by size.

[`message-flow.md`](message-flow.md) and [`encoding.md`](encoding.md) describe the design;
this file is the gap between that design and the tree.
[`provider-spec.md`](provider-spec.md) is what the five bindings under
`contracts/evm/src/protocols/` are held to; what they mean for an operator is in the README.

---

## 1. Blockers on specific paths

- **Getting a diverging spoke's report float there.** The report fires from inside the
  destination's inbound callback, where `msg.value` is zero, so it is paid from the spoke's
  own balance. The hub's `bootstrapFee` is charged on the home chain in the home currency and
  the spoke needs the destination's, so the two are funded separately and out of band.
  Making that automatic means the bootstrap message drops value across, which is a provider
  capability question rather than a contract one.

  **And the report's refund target is unresolved.** `_refundTo()` is `msg.sender`, which on
  a nested send is whoever delivered the message, so a provider refunding an overpaid report
  pays the relayer out of the spoke's balance. Nobody is stolen from, but the spoke drains
  at a rate nothing here bounds. `_reportReceiver` sends the quoted fee rather than the
  balance, which bounds one report; it does not answer where the refund goes.
- **Starknet bytes↔felt packing.** Bridges deliver Starknet payloads as `Array<felt252>`,
  not bytes. Before any container format can be parsed there has to be an agreed packing
  rule. Unspecified, needed in either container format, and the kind of value that is wrong
  once and wrong forever.
- **A Move receiver model.** Move has no general dynamic dispatch, so a receiver can verify
  a commitment perfectly and have no way to perform the approved calls. It also has no
  per-owner deployment, so the one-account-per-owner model and its single address do not
  survive. The largest unresolved piece of non-EVM support: see
  [`encoding.md`](encoding.md#commitments-off-the-evm).
- **A Cardano receiver model, or a decision that Cardano is out of scope.** eUTxO
  validators approve spending; they do not execute.
- **Poseidon for Starknet commitments.** `Scheme.Poseidon` is declared and reverts
  `SchemeNotComputable`. Porting it needs the exact round constants and MDS matrix over the
  Starknet field: a vector-checked task, not one to write from memory. Until then a
  Starknet commitment is computed off-chain and carried in an opaque element that calls
  that receiver's own `commit`.

  It lands as an `ICommitmentScheme` plugin through `ChainRegistry.setCommitmentScheme`,
  with no redeploy.

## 2. Measurements before mainnet

- **No provider's default gas is measured.** With no gas attribute, Hyperlane sends 50,000
  (the IGP default, written explicitly because the refund field follows it), the Wormhole
  Executor 200,000, and OP Stack's `minGasLimit` 200,000. Bootstrap and `_reportReceiver`
  always send with no attributes, and none of these defaults is measured against either.
  Hyperlane's is probably too low. An OP Stack underestimate is recoverable (the messenger
  records the failed relay and anyone can replay it with more gas); the others are not
  known to be.

## 3. Smaller open questions

- **The opaque container off the EVM**: ABI framing or a length-prefixed one. Not blocking
  until a non-EVM receiver exists, because the commitment never sees the container.
- **The Solana account list belongs inside the committed element.** Argued in
  [`encoding.md`](encoding.md); worth marking settled when the first vector is written.
- **Owner-writable non-EVM locations**: allowed directly, or only through the graded
  resolution paths?
- **What else a self-call may reach.** Today `commit` / `cancel` / `finalize` / `execute`.
  When a merkle-root setter lands, a self-call could rotate the policy: probably right,
  but it should be deliberate.
- **Whether bootstrap may carry a full payload**, or only enough to stand the account up.
- **Tron CREATE2 against a Shasta deployment**, to resolve the 0x41-vs-0xff docs
  contradiction. It needs a FUNDED deployment: the trick that settled Aurora, `eth_call`ing
  Arachnid's factory so the chain's own engine answers, does not transfer, because that
  factory relies on a pre-signed Ethereum transaction and is absent from Tron and Shasta. A one-afternoon empirical check that de-risks a whole chain family. Now
  load-bearing rather than merely tidy: `TronSpokeTransceiver` commits to `0x41` through
  `AddressDerive.tronCreate2`, so this check is what decides whether that spoke works. It
  fails closed if wrong (`AccountAddressMismatch` on every account creation), so the cost of
  being wrong is a redeploy rather than a loss. zkSync Era's override
  (`ZkSyncSpokeTransceiver`) is unverified the same way and needs the same one-account check.
- **The home chain is a deployment parameter**, not Ethereum. `SpokeTransceiverBase`
  takes its home chainKey, the provider's route to it, and the hub's address as
  write-once initializer arguments. Two things follow, and both are worth deciding rather
  than inheriting. The hub must be an EVM chain with the EIP-152 precompile, since the
  registry recomputes addresses and commitments locally. And every spoke in one deployment
  must be given the SAME home: nothing on-chain cross-checks that, because a spoke has no
  view of its siblings. A deploy script is the natural place to enforce it, and there is no
  deploy script yet.
- **Merkle-verified calls** as an opt-in policy, replacing the `(target, selector)`
  predicate. `isAllowed` defaults open, so this is an owner's restriction rather than a
  safety baseline.
- **Another provider, NEAR Intents / Chain Signatures, is not ruled out but needs its own
  research pass before it belongs beside the five.** Explored informally, not
  source-verified the way §4 to §8 of [`provider-research.md`](provider-research.md) are.

  NEAR Intents itself (the `defuse`/Verifier contract plus its PoA token bridge, in
  `near/intents`) is a swap-settlement ledger, not a message-passing transport: no
  arbitrary-call delivery, and its one data-carrying primitive
  (`PoaFactory.ft_deposit`'s `msg`, NEP-141's transfer-and-call) is gated to a small
  permissioned role and only ever reaches a NEAR contract's callback. It is not a candidate
  transport in the shape this protocol needs.

  The more plausible angle is Chain Signatures itself (`v1.signer`, NEAR's MPC
  threshold-signing contract, `crates/mpc` in the same repo), which signs an arbitrary
  payload for a key derived from a NEAR account, for any chain its curve covers — genuinely
  general-purpose, not restricted to token transfers. But it does not fit this protocol's
  transceiver shape at all: there is no message delivered and no gateway to authenticate,
  since a Chain-Signatures transaction is broadcast directly by whoever holds the signature
  and is indistinguishable on the destination chain from any other EOA's transaction.
  Adopting it would mean deciding how a destination chain trusts a NEAR-MPC-derived address
  as "the account" at all — an architecture question upstream of "add a binding," not a peer
  of the five in `provider-research.md`.

  **Not required by, and must not block, the five bindings that exist.** Recorded here
  so it isn't rediscovered under time pressure. The next step, if ever pursued, is
  source-verified research matching the existing provider-research.md format — of `v1.signer`
  and NEAR's validator threshold-signing scheme itself, not of the Intents/Verifier
  application layer built on top of it.

## 4. Infrastructure

- **No deploy scripts.** `script/` holds only the vendoring drivers. The Assumptions section
  specifies an elaborate deploy story (Arachnid's factory, proxy with deployer-as-owner,
  immediate upgrade, ProxyAdmin under the msig), with no code behind it. The CREATE2 parity
  argument stands or falls on that initcode being byte-identical, and nothing pins it. The
  scripts are also where the deployment-time provider decisions get made: the
  [spec's §6](provider-spec.md#6-configuration-a-compliant-deployment-performs) order, the
  `accountInitCodeHash` assertion (R8.4), and how many gateways each transceiver's
  initializer names, since a transceiver's gateways cannot be added to later.
- **The compliance suite has two gaps** ([spec §8](provider-spec.md#8-the-compliance-suite)
  says where every line is held). C21's script-side assertion waits on the deploy scripts.
  C11 and C29 to C31 against real endpoints are the fork tests below; Wormhole's own replay
  (C29 to C31) is already tested, since the binding owns it. C24's check cannot see a
  collision inside a single call, so two fields an initializer sets together are covered
  only by the suites that read them back.
- **No fork tests.** Every binding is tested against a mock of its provider. C11, and C29 to
  C31 for every provider but Wormhole, test the transport rather than the binding, so until
  they run against each provider's real deployment, P7 and P9 remain documented assumptions.
- **No `test/vectors/`.** [`encoding.md`](encoding.md) specifies the corpus and the
  "assert fields, not bytes" rule. Foundry can verify the commitment half for every VM with
  no non-EVM tooling: cheap, and the only defence on the execute-on-arrival path where
  there is no commitment at all. **Now load-bearing for the scheme plugins**: an
  `ICommitmentScheme` is only as good as the evidence that its primitive matches what the
  destination's own receiver applies, and a wrong one leaves an approval that can never be
  discharged. The corpus is what turns "we believe this is Blake2b" into a
  check.

  **Built per chain, as each non-EVM chain enters launch scope.** The gate: no
  `ChainRegistry.setCommitmentScheme` or `setDeriveParams` for a non-EVM chain until its
  vectors are in `test/vectors/`, produced by that chain's own tooling. EVM destinations are
  covered by the keccak and CREATE2 tests.
