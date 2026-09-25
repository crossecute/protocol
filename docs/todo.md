# Outstanding

Everything known to be missing, undecided, or wrong, in one place. Ordered by what blocks
what rather than by size.

[`message-flow.md`](message-flow.md) and [`encoding.md`](encoding.md) describe the design;
this file is the gap between that design and the tree.
[`provider-spec.md`](provider-spec.md) is what the five bindings under
`contracts/evm/src/protocols/` are held to; what they mean for an operator is in the README.

---

## 1. Blockers on specific paths

- **Funding a diverging spoke, and getting the money there.** The report fires from inside
  the destination's inbound callback, where `msg.value` is zero, so it is paid from the
  spoke's own balance and a dry one reverts the bootstrap with it. That revert is deliberate
  and keeps the operation retryable.

  **The fee half is built.** `HubTransceiverBase.bootstrapFee` is a per-chainKey surcharge
  the msig sets. `_bootstrapSendValue` takes it off `msg.value` at bootstrap and forwards it
  to the hub's `treasury` in the same transaction, so nothing accrues anywhere. It is zero
  by default, so only the chains that actually report are charged. It is in `quoteBootstrap`
  because a quote that omitted it would be worse than none: the caller would fund the send
  exactly, and the bootstrap would revert with the signers already committed.

  **What is not built is the crossing.** The fee is paid on the home chain in the home
  currency and the spoke needs the destination's, so the two are funded separately and out
  of band. Making that automatic means the bootstrap message drops value across, which is a
  provider capability question rather than a contract one.

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

  **It does not need a redeploy.** `ICommitmentScheme` plus
  `ChainRegistry.setCommitmentScheme` make a primitive a per-chainKey plugin, so the port
  lands as a deployment and one owner transaction rather than as new account bytecode,
  which frozen accounts could never receive anyway. The enum cannot grow, being compiled
  into every live transmitter, so a new primitive gets a contract rather than a member.
  What is outstanding is Poseidon itself.

## 2. Decisions taken that deserve a second look

None of these are bugs. Each is a deliberate choice with a cost worth confirming before
mainnet.

- **The owner is a live authority, and the roles bound it.** Configuration moved to `Ownable`
  when `ADMIN_ROLE` was retired, so a compromised owner can still repoint nothing that is
  write-once, add no transport, and redirect no fee. The treasury is write-once and is paid
  in the same transaction that charges it.
  What it CAN do is set a route or a counterpart on a chain that has none yet, and set the
  bootstrap fee.

  **RESOLVED, PARTIALLY BY DESIGN.** `setRouting` (`HubTransceiverBase`) let the owner
  silently repoint the registry a hub trusts and its provider id at any time, with no
  write-once guard and no test exercising that. That half is now locked, following
  `setRoute`/`setCounterpart`'s pattern: re-declaring the same `(registry, providerId)` pair
  is a no-op, a different one reverts `RoutingAlreadySet`.

  `minCounterpartProvenance` (also set through `setRouting`) and `ChainRegistry.setProvenance`
  turned out to be the opposite of a gap: `test_hubProvenanceBarAppliesToInbound` and
  `test_aDerivableChainMayNotReport` already exercise raising and lowering both live, on a
  deployed instance, as the intended way to react to a bridge's standing changing without a
  redeploy. Both stay freely rebindable. So the owner's list grows by exactly one entry
  removed (repointing the registry/provider id) rather than the three originally suspected.
- **Approvals are unordered, and a sequence has to be expressed inside the payloads.** A
  relayer holding two valid arrays chooses which lands first. Nothing stalls, which is the
  trade, but an operation that depends on order cannot rely on the approval layer for it.

  **CONFIRMED.** No planned operation depends on approvals landing in a particular order.

  **A note on privatizing execution, for when ordering matters operationally rather than
  correctness-wise.** `commit(hash)` reveals nothing about what the array contains, only
  `finalize(calls)` does, and `finalize` is permissionless and open to whoever holds the
  matching array. So a team wanting to control WHEN and IN WHAT ORDER two approved
  operations actually land can commit both hashes with no calldata published anywhere, and
  hold the matching arrays privately, submitting `finalize` themselves in whichever order
  they choose: an outside watcher sees two commitments and cannot construct either array
  from the hash alone, so it cannot race the team to finalize one out of turn. This is a
  usage pattern available today, not a protocol guarantee: it holds only as long as the
  calldata stays off-chain and unguessable until the team submits it.
- **A parity chain can still be sent to before its bootstrap has landed.** `isReachable` is
  true from dispatch there, because the address is pre-deterministic and correct. What is
  not guaranteed is that the receiver EXISTS yet, since a deferred bootstrap waits for
  someone to finalize it. Those sends fail on arrival and are retryable at the provider, so the cost is
  the fee and the wait. Closing it would mean a confirmation message on chains that need none,
  which is the trade this deliberately does not make.

  **CONFIRMED.** Accepting the trade: a lost, retryable send at the cost of sending before
  the destination is actually set up is not a security risk, only a self-inflicted ordering
  mistake. No confirmation message added.
- **A blank `CrossProxy` delegates to `address(0)` and succeeds silently.** Only safe
  because deploy, arm, and lock are one function. It becomes a real hole if those are ever
  split.

  **CONFIRMED SAFE, WITH THE MECHANISM SPELLED OUT.** `_createCrossAccount`
  (`TransceiverBase.sol`) calls `_deployAccount` (bare proxy: no implementation, admin = the
  transceiver) and then `upgradeInitializeAndLock` as two statements in ONE function, so
  there is no transaction boundary between them for anyone to call the blank proxy through.
  "Arm" and "lock" are themselves one call, not two: `CrossProxy.fallback()` runs
  `ERC1967Utils.upgradeToAndCall(implementation, data)` (sets the implementation AND
  delegatecalls into it with the initializer, which for a LayerZero transceiver is where
  `__OApp_init(delegate)`, the peer, and `GATEWAY_ROLE` all have to be set, since this is the
  only initializer call the proxy ever gets) and, immediately after, zeroes its own admin
  slot. There is no "before LZ config" phase and no separate step after arming; LZ setup IS
  part of arming. Stays a real hole only if deploy is ever split from arm/lock into separate
  transactions, which nothing today does.
- **Self-replaying payloads.** `finalize` clears an approval before executing, so a payload
  containing a self-call to `commit` with its own hash re-arms itself indefinitely.
  Owner-approved either way, so not an escalation, but "approvals are single-use" stops
  being true. Disallowing it costs extra code. Allowing it is strictly cheaper.

  **CONFIRMED.** Kept allowing it: the transmitter could already re-`commit` the same hash
  through an ordinary message any time it wants, so a self-replaying payload grants no
  authority that did not already exist. No guard added.
- **Whether to replace `src/addressing/Erc7930.sol` with OpenZeppelin's
  `draft-InteroperableAddress`.** It is out of reach at the pinned version, which predates
  it, so adopting it means moving the dependency first. Two checks come before that: the
  upstream is a `draft-`, and our `parseStrict` enforces strictness the registry depends on.
  Both are argued in
  [`provider-research.md`](provider-research.md#the-other-draft-worth-knowing-about). It is
  its own task with its own vectors.

  **DECLINED.** Staying on the hand-rolled `Erc7930.sol`: the OZ bump this would require
  breaks proxy inheritance (see `Roles.sol`'s note on `AccessControlEnumerableUpgradeable`
  and the `paris`/`mcopy` collision — OZ past 5.4.0 does not compile at `paris`, which the
  CREATE2 parity story depends on). Not worth the dependency migration.

- **A LayerZero receiver's or spoke's peer has no setter.** OApp's `setPeer` is `onlyOwner`
  and these contracts have no `Ownable`, so the peer is written once in the initializer. It
  fell out of that fix rather than being chosen: confirm it is wanted, rather than an
  owner-gated repoint on the account side, before mainnet.
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
- **Empty-array commitments.** `execute` refuses one; `finalize` accepts. Pick one.
- **Registry `slot` namespacing.** Raw `transceiverId`, so two callers choosing the same
  bytes32 collide; only the monotonic provenance rule limits the damage.
- **Owner-writable non-EVM locations**: allowed directly, or only through the graded
  resolution paths?
- **What else a self-call may reach.** Today `commit` / `cancel` / `finalize` / `execute`.
  When a merkle-root setter lands, a self-call could rotate the policy: probably right,
  but it should be deliberate.
- **Whether bootstrap may carry a full payload**, or only enough to stand the account up.
- **No storage gaps anywhere.** A transceiver locks upgrades in its own initializer, so
  there is no later upgrade to make room for; the registry and the account implementations
  are where a gap would still buy something.
- **`renounceOwnership` bricks a transmitter.** Recorded rather than prevented; disabling it
  is a separate decision.
- **Tron CREATE2 against a Shasta deployment**, to resolve the 0x41-vs-0xff docs
  contradiction. It needs a FUNDED deployment: the trick that settled Aurora, `eth_call`ing
  Arachnid's factory so the chain's own engine answers, does not transfer, because that
  factory relies on a pre-signed Ethereum transaction and is absent from Tron and Shasta. A one-afternoon empirical check that de-risks a whole chain family. Now
  load-bearing rather than merely tidy: `TronSpokeTransceiver` commits to `0x41` through
  `AddressDerive.tronCreate2`, so this check is what decides whether that spoke works. It
  fails closed if wrong (`AccountAddressMismatch` on every account creation), so the cost of
  being wrong is a redeploy rather than a loss. See §1. zkSync Era's override
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
- **A fourth provider, NEAR Intents / Chain Signatures, is not ruled out but needs its own
  research pass before it belongs anywhere near the other three.** Explored informally, not
  source-verified the way §4/§5 of [`provider-research.md`](provider-research.md) are.

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
  as "the account" at all — an architecture question upstream of "add a fourth binding," not
  a peer of the LayerZero/CCIP/Hyperlane comparison.

  **Explicitly not required for, and must not block, the three-provider MVP.** Recorded here
  so it isn't rediscovered under time pressure. The next step, if ever pursued, is
  source-verified research matching the existing provider-research.md format — of `v1.signer`
  and NEAR's validator threshold-signing scheme itself, not of the Intents/Verifier
  application layer built on top of it.

- **Sending should not make a signer responsible for pricing its own message, and this needs
  solving before mainnet even though it does not block the provider-bindings PR.** Found
  while wiring the three bindings: the identical mistake (quote now, send later, the fee
  moved) fails three different ways. LayerZero's stock `_payNative` requires
  `msg.value == nativeFee` EXACTLY and reverts `NotEnoughNative` on any drift, either
  direction; the bindings override it to spend `value`, and the endpoint still reverts an
  underpayment. CCIP's own NatSpec says an overpayment is accepted with no refund, so padding
  the quote for safety just burns the difference. Hyperlane's `Mailbox.dispatch` sends
  `requiredHook` what it asks and forwards the rest of `msg.value` to the post-dispatch
  hook; the IGP and ProtocolFee hooks refund their overpayment to `metadata.refundAddress`
  (which the binding sets to `_refundTo()` in `HyperlaneMessage.hookMetadata`), but any other hook the Mailbox owner
  configures may keep it. No single on-chain buffer is safe across all three; at least one
  of them turns "add a margin" into a standing cost. Wormhole's Executor quoter router
  refunds its overpayment to `_refundTo()`, and OP Stack has no fee to pad.

  **The direction to build toward: the transmitter prices and funds the send itself, rather
  than asking a signer to have attached the right `msg.value` in advance.** Concretely, on
  send the transmitter calculates the provider's current fee dynamically and pays it out of
  a pre-funded balance it holds, rather than requiring the caller's transaction to carry an
  exact, pre-computed amount. A signer approves a PAYLOAD, not a payload-plus-a-price, and
  never touches gas or bridging cost at all.

  **This is what actually closes the staleness problem, and closes it structurally rather
  than by padding a number.** The failure mode above exists because the fee is fixed at the
  moment something is SIGNED, and provider pricing can move before that signature is
  submitted and executed. Pricing at send time, from a balance that does not need the
  signer's transaction to carry an exact value, removes the gap between when a price is
  fixed and when it is paid — there is no longer a stale number to submit, because nothing
  about the signature commits to one.

  **Pre-production, not pre-PR.** This needs the bindings to exist and their real fee
  behavior to test against (this todo exists because that testing already found the
  divergence above), so it belongs after the provider-bindings PR lands, not inside it — but
  it has to land before mainnet, since it is the difference between a signer bearing gas risk
  and the protocol bearing it.

  **A stale NatSpec to correct in the same pass.** `OutboundBase._quoteMessage` currently
  says quoting inside a send is unnecessary because "a price that moved into a revert, when
  the provider's refund already handles it." That assumption is false for all three
  providers, per the divergence above: LZ reverts on any mismatch with nothing to refund,
  CCIP keeps an overpayment outright, and Hyperlane's refund depends on which hook the
  Mailbox owner has configured. Fix that comment when this lands, so it stops asserting a safety
  net that does not exist.

## 4. Infrastructure: None of it exists

- **`lib/` is pinned submodules**: forge-std v1.16.2, OZ v5.4.0, OZ-upgradeable v5.4.0, each
  recorded as an exact commit rather than a branch, because CREATE2 parity depends on
  byte-identical initcode and a floating dependency would move every account address on the
  next `--remote`. `git submodule update --init` is enough. The nested submodules OZ carries
  for its own test suite are not needed, and `--recursive` only costs time.

  **What this gives up against vendoring is availability, not exactness.** A gitlink is as
  precise as a committed tree, but the bytes now live upstream: a deleted or force-pushed tag
  is a repository nobody can build. Worth a mirror before mainnet rather than a policy.

  **A dependency bump moves every account address**, because `CrossProxy`'s initcode hash
  is a function of everything it compiles against. Free while nothing is deployed; after a
  deployment it is not a bump, it is a migration of every account on every chain. So the
  version to ship on has to be settled before `script/` exists, not after.

- **The `paris` pin and OpenZeppelin are on a collision course, and it gets worse.** OZ has
  DEPRECATED the storage-based `ReentrancyGuard` and says it will be replaced by
  `ReentrancyGuardTransient` in v6.0, which needs TSTORE and therefore Cancun. The question
  to settle before then is which chains the pin is actually buying, since zkSync and Tron are ALREADY excluded from address derivation by
  their provenance caps: their CREATE2 formulas differ, so parity never held for them. If
  the pin is only protecting chains that the registry already declines to derive, it is
  costing more than it buys.
- **No deploy scripts.** `script/` holds only the vendoring drivers. The Assumptions section
  specifies an elaborate deploy story (Arachnid's factory, proxy with deployer-as-owner,
  immediate upgrade, ProxyAdmin under the msig), with no code behind it. The CREATE2 parity
  argument stands or falls on that initcode being byte-identical, and nothing pins it. The
  scripts are also where the deployment-time provider decisions get made: the
  [spec's §6](provider-spec.md#6-configuration-a-compliant-deployment-performs) order, the
  `accountInitCodeHash` assertion (R8.4), and how many gateways each `Deployment` names, since
  a transceiver's gateways cannot be added to later.
- **No `ProviderCompliance.t.sol`.** The spec's C1 to C31 harness was never built. The five
  bindings share `test/protocols/ProviderBindingSpec.t.sol` instead, which holds every one of
  them to C1 and C2 (the send resolves the configured destination and reverts for an
  unconfigured one), C5 and C6 (unconfigured origin, impersonator), a quote equal to the
  mock's fee toward C11, and rejection of a wrong caller or a revoked gateway. Everything
  else is covered only in some bindings' own suites or not at all, and C29 to C31 only for
  Wormhole, the one binding that owns replay.
- **No fork tests.** Every binding is tested against a mock of its provider. C11, C29, and
  C30 test the transport rather than the binding, so until they run against each provider's
  real deployment, P7 and P9 remain documented assumptions.
- **No CI.** No `.github/`.
- **No `test/vectors/`.** [`encoding.md`](encoding.md) specifies the corpus and the
  "assert fields, not bytes" rule. Foundry can verify the commitment half for every VM with
  no non-EVM tooling: cheap, and the only defence on the execute-on-arrival path where
  there is no commitment at all. **Now load-bearing for the scheme plugins**: an
  `ICommitmentScheme` is only as good as the evidence that its primitive matches what the
  destination's own receiver applies, and a wrong one leaves an approval that can never be
  discharged. The corpus is what turns "we believe this is Blake2b" into a
  check.
