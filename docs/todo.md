# Outstanding

Everything known to be missing, undecided, or wrong, in one place. Ordered by what blocks
what rather than by size.

[`message-flow.md`](message-flow.md) and [`encoding.md`](encoding.md) describe the design;
this file is the gap between that design and the tree.
[`provider-spec.md`](provider-spec.md) is what the five bindings under
`contracts/evm/src/protocols/` are held to; what they mean for an operator is in the README.

---

## 1. Measurements before mainnet

- **No provider's default gas is measured.** With no gas attribute, Hyperlane sends 50,000
  (the IGP default, written explicitly because the refund field follows it), the Wormhole
  Executor 200,000, and OP Stack's `minGasLimit` 200,000. `_reportReceiver` always sends with
  no attributes, and a bootstrap does unless its caller passes one; none of these defaults is
  measured against either.
  Hyperlane's is probably too low. An OP Stack underestimate is recoverable (the messenger
  records the failed relay and anyone can replay it with more gas); the others are not
  known to be.

## 2. Chain checks before mainnet

- **Tron CREATE2 against a Shasta deployment**, to resolve the 0x41-vs-0xff docs
  contradiction. It needs a FUNDED deployment: the trick that settled Aurora, `eth_call`ing
  Arachnid's factory so the chain's own engine answers, does not transfer, because that
  factory relies on a pre-signed Ethereum transaction and is absent from Tron and Shasta. A
  one-afternoon empirical check that de-risks a whole chain family. Now load-bearing rather
  than merely tidy: `TronAccounts`, which every Tron transceiver uses, commits to `0x41`
  through `AddressDerive.tronCreate2`, so this check is what decides whether a Tron
  transceiver works. It fails closed if wrong (`AccountAddressMismatch` on every account
  creation), so the cost of being wrong is a redeploy rather than a loss. zkSync Era's
  derivation (`ZkSyncAccounts`) is unverified the same way and needs the same one-account
  check.

## 3. Infrastructure

- **No deploy scripts.** `script/` holds only the vendoring drivers. The deploy story in the
  [spec's §6](provider-spec.md#6-configuration-a-compliant-deployment-performs) (Arachnid's
  factory, a per-chain timelock, a seeded registry, transceivers born accepting the governor's
  home) has no code behind it. The CREATE2 parity argument stands or falls on that initcode
  and those constructor arguments being byte-identical on every chain, and nothing pins them.
  The scripts are also where the deployment-time provider decisions get made: the
  `accountInitCodeHash` assertion (R8.4), how many gateways each transceiver's initializer
  names (they cannot be added later), the N × N tables every chain needs about every
  other chain, generated from one source since nothing on-chain checks they agree, and the
  `WormholeMessage` library every Wormhole contract links, deployed before them (on zkSync
  and Tron, linked when that chain's bytecode is built).
- **The compliance suite has two gaps** ([spec §8](provider-spec.md#8-the-compliance-suite)
  says where every line is held). C21's script-side assertion waits on the deploy scripts.
  C11 and C29 to C31 against real endpoints are the fork tests below; Wormhole's own replay
  (C29 to C31) is already tested, since the binding owns it. C24's check cannot see a
  collision inside a single call, so two fields an initializer sets together are covered
  only by the suites that read them back.
- **No fork tests.** Every binding is tested against a mock of its provider. C11, and C29 to
  C31 for every provider but Wormhole, test the transport rather than the binding, so until
  they run against each provider's real deployment, P7 and P9 remain documented assumptions.

## 4. Post-launch: non-EVM destinations

Launch is EVM-only. No chain here is reachable until its vectors exist, so none of this
blocks it.

- **`test/vectors/`.** [`encoding.md`](encoding.md) specifies the corpus and the
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
- **The opaque container off the EVM**: ABI framing or a length-prefixed one. Not blocking
  until a non-EVM receiver exists, because the commitment never sees the container.
- **The Solana account list belongs inside the committed element.** Argued in
  [`encoding.md`](encoding.md); worth marking settled when the first vector is written.
- **Owner-writable non-EVM locations**: allowed directly, or only through the graded
  resolution paths?
