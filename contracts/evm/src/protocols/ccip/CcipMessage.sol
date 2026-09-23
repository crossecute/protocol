// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Client} from "@ccip/libraries/Client.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice `EVM2AnyMessage` construction and extraArgs attribute parsing, identical across
///         every CCIP sender (`CcipTransmitter`, `CcipHubTransceiver`, `CcipSpokeTransceiver`,
///         `CcipZkSyncSpokeTransceiver`, `CcipTronSpokeTransceiver`). `extraArgsFrom` does a
///         raw selector read via assembly plus a manual byte copy; keeping one copy means a
///         future fix to it can't diverge silently between callers.
library CcipMessage {
    bytes4 internal constant EXTRA_ARGS_ATTRIBUTE = bytes4(keccak256("crossecute.ccip.extraArgs"));

    error UnknownCcipAttribute(bytes attribute);

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
        if (attributes.length == 0) return "";
        if (attributes.length > 1) revert UnknownCcipAttribute(attributes[1]);
        bytes memory attribute = attributes[0];
        if (attribute.length < 4) revert UnknownCcipAttribute(attribute);
        bytes4 selector;
        assembly {
            selector := mload(add(attribute, 32))
        }
        if (selector != EXTRA_ARGS_ATTRIBUTE) revert UnknownCcipAttribute(attribute);
        uint256 len = attribute.length - 4;
        bytes memory encoded = new bytes(len);
        for (uint256 i; i < len; ++i) {
            encoded[i] = attribute[i + 4];
        }
        (uint256 gasLimit, bool allowOutOfOrderExecution) =
            abi.decode(encoded, (uint256, bool));
        return Client._argsToBytes(
            Client.EVMExtraArgsV2({
                gasLimit: gasLimit,
                allowOutOfOrderExecution: allowOutOfOrderExecution
            })
        );
    }
}
