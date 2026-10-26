# The `layerzero-oft` binding

What the `layerzero-oft` binding is held to, and what an OFT must be before a conduit uses
it. Normative, in the sense of [`provider-spec.md`](provider-spec.md): everything here is
checkable against this repository, and the findings behind it are in
[`provider-research.md` §9](provider-research.md#9-layerzero-oft-as-a-carrier).

The binding carries a conduit's messages through an OFT its own team operates. Every
message, the bootstrap included, is an `oft.send` the conduit makes itself, with no tokens
and the message as `composeMsg`. A factory with no owner, at one address on every chain,
creates the conduit on its home and its receiver on each destination.

It is not a provider in `provider-spec.md`'s sense. It has no transceiver, so §4.4, R5,
R7.3 to R7.6, §6 and the transceiver specs of §8 do not apply to it, and it has no registry
route, provenance bar, bootstrap fee, receiver report or governor. The rest of that file's
rules on conduits hold here as they do for every binding. What the conduit
trusts instead is in the README's
[message providers](../README.md#message-providers) section.

Keywords MUST, MUST NOT, SHOULD and MAY are used in the RFC 2119 sense.

## 1. Terms

- **Home OFT**: the OFT on the conduit's home chain that it sends through. Bound into the
  conduit's address.
- **Destination OFT**: the home OFT's peer for a destination's eid.
- **Leaf**: `keccak256(bytes.concat(keccak256(abi.encode(chainKey, eid, dstOft))))` for one
  destination (`LzOftMessage.leaf`).
- **Destination root**: the root `LzOftMessage.root` computes over a conduit's leaves, in
  ascending `chainKey` order. Bound into the conduit's address.
- **Factory**: `LzOftConduitFactory`, the CREATE2 deployer of every conduit of this binding, and the
  compose target of every bootstrap.

## 2. OFT prerequisites

A conduit MUST NOT be created on an OFT that fails one of these.
[`deploy/CHECKS.md` §7](../contracts/evm/deploy/CHECKS.md#7-layerzero-oft) says how to check
each, with frxUSD's results; `LzOftLeaves.s.sol` and `test/fork/LzOftFork.t.sol` run some of
them for a candidate.

| | Requirement | Why |
| --- | --- | --- |
| O1 | It is an OFT or OFT adapter whose `send` writes `addressToBytes32(msg.sender)` as `composeFrom` (`OFTMsgCodec.encode`) | `composeFrom` is the conduit's only authentication |
| O2 | It is peered both ways with every destination's OFT | the home and destination peer checks |
| O3 | Its enforced options for a send with a compose message carry lzReceive gas | the binding's default options carry only lzCompose gas; without them the send is refused at home |
| O4 | It accepts a send of 0 tokens | no message carries tokens (L3) |
| O5 | Its `lzReceive` is unordered | a stuck message would hold every later one |
| O6 | Every chain it is on, home and destinations, is a `parity` chain in `deploy/chains.toml` | the factory sits at one address only where Ethereum's CREATE2 and Arachnid's factory hold |
| O7 | It is operated by the conduit's own team | its owner, delegate and upgrade admin can stop the conduit's channel, and its delegate can weaken its verification |

## 3. Rules

### L1. Addresses

- **L1.1** The factory and its two logic contracts MUST be deployed through Arachnid's factory
  at salt zero, with no constructor argument that varies by chain (`LzOftDeploy.factory`).
- **L1.2** A conduit's CREATE2 salt MUST be
  `keccak256(abi.encode(owner, salt, homeChainKey, homeEid, homeOft, destRoot))`, deployed by
  the factory with `CrossProxy`'s initcode (`LzOftConduitFactory.conduitSalt`, `predictConduit`), where
  `homeEid` is the eid of the home OFT's endpoint. One conduit has one address on every chain
  in its root.
- **L1.3** The home factory MUST compute `destRoot` itself from the leaves it is given, and
  refuse leaves that are empty, not in strictly ascending `chainKey` order, name its own chain,
  carry a zero eid or OFT or the home's eid, or name an OFT the home OFT does not peer.

### L2. Sends

- **L2.1** The conduit MUST call `oft.send` itself, for every message and bootstrap. Anything
  in between would be `composeFrom`.
- **L2.2** Every send and its quote MUST be built from one `SendParam`
  (`LzOftMessage.sendParam`).
- **L2.3** Every send and quote MUST refuse a destination its home OFT no longer peers as the
  conduit recorded or created it (`LzOftMessage.requirePeer`).
- **L2.4** A bootstrap MUST be sent to the factory, and carry
  `LzOftMessage.Bootstrap(owner, salt, homeChainKey, homeEid, homeOft, destRoot, proof, calls)`, with
  the proof the home factory builds from the stored leaves. A message MUST be sent to the
  receiver, with the payload as `composeMsg`.
- **L2.5** The only attribute MUST be `LzMessage.OPTIONS_ATTRIBUTE`, which replaces the
  default lzCompose option whole.

### L3. No tokens

- **L3.1** Every send MUST have `amountLD` and `minAmountLD` of 0. No binding carries value
  but its fee.

### L4. The bootstrap at a destination

- **L4.1** The factory MUST refuse a compose unless, in order: the caller is the endpoint the
  delivering OFT (`_from`) names; `(localChainKey, endpoint.eid(), _from)` proves into the
  message's `destRoot`; the compose's source eid is the message's `homeEid`, and `_from` peers
  the message's `homeOft` for it; and `composeFrom` is the conduit the message's fields derive
  (L1.2). The eid check keeps the conduit's receiver on another chain, where the same OFT
  address may be deployed and peered, from becoming a new receiver's home.
- **L4.2** Nothing MUST move before those checks pass. Native value the executor attaches
  MUST reach the conduit before its receiver is armed.
- **L4.3** The receiver MUST be armed with the conduit as its source transmitter, the source
  eid as its home, the home OFT, and `_from` as its local OFT.

### L5. Receive

- **L5.1** A receiver MUST refuse a compose unless, in order: the caller holds
  `GATEWAY_ROLE`; `_from` is its local OFT; its local OFT still peers its home OFT for its home
  eid; the compose's source eid is its home; and `composeFrom` is its source transmitter, read
  through `ProviderAddress.evmSender`.
- **L5.2** It MUST NOT read the executor or `_extraData`.

## 4. What it gives up

- **Destinations are fixed at creation.** A chain not in the root needs a new conduit.
- **Re-peering cuts a destination off.** An OFT whose peer for a chain moves to a new address
  can no longer reach that chain from any existing conduit.
- **The OFT is fixed.** An operator replaces it by upgrading it in place, or by migrating to a
  new OFT and a new conduit.
- **No zkSync or Tron.** Their CREATE2 formulas place the factory's conduits elsewhere.
- **No `Call`-less destinations.** The portable bootstrap form reaches the factory's absent
  `quoteBootstrapElements` and reverts.

## 5. Compliance

Shared with every binding, through `LzOftFixture`: `ProviderReceiveSpec`,
`ProviderWideSenderSpec` and `ProviderTransmitterSpec` (C4, C5, C6, C9, C10, C18 and C24 for
the conduit).

| Rule | Tests |
| --- | --- |
| L1.1 | `LzOftForkTest`, which deploys through `LzOftDeploy.factory` on each fork and compares the addresses |
| L1.2 | `test_theConduitLandsWhereItsFieldsDerive`, `testFuzz_everyDestinationProvesIntoTheRoot`, `test_theHomeEidIsBoundIntoTheAddress` |
| L1.3 | `test_noDestinationsIsRefused`, `test_unsortedOrRepeatedLeavesAreRefused`, `test_aLeafForThisChainIsRefused`, `test_aLeafWithTheHomesEidIsRefused`, `test_aLeafTheHomeOftDoesNotPeerIsRefused`, `test_aHomeOftWithoutAnEndpointIsRefused` |
| L2.1, L2.4 | `test_theBootstrapGoesThroughTheHomeOftFromTheConduit`, `test_aMessageGoesToTheReceiverWithThePayloadAsTheCompose`, `LzOftForkTest` |
| L2.2 | the same two, which compare the value paid with the quote |
| L2.3 | `test_aRePeeredHomeOftRefusesTheBootstrapAndItsQuote`, `test_aRePeerAfterTheBootstrapRefusesMessages` |
| L2.5 | `test_theOptionsAttributeReplacesTheDefaultWhole`, `test_aSecondAttributeIsRefused`, `test_anotherBindingsAttributeIsRefused`, `test_onlyTheOptionsAttributeIsSupported` |
| L3.1 | `test_aSendMovesNoTokensAndCarriesTheDefaultCompose`, `LzOftForkTest` |
| L4.1 | `test_aCallerOtherThanTheOftsEndpointIsRefused`, `test_anOftOutsideTheRootIsRefused`, `test_aLeafForAnotherChainIsRefused`, `test_aComposeFromAnotherEidThanTheHomesIsRefused`, `test_anOftThatNoLongerPeersTheHomeIsRefused`, `test_aSenderOtherThanTheConduitIsRefused`, `test_aForgedRootCreatesAnotherConduit`, `test_aSecondBootstrapIsRefused` |
| L4.2, L4.3 | `test_valueReachesTheConduit`, `test_theBootstrapCreatesTheReceiverAtTheConduitsAddress` |
| L5.1 | `ProviderReceiveSpec`, `test_aComposeQueuedByAnotherContractIsRefused`, `test_aRePeeredLocalOftIsRefused` |
| C29 | `test_aDeliveredComposeCannotRunAgain`, `test_aFailedComposeIsRetried` |
