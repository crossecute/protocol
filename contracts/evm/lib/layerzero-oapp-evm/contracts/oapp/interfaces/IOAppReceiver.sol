// SPDX-License-Identifier: MIT

// Vendored, unmodified, from LayerZero-Labs/devtools @ 4973ba8bef7b0fdf7268469abea3ea50dbd4bbd8
// (packages/oapp-evm/contracts/oapp/interfaces/IOAppReceiver.sol).
// @layerzerolabs/oapp-evm-upgradeable and @layerzerolabs/oapp-evm have no
// dedicated repo of their own; this is their actual home. See docs/todo.md §2.
pragma solidity ^0.8.20;

import { ILayerZeroReceiver, Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";

interface IOAppReceiver is ILayerZeroReceiver {
    /**
     * @notice Indicates whether an address is an approved composeMsg sender to the Endpoint.
     * @param _origin The origin information containing the source endpoint and sender address.
     *  - srcEid: The source chain endpoint ID.
     *  - sender: The sender address on the src chain.
     *  - nonce: The nonce of the message.
     * @param _message The lzReceive payload.
     * @param _sender The sender address.
     * @return isSender Is a valid sender.
     *
     * @dev Applications can optionally choose to implement a separate composeMsg sender that is NOT the bridging layer.
     * @dev The default sender IS the OAppReceiver implementer.
     */
    function isComposeMsgSender(
        Origin calldata _origin,
        bytes calldata _message,
        address _sender
    ) external view returns (bool isSender);
}
