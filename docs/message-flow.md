# Message flow

The two paths a message takes, the wire formats, and what each contract does.

**Status.** Both paths are built end to end in-process:
`_sendMessage(bytes32, bytes, bytes)`, `send` / `sendTo` / `bootstrap`, the quote surface,
the inbound funnel, and the reentrancy guard. What is missing is a **message provider
binding**: `_sendMessage` reverts `SendNotImplemented` and `_quoteMessage` reverts
`QuoteNotImplemented` by default, so nothing crosses a real bridge yet. What a binding must
implement is specified in [`provider-spec.md`](provider-spec.md). The README's `TransceiverBase` /
`TransmitterBase` sections describe the same design; where they disagree with this file,
this file is the newer statement.

## Three properties the whole design turns on

**The home chain is a parameter.** Ethereum is the expected anchor, and a spoke names its
home (chainKey, provider route, and counterpart) once at initialization with no setters.
Everything below reads "hub" and "spoke" rather than "Ethereum" and "elsewhere" for that
reason.

1. **A transmitter is its own message-provider endpoint.** It sends to its receiver
   directly, so the transceiver is not in the path of a normal message.
2. **The wire carries a payload, not a commitment.** A message is a call array, executed
   on arrival.
3. **Committing is a call, not a message kind.** A transmitter that wants the
   queue-and-wait behaviour sends a payload whose single element calls the receiver's own
   `commit`. There is no message-type tag anywhere.

The transceiver has exactly two jobs: standing up a receiver on a chain that has none, and
reporting back where it landed.

## The two paths

### A. Normal send: transmitter to its own receiver

```
owner
 │  transmitter.send{value: fee}(8453, calls)                          onlyOwner
 │    chainKey = ChainKey.forEvm(8453)                                 pure
 │    _sendMessage(chainKey, abi.encode(calls), providerData)
 ▼
 ══════════════════ bridge ══════════════════
 │
 ▼  receiver.<provider callback>(origin, payload)
      origin.sender == peer                                            1:1, see below
      _onMessage(payload):
        calls = Payload.decodeCalls(payload)                           abi.decode(_, (Call[]))
        _execute(calls)                                                nonReentrant
```

The peer relationship is exactly 1:1 (one transmitter, one receiver, one chain pair),
which is the shape every provider's peer table already has. This is the reason the
transmitter can be its own endpoint at all; a shared transceiver fanning in from N
transmitters would not fit.

**Deferred execution is the same path.** To pin a hash now and run the array later, send a
payload whose one element targets the receiver itself:

```solidity
calls[0] = Call({
    target: address(receiver),
    value:  0,
    data:   abi.encodeCall(ICommitFinalize.commit, (hash))
});
```

It arrives, executes, and stores the hash. Anyone supplies the matching array to
`finalize` afterwards. Nothing on the wire distinguishes this from any other payload, and
nothing needs to.

### B. Bootstrap: no receiver on the destination yet

There is no peer to send to, so the message goes to the one contract that already exists
on that chain.

```
owner
 │  transmitter.bootstrap{value: fee}(chainId, calls)                  onlyOwner
 ▼
hub transceiver .bootstrap(chainKey, owner, salt, calls, providerData) msg.sender must BE the account
 │    _requireRoutable(chainKey)                                       ← provenance bar applies here
 │    _sendMessage(chainKey, Envelope.encodeBootstrap(owner, salt, calls), providerData)
 ▼
 ══════════════════ bridge ══════════════════
 │
 ▼  spoke transceiver ._onInbound(route, sender, message)
      _authenticateOrigin  → must be the hub
      _handleInbound → bootstrapInbound(owner, salt, calls):
        deploy CrossProxy at accountSalt(owner, salt)                  CREATE2, no args
        upgradeInitializeAndLock(receiverImpl, initialize(peer, calls))
              installs logic, executes the calls, drops the upgrade key (one call)
        if (addressesDiverge) _reportReceiver(owner, salt, receiver)
 ▼
 ══════════════════ bridge ══════════════════          ← only where the flag is set
 │
 ▼  hub transceiver ._handleInbound  → onDestinationReceiver → registry
```

**The message carries the OWNER AND THEIR SALT, not the transmitter.** The account address
derives from the pair, which is what puts an owner's transmitter and their receivers on one address. The
transmitter's own address could not serve: a CREATE2 address cannot be derived from itself.
The receiver's peer is therefore its own address, since that is where the transmitter sits
on the home chain.

**The return leg is sent by the spoke transceiver, and only where it buys something.** The
receiver cannot be its sender: it is not an `OutboundBase`, has no `_sendMessage`, and holds
neither the home route nor the hub's address. The spoke transceiver holds all four things
the report needs at once, which is the home route, the hub's address, the authenticated
`(owner, salt)` pair, and the address of the receiver it has just created.

**`addressesDiverge` decides whether it fires.** On a chain sharing Ethereum's CREATE2
formula the hub computed the receiver's address before the first message ever left, so a
report would spend a message to restate a derivation it already holds, and would replace a
`Derived` fact with an `Attested` one. The flag is written once at initialization because
the hub cannot work this out for itself: it recomputes Ethereum's formula, which is right on
most EVM chains and wrong on zkSync and Tron, and only the chain itself knows which it is.

**A failed report takes the account creation with it.** The send is nested inside the
delivery callback, where `msg.value` is zero, so a diverging spoke pays from its own balance
and a dry one reverts. That is the correct shape rather than something to catch: creating
the account anyway would leave the hub permanently unable to address it, since `CrossProxy`
arms exactly once and `initialize` is single-shot, so there is no second bootstrap to carry
a second report. All or nothing keeps the operation retryable once the spoke is funded.

On an EVM destination nothing persists past the transaction: deploy, arm, execute, and lock
all happen in the inbound handler. Chains where deployment is not synchronous (Starknet,
the Move chains) need somewhere to hold the payload in between, which is a per-VM concern
rather than a shared one.

After this, every subsequent message takes path A and the transceiver is not involved
again. Nothing has to be pointed anywhere: the transmitter's peer is its own address, which
is where its receiver sits on every chain, so it is derived rather than configured.

## Wire formats

Each channel carries exactly one shape, so direction remains the discriminant and no
channel needs a tag.

| Channel | Payload |
| --- | --- |
| transmitter → receiver | `abi.encode(Call[] calls)` on EVM, `abi.encode(bytes[] elements)` elsewhere |
| hub → spoke transceiver | `abi.encode(address owner, bytes32 salt, Call[] calls)` on EVM, `abi.encode(address owner, bytes32 salt, bytes[] elements)` elsewhere |
| spoke → hub transceiver | `abi.encode(address owner, bytes32 salt, bytes interop)` |

**The bootstrap message names the OWNER AND SALT, not the transmitter.** The destination
derives the account's address from that pair, which is what puts an owner's transmitter and
their receivers on one address; the transmitter's own address could not serve, because a
CREATE2 address cannot be derived from itself. Nothing the bridge reports says who on the
home chain authorized the message, since the hub is shared by every owner, so the pair is
stated. The report back names the same pair for the same reason, which is what lets the hub
key the receiver slot without a request id.

A call is `(address target, uint256 value, bytes data)`: the tuple ERC-7579 and ERC-7821
use, so payload-building tooling that already speaks those formats works without custom
code. Which form a destination receives follows from its chain type; see
[`encoding.md`](encoding.md).

A bare commit costs 320 bytes encoded this way, against 32 for the hash it carries. That
is ABI padding and offsets, not information. It amortizes across payloads with real
calldata in them, and it is not worth packed encoding to avoid.

**Non-EVM destinations keep their own call format.** The container is uniform; the
elements are whatever that VM means by a call: a Solana instruction with its account
list, a Starknet `(to, selector, calldata)`, an Aptos entry function. Only the receiver on
that chain decodes them, and `hashCalls` folds in the destination chainKey, so the format
is already namespaced per destination. Value is an EVM-ism and does not survive the trip;
every other VM moves native currency as an explicit asset.

## By contract

One subsection per contract in the tree, in the order a message meets them. Signatures are
the real ones; where a base declares something without implementing it, that is said.

### Executor

The shared execution loop, inherited by `TransmitterBase` and `ReceiverBase` alike.

- `_execute(Call[] calls)`: runs them in order, all or nothing. The target and the value sit
  inside each element, so an approval covers who is called and how much they receive, and a
  payload cannot be redirected or re-priced at execution time. One failure reverts
  everything, carrying the original reason out in `CallFailed(index, reason)` rather than
  swallowing it.
- The selector it checks is `bytes4(c.data)` only when `data.length >= 4`, and `bytes4(0)`
  otherwise. Under four bytes there is no selector: a bare value transfer, or a hit on the
  target's fallback. Reading one anyway would invent a selector the payload never named,
  and one that could match a policy entry by accident.
- `isAllowed(address, bytes4)` defaults to **true**. These are full-power accounts and the
  `(target, selector)` predicate was never what stood between a forged message and
  execution; failing closed would revert every payload until a protocol overrode it,
  including the bootstrap payload a receiver runs inside its initializer. Merkle-verified
  calls remain the plan, as an opt-in.
- **The two ends share it rather than one calling the other.** At home there is no receiver
  to run a payload in: a transmitter and its receivers share one address, and an address
  holds one contract, so at home that address is the transmitter. A payload authorized by
  the owner locally and a payload authorized by a commitment remotely therefore run through
  the same loop, the same policy check, and the same all-or-nothing rule.

### OutboundBase

The sending half, with no opinion about who is allowed to send, and no storage at all. That
is what makes it free to mix into a contract that already has a layout.

- `_dispatch(bytes32 chainKey, bytes payload, bytes providerData)`: rejects a zero
  destination and an empty payload, emits `Dispatched`, and hands off to `_sendMessage`.
- `_sendMessage(bytes32 chainKey, bytes payload, bytes providerData)`: `internal virtual`,
  reverting `SendNotImplemented` until a protocol binding overrides it. **One primitive for
  every channel.** A payload to an account, a bootstrap to a spoke transceiver, and a
  receiver report back are all `bytes` to a chainKey; three signatures would be three places
  for a binding to get authentication or fee handling subtly different.
- `_quote(...)` / `_quoteMessage(...)`: the same three arguments, `view`, reverting
  `QuoteNotImplemented` by default. `_quote` applies the same validation as `_dispatch`
  minus the event, so a quote cannot succeed for a message the send would refuse. Nothing on
  the send path consults it: the quote is advisory, and a price that moved in between is the
  provider's refund to make rather than a revert.
- `_refundTo()`: `msg.sender`. A fee is overpaid by whoever paid it. On path A that is the
  owner, because `send` is owner-gated; on path B it is the account, because `bootstrap`
  refuses any caller that is not `predictCrossAccount(owner, salt)`. The shared transceiver
  is structurally incapable of being its own refund target, since it is never the caller of
  its own `bootstrap`.
- `providerData` is opaque here and per send, not configuration: destination gas is a
  property of the payload, so a stored default would strand the first message that needed
  more. Empty means "the binding's default".
- `Dispatched(destinationChainKey, payloadHash)` carries the hash rather than the payload:
  the bytes are already in the transaction's calldata.

### TransmitterBase

`OutboundBase` + `Executor` + `Initializable`. The per-user account on the home chain. Its
storage is `transceiver` and `accountSalt`, and nothing else.

- **The destination is a parameter, not state.** One transmitter fans out to every chain,
  which is also what keeps one receiver per (transmitter, destination).
- `send(uint256 chainId, Call[] calls)` and `send(uint256, Call[], bytes providerData)`:
  path A. The caller names a plain chain id and the chainKey is derived purely, so there is
  no eid to know and no per-provider table to keep.
- `sendTo(bytes chainIdentifier, Call[] calls)` and `sendTo(bytes, bytes[] elements)`, each
  with a `providerData` overload: path A for destinations named by an ERC-7930 identifier.
  The typed form is refused for a non-EVM destination and the opaque form for an EVM one,
  enforced here because this is the last layer holding the envelope: downstream everything
  speaks chainKeys, which are hashes and cannot be asked what chain type they came from.
- `bootstrap(uint256 chainId, Call[] calls)` and `bootstrapTo(...)`, same four shapes: path
  B, forwarded to the transceiver with the whole `msg.value`. They pass `_owner()` and
  `accountSalt` rather than this contract's own address, because a CREATE2 address cannot be
  derived from itself.
- `quoteSend`, `quoteSendTo` (typed and opaque), `quoteBootstrap`, and `quoteBootstrapTo`
  (typed and opaque): `view`, ungated, and each mirrors its sending twin argument for
  argument minus `msg.value`. Every one states its `providerData`, including when empty:
  the options are most of what a quote prices, so a form that let a caller omit them would
  answer for the default and be spent on a message carrying something else. The bootstrap
  quotes delegate to the transceiver, because that is what sends path B.
- `execute(Call[] calls) payable onlyAccountOwner`: local, no bridge and no commitment. It
  takes no destination because it cannot have one.
- `commitmentCall(receiver, commitment)` and `cancellationCall(receiver, index, expected)`:
  `pure` builders for elements carried inside a payload bound for a receiver's chain, so the
  payload a signer reviews is the payload that executes. Cancellation is inherently remote:
  a transmitter holds no queue.
- `commitmentFor(uint256 chainId, Call[])` and `commitmentForChain(bytes identifier,
  Call[])`: `pure`, EVM destinations only. What stays here stays because it cannot go stale:
  every chain that executes `Call[]` hashes with keccak256. Non-EVM destinations are
  previewed through `ChainRegistry.commitmentFor`, where the primitive is a per-chainKey
  plugin.
- `_owner()` and `_checkOwner()` are declared, not implemented, and the modifier is
  `onlyAccountOwner` rather than `onlyOwner`: a provider SDK that brings `Ownable` also
  brings `onlyOwner`, and two base classes declaring one name is the collision the seam
  exists to avoid.
- `receive()`: a refunded fee comes back here on path B, and a provider's refund is a plain
  value transfer, so without it the refund would revert the bootstrap.
- **It holds no registry pointer and knows no routes.** The chainKey derivation is pure, and
  the provider's name for a chain is read from the transceiver at send time, through
  `IAccountTransceiver`: one interface over the single transceiver address an account
  stores, carrying bootstrap, the quotes that price it, and `routeTo`.

### TransceiverBase

`OutboundBase` + `Initializable` + `UUPSUpgradeable`. Authentication, routing, manufacture,
and the upgrade lock: the symmetric half, shared by hub and spoke.

It is deliberately **not** an `Executor` (a transceiver has no payload of its own) and not a
`ReceiverBase` (both commitment rules live where the commitment lives). It inherits no
ownership at all, so a binding can join at the concrete contract without its `Ownable`
colliding with one declared here.

- `CROSS_PROXY_INIT_CODE_HASH`: the one initcode hash every account deploys from, on every
  chain, transmitter and receiver alike. Exposed so the hub can reproduce addresses without
  deploying anything.
- `setRoute(bytes32 chainKey, bytes route)`: `onlyAdmin` and **write-once**, maintaining the
  reverse index in the same call because two setters is how the two directions drift apart.
  Re-writing the same route is a no-op; a different one reverts, and so does a route already
  held by another chain, since two chains sharing one provider id is a forgery primitive.
  Reads are `routeFor`, `chainKeyOfRoute`, `hasRoute`, and the public `routeTo` an account
  calls at send time. The table lives here rather than in the registry because this is the
  contract that sends.
- `accountSalt(owner, salt)` is `keccak256(abi.encode(owner, salt))`, hashed rather than
  concatenated so no pair can collide with another by sliding bytes across the boundary.
  `predictCrossAccount(owner, salt)` gives the address before it exists.
- `_createCrossAccount(owner, salt, calls)`: deploy, arm, and lock in one call. Two virtuals
  decide what is installed: `_accountImplementation` (hub: transmitter, spoke: receiver) and
  `_accountInitializer`. The proxy, the salt, and the deployer address are identical on both
  sides, which is what puts an owner's transmitter and their receivers on one address.
- `bootstrap(chainKey, owner, salt, calls, providerData) payable` and `bootstrapElements`:
  permissionless, because the caller must BE `predictCrossAccount(owner, salt)`, so the only
  account anyone can stand up is the one that already answers to them. **The only caller of
  `_requireRoutable`, and therefore the only place `minCounterpartProvenance` is enforced:**
  a bar on the first message to a chain rather than on every send, since afterwards an
  account's own sends go straight to its receiver and never reach this contract again.
- `quoteBootstrap` / `quoteBootstrapElements`: `view`, applying `_requireRoutable` so the
  provenance bar fails the quote wherever it fails the send, but **not** the caller check. A
  quote is taken before the account it prices exists, so requiring the caller to be that
  account would make it uncallable in exactly the case it is for.
- `_accountInitializer(owner, salt, calls)`: `virtual` all the way down, and **the only
  place provider setup can happen**. The proxy locks in the same call that arms it, and an
  account's own configuration is owner-gated, so a transceiver has no authority over an
  account after creating it.
- `_checkAdmin()` is declared, not implemented, and the modifier is `onlyAdmin`. Two
  ownership systems on one transceiver would mean upgrades "locked" behind one authority
  could still be reconfigured through the other.
- `lockUpgrades()`: irreversible, `onlyAdmin`, and `_authorizeUpgrade` refuses outright once
  set. A transceiver decides which cross-chain payloads are authentic, so a live upgrade key
  is a standing ability to forge one.
- `_onInbound(route, sender, message)`: the one funnel every binding routes an arriving
  message into. **Authentication is not the binding's job**: `_authenticateOrigin` runs here
  before anything is decoded, so a new binding cannot ship without it. It splits into two
  virtuals because two things vary independently: who may send varies by cardinality, and
  what they may say varies by direction.
- `_counterpartOn` and `_routeTo` are separate lookups on purpose. A chain can have a
  resolved counterpart with no route set yet, or the reverse, and folding them would make a
  half-wired destination un-inspectable.

### HubTransceiverBase

The home side: one transceiver, N counterparts, one registry to tell them apart.

- `transmitterImplementation`, write-once, because changing it forks the population: an
  account's proxy is locked the moment it is armed, so a change moves nobody who already has
  one.
- `setRouting(chainRegistry, messageProvider, minCounterpartProvenance)`: the registry
  pointer and the provenance dial, both absent from the spoke entirely.
- `createTransmitter(bytes32 salt)`: the owner is `msg.sender` by construction rather than
  by argument, which is what stops one party squatting the address another intends to use.
  `predictTransmitter(owner, salt)` gives it beforehand.
- `_counterpartOn`: `chainRegistry.transceiverFor(chainKey, messageProvider,
  minCounterpartProvenance)`, with the bar applied inside the read.
- `_authenticateOrigin`: N origins, so it is a lookup. The route names the chain and the
  registry names that chain's counterpart at this transceiver's bar. An unknown route
  reverts in `chainKeyOfRoute`; a known route with the wrong sender reverts `NotCounterpart`.
- `_handleInbound`: a hub receives receiver reports and nothing else, decoded by
  `Envelope.decodeReceiverReport` and passed to `onDestinationReceiver`, which is self-call
  only and therefore reachable from `_onInbound` and nowhere else. It derives
  `receiverSlot(chainKey, owner, salt)` from the authenticated pair, so the destination
  cannot choose which slot it writes, and the registry refuses a second write to it. The
  registry grades the result `Attested`, not this contract: a remote party does not mark its
  own homework.
- `destinationReceiverOn(chainKey, owner, salt)`: the read, at this transceiver's bar.
- **A hub has no receiver machinery at all**, not gated, absent. An address holds one
  contract, so a receiver on the home chain would collide with the transmitter that belongs
  there. Absence beats a revert, because there is no entry point for a later change to
  expose.

### SpokeTransceiverBase

Every chain that is not the home chain: exactly one counterpart, named at initialization.

- `homeChainKey`, `homeRoute()`, `homeTransceiver()`, and `receiverImplementation` are all
  written once in `__SpokeTransceiverBase_init` and **none has a setter**. That is a security
  property rather than a saving: a setter plus a lock would leave a window in which the
  admin could repoint the one address this contract authenticates every inbound message
  against. The set of chains that can drive a spoke is fixed at initialization and cannot be
  widened afterwards by anyone, including the local msig.
- The home chain is a deployment **parameter**, not Ethereum. What the hub must be is an EVM
  chain with the EIP-152 precompile, because the registry recomputes addresses and
  commitments locally.
- `_counterpartOn` and `_routeTo` revert `NotHome` for anything but the home chainKey, which
  is what makes spoke-to-spoke traffic structurally impossible rather than merely
  unconfigured.
- `_authenticateOrigin`: one origin, so it is a comparison. `_isHome(route, sender)` checks
  both halves against write-once values, with no registry, no provenance, and no lookup that
  could return the wrong answer if configuration drifted.
- `_handleInbound`: a spoke receives bootstrap messages and nothing else, decoded by
  `Envelope.decodeBootstrap` and passed to `bootstrapInbound(owner, salt, calls)`, which is
  self-call only. It creates and initializes the receiver, and that is its entire
  relationship with one: it never calls `commit`, `cancel`, or `execute` afterwards and
  holds no upgrade key past this transaction.
- `_accountInitializer` encodes `IReceiverInit.initialize(predictCrossAccount(owner, salt),
  calls)`. The receiver's peer is its own address, passed explicitly rather than assumed, so
  nothing breaks if the two ever diverge.
- **There is no permissionless creation path.** An account on a spoke exists because a
  bootstrap arrived. An open one would let anyone deploy an owner's account empty, one
  transaction ahead of their bootstrap, and permanently deny it, since `CrossProxy` arms
  exactly once.
- `bootstrapElements` has an outbound half on the hub and no inbound twin here, because
  `SpokeTransceiverBase` is Solidity and therefore only ever runs on an EVM chain.
- `addressesDiverge`, write-once: whether an account's address here differs from the one the
  hub derives for it. True on zkSync and Tron among EVM chains, false everywhere parity
  holds. The hub cannot determine this, and a provenance cap means something adjacent but
  not the same thing, so it is stated once here.
- `_reportReceiver(owner, salt, receiver)`, called from `bootstrapInbound` when that flag is
  set, sending `Envelope.encodeReceiverReport` home with canonical ERC-7930 bytes for the
  receiver on this chain. It names the pair rather than the address alone, because the hub
  derives the registry slot from the pair plus the origin it already authenticated. Paid
  from this contract's balance, since the send is nested inside a delivery callback; a dry
  spoke reverts, which takes the account creation with it and keeps the bootstrap
  retryable.

### ReceiverBase

`Executor` + `Initializable` + `ReentrancyGuardUpgradeable` + `IReceiverInit`. Exactly one
receiver per transmitter per destination, reused for every payload that transmitter ever
sends.

**It is not an `OutboundBase`.** A receiver never sends, so it has no `_sendMessage`, no
`_quoteMessage`, and no quote surface. The absence is structural rather than a gate someone
could widen later.

- `initialize(address sourceTransmitter, Call[] calls)` is a thin `initializer` wrapper over
  `__ReceiverBase_init`, which is `internal onlyInitializing` and does the work. **The split
  is what makes a protocol binding possible**: with the work inside an `external
  initializer` there was no way to configure a provider after the reentrancy guard and
  before the payload. A binding declares its own `initialize`, does its setup, and calls
  `__ReceiverBase_init` last; it must not call `super.initialize`.
- The initializer takes a payload and **executes it**. It does not set a commitment: a
  payload that should wait rather than run says so itself, by carrying a self-call to
  `commit`. An empty array is the inert case, and is not refused the way `execute` refuses
  one.
- **Approvals are a queue, not a slot**, because the receiver is long-lived: with one slot a
  second commit would have to revert while one was still pending. It is append-only, so the
  index `commit` returns names that approval for the life of the receiver.
- `commit(bytes32) returns (uint256 index)`, `cancel(uint256 index, bytes32 expected)`,
  `finalize(Call[])`, `finalize(Call[][])`, and `execute(Call[]) payable`.
- **Execution is strictly FIFO.** `finalize` takes the head and only the head, so a relayer
  holding two valid payloads cannot choose which lands first. The cost is head-of-line
  blocking, and `cancel` is the escape hatch: the two are load-bearing for each other and
  neither should be removed alone. `cancel` names the approval twice, index and `expected`,
  so a caller working from stale state cannot withdraw a different payload than it meant.
- **`finalize` is permissionless; `commit`, `cancel`, and `execute` are gated.** Exactly one
  of "the payload is checked" or "the caller is checked" holds, and each entry point picks a
  different one.
- The gate is `onlySourceTransmitter`, over `isAuthorizedCaller`: the source transmitter, or
  `address(this)`. **The parent transceiver is not on the list.** Its whole relationship with
  a receiver is the initializer it already spent; letting it commit afterwards would make it
  a standing authority over every receiver it had created, on the chain where it is also the
  contract that authenticates every inbound message. `address(this)` is what makes a
  deferred payload work, and it is stated explicitly rather than inherited from the fact
  that a receiver and its transmitter usually share an address: they do not on zkSync or
  Tron, and without the arm deferring would fail silently on exactly those chains. It is
  safe because the only way to produce `msg.sender == address(this)` is through `_execute`,
  reachable only from an authenticated inbound message or a gated entry point.
- `commit` is `external`, so the self-call is a real CALL rather than an internal jump.
- `_onMessage(bytes payload)`: the inbound funnel a binding routes into. Decodes with
  `Payload.decodeCalls` and executes on arrival. The binding does not decode: every provider
  gets the same decoder and the same failure mode.
- Queue reads: `commitment()`, `nextIndex()`, `queueLength()`, `head()`, `commitmentAt()`,
  `pendingCount()`. A consumed entry keeps its value and is passed by the head pointer while
  a cancelled one is zeroed in place, so the two stay distinguishable on-chain afterwards.
- The two commitment rules, `_requireMatchingCalls` and `_requireCommittable`, are `private`:
  this is the only contract that holds a commitment.
- The commitment is chain-bound. `Commitment.hashCalls` folds in `ChainKey.local()`, so an
  array approved for one chain cannot be finalized here. Accounts sit at deterministic
  addresses across chains, which is exactly where a cross-chain replay would otherwise work.
- `ReentrancyGuardUpgradeable` is the **storage** version, not the transient one, because
  `TSTORE` needs Cancun and the build is pinned to `paris` for CREATE2 parity. It guards
  `_onMessage`, `finalize`, and `execute` under one lock, and is initialized before the
  payload runs, since a proxy runs no constructor of its own.
- `receive()`: `finalize` is permissionless and carries no value, so a payload that spends
  native draws on a balance already here. The address is deterministic and fundable before
  the receiver exists, which makes a shortfall "top it up and retry" rather than a loss.

### Envelope

- `encodeBootstrap` / `decodeBootstrap`: `(address owner, bytes32 salt, Call[] calls)`.
- `encodeBootstrapElements`: `(address owner, bytes32 salt, bytes[] elements)`, the same
  message for a destination whose calls this chain cannot express. There is no
  `decodeBootstrapElements`, because nothing written in Solidity ever receives one:
  `SpokeTransceiverBase` runs on an EVM chain by construction, so the decoder for this
  lives in whatever language that destination speaks.
- `encodeReceiverReport` / `decodeReceiverReport`: `(address owner, bytes32 salt, bytes
  interop)`. It names the pair rather than the account's address, matching the bootstrap
  message it answers: the address is a derivation of the pair, so the pair is the identity.
- There is no commitment envelope; committing is folded into the call array.

## Failure handling

Execution runs inside the bridge callback, so a reverting payload fails the message rather
than stranding a commitment. Every provider lets anyone re-execute a failed message, so
this is a retry rather than a loss, and a payload that failed for a fixable reason
(insufficient balance, a target not yet deployed) succeeds on retry once the cause is
fixed.

**This holds only under unordered delivery.** It is the default everywhere; opting into
ordered execution would let one permanently-failing message block every message behind it
on that lane.

No fallback storage, and no payload size cap: the provider enforces the latter.

## Design decisions

- **`initialize` executes the calls.** It does not set a commitment. A payload that should
  wait carries a self-call to `commit` and says so itself. The work sits in
  `__ReceiverBase_init`, `internal onlyInitializing`, so a protocol binding can configure
  its provider between the reentrancy guard and the payload.
- **A receiver answers to its transmitter and nothing else.** `commit`, `cancel`, and
  `execute` are gated on the source transmitter or a self-call. The transceiver that
  created the receiver is not on that list: its only reach is the initializer, and standing
  authority over every receiver it had created would sit on the same contract that
  authenticates every inbound message.
- **A receiver has no outbound at all.** It is not an `OutboundBase`, so it has no
  `_sendMessage` and no quote surface. The return report is sent by the spoke transceiver,
  gated on `addressesDiverge`, so it costs nothing on the chains where the hub can derive
  the address itself.
- **`Call[]` vs `bytes[]` is settled: the form follows the destination.** An EVM
  destination always gets `abi.encode(Call[])`; every other VM always gets opaque
  `bytes[]`. **There is no form tag**: the sender picks by destination chain type and the
  receiver decodes the one shape its own VM implies, so every channel still carries exactly
  one shape and `Envelope`'s no-tag rule holds throughout the protocol.
  The **receiver's entry point is `Call[]` only**, as is `TransmitterBase.execute`.
  `bytes[]` remains the canonical commitment form and the only form a non-EVM destination receives,
  and the commitment stays defined over opaque elements because that layer must be
  VM-agnostic. The two encodings commit to one hash, so an
  approval computed over portable `bytes[]` is discharged by the typed array. Built in
  `Payload.sol` / `Call.sol`; see [`encoding.md`](encoding.md), including the condition
  that would force a tag back and the open question about the opaque container off the EVM.
- **The commitment hash is per-destination.** `Scheme` selects the primitive:
  `Keccak256` (EVM, Solana, Aptos, Sui, NEAR, Cosmos), `Sha256` (TON),
  `Blake2b256Scheme` (Cardano), and `Poseidon` (Starknet) which is **declared and not
  implemented**: it reverts with `SchemeNotComputable` rather than falling back to keccak
  and handing back a digest the destination could never match. The fold structure is held
  fixed so both sides can compute it, which is a deliberate trade against TON's cell hash
  and Starknet's felt-span Poseidon being more idiomatic there. Blake2b's precompile
  forces the dispatching functions from `pure` to `view`, the same tax `IVmDeriver`
  already pays.
- **No transmitter entry point takes a `Scheme`.** `commitmentFor`/`commitmentForChain`
  name an EVM destination and stay keccak-only and `pure`; the overload that took a
  `Scheme` was removed. A preview is frozen with the account (a `CrossProxy` locks in the
  call that arms it), so it could only ever name primitives that already existed, which is
  exactly wrong for the part of the protocol most likely to grow. Non-EVM destinations are
  previewed through `ChainRegistry.commitmentFor`, where the primitive is an
  `ICommitmentScheme` bound per chainKey. The plugin supplies the primitive and the
  registry keeps the fold, so a bad plugin can only produce a digest the destination
  refuses. Nothing on the execution path reads it: `ReceiverBase` enforces with its own
  frozen keccak fold, and advisory-here / enforced-there is what makes a mutable preview
  safe. See [`encoding.md`](encoding.md) and `registry/ICommitmentScheme.sol`.
- **A destination report carries no `requestId`, and nothing is registered in advance.**
  The correlation an id would provide is already implied: the slot is
  `receiverSlot(chainKey, owner, salt)`, the chainKey comes from `_authenticateOrigin`, and
  the pair is stated in the report, so a destination cannot choose which slot it writes.
  It is keyed by `(owner, salt)` rather than by the transmitter's address because that pair
  is what an account IS; the address is a derivation of it.
  The slot is **write-once**, so a replayed or hostile second report cannot repoint a
  receiver already on record.
- **The registry authenticates per provider.** `localTransceiver[messageProvider]` and the
  reverse `providerOfTransceiver` name the one contract allowed to report for a provider,
  so a second provider's hub can report without displacing the first. The callback takes no `messageProvider` argument: the provider
  is a property of `msg.sender`, not a claim the message gets to make about itself.
- **Routes are declared by the owner, write-once, and default to address parity.**
  `setTransceiverId` refuses a repoint, and the callback does not learn routes: a report
  is evidence, not a routing decision. An unset route falls back to the local
  transceiver's own address on that chain, which is correct wherever Ethereum's CREATE2
  formula holds, and withdraws on non-EVM chains and on any chain capped below `Derived`
  (which is how zkSync and Tron are excluded).

- **One owner, one address, every EVM chain.** An owner's transmitter on the home chain and
  their receiver on Base are the same address. Both are deployed as `CrossProxy` (an
  argument-free proxy, so its initcode is one constant) from the transceiver, at
  `accountSalt(owner, salt)`. The caller's salt lets one owner hold several accounts, each
  keeping the one-address property independently. Hub and spoke share an address, so all three CREATE2 inputs match
  and only the installed implementation differs, which the derivation never sees. A minimal
  clone could not do this: EIP-1167 embeds the implementation in its initcode. Transmitters
  are created by `createTransmitter(salt)` on the hub, where `owner` is `msg.sender` by
  construction.
- **The upgrade key exists for part of one transaction.** `CrossProxy` offers exactly one
  admin operation, which installs the implementation, runs the initializer, and zeroes the
  admin in that order: there is no way to upgrade without locking, and no reachable state
  in which an account has real logic and a live key. The transceiver that created the
  account holds it in between and cannot outlive the call.
- **A transmitter executes its own local payloads.** There is no receiver on the home chain to
  run them in, so `TransmitterBase` and `ReceiverBase` share `messaging/Executor`, one
  loop, one policy check, one all-or-nothing rule. `TransceiverBase` deliberately does not
  inherit it. Cancellation is inherently remote (a transmitter holds no queue), so
  `cancellationCall` builds the element and a payload carries it.
- **Approvals are an ordered queue with cancellation.** `ReceiverBase` holds
  `bytes32[] _commitments` plus a head pointer instead of a single slot. `commit` appends
  and returns a stable index; `finalize(Call[])` discharges only the oldest outstanding
  approval; `finalize(Call[][])` discharges several in queue order, all-or-nothing;
  `cancel(uint256 index, bytes32 expected)` withdraws one, naming the approval as well as the slot so a stale index reverts rather than silently dropping a different payload, and is gated exactly like `commit`. The head
  advances before execution, so a re-entrant `finalize` finds its own approval spent.
  Cancellation is inherently remote, since a transmitter holds no queue: `cancellationCall`
  builds the element and a payload carries it, which the `bytes` wire expresses without a
  message-type tag.
  **Ordering and cancellation are load-bearing for each other**: strict FIFO means a
  permanently-failing payload would stall everything behind it, and `cancel` is the only
  way out. This is the same trade the failure-handling section notes for ordered bridge
  delivery, now made deliberately at the approval layer rather than inherited from a lane.

**`Provenance.Committed` has no producer.** Nothing grades a reference at it; it exists
only as a cap, because several chains are configured at it through `setMaxProvenance` and
removing it would renumber `Derived` and silently loosen every one of those caps. A
reported reference lands at `Attested`, and anything wanting better must use a locally
derived path.

## TODO

Kept in [`todo.md`](todo.md), together with everything else outstanding, so there is one
list rather than three that drift.

## Invariants

- `Commitment.hashCalls` folds in the destination chainKey; `finalize` recomputes with
  `ChainKey.local()`. That is the cross-chain replay protection.
- Target and value sit inside the committed element, so an approval covers who is called
  and how much they receive.
- `finalize` is permissionless; `execute` is gated. Exactly one of "the payload is checked"
  or "the caller is checked" holds, and each entry point picks a different one.
- Account addresses are CREATE2 on `(owner, salt)`, fixed for the life of the protocol and
  pinnable in a signed payload. Each account has one address on every parity chain.
- Provenance gates bootstrap (the first message to a chain), rather than every send.
