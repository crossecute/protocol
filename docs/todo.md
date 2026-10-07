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
(2026-10-07).

- **EraVM's delivery costs are not measured.** The `DeliveryGas` defaults (1,000,000 for a
  bootstrap, 250,000 for a report) come from Forge's EVM, where an account creation costs
  590,000 to 650,000. A bootstrap to zkSync Era needs the same measurement on Era, which
  Forge cannot run; zkSync Sepolia can.
- **The report float is not sized.** A zkSync or Tron transceiver pays every return report
  from its own float, in its own currency, for accounts homed on any chain, while each home
  charges its bootstrap fee in the home's currency. Nothing moves the fee to the chain that
  pays; the float is funded out of band, and how much it needs depends on traffic from every
  home.

## 2. Chain checks before mainnet

- **No Wormhole quoter router on any configured chain** (#53). The binding quotes and sends
  through `ExecutorQuoterRouter`, which Wormhole's SDK lists only on Polygon and Monad.
- **LayerZero cannot reach zkSync** (#51). Its pathways default to a dead DVN, and the
  transceiver, its own delegate, has no way to set DVNs.
- **A Hyperlane domain with no route quotes 0** instead of reverting, and the dispatch would
  never be delivered. Nothing in the deploy refuses such a domain; the check is manual
  ([CHECKS §3](../contracts/evm/deploy/CHECKS.md#3-lanes)). All 20 configured pairs quote.
- **One account deployed on zkSync Era and on Shasta.** The formulas are checked: zkSync's
  matches `ContractDeployer.getNewAddressCreate2` on mainnet, and Tron's `0x41` preimage is
  java-tron's own (`WalletUtil.generateContractAddress2`), which settles the docs
  contradiction. Still unverified is the `accountBytecodeHash` each transceiver is born with,
  from zksolc and TRON-solc, which needs a funded deployment. It fails closed if wrong
  (`AccountAddressMismatch` on every account creation), so the cost is a redeploy.
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

- **Deploy scripts cover step 2 only**
  ([spec §6](provider-spec.md#6-configuration-a-compliant-deployment-performs)). Not scripted:
  step 1 (the per-chain timelock, the seeded registry, the treasury, so the timelock design is
  enforced by nothing), steps 3 to 7, and the payloads that write the N × N tables every chain
  needs about every other chain, whose source is `contracts/evm/deploy/`. zkSync and Tron have
  deploy functions the tests use but no production script: their bytecode, with
  `WormholeMessage` or `LzMessage` linked, is built by zksolc and TRON-solc, which these
  scripts do not drive.
- **The compliance suite's gaps** ([spec §8](provider-spec.md#8-the-compliance-suite) says
  where every line is held). C11 and C29 to C31 against real endpoints are the fork tests
  below. C24's check cannot see a collision inside a single call, so two fields an
  initializer sets together are covered only by the suites that read them back.
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
