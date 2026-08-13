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
| `GATEWAY_ROLE` | granted to `address(endpoint)` in the account's initializer, or to whatever routes `lzReceive` into `receiveMessage` |
| `_onMessage(bytes payload)` | reached through `receiveMessage`, which `_lzReceive` calls |
| `_onInbound(route, sender, message)` | called from `_lzReceive` on a transceiver, with `route` the stored chain identifier for `origin.srcEid` and `sender` narrowed per R4.2 |
| `_accountInitializer(owner, salt, calls)` | must build `__OApp_init(delegate)` **and** the peer, since the account locks in the same call |
| the owner / `_checkOwner` | `TransceiverBase` is `OwnableUpgradeable`, and OApp brings OpenZeppelin's own, so the two are ONE owner rather than two authorities. A binding must not add a third |
| `TREASURY_ROLE` / `GATEWAY_ROLE` | named in the `Deployment` struct at initialization, ungrantable afterwards; the endpoint goes in `gateways` |

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
  the open question in §4 below, now concrete: it contradicts the rule stated for the
  transceiver, and for a 1:1 pairing there is nothing extra to verify, so accepting it is
  defensible, but it should be a **written exception** rather than an omission.

## 3. Blockers on specific paths

- **Funding a diverging spoke, and getting the money there.** The report fires from inside
  the destination's inbound callback, where `msg.value` is zero, so it is paid from the
  spoke's own balance and a dry one reverts the bootstrap with it. That revert is deliberate
  and keeps the operation retryable.

  **The fee half is built.** `HubTransceiverBase.bootstrapFee` is a per-chainKey surcharge
  the msig sets, taken off `msg.value` at bootstrap and accrued in `collectedFees` for
  `withdrawFees`, whose destination must itself hold `TREASURY_ROLE`. It is zero by default, so
  only the chains that actually report are
  charged, and it is in `quoteBootstrap`, because a quote that omitted it would be worse
  than none: the caller would fund the send exactly and the bootstrap would revert with the
  signers already committed.

  **What is not built is the crossing.** The fee accrues on the home chain in the home
  currency and the spoke needs the destination's, so the msig withdraws and funds spokes out
  of band. Making that automatic means the bootstrap message drops value across, which is a
  provider capability question rather than a contract one.

  **And the report's refund target is unresolved.** `_refundTo()` is `msg.sender`, which on
  a nested send is whoever delivered the message, so a provider refunding an overpaid report
  pays the relayer out of the spoke's balance. Nobody is stolen from, but the spoke drains
  at a rate nothing here bounds. A spoke wanting to pass its whole balance to the send, as
  `_reportReceiver` now does, needs an answer to this first.
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

- **~~A TRANSCEIVER'S GATEWAY SET IS ADMIN-MUTABLE~~. SETTLED: it is not, any more.** The
  question was whether the msig could add a transport to a live transceiver, since a transport
  that can deliver can forge, which is the same power the upgrade lock exists to deny. It
  cannot: `grantRole` is `onlyInitializing`, so membership arrives while a contract is being
  armed and never afterwards. A transceiver's gateways are named in its `Deployment` and
  cannot be added to OR revoked; only a receiver may drop one, through `revokeGateway`, gated
  on its source transmitter.

  What that costs is the operability the looser version bought: a provider migrating its
  endpoint now forces a redeploy at a new address, which re-derives every account, unless the
  deployment named both endpoints up front. Naming several is exactly why `gateways` is an
  array. The remaining question is a deployment-time one — how many endpoints to name — rather
  than a protocol one.
- **The owner is a live authority, and the roles bound it.** Configuration moved to `Ownable`
  when `ADMIN_ROLE` was retired, so a compromised owner can still repoint nothing that is
  write-once, add no transport, and pay no address that does not already hold `TREASURY_ROLE`.
  What it CAN do is set a route or a counterpart on a chain that has none yet, and set the
  bootstrap fee. Worth confirming that list is the intended blast radius before mainnet.
- **Ordered execution blocks the queue.** Strict FIFO means a permanently-failing payload
  stalls everything behind it until `cancel`. Ordering and cancellation are load-bearing for
  each other; neither should be removed alone.
- **A blank `CrossProxy` delegates to `address(0)` and succeeds silently.** Only safe
  because deploy, arm, and lock are one function. It becomes a real hole if those are ever
  split.
- **Self-replaying payloads.** `finalize` clears an approval before executing, so a payload
  containing a self-call to `commit` with its own hash re-arms itself indefinitely.
  Owner-approved either way, so not an escalation, but "approvals are single-use" stops
  being true. Disallowing it costs plumbing; allowing it is strictly cheaper.
- **Whether to replace `src/addressing/Erc7930.sol` with OpenZeppelin's
  `draft-InteroperableAddress`.** OZ 5.5.0 brought it, 235 lines against our 248, audited and
  maintained, covering the same ground with `formatEvmV1`, `parseEvmV1`, and `try` and
  calldata variants. **It is out of reach at the pinned version**, which predates it, so
  adopting it means moving the dependency first. That is the trade to weigh, not the line
  count.
  Blocked on two checks: it is a `draft-`, which OZ excludes from API stability and may
  change in a MINOR release, and this codebase freezes accounts against exact bytes; and our
  `parseStrict` enforces strictness the registry depends on (non-minimal `eip155` references
  and trailing bytes both rejected) that `parseV1` may not match. Neither is a reason not to
  do it; both are reasons it is its own task with its own vectors. See
  [`provider-research.md`](provider-research.md#3-erc-7786-as-a-transport).

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

- **`lib/` is vendored rather than submoduled**: forge-std 1.16.2, OZ 5.4.0,
  OZ-upgradeable 5.4.0. Committed deliberately: CREATE2 parity depends on byte-identical
  initcode, so the exact dependency bytes are load-bearing. Costs 37MB per clone.

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
  destination's own receiver applies, and a wrong one wedges that receiver's FIFO queue
  until a `cancel` crosses. The corpus is what turns "we believe this is Blake2b" into a
  check.
