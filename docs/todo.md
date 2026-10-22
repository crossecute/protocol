# Outstanding

Everything known to be missing, undecided, or wrong, in one place. Ordered by what blocks
what rather than by size.

[`message-flow.md`](message-flow.md) and [`encoding.md`](encoding.md) describe the design;
this file is the gap between that design and the tree.
[`provider-spec.md`](provider-spec.md) is what the six bindings under
`contracts/evm/src/protocols/` are held to; what they mean for an operator is in the README.

---

## 1. Measurements before mainnet

[`deploy/CHECKS.md`](../contracts/evm/deploy/CHECKS.md) holds the checks and their results
(2026-10-07; §4's destination gas, 2026-10-21).

- **EraVM's pubdata cost is not measured.** The `DeliveryGas` defaults (1,000,000 for a
  bootstrap, 250,000 for a report) come from Forge's EVM, where an account creation costs
  about 624,000 to 678,000. On a local EraVM node a bootstrap's execution needs about 385,000
  to 389,000 ([CHECKS §4](../contracts/evm/deploy/CHECKS.md#4-destination-gas)), but that node
  publishes no pubdata. zkSync Sepolia can measure what pubdata adds, and whether it counts
  against the gas limit a provider calls the transceiver with. A report arriving at a zkSync
  home is not measured either.
- **Wormhole's VAA verification is not measured.** `ProviderDeliveryGasSpec` measures a
  Wormhole delivery against a mock Core that checks no guardian signatures, so the cost of a
  real VAA's verification is missing from every Wormhole number in
  [CHECKS §4](../contracts/evm/deploy/CHECKS.md#4-destination-gas). It counts against the
  same gas limit as the payload's calls. A fork test against a real Core and a signed VAA
  can measure it.
- **The report float is not sized.** A zkSync or Tron transceiver pays every return report
  from its own float, in its own currency, for accounts homed on any chain, while each home
  charges its bootstrap fee in the home's currency. Nothing moves the fee to the chain that
  pays; the float is funded out of band, and how much it needs depends on traffic from every
  home. Mass bootstrapping can also spend it down on purpose (#78, pinned by
  `test/invariant/FeesAndFloat.t.sol`): the fee floor is only nonzero, and the cheapest home
  sets the price. An empty float refuses bootstraps to that chain from every home, but strands
  none: anyone can retry one and bring its report's cost, so until a refill every user of that
  chain pays their own report. A fee of at least one report's cost makes the attacker pay for
  every report the float pays ([path B](message-flow.md#b-bootstrap-no-receiver-on-the-destination-yet)
  gives the cost), which needs the report's measured cost on each reporting chain. Each home's
  owner can halt bootstraps to a reporting chain by setting its fee there to zero.

## 2. Chain checks before mainnet

- **LayerZero's zkSync side is unverified.** Its pathways default to the dead DVN, so both
  ends pin LayerZero Labs' DVN (#51, [CHECKS §5](../contracts/evm/deploy/CHECKS.md#5-verification-on-the-destination)).
  The Ethereum side quotes on a fork; the zkSync side needs a zkSync Sepolia run.
- **One account deployed on zkSync Era and on Shasta.** The formulas are checked: zkSync's
  matches `ContractDeployer.getNewAddressCreate2` on mainnet, and Tron's `0x41` preimage is
  java-tron's own (`WalletUtil.generateContractAddress2`), which settles the docs
  contradiction. On a local EraVM node, a zkSync transceiver born with the hash read from a
  deployed `CrossProxy` created its account where it predicted (2026-10-20, CHECKS §4). Still
  unverified is the `accountBytecodeHash` of the production zksolc and TRON-solc builds,
  which needs a funded deployment. It fails closed if wrong (`AccountAddressMismatch` on
  every account creation), so the cost is a redeploy.
- **A chain without Arachnid's factory is unsupported.** It is `Unique` in every registry and
  grades every other chain `Unique` in its own (#33), so its transceivers cannot be born
  configured: the governor's home is not `Predetermined` from there, and `initialize` refuses
  that (#32). Supporting one needs a way to seed the home's counterpart on that chain, such as
  an explicit counterpart in the registry seed.
- **zkSync and Tron cannot compute BLAKE2b commitments.** EraVM has no EIP-152, and Tron's
  `0x09` is `BatchValidateSign`, with BLAKE2F off on mainnet; `Blake2b256` fails closed on
  both. An account homed there cannot use the BLAKE2b scheme.
- **Hyperlane's verification can change.** Each destination's default ISM is mapped per origin
  in [CHECKS §5](../contracts/evm/deploy/CHECKS.md#5-verification-on-the-destination); the
  Mailbox owner can replace it, so it is rechecked before mainnet.

## 3. Infrastructure

- **Deploy scripts cover parity chains only**
  ([spec §6](provider-spec.md#6-configuration-a-compliant-deployment-performs)). Steps 1 to 6
  are scripted for them, the N × N tables as payloads from `contracts/evm/deploy/`. Not
  scripted: `op-stack-l2-l2`'s lanes, which the payload script refuses to skip once a chain is
  listed; registry plugins, which no parity chain needs (a commitment scheme only previews);
  and a chain added after the first deployment, whose files repeat what is already set. zkSync
  and Tron, and every lane to them, are left out of the payloads, and have deploy functions
  the tests use but no production script: their bytecode, with
  `WormholeMessage` or `LzMessage` linked, and their `TransceiverExtension` variant are built by
  zksolc and TRON-solc, which these scripts do not drive. zksolc 1.5.18, with ZKsync's solc
  0.8.28-1.0.2, compiles the zkSync transceivers and extensions (checked by hand 2026-10-19).
  zksolc 1.5.15, with 0.8.28-1.0.1, compiles `ChainRegistry` (2026-10-20, #82), but not
  `VmDeriver`, whose Bitcoin schemes use `ripemd160`. CI runs neither.
- **Wormhole publish-only messages need a deliverer.** A multisig cannot carry a relay
  provider's quote, which expires an hour after it is issued (deploy/CHECKS.md), so its
  Wormhole sends and bootstraps take the publish-only attribute: the transaction publishes
  and pays no relay provider. Nothing delivers those messages yet. The tooling needs a job
  that watches `LogMessagePublished` from every governor transmitter and Wormhole
  transceiver, fetches each signed VAA from Wormholescan once the guardians sign it, and
  calls `executeVAAv1` on the destination, paying its gas. Anyone may run one; delivery
  needs no role.
- **Retrying a bootstrap stuck on an empty float needs tooling.** For LayerZero and Hyperlane
  it is the provider's own retry (`EndpointV2.lzReceive`, `Mailbox.process`) sent with the
  report's quote as `msg.value`. For CCIP it needs a contract that transfers the quote to the
  float and calls manual execution in one transaction, since a separate top-up can be spent by
  another retry first (#78). Neither is written.
- **The compliance suite's gaps** ([spec §8](provider-spec.md#8-the-compliance-suite) says
  where every line is held). C11 and C29 to C31 against real endpoints are the fork tests
  below. C24's check cannot see a collision inside a single call, so two fields an
  initializer sets together are covered only by the suites that read them back.
- **One fork test, and CI does not run it.** Every binding is tested against a mock of its
  provider. `test/fork/LzDvnFork.t.sol` checks #51 against Ethereum's LayerZero endpoint and
  skips without `ETH_RPC_URL`, which CI does not set. C11, and C29 to C31 for every provider
  but Wormhole, test the transport rather than the binding, so until they run against each
  provider's real deployment, P7 and P9 remain documented assumptions.
- **`deploy/governance.toml` is unset.** The governor's owner and salt, and each provider's
  `deployed_by` and salt, are zero, and the deploy scripts refuse them. Its proposers,
  LayerZero and CCIP, are a default to confirm: they must be two providers that reach every
  chain from the home, which rules out both OP Stack providers, and Wormhole until its
  deliverer exists.
- **Dependency pins.** Decided 2026-10-19: Foundry stays at 1.8.1 (latest 1.8.5), and
  OpenZeppelin at 5.4.0 (latest 5.7.0). Foundry does not set the bytecode; solc and its
  settings are pinned in `foundry.toml`. From 5.5.0, OpenZeppelin's `Arrays` uses `mcopy`,
  which `EnumerableSet` reaches, so `src/` no longer compiles at `paris` (README,
  Assumptions). The one OpenZeppelin advisory since 5.2 (`Bytes.lastIndexOf`) is fixed in
  5.4.0, and `src/` does not import `Bytes`.

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

`op-stack-l2-l2` is built over the `L2ToL2CrossDomainMessenger` predeploy and tested against a
mock, and deploys with an interop L2 as its governor's home. It is not deployable until interop
is live: `deploy/providers/op-stack-l2-l2.toml` lists no chain. Before listing one:

- **Dependency sets are not recorded.** A message executes only if its source is in the
  destination's dependency set, so a chain may be routed only within its set. Which chains
  share a set is not in `deploy/`.
- **Someone must relay.** `sendMessage` is non-payable and `relayMessage` permissionless, so
  delivery depends on an autorelayer or on this protocol relaying.
- **Expiry is unverified.** Whether a source log expires after some window, ending its retry,
  is not settled. [Failure handling](message-flow.md#failure-handling) assumes indefinite
  retry, so this is the provider checklist's work
  ([spec §2](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist)).
