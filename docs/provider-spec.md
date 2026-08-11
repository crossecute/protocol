# Message provider compliance

What a message provider binding must implement to be a first-class transport for this
protocol, and what the provider protocol itself must be capable of before a binding is
worth writing.

[`message-flow.md`](message-flow.md) describes the two paths and
[`encoding.md`](encoding.md) the payload formats. This file is the contract between those
designs and a transport: everything a binding MUST satisfy, everything it MUST NOT do, and
the fixed set of tests that decide whether it did.

**The core contracts now speak ERC-7786 directly.** `TransmitterBase` is an
`IERC7786GatewaySource` and `ReceiverBase` an `IERC7786Recipient`, so a binding attaches a
GATEWAY rather than translating a bespoke send. That narrows what a binding is, and several
rules below narrowed with it; [§13](#13-appendix-erc-7786-as-a-transport) records what the
standard gives up in exchange.

Nothing here is LayerZero-specific. LayerZero is used for worked examples because it is the
first binding, and its findings are recorded in [`todo.md`](todo.md#2-the-provider-binding).

Keywords MUST, MUST NOT, SHOULD and MAY are used in the RFC 2119 sense.

---

## 1. Terms

| Term | Meaning |
| --- | --- |
| **provider** | The third-party transport: LayerZero, Hyperlane, Wormhole, CCIP, Axelar. |
| **binding** | The contracts in this repo that attach a provider to the protocol. |
| **account** | A `CrossProxy` at `keccak256(abi.encode(owner, salt))`: a transmitter at home, a receiver everywhere else. One address on every parity chain. |
| **transceiver** | The shared msig-owned contract, one per provider per chain. Hub at home, spoke elsewhere. |
| **route** | The provider's own name for a chain, opaque `bytes`: an eid, a domain, a chain id, a selector, a name string. |
| **counterpart** | The address of the transceiver on the other chain, in that chain's own format. |
| **chainKey** | `keccak256(canonical ERC-7930 chain identifier)`. The protocol's only chain name. |

**Two channels, and both are the binding's responsibility.**

- **Path A**, the steady state: account to its own account, direct. The transceiver is not
  in this path. Every account is therefore its own provider endpoint.
- **Path B**, bootstrap: hub transceiver to spoke transceiver, once per (account, chain),
  plus the spoke's report back. The transceiver is the endpoint here.

That is why a binding is four concrete contracts and not one adapter: the endpoint role
lands on the transmitter, the receiver, the hub transceiver, and the spoke transceiver
independently.

---

## 2. Provider prerequisites: the go or no-go checklist

Before any code is written, the provider must be able to do all fourteen of these. A "no"
on any of P1 through P10 disqualifies the provider outright; P11 through P14 are costs
rather than blockers, and each has a stated fallback.

| # | Requirement | Why the protocol needs it |
| --- | --- | --- |
| **P1** | Carry an arbitrary `bytes` body, sender-chosen, no schema imposed | `_sendMessage` is the only send primitive and it carries `bytes`. Payloads, bootstrap envelopes, and reports all use it. |
| **P2** | Any contract may be its own endpoint, permissionlessly | Path A is account to account. If receiving requires provider governance to whitelist an address, every user's account needs an approval and the protocol does not work. |
| **P3** | Deliver to an address the sender chose, not one the provider assigns | The account address is fixed by CREATE2 before the account exists. A provider that mints or assigns the destination address breaks address parity, which is the whole product. |
| **P4** | Report the source chain and source address to the receiving contract | `_onInbound(route, sender, message)` cannot authenticate without both. A provider that reports only "some peer" is not authenticable at our layer. |
| **P5** | Unordered delivery | Ordered lanes turn one permanently-failing message into a halt on that lane. See [Failure handling](message-flow.md#failure-handling). |
| **P6** | Permissionless retry of a failed message | Execution runs inside the delivery callback, so a revert must be a retry and not a loss. |
| **P7** | **Exactly-once execution of a message that succeeded** | Path A runs a call array on arrival with no commitment, no nonce, and no id of its own, so a second delivery would run the payload a second time. Nothing in this repo prevents that, and the transport is the only layer that can. It composes with P6 rather than fighting it: mark consumed, then call the receiver with a plain external call, so a success is terminal and a revert rolls the mark back. See [R3.5](#r3-receive) and [§12](#12-appendix-transport-replay-guarantees). |
| **P8** | Fee payable at source in native currency, from `msg.value` | Signers transact only at home. A provider requiring a fee token per chain reintroduces the funding matrix the protocol exists to remove. |
| **P9** | **Quote that fee at source, as a `view`, before the send** | The fee is not knowable off-chain from first principles: it depends on payload length, destination gas, and the provider's own price feed. Without a quote a caller either overpays blindly or has a send revert after the signers have already approved it. See [R2](#r2-quote). |
| **P10** | No deployment-time registration that changes an address | Anything requiring the account to be deployed by a provider factory, or to hold a provider-issued id in its initcode, moves the address and breaks parity. Implementation-level immutables are fine: they never reach `CrossProxy`'s initcode. |
| **P11** | Send from inside a delivery callback, funded from contract balance | The spoke's receiver report is sent from inside the bootstrap callback where `msg.value` is zero. Fallback: the report is sent in a separate transaction by a relayer, which weakens the bootstrap to two steps. |
| **P12** | Per-message destination gas or execution options | Carried as ERC-7786 `attributes`. Fallback: the binding hard-codes a default and payloads above it fail on arrival. |
| **P13** | Support for the target chain set, including the non-EVM ones in scope | A provider that reaches only EVM chains is usable, but the Move, Solana, and Starknet work in [`todo.md`](todo.md#3-blockers-on-specific-paths) stays blocked on a second provider. |
| **P14** | An upgradeable-safe SDK: namespaced storage, no constructor-only state on the proxy | Accounts are proxies and transceivers are proxies. An SDK that stores in sequential slots forces a layout freeze on every contract it mixes into. |

**Prefer a provider's native SDK over its ERC-7786 gateway, where it offers both.** A
gateway satisfies P1 through P4 cleanly and would be less code, but ERC-7786 defines no
quote at all, so P9 fails outright and the entire quote surface goes dead for that binding.
See [§13](#13-appendix-erc-7786-as-a-transport) for how a 7786 binding would map and what
else it gives up.

**P2 and P3 together are the real filter.** They are what "an account is its own endpoint"
means, and they are the claim the entire redesign rests on. Verify them against the
provider's actual code, not its documentation, before writing anything else.

Every provider in scope satisfies P9 today: LayerZero's `endpoint.quote(MessagingParams,
address) -> MessagingFee`, Hyperlane's `quoteDispatch`, CCIP's `getFee`, Wormhole's
`quoteEVMDeliveryPrice`, Axelar's off-chain gas estimator with an on-chain equivalent. All
but Axelar's are `view`.

---

## 3. The contract set

A binding is five or six files under `src/protocols/<provider>/`. Naming follows the
existing LayerZero skeleton.

| File | Extends | Role |
| --- | --- | --- |
| `<P>Codec.sol` | library | The one place the provider's chain id has a Solidity type. **Only where one survives**: under ERC-7786 the route slot holds a chain identifier, so a gateway binding has no provider-native id to type and no codec. See [§10](#10-worked-skeleton-an-erc-7786-gateway-binding). |
| `<P>Endpoint.sol` | abstract | Shared send, quote, and receive plumbing, mixed into the four below. |
| `<P>Transmitter.sol` | `TransmitterBase`, `<P>Endpoint` | The per-user account at home. Sends on path A. |
| `<P>Receiver.sol` | `ReceiverBase`, `<P>Endpoint` | The per-user account on a spoke. Receives on path A. |
| `<P>HubTransceiver.sol` | `HubTransceiverBase`, `<P>Endpoint` | Sends bootstrap, receives reports. |
| `<P>SpokeTransceiver.sol` | `SpokeTransceiverBase`, `<P>Endpoint` | Receives bootstrap, sends the report. |

**`<P>Endpoint` is not optional structure, it is the deduplication that keeps the four in
agreement.** Fee handling, attribute decoding, the recipient byte form, and the sender byte
form must be identical across all four or authentication silently diverges between path A
and path B, and a quote stops predicting its own send. Writing them once is what makes that
structural. It declares no storage of its own beyond what the SDK brings.

---

## 4. The seams

Every abstract or virtual member a binding must answer, and where.

### 4.1 Required on all four contracts

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_sendMessage(bytes recipient, bytes payload, bytes[] attributes)` | `OutboundBase` | MUST override, returning the gateway's `sendId`. The default reverts `SendNotImplemented`. See [R1](#r1-send). |
| `_quoteMessage(bytes recipient, bytes payload, bytes[] attributes)` | `OutboundBase` | MUST override, `view`, same arguments as the send. The default reverts `QuoteNotImplemented`. See [R2](#r2-quote). |
| the provider's inbound callback | the SDK | MUST route into exactly one protocol funnel and nothing else. See [R3](#r3-receive). |

### 4.2 Required on the transmitter

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_owner()` | `TransmitterBase._owner` | Answer from the SDK's own ownership if it brings one, otherwise from `OwnableUpgradeable`. |
| `_checkOwner()` | `TransmitterBase._checkOwner` | Same. Note `TransmitterBase` uses `onlyAccountOwner`, not `onlyOwner`, precisely so an SDK's `onlyOwner` does not collide. |
| `initialize(address owner, address transceiver, bytes32 salt)` | `ITransmitterInit`, in `HubTransceiverBase.sol` | MUST exist with that exact signature, or the hub's `_accountInitializer` MUST be overridden to encode a different one. |

### 4.3 Required on the receiver

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `initialize(...)` | `IReceiverInit`, in `ReceiverBase.sol` | Declare a binding-specific one, do provider setup, then call `__ReceiverBase_init` LAST so the bootstrap payload runs against a configured provider. Never `super.initialize`. |
| an owner or delegate | none today | If the SDK needs an owner-gated config surface on the account, the receiver's initializer MUST carry the owner. `_accountInitializer` is `virtual` on the spoke for exactly this. |
| nothing else | | A binding MUST NOT expect the transceiver to reach a receiver after creation. `commit`, `cancel`, and `execute` are gated on the transmitter alone; the initializer is the transceiver's only call, ever. |

### 4.4 Required on the hub transceiver

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_checkAdmin()` | `TransceiverBase._checkAdmin` | Answer from the SDK's ownership, or from `OwnableUpgradeable`. MUST NOT introduce a second authority: two owners on one transceiver means an upgrade lock held by one can be undone through the other. |
| `_accountInitializer(owner, salt, calls)` | `TransceiverBase._accountInitializer` | Override to fold provider setup into the transmitter's initializer. There is no second chance: `CrossProxy` locks in the same call that arms it. |
| nothing for routing | | The base's `setRoute(chainKey, identifier)` is already typed for what a route now holds, and `routeFor` / `chainKeyOfRoute` / `hasRoute` / `routeTo` are the reads. A binding adds a typed wrapper only if it keeps a provider-native value of its own; a gateway binding adds nothing, which is what `LzHubTransceiver` demonstrates by carrying no provider vocabulary at all. |

### 4.5 Required on the spoke transceiver

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_checkAdmin()` | `TransceiverBase._checkAdmin` | As above. |
| `_accountInitializer(owner, salt, calls)` | `SpokeTransceiverBase._accountInitializer` | Override to fold provider setup into the receiver's initializer, and to carry the owner if the SDK needs one. |
| `initialize(...)` | convention | MUST pass the home chainKey, the home chain identifier, the hub's address, and `addressesDiverge` into `__SpokeTransceiverBase_init`, in the byte forms [R4](#r4-the-byte-forms-which-are-the-authentication) requires. Where a provider-native value survives, it goes through the codec first. |
| the receiver report | `_reportReceiver`, in the base | Nothing to override. The base sends it from `bootstrapInbound` when `addressesDiverge` is set, through the same `_sendMessage` the binding already implements. What a binding owes it is [R7.3](#r7-fees-and-value): the nested send is funded from contract balance. See [§9.3](#93-the-receiver-report-landed-gated-on-a-flag). |

### 4.6 Deliberately absent

A binding MUST NOT expect any of these, and MUST NOT add them.

- **No authentication seam.** `_authenticateOrigin` is answered by
  `HubTransceiverBase._authenticateOrigin` and `SpokeTransceiverBase._authenticateOrigin`, not by a binding. This is
  deliberate: a transceiver decides which cross-chain payloads are authentic, and leaving
  that per provider is how one provider ships without it.
- **No message-type seam.** Direction is the discriminant. Each channel carries one shape.
- **No registry pointer on an account.** A transmitter holds no registry and knows no
  routes, by design. It resolves through its transceiver: see [R1](#r1-send).
- **No provenance seam.** Grading is the registry's, applied at the hub.

---

## 5. Normative rules

### R1. Send

`_sendMessage` MUST put `payload` on the wire addressed to `recipient`, and MUST revert if
it cannot. It MUST return the gateway's `sendId`, and MUST NOT discard a non-zero one
silently: a non-zero id means the gateway has further, unstandardised work to do before the
message is away, so a binding either performs that second step or refuses gateways that need
one, and says which in its NatSpec.

**R1.1 The recipient arrives built, and the binding MUST NOT re-derive it.** It is a
binary interoperable address naming its own chain, so there is no chain id to resolve and
no route table to consult inside `_sendMessage`. The route table still exists, but it holds
each chain's ERC-7930 IDENTIFIER now rather than a provider's private id, and it is read by
`TransceiverBase._recipientOn` on the way in.

**R1.2** An account MUST NOT hold a route table of its own: a user adding a destination is
a msig configuration change, not a per-account migration. `IAccountTransceiver.routeTo` is
the read, on the transceiver an account already stores.

**R1.3** The destination on path A is this account's own address, and `TransmitterBase`
already enforces it on `eip155` recipients. A binding MUST NOT store a peer to reach that
answer when the SDK allows it to be derived; where the SDK insists on a peer table, the
binding SHOULD override the lookup to return `address(this)` unconditionally. A value with
exactly one correct answer is not configuration, and storing it creates a state in which it
can be wrong.

**R1.4** The recipient on path B is built by `_recipientOn(chainKey)` from the route and
`_counterpartOn`. A binding MUST NOT assume the address half is 20 bytes without checking
the chain type.

**R1.5** `attributes` are decoded only inside the binding, and an empty array MUST mean
"the gateway's default" rather than zero gas. A binding MUST answer `supportsAttribute`
honestly, and a gateway that refuses an attribute it does not know is behaving correctly.

**R1.6** A send to an unconfigured destination MUST revert, not succeed. `routeFor` reverts
`NoRouteFor` and `_requireBootstrapped` reverts `NotBootstrapped`; a binding that catches
either and falls back is non-compliant.

**R1.7** Path A is reachable only after path B has run for that destination.
`TransmitterBase` refuses a send to a chainKey it has not recorded a bootstrap for, and
refuses a second bootstrap to one it has. A binding inherits both gates and MUST NOT add a
send entry point that bypasses them: the peer address on an un-bootstrapped chain holds no
code, so such a send is a fee spent on a message that cannot be delivered.

### R2. Quote

Every send has a fee, and the fee is not derivable off-chain from first principles: it is a
function of the payload's exact bytes, the destination gas the payload needs, and the
provider's own price feed at that block. A caller therefore needs to ask.

**R2.1 The seam.** `_quoteMessage` MUST be overridden alongside `_sendMessage` and MUST
mirror it exactly:

```solidity
/// @notice What `_sendMessage` would cost, in this chain's native currency.
function _quoteMessage(
    bytes memory recipient,
    bytes memory payload,
    bytes[] memory attributes
) internal view virtual returns (uint256 nativeFee) {
    revert QuoteNotImplemented();
}
```

**R2.2 It MUST be `view`.** A quote that writes state cannot be called from an off-chain
`eth_call` in the same block as the send it prices, which is the only way it is ever used.
A provider whose quote is not `view` fails [P9](#2-provider-prerequisites-the-go-or-no-go-checklist)
and the binding MUST document the fallback rather than making the seam non-view: making
`_quoteMessage` mutable would force the whole read surface below to be mutable too, and a
`quoteMessage` that cannot be `eth_call`ed is not a quote.

**R2.2.1 A binding MUST NOT try to derive the fee by simulating its own send, and it could
not if it tried.** The idea is the obvious one and it fails for three independent reasons,
recorded here so nobody rediscovers them:

- `STATICCALL` forbids `LOG`, and every send emits. ERC-7786 requires a `MessageSent`
  event and every native SDK logs too, so the simulation reverts at the first log, before
  reaching anything worth reading.
- `STATICCALL` cannot carry value, so a fee-taking send cannot be simulated at all. The
  question becomes "does this succeed with nothing attached", whose answer is always no.
- There is nothing to read even if it ran. A send returns a message id, not a price. It
  CONSUMES `msg.value`; it never computes a number to hand back.

The mutating variant (perform the send, revert with the answer, call it through `eth_call`
so the state change is discarded) is a real pattern and is how Uniswap's quoter works. It
is still refused here. It requires the gateway to reveal the fee somehow, it needs a
balance override to fund the simulation, and it would make the whole read surface above
non-view, which is the property R2.2 exists to protect.

**R2.2.2 Where a provider offers no quote, the fallback is off-chain, and it MEASURES
rather than searches.** The constraints in R2.2.1 are the EVM's static context, and a
simulator is not bound by them. A Foundry fork test or script can call the REAL send,
overfunded, against the real endpoint, and read the exact net cost off the balance delta:

```solidity
uint256 snap = vm.snapshotState();
vm.deal(owner, 100 ether);
uint256 before = owner.balance;

bytes memory recipient = transmitter.recipientOn(destinationChainId);
bytes memory payload = transmitter.payloadForCalls(calls);

vm.prank(owner);
transmitter.sendMessage{value: 100 ether}(recipient, payload, attributes);

uint256 fee = before - owner.balance;   // charged minus refunded, exactly
vm.revertToState(snap);
```

That is one call and an exact number, not a bound from bisection, because the refund lands
back on `_refundTo()` and the delta is therefore the net. It cannot be exposed through
`quoteMessage`, since the on-chain constraints still hold, so it belongs in `script/` and
in the compliance suite rather than in the contracts.

The same measurement answers two other open questions, and should be written once and
reused: it is how [C11](#8-the-compliance-suite) checks that a quote equals what the send
actually consumes, and it is how an operator sizes the balance a diverging spoke needs for
its return report under [R7.5](#r7-fees-and-value).

A binding whose provider has no quote MUST say so in the NatSpec of the `_quoteMessage`
that reverts `QuoteNotImplemented`, and point at the script that measures instead.

Note also the cheaper mitigation, which is why a missing quote is a cost rather than a
disqualification: if the provider refunds excess reliably, a caller can simply overpay and
let [`_refundTo`](#r7-fees-and-value) return the difference. A quote buys capital
efficiency and a failure that happens before the signers commit, not correctness.

**R2.3 It MUST price the exact bytes the send would carry.** The quote is taken over
`Payload.encodeCalls(calls)` or `Envelope.encodeBootstrap(owner, salt, calls)`, the same
function `sendMessage` puts on the wire, not over an estimate of the length. Every provider prices
per byte. This is what makes a quote a number a caller can send rather than a number a
caller must pad, and it is why the public surface below takes exactly `sendMessage`'s
arguments.

**R2.4 It MUST use the same route, destination, and options resolution as the send.** Any
divergence between `_quoteMessage` and `_sendMessage` is a quote that prices a different
message than the one that goes out. In practice this means both call one shared internal
helper for recipient construction and one for attribute decoding, which is
[§3](#3-the-contract-set)'s argument for `<P>Endpoint` restated.

**R2.5 It MUST revert exactly where the send would.** An unconfigured route, an
unroutable destination, or a counterpart below the provenance bar MUST fail the quote too.
A quote that succeeds where the send fails tells a caller the operation is ready when it is
not, which is worse than no quote at all.

**R2.6 It MUST NOT be consulted by `_sendMessage`.** The quote is advisory. Making a send
call its own quote and compare doubles the provider round trip on every message, and turns
a price that moved between quote and send into a revert rather than into the provider's own
refund. Excess `msg.value` is refunded per [R7.2](#r7-fees-and-value); shortfall is the
provider's revert to raise.

**R2.7 It MUST NOT be cached on-chain.** A stored quote is a stale quote.

**R2.8 The native fee MUST be the whole answer.** Where a provider supports paying in its
own token (LayerZero's `lzTokenFee`), the binding MUST quote the native-only path, because
the protocol's funding model is native currency at home. A binding MAY expose a second,
clearly-named function for the token path; the compliance surface below is native.

**The public read surface is one function.** ERC-7786 gives the send a single shape, so the
quote has one too:

```solidity
/// @notice What `sendMessage` would cost, in this chain's native currency.
/// @dev Its arguments are `sendMessage`'s, minus the value. A caller builds the recipient
///      and the payload once, prices them, and sends the same three arguments with the
///      answer attached.
function quoteMessage(
    bytes calldata recipient,
    bytes calldata payload,
    bytes[] calldata attributes
) external view returns (uint256 nativeFee);
```

It carries the same gates the send does, for the reason in R2.5: an unbootstrapped
destination and a recipient that is not this account fail here too. It is ungated, unlike
the send, because a signer reviewing a payload before the owner submits it has to be able
to call it.

`quoteBootstrap` and `quoteBootstrapTo` remain in their `Call[]` and `bytes[]` forms,
because path B's envelope is built by the transceiver rather than handed to it.

**The transceiver's quote.** `TransceiverBase` MUST expose the path B quote it is asked
for, matching its `bootstrap` and `bootstrapElements` entry points:

```solidity
function quoteBootstrap(
    bytes32 destinationChainKey,
    address owner,
    bytes32 salt,
    Call[] calldata calls,
    bytes[] calldata attributes
) external view returns (uint256 nativeFee);
```

It MUST apply `_requireRoutable` first, exactly as `bootstrap` does, so the provenance bar
is enforced identically on the quote and on the send ([R2.5](#r2-quote)). It MUST NOT
apply `bootstrap`'s `predictCrossAccount(owner, salt) == msg.sender` check: a quote is
taken by a UI or a signer before the account exists, and gating it on being the account
would make it uncallable in exactly the case it is needed. The check protects the send from
standing up somebody else's account, and there is nothing to protect on a `view`.

### R3. Receive

The provider's delivery callback MUST route into exactly one funnel per contract, and MUST
do nothing else with the message.

| Contract | Entry point | Then |
| --- | --- | --- |
| receiver | `receiveMessage(receiveId, sender, payload)` | `_onMessage(payload)`, after both checks below |
| transceiver (hub or spoke) | the binding's callback | `_onInbound(route, sender, message)` |
| transmitter | none | MUST revert |

**R3.0 `ReceiverBase.receiveMessage` is `external`, so it carries its own gate.** Two
checks, and they are not the same check. `_isAuthorizedGateway(msg.sender)` says the
message came through transport this account trusts, and is the binding's to answer. The
sender's address must equal `address(this)`, which says it came from THIS account on the
other side; that one needs no configuration and is therefore answered in the base. An
honest but shared gateway would otherwise let one account's payload land in another's
receiver.

**R3.1 The transmitter MUST reject inbound messages.** There is no path in which a
transmitter receives. If the SDK's base contract provides a receive entry point, the
binding MUST override it to revert. A transmitter that could receive would make the hub
start seeing commitments as well as reports, which is the exact condition under which
`Envelope`'s no-tag property fails and a wrong-shape decode becomes a silent misread rather
than a revert.

**R3.2 The binding MUST NOT authenticate in place of `_onInbound`.** Translating the SDK's
callback into three arguments is the binding's entire inbound job. Any check the binding
performs is additive.

**R3.3 An SDK that authenticates before our code runs is acceptable and MUST be
documented.** LayerZero's `lzReceive` checks `msg.sender == endpoint` and then
`peer[srcEid] == origin.sender` before `_lzReceive` is reached. For a 1:1 pairing there is
nothing extra to verify, so this is defensible, but it contradicts the rule stated in
`TransceiverBase._onInbound` and MUST appear as a written exception in the binding's NatSpec
rather than as an omission. This is [todo §4](todo.md#4-decisions-taken-that-deserve-a-second-look),
still open.

**R3.4** The receiver's funnel is `_onMessage`, which is `nonReentrant` and executes on
arrival. The binding MUST NOT decode the payload itself: `Payload.decodeCalls` happens
inside `_onMessage`, so every provider gets the same decoder and the same failure mode.

**R3.5 Replay protection on path A is the transport's, and a binding whose transport does
not provide it MUST supply it.** This is the one protocol-level guarantee that is imported
rather than enforced here, and it is worth stating precisely because it is invisible in
this repo's source.

An execute-on-arrival payload carries no commitment and no identifier, so a second delivery
of the same message runs it again. Bootstrap and the receiver report are both structurally
single-shot and need nothing (`CrossProxy` arms exactly once, `initialize` is single-shot,
and the registry slot is write-once), but path A has no such property, and it is the path
every message after the first takes.

Four of the five providers in scope already guarantee it at the transport, and the
binding does nothing. Wormhole's core layer does not, and there a binding MUST dedupe
inside `<P>Endpoint` before reaching `_onMessage`, keyed on the VAA digest or on
`(emitterChain, emitterAddress, sequence)`. See [§12](#12-appendix-transport-replay-guarantees)
for what each provider actually does.

**R3.6 The dedupe MUST be per receiving account, not global to the binding.** Accounts are
their own endpoints, so one account's replay record must not be exhaustible by another's
traffic. Every transport that provides this already keys it correctly (LayerZero by
`[receiver][srcEid][sender][nonce]`, Hyperlane by a message id covering the recipient); a
binding supplying its own MUST match that shape.

**R3.7 A binding MUST NOT swallow a failing delivery**, with `try/catch` or otherwise. The
retry property in P6 exists because the mark-consumed write is rolled back by the same
revert that failed the payload. Catching the failure would consume the message and drop the
payload, converting a retry into a loss. `_execute` being all-or-nothing is the other half
of that: a partially applied payload could not be safely retried.

### R4. The byte forms, which are the authentication

This is the rule most likely to be got wrong, and it fails at runtime rather than at
compile time.

**R4.1** The `route` bytes passed to `_onInbound` MUST be byte-identical to what `setRoute`
stored for that chain. `chainKeyOfRoute` keys on `keccak256(route)`, so a one-byte
difference is an `UnknownRoute` revert. The binding MUST produce both directions from the
same codec function. Never hand-encode at one end.

**R4.2** The `sender` bytes MUST be byte-identical to what the counterpart lookup returns.
For an EVM counterpart that is 20 raw bytes: `ChainRegistry.defaultCounterpart` returns
`abi.encodePacked(address)` and `transceiverFor` returns
`Erc7930.parseStrict(r.interop).addr`, both 20 bytes. A provider reporting a 32-byte
left-padded sender MUST be narrowed by the binding.

```solidity
// WRONG: 32 bytes, will never equal the registry's 20.
bytes memory sender = abi.encode(origin.sender);

// RIGHT: the same 20 raw bytes the registry stores.
bytes memory sender = abi.encodePacked(address(uint160(uint256(origin.sender))));
```

**R4.3** The narrowing MUST reject a non-EVM sender rather than truncate one. A 32-byte
Solana pubkey cast down to 20 bytes is a forgery primitive, not a formatting bug.

**R4.4** A spoke's `_homeTransceiver` is written once at initialization with no setter. The
deployment MUST pass it in the same byte form the binding will produce inbound. There is no
way to fix a mistake here: see [todo §4](todo.md#4-decisions-taken-that-deserve-a-second-look)
on write-once having no recovery path.

### R5. The route codec

**R5.1** The route MUST be encoded with fixed-width `abi.encode`, never `encodePacked`. The
registry and the transceiver hold a LayerZero `uint32`, a Hyperlane `uint32`, a Wormhole
`uint16`, and a CCIP `uint64` in the same `bytes` slot, so the width has to travel with the
value. A value configured at the wrong width MUST fail loudly in `abi.decode` rather than
silently reinterpret. Under ERC-7786 the route holds a chain's ERC-7930 identifier rather
than a provider id, so this rule now binds only where a binding keeps a provider-native
value of its own.

**R5.2** The provider's native type MUST appear in exactly two places: the codec library
and the typed setters that wrap it. It MUST NOT appear in any base contract, in the
registry, or in an account's storage.

**R5.3** The codec MUST be a pure library with no storage and no owner.

### R6. Account initialization

**R6.1** Everything the provider needs configured on an account MUST be folded into
`_accountInitializer`. A transceiver has no authority over an account after creating it:
`CrossProxy` upgrades, initializes, and zeroes its own admin in one call, and the account's
own configuration is gated on its owner, which the transceiver is not.

**R6.2** The initializer MUST configure the provider before the bootstrap payload runs. A
payload can itself send, and it can call arbitrary targets.

**R6.3** The reentrancy guard MUST be initialized first, before any provider call and
before the payload. A proxy runs no constructor, so the guard is uninitialized until that
line.

**R6.4** A binding SHOULD account for the per-account provider cost and state it.
LayerZero's `__OAppCore_init` calls `endpoint.setDelegate`, so every account creation
touches the endpoint. That is real gas on the bootstrap path and the concrete form of
"peers and send-side security configuration are per-user rather than shared". It is also a
cost the bootstrap quote must include, which is [R2.3](#r2-quote) applied to path B.

### R7. Fees and value

**R7.1** Every protocol entry point that reaches `_sendMessage` is already `payable`. The
binding reads `msg.value` and pays the provider from it.

**R7.2** Refunding the excess is the binding's job, because only the binding knows the
provider's refund convention. The address it refunds to is NOT the binding's choice: it
MUST be `OutboundBase._refundTo()`, which is `msg.sender`, and a binding MUST NOT read a
refund address out of the attributes or substitute one of its own.

The rule is one sentence: a fee is overpaid by whoever paid it, so the remainder goes back
to the party that sent the value. It resolves correctly on both paths without anything
being threaded through the call stack. On path A `sendMessage` is `onlyAccountOwner`, so
`msg.sender` is the wallet that signed and funded the message. On path B `bootstrap`
refuses any caller that is not `predictCrossAccount(owner, salt)`, so `msg.sender` is the
ACCOUNT, and the transceiver is structurally incapable of being its own refund target: it
is never the caller of its own `bootstrap`. A shared transceiver refunding to
`address(this)` would pool every user's excess into infrastructure with no per-user way
out, and this is the arrangement under which that cannot be written by accident.

Both halves of an account declare `receive`, which on `TransmitterBase` is load-bearing
rather than decorative: a provider's refund is a plain value transfer, and one to a
contract that cannot accept it reverts the send that earned it.

**R7.3** A nested send (the receiver report, sent from inside a delivery callback) has
`msg.value == 0` and MUST be funded from the sending contract's balance. A binding whose
provider cannot do this MUST say so and the report path MUST fall back to a separately
funded transaction. This is the top blocker on the report path in
[todo §3](todo.md#3-blockers-on-specific-paths).

**R7.4** `bootstrap` forwards the whole `msg.value` to the transceiver. A binding MUST NOT
retain a remainder there.

**R7.5** Where the report is sent from a contract balance, the binding SHOULD expose the
report's own quote so an operator can size that balance. A spoke that runs dry fails every
bootstrap on its chain at the return leg, and the failure is invisible from home until
someone reads the registry and finds the slot unresolved.

### R8. Storage and address parity

**R8.1** The binding MUST NOT add constructor arguments to `CrossProxy`. Its initcode is one
constant byte string and every account address on every chain depends on it. Provider state
belongs on the implementation, where an `immutable` never reaches the proxy's initcode. A
per-chain endpoint address is exactly what an implementation-level immutable is for.

**R8.2** The SDK's storage MUST be ERC-7201 namespaced, or the binding MUST pin the
inheritance order and document the resulting layout. There are no storage gaps anywhere in
this codebase ([todo §5](todo.md#5-smaller-open-questions)), so a binding that appends
sequential slots to a base freezes that base's layout.

**R8.3** The binding MUST NOT change `CROSS_PROXY_INIT_CODE_HASH`, and MUST NOT change
compiler settings. `bytecode_hash = "none"` and `cbor_metadata = false` are pinned in
`foundry.toml` because solc's default trailer carries an IPFS hash of the source, comments
included, which would otherwise put every derived address one comment edit away from moving.

**R8.4** `ChainRegistry.setProviderDeployment`'s `accountInitCodeHash` MUST equal
`TransceiverBase.CROSS_PROXY_INIT_CODE_HASH`. A binding's deploy script MUST assert this
rather than transcribe it.

### R9. Write-once discipline

**R9.1** The binding MUST NOT add a setter for any value the base makes write-once:
`setRoute`, `setTransceiverId`, `setProviderDeployment`, `receiverImplementation`,
`transmitterImplementation`, `homeChainKey`, `homeRoute`, `homeTransceiver`, a resolved ref
slot.

**R9.2** A typed wrapper around a write-once setter is the
correct shape and inherits the write-once behavior. It MUST NOT add its own storage.

**R9.3** The binding MUST NOT expose an upgrade path that survives `lockUpgrades`. If the
SDK carries its own upgrade mechanism, the binding MUST disable it.

---

## 6. Configuration a compliant deployment performs

A binding is not compliant until its deployment story is expressible. In order, on the home
chain unless noted:

| # | Call | Notes |
| --- | --- | --- |
| 1 | `ChainRegistry.addChainKey(identifier)` | Per chain, canonical ERC-7930. |
| 2 | `ChainRegistry.addMessageProvider(name)` | The `bytes32` is `keccak256(name)`. |
| 3 | Deploy the hub transceiver proxy through the CREATE2 factory, upgrade, `initialize` | Proxy initcode must be identical on every chain. |
| 4 | Deploy each spoke transceiver the same way, `initialize` with home chainKey, home route, hub address | Every spoke in one deployment MUST be given the SAME home. Nothing on-chain cross-checks this, because a spoke has no view of its siblings. The deploy script is the only place it can be enforced. |
| 5 | `ChainRegistry.setLocalTransceiver(provider, hub)` | Also authorizes the hub as the only caller of `onForeignRefResolved` for that provider. |
| 6 | `ChainRegistry.setProviderDeployment(provider, salt, transceiverInitCodeHash, accountInitCodeHash)` | Write-once. `accountInitCodeHash` per [R8.4](#r8-storage-and-address-parity). |
| 7 | `<P>HubTransceiver.setRoute(chainKey, identifier)` per destination | Write-once, injective, and the identifier must hash to the chainKey. |
| 8 | `ChainRegistry.setCreate2Factory(chainKey, factory)` for zk-chains | Defaults to Arachnid's. |
| 9 | `ChainRegistry.setMaxProvenance(chainKey, cap)` for chains whose addresses cannot be recomputed here | zkSync and Tron are `eip155` with different CREATE2 formulas; capping below `Derived` is what withdraws the default counterpart. |
| 10 | `ChainRegistry.setTransceiverId` plus a resolution for any chain with no derivable counterpart | The exception path. Most EVM chains need neither. |
| 11 | `<P>HubTransceiver.setRouting(registry, provider, minCounterpartProvenance)` | The provenance dial. |
| 12 | Fund each spoke transceiver for its return reports | Sized from [R7.5](#r7-fees-and-value)'s quote, on the chains where the report is used. |
| 13 | `lockUpgrades()` on every transceiver | Irreversible, and the point of the whole proxy dance. |

There is no `script/` directory yet ([todo §6](todo.md#6-infrastructure-none-of-it-exists)).
The first binding writes it, and the ordering above is its specification.

---

## 7. Prohibitions

Collected, because each of these is individually tempting.

1. **No authentication in the binding** in place of `_onInbound`. ([R3.2](#r3-receive))
2. **No inbound path to a transmitter.** ([R3.1](#r3-receive))
3. **No message-type tag**, and no second shape on an existing channel. Direction is the
   discriminant, and that holds only while transmitters live at home only.
4. **No registry read from an account.** The chainKey derivation is pure; keeping the
   directory dependency on one contract on one chain is what makes a transmitter a pure
   commit-and-forward contract.
5. **No provider id outside the codec.** ([R5.2](#r5-the-route-codec))
6. **No new write-once setters.** ([R9.1](#r9-write-once-discipline))
7. **No second ownership authority** on a transceiver or an account. ([§4.4](#44-required-on-the-hub-transceiver))
8. **No silent send.** `_sendMessage` either delivers to the provider or reverts.
9. **No `encodePacked` on a route.** ([R5.1](#r5-the-route-codec))
10. **No constructor arguments on `CrossProxy`,** and no compiler settings change. ([R8.1](#r8-storage-and-address-parity), [R8.3](#r8-storage-and-address-parity))
11. **No truncation of a wide sender.** ([R4.3](#r4-the-byte-forms-which-are-the-authentication))
12. **No ordered lanes.** ([P5](#2-provider-prerequisites-the-go-or-no-go-checklist))
13. **No quote inside a send,** no cached quote, and no quote that prices anything but the
    exact bytes its twin would send. ([R2.3](#r2-quote), [R2.6](#r2-quote), [R2.7](#r2-quote))

---

## 8. The compliance suite

A binding is compliant when it passes `test/compliance/ProviderCompliance.t.sol`, an
abstract test contract that every binding inherits and parameterizes with its own four
contracts. This does not exist yet and is part of the first binding's work.

The abstract harness declares:

```solidity
abstract contract ProviderCompliance is Test {
    function deployHub() internal virtual returns (address);
    function deploySpoke(bytes32 homeChainKey, bytes memory homeRoute, bytes memory hub)
        internal virtual returns (address);
    function encodeRoute(uint256 nativeId) internal virtual returns (bytes memory);
    function deliverToTransceiver(address to, bytes memory route, bytes memory sender, bytes memory body)
        internal virtual;
    /// @dev An account is an `IERC7786Recipient`, so its delivery carries a full ERC-7930
    ///      sender envelope rather than a separate route: `receiveMessage` splits it.
    function deliverToAccount(address to, bytes memory sender, bytes memory payload)
        internal virtual;
    /// @dev The fee the mocked provider will charge, so a quote can be asserted against a
    ///      known number rather than against itself.
    function setProviderFee(uint256 nativeFee) internal virtual;
}
```

The `deliver*` hooks are how a binding hands the harness its own provider's callback shape.
Everything below is written once, against those hooks.

| # | Test | Asserts |
| --- | --- | --- |
| C1 | `send_reachesTheProviderWithTheRightRoute` | The provider saw the route `setRoute` stored, byte for byte. |
| C2 | `send_toUnconfiguredDestinationReverts` | `NoRouteFor`, not a default. |
| C3 | `send_addressesTheAccountsOwnAddress` | Path A's destination is `address(this)`. |
| C4 | `inbound_fromTheConfiguredOriginExecutes` | Round trip through `_onInbound`. |
| C5 | `inbound_fromAnUnknownRouteReverts` | `UnknownRoute`. |
| C6 | `inbound_fromTheWrongSenderReverts` | `NotCounterpart` on a hub, `NotHomeOrigin` on a spoke. |
| C7 | `inbound_senderBytesMatchTheRegistryExactly` | The [R4.2](#r4-the-byte-forms-which-are-the-authentication) footgun, directly. |
| C8 | `inbound_routeBytesRoundTripThroughTheCodec` | `chainKeyOfRoute(routeFor(k)) == k` for every configured chain. |
| C9 | `inbound_toATransmitterReverts` | [R3.1](#r3-receive). |
| C10 | `inbound_aWideSenderIsRejectedNotTruncated` | [R4.3](#r4-the-byte-forms-which-are-the-authentication). |
| C11 | `quote_equalsWhatTheSendActuallyConsumes` | Quote, send with exactly that value, assert the provider was paid it and nothing refunded. The central test. |
| C12 | `quote_isTakenOverTheExactPayloadBytes` | Two payloads of different lengths quote differently, and the longer one's quote matches a send of the longer one. [R2.3](#r2-quote). |
| C13 | `quote_revertsWhereTheSendWouldRevert` | Unconfigured route, unroutable destination, below the provenance bar. [R2.5](#r2-quote). |
| C14 | `quote_isView` | Called through `staticcall` and succeeds. [R2.2](#r2-quote). |
| C15 | `quote_bootstrapDoesNotRequireTheCallerToBeTheAccount` | The quote is callable before the account exists. [R2](#r2-quote). |
| C16 | `quote_underfundedSendReverts` | Sending less than the quote fails rather than half-delivering. |
| C17 | `bootstrap_createsTheAccountAtThePredictedAddress` | `predictCrossAccount` on the hub equals the deployed address on the spoke. |
| C18 | `bootstrap_accountIsProviderConfiguredBeforeThePayloadRuns` | A payload whose first call sends must succeed. |
| C19 | `bootstrap_belowTheProvenanceBarReverts` | The bar is applied to the first message to a chain. |
| C20 | `bootstrap_forSomebodyElsesAccountReverts` | `NotTheAccount`. |
| C21 | `parity_accountInitCodeHashMatchesTheRegistryRecord` | [R8.4](#r8-storage-and-address-parity). |
| C22 | `parity_hubAndSpokeProxiesShareInitcode` | The claim that puts hub and spokes at one address. |
| C23 | `parity_theBindingAddsNoConstructorArguments` | `type(CrossProxy).creationCode` unchanged. |
| C24 | `storage_noSlotCollisionAcrossTheInheritanceGraph` | Write every base field, read them all back. |
| C25 | `fees_excessRefundsToTheOwnerNotTheTransceiver` | [R7.2](#r7-fees-and-value). |
| C26 | `fees_nestedSendIsFundedFromBalance` | [R7.3](#r7-fees-and-value), or an explicit documented skip. |
| C27 | `lock_upgradesAreRefusedAfterLock` | The SDK brought no second upgrade path. |
| C28 | `writeOnce_everySetterRefusesASecondDistinctValue` | Enumerated over all of [R9.1](#r9-write-once-discipline). |
| C29 | `replay_aSecondDeliveryOfTheSameMessageIsRefused` | Deliver one payload twice through the binding's own callback. The second MUST NOT execute. The only test of [R3.5](#r3-receive), and the only thing standing between a duplicated delivery and a payload that runs twice. |
| C30 | `replay_aFailedDeliveryIsStillRetryable` | Deliver a payload that reverts, fix the cause, deliver again: it MUST succeed. Asserts the transport marked and rolled back rather than marked and kept, which is what makes C29 safe to rely on. |
| C31 | `replay_theDedupeIsPerAccount` | Two accounts, the same source and nonce shape. One consuming a message MUST NOT stop the other receiving its own. [R3.6](#r3-receive). |

**C11, C29 and C30 want FORK tests, against the real endpoint.** A mock provider does
whatever the harness makes it do, so exercising a binding against one proves the harness
dedupes, prices, and retries: it proves nothing about the transport, which is where all
three properties actually live. Run them against a forked chain with the provider's real
deployment, or accept that P7 and P9 remain documented assumptions.

**C29 is the one nobody writes.** It tests a property of somebody else's contract, which
feels out of scope until you notice that no line in this repo enforces it and path A has no
other defence. On a transport that provides it the test is three lines and passes
immediately; on one that does not, it is the only thing that fails before mainnet.

**C7, C8, C10, and C11 are the ones that would otherwise be found in production.** The
first three are the only defence on the byte forms, and no unit test of either side alone
catches them. C11 is the only thing that ties the quote to the send: a binding where the
two drift compiles, deploys, passes every other test, and overcharges or underfunds every
message it ever carries.

The suite is separate from and does not replace `test/vectors/`, which covers the
commitment half and is
[load-bearing for the scheme plugins](todo.md#6-infrastructure-none-of-it-exists).

---

## 9. Base changes the first binding needed. ALL LANDED

These were gaps in this repo, not obligations on a binding. **All five have landed**, so
nothing in this section blocks the first integration any more; it is kept as the record of
what each one had to be and why, because a binding that misreads any of them reintroduces
the gap.

### 9.1 The quote seam. LANDED

`_quoteMessage` now sits beside `_sendMessage` in `OutboundBase`, `view`, with a matching
`QuoteNotImplemented` default. The two are adjacent so a binding that implements one and
forgets the other is obvious on sight rather than discovered when an interface has nothing
to call. `TransmitterBase` carries four public quotes (`quoteMessage`, `quoteBootstrap`, and
`quoteBootstrapTo` in its `Call[]` and `bytes[]` forms) and `TransceiverBase` carries
`quoteBootstrap` and `quoteBootstrapElements`, which is what the transmitter's three
bootstrap quotes forward to through `IAccountTransceiver`.

**The send and quote surfaces are 1:1, deliberately.** `sendMessage`/`quoteMessage`, and each
of the three bootstraps against its own quote, all with identical arity. That is R2.3 made
structural rather than promised: `attributes` carries destination gas, which changes the
price, so there is no no-attributes send that would have no quote to price it. A binding
inherits the property and MUST NOT add a convenience overload that breaks it.

**A receiver has no quote and cannot acquire one.** `ReceiverBase` does not inherit
`OutboundBase`, so the absence is structural rather than a gate someone could widen: a
receiver never sends, and pricing a message that has no path is not a thing to expose.

**The payload builders are shared, not duplicated.** Each quote calls the same
`Payload.encodeCalls` / `Payload.encodeElements` / `Envelope.encodeBootstrap` its sending
twin calls, so "the quote prices the exact bytes that go out" is a property of there being
one builder rather than a promise two code paths make separately.

### 9.2 The `ReceiverBase` initializer split. LANDED

`ReceiverBase` now follows `TransmitterBase`: `__ReceiverBase_init` is
`internal onlyInitializing` and does the work, and the external `initialize` is a thin
`initializer` wrapper for bindings that need nothing extra.

That split is what makes a binding possible at all. With the work inside an
`external initializer` there was no way to configure a provider between the reentrancy
guard and the payload:

- calling `super.initialize` first runs the payload against an unconfigured provider;
- configuring first and then calling `super.initialize` reverts, because the SDK's own
  `onlyInitializing` setup would run while `_initializing` is still false;
- declaring `initializer` on both reverts `InvalidInitialization` under OpenZeppelin v5,
  since a nested `initializer` on a contract that already has code is not a valid
  top-level call.

A binding declares its own `initialize`, does provider setup, and calls
`__ReceiverBase_init` LAST. It MUST NOT call `super.initialize`.

**This also unblocks the owner problem.** A binding whose SDK needs an owner on the account
declares its own initializer signature carrying it and overrides
`SpokeTransceiverBase._accountInitializer` to encode that selector. The account address does
not move: the initializer calldata is not in the initcode.

**And it is now the transceiver's only reach into a receiver.** `commit`, `cancel`, and
`execute` are gated on the source transmitter alone, so a binding MUST fold everything a
receiver will ever need into that one initializer call. A transceiver holding standing
authority over every receiver it created, on the chain where it is also the contract that
authenticates every inbound message, was one compromise away from every account.

### 9.3 The receiver report. LANDED, GATED ON A FLAG

`SpokeTransceiverBase` gained `addressesDiverge`, written once in the initializer beside
the other home values and with no setter. When it is true, `bootstrapInbound` reports the
account it just created back to the hub; when it is false, nothing is sent.

**The flag exists because the hub cannot work this out.** It derives a receiver's address by
recomputing Ethereum's CREATE2 formula over the recorded factory, salt, and initcode hash,
which is right on most EVM chains and wrong on zkSync and Tron. The chain itself is the only
party that knows which it is, so it says so once rather than leaving the hub to infer it
from a provenance cap that means something adjacent but not the same thing.

**On a parity chain the report would be a downgrade, not merely waste.** A local derivation
is `Derived`; anything arriving over a bridge is graded `Attested`. So most spokes send
nothing, and only the ones that must be believed have to be funded to speak, which is what
confines the funding problem to the chains that actually have it.

**A failed report takes the account creation with it, and must.** The send is nested inside
a delivery callback where `msg.value` is zero, so a diverging spoke pays from its own
balance and a dry one reverts. Catching that would create an account the home chain could
never address: `CrossProxy` arms exactly once and `initialize` is single-shot, so there is
no second bootstrap to carry a second report. All-or-nothing is the only recoverable shape,
and it makes the bootstrap retryable once the balance is topped up.

Note that `SpokeTransceiverBase` is Solidity and therefore only ever runs on an EVM chain,
so the live cases for the flag here are zkSync and Tron. A Starknet or Move spoke implements
the same rule in its own language, with the flag always set.

### 9.4 Refund plumbing. LANDED, WITH NO PARAMETER AT ALL

The gap was narrower than it looked, and the fix threads nothing. `OutboundBase._refundTo()`
returns `msg.sender`, both endpoints inherit it, and both answers are already correct:
owner-gated `sendMessage` makes it the owner, and account-gated `bootstrap` makes it the account.
`TransmitterBase` gained a `receive` so a path B refund has somewhere to land.

The rejected alternatives are worth recording, because each looks reasonable first:

- **A fourth argument on `_sendMessage`.** Explicit and hard to get wrong, but
  it widens the one primitive every binding implements, to carry a value both call sites
  can already read off the stack.
- **A refund address inside the attributes.** No base change, but an empty blob on a
  bootstrap leaves `_sendMessage` with no correct default in scope: the owner is inside the
  encoded envelope, so the binding would have to decode `Envelope` to find it.
- **Transient-storage context set by `bootstrap`.** Keeps the primitive narrow, at the cost
  of a second contract holding per-message state that only one call frame ever reads.

### 9.5 A route read for accounts. LANDED

`IAccountTransceiver` carries `routeTo` alongside `bootstrap`, `bootstrapElements`, and the
two quotes that price them. An account holds exactly one transceiver address, so one
interface named for that relationship is the shape that cannot drift as the things an account
needs from it change.

---

## 10. Worked skeleton: an ERC-7786 gateway binding

Abbreviated to the compliance-relevant lines. The core contracts already speak the
standard, so a binding is thinner than it was: it names a gateway, decides who may deliver,
and answers the quote the standard does not define.

```solidity
abstract contract GatewayEndpoint {
    /// R8.1: on the implementation, so it never reaches CrossProxy's initcode. Every
    /// account on a chain uses the same gateway, which is what an immutable expresses.
    IERC7786GatewaySource public immutable gateway;

    constructor(address gateway_) {
        gateway = IERC7786GatewaySource(gateway_);
    }
}

contract GatewayTransmitter is TransmitterBase, GatewayEndpoint {
    /// R1: the recipient arrives built and checked. Nothing to resolve, nothing to encode.
    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal override returns (bytes32 sendId) {
        sendId = gateway.sendMessage{value: msg.value}(recipient, payload, attributes);
        // R1: a non-zero id means the gateway has NOT sent it yet. Refuse rather than
        // report success for a message still sitting in a queue somebody else must poke.
        if (sendId != bytes32(0)) revert TwoStepGatewayUnsupported(sendId);
    }

    /// R2: ERC-7786 defines no quote, so this is the gateway's own extension or nothing.
    /// Reverting is the honest answer; the binding then documents the measurement in
    /// R2.2.2 that replaces it.
    function _quoteMessage(bytes memory, bytes memory, bytes[] memory)
        internal
        view
        override
        returns (uint256)
    {
        revert QuoteNotImplemented();
    }

    function supportsAttribute(bytes4 selector) external view override returns (bool) {
        return gateway.supportsAttribute(selector);
    }
}

contract GatewayReceiver is ReceiverBase, GatewayEndpoint {
    /// R3.0: the binding answers WHICH gateway. The base answers whether the sender is
    /// this account, because that half needs no configuration.
    function _isAuthorizedGateway(address instance) internal view override returns (bool) {
        return instance == address(gateway);
    }
}

contract GatewaySpokeTransceiver is SpokeTransceiverBase, GatewayEndpoint {
    /// R3.2: translating the callback into three arguments is the whole inbound job.
    /// `_authenticateOrigin` is the base's, on both sides.
    function receiveMessage(bytes32, bytes calldata sender, bytes calldata payload)
        external
        payable
        returns (bytes4)
    {
        if (msg.sender != address(gateway)) revert NotAuthorizedGateway(msg.sender);
        Erc7930.Interop memory io = Erc7930.parseStrict(sender);
        _onInbound(
            Erc7930.toChainIdentifier(sender),   // the route: a bare chain identifier
            io.addr,                             // the sender: raw address bytes, R4.2
            payload
        );
        return IERC7786Recipient.receiveMessage.selector;
    }
}
```

The split is the pleasing part, and it is why `_authenticateOrigin` needs no override on
either side: `Erc7930.toChainIdentifier` reduces the sender envelope to exactly the bytes
`setRoute` stored, so `chainKeyOfRoute` on a hub and `_isHome` on a spoke both match
byte for byte ([R4.1](#r4-the-byte-forms-which-are-the-authentication)), and `io.addr` is
exactly the raw form the counterpart lookup returns
([R4.2](#r4-the-byte-forms-which-are-the-authentication)).

Note what is absent. There is no codec, because a recipient names its own chain and the
route slot holds that chain's identifier. There is no peer table, because an account's peer
is its own address and `TransmitterBase` checks it. There is no inbound authentication,
because `receiveMessage` performs both halves before `_onMessage` runs. What remains is a
gateway address, a policy about two-step sends, and a quote the standard did not define.

## 11. Checklist

A binding is done when every line is true.

**Contracts**
- [ ] Five or six files under `src/protocols/<provider>/`, with shared plumbing in `<P>Endpoint`
- [ ] `_sendMessage` overridden on all four endpoints
- [ ] `_quoteMessage` overridden on all four endpoints, `view`, sharing the send's resolver
- [ ] `supportsAttribute` answered on the transmitter, `quoteBootstrap` on the transceiver
- [ ] `_isAuthorizedGateway` answered on the receiver, and inbound routed into `_onInbound`
      on the transceivers
- [ ] Inbound reverts on the transmitter
- [ ] `_checkAdmin` and `_checkOwner` answered from one authority each
- [ ] `_accountInitializer` overridden on both transceivers
- [ ] Codec library and typed setters, only where a provider-native id survives

**Byte forms**
- [ ] Route produced by one codec function in both directions
- [ ] Sender narrowed to the registry's exact form, wide senders rejected
- [ ] Fixed-width `abi.encode` everywhere a route is built

**Value**
- [ ] `msg.value` pays the fee, excess refunds to the owner
- [ ] Quote priced over the exact payload bytes, never cached, never called by the send
- [ ] Nested send funded from balance, or the gap documented, and its quote exposed

**Parity**
- [ ] `CrossProxy` initcode unchanged, compiler settings unchanged
- [ ] `accountInitCodeHash` asserted against `CROSS_PROXY_INIT_CODE_HASH` in the script
- [ ] SDK storage namespaced or layout pinned

**Process**
- [ ] Every SDK-side authentication documented as a written exception
- [ ] No new setter for any write-once value
- [ ] `script/` deploys in the order of [§6](#6-configuration-a-compliant-deployment-performs)
- [ ] `ProviderCompliance.t.sol` C1 through C31 pass

---

## 12. Appendix: transport replay guarantees

What each candidate provider actually does about a message being delivered twice, checked
against the deployed source rather than the marketing. This is the evidence behind
[P7](#2-provider-prerequisites-the-go-or-no-go-checklist) and [R3.5](#r3-receive).

| Provider | Dedupes a successful message | Mechanism | Failed message retryable |
| --- | --- | --- | --- |
| **LayerZero V2** | Yes | `inboundPayloadHash[receiver][srcEid][sender][nonce]`, cleared by `_clearPayload` before the receiver is called | Yes, `lzReceive` is permissionless and a revert rolls the clear back |
| **Hyperlane** | Yes | `deliveries[messageId]` in `Mailbox`, written before `handle()`; `require(delivered(_id) == false, "Mailbox: already delivered")` | Yes, `process()` again; the `handle` call is plain, so a revert rolls the write back |
| **CCIP** | Yes | `s_executionStates[sourceChainSelector][seqNum]`; `SUCCESS` is terminal | Yes, manual execution from the `FAILURE` state |
| **Axelar** | Yes | the gateway marks a `commandId` consumed inside `validateContractCall`, which cannot be called twice | Yes, the whole `execute` reverts, so the approval survives |
| **Wormhole (core)** | **No** | `parseAndVerifyVM` verifies signatures and nothing else; the core contract keeps no record of consumed VAAs | n/a, replay is the integrator's problem |

**The pattern is the same in all four that provide it, and it is worth naming**: write the
consumed mark FIRST, then make a plain external call to the receiver. The write-first order
is reentrancy protection; the plain call is what gives retry, because the revert that fails
the payload also rolls the mark back. One mechanism, both properties. A binding that wraps
that call in `try/catch` breaks the second while appearing to improve it, which is
[R3.7](#r3-receive).

**Wormhole is the outlier and it is a documented one.** Its own guidance says integrators
must implement replay protection themselves, offering the VAA digest or the
`(emitterChain, emitterAddress, sequence)` triple as the key, and the same is true of the
newer Executor framework. A Wormhole binding is therefore not simply more code, it is code
carrying a guarantee the other four inherit for free, and it is the one place in this
protocol where a binding holds a security property rather than a translation.

**What this settles.** The protocol needs no `requestId` and no per-message nonce of its
own. Correlation never needed one: the receiver report's slot is derived from the
authenticated origin plus the stated `(owner, salt)`, and the slot is write-once.
Idempotency does need one, but it exists at the transport for every provider currently in
scope, and adding a protocol-level id would put a field on every channel plus a growing set
on every receiver to buy something four of five transports already give. The correct shape
is what is written above: state the requirement, test it per binding, and make the one
provider that lacks it carry the cost in its own `<P>Endpoint`.

Sources: [LayerZero `EndpointV2.sol`](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/EndpointV2.sol),
[Hyperlane `Mailbox.sol`](https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/Mailbox.sol),
[CCIP manual execution](https://docs.chain.link/ccip/concepts/manual-execution),
[Axelar Executable](https://docs.axelar.dev/dev/general-message-passing/executable),
[Wormhole core contracts](https://wormhole.com/docs/products/messaging/guides/core-contracts/).

---

## 13. Appendix: ERC-7786 as a transport

OpenZeppelin ships `interfaces/draft-IERC7786.sol` and `crosschain/ERC7786Recipient.sol`,
and this protocol arrived at nearly the same shape independently: an opaque `bytes` payload
to a recipient named by an interoperable address, with an opaque per-send options blob. So
the question is worth answering once rather than rediscovering per provider.

**MOSTLY LANDED.** The core contracts now implement `IERC7786GatewaySource` and
`IERC7786Recipient` directly, the route slot holds a chain identifier, and
`TransceiverBase._recipientOn` builds the recipient. What is NOT adopted is
`CrosschainLinked(Upgradeable)`: it sits behind `Bytes.sol` and its four `mcopy` sites, so
it cannot compile at `paris`, and independently its per-contract `_links` table and
`_isAuthorizedGateway` would replace the shared-transceiver routing and bypass the
registry's provenance dial. The analysis below is kept because it is the reasoning, and
because the gaps it names are now the protocol's gaps.

### The one thing that does not map, and how it resolves

ERC-7786 addresses a recipient as a binary interoperable address: chain and address in one
ERC-7930 blob. This protocol holds a `chainKey`, which is
`keccak256(<canonical chain identifier>)` and therefore one-way. A chainKey cannot produce a
7786 recipient.

**Store the chain identifier in the route slot.** `setRoute(chainKey, identifier)` makes the
reverse index correct BY CONSTRUCTION rather than by configuration, since
`keccak256(identifier) == chainKey` is the definition of a chainKey. `setRoute` already
enforces injectivity and chain identifiers are unique per chain, so nothing else changes.
The route slot holds a chain identifier instead of an eid, and every other piece of the
routing machinery works untouched.

That is the whole trick. A 7786 gateway needs no provider-native chain id, which is what the
route table existed to hold.

### Where each seam attaches

| Our hook | ERC-7786 |
| --- | --- |
| `_sendMessage(recipient, payload, attributes)` | `gateway.sendMessage(recipient, payload, attributes)`, one to one |
| `_quoteMessage(...)` | **nothing.** See below |
| `_onInbound(route, sender, message)` | called from `receiveMessage(receiveId, sender, payload)`, splitting the sender envelope with `Erc7930.toChainIdentifier` for the route and `parseStrict(...).addr` for the sender |
| `attributes` | passed straight through |

The inbound split is the pleasing part: `Erc7930.toChainIdentifier` already reduces an
account envelope to a bare chain identifier, which is exactly the `route` the hub's
`chainKeyOfRoute` and the spoke's `_isHome` expect. `_authenticateOrigin` needs no override
on either side.

### What ERC-7786 gives up

1. **No quote, at all.** The interface is `supportsAttribute` and `sendMessage`. A payable
   send with no way to ask its price fails [P9](#2-provider-prerequisites-the-go-or-no-go-checklist)
   and kills eight functions of read surface. This is the largest cost and the reason to
   prefer a native SDK where one exists. Fallbacks are in [R2.2.2](#r2-quote).
2. **`sendMessage` may not complete the send.** It returns a `sendId`, and a non-zero value
   means further gateway-specific, non-standardised action is required. `_sendMessage`
   returns nothing and assumes the message is away, so a binding must either handle a
   two-step send or restrict itself to gateways that return zero, and say which.
3. **No mandated exactly-once.** The standard defines a `receiveId` for correlation but
   requires nothing about replay, so [R3.5](#r3-receive) stays a per-gateway question rather
   than being answered by the standard. Note the `receiveId` is free where our own channels
   carry no id; see [`todo.md`](todo.md#4-decisions-taken-that-deserve-a-second-look) for why
   we concluded none was needed.

### The other draft worth knowing about

`utils/draft-InteroperableAddress.sol` is OpenZeppelin's ERC-7930, 245 lines against this
repo's 248-line `src/addressing/Erc7930.sol`, covering the same ground with `formatEvmV1`,
`parseEvmV1`, and `try` and calldata variants. Replacing ours with it is a real candidate:
audited, maintained, and one fewer library to own.

Two things block a straight swap. It is a `draft-`, which OpenZeppelin explicitly excludes
from its API stability guarantee and may change in a MINOR release, and this codebase freezes
accounts against exact bytes. And `Erc7930.parseStrict` enforces strictness the registry
depends on, rejecting non-minimal `eip155` references and trailing bytes; whether `parseV1`
matches has not been checked. Neither is a reason not to do it, both are reasons it is its
own task with its own vectors.
