# @crossecute/protocol

Solidity sources and ABIs for building on Crossecute. It holds every file under
`contracts/evm/src/` whose imports stay within the protocol, OpenZeppelin and the guard,
with its imports rewritten to relative paths. The provider bindings under `src/protocols/<p>/`
import vendored provider code and are left out.

```
@crossecute/protocol/=node_modules/@crossecute/protocol/contracts/
@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/
```

```ts
import { IERC7786GatewaySourceAbi } from "@crossecute/protocol/abi";
```

## Derived addresses

Do not predict conduit addresses with `ProxyInitCode.hash()` or `ProxyDeployer.predict`
compiled in your own project. Both hash `type(Proxy).creationCode` from your compiler, and the
protocol's addresses depend on its pinned settings (solc 0.8.28, paris, 200 runs, no
metadata). Call `predictReceiver` or `predictTransmitter` on the deployed transceiver instead.

## Versions

OpenZeppelin is a peer dependency pinned to the version the protocol is built with. The
sources need solc 0.8.28 or later.
