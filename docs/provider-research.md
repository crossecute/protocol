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
implementing the standard directly.

| Section | Pinned to | Goes stale when |
| --- | --- | --- |
| [1. Transport replay](#1-what-each-transport-guarantees-about-replay) | source as read: LayerZero V2, Hyperlane, CCIP, Axelar, Wormhole core, OP `CrossDomainMessenger`, Arbitrum `AbsOutbox`, Warp `contract.go`, `TeleporterMessenger`. Arbitrum's L1→L2 retryable is ArbOS Go and remains unread | any of them changes how a delivered message is marked consumed |
| [2. Canonical transports](#2-canonical-rollup-and-subnet-transports) | OP Stack, Arbitrum and Avalanche; the aliasing and same-address findings are from source, the latency and fee figures from documentation | a fault-proof window changes, Superchain interop ships, or ICM changes its fee model |
| [3. ERC-7786](#3-erc-7786-as-a-transport) | OpenZeppelin 5.6.1 `draft-IERC7786`, `draft-InteroperableAddress` | OpenZeppelin ships a minor release, which for a `draft-` may change the API |

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
writes, and the failure is a first-class state rather than an absence.

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
layer and Avalanche's Warp precompile are both signature-verification primitives: they prove
a message was authorised by a validator set and stop there, with delivery, ordering and
dedupe left to whatever is built on top. Wormhole's own guidance says integrators must
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

**Two things about our helper.** `AddressDerive.applyL1ToL2Alias` uses
`0x1111000000000000000000000000000000001111` and an unchecked add, which is Arbitrum's
`AddressAliasHelper.OFFSET` and `applyL1ToL2Alias` character for character, so it is
correct for both stacks. But it sits in the file's zkSync section, which reads as though it
were zkSync-specific, and there is no inverse: a binding needs the SUBTRACTION, and it is
the direction nothing here provides.

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
providers separately and each hub holds its own counterparts, and it is the arrangement
that makes the trust argument worth having: a payload to Optimism trusts Optimism's bridge
and nothing else, rather than trusting one attestation network with every destination at
once. What it costs is N deployments, N `setProvenance` entries, and N sets of routes,
which is the operational load `defaultCounterpart`-style ergonomics exist to keep bearable.

**Teleporter imposes the same-address property this protocol already relies on.**
`receiveCrossChainMessage` requires `warpMessage.originSenderAddress == address(this)`: the
messenger will only accept a message from a messenger at its own address on the source
chain. That is the account-is-its-own-peer rule one layer down, arrived at independently,
and it means an ICM binding inherits a deployment constraint the protocol was going to
impose anyway.

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

**The core contracts implement `IERC7786GatewaySource` and `IERC7786Recipient` directly**,
the route slot holds a chain identifier, and `TransceiverBase._recipientOn` builds the
recipient. `CrosschainLinked(Upgradeable)` is NOT adopted: it sits behind `Bytes.sol` and
its four `mcopy` sites, so it cannot compile at `paris`, and independently its per-contract
`_links` table and `_isAuthorizedGateway` would replace the shared-transceiver routing and
bypass the registry's provenance dial. The analysis below is the reasoning behind that, and
the gaps it names are the protocol's gaps.

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
   send with no way to ask its price fails [P9](provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist)
   and kills eight functions of read surface. This is the largest cost and the reason to
   prefer a native SDK where one exists. Fallbacks are in [R2.2.2](provider-spec.md#r2-quote).
2. **`sendMessage` may not complete the send.** It returns a `sendId`, and a non-zero value
   means further gateway-specific, non-standardised action is required. `_sendMessage`
   returns nothing and assumes the message is away, so a binding must either handle a
   two-step send or restrict itself to gateways that return zero, and say which.
3. **No mandated exactly-once.** The standard defines a `receiveId` for correlation but
   requires nothing about replay, so [R3.5](provider-spec.md#r3-receive) stays a per-gateway question rather
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
