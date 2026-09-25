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
| Which gateway may deliver to a receiver | `GATEWAY_ROLE`, granted in the binding's initializer | `LzReceiver` grants nobody, so a receiver accepts nothing |
| The transceiver's inbound callback | the binding's own, feeding `TransceiverBase._onInbound` | does not exist; `_onInbound` has no caller |
| Provider setup in `_accountInitializer` | `Hub`/`SpokeTransceiverBase` | `virtual` throughout, and no binding fills it |
| `supportsAttribute` | `TransmitterBase` | returns false for everything |

The spoke → hub report is not on this list. `SpokeTransceiverBase` sends it from
`bootstrapInbound`, gated on a write-once `addressesDiverge` flag, so it fires only where
the hub cannot derive the address itself. What it needs is funding a diverging spoke, below.

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
or the approval map however our layout changes, which also removes the storage-gap
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
| `GATEWAY_ROLE` | granted to `address(endpoint)` in the account's initializer, or to whatever routes `lzReceive` into `receiveMessage` |
| `_onMessage(bytes payload)` | reached through `receiveMessage`, which `_lzReceive` calls |
| `_onInbound(route, sender, message)` | called from `_lzReceive` on a transceiver, with `route` the stored chain identifier for `origin.srcEid` and `sender` narrowed per R4.2 |
| `_accountInitializer(owner, salt, calls)` | must build `__OApp_init(delegate)` **and** the peer, since the account locks in the same call |
| the owner / `_checkOwner` | `TransceiverBase` is `OwnableUpgradeable`, and OApp brings OpenZeppelin's own, so the two are ONE owner rather than two authorities. A binding must not add a third |
| `GATEWAY_ROLE` | named at initialization, ungrantable afterwards; the endpoint goes in the `gateways` array |

**A native binding reintroduces a codec, and the eid table with it.** ERC-7786 removed the
protocol's need for a provider id, not LayerZero's: `_lzSend` still takes a `uint32`. So a
native LayerZero binding keeps its own chainKey→eid mapping under R5, where a gateway
binding keeps none.

**The peer value is `counterpartOn(chainKey)`, not `address(this)`.** The two agree wherever
Ethereum's CREATE2 formula holds, which made the shortcut tempting; they differ on zkSync and
Tron, where deriving the peer names an address holding no receiver. One entry per
destination, read from the table rather than computed.

### Two consequences to decide on

- **`__OAppCore_init` calls `endpoint.setDelegate(_delegate)`, and the delegate is
  `address(this)`.** Settled: inside `upgradeInitializeAndLock`'s delegatecall that is the
  ACCOUNT, so each account is its own delegate and no other party can reconfigure it. The
  cost is that every account creation touches the endpoint, which is real gas on the
  bootstrap path and the concrete form of "peers and any send-side security configuration
  are per-user rather than shared". Recorded as R6.4 in the spec, which generalises it: any
  provider-side authority over an account is the account.
- **OApp authenticates inbound before our code runs.** `lzReceive` does
  `if (address(endpoint) != msg.sender) revert OnlyEndpoint(...)` then
  `if (_getPeerOrRevert(_origin.srcEid) != _origin.sender) revert OnlyPeer(...)`. That is
  the open question in §4 below, now concrete. It contradicts the rule stated for the
  transceiver. For a 1:1 pairing there is nothing extra to verify, so accepting it is
  defensible, but it should be a **written exception** rather than an omission.

## 3. Blockers on specific paths

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

## 4. Decisions taken that deserve a second look

None of these are bugs. Each is a deliberate choice with a cost worth confirming before
mainnet.

- **How many gateway endpoints a deployment should name.** `grantRole` is
  `onlyInitializing`, so a transceiver's gateways are fixed in its `Deployment` and cannot be
  added to later. A provider migrating its endpoint therefore forces a redeploy at a new
  address, which re-derives every account, unless the deployment named both endpoints up
  front. Naming several is why `gateways` is an array.

  **CONFIRMED.** A LayerZero endpoint, or any other provider's gateway, is never appended
  post-deploy; a migration is a redeploy, full stop. So `grantRole` staying `onlyInitializing`
  is the intended shape, not a gap to design around. This is still a deployment-time
  decision (how many endpoints to name in `Deployment` up front, e.g. to pre-empt a known
  future migration), which needs `script/` to actually make, not a contract change.
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

  **Which provider to bind is still open, and the 7786 answer is "only if it has to be".**
  A gateway binding is thin (see the skeleton in
  [`provider-spec.md`](provider-spec.md#9-worked-skeleton-an-erc-7786-gateway-binding)) but
  ERC-7786 defines no quote, so it fails P9 and the whole quote surface goes dead for that
  binding. Prefer a native SDK where a provider offers both.

- **Who authenticates the receiver's inbound message.** Half-settled. `ReceiverBase`
  now carries its own gate: `receiveMessage` is `onlyRole(GATEWAY_ROLE)` and checks that the
  ERC-7930 sender's address is its `sourceTransmitter`, so an account is not relying on the
  transport to keep another account's payload out of its receiver. What remains open is the
  TRANSCEIVER path, where a provider's own peer check runs before any of our code and
  contradicts the rule stated on `TransceiverBase._onInbound`. For a 1:1 pairing there is
  nothing extra to verify, so accepting it is defensible, but it should be a written
  exception in the binding's NatSpec (provider-spec R3.3) rather than an omission.

  **CONFIRMED FOR LAYERZERO** (PR #6). `LzReceiver`/`LzHubTransceiver`/`LzSpokeTransceiver`
  take the R3.3 exception: `lzReceive`'s `OnlyPeer`/`OnlyEndpoint` checks run inside the
  vendored OApp SDK, before `_lzReceive` — and so before `_onMessage`/`_onInbound` — ever
  runs. Written into NatSpec and confirmed by test (a wrong sender is rejected by
  LayerZero's own peer check; our code never sees it). **Operational consequence for
  Phase 7**: LayerZero is the one binding where "what actually authenticates a delivery"
  requires reviewing vendored, third-party files (`OAppCoreUpgradeable`/
  `OAppReceiverUpgradeable`) alongside this repo's own — an auditor reviewing only
  `src/protocols/layerzero/` would miss where the check actually lives. CCIP/Hyperlane/
  Wormhole/OP Stack are expected to check `GATEWAY_ROLE` in code this repo owns directly
  instead (see Phases 3–6), so this asymmetry is specific to LayerZero and worth a README
  line once Phase 7 runs.

  **CONFIRMED FOR CCIP** (Phase 3 PR). No exception needed, and no vendored SDK in the
  loop at all: `CcipReceiver`/`CcipHubTransceiver`/`CcipSpokeTransceiver` implement
  `IAny2EVMMessageReceiver.ccipReceive` directly rather than inheriting Chainlink's
  `CCIPReceiver`, and CCIP's off-ramp asserts nothing about the source-chain sender —
  `isSourceTransmitter`/`_authenticateOrigin` is the only check, matching `_onInbound`'s
  rule exactly. **Operational consequence**: the CCIP receiver binding tracks no
  per-origin state at all (no eid/domain/selector table the way LayerZero's peer or
  Hyperlane's enrolled router would be), so it has exactly one rejection path for every
  non-source-transmitter sender, regardless of claimed origin chain — simpler than
  LayerZero's binding, not a gap (`test/protocols/ccip/CcipBinding.t.sol` documents this
  directly on the hook that would otherwise test a distinct "unconfigured origin" case).

  Confirmed for Hyperlane (Phase 4 PR): no exception needed. `HyperlaneReceiver`/
  `HyperlaneHubTransceiver`/`HyperlaneSpokeTransceiver` implement
  `IMessageRecipient.handle` directly (no `MailboxClient`/`Router`), and `Mailbox.process`
  verifies the ISM, not the source-chain sender. The spokes additionally check
  `origin == homeDomain`, so a contract at the hub's address on some other domain is not
  taken for the hub; the hub maps `origin` through its domain table. The receiver, like
  `CcipReceiver`, checks the sender address only. `CcipSpokeTransceiver` does not compare
  `sourceChainSelector` to `homeSelector` the way the Hyperlane spoke compares domains;
  worth deciding for Phase 7 whether it should.

- **A LayerZero receiver/spoke's peer is fixed for life, with no setter at all.** Found
  wiring PR #6: OApp's `setPeer` is `onlyOwner`, but `LzReceiver`, `LzSpokeTransceiver`, and
  their zkSync/Tron variants have no `Ownable` — calling `setPeer` from their own
  initializer would have reverted unconditionally (`OwnableUnauthorizedAccount`) on every
  deployment. Fixed by writing OApp's peer storage directly inside the one-shot
  initializer, which closes the bug but also means these four contracts have no owner-facing
  entry point to repoint that peer afterward, ever. Same "no recovery path but a redeploy"
  property `_setRoute`/`_setCounterpart` already accept elsewhere in the protocol — but
  here it fell out of the fix rather than being a chosen constraint, so it is worth
  confirming that is the intended shape (rather than, say, an owner-gated repoint being
  wanted on the account side specifically) before mainnet, and worth a README line either
  way: a LayerZero destination or home-hub address named at deploy time cannot be corrected
  without redeploying the account.

- **Vendored provider SDKs have no update mechanism.** Hand-copying LayerZero's OApp
  contracts (Phase 1's choice, PR #6) keeps every byte reviewable and needs no dedicated
  package repo, but there is no `forge update`/`npm update` path if LayerZero ships a
  security patch to `OAppCoreUpgradeable`/`OAppReceiverUpgradeable`: someone has to notice
  it upstream, diff it, and manually re-vendor. Applies to whichever of CCIP's/Hyperlane's
  files end up hand-copied too (Phase 1, still undecided). Worth an operational README note
  once Phase 7 runs, naming which files are vendored and that they are not on any update
  path.

- **A vendored provider SDK's own fee-payment primitive can silently assume `msg.value ==
  the fee`, which this protocol's nested-send contract violates by design.** Found by
  Copilot review on PR #6, after the PR's own tests already passed: `OAppSenderUpgradeable
  ._payNative` (vendored, unmodified) reverts `NotEnoughNative` unless `msg.value` exactly
  equals the fee passed to `_lzSend`. `OutboundBase` documents the opposite contract for
  every binding's `_sendMessage` — told what it may spend via `value`, must not read
  `msg.value` — and two real call sites rely on it: `HubTransceiverBase._bootstrapSendValue`
  returns `msg.value - fee` once a bootstrap fee is configured, and
  `SpokeTransceiverBase._reportReceiver` sends nested inside the `lzReceive` delivery
  callback where `msg.value` is 0, spending from the contract's own pre-funded balance.
  Without overriding `_payNative`, every bootstrap with a nonzero fee reverted, and every
  zkSync/Tron account bootstrap reverted unconditionally (the report is not optional once
  `addressesDiverge` is true) — `LzHubTransceiver`/`LzZkSyncSpokeTransceiver`/
  `LzTronSpokeTransceiver` now override it to trust `value` and let `endpoint.send` revert
  on insufficient balance instead. **Operational consequence for Phase 7**: this class of
  bug — a vendored SDK's payment primitive silently re-deriving "how much to spend" from
  `msg.value` instead of accepting the protocol's own pre-computed amount — is worth
  checking explicitly for CCIP (`feeToken`/`msg.value` handling in `ccipSend`), Hyperlane
  (`dispatch`'s payment), and Wormhole (`sendPayloadToEvm`'s), not assumed absent just
  because a binding's own tests pass with a zero-fee mock.

- **CCIP's off-ramp will silently skip `ccipReceive` if `supportsInterface` answers
  wrong.** Found wiring Phase 3: unlike `onlyRouter`, this isn't documented in the
  interfaces this binding vendors — it's in `CCIPReceiver.sol`'s own comment at the
  pinned commit, which this binding does NOT inherit (see the note above), so nothing
  forces a binding to notice it needs `supportsInterface` at all. If a receiving contract
  either lacks `supportsInterface` or answers false for
  `type(IAny2EVMMessageReceiver).interfaceId`, CCIP's off-ramp does not revert: it treats
  the message as accepted, transfers any tokens, and never calls `ccipReceive` at all — a
  message that looks sent and simply never arrives. `CcipReceiver`/`CcipHubTransceiver`/
  `CcipSpokeTransceiver` all override `supportsInterface` to answer true for
  `IAny2EVMMessageReceiver` and `IERC165`, pinned by
  `test/protocols/ccip/CcipBinding.t.sol:CcipInterfaceSupportTest`. Worth a README line:
  any FUTURE change to this binding's inheritance (e.g. adding another interface, or
  refactoring `Roles`) that drops or shadows this override reintroduces a silent,
  untested failure mode rather than a revert.

- **Hyperlane inbound security is whatever the Mailbox's default ISM is.** No Hyperlane
  contract here implements `interchainSecurityModule()`, so `Mailbox.recipientIsm` returns
  `defaultIsm`, which the Mailbox owner can replace at any time (`setDefaultIsm`). This is
  the same class of trust as LayerZero's default DVN config. Pinning a specific ISM would
  need a setter or an initializer argument on every receiving contract; not done here.

- **Hyperlane's refund and gas defaults both assume the dispatcher is the payer.** Found
  wiring Phase 4. The IGP and ProtocolFee hooks refund overpayment to
  `metadata.refundAddress`, which defaults to the contract that called `dispatch`. A hub or
  spoke has no `receive`, so with empty metadata any overpaid send reverts. Every sender
  now passes StandardHookMetadata with `refundAddress = _refundTo()`
  (`HyperlaneMessage.hookMetadata`, pinned by
  `HyperlaneBinding.t.sol:test_overpaymentIsRefundedToTheCallerNotTheHub`). Because the
  refund field sits after `gasLimit` in that encoding, the binding now writes the IGP's
  default gas limit (50,000) explicitly when no attribute is given. That default is
  probably too low for a bootstrap and for `_reportReceiver`, which always sends with no
  attributes. Needs a measured per-path default before mainnet.

- **Wormhole binding, Phase 5 PR: Core + Executor, not the Standard Relayer.** Wormhole has
  deprecated the Standard Relayer (docs warning, migration guide `executor-vs-sr.md`; source
  removed in wormhole-foundation/wormhole#4644), so the binding publishes through Core and
  requests delivery through `ExecutorQuoterRouter`. What that moves onto this binding:
  - Inbound is permissionless. `executeVAAv1` verifies the VAA through Core's
    `parseAndVerifyVM`; guardian signatures authenticate the emitter. `GATEWAY_ROLE` is held
    by the Core bridge address and checked by membership rather than `msg.sender`, so
    `revokeGateway(coreBridge)` still disconnects Wormhole from an account.
  - Replay protection is the binding's own (R3.5): a consumed-VAA-hash set in an ERC-7201
    slot in `WormholeMessage`.
  - A VAA carries no destination. Receivers share one address across parity chains and
    trust the same transmitter, so the published payload is prefixed with
    `(targetChain, targetAddress)` and both are checked on arrival. Without it, one VAA would
    execute on every parity chain's receiver.
  - The quoter (relay provider) is an implementation-level immutable. Delivery liveness does
    not depend on it: anyone can submit a VAA to `executeVAAv1`.
  - The Executor requires a gas limit; the binding uses 200,000 when no attribute is given.
    Not measured against bootstrap or `_reportReceiver`.
  - Core requires its message fee exactly; the binding pays that and sends the rest to the
    router, which refunds its own overpayment to `_refundTo()`.

- **OP Stack binding, Phase 6 PR.** Inbound sender is `xDomainMessageSender()` read from the
  messenger during the relay, never anything in the delivered calldata (which the
  origin-side `sendMessage` caller writes in full); pinned by
  `OpStackBinding.t.sol:test_aSenderClaimedInsideTheMessageIsIgnored`. No R3.3 exception.
  Three decisions worth a second look:
  - The quote is zero, not `QuoteNotImplemented` as `provider-research.md` §7 and PR #5's
    plan assumed. L1->L2 deposits pay by burning gas in the sending transaction
    (`ResourceMetering`), L2->L1 pays nothing at the source, and `sendMessage`'s `msg.value`
    is bridged to the target rather than spent. So `value` must be zero (the binding
    reverts otherwise), and zero is the exact native cost, which is also what R2.2.2's
    balance-delta measurement would return. The real cost is the caller's own gas.
  - The destination is which messenger is called, so the hub and every transmitter it
    creates refuse any recipient not on `messengerChainKey`. Without that, a route to another
    chain would be delivered to the same address on this messenger's chain.
  - `minGasLimit` defaults to 200,000 when no attribute is given. Underestimating is
    recoverable (the messenger records a failed relay and anyone can replay it with more
    gas), but it is not measured against bootstrap.

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
  being wrong is a redeploy rather than a loss. See §3.
- **The home chain is a deployment parameter**, not Ethereum. `SpokeTransceiverBase`
  takes its home chainKey, the provider's route to it, and the hub's address as
  write-once initializer arguments. Two things follow, and both are worth deciding rather
  than inheriting. The hub must be an EVM chain with the EIP-152 precompile, since the
  registry recomputes addresses and commitments locally. And every spoke in one deployment
  must be given the SAME home: nothing on-chain cross-checks that, because a spoke has no
  view of its siblings. A deploy script is the natural place to enforce it, and there is no
  `script/` yet.
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
  direction. CCIP's own NatSpec says an overpayment is accepted with no refund, so padding
  the quote for safety just burns the difference. Hyperlane's `Mailbox.dispatch` sends
  `requiredHook` what it asks and forwards the rest of `msg.value` to the post-dispatch
  hook; the IGP and ProtocolFee hooks refund their overpayment to `metadata.refundAddress`
  (which the binding sets to `_refundTo()`, see §4), but any other hook the Mailbox owner
  configures may keep it. No single on-chain buffer is safe across all three; at least one
  of them turns "add a margin" into a standing cost.

  the quote for safety just burns the difference. Wormhole's Executor quoter router refunds overpayment
  to the refund address, like Hyperlane's IGP. Hyperlane's `Mailbox.dispatch` neither
  reverts nor refunds: it sends `requiredHook` what it asks and forwards WHATEVER IS LEFT of
  `msg.value` to the post-dispatch hook, which does not return to the sender either. No
  single on-chain buffer is safe across all three; two of them turn "add a margin" into a
  standing cost.

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

  **Pre-production, not pre-PR.** This needs the three bindings to exist and their real fee
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

## 6. Infrastructure: None of it exists

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
  destination's own receiver applies, and a wrong one leaves an approval that can never be
  discharged. The corpus is what turns "we believe this is Blake2b" into a
  check.
