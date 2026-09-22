// SPDX-License-Identifier: MIT

// Vendored, not a submodule: see ILayerZeroEndpointV2.sol in this directory for why.
// Hand-copied from LayerZero-Labs/LayerZero-v2 @ 9c741e7f9790639537b1710a203bcdfd73b0b9ac,
// packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroReceiver.sol, otherwise
// verbatim.

pragma solidity >=0.8.0;

import { Origin } from "./ILayerZeroEndpointV2.sol";

interface ILayerZeroReceiver {
    function allowInitializePath(Origin calldata _origin) external view returns (bool);

    function nextNonce(uint32 _eid, bytes32 _sender) external view returns (uint64);

    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}
