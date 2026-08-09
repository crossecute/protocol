# Message provider compliance

What a message provider binding must implement to be a first-class transport for this
protocol, and what the provider protocol itself must be capable of before a binding is
worth writing.

[`message-flow.md`](message-flow.md) describes the two paths and
[`encoding.md`](encoding.md) the payload formats. This file is the contract between those
designs and a transport: everything a binding MUST satisfy, everything it MUST NOT do, and
the fixed set of tests that decide whether it did.

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

Before any code is written, the provider must be able to do all thirteen of these. A "no"
on any of P1 through P9 disqualifies the provider outright; P10 through P13 are costs
rather than blockers, and each has a stated fallback.

| # | Requirement | Why the protocol needs it |
| --- | --- | --- |
| **P1** | Carry an arbitrary `bytes` body, sender-chosen, no schema imposed | `_sendMessage` is the only send primitive and it carries `bytes`. Payloads, bootstrap envelopes, and reports all use it. |
| **P2** | Any contract may be its own endpoint, permissionlessly | Path A is account to account. If receiving requires provider governance to whitelist an address, every user's account needs an approval and the protocol does not work. |
| **P3** | Deliver to an address the sender chose, not one the provider assigns | The account address is fixed by CREATE2 before the account exists. A provider that mints or assigns the destination address breaks address parity, which is the whole product. |
| **P4** | Report the source chain and source address to the receiving contract | `_onInbound(route, sender, message)` cannot authenticate without both. A provider that reports only "some peer" is not authenticable at our layer. |
| **P5** | Unordered delivery | Ordered lanes turn one permanently-failing message into a halt on that lane. See [Failure handling](message-flow.md#failure-handling). |
| **P6** | Permissionless retry of a failed message | Execution runs inside the delivery callback, so a revert must be a retry and not a loss. |
| **P7** | Fee payable at source in native currency, from `msg.value` | Signers transact only at home. A provider requiring a fee token per chain reintroduces the funding matrix the protocol exists to remove. |
| **P8** | **Quote that fee at source, as a `view`, before the send** | The fee is not knowable off-chain from first principles: it depends on payload length, destination gas, and the provider's own price feed. Without a quote a caller either overpays blindly or has a send revert after the signers have already approved it. See [R2](#r2-quote). |
| **P9** | No deployment-time registration that changes an address | Anything requiring the account to be deployed by a provider factory, or to hold a provider-issued id in its initcode, moves the address and breaks parity. Implementation-level immutables are fine: they never reach `CrossProxy`'s initcode. |
| **P10** | Send from inside a delivery callback, funded from contract balance | The spoke's receiver report is sent from inside the bootstrap callback where `msg.value` is zero. Fallback: the report is sent in a separate transaction by a relayer, which weakens the bootstrap to two steps. |
| **P11** | Per-message destination gas or execution options | Carried opaquely in `providerData`. Fallback: the binding hard-codes a default and payloads above it fail on arrival. |
| **P12** | Support for the target chain set, including the non-EVM ones in scope | A provider that reaches only EVM chains is usable, but the Move, Solana, and Starknet work in [`todo.md`](todo.md#3-blockers-on-specific-paths) stays blocked on a second provider. |
| **P13** | An upgradeable-safe SDK: namespaced storage, no constructor-only state on the proxy | Accounts are proxies and transceivers are proxies. An SDK that stores in sequential slots forces a layout freeze on every contract it mixes into. |

**P2 and P3 together are the real filter.** They are what "an account is its own endpoint"
means, and they are the claim the entire redesign rests on. Verify them against the
provider's actual code, not its documentation, before writing anything else.

Every provider in scope satisfies P8 today: LayerZero's `endpoint.quote(MessagingParams,
address) -> MessagingFee`, Hyperlane's `quoteDispatch`, CCIP's `getFee`, Wormhole's
`quoteEVMDeliveryPrice`, Axelar's off-chain gas estimator with an on-chain equivalent. All
but Axelar's are `view`.

---

## 3. The contract set

A binding is six files under `src/protocols/<provider>/`. Naming follows the existing
LayerZero skeleton.

| File | Extends | Role |
| --- | --- | --- |
| `<P>Codec.sol` | library | The one place the provider's chain id has a Solidity type. |
| `<P>Endpoint.sol` | abstract | Shared send, quote, and receive plumbing, mixed into the four below. |
| `<P>Transmitter.sol` | `TransmitterBase`, `<P>Endpoint` | The per-user account at home. Sends on path A. |
| `<P>Receiver.sol` | `ReceiverBase`, `<P>Endpoint` | The per-user account on a spoke. Receives on path A. |
| `<P>HubTransceiver.sol` | `HubTransceiverBase`, `<P>Endpoint` | Sends bootstrap, receives reports. |
| `<P>SpokeTransceiver.sol` | `SpokeTransceiverBase`, `<P>Endpoint` | Receives bootstrap, sends the report. |

**`<P>Endpoint` is not optional structure, it is the deduplication that keeps the four in
agreement.** Fee handling, `providerData` decoding, the route byte form, and the sender byte
form must be identical across all four or authentication silently diverges between path A
and path B, and a quote stops predicting its own send. Writing them once is what makes that
structural. It declares no storage of its own beyond what the SDK brings.

---

## 4. The seams

Every abstract or virtual member a binding must answer, and where.

### 4.1 Required on all four contracts

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_sendMessage(bytes32 chainKey, bytes payload, bytes providerData)` | `OutboundBase:79` | MUST override. The default reverts `SendNotImplemented`. See [R1](#r1-send). |
| `_quoteMessage(bytes32 chainKey, bytes payload, bytes providerData)` | `OutboundBase` | MUST override, `view`. The default reverts `QuoteNotImplemented`. See [R2](#r2-quote). |
| the provider's inbound callback | the SDK | MUST route into exactly one protocol funnel and nothing else. See [R3](#r3-receive). |

### 4.2 Required on the transmitter

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_owner()` | `TransmitterBase:89` | Answer from the SDK's own ownership if it brings one, otherwise from `OwnableUpgradeable`. |
| `_checkOwner()` | `TransmitterBase:92` | Same. Note `TransmitterBase` uses `onlyAccountOwner`, not `onlyOwner`, precisely so an SDK's `onlyOwner` does not collide. |
| `initialize(address owner, address transceiver, bytes32 salt)` | `ITransmitterInit`, `HubTransceiverBase:11` | MUST exist with that exact signature, or the hub's `_accountInitializer` MUST be overridden to encode a different one. |

### 4.3 Required on the receiver

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `initialize(...)` | `IReceiverInit`, `ReceiverBase:41` | Declare a binding-specific one, do provider setup, then call `__ReceiverBase_init` LAST so the bootstrap payload runs against a configured provider. Never `super.initialize`. |
| an owner or delegate | none today | If the SDK needs an owner-gated config surface on the account, the receiver's initializer MUST carry the owner. `_accountInitializer` is `virtual` on the spoke for exactly this. |
| nothing else | | A binding MUST NOT expect the transceiver to reach a receiver after creation. `commit`, `cancel`, and `execute` are gated on the transmitter alone; the initializer is the transceiver's only call, ever. |

### 4.4 Required on the hub transceiver

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_checkAdmin()` | `TransceiverBase:344` | Answer from the SDK's ownership, or from `OwnableUpgradeable`. MUST NOT introduce a second authority: two owners on one transceiver means an upgrade lock held by one can be undone through the other. |
| `_accountInitializer(owner, salt, calls)` | `TransceiverBase:313` | Override to fold provider setup into the transmitter's initializer. There is no second chance: `CrossProxy` locks in the same call that arms it. |
| a typed route setter | convention | `setEid(bytes32 chainKey, uint32 eid)` style, wrapping `setRoute`. See [R5](#r5-the-route-codec). |
| a typed route reader | convention | `eidFor(bytes32)` and `chainKeyForEid(uint32)` style, for off-chain checks. |

### 4.5 Required on the spoke transceiver

| Seam | Declared in | Obligation |
| --- | --- | --- |
| `_checkAdmin()` | `TransceiverBase:344` | As above. |
| `_accountInitializer(owner, salt, calls)` | `SpokeTransceiverBase:251` | Override to fold provider setup into the receiver's initializer, and to carry the owner if the SDK needs one. |
| `initialize(...)` | convention | MUST take the home route in the provider's own type, and pass it through the codec into `__SpokeTransceiverBase_init`. |
| the receiver report | does not exist yet | See [§9.3](#93-the-receiver-report-has-no-sender). |

### 4.6 Deliberately absent

A binding MUST NOT expect any of these, and MUST NOT add them.

- **No authentication seam.** `_authenticateOrigin` is answered by
  `HubTransceiverBase:178` and `SpokeTransceiverBase:206`, not by a binding. This is
  deliberate: a transceiver decides which cross-chain payloads are authentic, and leaving
  that per provider is how one provider ships without it.
- **No message-type seam.** Direction is the discriminant. Each channel carries one shape.
- **No registry pointer on an account.** A transmitter holds no registry and knows no
  routes, by design. It resolves through its transceiver: see [R1](#r1-send).
- **No provenance seam.** Grading is the registry's, applied at the hub.

---

## 5. Normative rules

### R1. Send

`_sendMessage` MUST put `payload` on the wire addressed to `destinationChainKey`, and MUST
revert if it cannot.

**R1.1** It MUST resolve the provider's chain id through the route table and nowhere else.
The table is `TransceiverBase._routes`, write-once, injective in both directions.

**R1.2** On a transceiver, resolve with `_routeTo(chainKey)`. On an account, resolve by
calling `routeTo(chainKey)` on the transceiver the account already stores
(`TransmitterBase.transceiver`, `ReceiverBase.parentTransceiver`). Both are `public view`
on `TransceiverBase:408`. An account MUST NOT hold a route table of its own: a user adding
a destination is a msig configuration change, not a per-account migration.

**R1.3** The destination address on path A is `address(this)`, always. An account's peer is
its own address on every chain. A binding MUST NOT make this a stored, settable value on
an account when the SDK allows it to be derived. Where the SDK insists on a peer table,
the binding SHOULD override the peer lookup to return `address(this)` unconditionally
rather than populate it. A value with exactly one correct answer is not configuration, and
storing it creates a state in which it can be wrong.

**R1.4** The destination address on path B is `_counterpartOn(chainKey)` on the hub and
`homeTransceiver()` on the spoke. Both return raw bytes in the destination's format. The
binding MUST NOT assume 20 bytes without checking the chain type.

**R1.5** `providerData` is opaque above the binding and MUST be decoded only inside it. An
empty `providerData` MUST mean "the binding's default" and MUST NOT mean zero gas.

**R1.6** A send with an unconfigured route MUST revert, not succeed. `routeFor` already
reverts `NoRouteFor`; a binding that catches this and falls back is non-compliant.

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
    bytes32 destinationChainKey,
    bytes memory payload,
    bytes memory providerData
) internal view virtual returns (uint256 nativeFee) {
    revert QuoteNotImplemented();
}
```

**R2.2 It MUST be `view`.** A quote that writes state cannot be called from an off-chain
`eth_call` in the same block as the send it prices, which is the only way it is ever used.
A provider whose quote is not `view` fails [P8](#2-provider-prerequisites-the-go-or-no-go-checklist)
and the binding MUST document the fallback rather than making the seam non-view: making
`_quoteMessage` mutable would force the whole read surface below to be mutable too, and a
`quoteSend` that cannot be `eth_call`ed is not a quote.

**R2.3 It MUST price the exact bytes the send would carry.** The quote is taken over
`Payload.encodeCalls(calls)` or `Envelope.encodeBootstrap(owner, salt, calls)`, the same
function `_dispatch` receives, not over an estimate of the length. Every provider prices
per byte. This is what makes `quote` a number a caller can send rather than a number a
caller must pad, and it is why the public surface below takes the same arguments as `send`
rather than taking raw `bytes`.

**R2.4 It MUST use the same route, destination, and options resolution as the send.** Any
divergence between `_quoteMessage` and `_sendMessage` is a quote that prices a different
message than the one that goes out. In practice this means both call one shared internal
helper for route resolution and one for `providerData` decoding, which is
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

**The public read surface.** Each entry point that spends a fee MUST have a quote whose
arguments are identical to it, minus `msg.value`. Declared as an interface so tooling has
one thing to import:

```solidity
/// @notice What a message would cost to send, in this chain's native currency.
/// @dev Mirrors the send surface argument for argument. Every function is `view` and
///      prices the exact payload bytes its sending twin would put on the wire.
interface IMessageQuote {
    /* -------- path A: transmitter to its own receiver -------- */

    function quoteSend(uint256 destinationChainId, Call[] calldata calls)
        external view returns (uint256 nativeFee);

    function quoteSend(
        uint256 destinationChainId,
        Call[] calldata calls,
        bytes calldata providerData
    ) external view returns (uint256 nativeFee);

    function quoteSendTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes calldata providerData
    ) external view returns (uint256 nativeFee);

    function quoteSendTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes calldata providerData
    ) external view returns (uint256 nativeFee);

    /* -------- path B: bootstrap -------- */

    function quoteBootstrap(
        uint256 destinationChainId,
        Call[] calldata calls,
        bytes calldata providerData
    ) external view returns (uint256 nativeFee);

    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        Call[] calldata calls,
        bytes calldata providerData
    ) external view returns (uint256 nativeFee);

    function quoteBootstrapTo(
        bytes calldata destinationChainIdentifier,
        bytes[] calldata elements,
        bytes calldata providerData
    ) external view returns (uint256 nativeFee);
}
```

`TransmitterBase` implements all seven, each a two-line body that builds the payload the
matching send would build and hands it to `_quoteMessage`. They belong on the base rather
than on a binding for the same reason `send` does: the payload construction and the
destination-key rules (`_evmKey`, `_typedKey`, `_opaqueKey`, and the typed-versus-opaque
pairing checks) must not be re-derived per provider.

The bootstrap quotes are the ones that matter most in practice. Bootstrap is the message a
caller is least able to guess the cost of, because it carries the account creation as well
as the payload, and it is the message that fails most expensively: the account is not there
yet, so an underfunded send is not a retry, it is a chain the account still does not exist
on.

**The transceiver's quote.** `TransceiverBase` MUST expose the path B quote it is asked
for, matching its `bootstrap` and `bootstrapElements` entry points:

```solidity
function quoteBootstrap(
    bytes32 destinationChainKey,
    address owner,
    bytes32 salt,
    Call[] calldata calls,
    bytes calldata providerData
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

| Contract | Funnel | Signature |
| --- | --- | --- |
| transceiver (hub or spoke) | `_onInbound` | `(bytes route, bytes sender, bytes calldata message)` |
| receiver | `_onMessage` | `(bytes calldata payload)` |
| transmitter | none | MUST revert |

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
`TransceiverBase:434` and MUST appear as a written exception in the binding's NatSpec
rather than as an omission. This is [todo §4](todo.md#4-decisions-taken-that-deserve-a-second-look),
still open.

**R3.4** The receiver's funnel is `_onMessage`, which is `nonReentrant` and executes on
arrival. The binding MUST NOT decode the payload itself: `Payload.decodeCalls` happens
inside `_onMessage`, so every provider gets the same decoder and the same failure mode.

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
silently reinterpret. `LzCodec` is the reference.

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
refund address out of `providerData` or substitute one of its own.

The rule is one sentence: a fee is overpaid by whoever paid it, so the remainder goes back
to the party that sent the value. It resolves correctly on both paths without anything
being threaded through the call stack. On path A `send` is `onlyAccountOwner`, so
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

**R9.2** A typed wrapper around a write-once setter (`setEid` over `setRoute`) is the
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
| 7 | `<P>HubTransceiver.setEid(chainKey, id)` per destination | Write-once, injective. |
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
    function deliverToAccount(address to, bytes memory route, bytes memory sender, bytes memory body)
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

**C7, C8, C10, and C11 are the ones that would otherwise be found in production.** The
first three are the only defence on the byte forms, and no unit test of either side alone
catches them. C11 is the only thing that ties the quote to the send: a binding where the
two drift compiles, deploys, passes every other test, and overcharges or underfunds every
message it ever carries.

The suite is separate from and does not replace `test/vectors/`, which covers the
commitment half and is
[load-bearing for the scheme plugins](todo.md#6-infrastructure-none-of-it-exists).

---

## 9. Base changes required before any binding compiles

These are gaps in this repo, not obligations on a binding. §9.1 and §9.2 have landed; the
rest still block the first integration.

### 9.1 The quote seam. LANDED

`_quoteMessage` now sits beside `_sendMessage` in `OutboundBase`, `view`, with a matching
`QuoteNotImplemented` default. The two are adjacent so a binding that implements one and
forgets the other is obvious on sight rather than discovered when an interface has nothing
to call. `TransmitterBase` carries the six public quotes and `TransceiverBase` carries
`quoteBootstrap` and `quoteBootstrapElements`.

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
owner-gated `send` makes it the owner, and account-gated `bootstrap` makes it the account.
`TransmitterBase` gained a `receive` so a path B refund has somewhere to land.

The rejected alternatives are worth recording, because each looks reasonable first:

- **A fourth argument on `_dispatch`/`_sendMessage`.** Explicit and hard to get wrong, but
  it widens the one primitive every binding implements, to carry a value both call sites
  can already read off the stack.
- **A refund address inside `providerData`.** No base change, but an empty blob on a
  bootstrap leaves `_sendMessage` with no correct default in scope: the owner is inside the
  encoded envelope, so the binding would have to decode `Envelope` to find it.
- **Transient-storage context set by `bootstrap`.** Keeps the primitive narrow, but this
  codebase already removed a contract for being exactly that (`Dissolve MessagingContext`).

### 9.5 A route read for accounts. LANDED

`ITransceiverBootstrap` is now `IAccountTransceiver` and carries `routeTo` alongside
bootstrap and the two quotes. An account holds exactly one transceiver address, so one
interface over it is the shape that cannot drift; the old name was already strained by the
quotes and `routeTo` broke it outright.

---

## 10. Worked skeleton: LayerZero

Verified against `@layerzerolabs/oapp-evm-upgradeable@0.1.3`, whose findings are in
[todo §2](todo.md#2-the-provider-binding). Abbreviated to the compliance-relevant lines.

```solidity
abstract contract LzEndpoint is OAppUpgradeable {
    // R8.1: on the implementation, so it never reaches CrossProxy's initcode.
    constructor(address endpoint_) OAppCoreUpgradeable(endpoint_) {}

    // R1.5: the one place providerData has a shape. Shared by send AND quote, which is
    // what keeps R2.4 true rather than merely intended.
    function _decodeProviderData(bytes memory d, address defaultRefund)
        internal pure returns (bytes memory options, address refund)
    {
        if (d.length == 0) return ("", defaultRefund);
        (options, refund) = abi.decode(d, (bytes, address));
        if (refund == address(0)) refund = defaultRefund;
    }

    // R4.2: the ONE narrowing, shared by all four contracts.
    function _senderBytes(bytes32 sender) internal pure returns (bytes memory) {
        // R4.3: refuse a wide sender rather than truncate it.
        require(uint256(sender) >> 160 == 0, "wide sender");
        return abi.encodePacked(address(uint160(uint256(sender))));
    }
}

contract LzTransmitter is TransmitterBase, LzEndpoint {
    function _sendMessage(bytes32 chainKey, bytes memory payload, bytes memory providerData)
        internal override
    {
        (uint32 eid, bytes memory options, address refund) = _resolve(chainKey, providerData);
        // R1.3: the peer is this account's own address, derived rather than stored.
        _lzSend(eid, payload, options, MessagingFee(msg.value, 0), refund);
    }

    // R2: the same resolution, the same payload, the same options. Different verb.
    function _quoteMessage(bytes32 chainKey, bytes memory payload, bytes memory providerData)
        internal view override returns (uint256)
    {
        (uint32 eid, bytes memory options,) = _resolve(chainKey, providerData);
        // R2.8: native only. `false` is payInLzToken.
        return endpoint.quote(
            MessagingParams(eid, _getPeerOrRevert(eid), payload, options, false), address(this)
        ).nativeFee;
    }

    // R2.4: one resolver, so a quote cannot price a different route than the send uses.
    // R1.2: the account holds no route table; it asks its transceiver.
    function _resolve(bytes32 chainKey, bytes memory providerData)
        private view returns (uint32 eid, bytes memory options, address refund)
    {
        eid = LzCodec.decodeEid(ITransceiverRoutes(transceiver).routeTo(chainKey));
        (options, refund) = _decodeProviderData(providerData, _owner());
    }

    // R3.1: a transmitter never receives.
    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata)
        internal pure override
    { revert InboundToTransmitter(); }

    // R1.3: one correct answer, so it is derived, not configuration.
    function _getPeerOrRevert(uint32) internal view override returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }
}

contract LzSpokeTransceiver is SpokeTransceiverBase, LzEndpoint {
    // R3: translate, do not authenticate. _onInbound does that.
    function _lzReceive(Origin calldata o, bytes32, bytes calldata message, address, bytes calldata)
        internal override
    {
        _onInbound(LzCodec.encodeEid(o.srcEid), _senderBytes(o.sender), message);
    }

    // R6: provider setup folded into the account initializer, with the owner carried.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal view override returns (bytes memory)
    {
        return abi.encodeCall(
            ILzReceiverInit.initialize, (predictCrossAccount(owner, salt), owner, calls)
        );
    }
}
```

Note `_resolve`: the reason the quote and the send agree is not that both were written
carefully, it is that neither can name a route or an option the other did not. That is the
shape every binding's quote should take.

Note also `endpoint.quote` taking `address(this)` as the sender: on path A the account is
the OApp, so it quotes for itself. A transceiver's quote passes `address(this)` for the same
reason, and the two are different contracts quoting different lanes, which is why
[R2.4](#r2-quote) is stated per contract rather than once.

The `Origin` struct's `srcEid` goes back through `LzCodec.encodeEid`, not through a
hand-written `abi.encode`: that is
[R4.1](#r4-the-byte-forms-which-are-the-authentication) in one line.

---

## 11. Checklist

A binding is done when every line is true.

**Contracts**
- [ ] Six files under `src/protocols/<provider>/`, with shared plumbing in `<P>Endpoint`
- [ ] `_sendMessage` overridden on all four endpoints
- [ ] `_quoteMessage` overridden on all four endpoints, `view`, sharing the send's resolver
- [ ] `IMessageQuote` answered on the transmitter, `quoteBootstrap` on the transceiver
- [ ] Inbound routed into `_onInbound` on transceivers, `_onMessage` on the receiver
- [ ] Inbound reverts on the transmitter
- [ ] `_checkAdmin` and `_checkOwner` answered from one authority each
- [ ] `_accountInitializer` overridden on both transceivers
- [ ] Codec library, typed setters on the hub, typed initializer arg on the spoke

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
- [ ] `ProviderCompliance.t.sol` C1 through C28 pass
