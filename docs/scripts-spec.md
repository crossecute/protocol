# Foundry scripts reference

A file-by-file reference of the SDK's Foundry scripting files: the script base contracts in `contracts` and the example script in `script`. It is written in the same form as [the naming and function reference](naming-spec.md), and the names follow the same rules. Each file has one sentence on what it is, and each function that another file calls, or that a user can run, has a row saying what it does, who calls it, and whether a user calls it.

The SDK part of the naming reference leaves these files out, and its "Called by" cells do not list their functions. The names here are the ones the SDK takes at the protocol 0.3.0 sync, so they can differ from the SDK's `main` until then. Callers are matched by name and call syntax, not by a compiler.

## Foundry library scripts: `contracts`

### `contracts` (top level)

#### `contracts/AuthorityRelayScript.sol`

Abstract Foundry script base that checks a destination receiver's authority selection on a fork and writes the source Safe's `relayAuthority` transaction (single or multicall batch) as Safe EIP-712 typed data.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `aggregate3Value(calls)`<br>_IAuthorityRelayMulticall · external payable_ | Multicall3-style batch entry point that carries several relay calls in one Safe transaction. | AuthorityRelayScript._authorityRelayBatchTx; also tests | Yes, via a multicall contract the Safe calls |
| `selection()`<br>_IAuthorityRelayReceiver · external view_ | The destination receiver's selected authority update head and graph hash, read to confirm nothing changed. | AuthorityRelayScript._requireAuthorityRelaySelection; also tests | Yes, anyone reads it on the receiver |
| `_writeAuthorityRelay(relay, destinationRpc, output)`<br>_AuthorityRelayScript · internal_ | Checks one relay against the destination fork and writes the source Safe's `relayAuthority` transaction as typed data. | tests only | Yes, from a Foundry script |
| `_writeAuthorityRelayBatch(relays, destinationRpcs, multicall, output)`<br>_AuthorityRelayScript · internal_ | Checks every relay against its destination fork and writes one multicall Safe transaction that relays them all. | tests only | Yes, from a Foundry script |
| `_authorityRelayBatchTx(relays, multicall)`<br>_AuthorityRelayScript · internal_ | Builds the single multicall Safe transaction for relays that share a source chain, Safe and nonce. | AuthorityRelayScript._writeAuthorityRelayBatch; also tests | Yes, from a Foundry script |
| `_authorityRelayTx(relay, quoteAccount)`<br>_AuthorityRelayScript · internal_ | Quotes the relay fee and builds the Safe transaction that calls `relayAuthority` on the transmitter. | AuthorityRelayScript._writeAuthorityRelay, AuthorityRelayScript._authorityRelayBatchTx; also tests | Yes, from a Foundry script |

Private helpers: `_requireAuthorityRelaySelection`, `_destinationFork`, `_safeRelayProposal`.


#### `contracts/CrossecuteScript.sol`

Abstract Foundry script base that forks each destination, simulates batches as the conduit's receiver there, turns them into the owner's home-chain calls and writes them as a plan file, Safe typed data, a Safe batch file or a broadcast.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_useHome(registry, transmitter_)`<br>_internal_ | Takes the `--fork-url` chain as the conduit's home and reverts unless the registry places the transmitter's transceiver and the transceiver's CREATE2 places the transmitter. | Example.run | Yes, from a Foundry script |
| `_useDestination(rpcUrl)`<br>_internal_ | Creates and registers a fork of a destination RPC and returns its chain id (first overload at the latest block, second at a fixed block). | Example.run | Yes, from a Foundry script |
| `_useDestination(rpcUrl, blockNumber)`<br>_internal_ | Creates and registers a fork of a destination RPC and returns its chain id (first overload at the latest block, second at a fixed block). | Example.run | Yes, from a Foundry script |
| `_selectHome()`<br>_internal_ | Switches to the home fork; virtual so a test can run every chain in one EVM. | CrossecuteScript._registerDestination, CrossecuteScript._requireConduit, CrossecuteScript._receiverOn, CrossecuteScript._plan, CrossecuteScript._safeTx, CrossecuteScript._broadcast, MerklePackageScript._queue, MerklePackageScript._observeReceiver; also tests | Overridable hook (tests); scripts do not call it |
| `_selectDestination(chainId)`<br>_internal_ | Switches to a destination's fork; virtual so a test can run every chain in one EVM. | CrossecuteScript._simulate, MerklePackageScript._observeReceiver; also tests | Overridable hook (tests); scripts do not call it |
| `_requireConduit(registry)`<br>_internal_ | Reverts unless the registry's prediction of the transmitter's transceiver, and that transceiver's CREATE2 of the transmitter, both hold. | CrossecuteScript._useHome; also tests | Overridable hook (tests); runs inside `_useHome` |
| `_receiverOn(chainId)`<br>_internal_ | The conduit's receiver on an EVM destination: the recorded one once bootstrapped, else the home transceiver's prediction. | CrossecuteScript._add, MerklePackageScript._observeReceiver; also tests | Yes, from a Foundry script |
| `_add(chainId, calls, attributes)`<br>_internal_ | Simulates calls as the receiver on a destination and queues them; the first batch to an unbootstrapped destination becomes its bootstrap. | Example.run; also tests | Yes, from a Foundry script |
| `_simulate(chainId, receiver, calls)`<br>_internal_ | Runs calls with the receiver as sender on the destination fork, checks its balance, and returns the gas used. | CrossecuteScript._add, MerklePackageScript._queue | Yes, from a Foundry script (subclasses) |
| `_plan()`<br>_internal_ | Builds the owner's home-chain calls for every queued batch and dry-runs them as the owner, then restores the fork. | Example.run; also tests | Yes, from a Foundry script |
| `_writeSafeBatch(plan, path)`<br>_internal_ | Writes the plan as a Safe Transaction Builder file for the owner Safe. | tests only | Yes, from a Foundry script |
| `_writePlan(plan, path)`<br>_internal_ | Writes the plan file the TypeScript SDK reads and `crossecute check` verifies. | Example.run; also tests | Yes, from a Foundry script |
| `_writeSafeTx(plan, nonce, path)`<br>_internal_ | Writes the plan as one Safe transaction at a nonce, as EIP-712 typed data to sign, and returns its hash. | Example.run; also tests | Yes, from a Foundry script |
| `_safeTx(plan, nonce)`<br>_internal_ | Builds the one Safe transaction for a plan (direct call or MultiSendCallOnly) and checks it against the Safe's own `getTransactionHash`. | CrossecuteScript._writeSafeTx; also tests | Yes, from a Foundry script (subclasses) |
| `_multiSendCallOnly(version)`<br>_internal view_ | The MultiSendCallOnly address a Safe of a given version uses on this chain, matched by code hash. | CrossecuteScript._safeTx; also tests | Yes, from a Foundry script (subclasses) |
| `_knownMultiSendCallOnly(version)`<br>_internal view_ | Table of known MultiSendCallOnly deployments and code hash per Safe version; virtual so tests can add one. | CrossecuteScript._multiSendCallOnly; also tests | Overridable hook (tests) |
| `_broadcast(plan)`<br>_internal_ | Sends the plan's calls from an EOA owner with the script's signer. | none found | Yes, from a Foundry script |

Private helpers: `_homeCallFor`, `_multiSendPacked`, `_registerDestination`, `_requireLiveDvn`, `_runAsOwner`, `_toAddress`.


#### `contracts/MerklePackageScript.sol`

Abstract Foundry script base that drafts the Merkle package behind a signed `registerRoot`, adding execution leaves per destination receiver.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_addLeaf(chainId, validAfter, deadline, calls, attributes)`<br>_internal_ | Queues calls for a destination receiver at the next free nonce after simulating them (first overload), or at a given nonce for the same batch under other attributes (second overload). | tests only | Yes, from a Foundry script |
| `_addLeaf(chainId, nonce, validAfter, deadline, calls, attributes)`<br>_internal_ | Queues calls for a destination receiver at the next free nonce after simulating them (first overload), or at a given nonce for the same batch under other attributes (second overload). | tests only | Yes, from a Foundry script |
| `_merklePackage()`<br>_internal view_ | Checks the queued plan and builds its package, reverting with a `MerklePackages` error on a plan the receiver would refuse. | tests only | Yes, from a Foundry script |
| `_writeMerklePackage(pkg, path)`<br>_internal_ | Writes the package as JSON to a path. | tests only | Yes, from a Foundry script |

Private helpers: `_observeReceiver`, `_queue`.



## Example script: `script`

### `script` (top level)

#### `script/Example.s.sol`

Example Foundry script that simulates ownership transfers on two destinations and writes the plan and the owner Safe's typed-data transaction.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `transferOwnership(newOwner)`<br>_IOwnable · external_ | Interface for the example's target contract; the plan calls it as the receiver. | Example._transfer; also tests | Target contract's own function |
| `run()`<br>_Example · external_ | Entry point: uses the home chain, forks two destinations, queues a `transferOwnership` batch on each, then writes the plan and Safe transaction files. | tests only | Yes, run with `forge script` |

Private helpers: `_transfer`.

