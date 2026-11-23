# @crossecute/protocol

Solidity sources and ABIs for building on Crossecute. The package includes EVM and guard
sources whose imports resolve within the protocol or OpenZeppelin, with bundled imports
rewritten to relative paths.

```
@crossecute/protocol/=node_modules/@crossecute/protocol/contracts/
@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/
```

```ts
import {
  ILzOftConduitFactoryViewAbi, ILzOftCreateAbi, ISignedTransmitterAbi, ISourceAuthorityGuardAbi, SafeBatchExecutorAbi,
} from "@crossecute/protocol/abi";
```

For LayerZero OFT tooling, import `ILzOftCreate`, `LzOftMerkle`, and `UlnConfig` from
`@crossecute/protocol/protocols/layerzero/`. Construct factory inputs with
`ILzOftCreate.OftLeaf(chainKey, eid, oft)`. The `createTransmitter` calldata still uses
`(bytes32,uint32,address)[]` for the destination records.

Use `ILzOftConduitFactoryView` to predict conduit addresses, read the deployed Proxy initcode
hash, and inspect committed destinations and their bootstrap proofs. `ISignedTransmitter`
exposes `quoteRelay`, `isRootRegistered`, and `isLeafRelayed` alongside `relayLeaf`.

## Derived addresses

Do not predict conduit addresses with `ProxyInitCode.hash()` or `ProxyDeployer.predict`
compiled in your own project. Both hash `type(Proxy).creationCode` from your compiler, and the
protocol's addresses depend on its pinned settings (solc 0.8.28, paris, 200 runs, no
metadata). Call `predictReceiver` or `predictTransmitter` on the deployed transceiver instead.

## Versions

OpenZeppelin is a peer dependency pinned to the version the protocol is built with. The
sources need solc 0.8.28 or later.
