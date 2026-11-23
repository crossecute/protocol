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
  ILzOftConduitFactoryAbi, ISignedReceiverAbi, ISignedTransmitterAbi, ISourceAuthorityGuardAbi, SafeBatchExecutorAbi,
} from "@crossecute/protocol/abi";
```

Each interface declares the events and errors its implementation emits and reverts with, so its
ABI alone decodes them.

For LayerZero OFT tooling, import from `@crossecute/protocol/protocols/layerzero/`:

- `ILzOftConduitFactory`: conduit creation, its events and errors, and the views for address
  prediction, committed destinations and their bootstrap proofs. Factory inputs are
  `ILzOftConduitFactory.Destination(chainKey, eid, oft)`.
- `LzOftConduitAddress`: the same derivation offline: each destination's leaf hash, the
  destination checks `createTransmitter` makes before reading peers, `destRoot`, `conduitSalt` and
  `predictConduit`.
- `UlnConfig`: the ABI layout of LayerZero's ULN configuration.

`OrderedMerkle` under `messaging/` builds the protocol's one Merkle tree, which both the guard's
`publishLeaves` and the OFT destination root use.

## Derived addresses

Do not predict conduit addresses with `ProxyInitCode.hash()` or `ProxyDeployer.predict`
compiled in your own project. Both hash `type(Proxy).creationCode` from your compiler, and the
protocol's addresses depend on its pinned settings (solc 0.8.28, paris, 200 runs, no
metadata). Call `predictReceiver` or `predictTransmitter` on the deployed transceiver instead.
For a `layerzero-oft` conduit, pass the deployed factory's `PROXY_INIT_CODE_HASH()` to
`LzOftConduitAddress.predictConduit`.

## Versions

OpenZeppelin is a peer dependency pinned to the version the protocol is built with. The
sources need solc 0.8.28 or later.
