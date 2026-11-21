# Protocol operator guide

This guide covers chain setup, provider configuration, and deployment assumptions.
Start with [Adding a chain or provider](#adding-a-chain-or-provider) for onboarding.

Run the EVM contract tests from the repository root with [Foundry](https://getfoundry.sh/).

```bash
git submodule update --init
cd contracts/evm
forge test
```

## Layout

```
src/
  addressing/     Erc7930, ChainType, ChainKey, Move        no imports outside itself
  derivation/     AddressDerive, IVmDeriver, VmDeriver, Bitcoin/Starknet/Sui
                  Blake2b256
  registry/       ChainRegistry, Provenance, IRefValidator, IChainRegistryRefs
                  ICommitmentScheme
  validators/     StarknetValidator, MoveValidator          pluggable, per chainKey
  schemes/        Keccak, Sha256, Blake2b                   pluggable, per chainKey
  messaging/      Commitment, Call, Payload, Envelope, Executor, Roles
                  IErc7786                                  vendored, ERC-7786's two
    outbound/     OutboundBase -> TransmitterBase -> OwnableTransmitter
    inbound/      ReceiverBase                          what a conduit receives with
    transceiver/  TransceiverBase -> zkSync / Tron          one per chain per provider
                  TransceiverExtension -> zkSync / Tron     init, owner config, views; one per chain
                  DivergentConduits                         zkSync and Tron derivation
  conduit/        Proxy                                what both halves, and transceivers, are
                  ProxyDeployer                        arms a transceiver's proxy in one call
  treasury/       Treasury                     one per chain: fees and the report float
  protocols/      per message provider; the only files naming an SDK
script/
  deploy/         shared deploy checks, one deploy per provider    tests deploy through these
  Deploy*.s.sol   production entry points, one per provider
  LzOftLeaves.s.sol  a layerzero-oft conduit's destinations, built and checked
  vendor/         provenance drivers for hand-copied SDK files
deploy/           chains.toml, providers/*.toml: chain facts, provider ids
```

Paths under `script/` and `deploy/` are relative to `contracts/evm/`.

Dependencies run one way: `addressing` is a leaf, and nothing above it is imported by
anything below:

```
addressing <- derivation <- registry <- validators
     ^                          ^
     +------- messaging --------+ <- protocols
```

## Where the reasoning lives

Contract paths in this section are relative to `contracts/evm/src/`.

| Question                                                                 | Answered in                           |
| ------------------------------------------------------------------------ | ------------------------------------- |
| Why one address, and why a proxy rather than a clone                     | `conduit/Proxy.sol`              |
| How a conduit is created, and why its upgrade key dies in the same call | `TransceiverBase._createConduit`, with the shared steps in `Conduits` |
| Why one transceiver makes both transmitters and receivers               | `TransceiverBase`                     |
| Why approvals are an unordered map of hash to count                      | `inbound/ReceiverBase.sol`            |
| Why a transceiver receives, and why it runs no payload                   | `TransceiverBase`                     |
| Why the wire carries a payload rather than a digest                      | `outbound/OutboundBase.sol`           |
| Why `Call[]` reaches EVM chains and opaque `bytes[]` everything else     | `messaging/Payload.sol`               |
| Why a commitment is defined over elements nothing here parses            | `messaging/Commitment.sol`            |
| Why a chain is graded, and what each grade is worth                      | `registry/Provenance.sol`             |
| Why the transceiver holds counterparts and the registry their grade      | `TransceiverExtension.setCounterpart` |
| Why routes live on the transceiver rather than in the registry           | `TransceiverExtension.setRoute`       |
| Why the owner configures and the roles are not authorities               | `messaging/Roles.sol`, `TransceiverBase` |
| Why the bootstrap fee is paid to the treasury in the same transaction    | `TransceiverBase._bootstrapSendValue` |
| Why each conduit is homed on its authenticated origin                   | `TransceiverBase._handleInbound`      |
| Why the report float pays reports and leaves only at the treasury's call | `TransceiverExtension.withdraw`, `Treasury.collect` |
| Why a chain's grade is write-once and suspension is the cut-off          | `registry/ChainRegistry.sol`          |
| Why zkSync and Tron derive conduits their own way, and what is unverified  | `transceiver/DivergentConduits.sol`   |
| Why a chain type needs more than a `ChainType` constant                  | `addressing/Erc7930.sol`              |
| Why the commitment _preview_ is swappable when the commitment is not     | `registry/ICommitmentScheme.sol`      |
| Why the route slot holds a chain identifier, not a provider's id         | `OutboundBase._recipientOn`           |
| Why the recipient is checked rather than trusted, and only on `eip155`   | `TransmitterBase.sendMessage`         |

## Adding a chain or provider

Deployment configuration lives in [`contracts/evm/deploy/`](../contracts/evm/deploy/).
`chains.toml` records chain IDs and derivation types. `providers/<p>.toml` records
provider-specific IDs and settings. [Deployment checks](../contracts/evm/deploy/CHECKS.md)
contains endpoint addresses, preflight procedures, and dated results.

### Add a chain

1. Follow the [chain deployment guide](../contracts/evm/deploy/README.md) in order.
   Run the applicable deployment checks for every provider that reaches the chain,
   in both directions with each chain it will talk to, before adding it to
   `chains.toml`.
2. Add the chain to the applicable [provider values tables](../contracts/evm/deploy/CHECKS.md#provider-values)
   and record the results with the date.
3. Add the chain to a provider's configuration where its checks pass. If a
   provider's checks fail for the chain, leave the chain out of that provider's
   TOML and open an issue for the failure. Follow the deployment guide for
   individual blocked lanes on a supported chain. Provider IDs and routes are
   write-once, so resolve configuration problems before deployment.

### Add a provider

1. Check the [provider prerequisites](providers/provider-spec.md#2-provider-prerequisites-the-go-or-no-go-checklist)
   and follow the [binding checklist](providers/provider-spec.md#10-checklist).
2. Under `contracts/evm/`, put the binding in `src/protocols/<p>/`, its fixture in
   `test/protocols/<p>/`, its deploy library in `script/deploy/<P>Deploy.sol`, and its
   entry point in `script/Deploy<P>.s.sol`. Run the shared provider specs with the
   new fixture.
3. Add `deploy/providers/<p>.toml`. Record the provider ID source and the date in
   the file header.
4. Extend [deployment checks](../contracts/evm/deploy/CHECKS.md) for the provider
   across all configured chains. Record endpoint values, how to quote a lane, what
   an unconnected pair returns, how the destination verifies messages, and how
   default destination gas compares with measured delivery costs. If payload size
   affects fees, update the [fee specification](providers/provider-spec.md#r2-quote).

For either addition, review [what the deployment checks do not cover](../contracts/evm/deploy/CHECKS.md#what-these-checks-do-not-cover)
and record any outstanding work in [`docs/todo.md`](todo.md).

## Adding a chain type

A chain of a type the protocol already has, such as another standard EVM chain, needs no new
contracts: see [`contracts/evm/deploy/README.md`](../contracts/evm/deploy/README.md). A new chain type
needs a type constant and a rule for validating its canonical chain reference.

1. **Allocate the `ChainType` constant** in `addressing/ChainType.sol`, and nowhere else.
   Every value used in the repo is allocated in that one file, because a ChainType is
   written into every envelope and registry keys are `keccak256(envelope)`: two files each picking a
   provisional value is a silent collision that surfaces as two chains sharing a key. Use the
   CASA CAIP-350 value where one exists; otherwise take the next free slot at or above
   `PROVISIONAL_FLOOR` and accept that a published profile later means a re-keying migration.

2. **Write the profile's canonicity rule into `Erc7930.parseStrict`**, beside the eip155 and
   starknet cases. `chainType` is read as an opaque `uint16` and never checked against the
   allocation table, so an unallocated value already parses and registers. It simply arrives
   with no canonicity condition attached, and both `0x00cafe` and `0xcafe` pass as references
   for the same chain and hash to two different keys. Allocating the constant does not close
   that; only the rule does. `test/UnknownChainType.t.sol` pins the current behaviour.

Then, per destination, add what the chain needs:

- a `Scheme` or `ICommitmentScheme` plugin, if it does not hash with keccak256
- an `IVmDeriver`, if its addresses can be recomputed here
- an `IRefValidator`, if the envelope cannot express its value ranges
- a grade below `Predetermined` when it is registered, if its addresses cannot be recomputed
  here at all; the grade is write-once. An EVM chain is `Predetermined` only if its transceivers
  are deployed through `ProxyDeployer`, which needs Arachnid's factory. One without that
  factory is `Unique` in every registry, and grades every other chain `Unique` in its own

## Message providers

Six native bindings live under `src/protocols/`. Each is held to
[`docs/providers/provider-spec.md`](providers/provider-spec.md). Each is one transceiver per chain, with
zkSync and Tron variants where the provider reaches those chains. On a transceiver, the
delivery's origin names a chain and the sender must be that chain's counterpart. A seventh,
`layerzero-oft`, has no transceiver: a conduit sends through an OFT its own team operates,
and is held to [`docs/providers/layerzero-oft-spec.md`](providers/layerzero-oft-spec.md). Where the
bindings differ is in who delivers a message to a conduit and what authenticates it:

| Provider | Inbound entry point | Sender authenticated by | Replay refused by |
| --- | --- | --- | --- |
| LayerZero | `lzReceive`, from the endpoint | the vendored OApp's peer check, then `GATEWAY_ROLE` and the source transmitter | the endpoint |
| CCIP | `ccipReceive`, from the router | `GATEWAY_ROLE` and the source transmitter (receivers also check the immutable router) | the off-ramp |
| Hyperlane | `handle`, from the Mailbox | `GATEWAY_ROLE`, the Mailbox's ISM, and the source transmitter | the Mailbox |
| Wormhole | `executeVAAv1`, from anyone | guardian signatures through Core, the emitter, and the VAA's `(targetChain, targetAddress)` prefix | the binding's own consumed-hash set |
| OP Stack, L1 ↔ L2 | `receiveOpStackMessage`, from the messenger that reaches the conduit's home | `GATEWAY_ROLE` and `xDomainMessageSender()` read during the relay | the messenger |
| OP Stack, L2 ↔ L2 | `receiveOpStackMessage`, from the `L2ToL2CrossDomainMessenger` | `GATEWAY_ROLE` and `crossDomainMessageSender()` read during the relay | the messenger |
| LayerZero through an OFT | `lzCompose`, from the endpoint | `GATEWAY_ROLE`, the delivering OFT, its peer for the home, and `composeFrom` as the source transmitter | the endpoint |

What an operator or integrator has to know:

- **Transports are fixed at initialization, and a disconnect is permanent.** `grantRole` is
  `onlyInitializing`, so a provider that migrates its endpoint means redeploying the
  transceiver unless its initializer's `gateways` named both endpoints up front. On a conduit,
  `revokeGateway` only subtracts. A receiver that drops its transport has no way to
  reconnect, and because `Proxy` arms once it cannot be redeployed at that address, so
  that owner's conduit on that chain stops receiving for good. This is deliberate: a
  re-grant path would be a fallback-override surface.
- **Provider ids named at deploy cannot be corrected.** Each entry in a transceiver's id
  table (eid, selector, domain, or Wormhole chain) and every LayerZero peer is write-once. A
  receiver's peer is set by its initializer; a transceiver's or transmitter's is set once per
  eid by its owner. Fixing a wrong one means a redeploy, or for a transmitter a new conduit.
- **LayerZero's inbound check is partly in vendored code.** Auditing it means reading
  `lib/layerzero-oapp-evm-upgradeable/.../OAppCoreUpgradeable.sol` and
  `OAppReceiverUpgradeable.sol` alongside `src/protocols/layerzero/`. Every other binding
  checks in this repo's own code. Each LayerZero conduit is its own OApp delegate.
- **Provider-side security configuration.** Hyperlane uses the Mailbox owner's replaceable
  `defaultIsm`. LayerZero uses the provider defaults unless a custom DVN stack is configured.
  For pathways whose default is the dead DVN, such as those touching zkSync or Fraxtal, the
  transceiver deployment pins LayerZero Labs' DVN once per eid. Receivers inherit that pin.
  The transceiver sends the bootstrap using its own configuration. Conduit owners can set
  and change the DVN stack for subsequent sends with `LzTransmitter.setDvn` (#51, #94).
- **Attestation-based providers prove who signed, not what happened.** LayerZero, CCIP,
  Hyperlane and Wormhole accept a message because parties outside the source chain attest to
  it: LayerZero's DVNs, Chainlink's node operators, the validators behind the Mailbox's ISM,
  and Wormhole's guardians. A valid attestation shows that enough of those keys signed, not
  that the source chain emitted the message, so a sender trusts that a quorum of them is
  honest and that whoever controls the set does not replace it: LayerZero's default
  configuration (or LayerZero Labs, on a pinned pathway), Chainlink, the Mailbox owner, and
  Wormhole's guardian governance. Nothing here checks a proof of the source chain's consensus.
  The OP Stack providers have no signer set; they trust the chains themselves. A signed
  receiver checks application and authority-update signatures itself against its selected
  graph. Its initial graph and head still depend on authenticated bootstrap delivery.
- **A CCIP receiving contract must keep answering `supportsInterface`.** If it stops answering
  true for `IAny2EVMMessageReceiver`, the off-ramp marks each message executed without ever
  calling `ccipReceive`. The message is lost silently rather than reverted.
  `CcipInterfaceSupportTest` pins the receiver's answer and `CcipTransceiver.t.sol` the
  transceiver's, on the plain and zkSync versions, so any inheritance change to the CCIP
  contracts has to keep them.
- **Wormhole delivery is permissionless.** Anyone may submit a VAA. Automatic delivery needs
  a relay provider's signed quote, fetched off-chain and passed with each send, which
  expires an hour after it is issued. A sender that cannot land its transaction within that
  hour, such as a multisig collecting signatures, sends publish-only instead: its provider payment goes to
  Core alone, and whoever submits the signed VAA to `executeVAAv1` delivers it, paying the
  destination gas. A send with neither reverts (#53).
- **`op-stack-l1-l2` sends carry no value.** The provider quote is zero; a routine send pays
  a fixed 0.0001 ETH Crossecute fee. The binding refuses a nonzero provider `value` because the messenger
  would bridge it rather than spend it. `op-stack-l1-l2`'s transceiver holds, per chain,
  the messenger that reaches it, write-once: on Ethereum one `L1CrossDomainMessenger` per OP
  Stack chain, on each OP Stack chain the `L2CrossDomainMessenger` predeploy, which reaches
  only Ethereum. A delivery's origin is the chain of the messenger that called.
- **OP Stack interop carries no value and no options, and needs a relayer.**
  `op-stack-l2-l2`'s messenger takes no value and no gas limit, so its provider quote is zero and any
  attribute is refused; the relay is a separate transaction whose sender picks the gas. A send
  reaches only a routed chain, which should be one in the sender's dependency set. A routine
  send pays the same fixed 0.0001 ETH Crossecute fee.
- **A `layerzero-oft` conduit trusts its OFT, not this protocol's operators.** No governor,
  transceiver or crossecute DVN setting is in its path. What it trusts, on every chain it
  reaches, is the OFT's owner, whose re-peering cuts a destination off and whose pausing or
  inspector can stop the channel but not forge it; the OFT's delegate, who can weaken its DVNs
  or libraries, which nothing here detects; for a proxied OFT, its upgrade admin, who can
  change how `composeFrom` is encoded; LayerZero's endpoint; and the factory, logic and
  `Proxy`, all immutable at one address everywhere. It is meant for an OFT the conduit's
  own team operates. A plain conduit needs the OFT channel to execute repair or migration
  calls. A signed receiver accepts valid message, leaf and authority submissions directly,
  so an OFT outage does not stop those paths after bootstrap. Its initial authority still
  relies on authenticated OFT delivery. Both modes use the same route-bound address;
  signed bootstrap requires an activated source Safe and matching receiver authority pins
  ([signed OFT transport](safe/safe-signed-dispatch.md#layerzero-oft-signed-transport)).
- **A `layerzero-oft` conduit reaches only the chains it was created with.** They are bound
  into its address, so another chain means another conduit. It carries no tokens, and reaches
  no zkSync or Tron chain.
- **Vendored provider code has no update path.** SDK files are hand-copied into `lib/`,
  pinned per file to a commit by `contracts/evm/script/vendor/<provider>.sh`. An upstream
  security fix has to be noticed, re-vendored, and diffed by hand. It then reaches no
  deployed contract, since transceivers and conduits lock on initialization.

**Provider-specific information** is in [provider research](https://github.com/crossecute/research/blob/main/protocol/provider-research.md), kept in the
[`crossecute/research`](https://github.com/crossecute/research) repository because it is
pinned to other teams' releases and goes stale on their schedule, not this protocol's. It
covers what each provider guarantees about replay, how its SDK fits the proxy layout, the
license of the files vendored from it, and the designs the research suggests adopting or
adding. It names the upstream commit each vendored file was read at, so when a vendor
script's pinned commit changes, re-check the matching section there.

## Assumptions

- `ProxyDeployer` is created through Arachnid's CREATE2 factory (`0x4e59..`), which puts
  it at one address on every standard EVM chain; transceivers are created through
  `ProxyDeployer`, and conduits by their transceiver's own CREATE2. A chain is
  `Predetermined` only if its transceivers were deployed that way; zkSync and Tron, whose
  CREATE2 formulas differ, and any chain without Arachnid's factory are `Unique`.
- Compiled against `evm_version = "paris"`, pinned in `contracts/evm/foundry.toml`. PUSH0
  (Shanghai) is absent on zkSync, Tron, and several L2s, and CREATE2 parity requires
  byte-identical initcode on every chain, so the target must not vary. Optimizer settings
  are pinned for the same reason, as are `bytecode_hash = "none"` and
  `cbor_metadata = false`: solc's default trailer carries an IPFS hash of the source,
  comments included, which would otherwise put every derived address one comment edit
  away from moving.
- Transceivers and conduits are all `Proxy`, and each locks in the same call that arms
  it. `ProxyDeployer` deploys a transceiver, installs its implementation, runs its
  initializer, and locks the proxy in one call, under a salt bound to its caller so nobody
  else can take the address first. The implementation has no upgrade function. A
  transceiver decides which cross-chain payloads are authentic, so a live upgrade key would
  be a standing ability to forge one, and there is no reachable state in which one exists.
- Nothing is upgraded after deployment. `ChainRegistry` is a plain contract with no proxy, so
  conduits, transceivers, and the registry all keep sequential storage with no gaps: no later
  version ever has to match their layout.
- OpenZeppelin 5.4.0 and forge-std 1.16.2, submodules pinned to exact commits and fetched
  from forks in the crossecute org, each holding its commit under its own tag, so a deleted
  or force-pushed upstream tag cannot break the build. The same commits are in
  `contracts/evm/foundry.lock`; a bump made with `git` alone has to update it by hand. The
  OZ version is an address-determining input like the compiler pin: `ProxyDeployer` compiles
  OZ's `Create2` and `Errors`, so a bump that changes any of their bytes moves the deployer,
  and with it every transceiver and every conduit on every chain. `Proxy` imports nothing
  from OZ. These are the versions to ship on.
  OZ 5.5's `Arrays` uses `mcopy`, which breaks `AccessControlEnumerableUpgradeable` at
  `paris` (`Roles.sol`), and v6's `ReentrancyGuardTransient` needs Cancun. ERC-7786's two
  interfaces are vendored at `src/messaging/IErc7786.sol` instead of imported, because they
  are a `draft-` upstream and this protocol's ABI here.
- A transmitter holds pre-funded provider and Crossecute fees. Every send and bootstrap is paid from
  that balance at a quote nothing caps, so value kept there for any other purpose is exposed
  to the bootstrap fee, which the transceiver's owner or its operator sets, and to a provider's
  price. A fee lands in the chain's treasury, so an operator can overcharge but not take it.
- Fee-aware transmitters charge 10% of the provider's native quote, rounded down, per
  `sendMessage`. Both OP Stack bindings instead charge 0.0001 ETH. `quoteMessage` includes
  both amounts; `quoteMessageBreakdown` returns them separately. The provider receives only
  its quote, and the Crossecute fee accumulates in `Treasury` for its owner's withdrawal,
  outside the receiver-report float. A provider revert rolls both payments back. Refunds
  return to the transmitter without reducing the Crossecute fee. Bootstrap, destination
  execution, local finalization and delivery retries add no Crossecute fee. Already-armed
  transmitters remain locked to their existing implementations; migration is separate work.
- A transceiver's owner can limit which conduits bootstrap through it by naming an
  `IBootstrapAllowlist` (`setBootstrapAllowlist`), and lift it by setting zero. It gates
  bootstraps and their quotes only: a conduit's messages to receivers it already has go
  from its transmitter and never reach the check. The allowlist is an external call on every
  bootstrap, so one that reverts halts bootstraps from that chain.
- Each chain has one `ChainRegistry` and one `Treasury`, shared by every provider there. A
  chain's grade, and so whether it reports its receivers, is given when it is registered and
  never changes; a chain can be suspended, which only refuses. Both are `Ownable`. The
  deployment design gives each chain one `TimelockController` with a 48-hour delay as their
  owner, where the governor's conduits under two providers propose and cancel, so a compromised
  provider can freeze them but not take them. `script/DeployChain.s.sol` deploys it from
  `contracts/evm/deploy/governance.toml` and reads the design back.
- A bootstrap fee is forwarded to the chain's `Treasury` in the transaction that charges it,
  so no transceiver holds an accrued fee. A transceiver holds only the float for its receiver
  reports, funded out of band, which pays those reports and otherwise leaves only when the
  treasury pulls it with `Treasury.collect`.
- Ownership is the only live authority, and it cannot admit a transport, drop one, or
  repoint a treasury. A conduit is one owner's, so a receiver may drop its own gateway through
  `revokeGateway`, which is the only membership change that survives initialization
  anywhere. `renounceOwnership` stays available everywhere: it retires that transmitter,
  transceiver, registry, or treasury for good, and that is the owner's call.

## CCIP dependency

The CCIP binding uses the MIT application interfaces and `Client` library from
`@chainlink/contracts-ccip` 2.0.0, vendored at the release commit by
`contracts/evm/script/vendor/ccip.sh`. Imports use the package's canonical
`@chainlink/contracts-ccip/contracts/` prefix.

`CcipReceiver` inherits the upstream v2 receiver helper and exposes both `router()`
and `getRouter()`. The vendor script changes the helper's `supportsInterface` from
`pure` to `view` to compose with AccessControl and maps its IERC165 import to the
pinned OpenZeppelin version. CCIP delivery copies the upstream message into memory.
Other providers decode directly from calldata.

See the [CCIP 2.0 options guide](providers/ccip-v2.md) for wire defaults,
V3 lane enablement, and receiver policies.
