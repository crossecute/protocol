# Message flow

The two paths a message takes, the wire formats, and what each contract does.

**Status.** Both paths are built end to end in-process: `_sendMessage(bytes, bytes,
bytes[])`, `sendMessage` / `bootstrap`, the quote surface, the inbound funnel, and the
reentrancy guard. The send and receive surfaces are ERC-7786's:
`TransmitterBase` is an `IERC7786GatewaySource` and `ReceiverBase` an `IERC7786Recipient`. What is missing is a **message provider
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
 │  transmitter.sendMessage{value: fee}(recipient, payload, attributes)  onlyAccountOwner
 │    recipient = <erc7930: chain 8453, address(this)>                  checked, not trusted
 │    payload   = abi.encode(calls)                                     built by the caller
 │    _sendMessage(recipient, payload, attributes)
 ▼
 ══════════════════ bridge ══════════════════
 │
 ▼  receiver.receiveMessage(receiveId, sender, payload)
      onlyRole(GATEWAY_ROLE)                                           granted at arming
      sender's address == address(this)                                1:1, derived
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
 │  transmitter.bootstrap{value: fee}(chainId, calls)          onlyAccountOwner
 ▼
hub transceiver .bootstrap(chainKey, owner, salt, calls, attributes)   msg.sender must BE the account
 │    _requireRoutable(chainKey)                                       ← provenance bar applies here
 │    _sendMessage(_recipientOn(chainKey), Envelope.encodeBootstrap(...), attributes)
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

**The message carries the OWNER AND THEIR SALT, not the transmitter**, because the account
address derives from that pair and a CREATE2 address cannot be derived from itself. The
receiver's peer is therefore its own address, since that is where the transmitter sits at
home. The wire-format section below says the same thing about the same field; it is stated
twice because getting it wrong produces an account at an address nobody can reach.

**The return leg is sent by the spoke transceiver, and only where it buys something.** The
receiver cannot be its own sender: it is not an `OutboundBase`, has no `_sendMessage`, and
holds neither the home route nor the hub's address. The spoke transceiver holds all four
things the report needs at once: the home route, the hub's address, the authenticated
`(owner, salt)` pair, and the receiver it has just created.

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

A recipient is a binary interoperable address (ERC-7930) carrying its own chain, so no
channel names a destination separately from its message.

| Channel | Payload |
| --- | --- |
| transmitter → receiver | `abi.encode(Call[] calls)` on EVM, `abi.encode(bytes[] elements)` elsewhere |
| hub → spoke transceiver | `abi.encode(address owner, bytes32 salt, Call[] calls)` on EVM, `abi.encode(address owner, bytes32 salt, bytes[] elements)` elsewhere |
| spoke → hub transceiver | `abi.encode(address owner, bytes32 salt, bytes interop)` |

**Both transceiver channels name the OWNER AND SALT rather than an address.** The pair has
to be stated because the hub is shared by every owner, so nothing the bridge reports says who
authorized the message; and it is the pair rather than the address because the address is a
derivation of it. That is also what lets the hub key the receiver slot without a request id.

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

One subsection per contract on the message path, in the order a message meets them.
Signatures are the real ones; where a base declares something without implementing it, that
is said. The addressing, derivation, and registry trees are not covered here: see
[`encoding.md`](encoding.md) for the commitment layer and `registry/ChainRegistry.sol` for
the directory.

### Roles

The two authorities, and the only two. `ADMIN_ROLE` configures a transceiver; `GATEWAY_ROLE`
is which transport may carry a contract's messages. Both were once a virtual predicate every
binding answered for itself; they are role membership now, so authorization has one shape and
a binding adds a transport or an operator by granting rather than by writing a comparison.

- **One role covers both directions.** A contract that accepted deliveries from one address
  while sending through another would be trusting two transports and authenticating against
  one, and nothing would say so: the send would work, and only a message from the second
  gateway would be silently refused. `ReceiverBase` inherits `Roles` directly rather than
  through `OutboundBase`, because a receiver never sends yet has the strictest need to know
  which gateway is real.
- **`DEFAULT_ADMIN_ROLE` is never granted.** OZ's default puts it over every role, which
  would make "who may add a gateway" a question with two answers. `ADMIN_ROLE` administers
  itself and `GATEWAY_ROLE`, so an admin can hand over, add an operator, or change the
  transport set, and nothing else can.
- **An account holds no `ADMIN_ROLE`, and that is what freezes it.** A receiver or transmitter
  grants its gateway in the call that arms it and leaves the admin set empty, so afterwards
  there is nobody a grant could come from. The same guarantee the write-once slots give,
  obtained by leaving a role unheld rather than by refusing a second write.
- **The role ids are namespaced** (`keccak256("crossecute.role.ADMIN")`). A role is a bytes32,
  so an SDK defining its own `ADMIN` would otherwise share this member set and hand its
  administrators this authority through a string collision.
- **Enumeration is ours, not OZ's, because of the `paris` pin.**
  `AccessControlEnumerableUpgradeable` reaches `EnumerableSet` and so `Arrays`, which emits
  `mcopy` and needs Cancun; a Cancun opcode in a spoke transceiver would not change an
  address, it would fail to execute. The interface is OZ's `IAccessControlEnumerable` and the
  member list is a swap-and-pop array, so `getRoleMembers` answers "who else" — the question
  a predicate could not, since a predicate only speaks about an address already suspected.

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

- **Entry points call `_sendMessage` directly**, with nothing in between to drift out of
  step with either. Validation sits at the entry point, where the untrusted argument arrives,
  and the send event is the standard's, since a gateway source must emit `MessageSent`.
- `_sendMessage(bytes recipient, bytes payload, bytes[] attributes) returns (bytes32
  sendId)`: `internal virtual`, reverting `SendNotImplemented` until a protocol binding
  overrides it. **One primitive for every channel**, and now ERC-7786's own: a payload to
  an account, a bootstrap to a spoke transceiver, and a receiver report back are all
  `bytes` to an interoperable address. The `sendId` is the gateway's, and a non-zero one
  means the message is NOT away yet; a binding either handles the second step or refuses
  gateways that need one.
- `_quoteMessage(...)`: the same three arguments, `view`, reverting `QuoteNotImplemented`
  by default, and called directly for the same reason `_sendMessage` is. `quoteMessage`
  repeats the entry point's checks so a quote cannot succeed for a message the send would
  refuse. Nothing on the send path consults it: the quote is advisory, and a price that
  moved in between is the provider's refund to make rather than a revert.
- `_refundTo()`: `msg.sender`. A fee is overpaid by whoever paid it. On path A that is the
  owner, because `sendMessage` is owner-gated; on path B it is the account, because `bootstrap`
  refuses any caller that is not `predictCrossAccount(owner, salt)`. The shared transceiver
  is structurally incapable of being its own refund target, since it is never the caller of
  its own `bootstrap`.
- `attributes` are per send, not configuration: destination gas is a property of the
  payload, so a stored default would strand the first message that needed more. An empty
  array means "the gateway's default", and `supportsAttribute` is how a caller learns what
  a given binding understands.
- Events are the standard's where there is one and the protocol's where there is not.
  Path A emits `MessageSent`, which ERC-7786 requires of a gateway source. Path B is not a
  gateway source, so `TransceiverBase` emits `BootstrapSent(chainKey, owner, salt)`, which
  names the pair rather than hashing it: that triple is what an account is, and what the
  return leg's registry slot is keyed by.

### TransmitterBase

`OutboundBase` + `Executor` + `Initializable` + `IERC7786GatewaySource`. The per-user
account on the home chain. Its storage is `transceiver`, `accountSalt`, and the
per-destination bootstrap record below, and nothing else.

- **The destination is a parameter, not state.** One transmitter fans out to every chain,
  which is also what keeps one receiver per (transmitter, destination).
- **A per-destination bootstrap record**, `isBootstrapped(chainKey)` (and
  `isBootstrappedOn(chainId)` for the plain-chain-id spelling). `sendMessage` requires the
  destination present in it and `bootstrap` requires it absent, so a payload cannot be paid
  for and sent to a chain where this account has no receiver, and a second bootstrap cannot
  be paid for to revert on arrival. It records that a bootstrap was DISPATCHED rather than
  that one landed: the message is asynchronous, and on a parity chain no report ever comes
  back, so there is no confirmation to wait for. Delivery is retryable at the provider, so
  a bootstrap that reverts on arrival is pending rather than lost.
- `sendMessage(bytes recipient, bytes payload, bytes[] attributes)`: path A, and the ONLY
  send. It is `IERC7786GatewaySource`'s signature, and one signature covers every
  destination: a recipient carries its own chain, so the chain id, the ERC-7930 envelope, and
  the choice between typed and opaque payloads all fold into two arguments.
- **The recipient is checked against the stored counterpart, not against `address(this)`.**
  `bootstrap` records the receiver it is standing up, and `sendMessage` refuses any recipient
  that is not it, whole: chain half included. Deriving the peer instead looked free, because
  an account and its receiver share an address wherever Ethereum's CREATE2 formula holds, but
  it could only be checked where it was derivable (so non-EVM recipients went unchecked) and
  it was wrong on zkSync and Tron, which are `eip155` and so kept a check that could never
  pass. On a chain that reports, the transceiver writes the real address through
  `onDestinationReceiverReported`, once: there is no override, not even the owner's, because
  an account's peer decides where a payload lands.
- **The payload arrives built, and that costs one check.** `bytes payload` cannot be asked
  whether it holds `Call[]` or opaque elements, so this contract cannot refuse a typed
  payload bound for a non-EVM chain or an opaque one bound for an EVM chain; the pairing is
  the caller's to get right. `payloadForCalls` and `payloadForElements` are pure builders so
  it is at least spelled the same way here as it is decoded there.
- **Every `bytes` argument has a builder that produces it**, because `Erc7930` is a library of
  `internal` functions and so is not callable off-chain at all: without these an integrator
  would have to reimplement ERC-7930 encoding, and an interoperable address got wrong is a
  message addressed into the void. `recipientOn(chainId)` builds `sendMessage`'s recipient
  (this account, on that chain) and `chainIdentifierFor(chainId)` builds `bootstrapTo`'s
  identifier (the chain alone, since path B addresses a chain that has no account yet). The
  two agree on the chain half, which is what lets a caller choose an entry point on
  ergonomics rather than on reach.
- `supportsAttribute(bytes4)`: required by ERC-7786, answered by the binding. The base
  understands none, which is the honest answer for a base with no gateway behind it.
- `quoteMessage(bytes recipient, bytes payload, bytes[] attributes)`: `sendMessage`'s
  arguments minus the value. ERC-7786 defines no quote, so this is the protocol's own, and
  it carries the same gates the send does.
- `bootstrap` and `bootstrapTo`, **three** overloads: path B, forwarded to the transceiver
  with the whole `msg.value`. Only two things about a bootstrap vary, so only two things are
  overloaded on: how the destination is spelled (a `uint256` chain id, or an ERC-7930
  identifier) and whether its calls are typed or opaque. `attributes` is mandatory on all
  three rather than a third axis, so each has a quote of matching arity; see below.
  They pass `_owner()` and `accountSalt` rather than this contract's own address, because a
  CREATE2 address cannot be derived from itself. Holding `Call[]` and `bytes[]` rather than a
  prebuilt payload is what lets path B enforce the pairing path A cannot:
  `_typedIdentifier` refuses a non-EVM destination and `_opaqueIdentifier` refuses an EVM
  one.
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
  the send path needs no route lookup at all now, because an ERC-7786 recipient names its own
  chain. What an account does hold is one address: `IAccountTransceiver`, over the single
  transceiver it stores, carrying `bootstrap`, `bootstrapElements`, the two quotes that price
  them, and `routeTo` for a caller that wants to read the chain identifier a destination is
  configured under. Only the bootstrap and quote members are called from this contract;
  `routeTo` is there so an account never needs a route table of its own.

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
- `setRoute(bytes32 chainKey, bytes route)`: `ADMIN_ROLE` and **write-once**, maintaining the
  reverse index in the same call because two setters is how the two directions drift apart.
  **The route is the chain's ERC-7930 identifier**, not a provider's private id for it: an
  ERC-7786 recipient names its own chain, so there is nothing left to translate. That also
  makes the reverse index correct by construction, since `keccak256(identifier)` IS the
  chainKey.
  Re-writing the same route is a no-op; a different one reverts `RouteAlreadySet`, and a
  route already held by another chain reverts `RouteInUse`, since two chains sharing one
  identifier would let an inbound message be attributed to the wrong source. Reads are
  `routeFor`, `chainKeyOfRoute`, `hasRoute`, and the public `routeTo`. The table lives here
  rather than in the registry because this is the contract that sends.
- `_recipientOn(chainKey)`: the two halves of `_requireRoutable` joined into the
  interoperable address a gateway takes, by parsing the stored identifier for its chain type
  and reference and re-encoding it around `_counterpartOn(chainKey)`. Building it here means
  both lookups happen on the send path, so the provenance bar and the route requirement are
  enforced by construction rather than by a separate call somebody could drop.
- `accountSalt(owner, salt)` is `keccak256(abi.encode(owner, salt))`, hashed rather than
  concatenated so no pair can collide with another by sliding bytes across the boundary.
  `predictCrossAccount(owner, salt)` gives the address before it exists.
- `_createCrossAccount(owner, salt, calls)`: deploy, arm, and lock in one call. Two virtuals
  decide what is installed: `_accountImplementation` (hub: transmitter, spoke: receiver) and
  `_accountInitializer`. The proxy, the salt, and the deployer address are identical on both
  sides, which is what puts an owner's transmitter and their receivers on one address.
- `bootstrap(chainKey, owner, salt, calls, attributes) payable` and `bootstrapElements`:
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
- **The authority is `ADMIN_ROLE`**, granted in `__TransceiverBase_init` from an address the
  deployment supplies, and a zero one is refused: every configuring operation is
  `onlyRole(ADMIN_ROLE)`, so a transceiver with an empty admin set could never be given a
  route. Two ownership systems over the same operations would mean an authority gated on one
  could be exercised through the other, which is why nothing here reads an `owner()`.
  Membership also answers about addresses that are not the caller, which a caller-shaped
  check could not: `withdrawFees` requires the DESTINATION to hold `ADMIN_ROLE`, so a fee
  taken to fund spokes cannot leave to somewhere that funds none.
- **Upgrades lock in the initializer.** `__TransceiverBase_init` sets the flag and both
  halves call it last, so there is no `lockUpgrades()` and no window between "the real logic
  is in place" and "nobody can replace it". A transceiver decides which cross-chain payloads
  are authentic, so a live upgrade key on one is a standing ability to forge any message the
  protocol will honour, and an operator who has not locked yet is running an authenticator
  somebody can replace. The proxy still gets exactly one upgrade — the one carrying this
  initializer, which fixes the address before the implementation is known, since every
  account's CREATE2 derives from it. `_authorizeUpgrade` refuses everything after.
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
- **The hub holds the counterpart directory**, `chainKey => location`, written by
  `setCounterpart` (declared) or `resolveCounterpart` (recomputed from the registry's deriver,
  naming the inputs so signers approve them rather than a pointer). Both are write-once. The
  registry holds `provenanceFor(chainKey)`, what a claim about that chain is worth, and
  `_counterpartOn` refuses anything below `minCounterpartProvenance`. Where a counterpart is
  differs per provider; how well it can be known does not, so the two live apart and two
  hubs cannot disagree about a chain. An unset counterpart on a `Derived` chain falls back
  to the hub's own address, since hub and spoke share one wherever parity holds.
- `_authenticateOrigin`: N origins, so it is a lookup. The route names the chain and the
  registry names that chain's counterpart at this transceiver's bar. An unknown route
  reverts in `chainKeyOfRoute`; a known route with the wrong sender reverts `NotCounterpart`.
- `_handleInbound`: a hub receives receiver reports and nothing else, decoded by
  `Envelope.decodeReceiverReport` and passed to `onDestinationReceiver`, which is self-call
  only and therefore reachable from `_onInbound` and nowhere else. **It writes to the
  account, not to the registry.** The registry is deliberately out of the send path, so an
  address filed there could not make a diverging chain reachable however faithfully it was
  recorded; the transmitter is the contract that addresses that receiver, so it is the
  contract that is told. The account is
  `predictCrossAccount` of the authenticated `(owner, salt)`, so a destination cannot choose
  which account it writes, and the account itself refuses a second report.
- The registry still says **which** chains may report: `requiresReceiverCallback(chainKey)`
  is true exactly where the hub cannot recompute an address, so a report from a derivable
  chain is refused rather than allowed to replace a `Derived` fact with a weaker one. That
  is the direction, which is chain-scoped and belongs in a directory; the data is not.
- `destinationReceiverOn(chainKey, owner, salt)`: a passthrough to the account's own
  counterpart table, so there is one answer rather than a directory copy that could disagree
  with the send path.
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
  holds. The hub cannot determine this, and a chain's provenance grade means something
  adjacent but not the same thing, so the spoke states it.
- **A deployment states it by choosing a contract, not by passing a bool.** The flag has to
  agree with `predictCrossAccount`, since one says the hub cannot derive an address here and
  the other is the arithmetic that makes that true. `LzSpokeTransceiver` is Ethereum's
  formula and takes no flag; `LzZkSyncSpokeTransceiver` and `LzTronSpokeTransceiver` are
  that chain's formula, set the flag themselves, and take the account bytecode hash their
  compiler produces, which is the one value neither can compute. The pair is exhaustive and
  mutually exclusive, so a flag disagreeing with the arithmetic is unrepresentable.
- `_reportReceiver(owner, salt, receiver)`, called from `bootstrapInbound` when that flag is
  set, sending `Envelope.encodeReceiverReport` home with canonical ERC-7930 bytes for the
  receiver on this chain. It names the pair rather than the address alone, because the hub
  derives the registry slot from the pair plus the origin it already authenticated. Paid
  from this contract's balance, since the send is nested inside a delivery callback; a dry
  spoke reverts, which takes the account creation with it and keeps the bootstrap
  retryable.

### ReceiverBase

`Executor` + `Initializable` + `ReentrancyGuard` + `IReceiverInit` + `IERC7786Recipient`.
Exactly one
receiver per transmitter per destination, reused for every payload that transmitter ever
sends.

**It is not an `OutboundBase`.** A receiver never sends, so it has no `_sendMessage`, no
`_quoteMessage`, and no quote surface. It is a recipient and nothing else. The absence is structural rather than a gate someone
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
- `receiveMessage(bytes32 receiveId, bytes sender, bytes payload)`: `IERC7786Recipient`'s
  entry point, and the only way in. It is `external`, so it carries TWO checks rather than
  one: `onlyRole(GATEWAY_ROLE)` says the message came through transport this account trusts,
  and the sender's address must match `sourceTransmitter`, which says it came from THIS
  account on the other side. An honest but shared gateway would otherwise let one
  account's payload land in another's receiver. The `receiveId` is ignored: a payload either
  matches a queued commitment or executes on arrival, and neither asks which message
  carried it.
- `GATEWAY_ROLE`: which transport is trusted is a property of the binding, so the binding
  grants it in the call that arms the account and nothing can grant another afterwards — an
  account holds no `ADMIN_ROLE`, and that role is what administers this one. The sender half
  needs no configuration, so it is answered in the base. The SAME role gates the outbound
  direction on a transmitter or transceiver, so a contract cannot accept from one address
  while sending through another; see `Roles`.
- `_onMessage(bytes payload)`: the inbound funnel `receiveMessage` routes into. Decodes with
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
- `ReentrancyGuard` is the **storage** version, not the transient one, because `TSTORE`
  needs Cancun and the build is pinned to `paris` for CREATE2 parity. It guards
  `_onMessage`, `finalize`, and `execute` under one lock. It is the NON-upgradeable
  contract: OpenZeppelin removed the upgradeable variant in 5.6.0, having flagged the guard
  stateless, because it keeps its state in an ERC-7201 namespaced slot rather than a linear
  one. Nothing initializes it, and nothing needs to: a proxy runs no constructor, so the
  slot stays zero, and the guard tests for `ENTERED` explicitly, so zero reads as
  not-entered. It costs one cold write on an account's first guarded call.
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

**And it holds only because the payload is all-or-nothing.** `_execute` reverts the whole
array on one failure, so a retry re-runs a payload that did nothing rather than re-applying
a prefix that already landed.

**Replay protection on path A is the transport's, not this protocol's.** An
execute-on-arrival payload carries no commitment and no identifier, so a second delivery
would run it twice; bootstrap and the receiver report are structurally single-shot and need
nothing. Every provider currently in scope except Wormhole's core layer guarantees
exactly-once at the transport, by the same shape that gives retry: mark the message
consumed, then call the receiver with a plain external call, so a revert rolls the mark
back. It is an imported guarantee rather than an enforced one, which is why it is a stated
provider prerequisite and a compliance test rather than a comment. See
[`provider-research.md`](provider-research.md#1-what-each-transport-guarantees-about-replay).

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
  name an EVM destination and stay keccak-only and `pure`, since every chain that executes
  `Call[]` hashes with keccak256 and there is exactly one primitive they can ever need. A
  scheme-parameterized preview belongs on the registry instead: here it would be frozen with
  the account (a `CrossProxy` locks in the call that arms it), so it could only ever name
  primitives that already existed, which is exactly wrong for the part of the protocol most
  likely to grow. Non-EVM destinations are
  previewed through `ChainRegistry.commitmentFor`, where the primitive is an
  `ICommitmentScheme` bound per chainKey. The plugin supplies the primitive and the
  registry keeps the fold, so a bad plugin can only produce a digest the destination
  refuses. Nothing on the execution path reads it: `ReceiverBase` enforces with its own
  frozen keccak fold, and advisory-here / enforced-there is what makes a mutable preview
  safe. See [`encoding.md`](encoding.md) and `registry/ICommitmentScheme.sol`.
- **A destination report carries no `requestId`, and nothing is registered in advance.**
  The correlation an id would provide is already implied: the target is the account
  `predictCrossAccount(owner, salt)` resolves to, the chainKey comes from
  `_authenticateOrigin`, and the pair is stated in the report, so a destination cannot
  choose which account it writes.
  It is keyed by `(owner, salt)` rather than by the transmitter's address because that pair
  is what an account IS; the address is a derivation of it. That argument is about
  CORRELATION. IDEMPOTENCY is a separate question and it is settled the same way: an
  execute-on-arrival payload has no structural protection of its own, so replay protection
  is the transport's, stated as a provider prerequisite and tested per binding rather than
  bought with a protocol-level id. See
  [`provider-research.md`](provider-research.md#1-what-each-transport-guarantees-about-replay).
- **A reported address must be on the chain that reported it.** An ERC-7930 envelope names
  its own chain, and `onDestinationReceiver` compares that against the origin it
  authenticated. Without the check the registry keyed the ref by whatever the envelope
  claimed while the slot was keyed by where the message came from, so a stored reference
  could contradict its own address. It grants no reach on its own, since an authenticated
  spoke can already report a wrong address on its own chain and payloads route by chainKey
  regardless; what it buys is a ref that cannot disagree with itself.
  The slot is **write-once**, so a replayed or hostile second report cannot repoint a
  receiver already on record.
- **The registry authenticates per provider.** `localTransceiver[messageProvider]` and the
  reverse `providerOfTransceiver` name the one contract allowed to report for a provider,
  so a second provider's hub can report without displacing the first. The callback takes no `messageProvider` argument: the provider
  is a property of `msg.sender`, not a claim the message gets to make about itself.
- **Routes are declared by the owner, write-once, and default to address parity.**
  `setCounterpart` and `setRoute` both refuse a repoint. An unset counterpart falls back to
  the hub's own address, which is correct wherever Ethereum's CREATE2 formula holds, and
  withdraws on non-EVM chains and on any chain graded below `Derived` (which is how zkSync
  and Tron are excluded).

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

**Provenance is two useful values and a null.** `Derived` means this chain can recompute an
address on that one; `Attested` means it cannot and was told, so the value is worth exactly
the bridge that carried it; `Unresolved` means nothing has been declared and no bar accepts
it. There is no middle grade because the question has no middle, and the order is the
semantics, so inserting one would renumber the rest.

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
- A destination is bootstrapped exactly once per account, and a send to one that has not
  been is refused locally rather than paid for and failed on arrival.
