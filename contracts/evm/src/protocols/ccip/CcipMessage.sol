// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "@ccip/libraries/Client.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

/// @notice `EVM2AnyMessage` construction and extraArgs attribute parsing, identical across
///         every CCIP sender (`CcipTransmitter`, `CcipHubTransceiver`, `CcipSpokeTransceiver`,
///         `CcipZkSyncSpokeTransceiver`, `CcipTronSpokeTransceiver`). Keeping one copy means
///         a future fix to it can't diverge silently between callers.
library CcipMessage {
    bytes4 internal constant EXTRA_ARGS_ATTRIBUTE = bytes4(keccak256("crossecute.ccip.extraArgs"));

    /// @dev Empty `extraArgs` is a valid default (CCIP's own 200k gas limit applies), not a
    ///      missing one.
    function build(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        address receiver = address(bytes20(Erc7930.parseStrict(recipient).addr));
        Client.EVMTokenAmount[] memory noTokens = new Client.EVMTokenAmount[](0);
        return Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: payload,
            tokenAmounts: noTokens,
            feeToken: address(0),
            extraArgs: extraArgsFrom(attributes)
        });
    }

    /// @notice One attribute: CCIP's `EVMExtraArgsV2`, as
    ///         `abi.encodePacked(EXTRA_ARGS_ATTRIBUTE, abi.encode(gasLimit,
    ///         allowOutOfOrderExecution))`. Anything else is refused per ERC-7786.
    function extraArgsFrom(bytes[] memory attributes) internal pure returns (bytes memory) {
        (bool present, bytes memory encoded) = ProviderAttribute.body(attributes, EXTRA_ARGS_ATTRIBUTE, 64);
        if (!present) return "";
        (uint256 gasLimit, bool allowOutOfOrderExecution) = abi.decode(encoded, (uint256, bool));
        return Client._argsToBytes(
            Client.EVMExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: allowOutOfOrderExecution})
        );
    }
}
