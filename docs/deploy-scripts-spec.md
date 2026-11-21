# Deployment scripts reference

A file-by-file reference of the Foundry deployment scripts in `contracts/evm/script`, written in the same form as [the naming and function reference](naming-spec.md). Each file has one sentence on what it is. Each function that another file calls, or that a user can run, has a row saying what it does, who calls it, and whether a user calls it.

The columns are those of the naming reference, and the naming reference does not list script callers. "Called by" here lists other script functions and summarizes tests. Callers are matched by name and call syntax, not by a compiler.

The scripts are not yet under the rules in Part 1 of the naming reference. Their helpers that revert on failure, such as `check`, `checkTransceiver`, `checkRegistryGrades` and `checkGovernorHomeId`, keep their `check*` names; the rest of the protocol uses `require*`.

## `contracts/evm/script` (top level)

### `contracts/evm/script/DeployCcip.s.sol`

Forge script that deploys the CCIP provider on a chain and refuses to broadcast unless this chain's CCIP lanes pass `CcipPreflight`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_providerName()`<br>_internal pure_ | The provider's registry name ("ccip"). Overrides or is overridden in: DeployProvider. | DeployProvider._config, DeployProvider._governorHomeId; also tests | No |
| `_preflight()`<br>_internal view_ | Runs `CcipPreflight` over this chain's lanes and reverts on any problem. Overrides or is overridden in: DeployProvider. | DeployProvider.run | No |
| `_implementations()`<br>_internal_ | Deploys CCIP's receiver, transmitter and transceiver implementations for the router. Overrides or is overridden in: DeployProvider. | DeployProvider.run | No |
| `_deploy(d)`<br>_internal_ | Deploys the CCIP transceiver proxy with the governor-home selector. Overrides or is overridden in: DeployProvider. | DeployProvider.run; also tests | No |


### `contracts/evm/script/DeployChain.s.sol`

Forge script for step 1 of the provider spec on one parity chain: deploys its timelock, `ChainRegistry` and `Treasury`; a rerun deploys nothing.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `run()`<br>_external_ | Reads chain and governance config, deploys and checks the timelock, registry and treasury. | tests only | Yes, run with `forge script` |

Private helpers: `_governanceFile`.


### `contracts/evm/script/DeployHyperlane.s.sol`

Forge script that deploys the Hyperlane provider on a chain.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_providerName()`<br>_internal pure_ | The provider's registry name ("hyperlane"). Overrides or is overridden in: DeployProvider. | DeployProvider._config, DeployProvider._governorHomeId; also tests | No |
| `_implementations()`<br>_internal_ | Deploys Hyperlane's receiver, transmitter and transceiver implementations for the mailbox. Overrides or is overridden in: DeployProvider. | DeployProvider.run | No |
| `_deploy(d)`<br>_internal_ | Deploys the Hyperlane transceiver proxy with the governor-home domain. Overrides or is overridden in: DeployProvider. | DeployProvider.run; also tests | No |


### `contracts/evm/script/DeployLz.s.sol`

Forge script that deploys the LayerZero provider on a chain, with the home pathway's DVN from the provider config where needed.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_providerName()`<br>_internal pure_ | The provider's registry name ("layerzero"). Overrides or is overridden in: DeployProvider. | DeployProvider._config, DeployProvider._governorHomeId; also tests | No |
| `_implementations()`<br>_internal_ | Deploys LayerZero's receiver, transmitter and transceiver implementations for the endpoint. Overrides or is overridden in: DeployProvider. | DeployProvider.run | No |
| `_deploy(d)`<br>_internal_ | Deploys the LayerZero transceiver proxy with the governor-home eid and DVN. Overrides or is overridden in: DeployProvider. | DeployProvider.run; also tests | No |


### `contracts/evm/script/DeployLzOft.s.sol`

Forge script that deploys the permissionless `layerzero-oft` factory and its logic, which sit at the same address on every chain with the same build.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `run()`<br>_external_ | Deploys (or finds) the factory through Arachnid's factory and checks it against the expected address. | tests only | Yes, run with `forge script` |
| `predict()`<br>_external view_ | The factory address to record for the release. | tests only | Yes, run with `forge script` (read-only) |

Private helpers: `_expectedFactory`, `_governanceFile`, `_treasury`.


### `contracts/evm/script/DeployOpStack.s.sol`

Forge script that deploys the `op-stack-l1-l2` provider, taking the home's messenger from the provider config.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_providerName()`<br>_internal pure_ | The provider's registry name ("op-stack-l1-l2"). Overrides or is overridden in: DeployProvider. | DeployProvider._config, DeployProvider._governorHomeId; also tests | No |
| `_implementations()`<br>_internal_ | Deploys the OP Stack receiver, transmitter and transceiver implementations. Overrides or is overridden in: DeployProvider. | DeployProvider.run | No |
| `_deploy(d)`<br>_internal_ | Deploys the OP Stack transceiver proxy with the home's messenger. Overrides or is overridden in: DeployProvider. | DeployProvider.run; also tests | No |

Private helpers: `_homeMessenger`.


### `contracts/evm/script/DeployOpStackInterop.s.sol`

Forge script that deploys the `op-stack-l2-l2` provider, refusing a chain or governor home not listed in the provider config.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_providerName()`<br>_internal pure_ | The provider's registry name ("op-stack-l2-l2"). Overrides or is overridden in: DeployProvider. | DeployProvider._config, DeployProvider._governorHomeId; also tests | No |
| `_implementations()`<br>_internal_ | Deploys the interop receiver, transmitter and transceiver implementations. Overrides or is overridden in: DeployProvider. | DeployProvider.run | No |
| `_deploy(d)`<br>_internal_ | Checks the chain is a member and deploys the interop transceiver proxy. Overrides or is overridden in: DeployProvider. | DeployProvider.run; also tests | No |


### `contracts/evm/script/DeployProvider.s.sol`

Abstract Forge script for step 2 of the provider spec: deploys one provider's conduit and transceiver implementations and the transceiver through `ProxyDeployer` from the registry's record.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_providerName()`<br>_internal pure_ | Hook returning the provider's name in the registry, hashed into its key. Overrides or is overridden in: DeployCcip, DeployHyperlane, DeployLz, DeployOpStack, DeployOpStackInterop, DeployWormhole. | DeployProvider._config, DeployProvider._governorHomeId; also tests | No |
| `_implementations()`<br>_internal_ | Hook that deploys the provider's receiver, transmitter and transceiver implementations. Overrides or is overridden in: DeployCcip, DeployHyperlane, DeployLz, DeployOpStack, DeployOpStackInterop, DeployWormhole. | DeployProvider.run | No |
| `_deploy(d)`<br>_internal_ | Hook that deploys the provider's transceiver proxy. Overrides or is overridden in: DeployCcip, DeployHyperlane, DeployLz, DeployOpStack, DeployOpStackInterop, DeployWormhole. | DeployProvider.run; also tests | No |
| `_preflight()`<br>_internal view_ | Hook for read-only checks of the provider's live state before broadcasting. Overrides or is overridden in: DeployCcip. | DeployProvider.run | No |
| `run()`<br>_external_ | Validates governance config, runs preflight, broadcasts the implementations and transceiver, and checks the result. | tests only | Yes, run with `forge script` |
| `_governorHomeId()`<br>_internal view_ | The provider's id for the governor's home, required unless this chain is the home. | DeployCcip._deploy, DeployHyperlane._deploy, DeployLz._deploy, DeployWormhole._deploy | No |
| `_governance()`<br>_internal view_ | Reads the governance config for this chain set. | DeployLz._deploy, DeployOpStack._homeMessenger, DeployOpStackInterop._deploy, DeployProvider.run, DeployProvider._governorHomeId | No |

Private helpers: `_checkChains`, `_config`, `_fromRecord`, `_governanceFile`.


### `contracts/evm/script/DeployWormhole.s.sol`

Forge script that deploys the Wormhole provider on a chain.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_providerName()`<br>_internal pure_ | The provider's registry name ("wormhole"). Overrides or is overridden in: DeployProvider. | DeployProvider._config, DeployProvider._governorHomeId; also tests | No |
| `_implementations()`<br>_internal_ | Deploys Wormhole's receiver, transmitter and transceiver implementations for the Core bridge and Executor. Overrides or is overridden in: DeployProvider. | DeployProvider.run | No |
| `_deploy(d)`<br>_internal_ | Deploys the Wormhole transceiver proxy with the governor-home chain id. Overrides or is overridden in: DeployProvider. | DeployProvider.run; also tests | No |

Private helpers: `_endpoints`.


### `contracts/evm/script/GovernancePayloads.s.sol`

Forge script that writes steps 3 to 6 of the provider spec as numbered Safe Transaction Builder batches under `out/governance/`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `run()`<br>_external_ | Loads the plan and writes the home, registry, bootstrap and connect batches. | tests only | Yes, run with `forge script` |
| `_outDir()`<br>_internal view_ | Output directory `out/governance`. Overrides or is overridden in: PayloadWriter. | GovernancePayloads.run; also tests | No |


### `contracts/evm/script/LzOftLeaves.s.sol`

Forge script that builds and checks the destination leaf list a `layerzero-oft` conduit is created with, sending nothing.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `run()`<br>_external_ | Builds and checks the ordered leaves and destination root from the environment and returns them for `createTransmitter`. | tests only | Yes, run with `forge script` |

Private helpers: `_nameOf`.


### `contracts/evm/script/PreflightCcip.s.sol`

Forge script that runs `CcipPreflight` on every parity chain CCIP reaches, broadcasting nothing.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `run()`<br>_external_ | Checks each parity chain's CCIP lanes at both ends and reverts with the problems found. | tests only | Yes, run with `forge script` |


### `contracts/evm/script/RotateDeployer.s.sol`

Forge script that writes the deployer rotation for every parity chain as numbered Safe Transaction Builder batches under `out/rotation/`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `run()`<br>_external_ | Computes pending pairs and writes the schedule and execute batches for the new deployer. | tests only | Yes, run with `forge script` |
| `_outDir()`<br>_internal view_ | Output directory `out/rotation`. Overrides or is overridden in: PayloadWriter. | RotateDeployer.run; also tests | No |

Private helpers: `_chainNamed`, `_newDeployer`, `_pending`, `_pendingChains`, `_pendingProviders`.


## `contracts/evm/script/deploy`

### `contracts/evm/script/deploy/CcipDeploy.sol`

Library that deploys CCIP's implementations and transceiver, with the router as the gateway.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiverImplementation(router)`<br>_internal_ | Deploys `CcipReceiver` for a router with the receiver authority pins. | DeployCcip._implementations; also tests | No |
| `transmitterImplementation(router)`<br>_internal_ | Deploys `CcipTransmitter` for a router. | DeployCcip._implementations; also tests | No |
| `transceiverImplementation(router)`<br>_internal_ | Deploys `CcipTransceiver` for a router and the shared extension. | DeployCcip._implementations; also tests | No |
| `transceiver(d, router, homeSelector)`<br>_internal_ | Deploys the CCIP transceiver proxy and checks the governor-home selector. | DeployCcip._deploy; also tests | No |

Private helpers: `tronTransceiver`, `zkSyncTransceiver`, `zkSyncTransceiverImplementation`.


### `contracts/evm/script/deploy/CcipPreflight.sol`

Library that checks a chain's CCIP lanes to and from every other parity chain against the allowed contract versions and blocked pairs, read-only.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `getOnRamp(destChainSelector)`<br>_ICcipRouterLanes · external view_ | The router's on-ramp for a destination selector. | CcipPreflight._onRamp | Yes via interface (read-only) |
| `getOffRamps()`<br>_ICcipRouterLanes · external view_ | The router's off-ramps. | CcipPreflight._offRamps; also tests | Yes via interface (read-only) |
| `typeAndVersion()`<br>_ITypeAndVersion · external view_ | A ramp's type and version string. | CcipPreflight._ramp; also tests | Yes via interface (read-only) |
| `problems(dir, cs, local, router)`<br>_CcipPreflight · internal view_ | Every problem found on a chain's lanes through a router, one per line, empty if none. | DeployCcip._preflight, PreflightCcip.run; also tests | No |
| `require_(found)`<br>_CcipPreflight · internal pure_ | Reverts with every problem found. | DeployCcip._preflight, PreflightCcip.run; also tests | No |
| `join(a, b)`<br>_CcipPreflight · internal pure_ | Concatenates two problem strings with a separator. | PreflightCcip.run, CcipPreflight.problems, CcipPreflight._offRampsFor, CcipPreflight._quote | No |

Private helpers: `_expected`, `_offRamps`, `_offRampsFor`, `_onRamp`, `_quote`, `_ramp`, `_same`, `supportedVersions`.


### `contracts/evm/script/deploy/ChainConfig.sol`

Library that reads and checks `deploy/chains.toml` and the per-provider tomls (chains, provider ids, routes, DVNs, registry grades).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `defaultDir()`<br>_internal view_ | The `deploy/` directory under the project root. | DeployCcip._preflight, DeployChain.run, DeployLz._deploy, DeployLzOft.run, DeployLzOft.predict, DeployOpStack._homeMessenger, DeployOpStackInterop._deploy, DeployProvider._checkChains, DeployProvider._governorHomeId, DeployProvider._governance, GovernancePayloads.run, LzOftLeaves.run (+3 more); also tests | No |
| `chains(dir)`<br>_internal view_ | Every configured chain with unique nonzero ids and a known derivation. | DeployCcip._preflight, DeployChain.run, DeployLz._deploy, DeployLzOft.run, DeployLzOft.predict, DeployOpStack._homeMessenger, DeployOpStackInterop._deploy, DeployProvider._checkChains, DeployProvider._governorHomeId, DeployProvider._governance, LzOftLeaves.run, PreflightCcip.run (+1 more); also tests | No |
| `chainWithId(cs, chainId)`<br>_internal pure_ | The chain entry for a chain id; reverts if none. | DeployCcip._preflight, DeployChain.run, DeployLz._deploy, DeployLzOft.run, DeployOpStack._homeMessenger, DeployOpStackInterop._deploy, DeployProvider._checkChains, DeployProvider._governorHomeId, LzOftLeaves.run; also tests | No |
| `providerId(dir, cs, provider, c)`<br>_internal view_ | A provider's id for a chain, or zero where it does not reach it. | DeployProvider._governorHomeId, LzOftLeaves.run, PreflightCcip.run, CcipPreflight.problems; also tests | No |
| `routeId(dir, cs, provider, local, remote)`<br>_internal view_ | A provider's id for a remote as the local transceiver names it, or zero where blocked or missing. | DeployProvider._governorHomeId, CcipPreflight.problems, GovernancePlan._cacheRoutes, GovernancePlan.idFor; also tests | No |
| `lzDvn(dir, cs, local, remote)`<br>_internal view_ | LayerZero Labs' DVN on the local chain for a remote pathway, or zero where defaults verify it. | DeployLz._deploy, GovernancePlan._cacheRoutes; also tests | No |
| `gradeOf(registryChain, graded)`<br>_internal pure_ | The provenance grade a registry chain gives another chain. | DeployProvider._checkChains, ChainConfig.checkRegistryGrades, GovernancePlan._chainCalls; also tests | No |
| `checkRegistryGrades(registry, cs, local)`<br>_internal view_ | Checks the registry's recorded grades match this configuration. | DeployProvider._checkChains | No |
| `read(path)`<br>_internal view_ | Reads a file under the allowed read paths. | CcipPreflight.supportedVersions, ChainConfig.chains, ChainConfig.providerId, ChainConfig.routeId, ChainConfig.lzDvn, GovernanceConfig.read, OpStackConfig.messenger, OpStackInteropConfig.isMember; also tests | No |
| `chainNamed(cs, name)`<br>_internal pure_ | The chain entry with a name; reverts if none. | LzOftLeaves.run, GovernanceConfig.read; also tests | No |
| `hasChainNamed(cs, name)`<br>_internal pure_ | Whether a chain with a name exists. | ChainConfig.lzDvn, ChainConfig._providerIds, OpStackConfig.messenger, OpStackInteropConfig.isMember | No |

Private helpers: `_derivation`, `_idNamed`, `_providerFile`, `_providerIds`, `_same`.


### `contracts/evm/script/deploy/ChainDeploy.sol`

Libraries that read `deploy/governance.toml` (`GovernanceConfig`) and deploy and predict a chain's timelock, registry and treasury (`ChainDeploy`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `defaultFile()`<br>_GovernanceConfig · internal view_ | Path of `deploy/governance.toml`. | DeployChain._governanceFile, DeployLzOft._governanceFile, DeployProvider._governanceFile, PayloadWriter._governanceFile; also tests | No |
| `read(file, cs)`<br>_GovernanceConfig · internal view_ | Parses the governance file against the chain list. | DeployChain.run, DeployLzOft._treasury, DeployProvider._governance, GovernancePlan.load; also tests | No |
| `requireSet(g)`<br>_GovernanceConfig · internal pure_ | Reverts unless the owner and deployer are set and every provider salt is nonzero and distinct. | DeployChain.run, DeployLzOft._treasury, DeployProvider.run, GovernancePlan.load; also tests | No |
| `providerSeed(g, name)`<br>_GovernanceConfig · internal pure_ | The seed record for a provider by name. | RotateDeployer._pending, GovernanceConfig.read, ChainDeploy.transceiver; also tests | No |
| `homeIdentifier(g)`<br>_ChainDeploy · internal pure_ | ERC-7930 chain identifier of the governor's home. | DeployProvider._config, ChainDeploy.seed; also tests | No |
| `governorConduit(g, provider)`<br>_ChainDeploy · internal pure_ | Predicts where the governor's conduit under a provider sits on a parity chain. | ChainDeploy.proposers, GovernancePlan.governor; also tests | No |
| `transceiver(g, provider)`<br>_ChainDeploy · internal pure_ | Predicts a provider's transceiver address from its record and the deployer. | ChainDeploy.governorConduit, GovernancePlan.transceiver; also tests | No |
| `predict(g)`<br>_ChainDeploy · internal pure_ | Predicts the timelock, registry and treasury addresses before deployment. | DeployLzOft._treasury, DeployProvider._config, ChainDeploy.checkChain, GovernancePlan.registryBatch, GovernancePlan.scheduleRegistry, GovernancePlan.executeRegistry, GovernancePlan.rotationBatch, GovernancePlan.scheduleRotation, GovernancePlan.executeRotation; also tests | No |
| `deploy(g)`<br>_ChainDeploy · internal_ | Deploys what is missing of the three and checks all of them; a rerun deploys nothing. | DeployChain.run; also tests | No |

Private helpers: `checkChain`, `proposers`, `registryInitCode`, `seed`, `timelockInitCode`, `treasuryInitCode`.


### `contracts/evm/script/deploy/GasAttribute.sol`

Library that builds the one gas attribute each binding takes to set a message's destination gas.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `forMultisig(provider, gas)`<br>_internal pure_ | The attributes a multisig sends with over a provider for a destination gas amount (Wormhole is publish-only). | GovernancePlan.rotateRemote, GovernancePlan._bootstrapTxs, GovernancePlan.connect | No |

Private helpers: `ccip`, `hyperlane`, `layerZero`, `opStack`.


### `contracts/evm/script/deploy/GovernancePlan.sol`

Library that computes the governance transactions (steps 3 to 6 of the provider spec and the deployer rotation) every parity chain needs, as Safe batches.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `load(dir, governanceFile)`<br>_internal view_ | Builds the plan from the chain list and governance file. | GovernancePayloads.run, RotateDeployer.run; also tests | No |
| `isOn(p, provider, chain)`<br>_internal view_ | Whether step 2 deployed a provider on a chain. | RotateDeployer._pending, GovernancePlan.load, GovernancePlan.peerCalls, GovernancePlan._transceiverCalls, GovernancePlan.prepareHome; also tests | No |
| `executeRegistry(p, local)`<br>_internal view_ | The transaction anyone submits on a chain after its timelock delay to execute registry changes. | GovernancePayloads.run; also tests | No |
| `executeRotation(p, newDeployer, pending)`<br>_internal view_ | The transaction anyone submits after the delay to execute a deployer rotation. | RotateDeployer.run; also tests | No |
| `rotateHome(p, newDeployer, pending)`<br>_internal view_ | Transactions by the governor's owner on the home that schedule the rotation there. | RotateDeployer.run; also tests | No |
| `rotateRemote(p, newDeployer, pending)`<br>_internal view_ | Transactions that schedule the rotation on every other chain through the governor's transmitter. | RotateDeployer.run; also tests | No |
| `prepareHome(p)`<br>_internal view_ | Step 3: creates the home transmitters, sets transceiver routes and ids, and schedules the home registry. | GovernancePayloads.run; also tests | No |
| `bootstrap(p)`<br>_internal view_ | Steps 4 and 5: sets home LayerZero peers and bootstraps every other chain under each provider. | GovernancePayloads.run; also tests | No |
| `connect(p)`<br>_internal view_ | Step 5: sets LayerZero peers off the home, one message per chain. | GovernancePayloads.run; also tests | No |

Private helpers: `_bootstrapTxs`, `_cacheRoutes`, `_chainCalls`, `_chainIndex`, `_execute`, `_hasProvider`, `_idSetter`, `_is`, `_providerCalls`, `_push`, `_setDvn`, `_transceiverCalls`, `_word`, `callGas`, `callsGas`, `governor`, `idFor`, `laneCalls`, `lzDvn`, `peerCalls`, `registryBatch`, `rotationBatch`, `scheduleGas`, `scheduleRegistry`, `scheduleRotation`, `transceiver`.


### `contracts/evm/script/deploy/HyperlaneDeploy.sol`

Library that deploys Hyperlane's implementations and transceiver, with the mailbox as the gateway.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiverImplementation(mailbox)`<br>_internal_ | Deploys `HyperlaneReceiver` for a mailbox with the receiver authority pins. | DeployHyperlane._implementations; also tests | No |
| `transmitterImplementation(mailbox)`<br>_internal_ | Deploys `HyperlaneTransmitter` for a mailbox. | DeployHyperlane._implementations; also tests | No |
| `transceiverImplementation(mailbox)`<br>_internal_ | Deploys `HyperlaneTransceiver` for a mailbox and the shared extension. | DeployHyperlane._implementations; also tests | No |
| `transceiver(d, mailbox, homeDomain)`<br>_internal_ | Deploys the Hyperlane transceiver proxy and checks the governor-home domain. | DeployHyperlane._deploy; also tests | No |

Private helpers: `tronTransceiver`, `zkSyncTransceiver`, `zkSyncTransceiverImplementation`.


### `contracts/evm/script/deploy/LzDeploy.sol`

Library that deploys LayerZero's implementations and transceiver (the OApp checks the endpoint itself, so no gateway role).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiverImplementation(endpoint)`<br>_internal_ | Deploys `LzReceiver` for an endpoint with the receiver authority pins. | DeployLz._implementations; also tests | No |
| `transmitterImplementation(endpoint)`<br>_internal_ | Deploys `LzTransmitter` for an endpoint. | DeployLz._implementations; also tests | No |
| `transceiverImplementation(endpoint)`<br>_internal_ | Deploys `LzTransceiver` for an endpoint and the shared extension. | DeployLz._implementations; also tests | No |
| `transceiver(d, homeEid, homeDvn)`<br>_internal_ | Deploys the LayerZero transceiver proxy and checks the governor-home eid and DVN. | DeployLz._deploy; also tests | No |

Private helpers: `_checkHome`, `tronTransceiver`, `zkSyncTransceiver`, `zkSyncTransceiverImplementation`.


### `contracts/evm/script/deploy/LzOftDeploy.sol`

Library that deploys the `layerzero-oft` factory and logic where production puts them, and checks a conduit's destination list.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `factory(treasury)`<br>_internal_ | Deploys the factory with its logic through Arachnid's factory at salt zero (second overload takes explicit guard and MultiSend pins). | DeployLzOft.run; also tests | No |
| `factory(treasury, guard, multiSendCallOnly)`<br>_internal_ | Deploys the factory with its logic through Arachnid's factory at salt zero (second overload takes explicit guard and MultiSend pins). | DeployLzOft.run; also tests | No |
| `predictFactory(treasury)`<br>_internal view_ | The factory address for a treasury and receiver authority pins (second overload takes explicit pins). | DeployLzOft.predict, LzOftDeploy.requireFactory; also tests | No |
| `predictFactory(treasury, guard, multiSendCallOnly)`<br>_internal pure_ | The factory address for a treasury and receiver authority pins (second overload takes explicit pins). | DeployLzOft.predict, LzOftDeploy.requireFactory; also tests | No |
| `requireFactory(treasury, expected)`<br>_internal view_ | Reverts unless the predicted factory equals the expected address. | DeployLzOft.run; also tests | No |
| `leaves(homeOft, destinations)`<br>_internal view_ | The leaves `createTransmitter` takes for destinations, read from the home OFT's peers in ascending chain key order. | LzOftLeaves.run; also tests | No |
| `checkOnDestination(leaf, homeEid, homeOft)`<br>_internal view_ | On the destination chain, checks the leaf names this chain, its OFT's eid matches and the OFT peers the home OFT back. | LzOftLeaves.run; also tests | No |

Private helpers: `_initcode`.


### `contracts/evm/script/deploy/OpStackDeploy.sol`

Libraries that deploy `op-stack-l1-l2`'s implementations and transceiver (`OpStackDeploy`) and read its provider config (`OpStackConfig`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiverImplementation()`<br>_OpStackDeploy · internal_ | Deploys `OpStackReceiver` with the receiver authority pins. | DeployOpStack._implementations; also tests | No |
| `transmitterImplementation()`<br>_OpStackDeploy · internal_ | Deploys `OpStackTransmitter`. | DeployOpStack._implementations; also tests | No |
| `transceiverImplementation()`<br>_OpStackDeploy · internal_ | Deploys `OpStackTransceiver` with the shared extension. | DeployOpStack._implementations; also tests | No |
| `transceiver(d, homeMessenger)`<br>_OpStackDeploy · internal_ | Deploys the OP Stack transceiver proxy with the home's messenger. | DeployOpStack._deploy; also tests | No |
| `messenger(dir, cs, local, remote)`<br>_OpStackConfig · internal view_ | The messenger on the local chain that reaches a remote chain, or zero where none does. | DeployOpStack._homeMessenger, GovernancePlan.idFor; also tests | No |

Private helpers: `_eq`.


### `contracts/evm/script/deploy/OpStackInteropDeploy.sol`

Libraries that deploy `op-stack-l2-l2`'s implementations and transceiver (`OpStackInteropDeploy`) and read its member list (`OpStackInteropConfig`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiverImplementation()`<br>_OpStackInteropDeploy · internal_ | Deploys `OpStackInteropReceiver` with the receiver authority pins. | DeployOpStackInterop._implementations; also tests | No |
| `transmitterImplementation()`<br>_OpStackInteropDeploy · internal_ | Deploys `OpStackInteropTransmitter`. | DeployOpStackInterop._implementations; also tests | No |
| `transceiverImplementation()`<br>_OpStackInteropDeploy · internal_ | Deploys `OpStackInteropTransceiver` with the shared extension. | DeployOpStackInterop._implementations; also tests | No |
| `transceiver(d)`<br>_OpStackInteropDeploy · internal_ | Deploys the interop transceiver proxy, refused where interop is not live. | DeployOpStackInterop._deploy; also tests | No |
| `isMember(dir, cs, chain)`<br>_OpStackInteropConfig · internal view_ | Whether a chain is listed in the interop provider config, checking every listed chain is a parity chain. | DeployOpStackInterop._deploy, GovernancePlan.load | No |

Private helpers: `_derivation`.


### `contracts/evm/script/deploy/PayloadWriter.sol`

Abstract base for the scripts that write governance payloads, holding the governance file path, output directory and the Safe Transaction Builder format.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_governanceFile()`<br>_internal view_ | The governance file path; tests override it. | GovernancePayloads.run, RotateDeployer.run; also tests | No |
| `_outDir()`<br>_internal view_ | The output directory hook. Overrides or is overridden in: GovernancePayloads, RotateDeployer. | GovernancePayloads.run, RotateDeployer.run; also tests | No |
| `_write(dir, name, chainId, safe, txs)`<br>_internal_ | Writes one named batch as `<dir>/<name>.json`. | GovernancePayloads.run, RotateDeployer.run | No |
| `batchJson(name, chainId, safe, txs)`<br>_public pure_ | The Transaction Builder JSON for a batch of transactions. | PayloadWriter._write | Yes, anyone (read-only) |
| `_one(t)`<br>_internal pure_ | Wraps one transaction in a one-element array. | GovernancePayloads.run; also tests | No |


### `contracts/evm/script/deploy/ProxyDeploy.sol`

Free functions for the deployment checks and Arachnid-factory deployments, including `ProxyDeployer` and `Proxy` deployment.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `check(ok, what)`<br>_internal pure_ | Reverts `DeployCheck` with a message unless a condition holds. | DeployChain.run, DeployLzOft.run, DeployOpStack._homeMessenger, DeployOpStackInterop._deploy, DeployProvider._config, DeployProvider._fromRecord, DeployProvider._checkChains, DeployProvider._governorHomeId, LzOftLeaves.run, PreflightCcip.run, RotateDeployer.run, RotateDeployer._pending (+25 more); also tests | No |
| `arachnidAddress(initCode)`<br>_internal pure_ | The address Arachnid's factory gives initcode at salt zero. | ChainDeploy.predict, LzOftDeploy.predictFactory, LzOftDeploy._initcode, ProxyDeploy.arachnidDeploy | No |
| `arachnidDeploy(initCode)`<br>_internal_ | Deploys initcode through Arachnid's factory at salt zero on first use. | ChainDeploy.deploy, LzOftDeploy.factory, ProxyDeploy.proxyDeployer, TransceiverDeploy.transceiverExtension, TransceiverDeploy.zkSyncTransceiverExtension | No |
| `proxyDeployer()`<br>_internal_ | Deploys `ProxyDeployer` where production puts it (`PROXY_DEPLOYER`). | ProxyDeploy.deployProxy; also tests | No |
| `deployProxy(deployedBy, salt, implementation, data)`<br>_internal_ | Deploys a `Proxy` for a deployer at a salt, armed and locked with an implementation and data. | TransceiverDeploy.deployTransceiverProxy; also tests | No |
| `_slot(proxy, slot)`<br>_internal view_ | Reads the address stored in a proxy's storage slot (used to check the implementation slot). | ProxyDeploy.deployProxy; also tests | No |


### `contracts/evm/script/deploy/TransceiverDeploy.sol`

Free functions that deploy a provider's transceiver through `ProxyDeployer` and check its initializer, record and shared extension.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiverAuthorityPins()`<br>_internal view_ | The fixed source-authority guard and MultiSendCallOnly pins (second overload takes them as arguments). | CcipDeploy.receiverImplementation, HyperlaneDeploy.receiverImplementation, LzDeploy.receiverImplementation, LzOftDeploy.factory, LzOftDeploy.predictFactory, OpStackDeploy.receiverImplementation, OpStackInteropDeploy.receiverImplementation, WormholeDeploy.receiverImplementation; also tests | No |
| `receiverAuthorityPins(guard, multiSendCallOnly)`<br>_internal pure_ | The fixed source-authority guard and MultiSendCallOnly pins (second overload takes them as arguments). | CcipDeploy.receiverImplementation, HyperlaneDeploy.receiverImplementation, LzDeploy.receiverImplementation, LzOftDeploy.factory, LzOftDeploy.predictFactory, OpStackDeploy.receiverImplementation, OpStackInteropDeploy.receiverImplementation, WormholeDeploy.receiverImplementation; also tests | No |
| `transceiverExtension()`<br>_internal_ | The shared transceiver extension, deployed on first use at one address per parity chain. | CcipDeploy.transceiverImplementation, HyperlaneDeploy.transceiverImplementation, LzDeploy.transceiverImplementation, OpStackDeploy.transceiverImplementation, OpStackInteropDeploy.transceiverImplementation, WormholeDeploy.transceiverImplementation; also tests | No |
| `zkSyncTransceiverExtension()`<br>_internal_ | The extension for the zkSync variants built for tests. | CcipDeploy.zkSyncTransceiverImplementation, HyperlaneDeploy.zkSyncTransceiverImplementation, LzDeploy.zkSyncTransceiverImplementation; also tests | No |
| `deployTransceiverProxy(d, initData, providerGateway)`<br>_internal_ | Deploys a transceiver through `ProxyDeployer` and checks what its initializer established. | CcipDeploy.transceiver, CcipDeploy.tronTransceiver, CcipDeploy.zkSyncTransceiver, HyperlaneDeploy.transceiver, HyperlaneDeploy.tronTransceiver, HyperlaneDeploy.zkSyncTransceiver, LzDeploy.transceiver, LzDeploy.tronTransceiver, LzDeploy.zkSyncTransceiver, OpStackDeploy.transceiver, OpStackInteropDeploy.transceiver, WormholeDeploy.transceiver | No |
| `checkTransceiver(t, d, providerGateway)`<br>_internal view_ | Checks a deployed transceiver's code, extension, registry, treasury and gateway. | TransceiverDeploy.deployTransceiverProxy | No |
| `_checkDeploymentRecord(tb, te, d)`<br>_internal view_ | Checks the transceiver matches the registry's deployment record and predicted address. | TransceiverDeploy.checkTransceiver | No |
| `expectedDeployer(registry, provider, chainKey)`<br>_internal view_ | The deployer the registry records for a provider on a chain, or the current one. | DeployProvider._fromRecord, TransceiverDeploy._checkDeploymentRecord; also tests | No |
| `checkGovernorHomeId(t, c, homeId)`<br>_internal view_ | For bindings with an id table, checks the governor home's id was named at birth. | CcipDeploy.transceiver, CcipDeploy.tronTransceiver, CcipDeploy.zkSyncTransceiver, HyperlaneDeploy.transceiver, HyperlaneDeploy.tronTransceiver, HyperlaneDeploy.zkSyncTransceiver, LzDeploy._checkHome, OpStackDeploy.transceiver, WormholeDeploy.transceiver | No |


### `contracts/evm/script/deploy/WormholeDeploy.sol`

Library that deploys Wormhole's implementations and transceiver, with the Core bridge holding the gateway role.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiverImplementation(e)`<br>_internal_ | Deploys `WormholeReceiver` with the Core bridge and receiver authority pins. | DeployWormhole._implementations; also tests | No |
| `transmitterImplementation(e)`<br>_internal_ | Deploys `WormholeTransmitter` with the Core bridge and Executor. | DeployWormhole._implementations; also tests | No |
| `transceiverImplementation(e)`<br>_internal_ | Deploys `WormholeTransceiver` with the Core bridge, Executor and shared extension. | DeployWormhole._implementations; also tests | No |
| `transceiver(d, coreBridge, homeChain)`<br>_internal_ | Deploys the Wormhole transceiver proxy and checks the governor-home chain id. | DeployWormhole._deploy; also tests | No |

