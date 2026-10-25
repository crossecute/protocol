# Plan: the `layerzero-oft` binding

A LayerZero binding with no crossecute messaging of its own. Every message, the bootstrap
included, is an `oft.send` that the account itself makes through an OFT its own team
operates, with the message as `composeMsg`. A factory with no owner, deployed at the same
address on every chain, creates the account on its home and its receivers elsewhere.

The point is the trust set. The OFT's operator trusts their own OFT and its DVNs,
LayerZero's endpoint, and immutable code at fixed addresses whose source they can audit. No
governor, transceiver peering or crossecute DVN configuration is in the path, on Path A or
Path B.

This file is the plan for the tracking PR. Once the binding lands, the findings move into
[`provider-research.md`](provider-research.md) as a section next to
[§8](provider-research.md#8-layerzero-as-a-native-binding), and this file is removed.

## Decisions taken

1. **The account calls `oft.send` itself, for Path A and for the bootstrap.** `composeFrom`
   is `msg.sender` of `send`, so a router, multicall or transceiver in between would put its
   own address there and the destination could no longer tell which account sent it.
2. **No destination transceivers.** A factory is the `lzCompose` target for bootstraps and the
   CREATE2 deployer of every account of this binding. It has no owner, no configuration and
   no upgrade path. It is deployed through Nick's deterministic deployment proxy
   (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), so its address and code are the same on
   every chain. Nick's proxy cannot be the compose target itself: its fallback reads calldata
   as salt and initcode.
3. **The factory is also the home side.** The account's address is CREATE2 over the factory,
   so the factory that creates the receiver on a destination must be the one that created the
   transmitter at home. The OFT's operator calls it once at home to create the account. It
   implements the views `TransmitterBase` reads from its transceiver (`predictReceiver`,
   `reportsReceiver`, `routeTo`) and refuses the bootstrap and quote functions, since the
   account sends its own.
4. **The destination set is fixed at creation and bound into the address.** The OFT's
   address differs per chain, and a factory on a destination cannot read `homeOft.peers(eid)`
   on the home chain, so something fixed in advance must say which `_from` is the real OFT
   there. That is a Merkle root of the destinations, part of the account's CREATE2 salt. A
   chain not in the root needs a new account, the same as a migration to a new OFT.
5. **One fixed OFT per account**, `homeOft`, also bound into the salt. No rotation. An
   operator who replaces the OFT either upgrades it in place (same address) or migrates to a
   new OFT and a new account. Re-peering a destination to a new OFT address cuts that
   destination off from every existing account.
6. **The peer check runs at home on every send and bootstrap.** `homeOft.peers(eid)` must
   equal the destination's `dstOft`. A mismatch reverts at home rather than paying for a
   message the destination will refuse.
7. **The reverse-peer check runs at the destination on every receive and bootstrap**:
   `dstOft.peers(homeEid) == homeOft`.
8. **No tokens move.** Every send has `amountLD = minAmountLD = 0`, as no other binding
   carries value but its fee. CCIP could carry tokens and sends none (`CcipMessage`).
9. **No interface changes.** `sendMessage`, `bootstrap` and their quotes keep their
   signatures. The one attribute is LayerZero's options, parsed as the plain binding parses
   it.
10. **The home factory stores each account's destinations.** At creation it takes the
    leaves, checks each against `homeOft.peers(eid)`, computes the root itself and stores
    `(eid, dstOft)` per destination. At bootstrap the account reads its destination and proof
    from the factory, so the owner passes nothing beyond `bootstrap`'s usual arguments, and no
    root can be bound into an address without leaves that produce it.
11. **The provider is named `layerzero-oft`, and the existing one stays `layerzero`.** It is
    not registered as a message provider: no registry route, provenance bar, bootstrap fee or
    receiver report applies to it.
12. **EVM chains with Ethereum's CREATE2 only.** zkSync and Tron derive addresses with other
    formulas, so a factory there cannot create the receiver at the account's address.

## Account address and the destination root

```solidity
leaf     = keccak256(bytes.concat(keccak256(abi.encode(chainKey, eid, dstOft))));
salt'    = keccak256(abi.encode(owner, salt, homeChainKey, homeOft, destRoot));
account  = CREATE2(factory, salt', CROSS_PROXY_INIT_CODE_HASH);
```

`destRoot` is an OpenZeppelin `MerkleProof` root over sorted pairs. The double hash keeps a
64-byte inner node from being read as a leaf. `chainKey` is the destination's crossecute
chain key and `eid` its LayerZero endpoint id.

The factory computes the root from the leaves the creator passes, in sorted order with no
duplicate `chainKey`, and stores the leaves under the account. The creator builds the leaf
list from `deploy/providers/layerzero.toml`'s eids. One account has one address on every chain in its root. The same owner and salt
with a different root, or a different `homeOft`, are a different account. A forged root
therefore creates some other account and never the victim's.

`salt'` differs from `TransceiverCore._accountSalt`'s `(owner, salt, homeChainKey)`, and the
deployer is the factory rather than a transceiver, so this binding's accounts never collide
with another binding's.

## Flows

**Creation, at home.** The operator calls `factory.createTransmitter(salt, homeOft, leaves)`,
with `msg.sender` as the owner, as `TransceiverBase.createTransmitter` does. The factory
checks that `homeOft` reports an endpoint with code and that `homeOft.peers(eid) == dstOft`
for every leaf, computes `destRoot`, stores the leaves under the account, then deploys, arms
and locks the account with `(owner, factory, salt, homeOft)`.

**Bootstrap, at home.** The owner calls the account's existing `bootstrap(destinationChainId,
calls, attributes)`. The account:

1. reads `(eid, dstOft, destRoot, proof)` for the chain from the factory, which refuses a
   chain not in the account's leaves and builds the proof from the stored leaves;
2. checks `homeOft.peers(eid) == dstOft`, since the peer may have changed since creation;
3. records `chainKey → (eid, dstOft)` and the route and counterpart, as `_markBootstrapped`
   does today;
4. calls `homeOft.send` with `to = factory`, no amount, and
   `composeMsg = LzOftMessage.Bootstrap(owner, salt,
   homeChainKey, homeOft, destRoot, proof, calls)`. No eid or `dstOft`: the destination
   proves its own.

**Bootstrap, at the destination.** The real `dstOft` queues the compose. In `lzCompose(_from, guid, message, ...)` the factory checks, in order:

| Check | Proves |
| --- | --- |
| `msg.sender == IOAppCore(_from).endpoint()` | the endpoint `_from` uses delivered it; the factory has no endpoint of its own, so a fake endpoint fails here |
| proof places `(localChainKey, endpoint.eid(), _from)` in `destRoot` | `_from` is this account's OFT on this chain; `localChainKey` comes from `block.chainid` |
| `srcEid == homeEid` and `IOAppCore(_from).peers(homeEid) == homeOft` | the packet came from `homeOft`, verified by `_from`'s own DVNs |
| `composeFrom == account` | the account called `send`; the account address is derived from the message's own fields |

It then creates the receiver at `account`, armed with `(account, homeChainKey, homeEid,
homeOft, _from, calls)`. Native value the executor attaches is forwarded to the account
before it is armed, so its bootstrap calls can spend it.

**Path A.** The owner calls `sendMessage(recipient, payload, attributes)`. The account reads
the stored `(eid, dstOft)`, rechecks `homeOft.peers(eid) == dstOft`, and calls
`homeOft.send` with `to = receiver`. No proof. The receiver's `lzCompose` checks:

| Check | Proves |
| --- | --- |
| `msg.sender == endpoint` (`GATEWAY_ROLE`) | it came through the endpoint |
| `_from == dstOft` | the fixed local OFT queued it |
| `srcEid == homeEid` | it came in on the home pathway |
| `dstOft.peers(homeEid) == homeOft` | the pathway still trusts the home OFT |
| `composeFrom == sourceTransmitter` | the account called `send` |

`executor` and `_extraData` are not authenticated and are not read.

Bootstraps and Path A messages go to different compose targets, so the factory never sees a
Path A payload and a receiver never sees a bootstrap. No envelope tag is needed between them.

## Failed composes

Anyone can retry a failed compose. A real bootstrap fails the factory's checks only if a leaf
pairs a `chainKey` with another chain's `eid`. The home factory checks the peer but cannot map
an eid to a chain, so `LzOftLeaves.s.sol` checks each leaf's `eid` against `layerzero.toml`.

## What LayerZero guarantees

Checked on 2026-10-24 against `LayerZero-Labs/devtools` (`packages/oft-evm`) and
`LayerZero-Labs/LayerZero-v2` (`MessagingComposer.sol`), both on main and at the commits
`script/vendor/layerzero.sh` pins. `OFTCore`, `OFTMsgCodec` and `MessagingComposer` are not
vendored, since nothing here compiles against them.

- `OFTMsgCodec.encode` writes `sendTo | amountSD | addressToBytes32(msg.sender) | composeMsg`
  when `composeMsg` is non-empty. The caller cannot set the third field.
- `OFTCore._lzReceive` credits `to`, then calls `endpoint.sendCompose(to, guid, 0, m)` with
  `m = nonce(8) | srcEid(4) | amountLD(32) | composeFrom(32) | composeMsg`, so `composeFrom`
  sits at bytes `[44:76]` and the payload at `[76:]`.
- `sendCompose` stores the hash under `composeQueue[msg.sender][to]`, so the `_from` that
  `lzCompose` reports is whoever queued it. Any contract can queue a compose for any `to`,
  which is why the factory needs the root.
- `lzCompose` writes `RECEIVED_MESSAGE_HASH` before it calls the composer, so a success is
  final and a revert rolls the mark back (P7, R3.5).
- `msgInspector` runs only on the send side, in `_buildMsgAndOptions`.

## Trust

The account trusts, on every chain in its root:

- **The OFT's owner.** Re-peering is caught by the peer checks, and cuts the destination off.
  Pausing, `msgInspector` and fee or minimum-amount rules can stop the channel but not forge
  it.
- **The OFT's delegate.** It can weaken the DVN set or the libraries. Nothing here detects
  that.
- **The OFT's upgrade admin**, for a proxied OFT. An upgrade can change the `composeFrom`
  encoding or remove compose support.
- **The factory, the transmitter and receiver logic, and `CrossProxy`**, all immutable and at
  fixed addresses.

It does not trust the crossecute governor, any transceiver, or crossecute's DVN pins.

The binding is meant for an OFT the account's own team operates. A paused or broken OFT
blocks the payload that would fix it, and with a fixed OFT the only way out is migrating the
account, which needs a working channel to hand roles off. Both belong in the user-facing docs.

## Provider prerequisites (P1 to P15)

| | This binding |
| --- | --- |
| P1 | `composeMsg` is arbitrary `bytes` |
| P2 | Any contract can call `send`, and any address can be a compose target |
| P3 | `SendParam.to` is the factory or the receiver |
| P4 | `srcEid` and `composeFrom` are in the compose message |
| P5 | Compose is unordered. The OFT's own `lzReceive` is unordered unless the operator opted in, which onboarding checks |
| P6 | Anyone can call `endpoint.lzCompose` again for a failed compose |
| P7 | Mark before call, as above |
| P8, P9 | `oft.quoteSend` is a view, and `send` is paid in native currency |
| P10 | The OFT address and root go in the init call and the salt, not the initcode |
| P11 | No receiver report: every chain in scope uses Ethereum's CREATE2 |
| P12 | `extraOptions` carries only the lzCompose gas (`LzMessage.composeOptions`). The OFT's enforced options for a send with a compose message must carry its own lzReceive gas; without them the executor refuses the send at home (`Executor_ZeroLzReceiveGasProvided`), and onboarding checks for them. The options attribute replaces the default whole |
| P13 | Limited to the chains in the account's root |
| P14 | The account does not inherit the OApp SDK, so carries no OApp storage |
| P15 | Not applicable: no transceiver-to-transceiver bootstrap |

The parts of `provider-spec.md` that assume a registered provider with transceivers (the
registry route, provenance, bootstrap fees, receiver reports, governor configuration) do not
apply. Step 12 writes the short spec this binding meets instead.

## Changes to the shared code

1. **`TransmitterBase`: two virtual hooks for the bootstrap's transport**, `_sendBootstrap`
   and `_quoteBootstrap`, defaulting to today's transceiver calls in `_bootstrapCalls` and
   `_quoteBootstrapCalls`. `LzOftTransmitter` overrides both to build one compose message
   and send or quote it through `homeOft`, so the send and its quote encode in one place.
   One implementer, which the repo's rules normally count against a hook; the bootstrap path
   is private today and there is no other way in.
2. **The deploy, arm, lock and address check in `TransceiverBase._createCrossAccount`** move
   into `src/account/CrossAccounts.sol`, which both it and the factory call. A library, not a
   base, so neither contract's storage layout changes (R8.2). The address check is its own
   function, run before the initializer is built, as `_createCrossAccount` did before.
3. **Commits `0046342` and `f2c418e` are undone.** The `BOOTSTRAP_OFT` kind has no sender or
   receiver in this design, and `bindingData` and the virtual `_bootstrapEnvelope` have no
   implementer. `TransceiverBase`'s single encoder for `bootstrap` and `quoteBootstrap` is
   kept as a private function, with its test, since it still keeps the two from drifting.
4. **`LzMessage` parses the options attribute once for both builds**, with the plain
   binding's lzReceive default or this binding's lzCompose default.

## Repository layout

| Area | `layerzero` (unchanged) | `layerzero-oft` (new) |
| --- | --- | --- |
| `src/protocols/layerzero/` | `LzTransceiver`, `LzTransmitter`, `LzReceiver`, `LzDivergentTransceiver` | `LzOftFactory`, `LzOftTransmitter`, `LzOftReceiver`, `LzOftMessage` |
| shared there | `LzMessage` (options encoding) | the same file |
| `test/protocols/layerzero/` | `LzFixture`, `LzBinding.t.sol`, `LzTransceiver.t.sol`, `MockLzEndpoint` | `LzOftFixture`, `LzOftBinding.t.sol`, `LzOftFactory.t.sol`, `MockOft` |
| `script/` | `DeployLz.s.sol`, `deploy/LzDeploy.sol` | `DeployLzOft.s.sol` (Nick's proxy, no arguments that vary by chain), `LzOftLeaves.s.sol` |

- **Options encoding is shared.** The lzCompose option goes in `LzMessage` next to the
  lzReceive one. `LzOftMessage` holds what targets an OFT: the compose messages, `send` and
  `quote` through `oft.send` and `oft.quoteSend`, the peer checks and the leaf hash.
- **The accounts share nothing with the plain build's accounts.** `LzOftTransmitter` is an
  `OwnableTransmitter` that calls an OFT, and `LzOftReceiver` is a `ReceiverBase` and an
  `ILayerZeroComposer`. Neither is an OApp.
- **No constructor argument varies by chain.** The logic contracts read the endpoint from the
  OFT, and the factory takes only the logic addresses, which are themselves the same on every
  chain. `localChainKey` is computed from `block.chainid`.
- **`MockLzEndpoint` gains `sendCompose` and `lzCompose`**, rather than a second endpoint mock.
- **No registry or provider-table entries.** `deploy/providers/layerzero-oft.toml`, the
  `ChainConfig` change and `governance.toml` entry from the earlier plan are dropped. Eids for
  root-building come from `layerzero.toml`.

## Work, in commit order

Each item is one commit. Steps 1 and 2 are done.

1. `docs`: this plan.
2. `chore(lib)`: vendor `IOFT`, `ILayerZeroComposer` and `OFTComposeMsgCodec`, with provenance
   headers.
3. `revert`: `0046342` (`BOOTSTRAP_OFT`).
4. `refactor(transceiver)`: undo `f2c418e`'s `bindingData` and make `_bootstrapEnvelope`
   private, keeping its test.
5. `refactor(transceiver)`: the shared deploy-and-arm library, used by `_createCrossAccount`.
   No behavior change.
6. `refactor(transmitter)`: `_sendBootstrap` and `_quoteBootstrap`. No behavior change.
7. `feat(lz-oft)`: the lzCompose option in `LzMessage`, and `LzOftMessage`.
8. `feat(lz-oft)`: `LzOftTransmitter`: the bootstrap read from the
   factory, and the bootstrap and Path A sends and quotes with the peer check.
9. `feat(lz-oft)`: `LzOftReceiver`: `lzCompose` with the five checks, then
   `_onMessageFrom`.
10. `feat(lz-oft)`: `LzOftFactory`: `createTransmitter` with the leaf checks and on-chain root,
    the stored leaves and the proof view, the transceiver views, and the bootstrap `lzCompose`
    with the four checks.
11. `test(lz-oft)`: `ProviderAccountFixture`, split out of `ProviderFixture` with the hooks
    that concern accounts only, under the receiver and transmitter specs
    (`ProviderReceiveSpec`, `ProviderWideSenderSpec`, `ProviderTransmitterSpec`); an
    `LzOftFixture` that runs them; and the binding's own tests for what is OFT-specific. The
    transceiver send specs do not apply, since this binding's sends leave from the account;
    `LzOftTransmitter.t.sol` covers the properties of those that hold for it.
12. `test(fork)` and `feat(deploy)`: a compose through a live OFT on two chains, decoding
    `[44:76]` to the account; `DeployLzOft.s.sol` and `LzOftLeaves.s.sol`.
13. `docs`: the binding's short spec, the trust section in the user-facing docs, the
    findings folded into `provider-research.md`, and `todo.md`.

## Cost

LayerZero prices per byte. Against the plain binding, each Path A message carries 72 more
bytes (`sendTo`, `amountSD`, `composeFrom`) and pays for a second executor step, the
lzCompose. A bootstrap carries those 72 bytes plus the account fields `(owner, salt,
homeChainKey, homeOft, destRoot)`, 160 bytes, a proof of `ceil(log2 n)` words for `n`
destinations, and 96 bytes of offset and length words for the struct and the proof: 256
bytes more than the calls alone for 8 destinations. No bootstrap fee is charged. Creation stores two slots per destination
(its leaf hash, and `dstOft`, `eid` and its index packed) plus two for the account, and
reads one peer each, on top of today's account creation; building a proof reads the
account's `n` leaf hashes. All are measured in step 11.

## Checks before merge

`forge build --sizes src` (EIP-170), `forge lint` and `FOUNDRY_PROFILE=lint-src forge lint`
on `src/`, `script/check-selectors.sh`, and the full test suite including the new fork test.
