// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {CcipConfig, ICcipLaneConfig} from "src/protocols/ccip/CcipConfig.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Send, quote, and `EVM2AnyMessage` construction for every CCIP sender (transmitter,
///         and the transceiver and its variants). The id `ccipSend` returns is discarded: senders
///         return a zero sendId, ERC-7786's "sent" (see `ProviderSendSpec`); the id is in
///         the on-ramp's send event.
library CcipMessage {
    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant EXTRA_ARGS_ATTRIBUTE = bytes4(keccak256("crossecute.ccip.extraArgs"));

    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant EXTRA_ARGS_V3_ATTRIBUTE = bytes4(keccak256("crossecute.ccip.extraArgsV3"));

    error CcipV3LaneDisabled(uint64 destination);
    error InvalidCcipV3Options();
    error CcipGasLimitOverflow(uint256 gasLimit);

    /// @notice The EVM sender of a delivered message.
    /// @dev `abi.decode` reverts on a word with bits above the low 20 bytes set, so a wider
    ///      sender is refused rather than truncated (C10).
    function sender(bytes memory encodedSender) internal pure returns (address) {
        return abi.decode(encodedSender, (address));
    }

    function send(
        address router,
        uint64 selector,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value,
        uint256 defaultGas,
        address laneConfig
    ) internal {
        // forge-lint: disable-start(unused-return) the id is in the on-ramp's event; sends return 0
        IRouterClient(router).ccipSend{value: value}(
            selector, buildOnLane(laneConfig, selector, recipient, payload, attributes, defaultGas)
        );
        // forge-lint: disable-end(unused-return)
    }

    function quote(
        address router,
        uint64 selector,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 defaultGas,
        address laneConfig
    ) internal view returns (uint256) {
        return IRouterClient(router)
            .getFee(selector, buildOnLane(laneConfig, selector, recipient, payload, attributes, defaultGas));
    }

    function buildOnLane(
        address laneConfig,
        uint64 selector,
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 defaultGas
    ) private view returns (Client.EVM2AnyMessage memory message) {
        message = build(recipient, payload, attributes, defaultGas);
        if (
            // forge-lint: disable-next-line(unsafe-typecast) inspect only the encoded format tag
            bytes4(message.extraArgs) == ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG
                && !ICcipLaneConfig(laneConfig).ccipV3LaneEnabled(selector)
        ) {
            revert CcipV3LaneDisabled(selector);
        }
    }

    function build(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 defaultGas)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        address receiver = ProviderAddress.evmRecipient(recipient);
        Client.EVMTokenAmount[] memory noTokens = new Client.EVMTokenAmount[](0);
        return Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: payload,
            tokenAmounts: noTokens,
            feeToken: address(0),
            extraArgs: extraArgsFrom(attributes, defaultGas)
        });
    }

    /// @notice Legacy attribute: CCIP's `GenericExtraArgsV2`, as
    ///         `abi.encodePacked(EXTRA_ARGS_ATTRIBUTE, abi.encode(gasLimit,
    ///         allowOutOfOrderExecution))`. V3 instead takes `abi.encode(GenericExtraArgsV3)`
    ///         after EXTRA_ARGS_V3_ATTRIBUTE. At most one attribute is accepted.
    /// @dev Omitted attributes retain V2 encoding and defaultGas. CCIP 2.0 ignores the legacy
    ///      ordering flag. A zero V3 gas limit selects defaultGas, bounded to uint32.
    function extraArgsFrom(bytes[] memory attributes, uint256 defaultGas) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast) inspect only the attribute selector
        if (attributes.length != 0 && bytes4(attributes[0]) == EXTRA_ARGS_V3_ATTRIBUTE) {
            (, bytes memory body) = ProviderAttribute.body(attributes, EXTRA_ARGS_V3_ATTRIBUTE, 0);
            ExtraArgsCodec.GenericExtraArgsV3 memory options = abi.decode(body, (ExtraArgsCodec.GenericExtraArgsV3));
            if (options.tokenReceiver.length != 0 || options.tokenArgs.length != 0) revert InvalidCcipV3Options();
            if (options.gasLimit == 0) {
                if (defaultGas > type(uint32).max) revert CcipGasLimitOverflow(defaultGas);
                // forge-lint: disable-next-line(unsafe-typecast) bounded above
                options.gasLimit = uint32(defaultGas);
            }
            if ((uint32(options.requestedFinalityConfig) & 0xfffe0000) != 0) revert InvalidCcipV3Options();
            FinalityCodec._validateRequestedFinality(options.requestedFinalityConfig);
            CcipConfig.validateCCVs(options.ccvs);
            return ExtraArgsCodec._encodeGenericExtraArgsV3(options);
        }
        (bool present, bytes memory encoded) = ProviderAttribute.body(attributes, EXTRA_ARGS_ATTRIBUTE, 64);
        // In order, as empty `extraArgs` would be.
        // forge-lint: disable-start(boolean-cst)
        (uint256 gasLimit, bool allowOutOfOrderExecution) =
            present ? abi.decode(encoded, (uint256, bool)) : (defaultGas, false);
        // forge-lint: disable-end(boolean-cst)
        return Client._argsToBytes(
            Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: allowOutOfOrderExecution})
        );
    }
}
