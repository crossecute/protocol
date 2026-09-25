# Provider research

What we have found out about transports we do not control, and about standards that are
still drafts. None of it is a requirement.

**READ THE STALENESS BEFORE THE CONTENT.** This file and
[`provider-spec.md`](provider-spec.md) were one document, and they were split because they
go out of date for different reasons. The spec changes when THIS protocol changes, and a
reader can check it against the tree. Everything here goes stale when somebody ELSE ships a
release: it makes version-pinned claims about contracts in other repositories, verified by
reading their deployed source on a particular day and true only until they redeploy.
Keeping the two together let that rot sit inside a document people read as a specification.

So: nothing in this file is normative. Where a finding here produced an obligation, the
obligation lives in the spec and is cited from here, not the other way round. The
[transport replay matrix](#1-what-each-transport-guarantees-about-replay) is the evidence
behind prerequisite P7, rules R3.5 through R3.7, and compliance tests C29 through C31; the
[ERC-7786 analysis](#3-erc-7786-as-a-transport) is the reasoning behind the core contracts
implementing the standard directly; the [CCIP](#4-ccip-as-a-native-binding) and
[Hyperlane](#5-hyperlane-as-a-native-binding) sections are the reasoning behind
`contracts/evm/src/protocols/ccip/` and `.../hyperlane/`, the template contracts alongside
`.../layerzero/`.

| Section | Pinned to | Goes stale when |
| --- | --- | --- |
| [1. Transport replay](#1-what-each-transport-guarantees-about-replay) | source as read: LayerZero V2, Hyperlane, CCIP, Axelar, Wormhole core, OP `CrossDomainMessenger`, Arbitrum `AbsOutbox`, Warp `contract.go`, `TeleporterMessenger`. Arbitrum's L1→L2 retryable is ArbOS Go and remains unread | any of them changes how a delivered message is marked consumed |
| [2. Canonical transports](#2-canonical-rollup-and-subnet-transports) | OP Stack, Arbitrum and Avalanche; the aliasing and same-address findings are from source, the latency and fee figures from documentation | a fault-proof window changes, Superchain interop ships, or ICM changes its fee model |
| [3. ERC-7786](#3-erc-7786-as-a-transport) | ERC-7786 as of OpenZeppelin 5.5.0, whose `draft-IERC7786` is vendored at `src/messaging/IErc7786.sol`; `draft-InteroperableAddress` for comparison | The ERC changes. The vendored copy makes that a reviewed edit rather than a dependency bump |
| [4. CCIP](#4-ccip-as-a-native-binding) | `smartcontractkit/ccip`, `ccip-develop` branch, commit `171f9f0c` | Chainlink changes `CCIPReceiver`'s authentication, `Client`'s struct shapes, or the Router/OnRamp/OffRamp split |
| [5. Hyperlane](#5-hyperlane-as-a-native-binding) | `hyperlane-xyz/hyperlane-monorepo`, `main` branch, commit `983831f6`; pinned dependency versions read from `solidity/remappings.txt` (OZ `4.9.3`) | Hyperlane bumps its own OZ pin past a version this repo can share, or changes `MailboxClient`/`Router`'s shape |
| [6. Wormhole](#6-wormhole-core-vs-the-relayer-two-different-bindings) | `wormhole-foundation/wormhole`, `main` branch, commit `2df4000c` (`IWormhole.sol`); `wormhole-foundation/wormhole-solidity-sdk`, `main` branch, commit `2cb855ea` (`IWormholeRelayer.sol`) | Wormhole Core adds general-message dedupe (it does not have it today), or the Relayer interface's delivery/quote shape changes |
| [7. OP Stack](#7-op-stack-as-a-native-binding) | `ethereum-optimism/optimism`, `develop` branch, commit `0abfb166` (`ICrossDomainMessenger.sol`) | Optimism changes `relayMessage`'s calling convention or how `xDomainMessageSender` is scoped |
| [8. LayerZero](#8-layerzero-as-a-native-binding) | `@layerzerolabs/oapp-evm-upgradeable@0.1.3`, `@layerzerolabs/oapp-evm@0.4.1`; per-file commits in `script/vendor/layerzero.sh` | LayerZero moves OApp's storage namespace, its peer check, or `_payNative`'s `msg.value` rule |

---

## 1. What each transport guarantees about replay

What each candidate provider actually does about a message being delivered twice, checked
against the deployed source rather than the marketing. This is the evidence behind
[P7](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist) and [R3.5](provider-spec.md#r3-receive).

| Provider | Dedupes a successful message | Mechanism | Failed message retryable |
| --- | --- | --- | --- |
| **LayerZero V2** | Yes | `inboundPayloadHash[receiver][srcEid][sender][nonce]`, cleared by `_clearPayload` before the receiver is called | Yes, `lzReceive` is permissionless and a revert rolls the clear back |
| **Hyperlane** | Yes | `deliveries[messageId]` in `Mailbox`, written before `handle()`; `require(delivered(_id) == false, "Mailbox: already delivered")` | Yes, `process()` again; the `handle` call is plain, so a revert rolls the write back |
| **CCIP** | Yes | `s_executionStates[sourceChainSelector][seqNum]`; `SUCCESS` is terminal | Yes, manual execution from the `FAILURE` state |
| **Axelar** | Yes | the gateway marks a `commandId` consumed inside `validateContractCall`, which cannot be called twice | Yes, the whole `execute` reverts, so the approval survives |
| **Wormhole (core)** | **No** | `parseAndVerifyVM` verifies signatures and nothing else; the core contract keeps no record of consumed VAAs | n/a, replay is the integrator's problem |
| **OP Stack (canonical)** | Yes | `successfulMessages[versionedHash]` in `CrossDomainMessenger`, written only after the call returns true; `failedMessages` takes the rest | Yes, `relayMessage` again, and it `require`s `failedMessages[versionedHash]` for any caller that is not the other messenger |
| **Arbitrum, L2→L1** | Yes | `Outbox.spent`, a packed bitmap over the withdrawal's merkle index; `recordOutputAsSpent` reverts `AlreadySpent` | Yes, `executeBridgeCall` bubbles the revert, so a failure rolls the spent bit back |
| **Arbitrum, L1→L2** † | Yes | retryable ticket id, redeemable once | Yes, manual redeem inside the ticket lifetime, ~7 days |
| **Avalanche Warp** | **No** | the precompile verifies a BLS aggregate over the source L1's validator set and nothing else; the word "replay" does not appear in it | n/a, replay is the integrator's problem |
| **Avalanche ICM (Teleporter)** | Yes | `_receivedMessageNonces[messageID]`, written BEFORE execution; `receivedFailedMessageHashes` is a separate record of a delivered message whose execution failed | Yes, `retryMessageExecution`, and see below: this is the only one that retries execution WITHOUT re-delivery |

**† One row is still unverified.** Arbitrum's retryable redeem is implemented in ArbOS, in
Go, and `ArbRetryableTx` in `nitro-contracts` is an interface only, so nothing in that
repository states the guarantee. Every other row here was read from source: OP Stack's
`CrossDomainMessenger` (`develop`), Arbitrum's `AbsOutbox` and `AddressAliasHelper`
(`main`), the Warp precompile's `contract.go` (`master`), and `TeleporterMessenger`
(`main`).

**Eight of the ten provide it, by three shapes, and the difference matters to a binding
author.**

MARK FIRST, THEN CALL PLAINLY: LayerZero, Hyperlane, Axelar, and Arbitrum's outbox. The
write-first order is reentrancy protection; the plain call is what gives retry, because the
revert that fails the payload also rolls the mark back. One state write, both properties.
Arbitrum is the clearest instance: `recordOutputAsSpent` runs before
`executeTransactionImpl`, and `executeBridgeCall` re-throws the callee's revert data
verbatim, so a failed withdrawal is simply not spent.

CALL, THEN RECORD WHICH WAY IT WENT: CCIP and the OP Stack. `relayMessage` makes a
low-level call and branches, `successfulMessages` on success and `failedMessages` on
failure, and the failed entry is what a later replay is required to come from. Two state
writes, and the failure is a recorded state of its own rather than an absence.

MARK DELIVERY FIRST, RECORD EXECUTION SEPARATELY: Avalanche ICM alone, and it is the
strongest of the three. `_markMessageReceived` writes the nonce before
`_handleInitialMessageExecution` runs, so the message can never be delivered twice; the
execution then happens through a bare `call` whose boolean is checked, and a failure is
stored as `receivedFailedMessageHashes[messageID]`. **Delivery and execution are separate
facts**, so `retryMessageExecution` re-runs a failed payload with no new bridge message.
Every other transport here conflates them and needs the message re-delivered.

**The second shape looks like the thing [R3.7](provider-spec.md#r3-receive) forbids, and is
not.** That rule says a BINDING must never wrap the delivery call in `try/catch`, because a
binding that swallows a failure consumes the message and drops the payload. A transport that
catches a failure and RECORDS IT AS REPLAYABLE has done the opposite: it is providing
[P6](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist), not defeating it.
The distinction is whether the failure survives the catch, and on both of these it does.

**Two of the nine are outliers, and they are outliers for one reason.** Wormhole's core
layer and Avalanche's Warp precompile are both signature-verification primitives. They
prove a message was authorised by a validator set and stop there, leaving delivery,
ordering and dedupe to whatever is built on top. Wormhole's own guidance says integrators must
implement replay protection themselves, offering the VAA digest or the
`(emitterChain, emitterAddress, sequence)` triple as the key; Warp's equivalent is the
Teleporter layer above it, which is why ICM appears separately in the table and does provide
it.

So a binding on either primitive is not simply more code: it is code carrying a guarantee
the other seven inherit for free, and it is the one place in this protocol where a binding
holds a security property rather than a translation. Binding to ICM rather than to raw Warp
is the way to avoid that on Avalanche.

**What this settles.** The protocol needs no `requestId` and no per-message nonce of its
own. Correlation never needed one: the receiver report's slot is derived from the
authenticated origin plus the stated `(owner, salt)`, and the slot is write-once.
Idempotency does need one, and it exists at the transport for every candidate here except
the two raw signature primitives. Adding a protocol-level id would put a field on every
channel plus a growing set on every receiver to buy something seven of nine already give.
The correct shape is what is written above: state the requirement, test it per binding, and
make the two that lack it carry the cost in their own `<P>Endpoint`.

Sources, for the five unmarked rows:
[LayerZero `EndpointV2.sol`](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/EndpointV2.sol),
[Hyperlane `Mailbox.sol`](https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/Mailbox.sol),
[CCIP manual execution](https://docs.chain.link/ccip/concepts/manual-execution),
[Axelar Executable](https://docs.axelar.dev/dev/general-message-passing/executable),
[Wormhole core contracts](https://wormhole.com/docs/products/messaging/guides/core-contracts/).

---

## 2. Canonical rollup and subnet transports

Avalanche, the OP Stack and the Arbitrum stack differ from the five above in kind rather
than degree, and the replay matrix is the wrong lens for them. They are not third-party
attestation networks: they are a chain's own bridge, so **the trust model is the chain's
own** and there is no validator set to compromise separately from the chain itself. Against
[P4](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist) and the security
argument in the README that is a strict improvement on every provider in §1.

What disqualifies or constrains them is elsewhere, in three properties the matrix does not
capture.

### Directionality and latency

| | L1 → L2 | L2 → L1 | L2 ↔ L2 |
| --- | --- | --- | --- |
| **OP Stack** | minutes, one step | **~7 days**, two steps: prove, then finalize after the fault-proof window | not without Superchain interop (`L2ToL2CrossDomainMessenger`, and only inside a shared dependency set) |
| **Arbitrum** | minutes, retryable ticket, auto-redeem when funded | **~7 days**, `ArbSys.sendTxToL1` then `Outbox.executeTransaction` after the challenge window | no |
| **Avalanche ICM** | n/a: C-Chain and Avalanche L1s, not Ethereum | n/a | **seconds, any-to-any**, which is the one mesh in this table |

**The asymmetry looks fatal and mostly is not.** This protocol is one-directional by
construction: the hub sends and every destination is a leaf, and the ONLY return leg is the
receiver report. That report fires only where `addressesDiverge`, which is false on both
rollup stacks, since they use Ethereum's CREATE2 formula and the hub computes an account's
address before the first message. So an Ethereum-anchored deployment reaching OP Stack and
Arbitrum spokes over their canonical bridges never needs the slow direction at all.

**It is fatal the other way round.** A deployment anchored ON an L2 with a spoke on its L1
puts every bootstrap and every payload through the seven-day window. That is not a binding
to write; it is a deployment topology to refuse, and it belongs in whatever `script/`
eventually enforces "every spoke names the same home".

### Address aliasing, which is the concrete trap

An L1 CONTRACT that deposits to an L2 does not arrive as itself. Arbitrum and the OP
Stack's `OptimismPortal` both add `0x1111000000000000000000000000000000001111` to the
sender, so the L2 sees an aliased address.

`ReceiverBase.receiveMessage` compares the sender against `sourceTransmitter`, and a
transmitter is a contract, so **a naive canonical binding fails every inbound message**.
The binding MUST un-alias before handing the sender to the protocol.
`AddressDerive.applyL1ToL2Alias` is already in this repo and is the forward direction;
subtracting the same offset is the inverse.

The two stacks differ in whether you have to. OP Stack's `CrossDomainMessenger` un-aliases
for you and exposes the original sender through `xDomainMessageSender()`, so a binding at
that layer sees the real address; one built directly on `OptimismPortal` does not. Arbitrum
has no equivalent, so undoing the alias is the binding's job either way.

**`AddressDerive` carries both directions**, under their own heading rather than zkSync's,
since the same constant serves all three stacks and it is Arbitrum's
`AddressAliasHelper.OFFSET` character for character. `undoL1ToL2Alias` is the one a binding
calls, and its NatSpec carries two traps. It is L1 -> L2 only, so applying it to a
withdrawal corrupts a sender that arrived unaliased. And the arithmetic wraps, so undoing an
alias that was never applied yields a well-formed address belonging to nobody, rather than
reverting. A caller decides from the DIRECTION of the message, never from the value.

Exactly one input undoes to the zero address, the offset itself, which a fuzz case pins.
That is the whole extent of what a zero check on the result would buy, and it is not a
defence.

### Fees and quotes

| | Fee at source, native? | `view` quote? |
| --- | --- | --- |
| **OP Stack** | yes, L2 gas bought through the deposit | **no**: you state `minGasLimit` and pay for it, and there is nothing to ask for a price |
| **Arbitrum** | yes | **partly**: `Inbox.calculateRetryableSubmissionFee(dataLength, baseFee)` is a view, and `NodeInterface.estimateRetryableTicket` covers the L2 gas |
| **Avalanche ICM** | **no**: the relayer incentive is an ERC-20 | n/a |

Arbitrum is the only one of the three that partly satisfies
[P9](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist). OP Stack fails
it and would use the off-chain measurement in
[R2.2.2](provider-spec.md#r2-quote). Avalanche ICM fails
[P8](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist) outright: a
per-chain ERC-20 fee reintroduces exactly the funding matrix the protocol exists to remove,
so a binding would have to pay relayers some other way or accept that signers hold a fee
token per destination.

### None of them is a fan-out

The five providers in §1 are meshes: one binding reaches every chain they support. These
are not. A canonical bridge connects one L2 to one L1, and Avalanche Warp connects
Avalanche L1s to each other and to nothing else. So a canonical strategy means **one
provider registration and one hub transceiver per rollup**, not one for the stack.

That composes without any change to this protocol, since `ChainRegistry` already keys
providers separately and each hub holds its own counterparts. It is also the arrangement
that makes the trust argument worth having. A payload to Optimism trusts Optimism's bridge
and nothing else, rather than trusting one attestation network with every destination at
once. What it costs is N deployments, N `setProvenance` entries, and N sets of routes,
which is the operational load `defaultCounterpart`-style ergonomics exist to keep bearable.

### Chain-level deployment permissioning, which breaks bootstrap and not sends

subnet-evm ships an optional `ContractDeployerAllowList` precompile at
`0x0200000000000000000000000000000000000000`. A chain enables it in genesis, and from then
on only allowlisted addresses may create contracts. It is opt-in, so most chains do not have
it; **two that LayerZero supports do.**

| | precompile | role of an arbitrary address |
| --- | --- | --- |
| Avalanche C-Chain | absent (`eth_getCode` empty) | n/a, deployment is open |
| **DFK Chain** | **active** | `0`, None |
| **Dexalot** | **active** | `0`, None |

**It gates `tx.origin`, not the contract performing the CREATE**, which is the detail that
decides how bad this is, and DFK says so in the error text. Probing it three ways:

```
top-level deploy, non-allowlisted from   ->  "tx.origin 0x1234… is not authorized
                                              to deploy a contract"
CREATE2 via Arachnid's factory, same from ->  execution reverted
CREATE2 via Arachnid's factory, from 0x0  ->  0xb2e363e5…da1e80a1   (0x0 has role Enabled)
```

The factory is a CONTRACT doing the create, and it fails or succeeds purely on who
originated the call. So allowlisting this protocol's transceiver buys nothing.

**What that costs is bootstrap, and only bootstrap.** An account is created inside the
inbound delivery callback, so `tx.origin` there is whoever submitted the delivery
transaction: the provider's relayer or executor, not us and not the owner. On such a chain
path B works only if that relayer is allowlisted, and
[P6](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist)'s permissionless
retry is gone with it, since an arbitrary party retrying a failed bootstrap is exactly an
arbitrary `tx.origin`. Path A is untouched: a normal send creates no contract.

**On these two chains today, LayerZero's executor cannot deploy, so bootstrap cannot
happen.** Not degraded: impossible. The Executor CONTRACT is the wrong thing to check, since
the gate is on the origin, and the origin is the off-chain key that drives it. Recent
deliveries on both chains come from one signing EOA, and it holds no role on either:

| | LayerZero executor contract | its signing EOA `0xe93685f3…` |
| --- | --- | --- |
| DFK Chain | `None` | **`None`** |
| Dexalot | `None` | **`None`** |

**And no arbitrary account can fix that for itself.** Granting is Admin-only, and the
precompile refuses everyone else by name:

```
setEnabled from a random EOA  ->  cannot modify allow list: modify address: 0x1234…,
                                  from role: NoRole, to role: EnabledRole
setEnabled from 0x0           ->  same, though 0x0 holds Enabled on DFK and CAN deploy
setAdmin  from a random EOA   ->  same, to role: AdminRole
```

The second line is the useful one: **Enabled is not Admin**. An address that may deploy
still may not grant, so there is no bootstrapping-by-a-friendly-party route. Making either
chain reachable requires that chain's own admin to allowlist the provider's executor key,
which is a governance ask to a third party, outside both our control and LayerZero's.

**And it is keyed on an operational key, which is the part that does not sit still.** If the
provider rotates its executor signing address, bootstrap breaks again with no change on
either side of this protocol and no event anyone here would see. A deployment that depends
on this arrangement has a liveness dependency on somebody else's key-rotation policy
matching somebody else's governance queue.

**And it generalises past this one precompile.** Any chain policy keyed on `tx.origin`
lands the same way, because everything this protocol does on a destination happens inside
somebody else's transaction. That is the shape to check for, not the precompile address.

**DFK's CREATE2 is EIP-1014**, incidentally: the address it returned is the one computed for
that salt and initcode, which is the same check that settled Aurora.

**Teleporter imposes the same-address property this protocol already relies on.**
`receiveCrossChainMessage` requires `warpMessage.originSenderAddress == address(this)`: the
messenger will only accept a message from a messenger at its own address on the source
chain. That is the account-is-its-own-peer rule one layer down, arrived at independently,
and it means an ICM binding inherits a deployment constraint the protocol was going to
impose anyway.

**Aurora is a parity chain, checked rather than assumed.** NEAR itself runs WASM and has no
EVM, so Solidity does not run on it; Aurora is an EVM implemented AS a NEAR contract, and it
presents as `eip155` chain 1313161554. The question that decides whether it needs anything
of its own is whether its CREATE2 is EIP-1014, and it is. Arachnid's factory is deployed
there at the usual address, and `eth_call`ing it executes on Aurora's own engine rather than
on a local simulation, so it answers directly. Three salts over `CrossProxy`'s initcode
returned exactly the addresses EIP-1014 predicts:

```
salt 00000000…   0x5a6eee7a8eb1d36ef7336bd24c57b975fb9ebc15
salt c0ffee01     0xb2e363e52060ca5f20a59fac76cf1960da1e80a1
salt deadbeef…   0x70e2fc1339425ad82497b92828ac23248b804297
```

So Aurora is `LzSpokeTransceiver` and nothing else: stock solc, so
`CROSS_PROXY_INIT_CODE_HASH` is right, and `addressesDiverge` false. NEAR PROPER is a
different question and not this one: `ChainType.NEAR` is for a Rust receiver addressed by a
named or implicit account, and unlike Move it is not blocked on dispatch, since
`Promise::function_call` takes the method name as a runtime string.

**The same trick does not settle Tron.** Arachnid's factory relies on a pre-signed Ethereum
transaction and is absent from both Tron mainnet and Shasta, so there is no live CREATE2
factory to `eth_call`. That check still needs a funded deployment.

**Avalanche is the odd one and the interesting one.** ICM is a real mesh, sub-minute and
bidirectional, which is a better shape than anything else here; it just cannot reach
Ethereum. It is the transport to reach for if a deployment ever anchors on the C-Chain, and
irrelevant otherwise.

---

## 3. ERC-7786 as a transport

OpenZeppelin ships `interfaces/draft-IERC7786.sol` and `crosschain/ERC7786Recipient.sol`,
and this protocol arrived at nearly the same shape independently: an opaque `bytes` payload
to a recipient named by an interoperable address, with an opaque per-send options blob. So
the question is worth answering once rather than rediscovering per provider.

**The interfaces are vendored, at `src/messaging/IErc7786.sol`.** They are copied byte for
byte from OpenZeppelin 5.5.0's `draft-IERC7786.sol`. The `draft-` prefix is upstream saying
it may change the API in a minor release, and these two interfaces are this protocol's ABI:
an event topic, a selector, an argument order. Holding the copy makes a change a
reviewed diff on our schedule rather than a side effect of a dependency bump.

**The core contracts implement `IERC7786GatewaySource` and `IERC7786Recipient` directly**,
the route slot holds a chain identifier, and `TransceiverBase._recipientOn` builds the
recipient. `CrosschainLinked(Upgradeable)` is NOT adopted: it sits behind `Bytes.sol` and
its four `mcopy` sites, so it cannot compile at `paris`, and independently its per-contract
`_links` table and its own gateway allowlist would replace the shared-transceiver routing
and bypass the registry's provenance dial. The analysis below is the reasoning behind that,
and the gaps it names are the protocol's gaps.

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
| `_sendMessage(recipient, payload, attributes, value)` | `gateway.sendMessage{value: value}(recipient, payload, attributes)`, one to one. Pay from `value`, never from `msg.value` |
| `_quoteMessage(...)` | **nothing.** See below |
| `_onInbound(route, sender, message)` | called from `receiveMessage(receiveId, sender, payload)`, splitting the sender envelope with `Erc7930.toChainIdentifier` for the route and `parseStrict(...).addr` for the sender |
| `attributes` | passed straight through |

The inbound split is the useful part: `Erc7930.toChainIdentifier` already reduces an
account envelope to a bare chain identifier, which is exactly the `route` the hub's
`chainKeyOfRoute` and the spoke's `_isHome` expect. `_authenticateOrigin` needs no override
on either side.

### What ERC-7786 gives up

1. **No quote, at all.** The interface is `supportsAttribute` and `sendMessage`. A payable
   send with no way to ask its price fails [P9](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist)
   and kills eight functions of read surface. This is the largest cost and the reason to
   prefer a native SDK where one exists. Fallbacks are in [R2.2.2](provider-spec.md#r2-quote).
2. **`sendMessage` may not complete the send.** It returns a `sendId`, and a non-zero value
   means further gateway-specific, non-standardised action is required. `_sendMessage`
   passes that id straight back and nothing here acts on it, so a binding must either handle
   the second step or restrict itself to gateways that return zero, and say which.
3. **No mandated exactly-once.** The standard defines a `receiveId` for correlation but
   requires nothing about replay, so [R3.5](provider-spec.md#r3-receive) stays a per-gateway question rather
   than being answered by the standard. Note the `receiveId` is free where our own channels
   carry no id; see `InboundBase.receiveMessage` for why we concluded none was needed.

### The other draft worth knowing about

`utils/draft-InteroperableAddress.sol` is OpenZeppelin's ERC-7930. It covers the same
ground as this repo's `src/addressing/Erc7930.sol`, with `formatEvmV1`, `parseEvmV1`, and
`try` and calldata variants. Replacing ours with it is a real candidate:
audited, maintained, and one fewer library to own.

Two things block a straight swap. It is a `draft-`, which OpenZeppelin explicitly excludes
from its API stability guarantee and may change in a MINOR release, and this codebase freezes
accounts against exact bytes. And `Erc7930.parseStrict` enforces strictness the registry
depends on, rejecting non-minimal `eip155` references and trailing bytes; whether `parseV1`
matches has not been checked. Neither is a reason not to do it, both are reasons it is its
own task with its own vectors.

**Declined**, separately: moving `Erc7930.sol` onto this draft would mean bumping this
repo's pinned OpenZeppelin past 5.4.0, and that bump is the same one that breaks
`AccessControlEnumerableUpgradeable`'s compilation at `paris` from 5.5.0 onward (see
`Roles.sol`). The dependency the swap would need is the dependency the pin cannot survive,
so it stays declined until the pin itself is revisited (see
[`todo.md`](todo.md#2-decisions-taken-that-deserve-a-second-look)).

---

## 4. CCIP as a native binding

Chainlink CCIP, read the same way LayerZero was in
[§8](#8-layerzero-as-a-native-binding): what a real
`contracts/evm/src/protocols/ccip/` binding would inherit, and what it owes R3.3 and R5.
Source: `smartcontractkit/ccip`, branch `ccip-develop`, commit `171f9f0c`, reading
`contracts/src/v0.8/ccip/applications/CCIPReceiver.sol`,
`contracts/src/v0.8/ccip/interfaces/{IAny2EVMMessageReceiver,IRouterClient}.sol`, and
`contracts/src/v0.8/ccip/libraries/Client.sol`.

**One Router, both directions.** A chain's CCIP `Router` implements `IRouterClient`
(`getFee(selector, message) view`, `ccipSend(selector, message) payable`) for the send side,
and is the only contract CCIP will ever call `ccipReceive` from. One `GATEWAY_ROLE` grant
covers both, the same as every other candidate here.

**The chain identifier is a `uint64` selector, not an EVM chain id.** `destChainSelector` /
`sourceChainSelector` are CCIP's own per-chain values. Same shape as LayerZero's `eid` and
Hyperlane's `domain`: a native CCIP binding needs its own chainKey↔selector table, under
[R5](provider-spec.md#5-the-route-codec), same as either of them.

**The wire addresses are ABI-encoded, not raw bytes.** `Client.EVM2AnyMessage.receiver` is
`abi.encode(address)` for an EVM destination, and `Client.Any2EVMMessage.sender` is
`abi.decode`d the same way for an EVM source. Neither is a raw 20-byte slice, which is what
LayerZero and a bare EVM address use; a binding's `_authenticateSender` narrowing has to
`abi.decode`, not slice.

**A native `view` quote, satisfying P9 outright.** `getFee` prices the exact message with no
fallback needed, unlike ERC-7786 (no quote at all) or OP Stack (no quote, an off-chain
measurement instead). `feeToken = address(0)` pays in native currency through `msg.value`,
which is the only choice consistent with
[P8](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist): CCIP also supports
paying in LINK, and using it would reintroduce exactly the per-chain funding-token matrix P8
exists to avoid.

**`CCIPReceiver` carries zero storage and zero external dependency.** It holds one
`immutable` (`i_ccipRouter`, set in the constructor — same "one constructor argument, on the
implementation, and it does not matter" shape as LayerZero's `OAppCoreUpgradeable` endpoint:
see [§8](#8-layerzero-as-a-native-binding)) and vendors its own tiny copy of
`IERC165` rather than importing OpenZeppelin's. No storage-layout question, no OZ-version
question. This is the cleanest of the three candidates to fit into this repo's proxy layout.

**No R3.3-style exception needed, provided a binding skips `CCIPReceiver` itself.**
`CCIPReceiver.ccipReceive` is gated by `onlyRouter`
(`msg.sender == i_ccipRouter`) alone — a transport-identity check, exactly what
`GATEWAY_ROLE` already answers — and asserts nothing about who sent the message on the
SOURCE chain. Unlike LayerZero's `_lzReceive`, which authenticates the peer BEFORE handing
control to the app and cannot be bypassed without forking the receive path, CCIP's own base
contract does not check the source-chain sender at all: that is left entirely to the
application. So a binding that implements `IAny2EVMMessageReceiver.ccipReceive` directly,
gated by `onlyRole(GATEWAY_ROLE)`, and authenticates the source chain and sender purely
through `_authenticateOrigin`, has exactly one origin check, in exactly one place — the rule
`_onInbound`'s NatSpec states, with nothing to write an exception for.

**Licensing is mixed, and matters for what gets vendored.** The infrastructure contracts
this protocol only ever CALLS (`Router.sol` itself, `FeeQuoter.sol`, the on-ramp/off-ramp
internals) are `BUSL-1.1`. The application-facing files a binding would actually vendor —
`CCIPReceiver.sol`, `IAny2EVMMessageReceiver.sol`, `IRouterClient.sol`, `Client.sol` — are
each individually tagged `MIT` in their own SPDX header. Worth a second look before mainnet
regardless, the way any vendored license is, but the files this binding needs are not the
BUSL ones.

**Replay is already covered.** §1's matrix already records CCIP's dedupe
(`s_executionStates[selector][seqNum]`, `SUCCESS` terminal, manual re-execution from
`FAILURE`); nothing here changes that finding.

---

## 5. Hyperlane as a native binding

Hyperlane, read the same way. What a real `contracts/evm/src/protocols/hyperlane/` binding
would inherit, and the one finding that rules out inheriting most of it. Source:
`hyperlane-xyz/hyperlane-monorepo`, branch `main`, commit `983831f6`, reading
`solidity/contracts/{Mailbox.sol,PackageVersioned.sol}`,
`solidity/contracts/client/{MailboxClient,Router}.sol`,
`solidity/contracts/interfaces/{IMailbox,IMessageRecipient}.sol`,
`solidity/contracts/libs/TypeCasts.sol`, and `solidity/remappings.txt`.

**One Mailbox, both directions.** `dispatch`/`quoteDispatch` (send) and `process` (the
permissionless relay call that verifies the message's ISM and then calls the recipient's
`handle`) live on the same `Mailbox` contract. One `GATEWAY_ROLE` grant covers both.

**The chain identifier is a `uint32` domain, not reliably an EVM chain id.** It conventionally
equals the EVM chain id for EVM chains, but that is a convention, not a guarantee the
protocol may depend on, and it is not even meaningful for a non-EVM chain. A native Hyperlane
binding needs its own chainKey↔domain table, same as LayerZero's `eid` and CCIP's selector,
under [R5](provider-spec.md#5-the-route-codec).

**A native `view` quote.** `IMailbox.quoteDispatch(domain, recipient, body[, hookMetadata,
hook])` prices the exact send, satisfying
[P9](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist) outright, the same
shape as CCIP's `getFee`.

**Addresses are `bytes32`, via a pure library.** `TypeCasts.addressToBytes32` /
`bytes32ToAddress` (alignment-preserving casts, no imports, nothing to collide with) are the
whole of it, and safe to vendor standalone regardless of what else is.

**THE FINDING THAT MATTERS MOST: `MailboxClient` and `Router` cannot be inherited into this
repo's proxies at all, and it is not a style question.** Both bring `OwnableUpgradeable`, and
`hyperlane-monorepo`'s own `remappings.txt` pins
`@openzeppelin/contracts-upgradeable/=dependencies/@openzeppelin-contracts-upgradeable-4.9.3/`.
`MailboxClient._MailboxClient_initialize` calls `__Ownable_init()` with NO argument, which is
OpenZeppelin 4.x's signature; this repo is pinned to 5.4.0, whose `OwnableUpgradeable` takes
an explicit initial owner and has no zero-argument overload at all. The two versions cannot
occupy one inheritance graph — Solidity will not compile two incompatible definitions of the
same base reached through different import paths. This is a harder wall than the
`draft-InteroperableAddress` OZ-bump question above: that one is blocked by a compile-target
collision (`paris` vs `mcopy`) that in principle a version choice could still resolve; this
one is blocked by two SHIPPED, INCOMPATIBLE major versions of the same contract, and nothing
about how either project builds changes that.

**The fix costs nothing, because the useful parts have no OZ dependency at all.**
`IMailbox.sol`, `IMessageRecipient.sol`, `IInterchainSecurityModule.sol`, and `TypeCasts.sol`
are plain interfaces and a pure library — no OpenZeppelin imports, no version to collide
with. (`IMailbox` imports `IPostDispatchHook`, itself a plain interface, and
`StandardHookMetadata` carries the refund address, so the vendored set is six files; see
`contracts/evm/script/vendor/hyperlane.sh`.) A real binding vendors those six, holds the `IMailbox` address as its OWN immutable (the same "one
constructor argument, on the implementation" shape used everywhere else in this survey), and
implements `IMessageRecipient.handle(uint32 origin, bytes32 sender, bytes calldata message)`
itself, gated by `onlyRole(GATEWAY_ROLE)` rather than `MailboxClient`'s `onlyMailbox`
modifier. Since neither `MailboxClient` nor `Router` is inherited, their `uint256[48] __GAP`
storage reservations never enter this repo's layout at all — there is nothing to collide
with, because there is nothing there.

**Skipping `Router` is independently correct, aside from the OZ collision.** `Router.handle`
checks an enrolled-router-per-domain mapping (`_routers`) BEFORE calling the app's own
`_handle` — the exact shape already rejected for OpenZeppelin's `CrosschainLinked` in
[§3](#3-erc-7786-as-a-transport): "its own gateway allowlist would replace the
shared-transceiver routing and bypass the registry's provenance dial." A binding built
directly on `IMessageRecipient` has no such allowlist to bypass.

**No R3.3-style exception needed, PROVIDED `Router` is skipped.** `Mailbox.process`
authenticates that a message passed its configured ISM before calling `handle` — a statement
about the message, not about which contract sent it on the source chain. The per-domain peer
check is `Router`'s own optional layer, not `Mailbox`'s. So a binding built directly on
`IMessageRecipient` + `IMailbox`, authenticating solely through `_authenticateOrigin`, has
exactly one origin check, in exactly one place, matching `_onInbound`'s stated rule — unlike
LayerZero, where the peer check is inside `_lzReceive` itself and there is no opting out of
it short of forking the receive path.

**Licensing is uniform and clean.** Every file read here is `MIT OR Apache-2.0`. No BUSL
question, unlike CCIP's mixed repository.

**Replay is already covered.** §1's matrix already records Hyperlane's dedupe
(`deliveries[messageId]` in `Mailbox`, written before `handle()`, `already delivered`
guarded); nothing here changes that finding.

---

## 6. Wormhole: Core vs. the Relayer are two different bindings

Read because Wormhole is qualitatively different from the other three, and §1's replay
matrix already flags it as one of only two outliers (with Avalanche's raw Warp precompile)
that leave dedupe to the integrator. Worth its own section because "Wormhole" names two
separable products with almost nothing in common at the interface level, and only one of
them is a template-comparable addition. Source: `wormhole-foundation/wormhole`, `main`,
commit `2df4000c`, reading `ethereum/contracts/interfaces/IWormhole.sol`; and
`wormhole-foundation/wormhole-solidity-sdk`, `main`, commit `2cb855ea`, reading
`src/interfaces/IWormholeRelayer.sol`.

### Core (`IWormhole`): the trust-minimized primitive, and the hard case

**`publishMessage` names no destination.** `publishMessage(nonce, payload,
consistencyLevel) payable returns (sequence)` takes no target chain and no target address at
all. It only emits `LogMessagePublished`; the guardian network observes that event
off-chain and signs a VAA attesting to `(emitterChainId, emitterAddress, sequence, payload)`.
Where that VAA goes, and whether it goes anywhere, is decided entirely off-protocol, by
whoever chooses to do something with it.

**There is no delivery, so there is no delivery-inclusive quote.** `messageFee()` is a flat,
tiny anti-spam fee paid on the SOURCE chain — unrelated to destination gas. Every other
provider surveyed here (LayerZero, CCIP, Hyperlane, and Wormhole's own Relayer below) prices
the full round trip in one native-currency number; bare Core has nothing to ask. A binding on
it falls back to the off-chain measurement already documented for OP Stack in
[§2](#2-canonical-rollup-and-subnet-transports), not to a `_quoteMessage` override that
answers on-chain.

**No push callback, and therefore no caller to gate.** `parseAndVerifyVM(encodedVM) view
returns (vm, valid, reason)` is a pure verification function. Wormhole Core never calls
anything. A binding has to expose its own external entry point that accepts a raw VAA from
WHOEVER submits it, calls `parseAndVerifyVM` itself, and proceeds only if `valid`. There is
no address to grant `GATEWAY_ROLE` to for this channel, because there is no fixed caller:
authenticity comes entirely from the guardian signatures inside the VAA, checked by
`_authenticateSender` against `vm.emitterChainId`/`vm.emitterAddress`, with nothing checking
"who submitted this transaction" at all. That is not a gap relative to the other bindings:
`_authenticateSender`, `_onMessage`, and `_onInbound` are already `internal`, so this
entry point reaches the same seam CCIP and Hyperlane already reuse — it is simply the first
candidate whose entry point has no role check in front of that seam.

**No replay protection, confirmed against the full interface, not assumed.** There is no
`delivered`/`consumed` mapping for an ordinary message anywhere in `IWormhole` —
`governanceActionIsConsumed` exists, and it is scoped to governance actions only. A binding
on bare Core is the first candidate in this survey to actually trigger
[R3.5](provider-spec.md#r3-receive) ("a binding whose transport does not provide it MUST
supply it"): it needs its own consumed-VAA-hash map, held on the binding's own receiver
contract exactly the way a peer table or an eid table already lives on a binding rather than
on `ReceiverBase`.

**Bootstrap (path B) is the one place bare Core's permissionless-relay model is a fit rather
than a cost.** `bootstrap` is already designed to be callable by anyone willing to pay for
it; a permissionlessly-submittable VAA composes with that directly, no special-casing
required.

### The Relayer (`IWormholeRelayer`): the template-comparable case

A separate product built on top of Core, not a mode of it. Confusingly also called
"Wormhole" in most integration guides, which is the reason this distinction is worth
recording rather than assuming.

| Our hook | Wormhole Relayer |
| --- | --- |
| `_sendMessage(recipient, payload, attributes, value)` | `sendPayloadToEvm(targetChain, targetAddress, payload, receiverValue, gasLimit){value}`: an explicit destination, finally |
| `_quoteMessage(recipient, payload, attributes)` | `quoteEVMDeliveryPrice(targetChain, receiverValue, gasLimit).nativePriceQuote`: destination-inclusive, in this chain's native currency, matching `_quoteMessage`'s contract exactly |
| `GATEWAY_ROLE` | granted to the Relayer contract, same pattern as the other three |
| inbound | `IWormholeReceiver.receiveWormholeMessages(payload, additionalMessages, sourceAddress, sourceChainId, deliveryHash)`: a real push callback |

**Dedupe exists at this layer.** `deliveryAttempted(bytes32 deliveryHash) view returns
(bool)` tracks delivery the way LZ/CCIP/Hyperlane already do, so R3.5 is satisfied the same
way it is for them — a binding on the Relayer does not need the consumed-hash map bare Core
would require. (Checked against the implementation for Phase 5: `executeDelivery` refuses a hash
already in `deliverySuccessBlock`; a failed delivery can be retried. A reverting
`receiveWormholeMessages` does not revert the delivery transaction. The implementation was
read at `wormhole-foundation/wormhole` `932a2e0a2c`, the parent of the commit that deleted
it from that repo.)

**The chain id is `uint16`, "Wormhole Chain ID" format** — a fourth provider-native width,
and the reason [`ProviderChainId`](../contracts/evm/src/protocols/ProviderChainId.sol)
(Phase 0 of the provider-bindings work) was built `uint256`-widened rather than sized to any
one provider: a fourth candidate slots into the existing table with no changes to it.

**The trust assumption moves, and is worth weighing on its own rather than assumed away.**
Message AUTHENTICITY still rests on the guardian-signed VAA underneath — the Relayer does
not weaken that. But delivery LIVENESS now also depends on a delivery-provider marketplace
(a "default delivery provider," typically Wormhole Labs-operated, or an alternate one named
by address) actually submitting the transaction. That is a second dependency the other three
bindings do not add: LayerZero's executor, CCIP's off-ramp, and Hyperlane's relayer are each
also third parties, so this is not unique to Wormhole, but it is a fact to grade the same way
`Provenance` already grades a counterpart's address claim, not to wave through because the
signature underneath is sound.

### Update (Phase 5): the Standard Relayer is deprecated; the binding uses Core + Executor

Wormhole now marks the Standard Relayer deprecated and points integrators to the Executor
framework (`wormhole-docs`, `protocol/infrastructure/relayers/relayer.md` and
`executor-vs-sr.md`; Relayer source removed from the core repo in
wormhole-foundation/wormhole#4644, "deprecated generic relayer"). No sunset date was found.
The binding therefore takes the Core path above, with the Executor for delivery:

| Our hook | Wormhole Core + Executor |
| --- | --- |
| `_sendMessage` | `ICoreBridge.publishMessage{messageFee}` then `IExecutorQuoterRouter.requestExecution{rest}`; the router refunds its overpayment to `refundAddr` |
| `_quoteMessage` | `messageFee() + IExecutorQuoterRouter.quoteExecution(...)`, a `view` (wormhole-solidity-sdk#118, Feb 2026) |
| inbound | `IVaaV1Receiver.executeVAAv1(vaa)`, permissionless; verified via `parseAndVerifyVM` |
| replay | the binding's own consumed-hash set, as the Core section above anticipated |

Two facts the Relayer used to cover: a VAA names no destination, so the binding prefixes the
payload with `(targetChain, targetAddress)` and checks both; and `GATEWAY_ROLE` has no caller
to name, so it is granted to the Core bridge and checked by membership. Sources:
`wormhole-solidity-sdk @ 2cb855ea` (`interfaces/ICoreBridge.sol`, `interfaces/IExecutor.sol`,
`Executor/Request.sol`, `Executor/Integration.sol`) and
`wormholelabs-xyz/example-messaging-executor @ 55f94274` (`ExecutorQuoterRouter.sol`,
`Executor.sol`).

### What this means for scope

Neither variant requires changing anything in the shared base contracts. `_sendMessage`/
`_quoteMessage` are already `virtual` per-binding overrides; `_authenticateSender`,
`_onMessage`, and `_onInbound` are already `internal` and reusable by any provider-specific
entry point regardless of that entry point's own gating; `Roles`/`GATEWAY_ROLE` needs no
change either way. The Relayer binding is a template-comparable addition, the same shape as
LZ/CCIP/Hyperlane. A bare-Core binding is real, additional, self-contained work — a
permissionless entry point and a replay-protection map, both local to a new
`protocols/wormhole/` binding — not a gap in what already exists.

---

## 7. OP Stack as a native binding

[§2](#2-canonical-rollup-and-subnet-transports) already covers latency, aliasing, fees, and
the no-fan-out property at the level of what disqualifies or constrains a canonical rollup
bridge generally. This section is the interface-level follow-up, read the same way CCIP,
Hyperlane, and Wormhole were: what a real `contracts/evm/src/protocols/op-stack/` binding
would inherit, and the one thing about its shape that is not like the other four. Source:
`ethereum-optimism/optimism`, `develop`, commit `0abfb166`, reading
`packages/contracts-bedrock/interfaces/universal/ICrossDomainMessenger.sol`.

**No chain id, and no chain-id table, because there is no fan-out to name.**
`sendMessage(address _target, bytes memory _message, uint32 _minGasLimit) external payable`
takes no destination chain at all. Each OP Stack chain has its OWN dedicated
`L1CrossDomainMessenger` deployed at its own address on L1; the destination IS which
messenger contract you call, not an argument to it. This is the concrete form of what §2
already concluded — "one hub transceiver per rollup, not one for the stack" — and it means
[`ProviderChainId`](../contracts/evm/src/protocols/ProviderChainId.sol) does not apply to
this binding at all. A hub transceiver for a given OP Stack chain holds that chain's
messenger address as its own immutable and never needs a second entry; deploying to another
OP Stack chain means deploying another hub transceiver instance, not adding a row to a
table.

**No on-chain quote, confirmed against the full interface.** There is no `quote`-shaped
function anywhere in `ICrossDomainMessenger`. `baseGas(message, minGasLimit)` exists, but it
returns a `uint64` GAS OVERHEAD, not a native-currency price — it still has to be combined
with an off-chain gas price to produce a `msg.value`. This confirms §2's finding
("no view quote... there is nothing to ask for a price") at the interface level: a binding's
`_quoteMessage` has nothing to answer from, and uses the off-chain measurement in
[R2.2.2](provider-spec.md#r2-quote), the same escape hatch already documented for bare
Wormhole Core.

**Correction (Phase 6): the native quote is zero, not missing.** Checked against
`CrossDomainMessenger.sendMessage` and `ResourceMetering` at the same commit: a deposit's L2
gas is paid by burning L1 gas in the sending transaction, and `sendMessage` forwards
`msg.value` to the target as bridged ETH (`relayMessage` calls the target with `_value`).
Nothing is charged in `msg.value`, so the binding requires zero value and quotes zero, which
is what the R2.2.2 balance-delta measurement would report. `baseGas` remains the only
price-shaped function, and it prices gas, not currency.

**THE SHARP EDGE: the authenticated sender is retrieved by a callback, never carried as an
argument, and treating it as one would be a real vulnerability rather than a style choice.**
`relayMessage(nonce, sender, target, value, minGasLimit, message)` makes a low-level call to
`target` with `message` as calldata — calldata that whoever called `sendMessage` on the
ORIGIN domain chose, in full, since `sendMessage` is permissionless and anyone may target
this protocol's receiver with it. Every other provider surveyed hands the authenticated
origin to the callback as a value the TRANSPORT computed (LayerZero's `Origin`, Hyperlane's
`sender`, CCIP's `message.sender`, Wormhole's `sourceAddress`). OP Stack does not: nothing
about `message`'s own bytes is trustworthy, because the caller who published it wrote every
byte of it themselves. The only fact the protocol actually guarantees is retrievable
separately, by calling `xDomainMessageSender()` on the messenger — `msg.sender` from the
called contract's own perspective — DURING the execution `relayMessage` triggers. A binding
MUST call this itself and MUST NOT accept a "sender" as part of `message`'s own payload; an
entry point that trusted a self-declared sender argument would let anyone impersonate this
account's transmitter simply by encoding a claim to that effect in `message`, since nothing
about `sendMessage` checks who is calling it or what they claim. `_authenticateSender` still
does the real comparison against `sourceTransmitter`; what changes is where the value being
compared comes from.

**Binding at this layer is what makes aliasing someone else's problem.** §2 already notes
`OptimismPortal` requires undoing `AddressAliasHelper`'s offset yourself
(`AddressDerive.undoL1ToL2Alias` exists in this repo for exactly that), while
`CrossDomainMessenger` un-aliases internally and hands back the real address through
`xDomainMessageSender()`. Binding here, one layer up, means `AddressDerive`'s alias-undoing
path stays unused by this binding entirely — it would only be needed by a binding built
directly on `OptimismPortal`, which this is deliberately not.

**No divergent-spoke variant, unlike the other three.** zkSync and Tron need
`ZkSyncSpokeTransceiver`/`TronSpokeTransceiver` because their CREATE2 formulas differ from
Ethereum's. An OP Stack chain runs standard `op-geth` and Ethereum's own CREATE2 formula, so
it is always the parity case; there is no OP-Stack-flavoured divergence to name a contract
for, and `OpStackDivergentSpokeTransceiver` would have nothing to override.

**No OZ dependency, no storage, same clean shape as CCIP's and Wormhole's interfaces.**
`ICrossDomainMessenger` is a plain interface with zero imports. A transmitter stays plain
`OwnableUpgradeable`, the same conclusion reached for CCIP, Hyperlane, and Wormhole: there is
no SDK `Ownable` here to merge with, unlike LayerZero's OApp.

**Replay is already covered**, and was covered before this section existed: §1's matrix
already records `successfulMessages`/`failedMessages` in `CrossDomainMessenger`, the
call-then-record-which-way-it-went shape shared with CCIP.

---

## 8. LayerZero as a native binding

The first binding, and the one the others were read against. Built as
`contracts/evm/src/protocols/layerzero/` on the vendored files below; the per-file commits
are in `contracts/evm/script/vendor/layerzero.sh`.

### What was found in the package

Verified against `@layerzerolabs/oapp-evm-upgradeable@0.1.3` (it imports interfaces from
`@layerzerolabs/oapp-evm`, 0.4.1 at the time of checking). Both are vendored under
`contracts/evm/lib/`.

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

### Two consequences, both settled

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
  the R3.3 exception, taken in each LayerZero contract's NatSpec: for a 1:1 pairing there is
  nothing extra to verify. The receiver checks `GATEWAY_ROLE` on top, so `revokeGateway` still
  disconnects LayerZero.
