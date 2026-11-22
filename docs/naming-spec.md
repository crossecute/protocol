# Naming and function reference

The naming rules for `crossecute/protocol` and the `crossecute/sdk` that tracks it, followed by a file-by-file reference of the code. Each file has one sentence on what it is. Each function that another file calls, or that a user can call, has a row saying what it does, who calls it, and whether a user calls it. New functions follow the rules below, and a rename that breaks a rule is a bug in the rename.

Part 1 holds the rules and a glossary. Part 2 is the protocol, as of the commit that added this file. Part 3 is the SDK, written with the names it takes from the protocol 0.3.0 sync, so it can differ from the SDK's `main` until that sync lands; its last section lists the differences. Part 4 lines up the same concept across the protocol, the SDK's Foundry library and its TypeScript.

## How to read the tables

| Column | Meaning |
|---|---|
| Function | Name with argument names, plus visibility and mutability. For a file with several contracts, the contract name comes first. |
| What it does | One sentence. For interface and override pairs it ends with where the same function is declared or implemented. |
| Called by | `Contract.function` for Solidity and `file.function` for TypeScript, from code in the two repos, including other functions in the same file (tests are summarized as "also tests" or "tests only"). `SDK ts/...` and `SDK ABI trim list` mean the SDK TypeScript or its trimmed ABI list references a protocol function by name. At most 12 callers are shown, then "(+N more)". |
| User-called? | Whether a person or integrator can call it from outside the code: a transaction, a Foundry script, the SDK API or the CLI. Access modifiers are shown where they gate it. |

What the tables do not cover:

- **Private helpers are not rows.** A `private` function, or an `internal` one used only inside its own file with no override elsewhere, appears in a "Private helpers" line under its file. Those names follow the same rules.
- **Callers are matched by name and call syntax, not by a compiler.** The match resolves the declared type of a variable where it can, so most same-name collisions are removed, but a call through a variable of an unrelated type with the same function name can still show up, and overloads share one caller list. Treat "Called by" as the places to check, and confirm with a build after renaming.
- **Tests, fixtures, mocks, docs and the generated ABI file are excluded** from callers except where marked. The SDK's Foundry scripting files are in [the scripts reference](scripts-spec.md), and the protocol's deployment scripts are not covered.
- **Interfaces and their implementations each get a row.** Renaming one means renaming both, and the "Declared in" and "Implemented in" notes list the pair.
- **Solidity events, errors, structs and constants are not rows.**


# Part 1: Naming rules

1. **A check that fails is `require*`.** Solidity functions revert and TypeScript functions throw. A `require*` function may return the value it checked or derived: `requireBootstrapBody` returns the body and `requireEvidence` returns the Safe transaction hash. Private helpers are `_require*`. The words `check`, `validate` and `verify` do not name a reverting check.
2. **A boolean is `is*` or `has*`.** `verify*` is also a boolean, for signature and proof checks that report instead of failing (the SDK's `verifyDispatchProof`, OpenZeppelin's `MerkleProof.verify`). A name that starts with `requires` is never a boolean.
3. **A function that records its input as used says so.** `consumeVaa` marks the VAA consumed and returns its payload, so it is not a check.
4. **A signed variant ends in `Signed`.** `bootstrapSigned`, `quoteBootstrapSigned`, `quoteMessageSigned`, `bootstrapCalldataSigned`, `sendMessageCalldataSigned`. The word is a suffix, never a prefix, and signed and unsigned variants have separate names, not overloads.
5. **A calldata builder ends in `Calldata`** and is named after the protocol function it encodes. A builder that returns a Safe transaction ends in `Tx`: `createLzOftTransmitterCalldata` returns calldata, and `lzOftCreateTx` wraps it in a Safe transaction. Encoders of values and wire bodies start with `encode`.
6. **A provider's chain id is set with `setProviderId`**, on the CCIP, Hyperlane, LayerZero, OP Stack and Wormhole transceivers. The parameter keeps the provider's own term (eid, selector, domain, Wormhole chain id, messenger address). The getters are `providerIdFor` and `hasProviderId`.
7. **Authority names.** `selectAuthority` replaces a Safe's authority graph and `selection` returns the selected update head and graph hash. The SDK's authority action is `select`.
8. **Bootstrap names.** `bootstrap(payload, attributes)` takes the payload that `bootstrapPayload(destinationChainIdentifier, body)` builds. The body is what the destination receiver runs on creation. In signed mode the body is a `SignedBootstrap`: `requireBootstrapBody` checks one against the guard's selection and returns it, and the SDK builds one with `bootstrapBodySigned` (Foundry) and `encodeBootstrapBodySigned` (TypeScript).
9. **JSON.** `...ToJsonObject` and `...FromJsonObject` convert between a value and its JSON object layout and verify nothing. `serialize...` and `parse...` use JSON text and verify.
10. **Names that others fix are kept.** Provider callbacks (`ccipReceive`, `handle`, `lzCompose`, `executeVAAv1`, `receiveOpStackMessage`), standard interfaces (ERC-165 `supportsInterface`, ERC-7786 `sendMessage` and `supportsAttribute`), inherited OpenZeppelin names (`grantRole`, `transferOwnership`, `_checkOwner`), Safe's `checkSignatures`, and command names of the `crossecute` CLI (`crossecute check`).

Not yet covered by a rule: the lookup suffixes (`For`, `Of`, `On`, `At`, `To`), whose use varies across `providerIdFor`, `commitmentFor`, `routeFor`, `destinationOf`, `deriverOf`, `isBootstrappedOn` and `chainKeyAt`.

## Glossary

| Term | Meaning |
|---|---|
| Chain key | The `bytes32` the protocol uses to name a chain, computed by hashing its canonical ERC-7930 chain identifier. `ChainKey.forEvm` takes an EVM chain id, and `Erc7930.chainKey` takes an ERC-7930 envelope. Both yield the same key for the same EVM chain. |
| Provider id | A provider's own id for a chain: an eid, selector, domain, Wormhole chain id, or on OP Stack the messenger address. Written once per chain key by `ProviderChainId`. |
| Unsigned mode, Safe-signed mode | In unsigned mode the home transmitter checks the conduit owner and the destination receiver authenticates delivery through its messaging provider. In Safe-signed mode the receiver also verifies Safe authorization for each message or Merkle leaf. |
| Bootstrap payload, body | The payload is `(destinationChainIdentifier, body)`. The body is what the destination receiver runs when it is created. |
| Selection | An `AuthoritySelection`: the selected update head and the hash of the selected authority graph. |
| Authority graph | The owner groups and thresholds of a source Safe that a receiver stores, committed to by the graph hash in the selection. |
| Staged record | The guard's record of an owner-signed Safe transaction, held until the signed target consumes it once. |
| Execution leaf | A Merkle leaf with the fields destination, nonce, `validAfter`, deadline, calls and attributes. `executionId` is its replay identity and leaves out the attributes. |
| Dispatch leaf hash | `dispatchLeafHash`: the double keccak of a leaf's encoded fields. `executionLeafHash` applies it to an execution leaf. |
| Plan | The unsigned-mode plan file: batches of home calls and the Safe transactions that carry them. `parsePlan` reads it and `requirePlan` checks it. |
| Merkle package | The leaves behind a signed `registerRoot`, with their tree, root and proofs. `requireMerklePlan` rejects leaf sets the receiver would refuse. |
| Delivery bundle | A signed Safe transaction together with its Merkle package. `requireDeliveryBundle` checks it offline, and calldata that submits it can be produced from it. |
| Wire body | The standalone or Merkle encoding that a signed receiver consumes (`encodeStandaloneWire`, `encodeMerkleWire`). |


# Part 2: Protocol (`crossecute/protocol`)

## EVM contracts: `contracts/evm/src`

### `contracts/evm/src/addressing`

#### `contracts/evm/src/addressing/ChainKey.sol`

Library that turns a chain identity (an EVM chain id, `block.chainid`, or an ERC-7930 identifier) into the `bytes32` key the protocol uses to name a destination.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `forEvm(chainId)`<br>_internal pure_ | Key for an eip155 chain id, computed with no storage or registry lookup. | ChainKey.local, TransmitterBase.isBootstrappedOn, TransmitterBase.recipientOn, TransmitterBase.commitmentFor, LzOftConduitFactory._createSignedReceiver, OpStackInteropTransceiver.receiveOpStackMessage, LzDvn.isDeadDvnRequired; also tests | No |
| `local()`<br>_internal view_ | This chain's own key, derived from `block.chainid`, as a destination-side receiver computes it. | Commitment.hashCalls, TransceiverCore.constructor, LzOftConduitFactory.constructor; also tests | No |
| `fromIdentifier(identifier)`<br>_internal pure_ | Key for any chain from an ERC-7930 envelope (strictly parsed, reduced to a chain identifier first), so every address on a chain gives one key. | OutboundBase._requireNames, TransmitterBase._requireOwnRecipient, TransmitterBase.commitmentForChain, LzOftConduitFactory.signedConduitBootstrap; also tests | No |
| `fromParsed(io)`<br>_internal pure_ | Same as `fromIdentifier` for an envelope that was already parsed. | ChainKey.fromIdentifier, LzOftTransmitter._messageParam; also tests | No |


#### `contracts/evm/src/addressing/ChainType.sol`

Constants-only library that is the single allocation table of ERC-7930 ChainType values, assigned and provisional.

Private helpers: `isProvisional`.


#### `contracts/evm/src/addressing/Erc7930.sol`

Library that encodes, strictly parses and derives keys for ERC-7930 interoperable addresses (the envelope binding a chain identity to an address).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `encode(chainType, chainRef, addr)`<br>_internal pure_ | Builds an interop address from a chain type, chain reference and address bytes. | Erc7930.encodeEvm, Erc7930.encodeChainId, Move.encodeMove, VmDeriver.deriveAddress, OutboundBase._recipientOn, LzOftConduitFactory.conduitBootstrap, LzOftConduitFactory.signedConduitBootstrap; also tests | No |
| `encodeEvm(chainId, a)`<br>_internal pure_ | Builds the eip155 interop address for a chain id and an address. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransceiverCore._reportPayload; also tests | No |
| `encodeChainId(chainType, chainRef)`<br>_internal pure_ | Builds a chain identifier: an interop address with a zero-length address part. | ChainKey.fromParsed, Erc7930.encodeEvmChain, Erc7930.toChainIdentifier, TransmitterBase._decodeBootstrap; also tests | No |
| `encodeEvmChain(chainId)`<br>_internal pure_ | Builds the chain identifier for an EVM chain id. | ChainKey.forEvm, TransmitterBase._evmIdentifier; also tests | No |
| `parseStrict(raw)`<br>_internal pure_ | Parses an envelope and reverts on anything non-canonical (version, lengths, trailing bytes, non-minimal eip155 reference). | ChainKey.fromIdentifier, Erc7930.toChainIdentifier, VmDeriver.deriveAddress, Payload.isTypedDestination, ReceiverBase.receiveMessage, OutboundBase._recipientOn, TransmitterBase._decodeBootstrap, SignedDispatchCalls.requireDestination, TransceiverBase._signedBootstrapInbound, TransceiverBase._onDestinationReceiver, TransceiverExtension._recordCounterpart, ProviderAddress.evmRecipient (+10 more); also tests | No |
| `evmChainId(io)`<br>_internal pure_ | Reads the EVM chain id out of a parsed eip155 envelope (inverse of `encodeEvmChain`). | SignedDispatchCalls.requireDestination, TransceiverBase._signedBootstrapInbound, OpStackInteropMessage._requireSend, OpStackInteropTransceiver._conduitInitializer; also tests | No |
| `toChainIdentifier(raw)`<br>_internal pure_ | Drops the address part of an envelope, leaving just the chain identifier. | Erc7930.chainKey, ChainRegistry._addChainKey | No |
| `chainKey(raw)`<br>_internal pure_ | Hashes the chain-identifier form of an envelope into a grouping key, independent of the account. | ReceiverBase.receiveMessage, TransceiverBase._onDestinationReceiver, ProviderChainId.providerIdOf, ProviderChainId._providerIdOf, OpStackInteropMessage._requireSend, ChainRegistry.requireLocation, ChainRegistry.expectedTransceiver; also tests | No |
| `toAddress(io)`<br>_internal pure_ | Reads a 20-byte address out of a parsed envelope. | LzOftTransmitter._messageParam; also tests | No |
| `minimalBigEndian(x)`<br>_internal pure_ | Minimal big-endian bytes for an integer, the eip155 chain-reference encoding rule. | Erc7930.encodeEvm, Erc7930.encodeEvmChain, AddressDerive.create; also tests | No |

Private helpers: `_slice`, `isEvmAccount`.


#### `contracts/evm/src/addressing/Move.sol`

Reference library for Move chains (Aptos, Movement, Sui): provisional chain types, a fixed-width address encoding, and a hashed qualifier (account, module, entry function) for signed payloads.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `isMoveChain(chainType)`<br>_internal pure_ | Whether a chain type is one of the provisional Move chain types. | Move.requireQualifier, Move.encodeMove, MoveValidator.requireRef | No |
| `hash(q)`<br>_internal pure_ | Commitment over a Move qualifier for inclusion in a signed payload (`abi.encode`, so fields cannot shift). | ChainRegistry.setQualifier; also tests | No |
| `requireQualifier(q, chainType)`<br>_internal pure_ | Structural check of a qualifier against its chain: kind set, module and function names present only when the kind needs them. | ChainRegistry.setQualifier | No |

Private helpers: `encodeAptos`, `encodeMove`, `encodeSui`, `isProvisional`, `requireIdentifier`, `toAddress`.


### `contracts/evm/src/conduit`

#### `contracts/evm/src/conduit/Conduits.sol`

Library holding the ordered steps every conduit creator takes: refuse an occupied address, CREATE2 a `Proxy`, check it landed where predicted, then arm and lock it.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireVacant(conduit, owner, salt)`<br>_internal view_ | Reverts `ConduitExists` if code is already at the predicted conduit address. | TransceiverBase._createConduit, LzOftConduitFactory.createTransmitter, LzOftConduitFactory._authenticate, LzOftConduitFactory._createSignedReceiver | No |
| `deploy(salt, initCodeStore)`<br>_internal_ | CREATE2s `Proxy`'s initcode (read from the code store) under the given salt. | TransceiverBase._deployConduit, LzOftConduitFactory.createTransmitter, LzOftConduitFactory._createReceiver, LzOftConduitFactory._createSignedReceiver; also tests | No |
| `requireLanded(predicted, deployed)`<br>_internal pure_ | Reverts `ConduitAddressMismatch` if the deployed address differs from the prediction. | TransceiverBase._createConduit, LzOftConduitFactory.createTransmitter, LzOftConduitFactory._createReceiver, LzOftConduitFactory._createSignedReceiver | No |
| `arm(conduit, implementation, initializer)`<br>_internal_ | Calls `upgradeInitializeAndLock` on the new proxy to install its implementation and lock the upgrade key in one call. | TransceiverBase._createConduit, LzOftConduitFactory.createTransmitter, LzOftConduitFactory._createReceiver, LzOftConduitFactory._armSignedReceiver; also tests | No |


#### `contracts/evm/src/conduit/Proxy.sol`

The minimal proxy every conduit and transceiver is deployed as, whose implementation is installed and locked once by its deployer.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `upgradeInitializeAndLock(implementation, data)`<br>_IProxy · external_ | The one deployer-only call on `Proxy`: set the implementation, run its initializer, and lock the upgrade key. | Conduits.arm, ProxyDeployer.deploy; also tests | Yes via interface (state-changing) |
| `constructor`<br>_Proxy · constructor_ | Records the deploying account as the only one allowed to arm the proxy. | tests only | No (constructor) |
| `fallback`<br>_Proxy · external payable_ | Delegatecalls every other call to the locked implementation. | tests only | Yes (plain call) |


#### `contracts/evm/src/conduit/ProxyDeployer.sol`

Singleton factory that deploys a `Proxy` and arms it in one transaction, with a per-caller CREATE2 salt so each caller has its own address space.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `deploy(salt, implementation, data)`<br>_external_ | Deploys a `Proxy` under `proxySalt(msg.sender, salt)` and arms it with the given implementation and initializer. | Conduits.deploy; also tests | Yes, anyone (state-changing) |
| `predict(deployedBy, salt)`<br>_external view_ | Returns the proxy address `deployedBy` would get for a salt. | tests only | Yes, anyone (read-only) |
| `proxySalt(deployedBy, salt)`<br>_internal pure_ | Hashes the caller into the CREATE2 salt so nobody else can deploy at that caller's addresses. | ProxyDeployer.deploy, ProxyDeployer.predict, ChainRegistry.predictTransceiver; also tests | No |


#### `contracts/evm/src/conduit/ProxyInitCode.sol`

Library that keeps `Proxy`'s initcode in a separate code-only contract so conduit creators read it instead of embedding it in their own runtime.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash()`<br>_internal pure_ | Hash of `Proxy`'s initcode, the value every CREATE2 conduit prediction uses. | TransceiverCore (initializer), LzOftConduitFactory (initializer); also tests | No |
| `store()`<br>_internal_ | Deploys the code-only contract holding `Proxy`'s initcode. | TransceiverBase._storeProxyInitCode, LzOftConduitFactory.constructor; also tests | No |
| `load(initCodeStore)`<br>_internal view_ | Reads the initcode back from a store contract. | Conduits.deploy; also tests | No |


### `contracts/evm/src/derivation`

#### `contracts/evm/src/derivation/AddressDerive.sol`

Library of deterministic address derivations for EVM and non-EVM chains (CREATE, CREATE2, CREATE3, EIP-1167 clones, zkSync, Tron, Cosmos, Solana, NEAR), computed on-chain.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `create2(deployer, salt, initCodeHash)`<br>_internal pure_ | EIP-1014 CREATE2 address from deployer, salt and initcode hash. | AddressDerive.clone2, AddressDerive.create3, VmDeriver._derive, ChainRegistry.predictTransceiver, ChainRegistry.predictConduit; also tests | No |
| `create(deployer, nonce)`<br>_internal pure_ | Nonce-based CREATE address, `keccak256(rlp([deployer, nonce]))[12:]`. | AddressDerive.create3, VmDeriver._derive; also tests | No |
| `cloneInitCodeHash(implementation)`<br>_internal pure_ | Creation-code hash of an EIP-1167 minimal proxy for an implementation. | AddressDerive.clone2, VmDeriver.cloneInitCodeHash, VmDeriver._derive; also tests | No |
| `clone2(deployer, implementation, salt)`<br>_internal pure_ | Address of an EIP-1167 clone deployed with CREATE2. | VmDeriver._derive; also tests | No |
| `create3(factory, salt)`<br>_internal pure_ | CREATE3 address, which depends only on factory and salt. | VmDeriver._derive | No |
| `zksyncCreate2(sender, salt, bytecodeHash, constructorInputHash)`<br>_internal pure_ | zkSync Era CREATE2 address from sender, salt, bytecode hash and constructor-input hash. | VmDeriver._derive, ZkSyncConduits._zkSyncConduit; also tests | No |
| `zksyncCreate(sender, nonce)`<br>_internal pure_ | zkSync Era CREATE address from sender and nonce. | VmDeriver._derive | No |
| `tronCreate2(deployer, salt, initCodeHash)`<br>_internal pure_ | Tron CREATE2 address (same preimage as EIP-1014 with the 0x41 domain byte). | VmDeriver._derive, TronConduits._tronConduit; also tests | No |
| `cosmosInstantiate2(checksum, creator, salt, initMsg)`<br>_internal pure_ | CosmWasm Instantiate2 address from checksum, creator, salt and init message. | VmDeriver._derive | No |
| `solanaCreateProgramAddress(seeds, bump, programId)`<br>_internal pure_ | Solana PDA for a known bump (does not search for the canonical bump). | VmDeriver._derive; also tests | No |
| `solanaAssociatedTokenAccount(owner, mint, tokenProgram, ataProgram, bump)`<br>_internal pure_ | Solana associated-token-account address from owner, mint, token program and bump. | VmDeriver._derive | No |
| `solanaCreateWithSeed(base, seed, programId)`<br>_internal pure_ | Solana `SystemProgram::createWithSeed` address. | VmDeriver._derive | No |
| `nearDeterministicAccount(borshStateInit)`<br>_internal pure_ | NEAR deterministic account id from a Borsh state init. | VmDeriver._derive | No |
| `nearEthImplicitAccount(uncompressedPubkey64)`<br>_internal pure_ | NEAR implicit account for an Ethereum public key. | VmDeriver._derive | No |

Private helpers: `applyL1ToL2Alias`, `hashL2Bytecode`, `undoL1ToL2Alias`.


#### `contracts/evm/src/derivation/BitcoinDerive.sol`

Library of Bitcoin script and witness-program hashes, kept apart from `AddressDerive` so `ripemd160` stays off EraVM builds.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash160(data)`<br>_internal pure_ | `ripemd160(sha256(x))`, used for P2PKH and P2WPKH programs. | BitcoinDerive.p2shScriptHash, VmDeriver._derive | No |
| `p2wshProgram(witnessScript)`<br>_internal pure_ | P2WSH witness program, `sha256` of the witness script. | VmDeriver._derive | No |
| `p2shScriptHash(redeemScript)`<br>_internal pure_ | P2SH script hash, `hash160` of the redeem script. | VmDeriver._derive | No |


#### `contracts/evm/src/derivation/Blake2b256.sol`

Library that builds full BLAKE2b-256 on the EIP-152 `blake2f` precompile.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash(input)`<br>_internal view_ | BLAKE2b-256 over arbitrary-length input. | SuiDerive.addressFromPubkey, SuiDerive.addressFromMultisig, SuiDerive.deriveObjectId, SuiDerive.deriveChildObjectId, Commitment._hash, Blake2bScheme.hash; also tests | No |

Private helpers: `_blockAt`, `_compress`, `_le64`.


#### `contracts/evm/src/derivation/IVmDeriver.sol`

Interface for uniform, stateless address derivation across every VM the protocol targets.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `deriveAddress(chainIdentifier, params)`<br>_external view_ | Derives the conduit envelope on a destination chain from a chain identifier and scheme-encoded parameters. Implemented in: VmDeriver. | ChainRegistry.expectedTransceiver; also tests | Yes via interface (read-only) |
| `supportsScheme(chainType, scheme)`<br>_external pure_ | Whether the deriver can serve a derivation scheme on a chain type, so the registry can reject bad wiring early. Implemented in: VmDeriver. | VmDeriver.deriveAddress, ChainRegistry.setDeriveParams; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/derivation/StarknetDerive.sol`

Library of the Starknet checks computable from the EVM (address bound, felt range, class hash), since Starknet addresses themselves cannot be derived here.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireAddress(addr)`<br>_internal pure_ | Reverts unless the address is strictly below Starknet's L2 address upper bound. | StarknetValidator.requireRef | No |
| `toFelt(addr)`<br>_internal pure_ | Reads a 32-byte Starknet address out of ERC-7930 address bytes as a field element. | StarknetValidator.requireRef | No |

Private helpers: `requireClassHash`, `requireFelt`, `selector`, `starknetKeccak`.


#### `contracts/evm/src/derivation/SuiDerive.sol`

Library for Sui address and object-id derivation using BLAKE2b-256.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `addressFromPubkey(flag, pubkey)`<br>_internal view_ | Sui address from a signature-scheme flag and public key. | VmDeriver._derive | No |
| `addressFromMultisig(threshold, flags, pubkeys, weights)`<br>_internal view_ | Sui MultiSig address from threshold, member flags, keys and weights. | VmDeriver._derive | No |
| `deriveObjectId(txDigest, creationNum)`<br>_internal view_ | Object id created by a transaction digest and creation number. | VmDeriver._derive | No |

Private helpers: `_le16`, `_le64`, `deriveChildObjectId`.


#### `contracts/evm/src/derivation/VmDeriver.sol`

Standalone stateless contract that implements every supported address derivation, dispatched by (chain type, scheme).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `cloneInitCodeHash(implementation)`<br>_external pure_ | External wrapper over `AddressDerive.cloneInitCodeHash` so the value can be computed off-chain and pinned in a payload. | tests only | Yes, anyone (read-only) |
| `deriveAddress(chainIdentifier, params)`<br>_external view_ | Decodes the scheme parameters and returns the derived conduit envelope for the chain. Declared in: IVmDeriver. | ChainRegistry.expectedTransceiver; also tests | Yes, anyone (read-only) |
| `supportsScheme(chainType, scheme)`<br>_public pure_ | The legality table of which scheme is valid on which chain type. Declared in: IVmDeriver. | VmDeriver.deriveAddress, ChainRegistry.setDeriveParams; also tests | Yes, anyone (read-only) |

Private helpers: `_derive`.


### `contracts/evm/src/messaging`

#### `contracts/evm/src/messaging/Call.sol`

Defines the typed `Call` struct and the `Calls` library that converts it to and from the canonical opaque element so both forms hash identically.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash(c)`<br>_internal pure_ | Element hash of a call, equal to `keccak256` of its canonical encoding. | Commitment.hashCalls; also tests | No |
| `encodeAll(calls)`<br>_internal pure_ | Encodes an array of typed calls into canonical opaque elements. | Commitment.hashCalls; also tests | No |

Private helpers: `decode`, `encode`.


#### `contracts/evm/src/messaging/Commitment.sol`

Library that computes the commitment over a call array, seeded with the destination's chain key so it cannot replay on another chain.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hashCalls(calls)`<br>_internal view_ | Hash a destination requires over calls or opaque elements, in overloads for local or given destination key, keccak or plug-in scheme, and typed calls or elements. | ReceiverBase._finalize, TransmitterBase.commitmentFor, TransmitterBase.commitmentForChain; also tests | No |
| `hashCalls(destinationChainKey, calls)`<br>_internal pure_ | Hash a destination requires over calls or opaque elements, in overloads for local or given destination key, keccak or plug-in scheme, and typed calls or elements. | ReceiverBase._finalize, TransmitterBase.commitmentFor, TransmitterBase.commitmentForChain; also tests | No |
| `hashCalls(destinationChainKey, elements)`<br>_internal pure_ | Hash a destination requires over calls or opaque elements, in overloads for local or given destination key, keccak or plug-in scheme, and typed calls or elements. | ReceiverBase._finalize, TransmitterBase.commitmentFor, TransmitterBase.commitmentForChain; also tests | No |
| `hashCalls(scheme, destinationChainKey, elements)`<br>_internal view_ | Hash a destination requires over calls or opaque elements, in overloads for local or given destination key, keccak or plug-in scheme, and typed calls or elements. | ReceiverBase._finalize, TransmitterBase.commitmentFor, TransmitterBase.commitmentForChain; also tests | No |
| `hashCalls(scheme, destinationChainKey, calls)`<br>_internal view_ | Hash a destination requires over calls or opaque elements, in overloads for local or given destination key, keccak or plug-in scheme, and typed calls or elements. | ReceiverBase._finalize, TransmitterBase.commitmentFor, TransmitterBase.commitmentForChain; also tests | No |

Private helpers: `_fold`, `_hash`, `_seed`, `isComputable`.


#### `contracts/evm/src/messaging/DeliveryGas.sol`

Constants library holding the default destination gas for a message by what it does on arrival, used when the attributes name none.

_Declares no functions._


#### `contracts/evm/src/messaging/Envelope.sol`

Library that encodes and decodes the tagged message bodies that cross between transceivers: bootstrap, element bootstrap, signed bootstrap and receiver report.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `kindOf(message)`<br>_internal pure_ | Reads the leading kind tag of a message and reverts unless it is a kind the protocol defines. | Envelope._expect, TransceiverBase._handleInbound | No |
| `encodeBootstrap(owner, salt, transmitter, calls)`<br>_internal pure_ | Encodes the payload that stands up a receiver (owner, salt, transmitter, calls). | TransceiverBase._bootstrapEnvelope; also tests | No |
| `decodeBootstrap(message)`<br>_internal pure_ | Decodes a bootstrap message back into owner, salt, transmitter and calls. | TransceiverBase._handleInbound; also tests | No |
| `encodeBootstrapElements(owner, salt, transmitter, elements)`<br>_internal pure_ | Encodes a bootstrap for a destination whose calls this chain cannot express, carrying opaque elements. | TransceiverBase.bootstrapElements, TransceiverBase.quoteBootstrapElements; also tests | No |
| `encodeBootstrapBodySigned(owner, salt, transmitter, body)`<br>_internal pure_ | Encodes a signed conduit's bootstrap whose body carries the authority records and setup calls. | TransceiverBase.bootstrapSigned, TransceiverBase.quoteBootstrapSigned; also tests | No |
| `decodeSignedBootstrap(message)`<br>_internal pure_ | Decodes a signed bootstrap message into owner, salt, transmitter and body. | TransceiverBase._handleInbound; also tests | No |
| `encodeReceiverReport(owner, salt, interop)`<br>_internal pure_ | Encodes the report telling the home chain where the destination created a receiver. | TransceiverCore._reportPayload; also tests | No |
| `isReceiverReport(message)`<br>_internal pure_ | Whether a message leads with the report kind. | TransceiverCore._defaultGas | No |
| `decodeReceiverReport(message)`<br>_internal pure_ | Decodes a receiver report into owner, salt and the receiver's interop address. | TransceiverBase._handleInbound | No |

Private helpers: `_expect`.


#### `contracts/evm/src/messaging/Executor.sol`

Abstract base that runs a verified call array all-or-nothing under an overridable call policy, shared by receivers and transmitters.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `isAllowed(address, bytes4)`<br>_public view_ | Call policy for a target and selector; the default allows everything and subclasses can restrict it. | Executor._execute; also tests | Yes, anyone (read-only) |
| `_execute(calls)`<br>_internal_ | Runs the calls in order, reverting the whole array with `CallFailed` if any call fails. | ReceiverBase.__ReceiverBase_init, ReceiverBase._finalize, ReceiverBase.execute, ReceiverBase._deliverCalls, SignedReceiver.initializeSigned, SignedReceiver._runMessage, SignedReceiver._runLeaf, TransmitterBase.execute; also tests | No |


#### `contracts/evm/src/messaging/IErc7786.sol`

ERC-7786 interfaces for source gateways (`IERC7786GatewaySource`) and recipients (`IERC7786Recipient`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `supportsAttribute(selector)`<br>_IERC7786GatewaySource · external view_ | Whether the gateway supports an attribute selector. Implemented in: CcipTransmitter, HyperlaneTransmitter, LzOftTransmitter, LzTransmitter, OpStackInteropTransmitter, OpStackTransmitter. | SDK ABI trim list; also tests | Yes via interface (read-only) |
| `sendMessage(recipient, payload, attributes)`<br>_IERC7786GatewaySource · external payable_ | Creates a cross-chain message to a recipient with a payload and attributes and returns a send id. Implemented in: SignedTransmitter, TransmitterBase. | SignedTransmitter.sendMessage, SignedDispatchCalls.sendMessageArgs, OpStackInteropMessage.send, OpStackMessage.send, CrossecuteGuard._isStaged, SignedDispatch.sendMessageCalldataSigned, SDK ts/signed.sendMessageCalldataSigned, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `receiveMessage(receiveId, sender, payload)`<br>_IERC7786Recipient · external payable_ | Receives a cross-chain message from the gateway and returns the receive selector. Implemented in: ReceiverBase. | ReceiverBase.receiveMessage; also tests | Yes via interface (state-changing) |


#### `contracts/evm/src/messaging/Payload.sol`

Library for the wire encoding of call arrays (typed `Call[]` for EVM, opaque `bytes[]` for other VMs) and of the bootstrap payload.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `encodeCalls(calls)`<br>_internal pure_ | Wire bytes for an EVM destination's calls. | TransmitterBase.payloadForCalls; also tests | No |
| `decodeCalls(wire)`<br>_internal pure_ | Decodes calldata wire bytes into calls and reverts on anything else. | ReceiverBase._onMessage, LzOftConduitFactory.conduitBootstrap; also tests | No |
| `decodeCallsFromMemory(wire)`<br>_internal pure_ | Same as `decodeCalls` for a wire already in memory. | ReceiverBase._onMessageMemory, SignedReceiver.initializeSigned, SignedReceiver._runMessage, SignedReceiver._runLeaf, SignedTransmitterLib._bootstrapAuthority, TransmitterBase._quoteBootstrap, TransmitterBase._sendBootstrap; also tests | No |
| `encodeElements(elements)`<br>_internal pure_ | Wire bytes for a destination's opaque call elements. | TransmitterBase.payloadForElements; also tests | No |
| `decodeElementsFromMemory(wire)`<br>_internal pure_ | Decodes memory wire bytes into opaque elements. | TransmitterBase._quoteBootstrap, TransmitterBase._sendBootstrap; also tests | No |
| `encodeBootstrap(destinationChainIdentifier, body)`<br>_internal pure_ | Bootstrap payload carrying the destination's chain identifier and the body the receiver runs on creation. | TransmitterBase.bootstrapPayload, SignedDispatch.bootstrapCalldataSigned; also tests | No |
| `decodeBootstrap(payload)`<br>_internal pure_ | Splits a bootstrap payload into destination chain identifier and body. | TransmitterBase._decodeBootstrap; also tests | No |
| `isTypedDestination(chainIdentifier)`<br>_internal pure_ | Whether a destination chain identifier takes the typed `Call[]` form. | TransmitterBase.commitmentForChain; also tests | No |

Private helpers: `decodeElements`.


#### `contracts/evm/src/messaging/Roles.sol`

Abstract access-control base that decides which gateway addresses may carry a contract's messages, with grants only during initialization.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `grantRole(role, conduit)`<br>_Roles · public_ | Grants a role from the contract's own bootstrap payload; closes when initialization ends. Overrides or is overridden in: RolesEnumerable. | RolesEnumerable.grantRole; also tests | Yes, gated by onlyInitializing (state-changing) |
| `_grantInitialRole(role, conduit)`<br>_Roles · internal_ | Initializer-time grant, such as the provider endpoint named as a gateway. | TransceiverExtension.initializeBase, ProviderReceiver.initialize, ProviderTransceiver.__ProviderTransceiver_init, LzOftReceiver.initialize, LzReceiver.initialize, OpStackInteropTransceiver.initialize, OpStackReceiver.initialize; also tests | No |
| `hasRole(role, conduit)`<br>_Roles · public view_ | Whether an address holds a role. Overrides or is overridden in: RolesEnumerable. | RolesEnumerable.hasRole, WormholeReceiver.executeVAAv1, WormholeTransceiver.executeVAAv1; also tests | Yes, anyone (read-only) |
| `grantRole(role, conduit)`<br>_RolesEnumerable · public_ | Same initialization-only grant with the enumerable member set. Overrides or is overridden in: Roles. | tests only | Yes, gated by onlyInitializing (state-changing) |
| `hasRole(role, conduit)`<br>_RolesEnumerable · public view_ | Whether an address holds a role, with the enumerable base resolved. Overrides or is overridden in: Roles. | Roles.hasRole, WormholeReceiver.executeVAAv1; also tests | Yes, anyone (read-only) |
| `_revokeRole(role, conduit)`<br>_RolesEnumerable · internal_ | Removes a role member; used by a receiver's `revokeGateway`. | ReceiverBase.revokeGateway; also tests | No |
| `supportsInterface(interfaceId)`<br>_RolesEnumerable · public view_ | ERC-165 support merged across the access-control bases. Overrides or is overridden in: CcipReceiver. | CcipReceiver.supportsInterface; also tests | Yes, anyone (read-only) |

Private helpers: `_grantRole`.


### `contracts/evm/src/messaging/authority`

#### `contracts/evm/src/messaging/authority/AuthorityGraph.sol`

Struct definitions for a signed source's authority graph: `AuthorityNode`, `AuthorityGraph` and `AuthorityEntry`.

_Declares no functions._


#### `contracts/evm/src/messaging/authority/AuthorityMutations.sol`

Library that applies ordered Safe owner self-calls to an authority record the way Safe 1.5.0's `OwnerManager` does and checks the result against the expected record.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `applyMutations(current, mutations, expected)`<br>_internal pure_ | Applies the owner self-calls to the current record and reverts unless the result equals the expected record. | ReceiverAuthority._authenticate, ReceiverAuthority._proveChildUpdate; also tests | No |

Private helpers: `_indexOf`, `_kindIn`, `_requireNewOwner`, `_requirePredecessor`, `_requireThreshold`.


#### `contracts/evm/src/messaging/authority/AuthorityRecognition.sol`

Library that classifies the signed source call of an authority update (ownership-change batch or `selectAuthority`) for the source guard and for receivers.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `recognizeUpdates(context, evidence, children)`<br>_public pure_ | Recognizes the main update and each child update in a submission and returns what each commits to. | ReceiverAuthority.submit | No (linked library: its host contract calls it by delegatecall) |
| `recognize(context, safeTx)`<br>_public pure_ | Recognizes one signed Safe transaction as an ownership change or selection and returns the update it carries. | AuthorityRecognition.recognizeUpdates, SourceAuthorityGuard._authorityPreHook; also tests | No (linked library: its host contract calls it by delegatecall) |


#### `contracts/evm/src/messaging/authority/AuthorityTransport.sol`

Library holding the shared direct and provider-delivered authority submission paths so the nested ABI codecs stay out of receiver bytecode.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiveAuthority($, sourceChainId, context, wire)`<br>_external_ | Decodes authority data that arrived through the provider and applies it to the receiver's state. | SignedReceiver._onSignedMessage | No (linked library: its host contract calls it by delegatecall) |
| `submitBatch($, sourceChainId, context, args)`<br>_external_ | Decodes a batch of direct authority submissions and applies them in order. | ReceiverAuthorityTemplate._applyAuthorityBatch | No (linked library: its host contract calls it by delegatecall) |
| `submit($, sourceChainId, context, args)`<br>_external_ | Decodes one direct authority submission and applies it. | ReceiverAuthorityTemplate._applyAuthority | No (linked library: its host contract calls it by delegatecall) |

Private helpers: `_applySubmission`, `_submit`.


#### `contracts/evm/src/messaging/authority/AuthorityUpdateEncoding.sol`

Library of authority-update hashing and encoding: record hash, graph entries, graph hash and ownership-batch decoding.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `recordHash(record)`<br>_internal pure_ | Hash of one Safe authority record (owners, kinds, threshold). | AuthorityMutations.applyMutations, AuthorityUpdateEncoding.entries, ReceiverAuthority.requireActivation, ReceiverAuthority._proveChildUpdate, SourceAuthorityGuard._authorityPreHook, SourceAuthorityGuard._requireNamedPositionsExecuted; also tests | No |
| `entries(authority)`<br>_internal pure_ | Flattens an authority graph into its ordered entries. | AuthorityUpdateEncoding.graphHash, ReceiverAuthority.seed, ReceiverAuthority.requireActivation, ReceiverAuthority.requireUpdate, ReceiverAuthority._requireUpdate; also tests | No |
| `graphHash(sourceChainId, graphEntries)`<br>_internal pure_ | Content hash of a graph (from entries in the first overload, from a graph in the second), including the source chain id. | ReceiverAuthority.encodedGraphHash, ReceiverAuthority.seed, ReceiverAuthority.requireActivation, ReceiverAuthority.requireUpdate, ReceiverAuthority._requireUpdate, ReceiverAuthority._proveChildUpdate; also tests | No |
| `graphHash(sourceChainId, authority)`<br>_internal pure_ | Content hash of a graph (from entries in the first overload, from a graph in the second), including the source chain id. | ReceiverAuthority.encodedGraphHash, ReceiverAuthority.seed, ReceiverAuthority.requireActivation, ReceiverAuthority.requireUpdate, ReceiverAuthority._requireUpdate, ReceiverAuthority._proveChildUpdate; also tests | No |
| `decodeOwnershipBatch(guard, safe, data)`<br>_internal pure_ | Strictly decodes an ownership-change multiSend batch into the update and owner mutations. | AuthorityRecognition.recognize; also tests | No |
| `isOwnershipBatch(guard, data)`<br>_internal pure_ | Whether a multiSend batch opens with a call to the guard's `registerOwnershipChange`. | SourceAuthorityGuard._isAuthorityCall | No |

Private helpers: `_nextEntry`, `batchCallsSelf`, `ownershipBatchData`.


#### `contracts/evm/src/messaging/authority/ChildUpdate.sol`

Struct definition for `ChildUpdate`, the update of a retained descendant Safe that a parent update moves.

_Declares no functions._


#### `contracts/evm/src/messaging/authority/IReceiverAuthority.sol`

Interface of a signed receiver's selected authority and the authenticated updates and reads it exposes.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `submitAuthority(evidence, newGraph, childUpdates)`<br>_external_ | Verifies and applies the next signed update, a successor of the stored head. Implemented in: ReceiverAuthorityTemplate, SignedReceiver. | SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `submitAuthorityBatch(submissions)`<br>_external_ | Applies consecutive authority submissions atomically. Implemented in: ReceiverAuthorityTemplate, SignedReceiver. | SDK ts/authority.submitAuthorityBatchCalldata, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `selection()`<br>_external view_ | The receiver's selected update head and authority hash. Implemented in: ReceiverAuthorityTemplate. | SignedReceiver.authorityGraph, SDK ts/authority.receiverAuthoritySelection, SDK ABI trim list; also tests | Yes via interface (read-only) |
| `graph(authorityHash)`<br>_external view_ | The stored authority graph for a graph hash. Implemented in: ReceiverAuthorityTemplate. | ReceiverAuthorityTemplate.graph, SDK ABI trim list; also tests | Yes via interface (read-only) |
| `record(recordHash)`<br>_external view_ | The stored Safe authority record for a record hash. Implemented in: ReceiverAuthorityTemplate. | ReceiverAuthorityTemplate.record, SDK ABI trim list; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/messaging/authority/ReceiverAuthority.sol`

Externally linked library that holds a signed receiver's authority state (selection, graph, records) and the checks that move it, called by delegatecall against the receiver's storage.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `encodedGraphHash(sourceChainId, encoded)`<br>_external pure_ | Hash of an encoded graph for a source chain. | SignedTransmitterLib._bootstrapAuthority | No (linked library: its host contract calls it by delegatecall) |
| `bootstrap($, sourceChainId, sourceSafe, guard, body)`<br>_external_ | Seeds a provider-authenticated bootstrap's graph under the implementation's guard pin and returns the selection and setup calls. | SignedReceiver.initializeSigned; also tests | No (linked library: its host contract calls it by delegatecall) |
| `graph($, authorityHash)`<br>_public view_ | Reads a stored graph by hash. | ReceiverAuthorityTemplate.graph; also tests | No (linked library: its host contract calls it by delegatecall) |
| `record($, recordHash)`<br>_public view_ | Reads a stored record by hash. | ReceiverAuthority.graph, ReceiverAuthority.selectedRecords, ReceiverAuthority._storedVoters, ReceiverAuthorityTemplate.record; also tests | No (linked library: its host contract calls it by delegatecall) |
| `selectedRecords($)`<br>_external view_ | All records of the currently selected graph. | SignedReceiver.authorityRecords | No (linked library: its host contract calls it by delegatecall) |
| `requireEvidence($, sourceChainId, sourceSafe, evidence)`<br>_external view_ | Reverts unless application evidence verifies under the selected graph, leaving its head unchanged, and returns the Safe transaction hash. | SignedReceiver._requireEvidence | No (linked library: its host contract calls it by delegatecall) |
| `seed($, sourceChainId, sourceSafe, updateHead, initial)`<br>_public_ | Stores, once, the head and graph a bootstrap carried. | ReceiverAuthority.bootstrap, ReceiverAuthorityTemplate._seedAuthority; also tests | No (linked library: its host contract calls it by delegatecall) |
| `requireActivation(sourceChainId, sourceSafe, evidence, initial, live, recognized)`<br>_external view_ | Reverts unless a source Safe's first selection follows from its signed activation (source guard only). | SourceAuthorityGuard._authorityPreHook | No (linked library: its host contract calls it by delegatecall) |
| `requireUpdate(current, currentGraph, request)`<br>_external view_ | Reverts unless a source update verifies against the exact graph its current selection commits to. | SourceAuthorityGuard._authorityPreHook | No (linked library: its host contract calls it by delegatecall) |
| `submit($, request)`<br>_external_ | Verifies and stores a submitted update and returns its hash. | AuthorityTransport._submit | No (linked library: its host contract calls it by delegatecall) |

Private helpers: `_authenticate`, `_find`, `_isSeeded`, `_isVoterOwner`, `_openVoter`, `_proveChildUpdate`, `_requireCanonical`, `_requireOwnerKinds`, `_requireRoot`, `_requireUpdate`, `_requireVotes`, `_store`, `_storedVoters`, `_voterRecord`, `_voters`.


#### `contracts/evm/src/messaging/authority/ReceiverAuthorityTemplate.sol`

Abstract base that gives a signed receiver the shared authority entry points over the linked `ReceiverAuthority` library, leaving source identity, recognition pins and context locking as hooks.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_authority()`<br>_internal view_ | Returns the ERC-7201 namespaced authority storage. | ReceiverAuthorityTemplate.selection, ReceiverAuthorityTemplate.graph, ReceiverAuthorityTemplate.record, ReceiverAuthorityTemplate._seedAuthority, ReceiverAuthorityTemplate._applyAuthorityBatch, ReceiverAuthorityTemplate._applyAuthority, SignedReceiver.initializeSigned, SignedReceiver._onSignedMessage, SignedReceiver._requireEvidence, SignedReceiver.authorityRecords | No |
| `selection()`<br>_public view_ | The selected update head and authority hash. Declared in: IReceiverAuthority. | SignedReceiver.authorityGraph, SDK ts/authority.receiverAuthoritySelection, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `graph(authorityHash)`<br>_public view_ | The stored graph for a hash. Declared in: IReceiverAuthority. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `record(recordHash)`<br>_public view_ | The stored record for a hash. Declared in: IReceiverAuthority. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `submitAuthority(evidence, newGraph, childUpdates)`<br>_external_ | Applies one authority submission. Declared in: IReceiverAuthority. | SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `submitAuthorityBatch(submissions)`<br>_external_ | Applies a batch of authority submissions. Declared in: IReceiverAuthority. | SDK ts/authority.submitAuthorityBatchCalldata, SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `_applyAuthorityBatch(args)`<br>_internal_ | Runs the batch path after the context-idle check. | ReceiverAuthorityTemplate.submitAuthorityBatch, SignedReceiver.submitAuthorityBatch | No |
| `_applyAuthority(args)`<br>_internal_ | Runs the single-submission path after the context-idle check. | ReceiverAuthorityTemplate.submitAuthority, SignedReceiver.submitAuthority | No |
| `_recognitionPins()`<br>_internal view_ | Hook returning the immutable guard and MultiSendCallOnly addresses used to recognize source calls. Overrides or is overridden in: SignedReceiver. | ReceiverAuthorityTemplate._authorityContext; also tests | No |
| `_authoritySource()`<br>_internal view_ | Hook returning the receiver's source chain id and owner Safe. Overrides or is overridden in: SignedReceiver. | ReceiverAuthorityTemplate._seedAuthority, ReceiverAuthorityTemplate._authorityContext, SignedReceiver._onSignedMessage; also tests | No |
| `_requireAuthorityContextIdle()`<br>_internal view_ | Hook that must block authority changes while an application execution is in flight. Overrides or is overridden in: SignedReceiver. | ReceiverAuthorityTemplate._applyAuthorityBatch, ReceiverAuthorityTemplate._applyAuthority; also tests | No |

Private helpers: `_authorityContext`, `_authorityStorage`, `_seedAuthority`.


### `contracts/evm/src/messaging/inbound`

#### `contracts/evm/src/messaging/inbound/ISignedReceiver.sol`

Interfaces for a receiver in signed mode: permissionless submission and nonce read (`ISignedReceiver`) and the signed initializer a transceiver calls (`ISignedReceiverInit`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `submitMessage(evidence)`<br>_ISignedReceiver · external payable_ | Submits a signed standalone message directly to its receiver, sharing verification and replay tracking with provider delivery. Implemented in: SignedReceiver. | SignedDispatch.submitMessageCalldata, SDK ts/signed.submitMessageCalldata, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `submitLeaf(registrationEvidence, leaf, proof)`<br>_ISignedReceiver · external payable_ | Submits a Merkle-authorized execution leaf with its signed root registration and proof. Implemented in: SignedReceiver. | SignedDispatch.submitLeafCalldata, SDK ts/signed.submitLeafCalldata, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `nextNonce()`<br>_ISignedReceiver · external view_ | The nonce the next new execution leaf must carry. Implemented in: SignedReceiver. | SDK ABI trim list; also tests | Yes via interface (read-only) |
| `initializeSigned(sourceChainId, owner, body)`<br>_ISignedReceiverInit · external_ | Stores the source authority the bootstrap carried and runs the receiver's setup, called by the transceiver right after base initialization. Implemented in: SignedReceiver. | TransceiverBase._signedBootstrapInbound, LzOftConduitFactory._createSignedReceiver, SDK ABI trim list; also tests | Yes via interface (state-changing) |


#### `contracts/evm/src/messaging/inbound/ReceiverBase.sol`

Destination-side base that holds one receiver per transmitter per destination, runs payloads by commit-then-finalize or direct execute, and accepts ERC-7786 deliveries from its trusted gateway.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `commit(commitment)`<br>_ICommitFinalize · external_ | Approves the hash of a call array to be executed later. Implemented in: ReceiverBase. | TransmitterBase.commitmentCall; also tests | Yes via interface (state-changing) |
| `finalize(calls)`<br>_ICommitFinalize · external_ | Runs an array that matches an approved hash (single array or batches). Implemented in: ReceiverBase. | tests only | Yes via interface (state-changing) |
| `finalize(batches)`<br>_ICommitFinalize · external_ | Runs an array that matches an approved hash (single array or batches). Implemented in: ReceiverBase. | tests only | Yes via interface (state-changing) |
| `cancel(commitment)`<br>_ICancel · external_ | Withdraws an approval. Implemented in: ReceiverBase. | TransmitterBase.cancellationCall; also tests | Yes via interface (state-changing) |
| `execute(calls)`<br>_IExecute · external payable_ | Runs a call array immediately with no hash comparison. Implemented in: ReceiverBase. | tests only | Yes via interface (state-changing) |
| `initialize(sourceTransmitter, homeOrigin, calls)`<br>_IReceiverInit · external_ | Binds a new receiver to its transmitter and home origin and runs its bootstrap calls; what a transceiver needs from the receiver it creates. Implemented in: LzOftReceiver, LzReceiver, OpStackReceiver, ProviderReceiver, ReceiverBase. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, OpStackInteropTransceiver._conduitInitializer; also tests | Yes via interface (state-changing) |
| `isSourceTransmitter(conduit)`<br>_ReceiverBase · public view_ | Whether an address is the transmitter this receiver was created for. | ReceiverBase.isAuthorizedCaller, ReceiverBase._authenticateSource, CcipReceiver._authorizeCcipPolicyChange, SDK ts/authority.planAuthorityCatchUp, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `isAuthorizedCaller(conduit)`<br>_ReceiverBase · public view_ | Whether an address may drive this receiver: the receiver itself (a payload it is executing) or its source transmitter. Overrides or is overridden in: SignedReceiver. | ReceiverBase.onlySourceTransmitter, SignedReceiver.isAuthorizedCaller, CcipReceiver._authorizeCcipPolicyChange; also tests | Yes, anyone (read-only) |
| `onlySourceTransmitter()`<br>_ReceiverBase · modifier_ | Modifier that reverts `NotSourceTransmitter` unless the caller passes `isAuthorizedCaller`. | ReceiverBase.revokeGateway, ReceiverBase.commit, ReceiverBase.cancel, ReceiverBase.execute | No (modifier) |
| `initialize(sourceTransmitter_, homeOrigin_, calls)`<br>_ReceiverBase · external_ | Binds the receiver to its transmitter and runs the payload it was created for. Declared in: IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, OpStackInteropTransceiver._conduitInitializer; also tests | Yes, gated by initializer (state-changing) |
| `__ReceiverBase_init(sourceTransmitter_, homeOrigin_, calls)`<br>_ReceiverBase · internal_ | Initializer body for bindings with their own `initialize`: binds, then runs the bootstrap calls. | ReceiverBase.initialize, ProviderReceiver.initialize, LzOftReceiver.initialize, LzReceiver.initialize, OpStackReceiver.initialize; also tests | No |
| `revokeGateway(gateway)`<br>_ReceiverBase · external_ | Source transmitter drops a gateway this receiver was armed with; only subtracts. | tests only | Yes, gated by onlySourceTransmitter (state-changing) |
| `commit(commitment_)`<br>_ReceiverBase · external_ | Source transmitter approves the hash of a call array for later finalization. Declared in: ICommitFinalize. | TransmitterBase.commitmentCall; also tests | Yes, gated by onlySourceTransmitter (state-changing) |
| `cancel(commitment_)`<br>_ReceiverBase · external_ | Source transmitter withdraws every copy of an approval. Declared in: ICancel. | TransmitterBase.cancellationCall; also tests | Yes, gated by onlySourceTransmitter (state-changing) |
| `finalize(calls)`<br>_ReceiverBase · external_ | Anyone supplies an array (or batches) that matches an outstanding approval and runs it. Declared in: ICommitFinalize. | tests only | Yes, gated by nonReentrant (state-changing) |
| `finalize(batches)`<br>_ReceiverBase · external_ | Anyone supplies an array (or batches) that matches an outstanding approval and runs it. Declared in: ICommitFinalize. | tests only | Yes, gated by nonReentrant (state-changing) |
| `execute(calls)`<br>_ReceiverBase · external payable_ | Source transmitter runs calls now with no commitment. Declared in: IExecute. | tests only | Yes, gated by onlySourceTransmitter, nonReentrant (state-changing) |
| `outstanding(commitment_)`<br>_ReceiverBase · public view_ | How many times a commitment may still be finalized. | tests only | Yes, anyone (read-only) |
| `isCommitted(commitment_)`<br>_ReceiverBase · public view_ | Whether a commitment has an approval left. | tests only | Yes, anyone (read-only) |
| `commitments()`<br>_ReceiverBase · external view_ | Every outstanding approval hash. | tests only | Yes, anyone (read-only) |
| `pendingCount()`<br>_ReceiverBase · external view_ | Number of distinct outstanding approvals. | tests only | Yes, anyone (read-only) |
| `receiveMessage(bytes32, sender, payload)`<br>_ReceiverBase · external payable_ | ERC-7786 delivery from the gateway: checks the gateway role and that the sender is this receiver's transmitter, then runs the payload. Declared in: IERC7786Recipient. | tests only | Yes, gated by onlyRole(GATEWAY_ROLE) (state-changing) |
| `_onMessageFrom(origin, sender, payload)`<br>_ReceiverBase · internal_ | Delivers a payload if the provider-reported origin and sender are this conduit's home and transmitter. | ReceiverBase.receiveMessage, HyperlaneReceiver.handle, LzOftReceiver.lzCompose, LzReceiver._lzReceive, OpStackInteropReceiver.receiveOpStackMessage, OpStackReceiver.receiveOpStackMessage, WormholeReceiver.executeVAAv1 | No |
| `_onMessageFromMemory(origin, sender, payload)`<br>_ReceiverBase · internal_ | Same as `_onMessageFrom` for providers whose callback already copied the payload to memory. | CcipReceiver._ccipReceive | No |
| `_onMessage(payload)`<br>_ReceiverBase · internal_ | Runs a payload that arrived over the wire (decode then execute); signed receivers override it. Overrides or is overridden in: SignedReceiver. | ReceiverBase._onMessageFrom, SignedReceiver._onMessage; also tests | No |
| `_onMessageMemory(payload)`<br>_ReceiverBase · internal_ | Same as `_onMessage` for a payload in memory. Overrides or is overridden in: SignedReceiver. | ReceiverBase._onMessageFromMemory, SignedReceiver._onMessageMemory | No |
| `receive`<br>_ReceiverBase · external payable_ | Accepts ETH so a receiver can be funded before a `finalize` that spends it. | tests only | Yes (plain call) |

Private helpers: `_authenticateSource`, `_deliverCalls`, `_finalize`.


#### `contracts/evm/src/messaging/inbound/SignedReceiver.sol`

Receiver that can be created in signed mode: its bootstrap seeds the source authority, authenticated updates select later graphs, and dispatch verifies Safe signatures whether delivered by a provider or submitted directly.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Sets the immutable source-authority guard and MultiSendCallOnly pins (both zero or both set). Overrides or is overridden in: CcipReceiver, HyperlaneReceiver, LzOftReceiver, LzReceiver, OpStackInteropReceiver, OpStackReceiver. | ProviderReceiver.constructor, CcipReceiver.constructor, HyperlaneReceiver.constructor, LzOftReceiver.constructor, LzReceiver.constructor, OpStackInteropReceiver.constructor, OpStackReceiver.constructor, WormholeReceiver.constructor; also tests | No (constructor) |
| `initializeSigned(sourceChainId, owner, body)`<br>_external_ | Validates and stores the source authority the bootstrap carried, then runs its setup calls. Declared in: ISignedReceiverInit. | TransceiverBase._signedBootstrapInbound, LzOftConduitFactory._createSignedReceiver, SDK ABI trim list; also tests | Yes, gated by nonReentrant (state-changing) |
| `submitAuthority(evidence, newGraph, childUpdates)`<br>_external_ | Verifies and applies the next signed authority update (nonReentrant). Declared in: IReceiverAuthority. | SDK ABI trim list; also tests | Yes, gated by nonReentrant (state-changing) |
| `submitAuthorityBatch(submissions)`<br>_external_ | Applies consecutive authority submissions atomically (nonReentrant). Declared in: IReceiverAuthority. | SDK ts/authority.submitAuthorityBatchCalldata, SDK ABI trim list; also tests | Yes, gated by nonReentrant (state-changing) |
| `_recognitionPins()`<br>_internal view_ | Returns the pinned guard and MultiSendCallOnly addresses. Overrides or is overridden in: ReceiverAuthorityTemplate. | ReceiverAuthorityTemplate._authorityContext; also tests | No |
| `_authoritySource()`<br>_internal view_ | Returns the receiver's source chain id and owner Safe. Overrides or is overridden in: ReceiverAuthorityTemplate. | ReceiverAuthorityTemplate._seedAuthority, ReceiverAuthorityTemplate._authorityContext, SignedReceiver._onSignedMessage; also tests | No |
| `_requireAuthorityContextIdle()`<br>_internal view_ | Blocks authority changes while an application execution or initialization holds the reentrancy lock. Overrides or is overridden in: ReceiverAuthorityTemplate. | ReceiverAuthorityTemplate._applyAuthorityBatch, ReceiverAuthorityTemplate._applyAuthority; also tests | No |
| `submitMessage(evidence)`<br>_external payable_ | Verifies and runs a signed standalone message, tracking its Safe transaction hash for replay. Declared in: ISignedReceiver. | SignedDispatch.submitMessageCalldata, SDK ts/signed.submitMessageCalldata, SDK ABI trim list; also tests | Yes, gated by nonReentrant (state-changing) |
| `submitLeaf(registrationEvidence, leaf, proof)`<br>_external payable_ | Verifies a signed root registration and Merkle proof and runs the execution leaf at its nonce. Declared in: ISignedReceiver. | SignedDispatch.submitLeafCalldata, SDK ts/signed.submitLeafCalldata, SDK ABI trim list; also tests | Yes, gated by nonReentrant (state-changing) |
| `_onMessage(payload)`<br>_internal_ | Signed-mode delivery: requires a recognized signed envelope and verified authorization before executing. Overrides or is overridden in: ReceiverBase. | ReceiverBase._onMessageFrom; also tests | No |
| `_onMessageMemory(payload)`<br>_internal_ | Same as `_onMessage` for a payload in memory. Overrides or is overridden in: ReceiverBase. | ReceiverBase._onMessageFromMemory | No |
| `isAuthorizedCaller(conduit)`<br>_public view_ | In signed mode, lets verified execution and finalization make self-calls; the transmitter address alone grants no authority. Overrides or is overridden in: ReceiverBase. | ReceiverBase.onlySourceTransmitter, CcipReceiver._authorizeCcipPolicyChange; also tests | Yes, anyone (read-only) |
| `authorityGraph()`<br>_external view_ | The stored graph hash, or zero for an unsigned receiver. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `authorityRecords()`<br>_external view_ | The stored Safe authority records in canonical order. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `nextNonce()`<br>_external view_ | The nonce the next new execution leaf must carry. Declared in: ISignedReceiver. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `executionAt(nonce)`<br>_external view_ | The execution id recorded at a nonce, or zero. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `isMessageExecuted(safeTxHash)`<br>_external view_ | Whether a standalone Safe transaction hash has already executed. | SDK ABI trim list; also tests | Yes, anyone (read-only) |

Private helpers: `_isSigned`, `_onSignedMessage`, `_requireEvidence`, `_runLeaf`, `_runMessage`, `_signedStorage`.


### `contracts/evm/src/messaging/outbound`

#### `contracts/evm/src/messaging/outbound/ISignedTransmitter.sol`

Interfaces for a transmitter in signed mode: the owner's calls plus the permissionless relay (`ISignedTransmitter`), and the signed initializer a transceiver calls (`ISignedTransmitterInit`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `bootstrap(payload, attributes)`<br>_ISignedTransmitter · external payable_ | Sends receiver setup together with the guard's selected authority head and graph (payload body is an encoded signed bootstrap). Implemented in: SignedTransmitter. | SignedReceiver.initializeSigned, SignedTransmitter.bootstrap, CrossecuteGuard._isStaged, SignedDispatch.bootstrapCalldataSigned, SDK ts/signed.bootstrapCalldataSigned, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `registerRoot(root)`<br>_ISignedTransmitter · external_ | Owner registers an authorized Merkle root so anyone can later relay its leaves. Implemented in: SignedTransmitter. | SignedDispatchCalls.registeredRoot, CrossecuteGuard._afterOwnerPolicyCheck, CrossecuteGuard._afterModulePolicyCheck, SignedDispatch.registerRootCalldata, SDK ts/signed.registerRootCalldata, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `relayAuthority(recipient, submission, attributes)`<br>_ISignedTransmitter · external payable_ | Anyone relays a published authority submission to the conduit's receiver, paying the fee; retries allowed. Implemented in: SignedTransmitter. | SignedTransmitter._refundTo, SDK ts/authority.buildAuthorityRelayProposal, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `quoteAuthority(recipient, submission, attributes)`<br>_ISignedTransmitter · external view_ | Prices the same authority relay. Implemented in: SignedTransmitter. | SignedTransmitter._refundTo, SDK ts/authority.buildAuthorityRelayProposal, SDK ABI trim list; also tests | Yes via interface (read-only) |
| `relayLeaf(registrationEvidence, leaf, proof)`<br>_ISignedTransmitter · external payable_ | Anyone pays to transmit one unused leaf authorized by a registered root and its signed registration. Implemented in: SignedTransmitter. | SignedTransmitter._refundTo, SignedDispatch.relayLeafCalldata, SDK ts/signed.relayLeafCalldata, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `initializeSigned()`<br>_ISignedTransmitterInit · external_ | Turns on signed mode, once. Implemented in: SignedTransmitter. | TransceiverBase.createTransmitter, LzOftConduitFactory.createTransmitter, SDK ABI trim list; also tests | Yes via interface (state-changing) |
| `isSigned()`<br>_ISignedTransmitterInit · external view_ | Whether the transmitter is in signed mode. Implemented in: SignedTransmitter. | TransceiverBase._isSignedConduit, LzOftConduitFactory.conduitBootstrap, LzOftConduitFactory.signedConduitBootstrap, LzOftConduitFactory.isSigned, SDK ABI trim list; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/messaging/outbound/OutboundBase.sol`

Abstract sending half shared by transmitters and transceivers: the counterpart and route tables per chain, recipient addressing, and the send and quote primitives.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_setRoute(chainKey, route)`<br>_internal_ | Records, write-once, how a destination chain is named (its canonical chain identifier) after checking it hashes to the key. | TransmitterBase._markBootstrapped, TransceiverExtension.initializeBase, TransceiverExtension.setRoute; also tests | No |
| `_requireNames(route, chainKey)`<br>_internal pure_ | Reverts unless the route is the canonical bare chain identifier the key hashes from. | OutboundBase._setRoute, TransceiverExtension.initializeBase | No |
| `_setCounterpart(chainKey, counterpart)`<br>_internal_ | Records this contract's counterpart on a chain, leaving the caller to decide whether a rewrite is allowed. | TransmitterBase.onDestinationReceiverReported, TransmitterBase._markBootstrapped, TransceiverExtension._recordCounterpart; also tests | No |
| `chainKeyOfRoute(route)`<br>_public view_ | The chain key of a configured route. | TransceiverBase._authenticateOrigin; also tests | Yes, anyone (read-only) |
| `routeFor(chainKey)`<br>_public view_ | How a chain is named here; reverts when unset. | OutboundBase._routeTo, TransceiverBase._signedBootstrapInbound, ProviderTransceiver._onProviderInbound, OpStackInteropTransceiver.receiveOpStackMessage, OpStackInteropTransceiver._conduitInitializer, OpStackTransceiver.receiveOpStackMessage; also tests | Yes, anyone (read-only) |
| `hasRoute(chainKey)`<br>_public view_ | Whether a route is set for a chain. | tests only | Yes, anyone (read-only) |
| `hasCounterpart(chainKey)`<br>_public view_ | Whether a counterpart is recorded for a chain. | TransmitterBase.isReachable, TransmitterBase._requireBootstrapped, TransceiverCore._counterpartOn, TransceiverExtension.setCounterpart, TransceiverExtension.resolveCounterpart; also tests | Yes, anyone (read-only) |
| `_counterpartOn(chainKey)`<br>_internal view_ | Where the counterpart lives; transceivers override it to apply provenance rules. Overrides or is overridden in: TransceiverCore. | OutboundBase.counterpartOn, OutboundBase._requireRoutable, OutboundBase._recipientOn, TransceiverBase._authenticateOrigin, TransceiverCore._counterpartOn, TransceiverCore._evmCounterpartOn, TransceiverExtension.initializeBase; also tests | No |
| `counterpartOn(chainKey)`<br>_public view_ | Public read of the counterpart on a chain. | TransmitterBase.destinationReceiverOn; also tests | Yes, anyone (read-only) |
| `routeTo(chainKey)`<br>_public view_ | Public read of the chain identifier a key is configured under. | tests only | Yes, anyone (read-only) |
| `_requireRoutable(chainKey)`<br>_internal view_ | Reverts unless both a trusted counterpart and a route exist for the chain. | TransceiverBase._requireBootstrappable | No |
| `_recipientOn(chainKey)`<br>_internal view_ | The counterpart on a chain as the ERC-7930 recipient an ERC-7786 gateway takes. | TransmitterBase.recipientOn, TransmitterBase._requireOwnRecipient, TransceiverBase._sendBootstrap, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver | No |
| `_refundTo()`<br>_internal view_ | Where a provider's excess fee goes back to; subclasses choose the payer. Overrides or is overridden in: SignedTransmitter, TransceiverCore, TransmitterBase. | SignedTransmitter._refundTo, HyperlaneTransceiverBase._sendMessage, HyperlaneTransceiverBase._quoteMessage, HyperlaneTransmitter._sendMessage, HyperlaneTransmitter._quoteMessage, LzOftTransmitter._sendMessage, LzTransceiverBase._sendMessage, LzTransmitter._sendMessage, WormholeTransceiver._sendMessage, WormholeTransmitter._sendMessage; also tests | No |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Provider-specific hook that puts a payload on the wire; no default. Overrides or is overridden in: CcipTransceiverBase, CcipTransmitter, HyperlaneTransceiverBase, HyperlaneTransmitter, LzOftTransmitter, LzTransceiverBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap, TransceiverBase._sendBootstrap, TransceiverBase._reportReceiver, LzOftTransmitter._sendSignedBootstrap; also tests | No |
| `_defaultGas(payload)`<br>_internal pure_ | Destination gas used when attributes name none, a function of the payload. Overrides or is overridden in: TransceiverCore, TransmitterBase. | CcipTransceiverBase._sendMessage, CcipTransceiverBase._quoteMessage, CcipTransmitter._sendMessage, CcipTransmitter._quoteMessage, HyperlaneTransceiverBase._sendMessage, HyperlaneTransceiverBase._quoteMessage, HyperlaneTransmitter._sendMessage, HyperlaneTransmitter._quoteMessage, LzOftTransmitter._messageParam, LzTransceiverBase._sendMessage, LzTransceiverBase._quoteMessage, LzTransmitter._sendMessage (+9 more); also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Provider-specific hook returning what `_sendMessage` would cost. Overrides or is overridden in: CcipTransceiverBase, CcipTransmitter, HyperlaneTransceiverBase, HyperlaneTransmitter, LzOftTransmitter, LzTransceiverBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver, LzOftTransmitter._quoteSignedBootstrap; also tests | No |
| `quoteMessage(recipient, payload, attributes)`<br>_external view_ | Quotes the cost of sending a payload to a recipient. Overrides or is overridden in: TransmitterBase. | SDK ABI trim list; also tests | Yes, anyone (read-only) |

Private helpers: `_routeTo`.


#### `contracts/evm/src/messaging/outbound/OwnableTransmitter.sol`

Abstract transmitter that uses OpenZeppelin `Ownable` as its authority, which every binding uses.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `initialize(owner_, transceiver_, salt_)`<br>_external_ | Initializes the transmitter with its owner, transceiver and salt in the shape the transceiver encodes. Overrides or is overridden in: LzOftTransmitter, LzTransmitter. | tests only | Yes, gated by initializer (state-changing) |
| `__OwnableTransmitter_init(owner_, transceiver_, salt_)`<br>_internal_ | Initializes `Ownable` with the owner and then the transmitter base; for bindings with their own `initialize`. | OwnableTransmitter.initialize, LzOftTransmitter.initialize, LzTransmitter.initialize; also tests | No |
| `_checkOwner()`<br>_internal view_ | Reverts unless the caller is the owner. Overrides or is overridden in: LzTransmitter, TransmitterBase. | SignedTransmitter.sendMessage, SignedTransmitter.bootstrap, TransmitterBase.onlyConduitOwner, LzTransmitter._checkOwner | No |


#### `contracts/evm/src/messaging/outbound/SignedTransmitter.sol`

Transmitter that can be created in signed mode: every owner send carries the owner Safe's signed transaction, a bootstrap carries the selected authority, and anyone can relay registered leaves or published authority updates.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `initializeSigned()`<br>_external_ | Enables signed mode, once. Declared in: ISignedTransmitterInit. | TransceiverBase.createTransmitter, LzOftConduitFactory.createTransmitter, SDK ABI trim list; also tests | Yes, but the body gates it (caller vs transceiver) (state-changing) |
| `sendMessage(recipient, payload, attributes)`<br>_public payable_ | In signed mode, consumes the Safe's staged call and sends its signed evidence with nested approvals; in unsigned mode takes the base path. Declared in: IERC7786GatewaySource. | SignedDispatchCalls.sendMessageArgs, OpStackInteropMessage.send, OpStackMessage.send, CrossecuteGuard._isStaged, SignedDispatch.sendMessageCalldataSigned, SDK ts/signed.sendMessageCalldataSigned, SDK ABI trim list; also tests | Yes, but the body gates it (owner check, super.sendMessage) (state-changing) |
| `bootstrap(payload, attributes)`<br>_public payable_ | In signed mode, consumes the staged call and sends setup calls with the guard's head and graph; unsigned mode takes the base path. Declared in: ISignedTransmitter. | SignedReceiver.initializeSigned, CrossecuteGuard._isStaged, SignedDispatch.bootstrapCalldataSigned, SDK ts/signed.bootstrapCalldataSigned, SDK ABI trim list; also tests | Yes, but the body gates it (owner check, super.bootstrap) (state-changing) |
| `registerRoot(root)`<br>_external_ | Owner registers a root for later permissionless leaf relays; only the root is stored. Declared in: ISignedTransmitter. | SignedDispatchCalls.registeredRoot, CrossecuteGuard._afterOwnerPolicyCheck, CrossecuteGuard._afterModulePolicyCheck, SignedDispatch.registerRootCalldata, SDK ts/signed.registerRootCalldata, SDK ABI trim list; also tests | Yes, gated by onlyConduitOwner (state-changing) |
| `transferOwnership(newOwner)`<br>_public_ | Transfers ownership via `Ownable` in unsigned mode. Signed mode fixes the owner to the creation-time Safe and reverts with `OwnershipFixed`. Overrides or is overridden in: LzTransmitter. | LzTransmitter.transferOwnership; also tests | Yes, but the body gates it (super.transferOwnership) (state-changing) |
| `renounceOwnership()`<br>_public_ | Renounces ownership via `Ownable` in unsigned mode and reverts with `OwnershipFixed` in signed mode. Overrides or is overridden in: LzTransmitter. | LzTransmitter.renounceOwnership; also tests | Yes, but the body gates it (super.renounceOwnership) (state-changing) |
| `_quoteSignedBootstrap(chainKey, bytes, body, attributes)`<br>_internal view_ | Hook that prices a signed bootstrap; bindings with their own transport override it. Overrides or is overridden in: LzOftTransmitter. | SignedTransmitter.bootstrap, SignedTransmitter.quoteBootstrap | No |
| `_sendSignedBootstrap(chainKey, bytes, body, attributes, fee)`<br>_internal_ | Hook that sends a signed bootstrap through the transceiver by default; OFT conduits send from the conduit. Overrides or is overridden in: LzOftTransmitter. | SignedTransmitter.bootstrap | No |
| `relayLeaf(registrationEvidence, leaf, proof)`<br>_external payable_ | Permissionless relay of one registered leaf, with a lock, used-leaf mark and balance check against reentrancy. Declared in: ISignedTransmitter. | SignedTransmitter._refundTo, SignedDispatch.relayLeafCalldata, SDK ts/signed.relayLeafCalldata, SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `relayAuthority(recipient, submission, attributes)`<br>_external payable_ | Permissionless relay of a published authority update to the receiver. Declared in: ISignedTransmitter. | SignedTransmitter._refundTo, SDK ts/authority.buildAuthorityRelayProposal, SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `quoteMessageBreakdown(recipient, payload, attributes)`<br>_public view_ | Quotes the unsigned send path, reverting in signed mode. Overrides or is overridden in: TransmitterBase. | TransmitterBase.sendMessage, TransmitterBase.quoteMessage; also tests | Yes, anyone (read-only) |
| `quoteBootstrap(payload, attributes)`<br>_public view_ | Quotes a bootstrap in either mode, validating and pricing a signed one's graph. Overrides or is overridden in: TransmitterBase. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `quoteMessageSigned(evidence)`<br>_external view_ | Builds the signed standalone payload from supplied evidence and returns its fee. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `quoteRelay(registrationEvidence, leaf, proof)`<br>_external view_ | The fee for relaying a given registration, leaf and proof. | SignedTransmitter._refundTo, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `quoteAuthority(recipient, submission, attributes)`<br>_external view_ | Prices the authority relay. Declared in: ISignedTransmitter. | SignedTransmitter._refundTo, SDK ts/authority.buildAuthorityRelayProposal, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `_refundTo()`<br>_internal view_ | Sends provider refunds to whoever funds a leaf or authority relay; other entry points keep refunds. Overrides or is overridden in: OutboundBase, TransmitterBase. | HyperlaneTransmitter._sendMessage, HyperlaneTransmitter._quoteMessage, LzOftTransmitter._sendMessage, LzTransmitter._sendMessage, WormholeTransmitter._sendMessage; also tests | No |
| `isSigned()`<br>_external view_ | Whether this transmitter is in signed mode. Declared in: ISignedTransmitterInit. | TransceiverBase._isSignedConduit, LzOftConduitFactory.conduitBootstrap, LzOftConduitFactory.signedConduitBootstrap, LzOftConduitFactory.isSigned, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `isRootRegistered(root)`<br>_external view_ | Whether the owner registered a root on this transmitter. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `isLeafRelayed(leafHash)`<br>_external view_ | Whether this transmitter already relayed a leaf hash. | SDK ABI trim list; also tests | Yes, anyone (read-only) |

Private helpers: `_authorityRelay`, `_beginRelay`, `_quoteStandalone`, `_relay`, `_requireSigned`, `_sendRelay`, `_sendStandalone`, `_signedBootstrap`, `_signedStorage`.


#### `contracts/evm/src/messaging/outbound/SignedTransmitterLib.sol`

Externally linked library that builds the signed transmitter's wire messages (standalone, Merkle leaf, authority), called by delegatecall so the transmitter is the signed target and the guard's `consume` caller.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `checkSignatures(executor, dataHash, signatures)`<br>_ISafeSignatures · external view_ | Safe 1.5.0's signature check against live owners and threshold, used to authorize a registration the relayer did not execute. | SignedTransmitterLib.relay; also tests | Yes via interface (read-only) |
| `deployer()`<br>_ISignedTransmitterView · external view_ | The transmitter's deployer, read back by self-call. | SignedTransmitterLib.consumeMessage, SignedTransmitterLib.quoteMessage, SignedTransmitterLib.consumeStaged, SignedTransmitterLib.requireBootstrapBody, SignedTransmitterLib.relay, SignedTransmitterLib.authority; also tests | Yes via interface (read-only) |
| `transceiver()`<br>_ISignedTransmitterView · external view_ | The transmitter's transceiver, read back by self-call. | SignedTransmitterLib.requireBootstrapBody; also tests | Yes via interface (read-only) |
| `consumeMessage(callData)`<br>_SignedTransmitterLib · external_ | Consumes the owner's staged transaction and builds its standalone wire message, recipient and attributes. | SignedTransmitter.sendMessage | No (linked library: its host contract calls it by delegatecall) |
| `quoteMessage(args)`<br>_SignedTransmitterLib · external view_ | Builds a standalone message from supplied evidence without consuming the staged transaction. | SignedTransmitter.quoteMessageSigned; also tests | No (linked library: its host contract calls it by delegatecall) |
| `consumeStaged()`<br>_SignedTransmitterLib · external_ | Consumes the staged transaction without reading it (used by bootstrap). | SignedTransmitter.bootstrap | No (linked library: its host contract calls it by delegatecall) |
| `requireBootstrapBody(chainKey, typed, body)`<br>_SignedTransmitterLib · external view_ | Reverts unless a supplied signed bootstrap matches the guard's current selection, and returns it unchanged. | SignedTransmitter._signedBootstrap | No (linked library: its host contract calls it by delegatecall) |
| `relay(args)`<br>_SignedTransmitterLib · external view_ | Validates the signed root registration and leaf proof, then builds the Merkle wire payload. | SignedTransmitter._relay; also tests | No (linked library: its host contract calls it by delegatecall) |
| `authority(submission)`<br>_SignedTransmitterLib · external view_ | Requires the exact portable evidence published by source execution and builds the authority wire. | SignedTransmitter._authorityRelay; also tests | No (linked library: its host contract calls it by delegatecall) |

Private helpers: `_bootstrapAuthority`, `_collect`, `_consume`, `_standalone`.


#### `contracts/evm/src/messaging/outbound/TransmitterBase.sol`

The per-user conduit on the home chain and source-side entry point (ERC-7786 `sendMessage`, `bootstrap`, quotes), plus `IConduitTransceiver`, the interface it uses on the transceiver it stores.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `treasury()`<br>_IConduitTransceiver · external view_ | The treasury the transceiver pays. | TransmitterBase._payCrossecuteFee; also tests | Yes via interface (read-only) |
| `bootstrap(destinationChainKey, owner, salt, calls, attributes)`<br>_IConduitTransceiver · external payable_ | Transceiver entry that sends a bootstrap with typed calls to a destination. | SignedReceiver.initializeSigned; also tests | Yes via interface (state-changing) |
| `bootstrapElements(destinationChainKey, owner, salt, elements, attributes)`<br>_IConduitTransceiver · external payable_ | Same for destinations whose calls are opaque elements. | tests only | Yes via interface (state-changing) |
| `quoteBootstrap(destinationChainKey, owner, salt, calls, attributes)`<br>_IConduitTransceiver · external view_ | Prices a typed-calls bootstrap. | TransmitterBase._quoteBootstrap; also tests | Yes via interface (read-only) |
| `quoteBootstrapElements(destinationChainKey, owner, salt, elements, attributes)`<br>_IConduitTransceiver · external view_ | Prices an elements bootstrap. | TransmitterBase._quoteBootstrap; also tests | Yes via interface (read-only) |
| `bootstrapSigned(destinationChainKey, owner, salt, body, attributes)`<br>_IConduitTransceiver · external payable_ | Bootstrap for a signed conduit whose body is an encoded signed bootstrap. | tests only | Yes via interface (state-changing) |
| `quoteBootstrapSigned(destinationChainKey, owner, salt, body, attributes)`<br>_IConduitTransceiver · external view_ | Prices a signed bootstrap. | SignedTransmitter._quoteSignedBootstrap; also tests | Yes via interface (read-only) |
| `conduitBootstrap(route, owner, salt, body)`<br>_IConduitTransceiver · external view_ | The message a conduit sends itself through its own transport to stand up on a chain; empty recipient means the transceiver carries it. | TransmitterBase._quoteBootstrap; also tests | Yes via interface (read-only) |
| `reportsReceiver(chainKey)`<br>_IConduitTransceiver · external view_ | Whether a destination reports its receiver address back rather than this chain deriving it. | SignedTransmitterLib.requireBootstrapBody, TransmitterBase._markBootstrapped; also tests | Yes via interface (read-only) |
| `routeTo(chainKey)`<br>_IConduitTransceiver · external view_ | The chain identifier the governor configured a destination under. | OpStackInteropMessage._requireSend; also tests | Yes via interface (read-only) |
| `predictReceiver(chainKey, owner, salt)`<br>_IConduitTransceiver · external view_ | Where this conduit's receiver will sit on a chain that does not report it. | TransmitterBase._markBootstrapped; also tests | Yes via interface (read-only) |
| `signedAuthority(owner)`<br>_IConduitTransceiver · external view_ | The owner's live authority records, or empty for an owner without a compatible guard. | tests only | Yes via interface (read-only) |
| `isBootstrapped(destinationChainKey)`<br>_TransmitterBase · public view_ | Whether a bootstrap to a destination has been dispatched. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `isBootstrappedOn(destinationChainId)`<br>_TransmitterBase · external view_ | Same by plain EVM chain id. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `isReachable(destinationChainKey)`<br>_TransmitterBase · external view_ | Whether this conduit can be sent to on a destination yet. | tests only | Yes, anyone (read-only) |
| `destinationReceiverOn(destinationChainKey)`<br>_TransmitterBase · external view_ | This conduit's receiver on a destination in that chain's own format. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `onDestinationReceiverReported(destinationChainKey, receiver)`<br>_TransmitterBase · external_ | Transceiver reports where the destination created this conduit's receiver, recorded as the counterpart. | tests only | Yes, but the body gates it (caller vs transceiver) (state-changing) |
| `isReceiverPinned(destinationChainKey)`<br>_TransmitterBase · external view_ | Whether a receiver report for a destination has been accepted. | tests only | Yes, anyone (read-only) |
| `_checkOwner()`<br>_TransmitterBase · internal view_ | Declared hook that reverts unless the caller is the owner. Overrides or is overridden in: LzTransmitter, OwnableTransmitter. | OwnableTransmitter._checkOwner, SignedTransmitter.sendMessage, SignedTransmitter.bootstrap, TransmitterBase.onlyConduitOwner, LzTransmitter._checkOwner | No |
| `onlyConduitOwner()`<br>_TransmitterBase · modifier_ | Modifier that applies `_checkOwner`. | SignedTransmitter.registerRoot, TransmitterBase.sendMessage, TransmitterBase.bootstrap, TransmitterBase.execute | No (modifier) |
| `sendMessage(recipient, payload, attributes)`<br>_TransmitterBase · public payable_ | Owner puts a payload on the wire for this conduit's receiver on another chain (the ERC-7786 source entry point). Declared in: IERC7786GatewaySource. | SignedTransmitter.sendMessage, SignedDispatchCalls.sendMessageArgs, OpStackInteropMessage.send, OpStackMessage.send, CrossecuteGuard._isStaged, SignedDispatch.sendMessageCalldataSigned, SDK ts/signed.sendMessageCalldataSigned, SDK ABI trim list; also tests | Yes, gated by onlyConduitOwner (state-changing) |
| `_sendFundedMessage(recipient, payload, attributes, providerFee, crossecuteFee)`<br>_TransmitterBase · internal_ | Requires the balance to cover provider and Crossecute fees, pays the Crossecute fee to the treasury, emits `MessageSent` and sends. | SignedTransmitter._sendStandalone, TransmitterBase.sendMessage | No |
| `_crossecuteFee(providerFee)`<br>_TransmitterBase · internal pure_ | Crossecute fee for a provider fee, by default one tenth of it; bindings can override. Overrides or is overridden in: OpStackTransmitterBase. | SignedTransmitter._sendStandalone, SignedTransmitter.quoteMessageSigned, TransmitterBase.quoteMessageBreakdown | No |
| `supportsAttribute(bytes4)`<br>_TransmitterBase · external view_ | ERC-7786 attribute support; none by default, bindings answer for theirs. Declared in: IERC7786GatewaySource. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `recipientOn(destinationChainId)`<br>_TransmitterBase · public view_ | The recipient `sendMessage` takes for this conduit on an EVM chain id, reverting until the receiver is known. | SDK ts/authority.planAuthorityCatchUp, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `chainIdentifierFor(destinationChainId)`<br>_TransmitterBase · public pure_ | ERC-7930 chain identifier for an EVM chain id. | tests only | Yes, anyone (read-only) |
| `payloadForCalls(calls)`<br>_TransmitterBase · public pure_ | Wire bytes for an EVM destination's calls. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `payloadForElements(elements)`<br>_TransmitterBase · public pure_ | Wire bytes for a destination's opaque elements. | tests only | Yes, anyone (read-only) |
| `_requireOwnRecipient(recipient)`<br>_TransmitterBase · internal view_ | Requires the recipient to be the receiver this conduit recorded for that chain and returns the chain key. | SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown | No |
| `bootstrap(payload, attributes)`<br>_TransmitterBase · public payable_ | Owner stands this conduit up on a destination through its transceiver and runs a payload there. Overrides or is overridden in: SignedTransmitter. | SignedReceiver.initializeSigned, SignedTransmitter.bootstrap, SDK ts/signed.bootstrapCalldataSigned, SDK ABI trim list; also tests | Yes, gated by onlyConduitOwner (state-changing) |
| `bootstrapPayload(destinationChainIdentifier, body)`<br>_TransmitterBase · public pure_ | Builds the payload `bootstrap` takes from a destination chain identifier and body. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `quoteMessage(recipient, payload, attributes)`<br>_TransmitterBase · public view_ | Quotes `sendMessage` with its checks applied. Overrides or is overridden in: OutboundBase. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `quoteMessageBreakdown(recipient, payload, attributes)`<br>_TransmitterBase · public view_ | Provider quote and Crossecute fee for a send. Overrides or is overridden in: SignedTransmitter. | SignedTransmitter.quoteMessageBreakdown, TransmitterBase.sendMessage, TransmitterBase.quoteMessage; also tests | Yes, anyone (read-only) |
| `quoteBootstrap(payload, attributes)`<br>_TransmitterBase · public view_ | Quotes a bootstrap without the owner/salt check. Overrides or is overridden in: SignedTransmitter. | SignedTransmitter.quoteBootstrap, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `_decodeBootstrap(payload)`<br>_TransmitterBase · internal view_ | Decodes and checks a bootstrap payload into chain key, route, typed flag and body. | SignedTransmitter._signedBootstrap, TransmitterBase.bootstrap, TransmitterBase.quoteBootstrap | No |
| `_requireFunded(fee)`<br>_TransmitterBase · internal view_ | Reverts unless the balance covers a fee. | SignedTransmitter.bootstrap, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap | No |
| `_markBootstrapped(chainKey, route)`<br>_TransmitterBase · internal_ | Records the destination before the transport call so a reentrant bootstrap meets the record. | SignedTransmitter.bootstrap, TransmitterBase.bootstrap | No |
| `execute(calls)`<br>_TransmitterBase · external payable_ | Owner runs calls on this chain with no bridge and no commitment. | SDK ABI trim list; also tests | Yes, gated by onlyConduitOwner (state-changing) |
| `commitmentCall(receiver, commitment)`<br>_TransmitterBase · public pure_ | Builds the call that pins a commitment on a receiver, for use inside a payload. | tests only | Yes, anyone (read-only) |
| `cancellationCall(receiver, commitment)`<br>_TransmitterBase · public pure_ | Builds the call that withdraws an approval on a receiver. | none found | Yes, anyone (read-only) |
| `commitmentFor(destinationChainId, calls)`<br>_TransmitterBase · public pure_ | The commitment a call array needs on an EVM destination by chain id. | tests only | Yes, anyone (read-only) |
| `commitmentForChain(destinationChainIdentifier, calls)`<br>_TransmitterBase · public pure_ | Same for a destination named by ERC-7930 identifier; refuses non-EVM. | tests only | Yes, anyone (read-only) |
| `receive`<br>_TransmitterBase · external payable_ | Accepts ETH, the balance sends are paid from and where provider refunds land. | tests only | Yes (plain call) |
| `_refundTo()`<br>_TransmitterBase · internal view_ | Refunds go back to this conduit (it paid from its own balance). Overrides or is overridden in: OutboundBase, SignedTransmitter. | SignedTransmitter._refundTo, HyperlaneTransmitter._sendMessage, HyperlaneTransmitter._quoteMessage, LzOftTransmitter._sendMessage, LzTransmitter._sendMessage, WormholeTransmitter._sendMessage; also tests | No |
| `_defaultGas(bytes)`<br>_TransmitterBase · internal pure_ | Default destination gas hook for the conduit. Overrides or is overridden in: OutboundBase. | CcipTransmitter._sendMessage, CcipTransmitter._quoteMessage, HyperlaneTransmitter._sendMessage, HyperlaneTransmitter._quoteMessage, LzOftTransmitter._messageParam, LzTransmitter._sendMessage, LzTransmitter._quoteMessage, OpStackTransmitter._sendMessage, OpStackTransmitter._quoteMessage, WormholeTransmitter._sendMessage, WormholeTransmitter._quoteMessage; also tests | No |
| `__TransmitterBase_init(owner_, transceiver_, salt_)`<br>_TransmitterBase · internal_ | Stores the transceiver (nonzero), the conduit salt and the deployer, and emits `TransmitterConfigured`. | OwnableTransmitter.__OwnableTransmitter_init | No |

Private helpers: `_evmIdentifier`, `_payCrossecuteFee`, `_quoteBootstrap`, `_requireBootstrapped`, `_requireNotBootstrapped`, `_sendBootstrap`.


### `contracts/evm/src/messaging/signed`

#### `contracts/evm/src/messaging/signed/Bytes.sol`

Library of memory byte-slice helpers that avoid `mcopy`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `slice(data, start, length)`<br>_internal pure_ | Copies a byte range into a new array, reverting if the range is invalid. | AuthorityUpdateEncoding.decodeOwnershipBatch, Bytes.arguments, SafeSignaturesUtils.extractContractSignature, SafeSignaturesUtils.approvalHash | No |
| `arguments(data, selector)`<br>_internal pure_ | Returns the calldata after a selector, reverting if the data does not start with it. | AuthorityMutations.applyMutations, AuthorityRecognition.recognize, AuthorityUpdateEncoding.decodeOwnershipBatch, AuthorityUpdateEncoding.isOwnershipBatch, AuthorityUpdateEncoding.batchCallsSelf, SignedDispatchCalls.sendMessageArgs, SignedDispatchCalls.registeredRoot | No |


#### `contracts/evm/src/messaging/signed/DispatchLeaves.sol`

Library for execution-leaf hashes and Merkle proof checks of a Safe-signed dispatch tree, matching the guard's `publishLeaves`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash(leaf)`<br>_internal pure_ | Double-keccak hash of every field of an execution leaf, attributes included. | SignedReceiver._runLeaf, SignedTransmitterLib.relay, MerklePackages._leafHashes; also tests | No |
| `executionId(leaf)`<br>_internal pure_ | Hash of a leaf's execution fields without attributes, identifying a batch at its nonce across re-approvals. | SignedReceiver._runLeaf, MerklePackages._leafHashes; also tests | No |
| `requireProof(proof, root, leafHash)`<br>_internal pure_ | Reverts unless the proof links the leaf hash to the root (smaller sibling hashed first). | SignedReceiver._runLeaf, SignedTransmitterLib.relay; also tests | No |


#### `contracts/evm/src/messaging/signed/NestedApprovalCollector.sol`

Library that gathers, on the source side, the nested child-Safe approval evidence a signature blob needs under each Safe's live threshold.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `collect(safe, dataHash, signatures)`<br>_internal view_ | Walks the signature blob and returns the approval evidence for each nested Safe, reverting if one is missing. | SignedTransmitterLib._collect; also tests | No |

Private helpers: `_approval`, `_entry`, `_nested`, `_threshold`, `_walk`.


#### `contracts/evm/src/messaging/signed/NestedOwnerManagerLib.sol`

Library of owner-list operations on stored Safe owner state that mirror Safe 1.5.0's `OwnerManager` ordering.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `setupOwners(self, sourceSafe, owners, threshold)`<br>_internal_ | Initializes a Safe's stored owner list and threshold once, in the supplied order. | SafeAuthority.store | No |
| `getOwners(self)`<br>_internal view_ | Reads each stored owner and kind in source Safe list order. | SafeAuthority._loadStored; also tests | No |

Private helpers: `_requireInitialized`, `_requireNewOwner`, `_requirePredecessor`, `_requireThreshold`, `addOwnerWithThreshold`, `changeThreshold`, `removeOwner`, `swapOwner`.


#### `contracts/evm/src/messaging/signed/SafeAuthority.sol`

Library that stores an authenticated owner graph on the destination and verifies Safe signature blobs against it without calling any Safe.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `store(self, records, sourceChainId)`<br>_public_ | Stores the authenticated graph records as the destination's local snapshot. | tests only | No (linked library: its host contract calls it by delegatecall) |
| `readRecords(self)`<br>_public view_ | Reads the stored graph back in canonical order. | tests only | No (linked library: its host contract calls it by delegatecall) |
| `requireQuorum(self, dataHash, signatures, approvals)`<br>_public view_ | Requires a valid root-Safe quorum over a data hash, including nested approvals. | tests only | No (linked library: its host contract calls it by delegatecall) |

Private helpers: `_isStoredOwner`, `_loadStored`, `_openStored`.


#### `contracts/evm/src/messaging/signed/SafeAuthorityGraph.sol`

Library defining the canonical owner graph of a Safe and its nested Safes, with live derivation, canonical-order validation and a shared depth-first walk.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `derive(root)`<br>_internal view_ | Derives the live canonical records of a root Safe by asking each owner Safe. | SafeViewer.signedAuthority; also tests | No |
| `requireCanonical(records)`<br>_internal view_ | Validates a supplied graph's owner groups, reachability, kinds and record order. | ReceiverAuthority._requireCanonical, SafeAuthority.store; also tests | No |
| `walk(root, context, load)`<br>_internal view_ | Traverses from a root with a supplied owner loader and returns each reachable Safe once. | SafeAuthority.readRecords, SafeAuthorityGraph.derive, SafeAuthorityGraph.requireCanonical | No |

Private helpers: `_ask`, `_grow`, `_insert`, `_isEoa`, `_loadLive`, `_loadRecord`, `_newIndex`, `_probe`, `_requireGroup`, `_visit`, `hash`.


#### `contracts/evm/src/messaging/signed/SafeQuorum.sol`

Library that verifies Safe 1.5.0 signature blobs against an authenticated owner source, reproducing `checkNSignatures` and nested `isValidSignature` without calling any Safe.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireQuorum(source, safe, dataHash, signatures, approvals)`<br>_internal view_ | Requires a valid quorum of a Safe over a data hash, including nested approvals. | ReceiverAuthority._requireVotes, SafeAuthority.requireQuorum; also tests | No |

Private helpers: `_requireNested`, `_requireSignatures`, `_signer`.


#### `contracts/evm/src/messaging/signed/SafeSignaturesUtils.sol`

Library of Safe 1.5.0 signature-blob parsing shared by the receiver's verifier and the source's evidence collection.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireLength(safe, signatures, threshold)`<br>_internal pure_ | Reverts if the blob is shorter than threshold-many 65-byte entries. | NestedApprovalCollector._walk, SafeQuorum._requireSignatures | No |
| `entry(safe, signatures, index)`<br>_internal pure_ | Reads r, s and v of one signature entry, rejecting `v = 1`. | NestedApprovalCollector._entry, SafeQuorum._signer | No |
| `recover(dataHash, r, s, v)`<br>_internal pure_ | Recovers a signer from a data hash and signature parts for `v` of 27/28 or 31/32. | SafeQuorum._signer; also tests | No |
| `extractContractSignature(safe, signatures, offset, threshold)`<br>_internal pure_ | Extracts the child's signature bytes for a contract-owner entry. | NestedApprovalCollector._entry, SafeQuorum._signer | No |
| `contractOwner(r)`<br>_internal pure_ | The child Safe a contract-owner entry names. | NestedApprovalCollector._entry, SafeQuorum._signer; also tests | No |
| `indexOfApproval(approvals, child, messageHash)`<br>_internal pure_ | Index of the approval for a child and message hash, or the array length if none. | NestedApprovalCollector._approval, SafeQuorum._requireNested; also tests | No |
| `nestedHash(parentHash, child, chainId)`<br>_internal pure_ | The child Safe's message hash for a parent's signed hash and chain id. | NestedApprovalCollector._nested, SafeQuorum._requireNested; also tests | No |
| `approvalHash(child, parentHash, approval, chainId)`<br>_internal pure_ | Checks that a transaction approves the parent hash and computes its child Safe transaction hash. | NestedApprovalCollector._nested, SafeQuorum._requireNested; also tests | No |


#### `contracts/evm/src/messaging/signed/SafeViewer.sol`

Library that decides whether a conduit owner gets signed mode at creation by reading its guard and live authority.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `signedAuthority(owner)`<br>_internal view_ | The owner's live authority records when its guard advertises `ICrossecuteGuard`, none otherwise; reverts if the graph does not derive. | TransceiverExtension.signedAuthority, LzOftConduitFactory.createTransmitter; also tests | No |

Private helpers: `isSigned`.


#### `contracts/evm/src/messaging/signed/SignedDispatchCalls.sol`

Library that reads a signed Safe transaction's target and calldata so the sending transmitter and the verifying receiver decode the same bytes alike.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireSourceCall(safeTx, target)`<br>_internal pure_ | Requires a CALL to the expected transmitter with zero Safe gas and gas price. | SignedReceiver._runMessage, SignedReceiver._runLeaf, SignedTransmitterLib.relay, SignedTransmitterLib._standalone | No |
| `sendMessageArgs(data)`<br>_internal pure_ | Checks the `sendMessage` selector and decodes recipient, payload and attributes. | SignedReceiver._runMessage, SignedTransmitterLib._standalone | No |
| `registeredRoot(safeTx)`<br>_internal pure_ | Checks a `registerRoot` call and returns the root it authorizes, refusing nonzero value. | SignedReceiver._runLeaf, SignedTransmitterLib.relay | No |
| `requireOpen(validAfter, deadline)`<br>_internal view_ | Requires the block time to be inside the inclusive validity window. | SignedReceiver._runLeaf | No |
| `requireDestination(destination, self)`<br>_internal view_ | Requires the destination to name this EVM chain and this receiver. | SignedReceiver._runMessage, SignedReceiver._runLeaf | No |


### `contracts/evm/src/messaging/signed/types`

#### `contracts/evm/src/messaging/signed/types/SafeAuthorityTypes.sol`

Struct definitions for a Safe authority graph: `SafeOwner` and `SafeAuthorityRecord`.

_Declares no functions._


#### `contracts/evm/src/messaging/signed/types/SignedDispatchTypes.sol`

Struct definitions for signed dispatch: `ExecutionLeaf`, `NestedSafeApproval`, `SafeTxEvidence` and `SignedBootstrap`.

_Declares no functions._


### `contracts/evm/src/messaging/transceiver`

#### `contracts/evm/src/messaging/transceiver/DivergentConduits.sol`

Abstract bases that derive and deploy conduits on chains whose CREATE2 differs from Ethereum's (zkSync Era in `ZkSyncConduits`, Tron in `TronConduits`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `__DivergentConduits_init(conduitBytecodeHash_)`<br>_DivergentConduits · internal_ | Stores the conduit bytecode hash the chain-specific formula needs. | DivergentTransceiver.__DivergentTransceiver_init | No |
| `_zkSyncConduit(conduitSalt)`<br>_ZkSyncConduits · internal view_ | Where this contract deploys a conduit for a salt on zkSync Era. | ZkSyncTransceiver._conduitAt, ZkSyncTransceiverExtension._conduitAt | No |
| `_zkSyncDeploy(conduitSalt)`<br>_ZkSyncConduits · internal_ | Deploys a conduit through zkSync's `ContractDeployer` system call. | ZkSyncTransceiver._deployConduit | No |
| `_tronConduit(conduitSalt)`<br>_TronConduits · internal view_ | Where this contract deploys a conduit for a salt on Tron. | TronTransceiver._conduitAt, TronTransceiverExtension._conduitAt | No |


#### `contracts/evm/src/messaging/transceiver/DivergentTransceiver.sol`

Combined transceiver bases for zkSync Era and Tron (and their extensions) that plug the chain's conduit derivation into `TransceiverBase` and always report receivers home.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `__DivergentTransceiver_init(c, conduitBytecodeHash_)`<br>_DivergentTransceiver · internal_ | Sets the derivation inputs first, then initializes the transceiver with addresses marked as diverging. | CcipZkSyncTransceiver.initialize, CcipTronTransceiver.initialize, HyperlaneZkSyncTransceiver.initialize, HyperlaneTronTransceiver.initialize, LzZkSyncTransceiver.initialize, LzTronTransceiver.initialize; also tests | No |
| `_conduitAt(conduitSalt)`<br>_ZkSyncTransceiver · internal view_ | Predicts a conduit address with zkSync's formula. Overrides or is overridden in: CcipZkSyncTransceiver, HyperlaneZkSyncTransceiver, LzZkSyncTransceiver, TransceiverCore. | TransceiverCore._predictConduit, CcipZkSyncTransceiver._conduitAt, HyperlaneZkSyncTransceiver._conduitAt, LzZkSyncTransceiver._conduitAt; also tests | No |
| `_deployConduit(salt)`<br>_ZkSyncTransceiver · internal_ | Deploys a conduit through the zkSync system call. Overrides or is overridden in: CcipZkSyncTransceiver, HyperlaneZkSyncTransceiver, LzZkSyncTransceiver, TransceiverBase. | TransceiverBase._createConduit, CcipZkSyncTransceiver._deployConduit, HyperlaneZkSyncTransceiver._deployConduit, LzZkSyncTransceiver._deployConduit; also tests | No |
| `_storeProxyInitCode()`<br>_ZkSyncTransceiver · internal_ | Stores no initcode, since EraVM cannot deploy raw initcode. Overrides or is overridden in: CcipZkSyncTransceiver, HyperlaneZkSyncTransceiver, LzZkSyncTransceiver, TransceiverBase. | TransceiverBase.constructor, CcipZkSyncTransceiver._storeProxyInitCode, HyperlaneZkSyncTransceiver._storeProxyInitCode, LzZkSyncTransceiver._storeProxyInitCode; also tests | No |
| `_conduitAt(conduitSalt)`<br>_TronTransceiver · internal view_ | Predicts a conduit address with Tron's formula. Overrides or is overridden in: CcipTronTransceiver, HyperlaneTronTransceiver, LzTronTransceiver, TransceiverCore. | TransceiverCore._predictConduit, CcipTronTransceiver._conduitAt, HyperlaneTronTransceiver._conduitAt, LzTronTransceiver._conduitAt; also tests | No |
| `_conduitAt(conduitSalt)`<br>_ZkSyncTransceiverExtension · internal view_ | Same zkSync prediction for the extension. Overrides or is overridden in: TransceiverCore. | TransceiverCore._predictConduit; also tests | No |
| `_conduitAt(conduitSalt)`<br>_TronTransceiverExtension · internal view_ | Same Tron prediction for the extension. Overrides or is overridden in: TransceiverCore. | TransceiverCore._predictConduit; also tests | No |


#### `contracts/evm/src/messaging/transceiver/IBootstrapAllowlist.sol`

Interface of the optional contract that decides which conduits a transceiver lets bootstrap.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `isAllowed(conduit)`<br>_external view_ | Whether the bootstrapping conduit (`msg.sender` of `bootstrap`) is allowed. | TransceiverBase._allowedConduit; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/messaging/transceiver/TransceiverBase.sol`

The per-chain, per-provider transceiver: creates transmitters and receivers for conduits, sends and accepts bootstraps and receiver reports, and forwards its other selectors to the extension by delegatecall.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Requires a deployed extension, stores it and writes `Proxy`'s initcode for conduit deployment. Overrides or is overridden in: CcipTransceiver, CcipTransceiverBase, CcipTronTransceiver, CcipZkSyncTransceiver, HyperlaneTransceiver, HyperlaneTransceiverBase. | TransceiverCore.constructor, CcipZkSyncTransceiver.constructor, CcipTronTransceiver.constructor, CcipTransceiverBase.constructor, CcipTransceiver.constructor, HyperlaneZkSyncTransceiver.constructor, HyperlaneTronTransceiver.constructor, HyperlaneTransceiverBase.constructor, HyperlaneTransceiver.constructor, LzZkSyncTransceiver.constructor, LzTronTransceiver.constructor, LzTransceiverBase.constructor (+4 more); also tests | No (constructor) |
| `_storeProxyInitCode()`<br>_internal_ | Writes `Proxy`'s initcode for `_deployConduit`; variants that deploy differently override it. Overrides or is overridden in: CcipZkSyncTransceiver, HyperlaneZkSyncTransceiver, LzZkSyncTransceiver, ZkSyncTransceiver. | TransceiverBase.constructor, CcipZkSyncTransceiver._storeProxyInitCode, HyperlaneZkSyncTransceiver._storeProxyInitCode, LzZkSyncTransceiver._storeProxyInitCode; also tests | No |
| `fallback`<br>_external payable_ | Delegatecalls any other selector to the extension against this contract's storage. | tests only | Yes (plain call) |
| `receive`<br>_external payable_ | Accepts the float that receiver reports are paid from. | tests only | Yes (plain call) |
| `__TransceiverBase_init(c)`<br>_internal_ | Initializer (first overload, Ethereum-style addresses) that configures the transceiver and grants gateways through the extension. | DivergentTransceiver.__DivergentTransceiver_init, CcipTransceiver.initialize, HyperlaneTransceiver.initialize, LzTransceiver.initialize, OpStackInteropTransceiver.initialize, OpStackTransceiver.initialize, WormholeTransceiver.initialize; also tests | No |
| `__TransceiverBase_init(c, addressesDiverge_)`<br>_internal_ | Initializer (first overload, Ethereum-style addresses) that configures the transceiver and grants gateways through the extension. | DivergentTransceiver.__DivergentTransceiver_init, CcipTransceiver.initialize, HyperlaneTransceiver.initialize, LzTransceiver.initialize, OpStackInteropTransceiver.initialize, OpStackTransceiver.initialize, WormholeTransceiver.initialize; also tests | No |
| `predictReceiver(chainKey, owner, salt)`<br>_public view_ | Where an owner/salt receiver sits on a chain that derives addresses with Ethereum's CREATE2. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `createTransmitter(salt)`<br>_external_ | Caller creates its own transmitter (owner is `msg.sender`), in signed mode when the caller is a Safe with a Crossecute guard. | SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `_deployConduit(salt)`<br>_internal_ | Deploys the proxy at a salt and returns where it landed. Overrides or is overridden in: CcipZkSyncTransceiver, HyperlaneZkSyncTransceiver, LzZkSyncTransceiver, ZkSyncTransceiver. | TransceiverBase._createConduit, CcipZkSyncTransceiver._deployConduit, HyperlaneZkSyncTransceiver._deployConduit, LzZkSyncTransceiver._deployConduit; also tests | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_internal view_ | Builds the initializer the conduit's logic is armed with, run by delegatecall during arming. Overrides or is overridden in: CcipTronTransceiver, CcipZkSyncTransceiver, HyperlaneTronTransceiver, HyperlaneZkSyncTransceiver, LzTransceiverBase, LzTronTransceiver. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer, CcipZkSyncTransceiver._conduitInitializer, CcipTronTransceiver._conduitInitializer, HyperlaneZkSyncTransceiver._conduitInitializer, HyperlaneTronTransceiver._conduitInitializer, LzZkSyncTransceiver._conduitInitializer, LzTronTransceiver._conduitInitializer, LzTransceiverBase._conduitInitializer, OpStackInteropTransceiver._conduitInitializer, OpStackTransceiver._conduitInitializer; also tests | No |
| `bootstrap(destinationChainKey, owner, salt, calls, attributes)`<br>_external payable_ | Conduit stands up a receiver on another chain and carries its payload (typed calls); callable only by the conduit that owner/salt resolves to. | SignedReceiver.initializeSigned, SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `bootstrapElements(destinationChainKey, owner, salt, elements, attributes)`<br>_external payable_ | Same for a destination whose calls are opaque elements. | tests only | Yes, anyone (state-changing) |
| `bootstrapSigned(destinationChainKey, owner, salt, body, attributes)`<br>_external payable_ | Bootstrap for a signed conduit carrying an encoded signed bootstrap. | SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `quoteBootstrapSigned(destinationChainKey, owner, salt, body, attributes)`<br>_external view_ | Prices a signed bootstrap. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `conduitBootstrap(bytes, address, bytes32, bytes)`<br>_external pure_ | Returns empty: this transceiver sends a conduit's bootstrap itself through `bootstrap`. | tests only | Yes, anyone (read-only) |
| `quoteBootstrap(destinationChainKey, owner, salt, calls, attributes)`<br>_external view_ | Prices a typed-calls bootstrap without the caller check. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `quoteBootstrapElements(destinationChainKey, owner, salt, elements, attributes)`<br>_external view_ | Prices an elements bootstrap. | tests only | Yes, anyone (read-only) |
| `_onInbound(route, sender, message)`<br>_internal_ | Entry funnel every binding routes an arriving message into; authenticates origin before decoding. | ProviderTransceiver._onProviderInbound, OpStackInteropTransceiver.receiveOpStackMessage, OpStackTransceiver.receiveOpStackMessage; also tests | No |
| `isLive(chainKey)`<br>_public view_ | Whether the registry has marked this provider's transceiver live on a chain. | TransceiverBase._requireBootstrappable; also tests | Yes, anyone (read-only) |
| `reportsReceiver(chainKey)`<br>_public view_ | Whether a chain reports its receiver address back instead of this transceiver deriving it. | TransceiverBase._requireBootstrappable; also tests | Yes, anyone (read-only) |

Private helpers: `_allowedConduit`, `_authenticateOrigin`, `_bootstrapCaller`, `_bootstrapEnvelope`, `_bootstrapInbound`, `_bootstrapSendValue`, `_conduitImplementation`, `_conduitUnder`, `_createConduit`, `_evmTransmitter`, `_handleInbound`, `_isSignedConduit`, `_onDestinationReceiver`, `_quoteBootstrap`, `_reportReceiver`, `_requireBootstrappable`, `_sendBootstrap`, `_signedBootstrapInbound`, `_transmitterWord`.


#### `contracts/evm/src/messaging/transceiver/TransceiverCore.sol`

Abstract state, events and shared logic of a transceiver's two contracts (`TransceiverBase` and `TransceiverExtension`), plus `ITransmitterInit` and `IConduitReceiverReport`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `initialize(owner, transceiver, salt)`<br>_ITransmitterInit · external_ | Initializer the transmitter logic exposes for a transceiver to arm a conduit with. | TransceiverBase._conduitInitializer; also tests | Yes via interface (state-changing) |
| `onDestinationReceiverReported(chainKey, receiver)`<br>_IConduitReceiverReport · external_ | What a transceiver tells a conduit after a destination reports its receiver. | TransceiverBase._onDestinationReceiver; also tests | Yes via interface (state-changing) |
| `constructor`<br>_TransceiverCore · constructor_ | Records this chain's own key. Overrides or is overridden in: CcipTransceiver, CcipTransceiverBase, CcipTronTransceiver, CcipZkSyncTransceiver, HyperlaneTransceiver, HyperlaneTransceiverBase. | TransceiverBase.constructor, TransceiverExtension.constructor, CcipZkSyncTransceiver.constructor, CcipTronTransceiver.constructor, CcipTransceiverBase.constructor, CcipTransceiver.constructor, HyperlaneZkSyncTransceiver.constructor, HyperlaneTronTransceiver.constructor, HyperlaneTransceiverBase.constructor, HyperlaneTransceiver.constructor, LzZkSyncTransceiver.constructor, LzTronTransceiver.constructor (+5 more); also tests | No (constructor) |
| `_conduitSalt(owner, salt, homeChainKey)`<br>_TransceiverCore · internal pure_ | The salt an owner's conduit deploys at on every chain, from owner, salt and home chain key. | TransceiverBase._conduitUnder, TransceiverBase._createConduit, TransceiverCore._predictConduit, TransceiverExtension.conduitSalt; also tests | No |
| `_predictConduit(owner, salt, homeChainKey)`<br>_TransceiverCore · internal view_ | Where an owner's conduit lives on this chain before it exists. | TransceiverBase.__TransceiverBase_init, TransceiverBase._createConduit, TransceiverCore._localConduit, TransceiverExtension.initializeBase, TransceiverExtension.predictConduit; also tests | No |
| `_conduitAt(conduitSalt)`<br>_TransceiverCore · internal view_ | Where the conduit under a salt lands on this chain; divergent chains override. Overrides or is overridden in: CcipTronTransceiver, CcipZkSyncTransceiver, HyperlaneTronTransceiver, HyperlaneZkSyncTransceiver, LzTronTransceiver, LzZkSyncTransceiver. | TransceiverCore._predictConduit, CcipZkSyncTransceiver._conduitAt, CcipTronTransceiver._conduitAt, HyperlaneZkSyncTransceiver._conduitAt, HyperlaneTronTransceiver._conduitAt, LzZkSyncTransceiver._conduitAt, LzTronTransceiver._conduitAt; also tests | No |
| `_localConduit(owner, salt)`<br>_TransceiverCore · internal view_ | The owner/salt conduit homed on this chain, its transmitter here. | TransceiverBase._allowedConduit, TransceiverBase._onDestinationReceiver, TransceiverExtension.predictTransmitter | No |
| `_reportPayload(owner, salt, receiver)`<br>_TransceiverCore · internal view_ | The exact receiver-report bytes for an owner, salt and receiver. | TransceiverBase._reportReceiver, TransceiverExtension.reportPayload | No |
| `_counterpartOn(chainKey)`<br>_TransceiverCore · internal view_ | Counterpart lookup that applies the registry's grade and suspension. Overrides or is overridden in: OutboundBase. | OutboundBase.counterpartOn, OutboundBase._requireRoutable, OutboundBase._recipientOn, TransceiverBase._authenticateOrigin, TransceiverCore._evmCounterpartOn, TransceiverExtension.initializeBase; also tests | No |
| `_evmCounterpartOn(chainKey)`<br>_TransceiverCore · internal view_ | The counterpart on a chain as an EVM address, refusing other widths. | TransceiverBase.predictReceiver, TransceiverBase._bootstrapInbound, TransceiverBase._signedBootstrapInbound, LzTransceiverBase._initGovernorHomePeer, LzTransceiverBase.setPeer | No |
| `_parityAddress(chainKey)`<br>_TransceiverCore · internal view_ | Where this provider's transceiver sits on a `Predetermined` chain, from the registry's prediction. | TransceiverCore._counterpartOn, TransceiverExtension._recordCounterpart; also tests | No |
| `_refundTo()`<br>_TransceiverCore · internal view_ | Refunds an overpaid fee to whoever paid it (the float for reports). Overrides or is overridden in: OutboundBase. | HyperlaneTransceiverBase._sendMessage, HyperlaneTransceiverBase._quoteMessage, LzTransceiverBase._sendMessage, WormholeTransceiver._sendMessage; also tests | No |
| `_defaultGas(payload)`<br>_TransceiverCore · internal pure_ | Default destination gas chosen by the message kind; reports have fixed gas. Overrides or is overridden in: OutboundBase. | CcipTransceiverBase._sendMessage, CcipTransceiverBase._quoteMessage, HyperlaneTransceiverBase._sendMessage, HyperlaneTransceiverBase._quoteMessage, LzTransceiverBase._sendMessage, LzTransceiverBase._quoteMessage, OpStackTransceiver._sendMessage, OpStackTransceiver._quoteMessage, WormholeTransceiver._sendMessage, WormholeTransceiver._quoteMessage; also tests | No |


#### `contracts/evm/src/messaging/transceiver/TransceiverExtension.sol`

The transceiver's initialization, owner configuration, float withdrawal and views, kept off `TransceiverBase` for size and reached only by delegatecall from the transceiver's fallback.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Disables initializers on the extension itself. Overrides or is overridden in: TransceiverCore. | TransceiverCore.constructor; also tests | No (constructor) |
| `initializeBase(c, addressesDiverge_)`<br>_external_ | Configures the transceiver and grants gateways; accepts only the transceiver's self-call during initialization. | TransceiverBase.__TransceiverBase_init; also tests | Yes, gated by onlyInitializing (state-changing) |
| `setRoute(chainKey, route)`<br>_public_ | Owner teaches the transceiver how a chain is named (write-once). | tests only | Yes, gated by onlyOwner (state-changing) |
| `setRouting(chainRegistry_, messageProvider_, minCounterpartProvenance_)`<br>_external_ | Owner sets the registry, provider id and provenance bar (registry and id write-once). | tests only | Yes, gated by onlyOwner (state-changing) |
| `setCounterpart(chainKey, interop)`<br>_external_ | Owner records where this provider's transceiver sits on another chain. | tests only | Yes, gated by onlyOwner (state-changing) |
| `resolveCounterpart(chainKey, paramsCommitment)`<br>_external_ | Owner records the counterpart by recomputing it from the registry's deriver and inputs, bound by a params commitment. | tests only | Yes, gated by onlyOwner (state-changing) |
| `setBootstrapAllowlist(allowlist)`<br>_external_ | Owner names the contract that decides which conduits may bootstrap (zero allows all). | tests only | Yes, gated by onlyOwner (state-changing) |
| `setOperator(operator_)`<br>_external_ | Owner sets the operator allowed to set bootstrap fees. | tests only | Yes, gated by onlyOwner (state-changing) |
| `setBootstrapFee(chainKey, fee)`<br>_external_ | Owner or operator sets the cost of standing a conduit up on a chain. | tests only | Yes, but the body gates it (caller vs _operator, caller vs owner()) (state-changing) |
| `withdraw(amount)`<br>_external_ | Sends part of the float to the treasury, at the treasury's call. | tests only | Yes, but the body gates it (caller vs to) (state-changing) |
| `conduitSalt(owner, salt, homeChainKey)`<br>_external pure_ | External form of the conduit salt for owner, salt and home chain. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `predictConduit(owner, salt, homeChainKey)`<br>_external view_ | Where an owner's conduit lives on this chain before it exists. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `signedAuthority(owner)`<br>_external view_ | The owner's live authority records, or empty if its guard is not a Crossecute guard. | TransceiverBase.createTransmitter, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `predictTransmitter(owner, salt)`<br>_external view_ | Where an owner/salt transmitter lives before it exists. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `reportPayload(owner, salt, receiver)`<br>_external view_ | The exact report bytes for an owner, salt and receiver, so the cost can be quoted. | tests only | Yes, anyone (read-only) |
| `transmitterImplementation()`<br>_external view_ | The transmitter implementation address. | tests only | Yes, anyone (read-only) |
| `receiverImplementation()`<br>_external view_ | The receiver implementation address. | tests only | Yes, anyone (read-only) |
| `addressesDiverge()`<br>_external view_ | Whether this chain's conduit addresses diverge from Ethereum's CREATE2. | tests only | Yes, anyone (read-only) |
| `chainRegistry()`<br>_external view_ | The registry this transceiver reads. | tests only | Yes, anyone (read-only) |
| `messageProvider()`<br>_external view_ | The provider id this transceiver serves. | tests only | Yes, anyone (read-only) |
| `minCounterpartProvenance()`<br>_external view_ | The minimum provenance grade a counterpart must have. | none found | Yes, anyone (read-only) |
| `bootstrapFee(chainKey)`<br>_external view_ | The bootstrap fee for a chain. | tests only | Yes, anyone (read-only) |
| `operator()`<br>_external view_ | The fee operator. | tests only | Yes, anyone (read-only) |
| `bootstrapAllowlist()`<br>_external view_ | The bootstrap allowlist contract. | tests only | Yes, anyone (read-only) |
| `treasury()`<br>_external view_ | The treasury that receives fees. | tests only | Yes, anyone (read-only) |
| `_sendMessage(bytes, bytes, bytes[], uint256)`<br>_internal pure_ | Reverts: the extension never sends. Overrides or is overridden in: OutboundBase. | tests only | No |
| `_quoteMessage(bytes, bytes, bytes[])`<br>_internal pure_ | Reverts `SendsNothing`. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage; also tests | No |

Private helpers: `_recordCounterpart`, `_setRouting`.


### `contracts/evm/src/protocols`

#### `contracts/evm/src/protocols/ProviderAddress.sol`

Library that narrows a provider's address forms to an EVM address, refusing instead of truncating or padding anything that is not one.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `evmRecipient(recipient)`<br>_internal pure_ | Reads the recipient as an EVM address for providers that deliver to one (CCIP, Hyperlane, Wormhole, OP Stack). | CcipMessage.build, HyperlaneMessage.recipientOf, OpStackInteropMessage._requireSend, OpStackMessage._requireRecipient, WormholeMessage.recipientOf | No |
| `evmSender(sender)`<br>_internal pure_ | Reads a provider-reported 32-byte sender as an EVM address, refusing nonzero high bytes. | HyperlaneReceiver.handle, HyperlaneTransceiverBase.handle, LzOftConduitFactory._authenticateBootstrap, LzOftReceiver.lzCompose, LzReceiver._lzReceive, LzTransceiverBase._lzReceive, WormholeMessage.consumeVaa | No |


#### `contracts/evm/src/protocols/ProviderAttribute.sol`

Library that parses the single selector-prefixed attribute each native binding accepts and refuses any other, as ERC-7786 requires.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `body(attributes, selector, bodyLength)`<br>_internal pure_ | The bytes after a selector in the single attribute, or "not present", requiring an exact length when given. | CcipMessage.extraArgsFrom, LzMessage._optionsOr, WormholeMessage.publishOnly, WormholeMessage.executionFrom; also tests | No |
| `uintValue(attributes, selector, max, defaultValue)`<br>_internal pure_ | The bounded `uint256` carried in a single selector attribute, or a default when none was given. | HyperlaneMessage.gasLimitFrom, OpStackMessage.minGasLimitFrom; also tests | No |
| `none(attributes)`<br>_internal pure_ | For a binding with no attributes: refuses the first one given. | OpStackInteropMessage._requireSend; also tests | No |

Private helpers: `_selectorOf`.


#### `contracts/evm/src/protocols/ProviderChainId.sol`

Interface (`IProviderIdTable`) and abstract contract that map the protocol's chain key to a provider's native chain id (LayerZero eid, CCIP selector, Hyperlane domain) in both directions.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `providerIdFor(chainKey)`<br>_IProviderIdTable · external view_ | The provider's id for a chain key, read by a transmitter from its transceiver. Implemented in: ProviderChainId. | ProviderChainId.providerIdOf; also tests | Yes via interface (read-only) |
| `_setProviderId(chainKey, providerId)`<br>_ProviderChainId · internal_ | Records a provider id for a chain key, write-once and ungated (the caller applies authority). | ProviderTransceiver._initGovernorHomeId, CcipTransceiverBase.setProviderId, HyperlaneTransceiverBase.setProviderId, LzTransceiverBase.setProviderId, OpStackTransceiver.setProviderId, WormholeTransceiver.setProviderId; also tests | No |
| `_providerIdFor(chainKey)`<br>_ProviderChainId · internal view_ | The provider's id for a chain key; reverts when unset. | ProviderChainId.providerIdFor, ProviderChainId._providerIdOf, ProviderTransceiver._conduitInitializer, LzTransceiverBase._conduitInitializer, OpStackTransceiver.messengerFor | No |
| `_chainKeyOfProvider(providerId)`<br>_ProviderChainId · internal view_ | The chain key a provider id refers to (inbound direction); reverts when unset. | ProviderTransceiver._onProviderInbound, CcipTransceiverBase.setCcipV3Lane, LzTransceiverBase.setPeer, OpStackTransceiver.receiveOpStackMessage; also tests | No |
| `hasProviderId(chainKey)`<br>_ProviderChainId · public view_ | Whether a provider id is recorded for a chain key. | tests only | Yes, anyone (read-only) |
| `providerIdFor(chainKey)`<br>_ProviderChainId · external view_ | External read of the provider id for a chain key; reverts `NoProviderIdFor` when unset. Declared in: IProviderIdTable. | ProviderChainId.providerIdOf; also tests | Yes, anyone (read-only) |
| `_providerIdOf(recipient)`<br>_ProviderChainId · internal view_ | The provider id for the chain a recipient is on. | CcipTransceiverBase._sendMessage, CcipTransceiverBase._quoteMessage, HyperlaneTransceiverBase._sendMessage, HyperlaneTransceiverBase._quoteMessage, LzTransceiverBase._sendMessage, LzTransceiverBase._quoteMessage, OpStackTransceiver._sendMessage, OpStackTransceiver._quoteMessage, WormholeTransceiver._route | No |
| `providerIdOf(transceiver, recipient)`<br>_internal view_ | Free function that reads a recipient's provider id from a given transceiver's table. | CcipTransmitter._sendMessage, CcipTransmitter._quoteMessage, HyperlaneTransmitter._sendMessage, HyperlaneTransmitter._quoteMessage, LzTransmitter._sendMessage, LzTransmitter._quoteMessage, OpStackTransmitter._sendMessage, OpStackTransmitter._quoteMessage, WormholeTransmitter._route; also tests | No |


#### `contracts/evm/src/protocols/ProviderReceiver.sol`

Abstract signed receiver whose only provider setup is naming the provider's delivery contract as its gateway.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Passes the source-authority guard and MultiSendCallOnly pins to `SignedReceiver`. Overrides or is overridden in: CcipReceiver, HyperlaneReceiver, OpStackInteropReceiver, SignedReceiver, WormholeReceiver. | SignedReceiver.constructor, CcipReceiver.constructor, HyperlaneReceiver.constructor, OpStackInteropReceiver.constructor, WormholeReceiver.constructor; also tests | No (constructor) |
| `initialize(sourceTransmitter_, homeOrigin_, calls)`<br>_external_ | Grants the provider gateway role (only possible while initializing) and then binds and runs the payload. Declared in: IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, OpStackInteropTransceiver._conduitInitializer; also tests | Yes, gated by initializer (state-changing) |
| `_providerGateway()`<br>_internal view_ | Hook returning the provider contract that delivers to this receiver. Overrides or is overridden in: CcipReceiver, HyperlaneReceiver, OpStackInteropReceiver, WormholeReceiver. | ProviderReceiver.initialize | No |


#### `contracts/evm/src/protocols/ProviderTransceiver.sol`

Abstract transceiver base shared by native bindings that have a provider chain id: the id table plus mapping a delivery's reported origin back to a route.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `__ProviderTransceiver_init(providerGateway)`<br>_internal_ | Names the provider's delivery contract as a gateway for bindings whose entry point checks the gateway role. | CcipTransceiverBase.__CcipTransceiver_init, HyperlaneTransceiverBase.__HyperlaneTransceiver_init, WormholeTransceiver.__WormholeTransceiver_init | No |
| `_initGovernorHomeId(governorHome, providerId)`<br>_internal_ | Names the provider's id for the governor's home so the bootstrap that creates the transceiver's owner can be accepted. | CcipTransceiverBase.__CcipTransceiver_init, HyperlaneTransceiverBase.__HyperlaneTransceiver_init, LzTransceiverBase.__LzTransceiver_init, OpStackTransceiver.initialize, WormholeTransceiver.__WormholeTransceiver_init | No |
| `_onProviderInbound(providerId, sender, message)`<br>_internal_ | Maps the provider's reported origin id to a route and funnels the message into `_onInbound`. | CcipTransceiverBase.ccipReceive, HyperlaneTransceiverBase.handle, LzTransceiverBase._lzReceive, WormholeTransceiver.executeVAAv1 | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_internal view_ | Builds the receiver initializer naming its home by the provider's id for it. Overrides or is overridden in: CcipTronTransceiver, CcipZkSyncTransceiver, HyperlaneTronTransceiver, HyperlaneZkSyncTransceiver, LzTransceiverBase, LzTronTransceiver. | TransceiverBase._createConduit, CcipZkSyncTransceiver._conduitInitializer, CcipTronTransceiver._conduitInitializer, HyperlaneZkSyncTransceiver._conduitInitializer, HyperlaneTronTransceiver._conduitInitializer, LzZkSyncTransceiver._conduitInitializer, LzTronTransceiver._conduitInitializer, LzTransceiverBase._conduitInitializer, OpStackTransceiver._conduitInitializer; also tests | No |


### `contracts/evm/src/protocols/ccip`

#### `contracts/evm/src/protocols/ccip/CcipConfig.sol`

Library and interface for CCIP configuration state: the namespaced storage layout (inbound policies and enabled V3 lanes), policy keys and verifier-list validation.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireCCVs(ccvs)`<br>_CcipConfig · internal pure_ | Reverts `InvalidCcipVerifiers` if a verifier list is over 255 long or has duplicates. | CcipMessage.extraArgsFrom, CcipPolicy.setCcipPolicy | No |
| `layout()`<br>_CcipConfig · internal pure_ | Returns the namespaced storage struct of CCIP config. | CcipPolicy.setCcipPolicy, CcipPolicy.getCCVsAndFinalityConfig, CcipTransceiverBase.setCcipV3Lane, CcipTransceiverBase.ccipV3LaneEnabled | No |
| `policyKey(source, sender)`<br>_CcipConfig · internal pure_ | Hash key of a (source selector, sender) inbound policy. | CcipPolicy.setCcipPolicy, CcipPolicy.getCCVsAndFinalityConfig | No |
| `ccipV3LaneEnabled(destination)`<br>_ICcipLaneConfig · external view_ | Whether an outbound lane to a destination selector uses CCIP V3. Implemented in: CcipTransceiverBase. | CcipMessage.buildOnLane; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/protocols/ccip/CcipDivergentTransceiver.sol`

CCIP transceivers for zkSync Era and Tron, which only add the chain's address derivation and deployment to `CcipTransceiverBase`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_CcipZkSyncTransceiver · constructor_ | Passes the CCIP router and extension to the base. Overrides or is overridden in: CcipTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, CcipTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeSelector, conduitBytecodeHash_)`<br>_CcipZkSyncTransceiver · external_ | Initializes with config, governor-home CCIP selector and the zksolc `Proxy` bytecode hash. | tests only | Yes, gated by initializer (state-changing) |
| `_conduitAt(conduitSalt)`<br>_CcipZkSyncTransceiver · internal view_ | Resolves the inheritance diamond to the zkSync conduit prediction. Overrides or is overridden in: TransceiverCore, ZkSyncTransceiver. | TransceiverCore._predictConduit; also tests | No |
| `_deployConduit(salt)`<br>_CcipZkSyncTransceiver · internal_ | Resolves the diamond to zkSync's system-call deployment. Overrides or is overridden in: TransceiverBase, ZkSyncTransceiver. | TransceiverBase._createConduit; also tests | No |
| `_storeProxyInitCode()`<br>_CcipZkSyncTransceiver · internal_ | Resolves the diamond to the zkSync no-store variant. Overrides or is overridden in: TransceiverBase, ZkSyncTransceiver. | TransceiverBase.constructor; also tests | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_CcipZkSyncTransceiver · internal view_ | Resolves the diamond to the provider transceiver's initializer. Overrides or is overridden in: ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer; also tests | No |
| `supportsInterface(interfaceId)`<br>_CcipZkSyncTransceiver · public view_ | Resolves the diamond to the CCIP transceiver's ERC-165 answer. Overrides or is overridden in: CcipTransceiverBase. | CcipReceiver.supportsInterface, CcipTransceiverBase.supportsInterface; also tests | Yes, anyone (read-only) |
| `constructor`<br>_CcipTronTransceiver · constructor_ | Passes the CCIP router and extension to the base. Overrides or is overridden in: CcipTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, CcipTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeSelector, conduitBytecodeHash_)`<br>_CcipTronTransceiver · external_ | Initializes with config, governor-home CCIP selector and Tron-solc's `Proxy` initcode hash. | tests only | Yes, gated by initializer (state-changing) |
| `_conduitAt(conduitSalt)`<br>_CcipTronTransceiver · internal view_ | Resolves the diamond to the Tron conduit prediction. Overrides or is overridden in: TransceiverCore, TronTransceiver. | TransceiverCore._predictConduit; also tests | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_CcipTronTransceiver · internal view_ | Resolves the diamond to the provider transceiver's initializer. Overrides or is overridden in: ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer; also tests | No |
| `supportsInterface(interfaceId)`<br>_CcipTronTransceiver · public view_ | Resolves the diamond to the CCIP transceiver's ERC-165 answer. Overrides or is overridden in: CcipTransceiverBase. | CcipReceiver.supportsInterface, CcipTransceiverBase.supportsInterface; also tests | Yes, anyone (read-only) |


#### `contracts/evm/src/protocols/ccip/CcipMessage.sol`

Linked library that builds the CCIP `EVM2AnyMessage`, sends and quotes through the router for every CCIP sender, and narrows delivered senders.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `sender(encodedSender)`<br>_internal pure_ | The EVM sender of a delivered message, refusing wider values. | CcipPolicy.setCcipPolicy, CcipReceiver._ccipReceive, CcipTransceiverBase.ccipReceive; also tests | No |
| `send(router, selector, recipient, payload, attributes, value, defaultGas, laneConfig)`<br>_public_ | Builds the CCIP message for a lane and calls the router's `ccipSend` with the native fee. | CcipTransceiverBase._sendMessage, CcipTransmitter._sendMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `quote(router, selector, recipient, payload, attributes, defaultGas, laneConfig)`<br>_public view_ | Builds the same message and returns the router's `getFee`. | CcipTransceiverBase._quoteMessage, CcipTransmitter._quoteMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `extraArgsFrom(attributes, defaultGas)`<br>_internal pure_ | Builds CCIP extra args (gas limit and out-of-order flag) from the single legacy attribute or the default gas. | CcipMessage.build | No |

Private helpers: `build`, `buildOnLane`.


#### `contracts/evm/src/protocols/ccip/CcipPolicy.sol`

Abstract inbound security policy per (source selector, sender): required and optional verifiers, threshold and allowed finality.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `setCcipPolicy(source, sender, policy)`<br>_external_ | Sets the inbound policy for a source and sender after the contract's authorization check. | tests only | Yes, anyone (state-changing) |
| `getCCVsAndFinalityConfig(source, sender)`<br>_public view_ | Returns the stored verifiers, threshold and finality for a source and sender (read by CCIP). Overrides or is overridden in: CcipReceiver, CcipTransceiverBase. | CcipReceiver.getCCVsAndFinalityConfig, CcipTransceiverBase.getCCVsAndFinalityConfig; also tests | Yes, anyone (read-only) |
| `_authorizeCcipPolicyChange(source, sender)`<br>_internal view_ | Hook that reverts unless the caller may set a policy for the source and sender. Overrides or is overridden in: CcipReceiver, CcipTransceiverBase. | CcipPolicy.setCcipPolicy | No |


#### `contracts/evm/src/protocols/ccip/CcipReceiver.sol`

Per-user CCIP conduit on a non-home chain that receives deliveries from the CCIP router.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Sets the guard pins and checks and stores the router. Overrides or is overridden in: ProviderReceiver, SignedReceiver. | SignedReceiver.constructor, ProviderReceiver.constructor; also tests | No (constructor) |
| `router()`<br>_public view_ | The CCIP router address. | tests only | Yes, anyone (read-only) |
| `_providerGateway()`<br>_internal view_ | Returns the router as the delivering gateway. Overrides or is overridden in: ProviderReceiver. | ProviderReceiver.initialize | No |
| `_authorizeCcipPolicyChange(source, sender)`<br>_internal view_ | Authorizes policy changes only as a self-call delivered under the current policy. Overrides or is overridden in: CcipPolicy. | CcipPolicy.setCcipPolicy | No |
| `getCCVsAndFinalityConfig(source, sender)`<br>_public view_ | Returns the inbound policy through `CcipPolicy`. Overrides or is overridden in: CcipPolicy. | CcipTransceiverBase.getCCVsAndFinalityConfig; also tests | Yes, anyone (read-only) |
| `supportsInterface(interfaceId)`<br>_public view_ | ERC-165 for CCIP receiver and the enumerable roles. Overrides or is overridden in: RolesEnumerable. | RolesEnumerable.supportsInterface; also tests | Yes, anyone (read-only) |

Private helpers: `_ccipReceive`, `_checkedRouter`.


#### `contracts/evm/src/protocols/ccip/CcipTransceiver.sol`

CCIP on `TransceiverBase`, shared by the standard EVM, zkSync and Tron variants: sends bootstraps and reports through the router and accepts deliveries through `ccipReceive`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_CcipTransceiverBase · constructor_ | Stores the router (nonzero) and the extension. Overrides or is overridden in: CcipTransceiver, CcipTronTransceiver, CcipZkSyncTransceiver, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, CcipZkSyncTransceiver.constructor, CcipTronTransceiver.constructor, CcipTransceiver.constructor; also tests | No (constructor) |
| `__CcipTransceiver_init(c, governorHomeSelector)`<br>_CcipTransceiverBase · internal_ | Initializer that sets the governor-home CCIP selector. | CcipZkSyncTransceiver.initialize, CcipTronTransceiver.initialize, CcipTransceiver.initialize | No |
| `setProviderId(chainKey, selector)`<br>_CcipTransceiverBase · external_ | Owner maps a chain key to its CCIP selector (write-once-if-unset). | tests only | Yes, gated by onlyOwner (state-changing) |
| `setCcipV3Lane(destination, enabled, evidenceHash)`<br>_CcipTransceiverBase · external_ | Owner enables a CCIP V3 outbound lane with an evidence hash of off-chain version checks. | tests only | Yes, gated by onlyOwner (state-changing) |
| `ccipV3LaneEnabled(destination)`<br>_CcipTransceiverBase · external view_ | Whether the lane to a destination selector uses V3. Declared in: ICcipLaneConfig. | CcipMessage.buildOnLane; also tests | Yes, anyone (read-only) |
| `_authorizeCcipPolicyChange(uint64, address)`<br>_CcipTransceiverBase · internal view_ | Authorizes policy changes by the owner. Overrides or is overridden in: CcipPolicy. | CcipPolicy.setCcipPolicy | No |
| `getCCVsAndFinalityConfig(source, sender)`<br>_CcipTransceiverBase · public view_ | Returns the inbound policy through `CcipPolicy`. Overrides or is overridden in: CcipPolicy. | CcipReceiver.getCCVsAndFinalityConfig; also tests | Yes, anyone (read-only) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_CcipTransceiverBase · internal_ | Sends through `ccipSend` with the transceiver's float or value. Overrides or is overridden in: OutboundBase. | TransceiverBase._sendBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_CcipTransceiverBase · internal view_ | Quotes via the router for the recipient's selector and default gas. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `ccipReceive(message)`<br>_CcipTransceiverBase · external_ | CCIP router delivers a message; the base authenticates the origin and handles it. | tests only | Yes, gated by onlyRole(GATEWAY_ROLE) (state-changing) |
| `supportsInterface(interfaceId)`<br>_CcipTransceiverBase · public view_ | Declares support for `IAny2EVMMessageReceiver` and ERC-165 so the off-ramp delivers. Overrides or is overridden in: CcipTronTransceiver, CcipZkSyncTransceiver. | CcipZkSyncTransceiver.supportsInterface, CcipTronTransceiver.supportsInterface, CcipReceiver.supportsInterface; also tests | Yes, anyone (read-only) |
| `constructor`<br>_CcipTransceiver · constructor_ | Passes the router and extension to the base. Overrides or is overridden in: CcipTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, CcipTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeSelector)`<br>_CcipTransceiver · external_ | Initializes the CCIP settings and then the transceiver base. | tests only | Yes, gated by initializer (state-changing) |


#### `contracts/evm/src/protocols/ccip/CcipTransmitter.sol`

Per-user sender-only CCIP transmitter created by `TransceiverBase.createTransmitter`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Stores the router (nonzero). | tests only | No (constructor) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Sends the payload through CCIP to the recipient's selector, paying in native currency. Overrides or is overridden in: OutboundBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Quotes the CCIP fee using the transceiver's selector table. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap; also tests | No |
| `supportsAttribute(selector)`<br>_external pure_ | Accepts the CCIP extra-args and V3 extra-args attributes. Declared in: IERC7786GatewaySource. | tests only | Yes, anyone (read-only) |


### `contracts/evm/src/protocols/hyperlane`

#### `contracts/evm/src/protocols/hyperlane/HyperlaneDivergentTransceiver.sol`

Hyperlane transceivers for zkSync Era and Tron, which only add the chain's address derivation and deployment to `HyperlaneTransceiverBase`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_HyperlaneZkSyncTransceiver · constructor_ | Passes the Hyperlane mailbox and extension to the base. Overrides or is overridden in: HyperlaneTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, HyperlaneTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeDomain, conduitBytecodeHash_)`<br>_HyperlaneZkSyncTransceiver · external_ | Initializes with config, governor-home Hyperlane domain and the zksolc `Proxy` bytecode hash. | tests only | Yes, gated by initializer (state-changing) |
| `_conduitAt(conduitSalt)`<br>_HyperlaneZkSyncTransceiver · internal view_ | Resolves the inheritance diamond to the zkSync conduit prediction. Overrides or is overridden in: TransceiverCore, ZkSyncTransceiver. | TransceiverCore._predictConduit; also tests | No |
| `_deployConduit(salt)`<br>_HyperlaneZkSyncTransceiver · internal_ | Resolves the diamond to zkSync's system-call deployment. Overrides or is overridden in: TransceiverBase, ZkSyncTransceiver. | TransceiverBase._createConduit; also tests | No |
| `_storeProxyInitCode()`<br>_HyperlaneZkSyncTransceiver · internal_ | Resolves the diamond to the zkSync no-store variant. Overrides or is overridden in: TransceiverBase, ZkSyncTransceiver. | TransceiverBase.constructor; also tests | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_HyperlaneZkSyncTransceiver · internal view_ | Resolves the diamond to the provider transceiver's initializer. Overrides or is overridden in: ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer; also tests | No |
| `constructor`<br>_HyperlaneTronTransceiver · constructor_ | Passes the mailbox and extension to the base. Overrides or is overridden in: HyperlaneTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, HyperlaneTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeDomain, conduitBytecodeHash_)`<br>_HyperlaneTronTransceiver · external_ | Initializes with config, governor-home domain and Tron-solc's `Proxy` initcode hash. | tests only | Yes, gated by initializer (state-changing) |
| `_conduitAt(conduitSalt)`<br>_HyperlaneTronTransceiver · internal view_ | Resolves the diamond to the Tron conduit prediction. Overrides or is overridden in: TransceiverCore, TronTransceiver. | TransceiverCore._predictConduit; also tests | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_HyperlaneTronTransceiver · internal view_ | Resolves the diamond to the provider transceiver's initializer. Overrides or is overridden in: ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer; also tests | No |


#### `contracts/evm/src/protocols/hyperlane/HyperlaneMessage.sol`

Library for Hyperlane recipient narrowing, hook metadata and the `dispatch` and `quoteDispatch` calls shared by every Hyperlane sender.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `dispatch(mailbox, domain, recipient, payload, attributes, value, refundTo, defaultGas)`<br>_internal_ | Dispatches a message through the mailbox with hook metadata and returns zero as the "sent" id. | HyperlaneTransceiverBase._sendMessage, HyperlaneTransmitter._sendMessage; also tests | No |
| `quote(mailbox, domain, recipient, payload, attributes, refundTo, defaultGas)`<br>_internal view_ | Quotes the mailbox's dispatch fee and refuses a zero quote (domain not routed). | HyperlaneMessage.dispatch, HyperlaneTransceiverBase._quoteMessage, HyperlaneTransmitter._quoteMessage; also tests | No |

Private helpers: `gasLimitFrom`, `hookMetadata`, `recipientOf`.


#### `contracts/evm/src/protocols/hyperlane/HyperlaneReceiver.sol`

Per-user Hyperlane conduit on a non-home chain that implements `IMessageRecipient.handle` behind the gateway role.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Sets the guard pins and stores the mailbox (nonzero). Overrides or is overridden in: ProviderReceiver, SignedReceiver. | SignedReceiver.constructor, ProviderReceiver.constructor; also tests | No (constructor) |
| `_providerGateway()`<br>_internal view_ | Returns the mailbox as the delivering gateway. Overrides or is overridden in: ProviderReceiver. | ProviderReceiver.initialize | No |
| `handle(origin, sender, message)`<br>_external payable_ | Mailbox delivers a message; checks origin and sender through `_onMessageFrom`. | tests only | Yes, gated by onlyRole(GATEWAY_ROLE) (state-changing) |


#### `contracts/evm/src/protocols/hyperlane/HyperlaneTransceiver.sol`

Hyperlane on `TransceiverBase`, shared by the standard EVM, zkSync and Tron variants: sends through the mailbox and accepts deliveries through `handle`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_HyperlaneTransceiverBase · constructor_ | Stores the mailbox (nonzero) and the extension. Overrides or is overridden in: HyperlaneTransceiver, HyperlaneTronTransceiver, HyperlaneZkSyncTransceiver, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, HyperlaneZkSyncTransceiver.constructor, HyperlaneTronTransceiver.constructor, HyperlaneTransceiver.constructor; also tests | No (constructor) |
| `__HyperlaneTransceiver_init(c, governorHomeDomain)`<br>_HyperlaneTransceiverBase · internal_ | Initializer that sets the governor-home Hyperlane domain. | HyperlaneZkSyncTransceiver.initialize, HyperlaneTronTransceiver.initialize, HyperlaneTransceiver.initialize | No |
| `setProviderId(chainKey, domain)`<br>_HyperlaneTransceiverBase · external_ | Owner maps a chain key to its Hyperlane domain (write-once-if-unset). | tests only | Yes, gated by onlyOwner (state-changing) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_HyperlaneTransceiverBase · internal_ | Dispatches through the mailbox, refunding to the float during a report and the caller otherwise. Overrides or is overridden in: OutboundBase. | TransceiverBase._sendBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_HyperlaneTransceiverBase · internal view_ | Quotes the mailbox dispatch for the recipient's domain. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `handle(origin, sender, message)`<br>_HyperlaneTransceiverBase · external payable_ | Mailbox delivers a message; the base's origin check is the only sender check. | tests only | Yes, gated by onlyRole(GATEWAY_ROLE) (state-changing) |
| `constructor`<br>_HyperlaneTransceiver · constructor_ | Passes the mailbox and extension to the base. Overrides or is overridden in: HyperlaneTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, HyperlaneTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeDomain)`<br>_HyperlaneTransceiver · external_ | Initializes the Hyperlane settings and then the transceiver base. | tests only | Yes, gated by initializer (state-changing) |


#### `contracts/evm/src/protocols/hyperlane/HyperlaneTransmitter.sol`

Per-user sender-only Hyperlane transmitter created by `TransceiverBase.createTransmitter`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Stores the mailbox (nonzero). | tests only | No (constructor) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Dispatches the payload through the mailbox to the recipient's domain. Overrides or is overridden in: OutboundBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Quotes the dispatch for the recipient's domain. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap; also tests | No |
| `supportsAttribute(selector)`<br>_external pure_ | Accepts the Hyperlane gas-limit attribute. Declared in: IERC7786GatewaySource. | tests only | Yes, anyone (read-only) |


### `contracts/evm/src/protocols/layerzero`

#### `contracts/evm/src/protocols/layerzero/ILzOftConduitFactory.sol`

Interfaces for what a `layerzero-oft` conduit reads from its factory: per-destination eid and OFT, and the signed bootstrap transport.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `destinationOf(conduit, chainKey)`<br>_ILzOftConduitFactory · external view_ | The eid and OFT a conduit reaches a chain through, as it was created with; reverts for a chain it was not created with. Implemented in: LzOftConduitFactory. | LzOftTransmitter._messageParam, SDK ABI trim list; also tests | Yes via interface (read-only) |
| `signedConduitBootstrap(route, body)`<br>_ILzOftSignedConduitFactory · external view_ | Encodes the calling conduit's signed bootstrap and its destination factory route, so quote and send use identical bytes. Implemented in: LzOftConduitFactory. | LzOftTransmitter._quoteSignedBootstrap, LzOftTransmitter._sendSignedBootstrap, SDK ABI trim list; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/protocols/layerzero/LzDivergentTransceiver.sol`

LayerZero transceivers for zkSync Era and Tron, which only add the chain's address derivation and deployment to `LzTransceiverBase`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_LzZkSyncTransceiver · constructor_ | Passes the LayerZero endpoint and extension to the base. Overrides or is overridden in: LzTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, LzTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeEid, governorHomeDvn, conduitBytecodeHash_)`<br>_LzZkSyncTransceiver · external_ | Initializes with config, governor-home eid and DVN, and the zksolc `Proxy` bytecode hash. | tests only | Yes, gated by initializer (state-changing) |
| `_conduitAt(conduitSalt)`<br>_LzZkSyncTransceiver · internal view_ | Resolves the inheritance diamond to the zkSync conduit prediction. Overrides or is overridden in: TransceiverCore, ZkSyncTransceiver. | TransceiverCore._predictConduit; also tests | No |
| `_deployConduit(salt)`<br>_LzZkSyncTransceiver · internal_ | Resolves the diamond to zkSync's system-call deployment. Overrides or is overridden in: TransceiverBase, ZkSyncTransceiver. | TransceiverBase._createConduit; also tests | No |
| `_storeProxyInitCode()`<br>_LzZkSyncTransceiver · internal_ | Resolves the diamond to the zkSync no-store variant. Overrides or is overridden in: TransceiverBase, ZkSyncTransceiver. | TransceiverBase.constructor; also tests | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_LzZkSyncTransceiver · internal view_ | Resolves the diamond to the LayerZero transceiver's initializer. Overrides or is overridden in: LzTransceiverBase, ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer, LzTransceiverBase._conduitInitializer; also tests | No |
| `_checkOwner()`<br>_LzZkSyncTransceiver · internal view_ | Resolves the diamond to the OApp-delegate-safe owner check. Overrides or is overridden in: LzTransceiverBase. | OwnableTransmitter._checkOwner, LzTransceiverBase._checkOwner | No |
| `constructor`<br>_LzTronTransceiver · constructor_ | Passes the endpoint and extension to the base. Overrides or is overridden in: LzTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, LzTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeEid, governorHomeDvn, conduitBytecodeHash_)`<br>_LzTronTransceiver · external_ | Initializes with config, governor-home eid and DVN, and Tron-solc's `Proxy` initcode hash. | tests only | Yes, gated by initializer (state-changing) |
| `_conduitAt(conduitSalt)`<br>_LzTronTransceiver · internal view_ | Resolves the diamond to the Tron conduit prediction. Overrides or is overridden in: TransceiverCore, TronTransceiver. | TransceiverCore._predictConduit; also tests | No |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_LzTronTransceiver · internal view_ | Resolves the diamond to the LayerZero transceiver's initializer. Overrides or is overridden in: LzTransceiverBase, ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer, LzTransceiverBase._conduitInitializer; also tests | No |
| `_checkOwner()`<br>_LzTronTransceiver · internal view_ | Resolves the diamond to the OApp-delegate-safe owner check. Overrides or is overridden in: LzTransceiverBase. | OwnableTransmitter._checkOwner, LzTransceiverBase._checkOwner | No |


#### `contracts/evm/src/protocols/layerzero/LzHomePeer.sol`

Abstract helper that sets a LayerZero peer during an initializer, for receivers and for a transceiver's governor-home peer that have no owner yet.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_initHomePeer(eid, peer)`<br>_internal_ | Writes the peer for an eid directly into OApp storage and emits `PeerSet`; reverts for eid zero. | LzReceiver.initialize, LzTransceiverBase._initGovernorHomePeer | No |


#### `contracts/evm/src/protocols/layerzero/LzMessage.sol`

Linked library for LayerZero send and quote through the endpoint, the execution-options attribute, and DVN pinning on the send and receive libraries.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `send(endpoint, dstEid, peer, payload, attributes, defaultGas, value, refundTo)`<br>_public_ | Sends a payload to the peer on a destination eid through the endpoint, returning nothing (the guid is in the endpoint's event). | LzTransceiverBase._sendMessage, LzTransmitter._sendMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `quote(endpoint, dstEid, peer, payload, attributes, defaultGas)`<br>_public view_ | The endpoint's native fee for the same message. | LzTransceiverBase._quoteMessage, LzTransmitter._quoteMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `pinSendDvn(endpoint, eid, dvn)`<br>_public_ | Verifies what this OApp sends to an eid with one DVN alone on the current default send library. | LzTransceiverBase._pinDvn; also tests | No (linked library: its host contract calls it by delegatecall) |
| `setSendDvns(endpoint, eid, required, optional, optionalThreshold)`<br>_public_ | Sets required and optional DVNs (with threshold) for sends to an eid, replacing the default and earlier sets. | LzMessage.pinSendDvn, LzTransmitter.setDvn | No (linked library: its host contract calls it by delegatecall) |
| `pinReceiveDvn(endpoint, eid, dvn)`<br>_public_ | Same as `pinSendDvn` for what this OApp accepts from an eid. | LzReceiver.initialize, LzTransceiverBase._pinDvn; also tests | No (linked library: its host contract calls it by delegatecall) |
| `composeOptions(attributes, gas)`<br>_internal pure_ | Options for a message sent through an OFT with a compose message, defaulting to one `lzCompose` option with the given gas. | LzOftMessage.sendParam | No |

Private helpers: `_dvnStack`, `_optionsOr`, `defaultComposeOptions`, `options`.


#### `contracts/evm/src/protocols/layerzero/LzOftConduitFactory.sol`

Factory that creates every `layerzero-oft` conduit: the transmitter at `createTransmitter` and each receiver when its bootstrap arrives as an OFT compose.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `deployer()`<br>_IConduitIdentity · external view_ | A conduit's fixed deployer, read back by the factory. | LzOftConduitFactory.signedConduitBootstrap; also tests | Yes via interface (read-only) |
| `conduitSalt()`<br>_IConduitIdentity · external view_ | A conduit's fixed salt, read back by the factory. | LzOftConduitFactory.signedConduitBootstrap; also tests | Yes via interface (read-only) |
| `constructor`<br>_LzOftConduitFactory · constructor_ | Stores the implementations, treasury and local chain key and stores `Proxy`'s initcode. | tests only | No (constructor) |
| `conduitSalt(owner, salt, homeChainKey, homeEid, homeOft, destRoot)`<br>_LzOftConduitFactory · public pure_ | The salt a conduit deploys at, from owner, salt, home chain key and eid, home OFT and destination root. | LzOftConduitFactory.predictConduit, LzOftConduitFactory.createTransmitter, LzOftConduitFactory._authenticateBootstrap, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `predictConduit(owner, salt, homeChainKey, homeEid, homeOft, destRoot)`<br>_LzOftConduitFactory · public view_ | The conduit address those inputs produce. | LzOftConduitFactory._requireDerived, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `createTransmitter(salt, homeOft, leaves)`<br>_LzOftConduitFactory · external_ | Caller creates its conduit, reaching exactly the given destination leaves, after checking each leaf against the home OFT's peers. | SDK ts/lzOft.createLzOftTransmitterCalldata, SDK ABI trim list; also tests | Yes, anyone (state-changing) |
| `bootstrapRoute(conduit, chainKey)`<br>_LzOftConduitFactory · external view_ | Where a conduit's bootstrap to a chain goes, with the home eid, root and proof that the compose carries. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `destinationOf(conduit, chainKey)`<br>_LzOftConduitFactory · external view_ | The eid and OFT a conduit reaches a chain through. Declared in: ILzOftConduitFactory. | LzOftTransmitter._messageParam, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `conduitBootstrap(route, owner, salt, body)`<br>_LzOftConduitFactory · external view_ | The bootstrap message the calling conduit sends itself through its home OFT to the destination factory. | tests only | Yes, anyone (read-only) |
| `signedConduitBootstrap(route, body)`<br>_LzOftConduitFactory · external view_ | The signed-bootstrap message for the calling conduit to send through its own OFT. Declared in: ILzOftSignedConduitFactory. | LzOftTransmitter._quoteSignedBootstrap, LzOftTransmitter._sendSignedBootstrap, SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `isSigned(conduit)`<br>_LzOftConduitFactory · external view_ | Whether a conduit was created in signed mode. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `reportsReceiver(bytes32)`<br>_LzOftConduitFactory · external pure_ | Always false: every chain this binding reaches uses Ethereum's CREATE2. | tests only | Yes, anyone (read-only) |
| `predictReceiver(bytes32, address, bytes32)`<br>_LzOftConduitFactory · external view_ | The calling conduit's receiver address on any destination, which is its own address. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `lzCompose(_from, bytes32, _message, address, bytes)`<br>_LzOftConduitFactory · external payable_ | The OFT delivers a bootstrap compose; authenticates it and creates and arms the receiver. | tests only | Yes, anyone (state-changing) |

Private helpers: `_armSignedReceiver`, `_authenticate`, `_authenticateBootstrap`, `_callerConduit`, `_createReceiver`, `_createSignedReceiver`, `_destination`, `_forwardValue`, `_homeEid`, `_requireDerived`, `_requireLeaves`.


#### `contracts/evm/src/protocols/layerzero/LzOftMessage.sol`

Library for sending and quoting through an operator's OFT and for the leaf and bootstrap formats the `layerzero-oft` binding's two ends agree on.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `sendParam(dstEid, to, composeMsg, attributes, gas)`<br>_public pure_ | Builds the one OFT `SendParam` that a send and its quote both use. | LzOftTransmitter._messageParam; also tests | No (linked library: its host contract calls it by delegatecall) |
| `send(oft, param, value, refundTo)`<br>_public_ | Calls the OFT's `send` with the fee and refund address. | LzOftTransmitter._sendMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `quote(oft, param)`<br>_public view_ | The OFT's native fee for a `SendParam`. | LzOftTransmitter._quoteMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `requirePeer(oft, eid, expected)`<br>_internal view_ | Reverts unless the OFT still names the expected peer for an eid. | LzOftConduitFactory._authenticateBootstrap, LzOftConduitFactory._requireLeaves, LzOftReceiver.lzCompose, LzOftTransmitter._messageParam; also tests | No |
| `leaf(chainKey, eid, oft)`<br>_internal pure_ | A destination's leaf in a conduit's root, hashed twice. | LzOftConduitFactory._authenticateBootstrap, LzOftConduitFactory._requireLeaves; also tests | No |
| `encodeBootstrap(b)`<br>_internal pure_ | ABI-encodes a bootstrap compose message. | LzOftConduitFactory.conduitBootstrap; also tests | No |
| `decodeBootstrap(message)`<br>_internal pure_ | Decodes a bootstrap compose message. | LzOftConduitFactory._authenticate; also tests | No |
| `root(leaves)`<br>_internal pure_ | Merkle root over leaves in the given order. | LzOftConduitFactory.createTransmitter; also tests | No |
| `proof(level, index)`<br>_internal pure_ | Sibling path for a leaf index. | LzOftConduitFactory.bootstrapRoute, LzOftConduitFactory.conduitBootstrap, LzOftConduitFactory.signedConduitBootstrap; also tests | No |

Private helpers: `_up`.


#### `contracts/evm/src/protocols/layerzero/LzOftReceiver.sol`

A `layerzero-oft` conduit on a destination that takes each message as an OFT compose from its operator's OFT here.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `initialize(sourceTransmitter, homeEid, homeOft, localOft, calls)`<br>_ILzOftReceiverInit · external_ | The initializer the factory arms the receiver with (source transmitter, home eid and OFT, local OFT, calls). Implemented in: LzOftReceiver. | LzOftConduitFactory._createReceiver, LzOftConduitFactory._armSignedReceiver; also tests | Yes via interface (state-changing) |
| `constructor`<br>_LzOftReceiver · constructor_ | Passes the guard pins to `SignedReceiver`. Overrides or is overridden in: SignedReceiver. | SignedReceiver.constructor; also tests | No (constructor) |
| `initialize(address, bytes32, Call[])`<br>_LzOftReceiver · external pure_ | Reverts `UseLzOftInitializer` because the OFT conduit requires a provider-specific initializer. Declared in: ILzOftReceiverInit, IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, LzOftConduitFactory._createReceiver, LzOftConduitFactory._armSignedReceiver, OpStackInteropTransceiver._conduitInitializer; also tests | Yes, anyone (read-only) |
| `initialize(sourceTransmitter_, homeEid, homeOft_, localOft_, calls)`<br>_LzOftReceiver · external_ | Binds the receiver to its transmitter, home eid and OFTs, grants the gateway and runs the bootstrap calls. Declared in: ILzOftReceiverInit, IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, LzOftConduitFactory._createReceiver, LzOftConduitFactory._armSignedReceiver, OpStackInteropTransceiver._conduitInitializer; also tests | Yes, gated by initializer (state-changing) |
| `lzCompose(_from, bytes32, _message, address, bytes)`<br>_LzOftReceiver · external payable_ | The endpoint delivers a compose; checks the gateway role, the local OFT and peer, then runs the payload via `_onMessageFrom`. | tests only | Yes, but the body gates it (role GATEWAY_ROLE) (state-changing) |


#### `contracts/evm/src/protocols/layerzero/LzOftTransmitter.sol`

A `layerzero-oft` conduit on its home that sends every message, bootstraps included, through its operator's OFT.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `initialize(owner, factory, salt, homeOft)`<br>_ILzOftTransmitterInit · external_ | The initializer the factory arms a transmitter with (owner, factory, salt, home OFT). Implemented in: LzOftTransmitter. | LzOftConduitFactory.createTransmitter; also tests | Yes via interface (state-changing) |
| `initialize(address, address, bytes32)`<br>_LzOftTransmitter · external pure_ | Reverts: the base initializer would leave the home OFT unset. Declared in: ILzOftTransmitterInit. | LzOftConduitFactory.createTransmitter; also tests | Yes, anyone (read-only) |
| `initialize(owner_, factory_, salt_, homeOft_)`<br>_LzOftTransmitter · external_ | Initializes ownership and the transmitter base and stores the home OFT. Declared in: ILzOftTransmitterInit. | LzOftConduitFactory.createTransmitter; also tests | Yes, gated by initializer (state-changing) |
| `destinationOf(chainKey)`<br>_LzOftTransmitter · external view_ | The eid and OFT a bootstrap recorded for a chain; zero before it. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `supportsAttribute(selector)`<br>_LzOftTransmitter · external pure_ | Accepts the LayerZero options attribute. Declared in: IERC7786GatewaySource. | SDK ABI trim list; also tests | Yes, anyone (read-only) |
| `_quoteSignedBootstrap(bytes32, route, body, attributes)`<br>_LzOftTransmitter · internal view_ | Quotes the signed bootstrap envelope sent through the OFT. Overrides or is overridden in: SignedTransmitter. | SignedTransmitter.bootstrap, SignedTransmitter.quoteBootstrap | No |
| `_sendSignedBootstrap(bytes32, route, body, attributes, fee)`<br>_LzOftTransmitter · internal_ | Sends the signed bootstrap through the OFT, preserving `composeFrom` and recording the destination first. Overrides or is overridden in: SignedTransmitter. | SignedTransmitter.bootstrap | No |
| `_sendMessage(recipient, payload, attributes, value)`<br>_LzOftTransmitter · internal_ | Sends through the OFT, recording a bootstrap's destination before the external call. Overrides or is overridden in: OutboundBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap, LzOftTransmitter._sendSignedBootstrap; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_LzOftTransmitter · internal view_ | Quotes the OFT send for the message. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap, LzOftTransmitter._quoteSignedBootstrap; also tests | No |

Private helpers: `_messageParam`.


#### `contracts/evm/src/protocols/layerzero/LzReceiver.sol`

Per-user native LayerZero conduit on a non-home chain; receiver-only OApp that sets its one peer at initialization.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `initialize(sourceTransmitter, calls, homeEid, homeDvn)`<br>_ILzReceiverInit · external_ | The initializer a transceiver arms the receiver with (source transmitter, calls, home eid and DVN). Implemented in: LzReceiver. | LzTransceiverBase._conduitInitializer; also tests | Yes via interface (state-changing) |
| `constructor`<br>_LzReceiver · constructor_ | Passes the guard pins to `SignedReceiver` and the endpoint to the OApp. Overrides or is overridden in: SignedReceiver. | SignedReceiver.constructor; also tests | No (constructor) |
| `initialize(address, bytes32, Call[])`<br>_LzReceiver · external pure_ | Reverts `UseLzInitializer` because the LayerZero receiver requires a provider-specific initializer. Declared in: ILzReceiverInit, IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, LzTransceiverBase._conduitInitializer, OpStackInteropTransceiver._conduitInitializer; also tests | Yes, anyone (read-only) |
| `initialize(sourceTransmitter_, calls, homeEid, homeDvn)`<br>_LzReceiver · external_ | Sets the home peer, optionally pins the home's DVN, grants the gateway and runs the bootstrap calls. Declared in: ILzReceiverInit, IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, LzTransceiverBase._conduitInitializer, OpStackInteropTransceiver._conduitInitializer; also tests | Yes, gated by initializer (state-changing) |

Private helpers: `_lzReceive`.


#### `contracts/evm/src/protocols/layerzero/LzTransceiver.sol`

LayerZero on `TransceiverBase`, shared by the standard EVM, zkSync and Tron variants: one OApp sends bootstraps and reports to any configured eid and receives them from any set peer.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_LzTransceiverBase · constructor_ | Stores the endpoint (nonzero) and the extension. Overrides or is overridden in: LzTransceiver, LzTronTransceiver, LzZkSyncTransceiver, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, LzZkSyncTransceiver.constructor, LzTronTransceiver.constructor, LzTransceiver.constructor; also tests | No (constructor) |
| `__LzTransceiver_init(c, governorHomeEid, governorHomeDvn)`<br>_LzTransceiverBase · internal_ | Makes the OApp its own delegate and initializes the governor-home eid and DVN. | LzZkSyncTransceiver.initialize, LzTronTransceiver.initialize, LzTransceiver.initialize | No |
| `setDvn(eid, dvn)`<br>_LzTransceiverBase · external_ | Owner verifies the pathway to and from an eid with one DVN, write-once. | tests only | Yes, gated by onlyOwner (state-changing) |
| `_checkOwner()`<br>_LzTransceiverBase · internal view_ | Owner check that also refuses `setDelegate`-style changes by anyone but the owner. Overrides or is overridden in: LzTronTransceiver, LzZkSyncTransceiver. | OwnableTransmitter._checkOwner, LzZkSyncTransceiver._checkOwner, LzTronTransceiver._checkOwner | No |
| `_initGovernorHomePeer(c, governorHomeEid)`<br>_LzTransceiverBase · internal_ | Sets the peer for the governor's home eid to the counterpart there so the bootstrap that creates the owner can arrive. | LzZkSyncTransceiver.initialize, LzTronTransceiver.initialize, LzTransceiver.initialize | No |
| `setProviderId(chainKey, eid)`<br>_LzTransceiverBase · external_ | Owner maps a chain key to its LayerZero eid (write-once-if-unset). | tests only | Yes, gated by onlyOwner (state-changing) |
| `setPeer(eid, peer)`<br>_LzTransceiverBase · public_ | Owner sets an eid's peer, which must be the counterpart on the chain the eid maps to. Overrides or is overridden in: LzWriteOncePeer. | LzWriteOncePeer.setPeer; also tests | Yes, gated by onlyOwner (state-changing) |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_LzTransceiverBase · internal view_ | Builds a receiver initializer armed with the home's eid and pinned DVN. Overrides or is overridden in: LzTronTransceiver, LzZkSyncTransceiver, ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer, LzZkSyncTransceiver._conduitInitializer, LzTronTransceiver._conduitInitializer; also tests | No |
| `_sendMessage(recipient, payload, attributes, value)`<br>_LzTransceiverBase · internal_ | Sends through the endpoint to the peer for the recipient's eid. Overrides or is overridden in: OutboundBase. | TransceiverBase._sendBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_LzTransceiverBase · internal view_ | Quotes the endpoint fee to the peer for the recipient's eid. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `constructor`<br>_LzTransceiver · constructor_ | Passes the endpoint and extension to the base. Overrides or is overridden in: LzTransceiverBase, TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor, LzTransceiverBase.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeEid, governorHomeDvn)`<br>_LzTransceiver · external_ | Initializes the LayerZero settings, the transceiver base and the governor-home peer. | tests only | Yes, gated by initializer (state-changing) |

Private helpers: `_lzReceive`, `_pinDvn`.


#### `contracts/evm/src/protocols/layerzero/LzTransmitter.sol`

Per-user sender-only native LayerZero transmitter; the owner sets one peer per destination before its first send.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Stores the LayerZero endpoint on the implementation. | tests only | No (constructor) |
| `initialize(owner_, transceiver_, salt_)`<br>_external_ | Initializes ownership and the transmitter base with no peers. Overrides or is overridden in: OwnableTransmitter. | tests only | Yes, gated by initializer (state-changing) |
| `_checkOwner()`<br>_internal view_ | Resolves the diamond to the owner check. Overrides or is overridden in: OwnableTransmitter, TransmitterBase. | OwnableTransmitter._checkOwner, SignedTransmitter.sendMessage, SignedTransmitter.bootstrap, TransmitterBase.onlyConduitOwner | No |
| `transferOwnership(newOwner)`<br>_public_ | Resolves the diamond to `SignedTransmitter`'s signed-mode-aware version. Overrides or is overridden in: SignedTransmitter. | SignedTransmitter.transferOwnership; also tests | Yes, but the body gates it (super.transferOwnership) (state-changing) |
| `renounceOwnership()`<br>_public_ | Resolves the diamond to `SignedTransmitter`'s signed-mode-aware version. Overrides or is overridden in: SignedTransmitter. | SignedTransmitter.renounceOwnership; also tests | Yes, but the body gates it (super.renounceOwnership) (state-changing) |
| `setDvn(eid, required, optional, optionalThreshold)`<br>_external_ | Owner verifies what this conduit sends to an eid with its own required and optional DVN stack. | tests only | Yes, gated by onlyOwner (state-changing) |
| `setPeer(eid, peer)`<br>_public_ | Resolves the diamond to the write-once peer setter. Overrides or is overridden in: LzWriteOncePeer. | LzWriteOncePeer.setPeer; also tests | Yes, but the body gates it (super.setPeer) (state-changing) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Sends through the endpoint to the peer recorded for the eid, paid from the conduit's balance. Overrides or is overridden in: OutboundBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Quotes the endpoint fee to the peer for the recipient's eid. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap; also tests | No |
| `supportsAttribute(selector)`<br>_external pure_ | Accepts the LayerZero options attribute. Declared in: IERC7786GatewaySource. | tests only | Yes, anyone (read-only) |


#### `contracts/evm/src/protocols/layerzero/LzWriteOncePeer.sol`

Abstract OApp mixin that makes `setPeer` write-once per eid for contracts that have an owner.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `setPeer(eid, peer)`<br>_public_ | Owner sets a nonzero peer once per eid; the same peer again is a no-op and a different one reverts. Overrides or is overridden in: LzTransceiverBase, LzTransmitter. | LzTransceiverBase.setPeer, LzTransmitter.setPeer; also tests | Yes, gated by onlyOwner (state-changing) |


### `contracts/evm/src/protocols/op-stack`

#### `contracts/evm/src/protocols/op-stack/OpStackInteropMessage.sol`

Library with the send, quote and inbound-context logic shared by every `op-stack-l2-l2` contract over the Superchain interop `L2ToL2CrossDomainMessenger`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `send(routes, recipient, payload, attributes, value)`<br>_internal_ | Sends `receiveOpStackMessage(payload)` to the recipient on the destination chain through the interop messenger (no fee, no options). | OpStackInteropTransceiver._sendMessage, OpStackInteropTransmitter._sendMessage; also tests | No |
| `quote(routes, recipient, attributes)`<br>_internal view_ | Returns zero after the same checks `send` applies, so it reverts wherever the send would. | OpStackInteropTransceiver._quoteMessage, OpStackInteropTransmitter._quoteMessage; also tests | No |
| `context()`<br>_internal view_ | The origin-chain sender and chain id of the message being relayed, read from the messenger. | OpStackInteropReceiver.receiveOpStackMessage, OpStackInteropTransceiver.receiveOpStackMessage; also tests | No |

Private helpers: `_requireSend`.


#### `contracts/evm/src/protocols/op-stack/OpStackInteropReceiver.sol`

Per-user conduit on a non-home chain for `op-stack-l2-l2`, whose origin is the source chain id the interop messenger reports.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Passes the guard pins to `SignedReceiver`. Overrides or is overridden in: ProviderReceiver, SignedReceiver. | SignedReceiver.constructor, ProviderReceiver.constructor; also tests | No (constructor) |
| `_providerGateway()`<br>_internal pure_ | Returns the interop messenger predeploy as the delivering gateway. Overrides or is overridden in: ProviderReceiver. | ProviderReceiver.initialize | No |
| `receiveOpStackMessage(payload)`<br>_external_ | The messenger delivers a payload; the sender is the messenger's `crossDomainMessageSender`, then `_onMessageFrom` checks it. Declared in: IOpStackRecipient. | OpStackInteropMessage.send, OpStackMessage.send; also tests | Yes, gated by onlyRole(GATEWAY_ROLE) (state-changing) |


#### `contracts/evm/src/protocols/op-stack/OpStackInteropTransceiver.sol`

Superchain interop on `TransceiverBase`: the `op-stack-l2-l2` provider between OP Stack chains, using one messenger that names a destination by chain id.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Passes the extension to the base. Overrides or is overridden in: TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor; also tests | No (constructor) |
| `initialize(c)`<br>_external_ | Initializes the transceiver base and grants `GATEWAY_ROLE` to the messenger. | tests only | Yes, gated by initializer (state-changing) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Sends a bootstrap or report through the interop messenger. Overrides or is overridden in: OutboundBase. | TransceiverBase._sendBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `_quoteMessage(recipient, bytes, attributes)`<br>_internal view_ | Zero, as interop sends have no fee. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `receiveOpStackMessage(payload)`<br>_external_ | The messenger delivers a payload; authenticates the source chain and sender through `_onInbound`. Declared in: IOpStackRecipient. | OpStackInteropMessage.send, OpStackMessage.send; also tests | Yes, gated by onlyRole(GATEWAY_ROLE) (state-changing) |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_internal view_ | Builds a receiver initializer that names its home by the chain id the messenger reports. Overrides or is overridden in: TransceiverBase. | TransceiverBase._createConduit; also tests | No |


#### `contracts/evm/src/protocols/op-stack/OpStackInteropTransmitter.sol`

Per-user sender-only transmitter for `op-stack-l2-l2`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Sends through `OpStackInteropMessage.send` using the transceiver's routes. Overrides or is overridden in: OutboundBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap; also tests | No |
| `_quoteMessage(recipient, bytes, attributes)`<br>_internal view_ | Zero, as interop sends have no fee. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap; also tests | No |
| `supportsAttribute(bytes4)`<br>_external pure_ | Accepts no attributes. Declared in: IERC7786GatewaySource. | tests only | Yes, anyone (read-only) |


#### `contracts/evm/src/protocols/op-stack/OpStackMessage.sol`

Interface for the inbound entry point every OP Stack binding exposes (`IOpStackRecipient`) and the shared `op-stack-l1-l2` send, quote and sender logic over `CrossDomainMessenger`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `receiveOpStackMessage(payload)`<br>_IOpStackRecipient · external_ | Inbound entry point that the messenger calls with the payload. Implemented in: OpStackInteropReceiver, OpStackInteropTransceiver, OpStackReceiver, OpStackTransceiver. | OpStackInteropMessage.send, OpStackMessage.send; also tests | Yes via interface (state-changing) |
| `send(messenger, recipient, payload, attributes, value, defaultGas)`<br>_OpStackMessage · internal_ | Sends `receiveOpStackMessage(payload)` through the messenger for the recipient's chain with a minimum gas limit. | OpStackTransceiver._sendMessage, OpStackTransmitter._sendMessage; also tests | No |
| `quote(recipient, attributes, defaultGas)`<br>_OpStackMessage · internal pure_ | Returns zero after the same checks as `send`. | OpStackTransceiver._quoteMessage, OpStackTransmitter._quoteMessage; also tests | No |
| `sender()`<br>_OpStackMessage · internal view_ | The origin-chain sender of the message being relayed, read from the messenger that called. | OpStackReceiver.receiveOpStackMessage, OpStackTransceiver.receiveOpStackMessage; also tests | No |

Private helpers: `_requireRecipient`, `minGasLimitFrom`.


#### `contracts/evm/src/protocols/op-stack/OpStackReceiver.sol`

Per-user conduit on a non-home chain for `op-stack-l1-l2`, whose origin is the messenger that called.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `initialize(sourceTransmitter, calls, messenger)`<br>_IOpStackReceiverInit · external_ | The initializer the receiver is armed with (source transmitter, calls, home's messenger). Implemented in: OpStackReceiver. | OpStackTransceiver._conduitInitializer; also tests | Yes via interface (state-changing) |
| `constructor`<br>_OpStackReceiver · constructor_ | Passes the guard pins to `SignedReceiver`. Overrides or is overridden in: SignedReceiver. | SignedReceiver.constructor; also tests | No (constructor) |
| `initialize(address, bytes32, Call[])`<br>_OpStackReceiver · external pure_ | First overload reverts `UseOpStackInitializer`; the second grants the messenger the gateway role, binds the transmitter and runs the bootstrap calls. Declared in: IOpStackReceiverInit, IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, OpStackInteropTransceiver._conduitInitializer, OpStackTransceiver._conduitInitializer; also tests | Yes, anyone (read-only) |
| `initialize(sourceTransmitter_, calls, messenger)`<br>_OpStackReceiver · external_ | First overload reverts `UseOpStackInitializer`; the second grants the messenger the gateway role, binds the transmitter and runs the bootstrap calls. Declared in: IOpStackReceiverInit, IReceiverInit. | TransceiverBase._conduitInitializer, ProviderTransceiver._conduitInitializer, OpStackInteropTransceiver._conduitInitializer, OpStackTransceiver._conduitInitializer; also tests | Yes, gated by initializer (state-changing) |
| `receiveOpStackMessage(payload)`<br>_OpStackReceiver · external_ | The messenger delivers a payload; the sender is `xDomainMessageSender`, then `_onMessageFrom` checks it. Declared in: IOpStackRecipient. | OpStackInteropMessage.send, OpStackMessage.send; also tests | Yes, gated by onlyRole(GATEWAY_ROLE) (state-changing) |


#### `contracts/evm/src/protocols/op-stack/OpStackTransceiver.sol`

OP Stack's `CrossDomainMessenger` on `TransceiverBase`: the `op-stack-l1-l2` provider between Ethereum and each OP Stack chain, with one messenger per chain.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Passes the extension to the base. Overrides or is overridden in: TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeMessenger)`<br>_external_ | Initializes with config and the messenger that reaches the governor's home. | tests only | Yes, gated by initializer (state-changing) |
| `setProviderId(chainKey, messenger)`<br>_external_ | Owner names the messenger on this chain that reaches a chain key (write-once-if-unset). | tests only | Yes, gated by onlyOwner (state-changing) |
| `messengerFor(chainKey)`<br>_public view_ | The messenger that reaches a chain key; reverts when unset. | OpStackTransceiver._conduitInitializer; also tests | Yes, anyone (read-only) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Sends through the messenger for the recipient's chain. Overrides or is overridden in: OutboundBase. | TransceiverBase._sendBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Zero, as L1 to L2 deposits have no native fee. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `receiveOpStackMessage(payload)`<br>_external_ | A messenger delivers a payload; its chain is looked up first, then origin and sender are authenticated. Declared in: IOpStackRecipient. | OpStackInteropMessage.send, OpStackMessage.send; also tests | Yes, anyone (state-changing) |
| `_conduitInitializer(owner, salt, homeChainKey, sourceTransmitter, calls)`<br>_internal view_ | Builds a receiver initializer whose gateway is the messenger that reaches the conduit's home. Overrides or is overridden in: ProviderTransceiver, TransceiverBase. | TransceiverBase._createConduit, ProviderTransceiver._conduitInitializer; also tests | No |


#### `contracts/evm/src/protocols/op-stack/OpStackTransmitter.sol`

Per-user sender-only transmitter for `op-stack-l1-l2`, sending through the messenger its transceiver maps the recipient's chain to.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Sends through the messenger recorded for the recipient's chain with the default gas. Overrides or is overridden in: OutboundBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Zero, as L1 to L2 deposits have no native fee. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap; also tests | No |
| `supportsAttribute(selector)`<br>_external pure_ | Accepts the OP Stack minimum-gas-limit attribute. Declared in: IERC7786GatewaySource. | tests only | Yes, anyone (read-only) |


#### `contracts/evm/src/protocols/op-stack/OpStackTransmitterBase.sol`

Abstract transmitter base holding the fixed outbound Crossecute fee shared by the two OP Stack bindings.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `_crossecuteFee(uint256)`<br>_internal pure_ | Fixed fee of 0.0001 ether regardless of the provider fee. Overrides or is overridden in: TransmitterBase. | SignedTransmitter._sendStandalone, SignedTransmitter.quoteMessageSigned, TransmitterBase.quoteMessageBreakdown | No |


### `contracts/evm/src/protocols/wormhole`

#### `contracts/evm/src/protocols/wormhole/WormholeMessage.sol`

Linked library for Wormhole send, quote and inbound VAA verification over Core `publishMessage` and Executor delivery.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `send(route, recipient, payload, attributes, value, refundTo, defaultGas)`<br>_public_ | Publishes through Core and requests Executor delivery with the caller's signed quote, refunding the rest. | WormholeTransceiver._sendMessage, WormholeTransmitter._sendMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `quote(route, recipient, attributes, defaultGas)`<br>_public view_ | Core's message fee plus the execution price, reverting where `send` would. | WormholeTransceiver._quoteMessage, WormholeTransmitter._quoteMessage; also tests | No (linked library: its host contract calls it by delegatecall) |
| `consumeVaa(coreBridge, gatewayHeld, vaa)`<br>_internal_ | Checks a VAA for delivery to this contract, marks it consumed and returns its emitter chain, emitter and inner payload. | WormholeReceiver.executeVAAv1, WormholeTransceiver.executeVAAv1 | No |
| `consumed(vaaHash)`<br>_internal view_ | Whether a VAA hash has been consumed. | WormholeReceiver.vaaConsumed, WormholeTransceiver.vaaConsumed | No |

Private helpers: `_consume`, `_consumedSet`, `_payloadOf`, `_refund`, `_requestBytes`, `_requestExecution`, `_word`, `execution`, `executionFrom`, `executionPrice`, `publishOnly`, `recipientOf`, `relayInstructions`.


#### `contracts/evm/src/protocols/wormhole/WormholeReceiver.sol`

Per-user conduit on a non-home chain that accepts permissionless VAA delivery, checking that the Core bridge still holds the gateway role.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Passes the guard pins to `SignedReceiver` and stores the Core bridge (nonzero). Overrides or is overridden in: ProviderReceiver, SignedReceiver. | SignedReceiver.constructor, ProviderReceiver.constructor; also tests | No (constructor) |
| `_providerGateway()`<br>_internal view_ | Returns the Core bridge as the gateway. Overrides or is overridden in: ProviderReceiver. | ProviderReceiver.initialize | No |
| `executeVAAv1(multiSigVaa)`<br>_external payable_ | Anyone submits a guardian-signed VAA; verifies it and runs the payload via `_onMessageFrom`. | tests only | Yes, anyone (state-changing) |
| `vaaConsumed(vaaHash)`<br>_external view_ | Whether a VAA hash has already been consumed. | tests only | Yes, anyone (read-only) |


#### `contracts/evm/src/protocols/wormhole/WormholeTransceiver.sol`

Wormhole on `TransceiverBase`, with a table from chain key to Wormhole's own `uint16` chain id; there are no zkSync or Tron variants.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Stores the Core bridge and Executor (both nonzero) and the extension. Overrides or is overridden in: TransceiverBase, TransceiverCore. | TransceiverBase.constructor, TransceiverCore.constructor; also tests | No (constructor) |
| `initialize(c, governorHomeChain)`<br>_external_ | Initializes the Wormhole settings with the governor-home chain and then the transceiver base. | tests only | Yes, gated by initializer (state-changing) |
| `setProviderId(chainKey, wormholeChain)`<br>_external_ | Owner maps a chain key to its Wormhole chain id (write-once-if-unset). | tests only | Yes, gated by onlyOwner (state-changing) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Publishes and requests execution through Wormhole, refunding the excess to the caller. Overrides or is overridden in: OutboundBase. | TransceiverBase._sendBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Quotes Core's fee plus execution price for the recipient's route. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, TransceiverBase._quoteBootstrap, TransceiverBase._reportReceiver; also tests | No |
| `executeVAAv1(multiSigVaa)`<br>_external payable_ | Anyone submits a VAA; the base's origin check is the only sender check. | tests only | Yes, anyone (state-changing) |
| `vaaConsumed(vaaHash)`<br>_external view_ | Whether a VAA hash has already been consumed. | tests only | Yes, anyone (read-only) |

Private helpers: `__WormholeTransceiver_init`, `_route`.


#### `contracts/evm/src/protocols/wormhole/WormholeTransmitter.sol`

Per-user sender-only Wormhole transmitter, which is the emitter its receivers authenticate.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Stores the Core bridge and Executor (both nonzero). | tests only | No (constructor) |
| `_sendMessage(recipient, payload, attributes, value)`<br>_internal_ | Sends through `WormholeMessage.send` for the recipient's route, refunding to `_refundTo`. Overrides or is overridden in: OutboundBase. | SignedTransmitter._sendRelay, TransmitterBase._sendFundedMessage, TransmitterBase._sendBootstrap; also tests | No |
| `_quoteMessage(recipient, payload, attributes)`<br>_internal view_ | Quotes Core's fee plus execution price for the recipient's route. Overrides or is overridden in: OutboundBase. | OutboundBase.quoteMessage, SignedTransmitter._quoteStandalone, SignedTransmitter._relay, TransmitterBase.quoteMessageBreakdown, TransmitterBase._quoteBootstrap; also tests | No |
| `supportsAttribute(selector)`<br>_external pure_ | Accepts the Wormhole execution and publish-only attributes. Declared in: IERC7786GatewaySource. | tests only | Yes, anyone (read-only) |

Private helpers: `_route`.


### `contracts/evm/src/registry`

#### `contracts/evm/src/registry/ChainRegistry.sol`

Per-chain, owner-governed directory of the chains this chain talks to, the message providers deployed here, and what can be known or derived about addresses on each chain.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Sets the owner (the chain's timelock) and seeds the current deployer, the governor's home chain and its providers (marked live there) through the same write-once setters the owner uses later. | tests only | No (constructor) |
| `addChainKey(identifier, provenance)`<br>_external_ | Registers a chain by its ERC-7930 chain identifier with a write-once provenance grade and returns its key. | tests only | Yes, gated by onlyOwner (state-changing) |
| `removeChainKey(chainKey)`<br>_external_ | Drops a chain from onboarding (no new counterpart can be recorded there) while keeping its identifier and grade. | tests only | Yes, gated by onlyOwner (state-changing) |
| `setSuspended(chainKey, suspended)`<br>_external_ | Makes every transceiver here refuse a chain, or lifts the refusal. | tests only | Yes, gated by onlyOwner (state-changing) |
| `isSuspended(chainKey)`<br>_external view_ | Whether transceivers refuse the chain. | tests only | Yes, anyone (read-only) |
| `addMessageProvider(name)`<br>_external_ | Registers a provider by name; its key is `keccak256(name)`. | tests only | Yes, gated by onlyOwner (state-changing) |
| `removeMessageProvider(messageProvider)`<br>_external_ | Removes a provider and its name from the directory; reverts for an unknown provider. | none found | Yes, gated by onlyOwner (state-changing) |
| `setLocalTransceiver(messageProvider, transceiver_)`<br>_external_ | Records (or with zero retires) the transceiver on this chain that serves one provider. | tests only | Yes, gated by onlyOwner (state-changing) |
| `setProviderDeployment(messageProvider, salt, proxyInitCodeHash)`<br>_external_ | Records, write-once, the CREATE2 salt and proxy initcode hash a provider's contracts share on every chain. | tests only | Yes, gated by onlyOwner (state-changing) |
| `providerDeployment(messageProvider)`<br>_external view_ | Reads a provider's recorded CREATE2 salt and initcode hash. | TransceiverBase._conduitUnder; also tests | Yes, anyone (read-only) |
| `setCurrentDeployer(deployer)`<br>_external_ | Sets the deployer account that later `addProviderOnChain` calls must name. | tests only | Yes, gated by onlyOwner (state-changing) |
| `addProviderOnChain(chainKey, messageProvider, expectedDeployer)`<br>_external_ | Records, write-once, which deployer deploys a provider's transceiver on a chain, in `Pending` state. | tests only | Yes, gated by onlyOwner (state-changing) |
| `rekeyPending(chainKey, messageProvider, newDeployer)`<br>_external_ | Changes the deployer a `Pending` entry is predicted under, for a chain added before a deployer rotation. | tests only | Yes, gated by onlyOwner (state-changing) |
| `markLive(chainKey, messageProvider)`<br>_external_ | Allows sends to a provider's transceiver on a chain once its deployment has been checked. | tests only | Yes, gated by onlyOwner (state-changing) |
| `isLive(chainKey, messageProvider)`<br>_external view_ | Whether sends to a provider's transceiver on a chain are allowed. | TransceiverBase.isLive; also tests | Yes, anyone (read-only) |
| `statusOf(chainKey, messageProvider)`<br>_external view_ | The provider's deployment status on a chain. | tests only | Yes, anyone (read-only) |
| `deployedBy(chainKey, messageProvider)`<br>_external view_ | The deployer recorded for a provider's transceiver on a chain. | tests only | Yes, anyone (read-only) |
| `predictTransceiver(chainKey, messageProvider)`<br>_public view_ | Recomputes where a provider's transceiver lands on a chain from the proxy deployer, recorded deployer, salt and initcode hash. | ChainRegistry.predictConduit; also tests | Yes, anyone (read-only) |
| `predictConduit(chainKey, messageProvider, owner, salt, homeChainKey)`<br>_external view_ | Recomputes where an owner's conduit lands on a chain (transceiver first, then conduit salt). | tests only | Yes, anyone (read-only) |
| `provenanceFor(chainKey)`<br>_public view_ | The provenance grade registered for a chain. | TransceiverBase._bootstrapInbound, TransceiverBase._signedBootstrapInbound, TransceiverExtension._recordCounterpart, ChainRegistry._isEvmDerivable; also tests | Yes, anyone (read-only) |
| `isReceiverCallbackRequired(chainKey)`<br>_external view_ | Whether conduits on a chain must report their own address home because this registry cannot recompute it. | TransceiverBase._onDestinationReceiver, TransceiverBase.reportsReceiver; also tests | Yes, anyone (read-only) |
| `requireLocation(chainKey, interop)`<br>_external view_ | Requires a canonical ERC-7930 envelope for the registered chain and runs its validator if configured. A chain identifier with an empty address can pass when no validator is configured. | TransceiverExtension._recordCounterpart; also tests | Yes, anyone (read-only) |
| `setValidator(chainKey, validator)`<br>_external_ | Attaches a value-range validator to a chain. | tests only | Yes, gated by onlyOwner (state-changing) |
| `setQualifier(chainKey, messageProvider, q)`<br>_external_ | Attaches a write-once Move qualified name to a provider's transceiver on a Move chain. | tests only | Yes, gated by onlyOwner (state-changing) |
| `qualifier(chainKey, messageProvider)`<br>_external view_ | Reads the Move qualifier for a provider on a chain. | tests only | Yes, anyone (read-only) |
| `setCommitmentScheme(chainKey, scheme)`<br>_external_ | Sets (or with zero clears) the commitment hash plugin for a chain. | tests only | Yes, gated by onlyOwner (state-changing) |
| `commitmentFor(chainKey, elements)`<br>_external view_ | Previews the commitment a chain's receiver will require over a list of elements. | tests only | Yes, anyone (read-only) |
| `setDeriver(chainKey, deriver)`<br>_external_ | Points a chain at the deriver contract that computes addresses on it. | tests only | Yes, gated by onlyOwner (state-changing) |
| `setDeriveParams(chainKey, params)`<br>_external_ | Stores the derivation inputs for a chain after checking them against its deriver. | tests only | Yes, gated by onlyOwner (state-changing) |
| `expectedTransceiver(chainKey)`<br>_public view_ | Recomputes the transceiver envelope expected on a chain, whatever VM it runs. | TransceiverExtension.resolveCounterpart, ChainRegistry.expectedTransceivers; also tests | Yes, anyone (read-only) |
| `expectedTransceivers()`<br>_external view_ | Returns the expected transceiver for every registered chain, with empty entries where underivable. | tests only | Yes, anyone (read-only) |
| `deriveParams(chainKey)`<br>_external view_ | Reads the stored derivation inputs for a chain. | TransceiverExtension.resolveCounterpart | Yes, anyone (read-only) |
| `localTransceiver(messageProvider)`<br>_external view_ | Reads this chain's transceiver for a provider. | tests only | Yes, anyone (read-only) |
| `providerOfTransceiver(transceiver_)`<br>_external view_ | Reads which provider a local transceiver serves. | none found | Yes, anyone (read-only) |
| `deriverOf(chainKey)`<br>_external view_ | Reads a chain's deriver contract. | none found | Yes, anyone (read-only) |
| `validatorOf(chainKey)`<br>_external view_ | Reads a chain's validator contract. | none found | Yes, anyone (read-only) |
| `commitmentSchemeOf(chainKey)`<br>_external view_ | Reads a chain's commitment plugin. | tests only | Yes, anyone (read-only) |
| `chainKeyCount()`<br>_external view_ | Number of registered chains. | tests only | Yes, anyone (read-only) |
| `chainKeyAt(i)`<br>_external view_ | Chain key at an index. | none found | Yes, anyone (read-only) |
| `chainKeys()`<br>_external view_ | All registered chain keys. | none found | Yes, anyone (read-only) |
| `hasChainKey(chainKey)`<br>_external view_ | Whether a chain is registered. | tests only | Yes, anyone (read-only) |
| `chainIdentifier(chainKey)`<br>_external view_ | The ERC-7930 chain identifier a key hashes from. | tests only | Yes, anyone (read-only) |
| `messageProviderCount()`<br>_external view_ | Number of registered providers. | none found | Yes, anyone (read-only) |
| `messageProviderAt(i)`<br>_external view_ | Provider key at an index. | none found | Yes, anyone (read-only) |
| `messageProviders()`<br>_external view_ | All provider keys. | none found | Yes, anyone (read-only) |
| `hasMessageProvider(messageProvider)`<br>_external view_ | Whether a provider is registered. | none found | Yes, anyone (read-only) |
| `messageProviderName(messageProvider)`<br>_external view_ | Name a provider key was registered under. | none found | Yes, anyone (read-only) |

Private helpers: `_addChainKey`, `_addMessageProvider`, `_addProviderOnChain`, `_isEvmDerivable`, `_requireEvmDerivable`, `_setCurrentDeployer`, `_setProviderDeployment`.


#### `contracts/evm/src/registry/IChainRegistryRefs.sol`

Interface of the slice of `ChainRegistry` a transceiver reads: grades, suspension, derived counterpart addresses, location validation and deployment records.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `provenanceFor(chainKey)`<br>_external view_ | Provenance grade of a chain. | TransceiverBase._bootstrapInbound, TransceiverBase._signedBootstrapInbound, TransceiverCore._counterpartOn, TransceiverExtension._recordCounterpart; also tests | Yes via interface (read-only) |
| `isSuspended(chainKey)`<br>_external view_ | Whether transceivers refuse a chain. | TransceiverCore._counterpartOn; also tests | Yes via interface (read-only) |
| `expectedTransceiver(chainKey)`<br>_external view_ | The transceiver envelope the registry recomputes for a chain. | TransceiverExtension.resolveCounterpart; also tests | Yes via interface (read-only) |
| `providerDeployment(messageProvider)`<br>_external view_ | A provider's shared CREATE2 inputs. | TransceiverBase._conduitUnder; also tests | Yes via interface (read-only) |
| `predictTransceiver(chainKey, messageProvider)`<br>_external view_ | Where a provider's transceiver lands on a chain. | TransceiverCore._parityAddress; also tests | Yes via interface (read-only) |
| `isLive(chainKey, messageProvider)`<br>_external view_ | Whether sends to a provider's transceiver on a chain are allowed. | TransceiverBase.isLive; also tests | Yes via interface (read-only) |
| `deployedBy(chainKey, messageProvider)`<br>_external view_ | Who deployed or will deploy a provider's transceiver on a chain. | tests only | Yes via interface (read-only) |
| `currentDeployer()`<br>_external view_ | The deployer new provider entries are recorded under. | tests only | Yes via interface (read-only) |
| `chainIdentifier(chainKey)`<br>_external view_ | The ERC-7930 chain identifier behind a chain key. | tests only | Yes via interface (read-only) |
| `requireLocation(chainKey, interop)`<br>_external view_ | Requires a canonical ERC-7930 envelope for the registered chain and applies its configured validator, if any. Without a validator, the envelope may be a chain identifier with an empty address. | TransceiverExtension._recordCounterpart; also tests | Yes via interface (read-only) |
| `deriveParams(chainKey)`<br>_external view_ | The derivation inputs recorded for a chain. | TransceiverExtension.resolveCounterpart | Yes via interface (read-only) |
| `isReceiverCallbackRequired(chainKey)`<br>_external view_ | Whether conduits on a chain must report their own address home. | TransceiverBase._onDestinationReceiver, TransceiverBase.reportsReceiver; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/registry/ICommitmentScheme.sol`

Interface for a chain's commitment hash primitive, plus the `SchemeFold` library that folds elements through a plugin's primitive for previews.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash(data)`<br>_ICommitmentScheme · external view_ | The destination chain's hash of the data, which must match the primitive its receiver applies. Implemented in: Blake2bScheme, KeccakScheme, Sha256Scheme. | SchemeFold.hashCalls; also tests | Yes via interface (read-only) |
| `hashCalls(scheme, destinationChainKey, elements)`<br>_SchemeFold · internal view_ | Folds call elements through a scheme's hash, seeded with the destination chain key, as the destination receiver would. | ChainRegistry.commitmentFor; also tests | No |


#### `contracts/evm/src/registry/IRefValidator.sol`

Interface for the registry's per-chain value-range check on an address.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireRef(interop)`<br>_external view_ | Reverts if the canonical ERC-7930 address is outside what the chain allows. Implemented in: MoveValidator, StarknetValidator. | ChainRegistry.requireLocation; also tests | Yes via interface (read-only) |


#### `contracts/evm/src/registry/Provenance.sol`

Enum grading how much this chain can know about an address on another chain (`Unknown`, `Unique`, `Predetermined`).

_Declares no functions._


### `contracts/evm/src/schemes`

#### `contracts/evm/src/schemes/Blake2bScheme.sol`

Commitment scheme using BLAKE2b-256 (Cardano), the one scheme that cannot be `pure`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash(data)`<br>_external view_ | Returns the BLAKE2b-256 hash of the data. Declared in: ICommitmentScheme. | SchemeFold.hashCalls; also tests | Yes, anyone (read-only) |


#### `contracts/evm/src/schemes/KeccakScheme.sol`

Commitment scheme using keccak256, the primitive every EVM destination uses and the control case of the plugin path.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash(data)`<br>_external pure_ | Returns the keccak256 hash of the data. Declared in: ICommitmentScheme. | SchemeFold.hashCalls; also tests | Yes, anyone (read-only) |


#### `contracts/evm/src/schemes/Sha256Scheme.sol`

Commitment scheme using SHA-256 (TON).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `hash(data)`<br>_external pure_ | Returns the SHA-256 hash of the data. Declared in: ICommitmentScheme. | SchemeFold.hashCalls; also tests | Yes, anyone (read-only) |


### `contracts/evm/src/treasury`

#### `contracts/evm/src/treasury/Treasury.sol`

Ownable contract where a chain's outbound fees, bootstrap fees and report float land, and the only place that can move them out.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `withdraw(amount)`<br>_IReportFloat · external_ | Transceiver-side call that pays the float to the transceiver's treasury. | Treasury.collect; also tests | Yes via interface (state-changing) |
| `constructor`<br>_Treasury · constructor_ | Sets the treasury owner. | tests only | No (constructor) |
| `receive`<br>_Treasury · external payable_ | Accepts native fees sent with a plain call. | tests only | Yes (plain call) |
| `collect(from, amount)`<br>_Treasury · external_ | Owner pulls an amount of a transceiver's report float into the treasury. | tests only | Yes, gated by onlyOwner (state-changing) |
| `withdraw(to, amount)`<br>_Treasury · external_ | Owner sends native currency out. | tests only | Yes, gated by onlyOwner (state-changing) |
| `withdrawERC20(token, to, amount)`<br>_Treasury · external_ | Owner sends an ERC-20 out using `SafeERC20`. | tests only | Yes, gated by onlyOwner (state-changing) |


### `contracts/evm/src/validators`

#### `contracts/evm/src/validators/MoveValidator.sol`

Per-chain reference validator that enforces the fixed 32-byte Move address width.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireRef(interop)`<br>_external pure_ | Reverts unless the interop reference is a canonical 32-byte Move address. Declared in: IRefValidator. | ChainRegistry.requireLocation; also tests | Yes, anyone (read-only) |


#### `contracts/evm/src/validators/StarknetValidator.sol`

Per-chain reference validator that rejects Starknet addresses no contract can occupy.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireRef(interop)`<br>_external pure_ | Reverts if the Starknet address is out of range. Declared in: IRefValidator. | ChainRegistry.requireLocation; also tests | Yes, anyone (read-only) |



## Safe guard contracts: `contracts/safe-guard/src`

### `contracts/safe-guard/src` (top level)

#### `contracts/safe-guard/src/CrossecuteGuard.sol`

Safe 1.5.0 transaction (and optional module) guard, shared by many Safes, that stages each owner-signed `sendMessage` or `bootstrap` for the signed target to consume, caches child-Safe approvals and publishes Merkle leaves, on top of the inherited policy and authority engines.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Configures the authority engine's pinned contracts; policy delay and expiry are set per Safe. Overrides or is overridden in: SourceAuthorityGuard. | SourceAuthorityGuard.constructor; also tests | No (constructor) |
| `configurationTiming(safe)`<br>_public view_ | The policy request delay and expiry for a Safe: its recorded timing, or no delay and no expiry before one is set (overrides the policy engine's hook). | tests only | Yes, anyone (read-only) |
| `configureTimingImmediately(delay, expiry)`<br>_external_ | Sets the caller's delay and expiry at once while this guard is in neither of its Safe guard slots; reverts if the delay exceeds 365 days or the expiry is zero. | tests only | Yes, a Safe for its own timing (state-changing) |
| `timingConfigurationRoot(delay, expiry)`<br>_public pure_ | The root to pass to `requestConfiguration` for a change to a delay and expiry. | CrossecuteGuard.applyConfigurationTiming; also tests | Yes, anyone (read-only) |
| `applyConfigurationTiming(delay, expiry)`<br>_external_ | Applies the caller's matured timing request, with the same bounds as the immediate path. | CrossecuteGuard._isConfigurationSelector; also tests | Yes, a Safe for its own timing (state-changing) |
| `supportsInterface(interfaceId)`<br>_external pure_ | ERC-165: advertises the Crossecute guard interface alongside the inherited ones. | CcipReceiver.supportsInterface; also tests | Yes, anyone (read-only) |
| `consume(safe)`<br>_external_ | Marks a Safe's live staged record consumed and returns the signed Safe transaction; only the signed target may call it, once per record. Declared in: ICrossecuteGuard. | SignedTransmitterLib.consumeStaged, SignedTransmitterLib._consume; also tests | Yes, anyone (state-changing) |
| `getApproval(childSafe, messageHash)`<br>_external view_ | Returns the approval evidence a child Safe cached for a message hash, reverting if none. Declared in: ICrossecuteGuard. | NestedApprovalCollector._approval; also tests | Yes, anyone (read-only) |
| `publishLeaves(leaves)`<br>_external_ | Records the Merkle root of a leaf list and emits an event per leaf; anyone may call. Declared in: ICrossecuteGuard. | SignedDispatch.publishLeavesCalldata, SDK ts/signed.publishLeavesCalldata; also tests | Yes, anyone (state-changing) |
| `isPublished(root)`<br>_external view_ | Whether a root was recorded by `publishLeaves`. Declared in: ICrossecuteGuard. | SignedTransmitter.registerRoot; also tests | Yes, anyone (read-only) |
| `_executionLive(safe)`<br>_internal view_ | Reads the transient-storage marker that says a Safe owner execution is in flight (overrides the authority engine's hook). Overrides or is overridden in: SourceAuthorityGuard. | CrossecuteGuard._afterOwnerPolicyCheck, CrossecuteGuard._afterModulePolicyCheck, SourceAuthorityGuard.stageUpdate | No |

Private helpers: `_afterModulePolicyCheck`, `_afterOwnerExecution`, `_afterOwnerPolicyCheck`, `_allowedCalls`, `_approvalSignatures`, `_cacheApproval`, `_executionId`, `_isConfigurationSelector`, `_isStaged`, `_safeId`, `_safeTx`, `_setConfigurationTiming`, `_tloadSignedSafeTx`, `_tstoreSignatures`, `_tstoreSignedSafeTx`.


#### `contracts/safe-guard/src/GuardDiscovery.sol`

Library that finds a Safe's installed transaction guard by reading the guard storage slot through `getStorageAt`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `transactionGuard(safe)`<br>_internal view_ | Returns the Safe's installed guard, reverting unless the slot holds exactly one address with code (no unsigned fallback). | SignedTransmitter.registerRoot, SignedTransmitterLib.consumeStaged, SignedTransmitterLib._bootstrapAuthority, SignedTransmitterLib.authority, SignedTransmitterLib._consume, NestedApprovalCollector._approval; also tests | No |
| `storageWord(safe, slot)`<br>_internal view_ | Reads one strictly decoded storage word of a Safe through `getStorageAt`. | SourceAuthorityGuard._requireSupportedConfiguration | No |


#### `contracts/safe-guard/src/ICrossecuteGuard.sol`

Interface of what a transmitter consumes from the guard and a relayer reads from it, advertised through ERC-165.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `consume(safe)`<br>_external_ | Marks a Safe's live staged record consumed and returns it. Implemented in: CrossecuteGuard. | SignedTransmitterLib.consumeStaged, SignedTransmitterLib._consume; also tests | Yes via interface (state-changing) |
| `getApproval(childSafe, messageHash)`<br>_external view_ | Returns the child Safe's cached approval evidence for a message hash. Implemented in: CrossecuteGuard. | NestedApprovalCollector._approval; also tests | Yes via interface (read-only) |
| `publishLeaves(leaves)`<br>_external_ | Records the Merkle root of the leaves and emits `LeafPublished` per leaf. Implemented in: CrossecuteGuard. | SignedDispatch.publishLeavesCalldata, SDK ts/signed.publishLeavesCalldata; also tests | Yes via interface (state-changing) |
| `isPublished(root)`<br>_external view_ | Whether a root has been published on this guard. Implemented in: CrossecuteGuard. | SignedTransmitter.registerRoot; also tests | Yes via interface (read-only) |


#### `contracts/safe-guard/src/SafeBatchExecutor.sol`

Contract that runs several separately signed Safe transactions in one outer transaction, all or nothing.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `execTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, signatures)`<br>_ISafeExec · external payable_ | Safe 1.5.0's `execTransaction`, used by the executor and checked for a `false` return. | SafeBatchExecutor.execute; also tests | Yes via interface (state-changing) |
| `execute(executions)`<br>_SafeBatchExecutor · external_ | Executes the signed Safe transactions in order and reverts the whole batch if any fails or returns false. | SDK ts/signed.safeBatchCalldata; also tests | Yes, anyone (state-changing) |


#### `contracts/safe-guard/src/SafeHashes.sol`

Library that computes Safe 1.5.0's EIP-712 transaction and message hashes without calling the Safe.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `transactionHash(safeTx, safe, chainId)`<br>_internal pure_ | The hash a Safe on a given chain returns from `getTransactionHash` for a Safe transaction. | ReceiverAuthority.requireEvidence, ReceiverAuthority.requireActivation, ReceiverAuthority._requireUpdate, ReceiverAuthority._proveChildUpdate, SignedTransmitterLib.authority, SignedTransmitterLib._collect, SafeSignaturesUtils.approvalHash, CrossecuteGuard._afterOwnerPolicyCheck, CrossecuteGuard._tstoreSignedSafeTx, SourceAuthorityGuard._authorityPreHook; also tests | No |
| `messageHash(message, safe, chainId)`<br>_internal pure_ | The hash `SignMessageLib.signMessage` writes into a Safe's `signedMessages` for a message. | SafeSignaturesUtils.nestedHash, CrossecuteGuard._afterOwnerPolicyCheck; also tests | No |

Private helpers: `domainSeparator`.


### `contracts/safe-guard/src/authority`

#### `contracts/safe-guard/src/authority/AuthorityUpdateTypes.sol`

Struct definitions for a source Safe's selected authority graph (`AuthoritySelection`) and for what an ownership change or selection signs (`AuthorityUpdate`).

_Declares no functions._


#### `contracts/safe-guard/src/authority/ISourceAuthorityGuard.sol`

Interface of the source-authority operations (activate, ownership change, select, stage) and reads the guard implements.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `publishedAuthority(sourceSafe, updateHead)`<br>_external view_ | Hash of the exact published authority submission for a source Safe and update head, or zero. | SignedTransmitterLib.authority, SDK ts/authority.AuthoritySource.publishedHash; also tests | Yes via interface (read-only) |
| `stageUpdate(sourceSafe, currentGraph, newGraph, childUpdates, portableSignatures, nestedApprovals)`<br>_external_ | Lets anyone supply the current graph, new graph, child updates and signatures the next activation or update commits to, held for the current transaction only. Implemented in: SourceAuthorityGuard. | SDK ts/authority.authorityExecution; also tests | Yes via interface (state-changing) |
| `activate(authorityHash)`<br>_external_ | A Safe's first authority update, signed by its quorum after installing the guard. Implemented in: SourceAuthorityGuard. | AuthorityRecognition.recognize, CrossecuteGuard._allowedCalls, SourceAuthorityGuard._isAuthorityCall, SDK ts/authority.buildAuthorityProposal; also tests | Yes via interface (state-changing) |
| `registerOwnershipChange(update)`<br>_external_ | First call of a one-transaction ownership change, followed by the ordered owner self-calls. Implemented in: SourceAuthorityGuard. | AuthorityUpdateEncoding.ownershipBatchData, AuthorityUpdateEncoding.decodeOwnershipBatch, AuthorityUpdateEncoding.isOwnershipBatch, CrossecuteGuard._allowedCalls, SDK ts/authority.buildAuthorityProposal; also tests | Yes via interface (state-changing) |
| `selectAuthority(update)`<br>_external_ | Authorizes a full authority graph replacement without changing root ownership. Implemented in: SourceAuthorityGuard. | AuthorityRecognition.recognize, CrossecuteGuard._allowedCalls, SourceAuthorityGuard._isAuthorityCall, SDK ts/authority.buildAuthorityProposal; also tests | Yes via interface (state-changing) |
| `selection(sourceSafe)`<br>_external view_ | A source Safe's selected authority hash and update head. Implemented in: SourceAuthorityGuard. | SignedTransmitterLib._bootstrapAuthority, SDK ts/authority.AuthoritySource.selection; also tests | Yes via interface (read-only) |
| `executed(sourceSafe, updateHead)`<br>_external view_ | Whether an update head is a position the source Safe executed on this chain. Implemented in: SourceAuthorityGuard. | tests only | Yes via interface (read-only) |


#### `contracts/safe-guard/src/authority/SourceAuthorityGuard.sol`

Abstract guard half that holds per-Safe authority state, activation and linked updates, and keeps an activated Safe's live owners equal to its selected root record.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `constructor`<br>_constructor_ | Sets the pinned contracts the authority rules check against. Overrides or is overridden in: CrossecuteGuard. | CrossecuteGuard.constructor; also tests | No (constructor) |
| `selection(sourceSafe)`<br>_external view_ | A source Safe's selected authority hash and update head. Declared in: ISourceAuthorityGuard. | SignedTransmitterLib._bootstrapAuthority, SDK ts/authority.AuthoritySource.selection; also tests | Yes, anyone (read-only) |
| `executed(sourceSafe, updateHead)`<br>_external view_ | Whether an update head is a position the Safe executed on this chain. Declared in: ISourceAuthorityGuard. | tests only | Yes, anyone (read-only) |
| `stageUpdate(sourceSafe, currentGraph, newGraph, childUpdates, portableSignatures, nestedApprovals)`<br>_external_ | Stages an update's graphs and signatures in transient storage; rejected during an owner execution, and a later stage replaces an earlier unconsumed one. Declared in: ISourceAuthorityGuard. | SDK ts/authority.authorityExecution; also tests | Yes, anyone (state-changing) |
| `activate(bytes32)`<br>_external view_ | Call target with no effect of its own: reverts unless the guard's pre-hook already marked this Safe transaction as an activation. Declared in: ISourceAuthorityGuard. | AuthorityRecognition.recognize, CrossecuteGuard._allowedCalls, SourceAuthorityGuard._isAuthorityCall, SDK ts/authority.buildAuthorityProposal; also tests | Yes, anyone (read-only) |
| `registerOwnershipChange(AuthorityUpdate)`<br>_external view_ | Call target with no effect of its own: reverts unless the pre-hook marked this Safe transaction as an ownership change. Declared in: ISourceAuthorityGuard. | AuthorityUpdateEncoding.ownershipBatchData, AuthorityUpdateEncoding.decodeOwnershipBatch, AuthorityUpdateEncoding.isOwnershipBatch, CrossecuteGuard._allowedCalls, SDK ts/authority.buildAuthorityProposal; also tests | Yes, anyone (read-only) |
| `selectAuthority(AuthorityUpdate)`<br>_external view_ | Call target with no effect of its own: reverts unless the pre-hook marked this Safe transaction as an authority selection. Declared in: ISourceAuthorityGuard. | AuthorityRecognition.recognize, CrossecuteGuard._allowedCalls, SourceAuthorityGuard._isAuthorityCall, SDK ts/authority.buildAuthorityProposal; also tests | Yes, anyone (read-only) |
| `_executionLive(safe)`<br>_internal view_ | Hook the host guard overrides to say whether an owner execution is live for a Safe. Overrides or is overridden in: CrossecuteGuard. | CrossecuteGuard._afterOwnerPolicyCheck, CrossecuteGuard._afterModulePolicyCheck, SourceAuthorityGuard.stageUpdate | No |
| `_activated(safe)`<br>_internal view_ | Whether a Safe has completed authority activation. | CrossecuteGuard._afterOwnerPolicyCheck; also tests | No |
| `_authorityPreHook(safeTx)`<br>_internal_ | Pre-execution check of an owner transaction: recognizes activation, ownership change or selection, and confines other transactions of an activated Safe to calls that cannot change its owners. | CrossecuteGuard._afterOwnerPolicyCheck | No |
| `_authorityPostHook(txHash)`<br>_internal_ | Post-execution check that the executed transaction was the recognized one and the Safe's final owners and threshold match the selected record, else the Safe transaction reverts. | CrossecuteGuard._afterOwnerExecution | No |
| `_tload(id, offset)`<br>_internal view_ | Reads a word from the guard's transient-storage record. | CrossecuteGuard.consume, CrossecuteGuard._afterOwnerExecution, CrossecuteGuard._tloadSignedSafeTx, CrossecuteGuard._executionLive, SourceAuthorityGuard._authorityLive, SourceAuthorityGuard._authorityPostHook, SourceAuthorityGuard._requireMarker, SourceAuthorityGuard._tloadBytes; also tests | No |
| `_tstore(id, offset, value)`<br>_internal_ | Writes a word to the guard's transient-storage record. | CrossecuteGuard.consume, CrossecuteGuard._afterOwnerPolicyCheck, CrossecuteGuard._tstoreSignedSafeTx, CrossecuteGuard._afterOwnerExecution, CrossecuteGuard._tstoreSignatures, SourceAuthorityGuard._authorityPostHook, SourceAuthorityGuard._tstoreLive, SourceAuthorityGuard._tstoreBytes | No |

Private helpers: `_authorityLive`, `_consumeStage`, `_isAuthorityCall`, `_liveId`, `_liveRecord`, `_ownersHash`, `_recordOwnersHash`, `_requireInsideProtectedCalls`, `_requireMarker`, `_requireNamedPositionsExecuted`, `_requireSupportedConfiguration`, `_stageId`, `_tloadBytes`, `_tstoreBytes`, `_tstoreLive`.



## Other tooling

### Protocol tooling scripts (not Solidity)

None of these define functions that other code calls. Helper functions inside a script are private to it, so they are not listed.

| File | What it is | How it is used |
|---|---|---|
| `contracts/evm/script/check-selectors.sh` | Fails if a transceiver declares a selector that a `TransceiverExtension` declares under a different signature. | CI and developers, after `forge build`. |
| `contracts/evm/script/vendor/lib.sh` | Defines `vendor_file(repo, commit, upstream_path, dest_path, license_note)`, which fetches one pinned upstream file and adds a provenance header. | Sourced by `ccip.sh`, `hyperlane.sh`, `layerzero.sh`, `op-stack.sh` and `wormhole.sh`. Not run directly. |
| `contracts/evm/script/vendor/ccip.sh`, `hyperlane.sh`, `layerzero.sh`, `op-stack.sh`, `wormhole.sh` | Each re-vendors the pinned provider interfaces and libraries one binding depends on. | Run by a developer when bumping a provider commit. |
| `contracts/evm/script/vendor/ccip-test.sh` | Reproduces the pinned CCIP integration binaries without running package scripts. | Run from the command line. |
| `contracts/evm/npm/pack.mjs` | Builds the publishable npm tree: every `src/` file whose imports stay inside `src/`, OpenZeppelin and the guard, rewritten to relative imports, plus the shipped ABIs. | Run from `contracts/evm` after `forge build`. |
| `contracts/evm/npm/check-consumer.sh` | Packs `@crossecute/protocol` and compiles every shipped source from a fresh project, so an unresolvable import fails. | Run from `contracts/evm` after `forge build`. |
| `contracts/evm/test/eravm/era-delivery-gas.sh` | Measures on a local EraVM node the smallest gas limit a delivery to a zkSync transceiver needs, which is the value `DeliveryGas` sets. | Run by hand when refreshing delivery gas. |
| `contracts/evm/test/protocols/ccip/native-compile.py` | Compiles the CCIP implementation targets with an explicitly supplied native compiler. | Run from the command line. |
| `contracts/safe-guard/script/lint.py` | Runs Forge lint with canonical import paths across the two Foundry projects. | Run from the command line. |
| `docs/vectors/check-safe-authority-updates-109.py` | Generates and checks offline Safe hash vectors, receiver vectors and semantic cases for the authority updates. | Run from the command line. |
| `docs/benchmarks/authority-109/run.py`, `measure-updates.py` | Run the isolated baseline benchmark offline and measure current authority operations. | Run from the command line. |
| `tools/authority-archive/archive.py` (`put-graph`, `get-graph`, `put-submission`, `get-chain`) | Offline, content-checked archive of authority graphs and published submissions, never sending transactions. | Run from the command line; `test_archive.py` tests it. |


# Part 3: SDK (`crossecute/sdk`)

## Foundry library: `contracts`

### `contracts` (top level)

#### `contracts/ISafe.sol`

Interface of the Safe views the SDK reads (`VERSION`, `nonce`, `getTransactionHash`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `VERSION()`<br>_external view_ | The Safe's version string, used to pick the MultiSendCallOnly. | none found | Safe's own function (read-only); SDK reads it |
| `nonce()`<br>_external view_ | The Safe's current nonce. | CrossecuteGuard._safeTx; also tests | Safe's own function (read-only); SDK reads it |
| `getTransactionHash(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, nonce)`<br>_external view_ | The Safe's own hash for a transaction, used to cross-check the SDK's computed hash. | tests only | Safe's own function (read-only); SDK reads it |


#### `contracts/LzDvn.sol`

Library plus LayerZero interfaces that detect whether a sender's send config requires LayerZero's dead DVN, which would make every quote and send revert.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `messageProvider()`<br>_ILzConduitTransceiver · external view_ | The provider key the transceiver serves, compared with `keccak256("layerzero")` to detect a native LayerZero conduit. | LzDvn.isDeadDvnRequired; also tests | LayerZero conduit's own function (read-only) |
| `providerIdFor(chainKey)`<br>_ILzConduitTransceiver · external view_ | The LayerZero endpoint id for a chain key. | LzDvn.isDeadDvnRequired; also tests | LayerZero conduit's own function (read-only) |
| `endpoint()`<br>_ILzConduit · external view_ | The conduit's LayerZero endpoint. | LzOftConduitFactory._authenticateBootstrap, LzOftConduitFactory._homeEid, LzOftReceiver.initialize, LzDvn.isDeadDvnRequired; also tests | LayerZero conduit's own function (read-only) |
| `getSendLibrary(sender, eid)`<br>_ILzSendConfig · external view_ | The send library an OApp uses toward an endpoint id. | LzDvn.isDeadDvnRequired; also tests | LayerZero endpoint function (read-only) |
| `getConfig(oapp, lib, eid, configType)`<br>_ILzSendConfig · external view_ | The send ULN config of an OApp, library and endpoint id. | LzDvn.isDeadDvnRequired; also tests | LayerZero endpoint function (read-only) |
| `isDeadDvnRequired(transceiver, sender, chainId)`<br>_LzDvn · internal view_ | For a native `layerzero` conduit, whether the sender's send ULN config toward a chain lists the dead DVN as required, and the destination's LayerZero eid. | tests only | Yes, from a Foundry script |


#### `contracts/LzOft.sol`

Foundry builders for the `layerzero-oft` conduit binding: options attribute, destination leaf hashes and root, `createTransmitter` calldata and conduit address prediction.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `createTransmitter(salt, homeOft, leaves)`<br>_ILzOftCreate · external_ | The factory's creation entry point, declared so calldata and selector can be built and checked against the pinned ABI. | LzOft.createTransmitterCalldata; also tests | Yes, owner Safe calls it on the factory |
| `optionsAttribute(rawOptions)`<br>_LzOft · internal pure_ | Builds the only attribute a `layerzero-oft` conduit accepts, carrying raw options that replace the default compose option. | tests only | Yes, from a Foundry script |
| `leafHash(leaf)`<br>_LzOft · internal pure_ | Hash of one destination leaf, as `LzOftMessage.leaf` computes it. | LzOft.root; also tests | Yes, from a Foundry script |
| `requireLeaves(leaves)`<br>_LzOft · internal pure_ | Offline form of the factory's leaf checks: at least one leaf, strictly ascending chain key, nonzero eid and OFT; the second overload also rejects a leaf naming the home chain key or eid. | LzOft.root, LzOft.createTransmitterCalldata | Yes, from a Foundry script |
| `requireLeaves(leaves, homeChainKey, homeEid)`<br>_LzOft · internal pure_ | Offline form of the factory's leaf checks: at least one leaf, strictly ascending chain key, nonzero eid and OFT; the second overload also rejects a leaf naming the home chain key or eid. | LzOft.root, LzOft.createTransmitterCalldata | Yes, from a Foundry script |
| `root(leaves)`<br>_LzOft · internal pure_ | Merkle root of the destination leaves (ascending chain key), the `destRoot` bound into the conduit address; second overload adds the home-chain checks. | tests only | Yes, from a Foundry script |
| `root(leaves, homeChainKey, homeEid)`<br>_LzOft · internal pure_ | Merkle root of the destination leaves (ascending chain key), the `destRoot` bound into the conduit address; second overload adds the home-chain checks. | tests only | Yes, from a Foundry script |
| `createTransmitterCalldata(salt, homeOft, leaves)`<br>_LzOft · internal pure_ | Calldata for `createTransmitter`, which the owner Safe sends as a CALL. | tests only | Yes, from a Foundry script |
| `conduitSalt(owner, salt, homeChainKey, homeEid, homeOft, destRoot)`<br>_LzOft · internal pure_ | The conduit CREATE2 salt, matching `LzOftConduitFactory.conduitSalt`. | LzOft.predictConduit; also tests | Yes, from a Foundry script |
| `predictConduit(factory, owner, salt, homeChainKey, homeEid, homeOft, destRoot, proxyInitCodeHash)`<br>_LzOft · internal pure_ | The conduit address the factory at a given address will create, given the proxy initcode hash. | tests only | Yes, from a Foundry script |

Private helpers: `_check`.


#### `contracts/MerklePackage.sol`

Library that builds the Merkle package (root, each leaf's hash and proof) a signed `registerRoot` commits to, with the same plan rules as the TypeScript `buildMerklePackage`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireMerklePlan(leaves, receiverNonces)`<br>_internal pure_ | Reverts on a plan the receiver would refuse or that wastes a root (duplicate leaf, conflicting or stale nonces, missing or unused receiver nonces). | tests only | Yes, from a Foundry script |
| `build(leaves, receiverNonces)`<br>_internal pure_ | Checks the plan and returns the root plus each leaf's hash and proof in order. | tests only | Yes, from a Foundry script |
| `publishLeavesCalldata(pkg)`<br>_internal pure_ | Calldata for the guard's `publishLeaves` carrying the encoded leaves in package order. | tests only | Yes, from a Foundry script |
| `registerRootCalldata(pkg)`<br>_internal pure_ | Calldata for the transmitter's `registerRoot` for the owner Safe's signed transaction. | tests only | Yes, from a Foundry script |

Private helpers: `_indexOf`, `_leafHashes`, `_receiverKeys`.


#### `contracts/MerklePackageJson.sol`

Library that writes a `MerklePackage` as the JSON file the TypeScript SDK parses and signers review.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `toJson(pkg)`<br>_internal pure_ | Serializes a Merkle package with decimal-string integers, lowercase hex and the TypeScript field order. | tests only | Yes, from a Foundry script |

Private helpers: `_bytesArray`, `_entry`, `_receiverNonce`, `_wordArray`.


#### `contracts/PlanJson.sol`

Library that serializes a plan as a Safe Transaction Builder batch, the plan file, or Safe EIP-712 typed data.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `safeBatch(plan)`<br>_internal pure_ | JSON in Safe Transaction Builder format bound to the owner Safe. | none found | Yes, from a Foundry script |
| `planFile(p)`<br>_internal pure_ | JSON plan file with decimal-string integers that the TypeScript SDK reads. | none found | Yes, from a Foundry script |
| `safeTxTypedData(chainId, safe, t)`<br>_internal pure_ | Safe EIP-712 typed data in the field order Forge Attest's `safe-eip712` reader needs. | tests only | Yes, from a Foundry script |

Private helpers: `_batch`, `_calls`, `_homeCalls`, `_safeTxMessage`.


#### `contracts/SafeTxHash.sol`

Library that computes Safe's EIP-712 domain separator, struct hash and transaction hash for Safe 1.3.0 and later.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `domainSeparator(chainId, safe)`<br>_internal pure_ | Safe's EIP-712 domain separator from chain id and Safe address. | SafeTxHash.hash; also tests | Yes, from a Foundry script |
| `structHash(t)`<br>_internal pure_ | Safe's EIP-712 struct hash of a Safe transaction. | SafeTxHash.hash | Yes, from a Foundry script |
| `hash(chainId, safe, t)`<br>_internal pure_ | The Safe transaction hash for a chain, Safe and transaction. | tests only | Yes, from a Foundry script |


#### `contracts/SignedDispatch.sol`

Foundry builders for the protocol's signed dispatch: leaf encoding, Merkle root and proof, send, bootstrap, register, publish and relay calldata, wire bodies and the source-chain Safe transaction.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `encodeLeaf(leaf)`<br>_internal pure_ | Encodes an execution leaf's fields for guard publication. | MerklePackages.publishLeavesCalldata; also tests | Yes, from a Foundry script |
| `root(leaves)`<br>_internal pure_ | Merkle root over encoded leaves (sorted sibling hashing, odd-node promotion, as the guard does). | tests only | Yes, from a Foundry script |
| `proof(leaves, index)`<br>_internal pure_ | Sibling hashes that prove one leaf; empty for a single-leaf tree. | tests only | Yes, from a Foundry script |
| `tree(leaves, index)`<br>_internal pure_ | Builds root and proof together over encoded leaves. | SignedDispatch.root, SignedDispatch.proof | Yes, from a Foundry script (via `root` and `proof`) |
| `treeOfHashes(level, index)`<br>_internal pure_ | Same as `tree` over leaf hashes already computed; overwrites its input. | LzOft.root, MerklePackages.build, SignedDispatch.tree | Yes, from a Foundry script |
| `sendMessageCalldataSigned(destination, calls, attributes)`<br>_internal pure_ | Calldata for the transmitter's `sendMessage(destination, calls, attributes)`, refusing empty calls. | tests only | Yes, from a Foundry script |
| `bootstrapCalldataSigned(destinationChainIdentifier, body, attributes)`<br>_internal pure_ | Calldata for a signed transmitter's `bootstrap` naming the destination chain and carrying a bootstrap body. | tests only | Yes, from a Foundry script |
| `registerRootCalldata(treeRoot)`<br>_internal pure_ | Calldata for `registerRoot` with a Merkle root. | MerklePackages.registerRootCalldata; also tests | Yes, from a Foundry script |
| `publishLeavesCalldata(leaves)`<br>_internal pure_ | Calldata for the guard's `publishLeaves` with the leaves. | MerklePackages.publishLeavesCalldata; also tests | Yes, from a Foundry script |
| `transaction(transmitter, nonce, data, value)`<br>_internal pure_ | Builds the source-chain owner Safe transaction: its own CALL at a nonce to the transmitter. | tests only | Yes, from a Foundry script |
| `standaloneWire(evidence)`<br>_internal pure_ | Wire body for a standalone (non-Merkle) signed submission. | tests only | Yes, from a Foundry script |
| `merkleWire(evidence, leaf, proof)`<br>_internal pure_ | Wire body for a Merkle-leaf signed submission with its proof. | tests only | Yes, from a Foundry script |
| `bootstrapBodySigned(guard, updateHead, graph, setupCalls)`<br>_internal pure_ | ABI-encoded signed bootstrap for the guard, update head, authority graph and setup calls. | tests only | Yes, from a Foundry script |
| `relayLeafCalldata(evidence, leaf, proof)`<br>_internal pure_ | Calldata for the transmitter's `relayLeaf` with evidence, leaf and proof. | tests only | Yes, from a Foundry script |
| `submitMessageCalldata(evidence)`<br>_internal pure_ | Calldata for the receiver's `submitMessage`. | tests only | Yes, from a Foundry script |
| `submitLeafCalldata(evidence, leaf, proof)`<br>_internal pure_ | Calldata for the receiver's `submitLeaf`, with the leaf and its proof. | tests only | Yes, from a Foundry script |


#### `contracts/Types.sol`

Struct definitions for plans: `HomeCall`, `Batch` and `Plan`.

_Declares no functions._



## TypeScript library and CLI: `ts/src`

### `ts/src` (top level)

#### `ts/src/authority.ts`

TypeScript planner for authority updates: builds the source Safe's activation, ownership-change and selection proposals, proves child updates from published history, and builds the relay and catch-up transactions that move a receiver's authority forward.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `decodeAuthoritySubmission(bytes)`<br>_exported_ | Strictly decodes a published authority submission (evidence, new graph, child updates), requiring it to re-encode to the same bytes. | authority (type alias or module-level code), authority.AuthoritySource.loadSubmission | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `buildAuthorityProposal({…})`<br>_exported_ | Builds the Safe transaction for an authority `activate`, `select` (the guard's `selectAuthority`) or `ownership` change after validating the graphs against the guard's selection. | authority.planAuthorityProposal; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `authorityExecution({…})`<br>_exported_ | Builds the multicall that stages the update on the guard and then executes the Safe transaction with the live signatures. | authority.prepareAuthorityExecution; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `prepareAuthorityExecution({…})`<br>_exported_ | Builds that execution, reusing portable signatures when the live Safe accepts them and asking a callback for new ones only after a live-signature revert. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `planAuthorityProposal(source, input)`<br>_exported_ | Reads the source selection and witness graph over RPC, plans child updates and calls `buildAuthorityProposal`. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `planChildUpdates(source, currentGraph, newGraph)`<br>_exported_ | Proves retained and nested positions from published child updates and returns the `ChildUpdate` entries a new graph needs. | authority.planAuthorityProposal | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `submitAuthorityCalldata(update)`<br>_exported_ | Calldata for the receiver's `submitAuthority` from a published authority update. | none found (user-facing entry) | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `submitAuthorityBatchCalldata(updates)`<br>_exported_ | Calldata for the receiver's `submitAuthorityBatch`, requiring consecutive successors. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `buildAuthorityRelayProposal({…})`<br>_exported_ | Quotes the relay on the transmitter and builds the Safe CALL to `relayAuthority` carrying that fee. | authority.buildAuthorityRelayBatch, authority.planAuthorityCatchUp; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `receiverAuthoritySelection(rpc, receiver, blockNumber)`<br>_exported_ | Reads a receiver's selected authority head and hash over RPC. | authority.authorityRelayDelivered, authority.planAuthorityCatchUp | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `staleAuthorityChildren(source, graph)`<br>_exported_ | Lists child Safes whose latest selection has moved past the position the parent's graph selected. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `planAuthorityCatchUp({…})`<br>_exported_ | Checks the transmitter/receiver route and builds the relay that brings a receiver's authority up to the source's selected head. | authority (type alias or module-level code), cli.authorityRelay; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `authorityRelayDelivered(rpc, receiver, expected, blockNumber)`<br>_exported_ | Whether a receiver's selection equals the expected one. | none found (user-facing entry) | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `buildAuthorityRelayBatch(plans, multicall, rpc)`<br>_exported_ | Builds one multicall Safe transaction relaying one successor per receiver. | authorityAttest.scaffoldAuthorityRelayBatch; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `AuthoritySource.constructor({…})`<br>_exported_ | Binds RPC reads to one source block, guard and log-history range. | none found (user-facing entry) | Yes (SDK API, through the class) |
| `AuthoritySource.selection(sourceSafe)`<br>_exported_ | The guard's authority selection for a source Safe. | authority.planAuthorityCatchUp, authority.staleAuthorityChildren; also tests | Yes (SDK API, through the class) |
| `AuthoritySource.submission(sourceSafe, updateHead, atOrBefore)`<br>_exported_ | The published authority submission for a Safe and update head, found in guard logs. | authority.AuthoritySource.loadSubmission, authority.planChildUpdates; also tests | Yes (SDK API, through the class) |
| `AuthoritySource.witness(sourceSafe, selected)`<br>_exported_ | The full graph behind a Safe's selected authority hash, rebuilt from published history. | authority.planAuthorityProposal; also tests | Yes (SDK API, through the class) |
| `AuthoritySource.successors(sourceSafe, fromHead, toHead)`<br>_exported_ | The published updates from a receiver's head to a target head. | authority.planAuthorityCatchUp; also tests | Yes (SDK API, through the class) |

Private helpers: `checkedGraph`, `predecessor`, `submissionHash`, `AuthoritySource.publishedHash`, `AuthoritySource.loadSubmission`.


#### `ts/src/authorityAttest.ts`

Scaffolds Forge Attest Solidity and config for authority-relay Safe proposals, single or batched.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `scaffoldAuthorityRelay({…})`<br>_exported_ | Returns the Forge Attest scaffold (a `RelayAuthority` Forge script that calls `_writeAuthorityRelay`, plus its config) for one authority relay. | cli.authorityRelay; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `scaffoldAuthorityRelayBatch({…})`<br>_exported_ | Same scaffold for several relays sent in one multicall, using `_writeAuthorityRelayBatch`. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |

Private helpers: `rpcName`, `hex`, `relayFields`, `scaffold`.


#### `ts/src/bundle.ts`

Builds, verifies, serializes and parses the delivery bundle (a signed Safe transaction with its Merkle package) and produces the calldata that submits it.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `buildDeliveryBundle({…})`<br>_exported_ | Builds and verifies a bundle, returning addresses and hex in the form `parseDeliveryBundle` reads. | safeQueue.SafeQueue.exportBundle; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `requireDeliveryBundle(bundle)`<br>_exported_ | Checks what needs no signer or RPC: the Safe transaction hash, that calldata is one `sendMessage` or the `registerRoot` of the package root, the tree, and nested approvals. | bundle.buildDeliveryBundle, bundle.parseDeliveryBundle, bundle.serializeDeliveryBundle; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `relayLeafFromBundle(bundle, index)`<br>_exported_ | `relayLeaf` calldata for a transmitter on the source chain. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `submitLeafFromBundle(bundle, index)`<br>_exported_ | `submitLeaf` calldata for the destination receiver, with no provider involved. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `submitMessageFromBundle(bundle)`<br>_exported_ | `submitMessage` calldata for a standalone bundle. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `deliveryBundleToJsonObject(bundle)`<br>_exported_ | Converts a bundle to its JSON layout. | bundle.buildDeliveryBundle, bundle.serializeDeliveryBundle | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `deliveryBundleFromJsonObject(raw)`<br>_exported_ | Strictly reads the JSON layout without verifying it. | bundle.buildDeliveryBundle, bundle.parseDeliveryBundle | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `serializeDeliveryBundle(bundle)`<br>_exported_ | Verifies a bundle and returns it as pretty JSON text. | cli.signedQueue, safeQueue.unsignedDraft; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `parseDeliveryBundle(json)`<br>_exported_ | Strictly parses JSON text and runs `requireDeliveryBundle`. | cli.signedQueue, safeQueue.unsignedDraft; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |

Private helpers: `leafEntry`, `signedTxToJSON`, `signedTxFromJSON`.


#### `ts/src/cli.ts`

The `crossecute` command-line entry point: checks unsigned-mode plans, proposes, confirms and exports signed-queue transactions, and provides authority-relay scaffolding.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `signedQueue(command, draftPath, owners)`<br>_local_ | Proposes, confirms or exports a signed bundle through Safe Queue, signing with a Ledger via `cast`. | cli.main | Yes, `crossecute signed-propose\|signed-confirm\|signed-export` |
| `check(planPath, safeTxPath)`<br>_local_ | Verifies an unsigned-mode plan and prints its Safe transaction hashes. | cli (type alias or module-level code), cli.main; also tests | Yes, `crossecute check` |
| `authorityRelay(configPath, directory)`<br>_local_ | Reads a relay config and scaffolds the Forge Attest proposal for a receiver's next authority update. | cli.main | Yes, `crossecute authority-relay` |
| `main({…})`<br>_local_ | Dispatches `check`, `authority-relay` and `signed-propose\|confirm\|export` from the command line. | cli (type alias or module-level code) | Yes, `crossecute <command>` (bin entry) |

Private helpers: `signWithLedger`.


#### `ts/src/encoding.ts`

TypeScript twins of the protocol's ERC-7930 and payload encoders (`Erc7930`, `ChainKey`, `Payload`).

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `encodeEvmChain(chainId)`<br>_exported_ | `Erc7930.encodeEvmChain`: an eip155 chain identifier with no address. | encoding.chainKey, plan.homeCalldata; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `encodeEvm(chainId, account)`<br>_exported_ | `Erc7930.encodeEvm`: an account on an eip155 chain. | authority.planAuthorityCatchUp, plan.homeCalldata; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `chainKey(chainId)`<br>_exported_ | `ChainKey.forEvm`: the protocol's key for an EVM chain id. | lzOft (type alias or module-level code), lzOft.requireLzOftLeaves, lzOft.lzOftLeafHash, lzOft.lzOftLeaves; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `encodeCalls(calls)`<br>_exported_ | `Payload.encodeCalls`: the wire bytes an EVM receiver decodes. | plan.homeCalldata; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `encodeBootstrap(destinationChainIdentifier, body)`<br>_exported_ | `Payload.encodeBootstrap`: destination chain identifier plus body. | plan.homeCalldata, signed.bootstrapCalldataSigned; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |

Private helpers: `chainRef`, `lengthByte`.


#### `ts/src/index.ts`

Package entry that re-exports every module except `json.ts` and `cli.ts`.


#### `ts/src/json.ts`

Strict readers for exported JSON (decimal-string integers, complete hex bytes, exact key sets) used by every parser in the package.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `uint(v, at)`<br>_exported_ | Reads a decimal-string integer as a bigint or throws. | bundle.deliveryBundleFromJsonObject, cli.authorityRelay, merkle (type alias or module-level code), merkle.fieldFromJSON, merkle.merklePackageFromJsonObject, merkle.merklePackageToJsonObject, plan.parsePlan, safeQueue.matchingTransaction, safeTx.parseSafeTxFields, safeTx.parseSafeTxTypedData | No (not re-exported from the package entry) |
| `bytesHex(v, at)`<br>_exported_ | Reads complete hex bytes as lowercase hex or throws. | bundle.signedTxFromJSON, cli.authorityRelay, cli.signWithLedger, merkle.fieldFromJSON, merkle.merklePackageFromJsonObject, plan.parsePlan, safeQueue.SafeQueue.confirm, safeQueue.SafeQueue.propose, safeQueue.checkedSignature, safeTx.parseSafeTxFields | No (not re-exported from the package entry) |
| `word(v, at)`<br>_exported_ | Reads a 32-byte hex word as lowercase hex or throws. | bundle.deliveryBundleFromJsonObject, merkle.merklePackageFromJsonObject, safeQueue.matchingTransaction; also tests | No (not re-exported from the package entry) |
| `address(v, at)`<br>_exported_ | Reads a checksummed address or throws. | bundle.deliveryBundleFromJsonObject, cli.authorityRelay, cli.signedQueue, plan.parsePlan, safeQueue (type alias or module-level code), safeQueue.SafeQueue.confirm, safeQueue.SafeQueue.exportBundle, safeQueue.SafeQueue.propose, safeQueue.confirmations, safeQueue.matchingTransaction; also tests | No (not re-exported from the package entry) |
| `object(v, keys, at)`<br>_exported_ | Requires an object with exactly the given keys. | bundle.deliveryBundleFromJsonObject, bundle.signedTxFromJSON, cli.authorityRelay, merkle.merklePackageFromJsonObject | No (not re-exported from the package entry) |
| `array(v, at)`<br>_exported_ | Requires an array. | bundle.deliveryBundleFromJsonObject, cli.authorityRelay, merkle.fieldFromJSON, merkle.merklePackageFromJsonObject, plan.parsePlan, safeQueue.confirmations | No (not re-exported from the package entry) |


#### `ts/src/lzOft.ts`

TypeScript builders for the `layerzero-oft` binding: options attribute, destination leaves and root, `createTransmitter` calldata and transaction, and conduit address prediction.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `lzOptionsAttribute(rawOptions)`<br>_exported_ | The only attribute a `layerzero-oft` conduit accepts, `abi.encodePacked(selector, rawOptions)`. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `lzOftLeafHash(leaf)`<br>_exported_ | `LzOftMessage.leaf`: a destination leaf's hash. | lzOft.lzOftRoot; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `requireLzOftLeaves(leaves, home)`<br>_exported_ | The factory's leaf checks without the peer reads: at least one leaf, strictly ascending chain key, nonzero eid and OFT, and with `home` none naming the home. | lzOft.createLzOftTransmitterCalldata, lzOft.lzOftLeaves, lzOft.lzOftRoot; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `lzOftLeaves(destinations, home)`<br>_exported_ | Leaves for destinations in the ascending chain-key order the factory requires, rejecting two destinations on one chain. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `lzOftRoot(leaves, home)`<br>_exported_ | `LzOftMessage.root`: the `destRoot` bound into the conduit's address, over leaves already in order. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `createLzOftTransmitterCalldata(salt, homeOft, leaves)`<br>_exported_ | `LzOftConduitFactory.createTransmitter` calldata, which the owner Safe sends as a CALL. | lzOft.lzOftCreateTx; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `lzOftCreateTx(chainId, ownerSafe, factory, nonce, salt, homeOft, leaves)`<br>_exported_ | The owner Safe's CALL transaction to the factory that creates the conduit. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `lzOftConduitSalt(f)`<br>_exported_ | `LzOftConduitFactory.conduitSalt`. | lzOft.predictLzOftConduit; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `predictLzOftConduit(factory, f, proxyInitCodeHash)`<br>_exported_ | `LzOftConduitFactory.predictConduit` for a factory and proxy initcode hash. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |


#### `ts/src/merkle.ts`

Builds, verifies, serializes and parses the Merkle package behind a signed `registerRoot`, with the same plan rules as the Solidity `MerklePackages`.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `requireMerklePlan(leaves, receiverNonces)`<br>_exported_ | Rejects plans the receiver would refuse or that waste a root (duplicates, conflicting or stale nonces, missing or unused receiver nonces). | none found (user-facing entry) | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `buildMerklePackage(leaves, receiverNonces)`<br>_exported_ | Builds the root, leaf hashes and proofs the guard's `publishLeaves` records, in order. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `requireMerklePackage(pkg)`<br>_exported_ | Rebuilds the package from its leaves and throws unless every root, hash and proof matches. | bundle.requireDeliveryBundle, merkle.parseMerklePackage, merkle.serializeMerklePackage; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `publishMerklePackageCalldata(pkg)`<br>_exported_ | Calldata for the guard's permissionless `publishLeaves` with the ordered encoded leaves. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `merklePackageToJsonObject(pkg)`<br>_exported_ | Converts a package to its JSON layout. | bundle.deliveryBundleToJsonObject, merkle.buildMerklePackage, merkle.serializeMerklePackage; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `merklePackageFromJsonObject(raw, at)`<br>_exported_ | Strictly reads the JSON layout without checking it against its tree. | bundle.deliveryBundleFromJsonObject, merkle.buildMerklePackage, merkle.parseMerklePackage | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `serializeMerklePackage(pkg)`<br>_exported_ | Verifies a package and returns it as pretty JSON text. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `parseMerklePackage(json)`<br>_exported_ | Parses JSON text and runs `requireMerklePackage`. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |

Private helpers: `planHashes`, `assemble`, `fieldFromJSON`, `same`.


#### `ts/src/plan.ts`

Parses and checks the unsigned-mode plan file.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `parsePlan(json)`<br>_exported_ | Parses and type-checks a plan file without checking calls against batches. | cli.check; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `homeCalldata(batch)`<br>_exported_ | The transmitter calldata that carries a batch. | plan.requirePlan | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `requirePlan(plan)`<br>_exported_ | Throws unless every home call is the transmitter call its batch implies and only the first call carries value. | cli.check, safeTx.requireSafeTx; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |


#### `ts/src/safeQueue.ts`

Client for Safe's Queue API that proposes a signed bundle, confirms it and exports owners' confirmations.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `SafeQueue.constructor({…})`<br>_exported_ | Sets the API base URL and optional API key. | none found (user-facing entry) | Yes (SDK API, through the class) |
| `SafeQueue.propose(input, signer)`<br>_exported_ | Signs the unsigned bundle, posts it as a new queued Safe transaction, checks the queue recorded the proposer's confirmation and returns the Safe transaction hash. | cli.signedQueue; also tests | Yes (SDK API, through the class) |
| `SafeQueue.confirm(input, signer)`<br>_exported_ | Signs and posts the signer's confirmation for the queued transaction (refused if already executed or already confirmed) and returns the Safe transaction hash. | cli.signedQueue; also tests | Yes (SDK API, through the class) |
| `SafeQueue.exportBundle(input, owners)`<br>_exported_ | Exports the selected owners' confirmations as a bundle for a destination quorum. | cli.signedQueue; also tests | Yes (SDK API, through the class) |

Private helpers: `unsignedDraft`, `fields`, `matchingTransaction`, `checkedSignature`, `sign`, `confirmations`, `SafeQueue.request`, `SafeQueue.getTransaction`.


#### `ts/src/safeTx.ts`

Reads, writes and checks Safe transaction typed data and hashes, and the MultiSend encoding used by the unsigned-mode planner.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `parseSafeTxTypedData(json)`<br>_exported_ | Parses Safe transaction typed data, refusing any other shape. | cli.check; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `serializeSafeTxFields(tx)`<br>_exported_ | The ten `SafeTx` fields as JSON strings. | bundle.signedTxToJSON, cli.signWithLedger, safeQueue (type alias or module-level code), safeQueue.SafeQueue.propose, safeTx.serializeSafeTxTypedData; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `parseSafeTxFields(m)`<br>_exported_ | Inverse of `serializeSafeTxFields`. | bundle.signedTxFromJSON, safeQueue (type alias or module-level code), safeQueue.matchingTransaction, safeTx.parseSafeTxTypedData | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `safeTxHashes({…})`<br>_exported_ | The domain hash, message hash and Safe transaction hash a signer's device shows. | authority.prepareAuthorityExecution, authority.submissionHash, authorityAttest.scaffold, bundle.buildDeliveryBundle, bundle.requireDeliveryBundle, cli.check, safeQueue (type alias or module-level code), safeQueue.matchingTransaction; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `multiSendCalldata({…})`<br>_exported_ | The packed MultiSend encoding of calls followed by the `multiSend` call. | authority.buildAuthorityProposal, safeTx.requireSafeTx | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `requireSafeTx(plan, envelope)`<br>_exported_ | Throws unless the typed data is the one Safe transaction that carries the plan. | cli.check; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `serializeSafeTxTypedData({…})`<br>_exported_ | Forge Attest and `cast wallet sign` EIP-712 input with lossless decimal integers. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |


#### `ts/src/signed.ts`

TypeScript twins of the signed-dispatch encoders: leaf and tree hashing, authority graph encoding and validation, wire bodies, and calldata for the signed transmitter, receiver and guard.

| Function | What it does | Called by | User-called? |
|---|---|---|---|
| `encodeExecutionLeaf(leaf)`<br>_exported_ | Encodes an execution leaf's fields as the guard publishes them (not `abi.encode(struct)`). | merkle (type alias or module-level code), merkle.publishMerklePackageCalldata, merkle.planHashes, signed.executionLeafHash; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `dispatchLeafHash(encodedFields)`<br>_exported_ | Double keccak of encoded leaf fields. | lzOft.lzOftLeafHash, merkle (type alias or module-level code), merkle.planHashes, signed (type alias or module-level code), signed.executionId, signed.executionLeafHash | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `executionLeafHash(leaf)`<br>_exported_ | Leaf hash of an execution leaf. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `executionId(leaf)`<br>_exported_ | Replay identity of a leaf, excluding delivery attributes (`DispatchLeaves.executionId`). | merkle (type alias or module-level code), merkle.planHashes; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `dispatchTree(leaves)`<br>_exported_ | Builds the ordered tree over encoded leaves (root and proofs); odd nodes are promoted and leaves never sorted. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `dispatchTreeFromHashes(hashes)`<br>_exported_ | Same tree over leaf hashes already computed. | lzOft.lzOftRoot, merkle (type alias or module-level code), merkle.assemble, signed (type alias or module-level code) | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `verifyDispatchProof(hash, proof, root)`<br>_exported_ | Whether a proof links a leaf hash to a root. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `encodeAuthorityGraph(graph)`<br>_exported_ | `abi.encode(AuthorityGraph)`, the authority field of a bootstrap. | signed.encodeBootstrapBodySigned; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `authorityRecordHash(record)`<br>_exported_ | `AuthorityUpdateEncoding.recordHash`. | authority (type alias or module-level code), authority.planChildUpdates, signed.authorityGraphHash; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `authorityGraphHash(sourceChainId, graph)`<br>_exported_ | `AuthorityUpdateEncoding.graphHash`: the value the guard stores as the selection's authority hash. | authority (type alias or module-level code), authority.AuthoritySource.witness, authority.buildAuthorityProposal, authority.planAuthorityCatchUp; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `requireAuthorityGraph(graph, root)`<br>_exported_ | Offline form of the receiver's bootstrap shape checks (root, positions, owner limits, thresholds, kinds, node order). | authority (type alias or module-level code), authority.AuthoritySource.loadSubmission, authority.AuthoritySource.witness, authority.buildAuthorityProposal, signed.encodeBootstrapBodySigned; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `safeMessageHash(chainId, childSafe, message)`<br>_exported_ | The child Safe's message hash approved by `SignMessageLib`. | authority (type alias or module-level code), authority.planChildUpdates; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `encodeStandaloneWire(evidence)`<br>_exported_ | Wire bytes for a standalone signed submission. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `encodeMerkleWire(evidence, leaf, proof)`<br>_exported_ | Wire bytes for a Merkle-leaf signed submission with its proof. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `encodeBootstrapBodySigned(body, owner)`<br>_exported_ | `abi.encode(SignedBootstrap(...))` for the guard, selected head, graph and setup calls. | signed.bootstrapCalldataSigned; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `bootstrapCalldataSigned(destinationChainIdentifier, body, owner, attributes)`<br>_exported_ | `bootstrap(payload, attributes)` calldata for a signed transmitter. | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `sendMessageCalldataSigned(destination, calls, attributes)`<br>_exported_ | `sendMessage` calldata for a signed transmitter, refusing empty payloads. | bundle (type alias or module-level code), bundle.requireDeliveryBundle; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `registerRootCalldata(root)`<br>_exported_ | `registerRoot` calldata. | bundle (type alias or module-level code), bundle.requireDeliveryBundle; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `publishLeavesCalldata(leaves)`<br>_exported_ | `publishLeaves` calldata for the guard. | merkle (type alias or module-level code), merkle.publishMerklePackageCalldata; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `relayLeafCalldata(evidence, leaf, proof)`<br>_exported_ | `relayLeaf` calldata for the transmitter. | bundle (type alias or module-level code), bundle.relayLeafFromBundle; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `submitMessageCalldata(evidence)`<br>_exported_ | `submitMessage` calldata for the receiver. | bundle (type alias or module-level code), bundle.submitMessageFromBundle; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `submitLeafCalldata(evidence, leaf, proof)`<br>_exported_ | `submitLeaf` calldata for the receiver. | bundle (type alias or module-level code), bundle.submitLeafFromBundle; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `requireSignedDispatchRange(chainId, nonce, value)`<br>_exported_ | Requires chain id, Safe nonce and value to fit the signed transaction's fields and the chain id to be nonzero. | bundle (type alias or module-level code), bundle.buildDeliveryBundle, bundle.requireDeliveryBundle, signed.signedDispatchTx | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `signedDispatchTx(chainId, safe, transmitter, nonce, data, value)`<br>_exported_ | A separately signed CALL at its own Safe nonce (never wrapped in MultiSend). | authority (type alias or module-level code), authority.buildAuthorityProposal, authority.buildAuthorityRelayBatch, authority.buildAuthorityRelayProposal, lzOft.lzOftCreateTx; also tests | Yes (SDK API: `import` from `@crossecute/sdk`) |
| `safeBatchCalldata({…})`<br>_exported_ | Calldata for the batch executor's atomic submission of separately signed Safe transactions (one source chain, consecutive nonces per Safe). | tests only | Yes (SDK API: `import` from `@crossecute/sdk`) |

Private helpers: `member`, `abiFunction`, `pair`.


#### `ts/src/signedAbi.ts`

Generated by `scripts/sync-protocol.py`: the trimmed ABIs of the pinned protocol release (`signedTransmitterAbi`, `signedReceiverAbi`, `crossecuteGuardAbi` and others) and `PROTOCOL_VERSION`; a protocol rename must be followed by regenerating it.



## Other tooling

### SDK tooling scripts (not Solidity or TypeScript)

| File | What it is | How it is used |
|---|---|---|
| `scripts/sync-protocol.py` | Regenerates what the SDK derives from the pinned `@crossecute/protocol` release: the trimmed ABIs in `ts/src/signedAbi.ts`, the protocol version and revision, and the LayerZero OFT pins. Its `MEMBERS` table names the protocol functions and events each trimmed ABI keeps, so a protocol rename must be mirrored there. Flags: `--check`, `--revision`. | Maintainers on a protocol release. `--check` and `--revision` are meant for CI. |
| `scripts/check-lzoft-vectors.py` | Checks `vectors/lzoft.json` against the protocol's own LayerZero OFT code by writing, running and removing a Forge script in a protocol checkout. | Maintainers and CI, with a protocol checkout path as its one argument. |
| `scripts/check-forge-attest.sh` | Runs Forge Attest's own `safe-eip712` reader and hash derivation over the typed data the Solidity tests write and compares the Safe transaction hash with the SDK's. | Developers, after `forge test` (`pnpm test:attest`). |


# Part 4: The same concept across the three surfaces

A dash means that surface has no function for the concept. Only concepts that have more than one function name are listed.

| Concept | Protocol (Solidity) | SDK Foundry (Solidity) | SDK TypeScript |
|---|---|---|---|
| Calldata for `sendMessage` in signed mode | `TransmitterBase.sendMessage` | `SignedDispatch.sendMessageCalldataSigned` | `sendMessageCalldataSigned` |
| Calldata for `registerRoot` | `ISignedTransmitter.registerRoot` | `SignedDispatch.registerRootCalldata`, `MerklePackages.registerRootCalldata` | `registerRootCalldata` |
| Calldata for `publishLeaves` | `ICrossecuteGuard.publishLeaves` | `SignedDispatch.publishLeavesCalldata`, `MerklePackages.publishLeavesCalldata` | `publishLeavesCalldata`, `publishMerklePackageCalldata` |
| Calldata for `relayLeaf` | `ISignedTransmitter.relayLeaf` | `SignedDispatch.relayLeafCalldata` | `relayLeafCalldata` |
| Calldata for `submitMessage` and `submitLeaf` | `ISignedReceiver.submitMessage`, `submitLeaf` | `SignedDispatch.submitMessageCalldata`, `submitLeafCalldata` | `submitMessageCalldata`, `submitLeafCalldata` |
| Calldata for `bootstrap` in signed mode | `ISignedTransmitter.bootstrap` | `SignedDispatch.bootstrapCalldataSigned` | `bootstrapCalldataSigned` |
| Signed bootstrap body | struct `SignedBootstrap`, checked by `SignedTransmitterLib.requireBootstrapBody` | `SignedDispatch.bootstrapBodySigned` | `encodeBootstrapBodySigned` |
| Source Safe transaction for a send | - | `SignedDispatch.transaction` | `signedDispatchTx` |
| Standalone and Merkle wire bodies | `ISignedReceiver` consumes them | `SignedDispatch.standaloneWire`, `merkleWire` | `encodeStandaloneWire`, `encodeMerkleWire` |
| Merkle root, proof and tree | `DispatchLeaves.requireProof` | `SignedDispatch.root`, `proof`, `tree`, `treeOfHashes` | `dispatchTree`, `dispatchTreeFromHashes`, `verifyDispatchProof` |
| Leaf hash | `DispatchLeaves.hash` | - | `executionLeafHash`, `dispatchLeafHash` |
| Merkle package build and check | - | `MerklePackages.build`, `requireMerklePlan` | `buildMerklePackage`, `requireMerklePlan` |
| Merkle package JSON | - | `MerklePackageJson.toJson` | `merklePackageToJsonObject`, `serializeMerklePackage` |
| Safe transaction hash | `SafeHashes.transactionHash` (guard) | `SafeTxHash.hash` | `safeTxHashes` |
| Safe typed data | - | `PlanJson.safeTxTypedData` | `serializeSafeTxTypedData`, `parseSafeTxTypedData` |
| Unsigned-mode plan | - | `PlanJson.planFile` | `parsePlan`, `requirePlan`, `homeCalldata` |
| Authority graph and record hash | `AuthorityUpdateEncoding.graphHash`, `recordHash` | - | `authorityGraphHash`, `authorityRecordHash` |
| Select a new authority graph | `ISourceAuthorityGuard.selectAuthority` | - | action `select` in `buildAuthorityProposal` |
| EVM chain key | `ChainKey.forEvm(chainId)` and `Erc7930.chainKey(envelope)` produce the same key for the same chain | - | `chainKey` |
| LayerZero OFT leaf | `LzOftMessage.leaf` | `LzOft.leafHash` | `lzOftLeafHash` |
| LayerZero OFT root | `LzOftMessage.root` | `LzOft.root` | `lzOftRoot` |
| LayerZero OFT conduit salt and address | `LzOftConduitFactory.conduitSalt`, `predictConduit` | `LzOft.conduitSalt`, `predictConduit` | `lzOftConduitSalt`, `predictLzOftConduit` |
| LayerZero OFT options attribute | `LzMessage` (options attribute) | `LzOft.optionsAttribute` | `lzOptionsAttribute` |
| LayerZero OFT leaf check | `LzOftConduitFactory._requireLeaves` | `LzOft.requireLeaves` | `requireLzOftLeaves` |
| `createTransmitter` calldata | `LzOftConduitFactory.createTransmitter` | `LzOft.createTransmitterCalldata` | `createLzOftTransmitterCalldata`, `lzOftCreateTx` |
| Provider chain id setter | `setProviderId` on `CcipTransceiverBase`, `HyperlaneTransceiverBase`, `LzTransceiverBase`, `OpStackTransceiver` and `WormholeTransceiver`, each wrapping `ProviderChainId._setProviderId` | - | - |

# Part 5: SDK names at the protocol 0.3.0 sync

The SDK's `main` still uses the names in the left column. At the sync, apply the renames below and replace `quoteSignedMessage` with `quoteMessageSigned` in the `MEMBERS` table of `scripts/sync-protocol.py`. Regenerate `ts/src/signedAbi.ts` and update the release assertion in `ts/test/protocolRelease.test.ts` and the quote example in `docs/usage.md`. Remove this section once the sync lands.

| Surface | Current name | Name after the sync |
|---|---|---|
| TypeScript | `checkLzOftLeaves`, `checkMerklePlan`, `checkPlan`, `checkSafeTx`, `checkSignedDispatchRange` | `requireLzOftLeaves`, `requireMerklePlan`, `requirePlan`, `requireSafeTx`, `requireSignedDispatchRange` |
| TypeScript | `verifyMerklePackage`, `verifyDeliveryBundle`, `validateAuthorityGraph` | `requireMerklePackage`, `requireDeliveryBundle`, `requireAuthorityGraph` |
| TypeScript | `signedSendData`, `signedBootstrapData` | `sendMessageCalldataSigned`, `bootstrapCalldataSigned` |
| TypeScript | `registerRootData`, `publishLeavesData`, `merklePublishData`, `relayLeafData` | `registerRootCalldata`, `publishLeavesCalldata`, `publishMerklePackageCalldata`, `relayLeafCalldata` |
| TypeScript | `submitMessageData`, `submitLeafData`, `submitAuthorityData`, `submitAuthorityBatchData` | `submitMessageCalldata`, `submitLeafCalldata`, `submitAuthorityCalldata`, `submitAuthorityBatchCalldata` |
| TypeScript | `createLzOftTransmitterData`, `safeBatchData`, `multiSendData`, `homeCallData` | `createLzOftTransmitterCalldata`, `safeBatchCalldata`, `multiSendCalldata`, `homeCalldata` |
| TypeScript | `encodeSignedBootstrap` | `encodeBootstrapBodySigned` |
| TypeScript | `deliveryBundleToJSON`, `deliveryBundleFromJSON`, `merklePackageToJSON`, `merklePackageFromJSON` | `deliveryBundleToJsonObject`, `deliveryBundleFromJsonObject`, `merklePackageToJsonObject`, `merklePackageFromJsonObject` |
| TypeScript | authority action `adopt` | `select` |
| Foundry | `SignedDispatch.sendData`, `bootstrapData`, `registerData`, `publishData`, `relayData` | `sendMessageCalldataSigned`, `bootstrapCalldataSigned`, `registerRootCalldata`, `publishLeavesCalldata`, `relayLeafCalldata` |
| Foundry | `SignedDispatch.submitData` (two overloads) | `submitMessageCalldata`, `submitLeafCalldata` |
| Foundry | `SignedDispatch.bootstrapBody` | `bootstrapBodySigned` |
| Foundry | `MerklePackages.registerData`, `publishData`, `check` | `registerRootCalldata`, `publishLeavesCalldata`, `requireMerklePlan` |
| Foundry | `LzOft.createTransmitterData`, `checkLeaves` | `createTransmitterCalldata`, `requireLeaves` |
| Foundry | `LzDvn.requiresDeadDvn` | `isDeadDvnRequired` |
