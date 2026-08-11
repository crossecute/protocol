# Outstanding

Everything known to be missing, undecided, or wrong, in one place. Ordered by what blocks
what rather than by size.

[`message-flow.md`](message-flow.md) and [`encoding.md`](encoding.md) describe the design;
this file is the gap between that design and the tree.
[`provider-spec.md`](provider-spec.md) is what closing the first gap below requires.

---

## 1. No message provider is integrated

**This is the headline.** Both paths are built end to end in-process (`_sendMessage`,
`sendMessage` / `bootstrap` / `bootstrapTo`, the inbound funnel, the reentrancy guard), and
nothing crosses a real bridge, because every seam that would touch a provider is still at
its default.

Still missing on the transport itself:

| Missing | Where | Default today |
| --- | --- | --- |
| The send | `OutboundBase._sendMessage` | reverts `SendNotImplemented` |
| The quote | `OutboundBase._quoteMessage` | reverts `QuoteNotImplemented` |
| Which gateway may deliver to a receiver | `ReceiverBase._isAuthorizedGateway` | `LzReceiver` returns false, so a receiver accepts nothing |
| The transceiver's inbound callback | the binding's own, feeding `TransceiverBase._onInbound` | does not exist; `_onInbound` has no caller |
| Provider setup in `_accountInitializer` | `Hub`/`SpokeTransceiverBase` | `virtual` throughout, and no binding fills it |
| `supportsAttribute` | `TransmitterBase` | returns false for everything |

The spoke → hub report is no longer on this list: `SpokeTransceiverBase` sends it from
`bootstrapInbound`, gated on a write-once `addressesDiverge` flag, so it fires only where
the hub cannot derive the address itself. What remains is funding a diverging spoke, below.

## 2. The provider binding

`LzTransmitter`, `LzReceiver`, `LzHubTransceiver`, and `LzSpokeTransceiver` inherit no
LayerZero code: no `OApp`, no endpoint, no `@layerzerolabs` in `lib/` or in the remappings.
**Nothing has ever crossed a bridge.**

The claim the whole redesign rests on (that an account can be its own provider endpoint,
and that a *proxy* can hold one) is untested. This is the next thing to build: it is what
turns `_sendMessage` from a seam into a send, and it is what every remaining path is
waiting on.

### What was found in the package

Verified against `@layerzerolabs/oapp-evm-upgradeable@0.1.3` (it imports interfaces from
`@layerzerolabs/oapp-evm`, 0.4.1 at the time of checking). Vendor both under
`contracts/evm/lib/`, matching the existing convention.

```solidity
abstract contract OAppCoreUpgradeable is IOAppCore, OwnableUpgradeable {
    ILayerZeroEndpointV2 public immutable endpoint;
    constructor(address _endpoint) { endpoint = ILayerZeroEndpointV2(_endpoint); }
    function __OAppCore_init(address _delegate) internal onlyInitializing {
        if (_delegate == address(0)) revert InvalidDelegate();
        endpoint.setDelegate(_delegate);
    }
}

abstract contract OAppUpgradeable is OAppSenderUpgradeable, OAppReceiverUpgradeable {
    constructor(address _endpoint) OAppCoreUpgradeable(_endpoint) {}
    function __OApp_init(address _delegate) internal onlyInitializing {
        __OAppCore_init(_delegate);
        __OAppReceiver_init_unchained();
        __OAppSender_init_unchained();
    }
}
```

**One constructor argument, and it does not matter.** It is on the *implementation*, and an
implementation's address lives in the proxy's ERC-1967 storage slot rather than in its
initcode, so `CrossProxy` stays argument-free and no derived address moves. The endpoint
being an `immutable` is correct rather than merely tolerable: every account on a chain uses
the same endpoint, which is exactly what an implementation-level immutable expresses.

**It fits our layout without collisions.** `OAppCoreUpgradeable` keeps its peer mapping in
ERC-7201 namespaced storage (`OAPP_CORE_STORAGE_LOCATION`), as do `OAppOptionsType3`,
`PreCrime`, and the simulator. So it cannot collide with `sourceTransmitter`, `accountSalt`,
or the approval queue however our layout changes, which also removes the storage-gap
question for accounts specifically.

**`Ownable` is deliberately left uninitialized.** The package says so in a comment: *"Ownable
is not initialized here on purpose. It should be initialized in the child contract to
accommodate the different version of Ownable."* Since it derives OZ's `OwnableUpgradeable`,
the same one `LzTransmitter` uses today, `__Ownable_init(owner)` plus `__OApp_init(delegate)`
composes rather than collides, and `TransmitterBase`'s ownership seam means the base is
unaffected either way.

### Where each seam attaches

The hooks are ERC-7786-shaped now, so a NATIVE LayerZero binding has one translation the
old table did not: the recipient arrives as an ERC-7930 envelope and the eid has to come
back out of it, rather than out of a route lookup.

| Our hook | LayerZero |
| --- | --- |
| `_sendMessage(recipient, payload, attributes)` | `_lzSend(eid, payload, options, MessagingFee, refund)`: `eid` from the binding's own chainKey→eid table keyed on `ChainKey.fromIdentifier(recipient)`, `options` decoded from `attributes`, `refund` from `_refundTo()` |
| `_quoteMessage(recipient, payload, attributes)` | `endpoint.quote(MessagingParams(...), address(this)).nativeFee`, over the same `eid` and `options` the send resolves |
| `_isAuthorizedGateway(address)` | `instance == address(endpoint)`, or however the binding routes `lzReceive` into `receiveMessage` |
| `_onMessage(bytes payload)` | reached through `receiveMessage`, which `_lzReceive` calls |
| `_onInbound(route, sender, message)` | called from `_lzReceive` on a transceiver, with `route` the stored chain identifier for `origin.srcEid` and `sender` narrowed per R4.2 |
| `_accountInitializer(owner, salt, calls)` | must build `__OApp_init(delegate)` **and** the peer, since the account locks in the same call |
| `_checkAdmin` / `_checkOwner` | answered from OApp's own `Ownable` |

**A native binding reintroduces a codec, and the eid table with it.** ERC-7786 removed the
protocol's need for a provider id, not LayerZero's: `_lzSend` still takes a `uint32`. So a
native LayerZero binding keeps its own chainKey→eid mapping under R5, where a gateway
binding keeps none.

**The peer value is `counterpartOn(chainKey)`, not `address(this)`.** The two agree wherever
Ethereum's CREATE2 formula holds, which made the shortcut tempting; they differ on zkSync and
Tron, where deriving the peer names an address holding no receiver. One entry per
destination, read from the table rather than computed.

### Two consequences to decide on

- **`__OAppCore_init` calls `endpoint.setDelegate(_delegate)`.** That runs inside
  `upgradeInitializeAndLock`'s delegatecall, so `address(this)` is the proxy and the
  delegate is registered per account: correct, but it means **every account creation
  touches the endpoint**. Real gas on the bootstrap path, and the concrete form of the cost
  named as "peers and any send-side security configuration are per-user rather than shared".
- **OApp authenticates inbound before our code runs.** `lzReceive` does
  `if (address(endpoint) != msg.sender) revert OnlyEndpoint(...)` then
  `if (_getPeerOrRevert(_origin.srcEid) != _origin.sender) revert OnlyPeer(...)`. That is
  the open question in §4 below, now concrete: it contradicts the rule stated for the
  transceiver, and for a 1:1 pairing there is nothing extra to verify, so accepting it is
  defensible, but it should be a **written exception** rather than an omission.

## 3. Blockers on specific paths

- ~~**Path A does not work on a diverging chain.**~~ FIXED, by storing the counterpart
  instead of deriving it. Both checks used to branch on chain TYPE, which cannot express
  divergence: zkSync and Tron ARE `eip155`, so the transmitter enforced `address(this)` there
  and refused the receiver that actually existed, while the receiver compared its sender
  against `address(this)` and refused the transmitter that actually sent. Both now compare
  against a stored fact: `TransmitterBase` against the counterpart `bootstrap` records and
  `setDestinationReceiver` corrects, `ReceiverBase` against the `sourceTransmitter` it was
  already given at creation and simply was not using. `test/Transport.t.sol`'s
  `DivergingDestinationTest` covers both directions.

  **The check got stronger rather than weaker.** A derived peer could only be checked where
  it was derivable, so every non-EVM recipient went unchecked; a stored one binds on every
  chain, and it compares the whole ERC-7930 recipient, so the chain half is checked too.

  **The derivation is wired too, and the seams are what made it possible.**
  `predictCrossAccount` and `_deployAccount` are `virtual`, and `_createCrossAccount`
  compares what it deployed against what was predicted, so a chain-specific spoke can
  override the formula without being trusted to get it right.
  `ZkSyncSpokeTransceiver` and `TronSpokeTransceiver` use `AddressDerive`'s existing
  `zksyncCreate2` and `tronCreate2`. zkSync overrides both seams, because it cannot deploy
  raw initcode at all: deployment goes through a system contract, so `new CrossProxy{salt:}`
  is what zksolc lowers into it. Tron overrides only the prediction.

  **Both take their account bytecode hash as a write-once initializer argument**, because
  neither can compute it: `CROSS_PROXY_INIT_CODE_HASH` is keccak of SOLC's initcode, while
  zkSync keys on an EraVM versioned hash of a zksolc artifact and Tron on TRON-solc's
  initcode. The value comes from the build for that chain.

  **TWO THINGS ARE STILL UNVERIFIED, AND NEITHER CAN BE SETTLED IN THIS REPO.** Forge runs
  an Ethereum EVM, so the suite pins that each override reproduces `AddressDerive`'s formula,
  that neither matches Ethereum's, and that both fail closed here via the guard. It cannot
  pin that the target chain's own deployer agrees.

  1. **Tron's domain byte is still the open 0x41-vs-0xff question**, recorded in §5 and
     carried as a caveat on `AddressDerive.tronCreate2`. Writing the contract did not resolve
     it; deploying one account through the spoke on Shasta and comparing does.
  2. **The zkSync spoke has never been compiled with zksolc.** `CROSS_PROXY_INIT_CODE_HASH`
     is `keccak256(type(CrossProxy).creationCode)`, and zksolc's handling of `creationCode`
     is not the same as solc's, so the base may not compile there at all. That is the next
     thing to find out, and it is a build question rather than a design one.

  Until both are done, treat a zkSync or Tron deployment as unverified rather than merely
  untested.
- **Funding a diverging spoke.** The report fires from inside the destination's inbound
  callback, where `msg.value` is zero, so it is paid from the spoke's own balance and a dry
  one reverts the bootstrap with it. That revert is deliberate and keeps the operation
  retryable, but the balance still has to come from somewhere: either the msig funds each
  diverging spoke, or the bootstrap message drops value across.

  **Much smaller than it was.** `addressesDiverge` keeps the report off every chain sharing
  Ethereum's CREATE2 formula, so this is an operational requirement on zkSync, Tron, and the
  non-EVM spokes rather than on the whole deployment.
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

  **No longer blocked on a redeploy.** `ICommitmentScheme` plus
  `ChainRegistry.setCommitmentScheme` make a primitive a per-chainKey plugin, so the port
  lands as a deployment and one owner transaction rather than as new account bytecode,
  which frozen accounts could never receive anyway. The enum stays exactly as it is: it is
  compiled into every live transmitter and cannot grow, and new primitives get a contract
  instead of a member. What is still outstanding is Poseidon itself.

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
- ~~**Two `isAuthorizedCommitter` arms are the same address.**~~ SETTLED, and the third arm
  went with it. `commit`, `cancel`, and `execute` are now gated on `isAuthorizedCaller`:
  the source transmitter, or a self-call. The PARENT TRANSCEIVER was removed outright,
  because it only ever needed authority for the bootstrap payload and it has that inside
  `__ReceiverBase_init`; keeping it made the contract that authenticates every inbound
  message on a spoke a standing authority over every receiver it had created. The
  `address(this)` arm was kept explicitly rather than left to coincide with
  `sourceTransmitter`: the two share an address wherever Ethereum's CREATE2 formula holds,
  but not on zkSync or Tron, and without the arm deferred payloads would work on most of a
  deployment and fail silently on the rest.
- **A blank `CrossProxy` delegates to `address(0)` and succeeds silently.** Only safe
  because deploy, arm, and lock are one function. It becomes a real hole if those are ever
  split.
- **Self-replaying payloads.** `finalize` clears an approval before executing, so a payload
  containing a self-call to `commit` with its own hash re-arms itself indefinitely.
  Owner-approved either way, so not an escalation, but "approvals are single-use" stops
  being true. Disallowing it costs plumbing; allowing it is strictly cheaper.
- **Split `provider-spec.md` into a normative half and a research half.** It is past a
  thousand lines and carries three appendices, which is the size at which a reader stops
  being able to tell what they MUST do from what we happen to have found out. The normative
  part is §1 through §8: the prerequisites, the seams, the rules, the prohibitions, the
  compliance suite. The research part is §12 and §13 and growing: what each transport
  actually guarantees about replay, how ERC-7786 would attach, what OpenZeppelin's ERC-7930
  would replace.

  They have different lifetimes, which is the real argument. The normative half changes when
  this protocol changes; the research half goes stale when somebody ELSE ships a release,
  and it carries version-pinned claims about contracts we do not control. Splitting them
  makes the second half's staleness visible instead of letting it rot inside a document
  people read as a specification. A table of contents on whatever remains, too.

- ~~**Whether to bind to a 7786 gateway at all.**~~ SETTLED, in the core rather than as a
  binding: `TransmitterBase` is an `IERC7786GatewaySource`, `ReceiverBase` an
  `IERC7786Recipient`, and the route slot holds a chain identifier. Two guarantees were
  traded for that and are recorded rather than hidden: the typed-versus-opaque payload
  pairing is no longer checkable on path A, since `bytes payload` cannot be asked which form
  it holds, and the recipient-is-this-account check binds on `eip155` only, because on a
  diverging or non-EVM chain the address is not derivable here.
  `CrosschainLinked(Upgradeable)` is NOT adopted: see
  [`provider-spec.md`](provider-spec.md#13-appendix-erc-7786-as-a-transport).

- **Whether to replace `src/addressing/Erc7930.sol` with OpenZeppelin's
  `draft-InteroperableAddress`.** 5.6.1 brought it: 245 lines against our 248, audited and
  maintained, covering the same ground with `formatEvmV1`, `parseEvmV1`, and `try` and
  calldata variants. The one decision left over from the ERC-7786 work, and it is not taken.
  Blocked on two checks: it is a `draft-`, which OZ excludes from API stability and may
  change in a MINOR release, and this codebase freezes accounts against exact bytes; and our
  `parseStrict` enforces strictness the registry depends on (non-minimal `eip155` references
  and trailing bytes both rejected) that `parseV1` may not match. Neither is a reason not to
  do it; both are reasons it is its own task with its own vectors. See
  [`provider-spec.md`](provider-spec.md#13-appendix-erc-7786-as-a-transport).

  **Which provider to bind is still open, and the 7786 answer is "only if it has to be".**
  A gateway binding is thin (see the skeleton in
  [`provider-spec.md`](provider-spec.md#10-worked-skeleton-an-erc-7786-gateway-binding)) but
  ERC-7786 defines no quote, so it fails P9 and the whole quote surface goes dead for that
  binding. Prefer a native SDK where a provider offers both.

- ~~**RESEARCH: a requestId, or any unique identifier, for messages.**~~ RESEARCHED, and the
  answer is no protocol-level id. The two halves of the question have different answers.

  **Correlation never needed one, and that argument stands.** The receiver report's slot is
  `receiverSlot(chainKey, owner, salt)`, the chainKey comes from `_authenticateOrigin`, the
  pair is stated, and the slot is write-once. An id would restate what the fields imply.

  **Idempotency does need one, and the transport already has it.** Bootstrap and the report
  are structurally single-shot, but an execute-on-arrival payload carries no commitment and
  no id, so a duplicated delivery runs it twice. Checked against deployed source: LayerZero
  keys `inboundPayloadHash` by `[receiver][srcEid][sender][nonce]` and clears it before
  calling; Hyperlane keeps `deliveries[messageId]` and refuses a repeat; CCIP makes
  `SUCCESS` terminal in `s_executionStates`; Axelar consumes the `commandId` inside
  `validateContractCall`. All four write the mark FIRST and then make a plain external call,
  so a revert rolls the mark back: exactly-once on success and retryable on failure out of
  one mechanism.

  **Wormhole's core layer does not dedupe at all**, by its own documentation, so a Wormhole
  binding must carry replay protection itself, keyed on the VAA digest or
  `(emitterChain, emitterAddress, sequence)`.

  So the requirement is recorded rather than built: a provider prerequisite (P7), three
  rules on the inbound path (R3.5 through R3.7), and three compliance tests (C29 through
  C31) in [`provider-spec.md`](provider-spec.md#12-appendix-transport-replay-guarantees),
  which carries the full matrix. Adding a protocol-level id would put a field on every
  channel and a growing set on every receiver to buy what four of five transports give free.

  **The one thing to keep in view**: a binding must never wrap the delivery call in
  `try/catch`. That consumes the message and drops the payload, turning a retry into a loss,
  and it looks like defensive coding.
- **Who authenticates the receiver's inbound message.** Half-settled. `ReceiverBase`
  now carries its own gate: `receiveMessage` checks `_isAuthorizedGateway(msg.sender)` and
  that the ERC-7930 sender's address is `address(this)`, so an account is not relying on the
  transport to keep another account's payload out of its receiver. What remains open is the
  TRANSCEIVER path, where a provider's own peer check runs before any of our code and
  contradicts the rule stated on `TransceiverBase._onInbound`. For a 1:1 pairing there is
  nothing extra to verify, so accepting it is defensible, but it should be a written
  exception in the binding's NatSpec (provider-spec R3.3) rather than an omission.

## 5. Smaller open questions

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
- ~~**Refund plumbing.**~~ SETTLED, and it needed no parameter. `OutboundBase._refundTo()`
  is `msg.sender`, which is already the right answer on both paths: `sendMessage` is owner-gated
  so it is the owner, and `bootstrap` refuses any caller that is not the account so it is
  the account. The shared transceiver cannot be its own refund target because it is never
  the caller of its own `bootstrap`. `TransmitterBase` gained a `receive` to accept one.
- **No storage gaps anywhere.** The transceiver is UUPS until `lockUpgrades()`.
- **`renounceOwnership` bricks a transmitter.** Recorded rather than prevented; disabling it
  is a separate decision.
- **Tron CREATE2 against a Shasta deployment**, to resolve the 0x41-vs-0xff docs
  contradiction. A one-afternoon empirical check that de-risks a whole chain family. Now
  load-bearing rather than merely tidy: `TronSpokeTransceiver` commits to `0x41` through
  `AddressDerive.tronCreate2`, so this check is what decides whether that spoke works. It
  fails closed if wrong (`AccountAddressMismatch` on every account creation), so the cost of
  being wrong is a redeploy rather than a loss. See §3.
- **The home chain is now a deployment parameter**, not Ethereum. `SpokeTransceiverBase`
  takes its home chainKey, the provider's route to it, and the hub's address as
  write-once initializer arguments. Two things follow that are worth deciding rather than
  inheriting: the hub must be an EVM chain with the EIP-152 precompile, since the registry
  recomputes addresses and commitments locally, and every spoke in one deployment must be
  given the SAME home: nothing on-chain cross-checks that, because a spoke has no view of
  its siblings. A deploy script is the natural place to enforce it, and there is no
  `script/` yet.
- **Merkle-verified calls** as an opt-in policy, replacing the `(target, selector)`
  predicate. `isAllowed` defaults open, so this is an owner's restriction rather than a
  safety baseline.

## 6. Infrastructure: None of it exists

- **`lib/` is vendored rather than submoduled**: forge-std 1.16.2, OZ 5.6.1,
  OZ-upgradeable 5.6.1. Committed deliberately: CREATE2 parity depends on byte-identical
  initcode, so the exact dependency bytes are load-bearing. Costs 37MB per clone.

  **A dependency bump moves every account address**, which is why this one happened before
  `script/` exists rather than after. `CrossProxy`'s initcode hash went
  `0xf2d41a...` (5.1.0) to `0xc3e962...` (5.6.1). Free today because nothing is deployed;
  after a deployment it is not a bump, it is a migration of every account on every chain.

- **The `paris` pin and OpenZeppelin are on a collision course.** Taking 5.6.1 already
  required forking `EnumerableSet` into `registry/Bytes32Set.sol`, because it now imports
  `Arrays`, which uses `mcopy`, which needs Cancun. The pin exists because PUSH0 is absent
  on zkSync, Tron, and several L2s, and identical initcode everywhere is the whole CREATE2
  story, so the pin won.

  It will recur, and next time larger: OZ has DEPRECATED the storage-based `ReentrancyGuard`
  and says it will be replaced by `ReentrancyGuardTransient` in v6.0, which needs TSTORE and
  therefore Cancun as well. The question to settle before then is which chains the pin is
  actually buying, since zkSync and Tron are ALREADY excluded from address derivation by
  their provenance caps: their CREATE2 formulas differ, so parity never held for them. If
  the pin is only protecting chains that the registry already declines to derive, it is
  costing more than it buys.
- **No `script/`.** The Assumptions section specifies an elaborate deploy story (Arachnid's
  factory, proxy with deployer-as-owner, immediate upgrade, ProxyAdmin under the msig), with
  no code behind it. The CREATE2 parity argument stands or falls on that initcode being
  byte-identical, and nothing pins it.
- **No CI.** No `.github/`.
- **No `test/vectors/`.** [`encoding.md`](encoding.md) specifies the corpus and the
  "assert fields, not bytes" rule. Foundry can verify the commitment half for every VM with
  no non-EVM tooling: cheap, and the only defence on the execute-on-arrival path where
  there is no commitment at all. **Now load-bearing for the scheme plugins**: an
  `ICommitmentScheme` is only as good as the evidence that its primitive matches what the
  destination's own receiver applies, and a wrong one wedges that receiver's FIFO queue
  until a `cancel` crosses. The corpus is what turns "we believe this is Blake2b" into a
  check.
