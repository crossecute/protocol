# xsafe protocol

Secure multisig operations across chains, anchored on one of them.

## The idea

**One owner, one address, every chain.** An owner's account is deployed at
`CREATE2(transceiver, keccak256(owner, salt), XSafeProxy)` — and because all three inputs
are the same everywhere, so is the address. On the **home chain** it is armed with
transmitter logic and driven by its owner; on every other chain it is armed with receiver
logic and driven by messages from the first. Same address, different half.

**The home chain is a choice.** Ethereum is the expected anchor and the reason the protocol
reads that way, but nothing requires it: a team can centralize on whichever chain they are
willing to anchor to, and every spoke names that one instead. A spoke is exactly as rigid
either way — its home chainKey, route, and counterpart are all written once at
initialization with no setters. What the home chain *must* be is an EVM chain with the
EIP-152 precompile, because the registry recomputes addresses and commitments locally.

Two paths, and only the second involves a transceiver:

```
A · normal send    owner → account.send(8453, calls)
                        ══ bridge ══
                   → its own account on Base: decode, execute        nonReentrant

B · bootstrap      owner → account.bootstrap(8453, calls)
                   → hub transceiver: (owner, salt, calls)           ← provenance bar
                        ══ bridge ══
                   → spoke transceiver: deploy the account, arm it,
                     run the payload, drop the upgrade key — one call
                        ══ bridge ══
                   → hub → registry: where it landed
```

Path B runs once per chain. After it, the account talks to its counterpart directly and no
shared contract is in the path of a normal message.

**Committing is a call, not a message kind.** To approve a payload now and run it later,
send one whose single element calls the receiver's own `commit`. Nothing on the wire
distinguishes it from any other payload, which is why there is no message-type tag anywhere
in the protocol.

## Layout

```
src/
  addressing/     Erc7930, ChainType, ChainKey, Move        no imports outside itself
  derivation/     AddressDerive, VmDeriver, Starknet/Sui, Blake2b256
  registry/       ChainRegistry, ForeignRef, IRefValidator, IChainRegistryRefs
  validators/     StarknetValidator, MoveValidator          pluggable, per chainKey
  messaging/      Commitment, Call, Payload, Envelope, Executor
    outbound/     OutboundBase -> TransmitterBase
    inbound/      ReceiverBase
    transceiver/  TransceiverBase -> Hub / Spoke
  factories/      XSafeProxy
  protocols/      per message provider; the only files naming an SDK
```

Dependencies run one way — `addressing` is a leaf, and nothing above it is imported by
anything below:

```
addressing <- derivation <- registry <- validators
     ^                          ^
     +------- messaging --------+ <- protocols
```

There is no `libs/` or `utils/`. A folder named for what a file *is not* is a place to put
things rather than a statement about them.

## Where the reasoning lives

Every design decision is argued in the contract that implements it. This is an index, not a
summary — the file is always the newer statement.

| Question | Answered in |
| --- | --- |
| Why one address, and why a proxy rather than a clone | `factories/XSafeProxy.sol` |
| How an account is created, and why its upgrade key dies in the same call | `TransceiverBase._createXSafeAccount` |
| Why a hub makes transmitters and a spoke makes receivers | `TransceiverBase`, `Hub` / `Spoke` |
| Why approvals are an ordered queue, and why `cancel` is load-bearing | `inbound/ReceiverBase.sol` |
| Why the wire carries a payload rather than a digest | `outbound/OutboundBase.sol` |
| Why `Call[]` reaches EVM chains and opaque `bytes[]` everything else | `messaging/Payload.sol` |
| Why a commitment is defined over elements nothing here parses | `messaging/Commitment.sol` |
| Why a stored location is graded, and what each grade is worth | `registry/ForeignRef.sol` |
| Why routes live on the transceiver rather than in the registry | `TransceiverBase.setRoute` |
| Why neither base inherits an ownership system | `TransmitterBase`, `TransceiverBase` |
| Why a chain type needs more than a `ChainType` constant | `addressing/Erc7930.sol` |

## Assumptions

- All contracts are created through Arachnid's CREATE2 factory with a salt — `0x4e59..`
  where it exists; zk-chains use their own.
- Compiled against `evm_version = "paris"`, pinned in `contracts/evm/foundry.toml`. PUSH0
  (Shanghai) is absent on zkSync, Tron, and several L2s, and CREATE2 parity requires
  byte-identical initcode on every chain — so the target must not vary. Optimizer settings
  are pinned for the same reason.
- Transceivers are deployed as upgradeable proxies, upgraded to their real implementation,
  then `lockUpgrades()`. A transceiver decides which cross-chain payloads are authentic, so
  a live upgrade key is a standing ability to forge one.
- Accounts are `XSafeProxy` and lock in the same call that arms them. There is no reachable
  state in which one has real logic and a live upgrade key.
- The xsafe msig owns the registry and every transceiver.

## Docs

- [`docs/message-flow.md`](docs/message-flow.md) — the two paths, wire formats, and what
  each contract does
- [`docs/encoding.md`](docs/encoding.md) — call serialization, the commitment preimage, and
  what changes off the EVM
- [`docs/todo.md`](docs/todo.md) — everything outstanding, ordered by what blocks what

## Status

The EVM side is built and tested: account creation, the approval queue, cancellation,
execution, per-destination commitment schemes, and both message paths end to end in-process.

```
cd contracts/evm && forge test        # 224 passing
```

**Nothing crosses a real bridge yet.** `_sendMessage` reverts `SendNotImplemented` until a
protocol binding overrides it, and no provider is bound — `LzTransmitter` and friends are
structure without an SDK behind them. That is the next thing to build, and every remaining
path waits on it.
