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
- **The report float is not sized.** A zkSync or Tron transceiver pays every return report
  from its own float, in its own currency, for accounts homed on any chain, while each home
  charges its bootstrap fee in the home's currency. Nothing moves the fee to the chain that
  pays; the float is funded out of band, and how much it needs depends on traffic from every
  home.

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
- **Arachnid's factory on every target chain.** A chain is `Predetermined` only if its
  transceivers were deployed through `CrossProxyDeployer`, which Arachnid's factory places
  (#33). Ethereum, Base, Arbitrum One, OP Mainnet, and zkSync Era all have its code at its
  address (checked over RPC, 2026-10-06, recorded in `contracts/evm/deploy/chains.toml`); a
  chain added later is checked when it is. Code there is not enough on its own: zkSync Era has
  it, but EraVM places `CrossProxyDeployer` elsewhere. A chain without it is `Unique` in every registry and grades every other
  chain `Unique` in its own, so its transceivers cannot be born configured: the governor's
  home is not `Predetermined` from there, and `initialize` refuses that (#32). Supporting one needs
  a way to seed the home's counterpart on that chain, such as an explicit counterpart in the
  registry seed.
- **EIP-152 on every target chain.** Any chain can be a home, and the BLAKE2b commitment
  scheme needs the precompile at `0x09`. Without it `Blake2b256` fails closed (the scheme
  reverts), so the cost is the feature, not funds, but which target chains have it is not
  verified.
- **Not every pair is a lane.** CCIP lanes, Wormhole Executor quotes, and Hyperlane routes
  exist per pair, and every transceiver now has routes to nearly every chain. What each
  provider's quote does for an unconnected pair is not checked; a bootstrap there should
  revert at the quote rather than on the provider. One test per binding.
- **Hyperlane's verification is the destination's.** The destination Mailbox's ISM decides
  what counts as verified for every origin that chain accepts, so each origin added on a
  chain is held to that chain's ISM. Which ISM each target chain's Mailbox uses is not
  checked.

## 3. Infrastructure

- **Deploy scripts cover step 2 only.** `script/Deploy<Provider>.s.sol` deploys each
  provider's account implementations and transceiver on a standard EVM chain, through the
  `script/deploy/` functions the test suites also deploy through
  ([spec §6](provider-spec.md#6-configuration-a-compliant-deployment-performs)). Not scripted:
  step 1 (the per-chain timelock, the seeded registry, the treasury, so the timelock design is
  enforced by nothing), steps 3 to 7, and the payloads that write the N × N tables every chain
  needs about every other chain. Their source exists: `contracts/evm/deploy/` holds each
  chain's derivation, from which every pair's grade follows, and each provider's ids, checked
  by every test and deployment. Nothing generates the payloads from it yet. How many gateways
  each transceiver's initializer names is the deployer's `GATEWAYS` input; they cannot be
  added later. Wormhole's contracts link `WormholeMessage` (#29), which `forge script` deploys
  first through Arachnid's factory. zkSync and Tron have deploy functions the tests use but no
  production script: their bytecode, with `WormholeMessage` linked, is built by zksolc and
  TRON-solc, which these scripts do not drive. The registry's write-once record is keyed by
  the provider names `layerzero`, `ccip`, `hyperlane`, `wormhole`, and `op-stack`.
- **The compliance suite's gaps** ([spec §8](provider-spec.md#8-the-compliance-suite) says
  where every line is held). C11 and C29 to C31 against real endpoints are the fork tests
  below; Wormhole's own replay (C29 to C31) is already tested, since the binding owns it.
  C24's check cannot see a collision inside a single call, so two fields an initializer sets
  together are covered only by the suites that read them back.
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

## 5. Post-launch: Superchain interop

OP Stack stays the pairwise L1-to-L2 binding. Superchain interop's
`L2ToL2CrossDomainMessenger` fits the one-transceiver-per-chain shape and becomes a separate
provider once it is on mainnet. Before building it:

- **L2 to L2 only.** Ethereum is not in the interop set, so an Ethereum home still needs the
  pairwise binding.
- **Dependency sets.** A message executes only if its source is in the destination's
  dependency set, so the routes must match each chain's set, and a bootstrap outside it must
  revert at the quote.
- **Someone must relay.** `sendMessage` is non-payable and `relayMessage` permissionless, so
  delivery depends on an autorelayer or on this protocol relaying.
- **Retry and expiry are unverified.** A message relays at most once (`successfulMessages`);
  whether a reverted relay can be retried, and whether a 7-day expiry on the source log
  applies, is not settled. [Failure handling](message-flow.md#failure-handling) assumes
  indefinite retry, so this is the provider checklist's work
  ([spec §2](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist)).
