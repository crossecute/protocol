// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";

/// @notice For harnesses that exercise everything but the transport: `OutboundBase`'s two
///         provider seams, as reverts. One per base, because a mixin beside the base would
///         collide with the functions the base itself overrides from `OutboundBase`.

error Unsent();

abstract contract UnsendableTransceiver is TransceiverBase {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        virtual
        override
        returns (bytes32)
    {
        revert Unsent();
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal view virtual override returns (uint256) {
        revert Unsent();
    }
}

abstract contract UnsendableHub is HubTransceiverBase {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        virtual
        override
        returns (bytes32)
    {
        revert Unsent();
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal view virtual override returns (uint256) {
        revert Unsent();
    }
}

abstract contract UnsendableSpoke is SpokeTransceiverBase {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        virtual
        override
        returns (bytes32)
    {
        revert Unsent();
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal view virtual override returns (uint256) {
        revert Unsent();
    }
}

abstract contract UnsendableTransmitter is TransmitterBase {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        virtual
        override
        returns (bytes32)
    {
        revert Unsent();
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal view virtual override returns (uint256) {
        revert Unsent();
    }
}
