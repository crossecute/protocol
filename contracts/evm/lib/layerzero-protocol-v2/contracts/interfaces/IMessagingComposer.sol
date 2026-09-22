// SPDX-License-Identifier: MIT

// Vendored, not a submodule: see ILayerZeroEndpointV2.sol in this directory for why.
// Hand-copied from LayerZero-Labs/LayerZero-v2 @ 9c741e7f9790639537b1710a203bcdfd73b0b9ac,
// packages/layerzero-v2/evm/protocol/contracts/interfaces/IMessagingComposer.sol, otherwise
// verbatim.

pragma solidity >=0.8.0;

interface IMessagingComposer {
    event ComposeSent(address from, address to, bytes32 guid, uint16 index, bytes message);
    event ComposeDelivered(address from, address to, bytes32 guid, uint16 index);
    event LzComposeAlert(
        address indexed from,
        address indexed to,
        address indexed executor,
        bytes32 guid,
        uint16 index,
        uint256 gas,
        uint256 value,
        bytes message,
        bytes extraData,
        bytes reason
    );

    function composeQueue(
        address _from,
        address _to,
        bytes32 _guid,
        uint16 _index
    ) external view returns (bytes32 messageHash);

    function sendCompose(address _to, bytes32 _guid, uint16 _index, bytes calldata _message) external;

    function lzCompose(
        address _from,
        address _to,
        bytes32 _guid,
        uint16 _index,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;
}
