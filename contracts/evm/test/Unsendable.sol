// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";

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

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        revert Unsent();
    }
}

/// @notice A transceiver owned by an address the test names, for suites about routing and
///         counterparts rather than how the owner is derived (`Transceiver.t.sol` covers that).
///         It never creates an account, so the implementations only have to be non-zero.
contract OwnedTransceiver is UnsendableTransceiver {
    function initialize(address owner_) external initializer {
        __TransceiverBase_init(
            TransceiverConfig({
                gateways: new address[](0),
                transmitterImplementation: address(0x1E19),
                receiverImplementation: address(0x1E19),
                governorOwner: owner_,
                governorSalt: bytes32(0),
                governorHome: ChainKey.local(),
                treasury: address(0x7EA5)
            })
        );
        _transferOwnership(owner_);
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

abstract contract UnsendableTransmitter is OwnableTransmitter {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        virtual
        override
        returns (bytes32)
    {
        revert Unsent();
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        revert Unsent();
    }
}
