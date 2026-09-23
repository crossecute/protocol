// SPDX-License-Identifier: MIT

// Vendored, unmodified, from LayerZero-Labs/LayerZero-v2 @ 9c741e7f9790639537b1710a203bcdfd73b0b9ac
// (packages/layerzero-v2/evm/protocol/contracts/interfaces/IMessagingContext.sol).
// @layerzerolabs/lz-evm-protocol-v2 has no standalone package repo of its own;
// this is its actual home. See docs/todo.md §2.

pragma solidity >=0.8.0;

interface IMessagingContext {
    function isSendingMessage() external view returns (bool);

    function getSendContext() external view returns (uint32 dstEid, address sender);
}
