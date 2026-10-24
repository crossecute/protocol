// SPDX-License-Identifier: MIT

// Vendored, unmodified, from LayerZero-Labs/LayerZero-v2 @ 9c741e7f9790639537b1710a203bcdfd73b0b9ac
// (packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroComposer.sol).
// @layerzerolabs/lz-evm-protocol-v2 has no standalone package repo of its own;
// this is its actual home. See docs/provider-research.md §8.

pragma solidity >=0.8.0;

/**
 * @title ILayerZeroComposer
 */
interface ILayerZeroComposer {
    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from The address initiating the composition, typically the OApp where the lzReceive was called.
     * @param _guid The unique identifier for the corresponding LayerZero src/dst tx.
     * @param _message The composed message payload in bytes. NOT necessarily the same payload passed via lzReceive.
     * @param _executor The address of the executor for the composed message.
     * @param _extraData Additional arbitrary data in bytes passed by the entity who executes the lzCompose.
     */
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}
