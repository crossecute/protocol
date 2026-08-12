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
[ERC-7786 analysis](#2-erc-7786-as-a-transport) is the reasoning behind the core contracts
implementing the standard directly.

| Section | Pinned to | Goes stale when |
| --- | --- | --- |
| [1. Transport replay](#1-what-each-transport-guarantees-about-replay) | LayerZero V2, Hyperlane, CCIP, Axelar, Wormhole core, as deployed when checked | any of them changes how a delivered message is marked consumed |
| [2. ERC-7786](#2-erc-7786-as-a-transport) | OpenZeppelin 5.6.1 `draft-IERC7786`, `draft-InteroperableAddress` | OpenZeppelin ships a minor release, which for a `draft-` may change the API |

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

**The pattern is the same in all four that provide it, and it is worth naming**: write the
consumed mark FIRST, then make a plain external call to the receiver. The write-first order
is reentrancy protection; the plain call is what gives retry, because the revert that fails
the payload also rolls the mark back. One mechanism, both properties. A binding that wraps
that call in `try/catch` breaks the second while appearing to improve it, which is
[R3.7](provider-spec.md#r3-receive).

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

## 2. ERC-7786 as a transport

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
