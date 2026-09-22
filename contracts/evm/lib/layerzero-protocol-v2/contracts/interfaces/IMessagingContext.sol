// SPDX-License-Identifier: MIT

// Vendored, not a submodule: see ILayerZeroEndpointV2.sol in this directory for why.
// Hand-copied from LayerZero-Labs/LayerZero-v2 @ 9c741e7f9790639537b1710a203bcdfd73b0b9ac,
// packages/layerzero-v2/evm/protocol/contracts/interfaces/IMessagingContext.sol, otherwise
// verbatim.

pragma solidity >=0.8.0;

interface IMessagingContext {
    function isSendingMessage() external view returns (bool);

    function getSendContext() external view returns (uint32 dstEid, address sender);
}
