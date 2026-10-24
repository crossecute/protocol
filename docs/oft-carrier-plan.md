# Plan: LayerZero OFT carrier binding

A LayerZero binding whose Path A rides an OFT the account's operator already runs. The
transmitter sends each payload as a 0-amount `oft.send` with the payload as `composeMsg`,
and the receiver takes it in `lzCompose`. The OFT's DVNs, executor, enforced options and
peers are already configured by its operator, so the binding sets none of them.

Path B is unchanged in shape: a bootstrap goes transceiver to transceiver over a LayerZero
OApp, as `LzTransceiver` does today. Receivers are therefore created at the same CREATE2
address on every parity chain.

This file is the plan for the tracking PR. Once the binding lands, the findings move into
[`provider-research.md`](provider-research.md) as a section next to
[§8](provider-research.md#8-layerzero-as-a-native-binding), and this file is removed.

## Decisions taken

1. **The transmitter calls `oft.send` itself.** `composeFrom` is `msg.sender` of `send`, so a
   router or multicall in between would make every message unauthenticable.
2. **The receiver authenticates with `composeFrom`.** No proof field is added to the payload.
   A payload is public once sent, so anything inside it can be copied. A signature would make
   receivers learn the signer set.
3. **One fixed OFT per transmitter and per receiver.** No rotation. An operator who replaces
   the OFT either upgrades it in place (same address) or migrates to a new OFT and a new
   crossecute account.
4. **Bootstrap carries the OFT pair.** At bootstrap the transmitter reads
   `homeOft.peers(dstEid)`, and `(homeOft, dstOft)` travels in the bootstrap. The destination
   checks `dstOft.peers(homeEid) == homeOft` before it creates the receiver.
5. **The reverse-peer check also runs on every receive**, in one internal function shared
   with the bootstrap check.
6. **The transmitter checks the home peer on every send.** `homeOft.peers(dstEid)` must
   still equal the `dstOft` the bootstrap sent. A mismatch reverts at home, rather than
   paying for a message the receiver will refuse.
7. **The pair travels in a new envelope kind, `BOOTSTRAP_CARRIER`.** It is `BOOTSTRAP` with
   two fixed words `(homeOft, dstOft)` after `transmitter`. Existing kinds keep their bytes.
   Prepending a self-call to `calls` was rejected: signers approve `calls`, and the receiver
   would run a call no signer approved.
8. **The transmitter holds all OFT state; the transceiver holds none.** The transmitter
   stores `homeOft` and, per destination, the `dstOft` it read at bootstrap. The transceiver
   reads the pair from the bootstrapping account when it builds the envelope and stores
   nothing.
9. **`homeOft` is set by a write-once, owner-only `setOft`**, matching `LzTransmitter.setPeer`.
   It refuses an address whose `IOAppCore(oft).endpoint()` is not this chain's endpoint, which
   catches an address from the wrong chain or one that is not an OApp. Bootstrap refuses an
   account that has not set it.

## What LayerZero guarantees

Checked on 2026-10-24 against `LayerZero-Labs/devtools` (`packages/oft-evm`) and
`LayerZero-Labs/LayerZero-v2` (`MessagingComposer.sol`), both on main and at the commits
`script/vendor/layerzero.sh` pins. `OFTCore`, `OFTMsgCodec` and `MessagingComposer` are not
vendored, since nothing here compiles against them.

- `OFTMsgCodec.encode` writes `sendTo | amountSD | addressToBytes32(msg.sender) | composeMsg`
  when `composeMsg` is non-empty. The caller cannot set the third field.
- `OFTCore._lzReceive` calls `endpoint.sendCompose(to, guid, 0, m)` with
  `m = nonce(8) | srcEid(4) | amountLD(32) | composeFrom(32) | composeMsg`, so `composeFrom`
  sits at bytes `[44:76]` and the payload at `[76:]`.
- `sendCompose` stores the hash under `composeQueue[msg.sender][to]`, so the `_from` that
  `lzCompose` reports is whoever queued it.
- `lzCompose` writes `RECEIVED_MESSAGE_HASH` before it calls the composer, so a success is
  final and a revert rolls the mark back (P7, R3.5).
- `msgInspector` runs only on the send side, in `_buildMsgAndOptions`.

## Receiver checks

| Check | Proves |
| --- | --- |
| `msg.sender == endpoint` (`GATEWAY_ROLE`) | it came through the endpoint, and `revokeGateway` can disconnect it |
| `_from == dstOft` | the fixed local OFT queued it |
| `srcEid == homeEid` | it came in on the home pathway |
| `dstOft.peers(homeEid) == homeOft` | the pathway still trusts the home OFT |
| `composeFrom == transmitter` | the transmitter called `send` |

`executor` and `_extraData` are not authenticated and are not read.

## Trust this binding adds

The account inherits the OFT operator's security on every chain the OFT reaches:

- **Owner.** Re-peering is caught by the per-receive check. Everything else the owner
  controls, such as pausing, `msgInspector` and fee or minimum-amount rules, can stop the
  admin channel but not forge it.
- **Delegate.** It can weaken the DVN set or the libraries. Nothing in this binding detects
  that.
- **Upgrade admin**, for a proxied OFT. An upgrade can change `composeFrom` encoding or
  remove compose support.

The binding is meant for an OFT the account's own team operates, not a third party's. A
paused or broken OFT blocks the payload that would fix it, and with a fixed OFT the only way
out is migrating the account, which needs a working channel to hand roles off. Both belong
in the user-facing docs, not only here.

The reverse-peer check at bootstrap catches one-way peering, which would otherwise create a
receiver that every later message fails to reach. It does not protect against an operator
who controls both ends, since a fake `dstOft` can return any peer.

## Provider prerequisites (P1 to P15)

| | This binding |
| --- | --- |
| P1 | `composeMsg` is arbitrary `bytes` |
| P2 | Any contract can call `send`, and any address can be a compose target |
| P3 | `SendParam.to` is the receiver |
| P4 | `srcEid` and `composeFrom` are in the compose message |
| P5 | Compose is unordered. The OFT's own `lzReceive` is unordered unless the operator opted in, which onboarding checks |
| P6 | Anyone can call `endpoint.lzCompose` again for a failed compose |
| P7 | Mark before call, as above |
| P8, P9 | `oft.quoteSend` is a view, and `send` is paid in native currency |
| P10 | The OFT address goes in the init call, not the initcode |
| P11 | Path B is unchanged, so the receiver report is unchanged |
| P12 | `extraOptions` carries the lzCompose gas, merged with the OFT's enforced options |
| P13 | Limited to the chains where the OFT is deployed and peered |
| P14 | The account no longer inherits the OApp SDK, which removes its storage from the account |
| P15 | Unchanged, since Path B is unchanged |

## Changes to the shared bases

Decisions 7 and 8 need three hooks that do not exist today. Each has one implementer, which
the repo's rules normally count against a hook. Here there is no other way in: the bootstrap
path is private in `TransmitterBase` and non-virtual in `TransceiverBase`.

1. **`TransmitterBase`: a virtual `_beforeBootstrap(bytes32 chainKey)`**, empty by default,
   called from `_bootstrapCalls` after `_markBootstrapped` and before the transceiver is
   called. The carrier transmitter reads `homeOft.peers(dstEid)`, refuses zero, and stores it
   as that destination's `dstOft`.
2. **`TransceiverBase`: a virtual `_bootstrapEnvelope(owner, salt, transmitter, calls)`**,
   returning `Envelope.encodeBootstrap(...)` by default. `bootstrap` and `quoteBootstrap` both
   call it, so the send and its quote encode in one place. The carrier transceiver reads the
   pair from the account through a view and encodes `BOOTSTRAP_CARRIER`. A quote taken
   before the account exists, or before `_beforeBootstrap` has run, encodes zero words. The
   fee is the same, since the words are fixed width.
3. **`TransceiverBase`: a `bytes bindingData` parameter on `_bootstrapInbound`,
   `_createCrossAccount` and `_accountInitializer`**, empty for every existing binding. The
   carrier transceiver overrides `_handleInbound` to decode `BOOTSTRAP_CARRIER` and passes the
   pair through. Existing overrides of `_accountInitializer` change only their signature.

## Work, in commit order

Each item is one commit.

1. `docs`: this plan.
2. `chore(lib)`: vendor `IOFT` (`SendParam`, `MessagingFee`, `OFTReceipt`),
   `ILayerZeroComposer` and `OFTComposeMsgCodec` from `devtools`, with provenance headers.
3. `feat(envelope)`: `BOOTSTRAP_CARRIER`, its encoder and decoder, and `kindOf`'s bound.
   Tests for the tag checks and the round trip.
4. `refactor(transceiver)`: `_bootstrapEnvelope`, used by `bootstrap` and `quoteBootstrap`,
   and `bindingData` threaded to `_accountInitializer`. No behavior change: existing
   envelopes and every existing binding's tests are unchanged.
5. `refactor(transmitter)`: the empty `_beforeBootstrap` hook. No behavior change.
6. `feat(lz-oft)`: `LzOftMessage`, the shared library: `send` and `quote` through
   `oft.send` and `oft.quoteSend`, compose-gas options from `_defaultGas` or the attribute,
   and the peer check used by every caller.
7. `feat(lz-oft)`: `LzOftTransmitter`: `setOft` with the endpoint check, `_beforeBootstrap`
   storing `dstOft`, the pair view the transceiver reads, and send and quote with the home
   peer check (decision 6).
8. `feat(lz-oft)`: `LzOftReceiver`: `lzCompose` with the five checks above, then
   `_onMessageFrom`.
9. `feat(lz-oft)`: `LzOftTransceiver` on `LzTransceiverBase` for Path B. At home it encodes
   `BOOTSTRAP_CARRIER` from the account's pair. At the destination it runs the reverse-peer
   check and arms the receiver with `(homeEid, homeOft, dstOft)`.
10. `test(lz-oft)`: the fixture on `ProviderBindingSpec`, a mock OFT that follows `OFTCore`'s
    encoding, and binding tests: a fake OFT calling `sendCompose`, a router as the `send`
    caller, a re-peered home and destination, one-way peering at bootstrap, `setOft` with a
    wrong endpoint, a bootstrap before `setOft`, quote and send agreeing before and after
    the account exists, replay (C29) and a 0-amount compose round trip.
11. `test(fork)`: a 0-amount compose through a live OFT on two chains, decoding `[44:76]` to
    the transmitter. Doubles as the onboarding check for a candidate OFT.
12. `feat(deploy)`: `providers/lz-oft.toml`, `script/deploy/LzOftDeploy.sol`,
    `script/DeployLzOft.s.sol`, and the `CHECKS.md` sections.
13. `docs`: fold this plan into `provider-research.md` and `provider-spec.md`, add the
    trust section to the user-facing docs, and update `todo.md`.

Out of scope for this PR: the zkSync and Tron variants (`LzDivergentTransceiver`), which
follow once the plain binding is settled.

## Cost

LayerZero prices per byte. Against the plain binding, each Path A message carries 72 more
bytes (`sendTo`, `amountSD`, `composeFrom`) and pays for a second executor step, the
lzCompose. Bootstraps on this binding carry 64 more bytes for the OFT pair. Both are
measured in step 10 and recorded in `CHECKS.md`.

## Checks before merge

`forge build --sizes src` (EIP-170), `forge lint` and `FOUNDRY_PROFILE=lint-src forge lint`
on `src/`, `script/check-selectors.sh`, and the full test suite including the new fork test.
