# Message flow

The two paths a message takes, the wire formats, and what each contract does.

**Status.** Both paths are built end to end in-process: `_sendMessage(bytes32, bytes)`,
`send` / `sendTo` / `bootstrap`, the inbound funnel, and the reentrancy guard. What is
missing is a **message provider binding**: `_sendMessage` reverts `SendNotImplemented` by
default, so nothing crosses a real bridge yet. The README's `TransceiverBase` /
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
 │    _sendMessage(chainKey, abi.encode(calls))
 ▼
 ══════════════════ bridge ══════════════════
 │
 ▼  receiver.<provider callback>(origin, payload)
      origin.sender == peer                                            1:1, see below
      calls = abi.decode(payload, (bytes[]))
      _execute(calls)                                                  nonReentrant
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
hub transceiver .bootstrap(chainKey, calls)                            msg.sender = transmitter
 │    (counterpart, route) = _route(chainKey)                          ← provenance bar applies here
 │    _sendMessage(chainKey, Envelope.encodeBootstrap(owner, salt, calls))
 ▼
 ══════════════════ bridge ══════════════════
 │
 ▼  spoke transceiver ._onInbound(route, sender, message)
      _authenticateOrigin  → must be the hub
      _handleInbound → bootstrapInbound(owner, salt, calls):
        deploy CrossProxy at accountSalt(owner, salt)                  CREATE2, no args
        upgradeInitializeAndLock(receiverImpl, initialize(peer, calls))
          │   installs logic, executes the calls, drops the upgrade key (one call)
          └─  calls back: reportSelf()          ← the receiver's only outbound
 ▼
 ══════════════════ bridge ══════════════════
 │
 ▼  hub transceiver ._handleInbound  → onDestinationReceiver → registry
```

**The message carries the OWNER AND THEIR SALT, not the transmitter.** The account address
derives from the pair, which is what puts an owner's transmitter and their receivers on one address. The
transmitter's own address could not serve: a CREATE2 address cannot be derived from itself.
The receiver's peer is therefore its own address, since that is where the transmitter sits
on the home chain.

**The receiver reports its own address, and that is the only message it can send.** It has
no general outbound: no `_sendMessage`, no `OutboundBase`. During `initialize` it calls
back into the transceiver that created it, and the transceiver puts the report on the wire.

That is the right shape for a specific reason: on the chains this path exists for, the
address is not predictable from the hub. Starknet's is a Pedersen hash chain the EVM
cannot run. The receiver is the only party that knows what it is. Reporting through the
receiver rather than from the transceiver's own `predictCrossAccount` also means the address
reported is one that exists and initialized successfully, rather than one that was
computed and might not.

On an EVM destination nothing persists past the transaction: deploy, arm, execute, and lock
all happen in the inbound handler. Chains where deployment is not synchronous (Starknet,
the Move chains) need somewhere to hold the payload in between, which is a per-VM concern
rather than a shared one.

After this, the owner points the transmitter's peer at the receiver and every subsequent
message takes path A.

## Wire formats

Each channel carries exactly one shape, so direction remains the discriminant and no
channel needs a tag.

| Channel | Payload |
| --- | --- |
| transmitter → receiver | `abi.encode(Call[] calls)` on EVM, `abi.encode(bytes[] elements)` elsewhere |
| hub → spoke transceiver | `abi.encode(address transmitter, Call[] calls)` |
| spoke → hub transceiver | `abi.encode(address owner, bytes32 salt, bytes interop)` |

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

### OutboundBase

- `_send(bytes32, bytes32)` → `_sendMessage(bytes32 chainKey, bytes payload)`. One
  primitive for all three channels. The old signature could not express the receiver
  report at all, which is why that path was never built.
- `Dispatched` carries the payload hash rather than a commitment.

### TransmitterBase

- Holds the provider's endpoint half. This is where `OApp` and friends attach.
- `send(uint256 chainId, bytes[] calls)`: path A.
- `sendTo(bytes chainIdentifier, bytes[] calls)`: path A for destinations with no
  `uint256` chain id.
- `bootstrap(uint256 chainId, bytes[] calls)`: path B, via the transceiver.
- `execute(Call[] calls)`: local, no bridge.
- `commitmentFor` builds the argument to a self-call to `commit`.
- Peer management comes from the provider base. The owner sets one peer per destination,
  which is where the transmitter learns its receiver's address.

### TransceiverBase

- `bootstrap(bytes32 chainKey, Call[] calls) payable`: external, `msg.sender` is the
  transmitter. Permissionless: the only reachable outcome is a receiver keyed to the
  caller's own address, which answers to nobody else.
- `_createCrossAccount(owner, calls)` on `TransceiverBase`: deploy, arm, lock, one call.
  Two virtuals decide what is installed: `_accountImplementation` (hub: transmitter, spoke:
  receiver) and `_accountInitializer`.
- `createTransmitter(bytes32 salt)` on the hub: `owner` is `msg.sender` by construction;
  `predictTransmitter(owner, salt)` gives the address before it exists.
- **No public creation path on a spoke.** An account there exists because a bootstrap
  arrived. An open one would let anyone deny an owner their bootstrap by deploying the
  account empty first, since `CrossProxy` arms exactly once.
- **A hub has no receiver machinery at all**, not gated, absent. An address holds one
  contract, so a receiver on the home chain would collide with the transmitter that
  belongs there.
- `setRoute(chainKey, bytes)`: write-once, `onlyAdmin`, maintaining the reverse index in
  the same call. The route lives here rather than in the registry because this is the
  contract that sends: a registry read would put a second shared contract in the path of
  every send and let a compromised one misroute a payload. `LzHubTransceiver.setEid` is the
  typed wrapper.
- It is the only caller of `_requireRoutable`, and therefore the
  only place `minCounterpartProvenance` is enforced: a bar on the first message to a
  chain rather than on every send.
- The spoke holds the callback the receiver's `initialize` reports through, and puts the
  resulting report on the wire. It must verify the caller is the account it just created.
- Chains where deployment is not synchronous need somewhere to hold the payload between
  arrival and creation, keyed by owner so one cannot wedge another. On EVM nothing
  persists: deploy, arm, execute, and lock happen in the inbound handler.
- `bootstrapElements`: the outbound opaque half. There is no inbound twin, because
  `SpokeTransceiverBase` is Solidity and therefore only ever runs on an EVM chain; the
  decoder for an opaque bootstrap lives in whatever language that destination speaks.
- **Provider setup is folded into `_accountInitializer`**, which is `virtual` through Hub
  and Spoke so a binding can override it. There is no post-creation hook and cannot be: the
  proxy locks in the same call that arms it, and an account's peer table and delegate are
  owner-gated: the transceiver is not the owner. The peer value is not provider-specific:
  it is the account's own address.

### ReceiverBase

- Holds the provider's receiving half, with the account address as its peer. This works in
  a proxy: the endpoint address is an immutable shared by every account, which is correct
  since they all use the same one, and the peer is per-account storage.
- `initialize(address transmitter, Call[] calls)`: takes a payload and **executes it**. It
  does not set a commitment. A payload that should wait rather than run says so itself, by
  carrying a self-call to `commit`; nothing about the initializer needs to know the
  difference. The reentrancy guard must be initialized before the calls run.
- The two commitment rules are `private` to the receiver: it is the only thing that holds
  a commitment, so there is nowhere else they could be needed.
- `_onMessage(bytes payload)`: the inbound funnel a provider adapter routes into. Decodes
  with `Payload.decodeCalls` and executes on arrival. `nonReentrant`, shared with `finalize`
  and `execute`.
- `reportSelf()`: the one thing a receiver sends. Called during `initialize`, it hands the
  receiver's own address to `parentTransceiver`, which puts it on the wire. The receiver is
  not an `OutboundBase` and has no other outbound path.
- `isAuthorizedCommitter` accepts `address(this)`. Safe because the only way to produce
  `msg.sender == address(this)` is through `_execute`, which is reachable only via an
  authenticated inbound message or a gated `execute()`. A target calling back presents
  itself, not the receiver.
- `commit` is `external`: the self-call is a real CALL, not an internal jump.
- `isAllowed` defaults to **true**. The receiver is a full-power account; the merkle policy
  is an opt-in restriction rather than a safety baseline.
- `ReentrancyGuardUpgradeable`: the storage version, not the transient one, because
  `TSTORE` needs Cancun and the build is pinned to `paris` for CREATE2 parity. Initialized
  in `initialize`, since a proxy runs no constructor of its own. Guards the inbound handler,
  `finalize`, and `execute` under one lock.
- `receive()`: payloads spend native from a pre-funded balance rather than value
  delivered with the message: the address is deterministic and fundable before the
  receiver exists, and a payload that fails for want of funds becomes "top it up and
  retry" rather than a loss.

### Envelope

- `encodeBootstrap` / `decodeBootstrap`: `(address transmitter, Call[] calls)`.
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
  wait carries a self-call to `commit` and says so itself.
- **A receiver's only outbound is its own address**, reported through its parent transceiver
  during `initialize`.
- **`Call[]` vs `bytes[]` is settled: the form follows the destination.** An EVM
  destination always gets `abi.encode(Call[])`; every other VM always gets opaque
  `bytes[]`. **There is no form tag**: the sender picks by destination chain type and the
  receiver decodes the one shape its own VM implies, so every channel still carries exactly
  one shape and `Envelope`'s no-tag rule holds throughout the protocol.
  The **receiver's entry point is `Call[]` only**, as is `TransmitterBase.execute`.
  `bytes[]` remains the canonical commitment form and the only form a non-EVM destination receives,
  and `commit`/`commitTo` keep both overloads because they approve payloads for
  destinations this chain cannot execute on. The two encodings commit to one hash, so an
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
  The correlation an id would provide is already implied: the slot is derived from
  `(chainKey, transmitter)`, the chainKey comes from `_authenticateOrigin`, and the
  transmitter is stated in the report, so a destination cannot choose which slot it writes.
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
  `TransmitterBase.cancel` covers the local receiver, and `cancellationCall` builds the
  element for a remote one, which needs the transport rewrite to cross, since a `bytes32`
  wire cannot express "cancel index N" without a message-type tag.
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
