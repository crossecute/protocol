// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";

/// @notice The account home most suites use: Ethereum.
function home() pure returns (bytes32) {
    return ChainKey.forEvm(1);
}

/// @notice A transceiver configuration homed on Ethereum, with no registry and no gateways.
///         A suite that needs another field sets it on the returned copy.
function transceiverConfig(address governor, address transmitterImpl, address receiverImpl, address treasury)
    pure
    returns (TransceiverConfig memory)
{
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: transmitterImpl,
        receiverImplementation: receiverImpl,
        governorOwner: governor,
        governorSalt: bytes32(0),
        governorHome: Erc7930.encodeEvmChain(1),
        treasury: treasury,
        chainRegistry: IChainRegistryRefs(address(0)),
        messageProvider: bytes32(0),
        minCounterpartProvenance: Provenance.Unknown
    });
}

/// @notice `transceiverConfig` with placeholder governor, transmitter, and treasury.
function transceiverConfig(address receiverImpl) pure returns (TransceiverConfig memory) {
    return transceiverConfig(address(0x5165), address(0xBEEF), receiverImpl, address(0x7EA5));
}

function toBytes32(address a) pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
}

/// @notice A transceiver's extension functions, reached through its `fallback`, for a test that
///         holds the transceiver under its own type.
function ext(address transceiver) pure returns (TransceiverExtension) {
    return TransceiverExtension(transceiver);
}

/// @notice A test transceiver with its own extension, deployed with it, so each copy reads the
///         chain id it is deployed under as a production pair does. A harness that derives
///         accounts its own way overrides `_newExtension` with an extension that derives alike.
abstract contract TestTransceiver is TransceiverBase {
    constructor() TransceiverBase(_newExtension()) {}

    function _newExtension() internal virtual returns (address) {
        return address(new TransceiverExtension());
    }
}

/// @notice For harnesses that exercise everything but the transport: `OutboundBase`'s two
///         provider seams, as reverts. One per base, because a mixin beside the base would
///         collide with the functions the base itself overrides from `OutboundBase`. The
///         `AnyGateway` contracts below extend these in a line for the same reason.

error Unsent();

abstract contract UnsendableTransceiver is TestTransceiver {
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

/// @dev A harness trusts any gateway, which no deployment may do. Overriding the membership
///      read rather than granting a role keeps each test on its own subject.
abstract contract AnyGatewayReceiver is ReceiverBase {
    function hasRole(bytes32 role, address account) public view virtual override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev See `AnyGatewayReceiver`.
abstract contract AnyGatewayTransceiver is UnsendableTransceiver {
    function hasRole(bytes32 role, address account) public view virtual override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev See `AnyGatewayReceiver`.
abstract contract AnyGatewayTransmitter is UnsendableTransmitter {
    function hasRole(bytes32 role, address account) public view virtual override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @notice A transceiver owned by an address the test names, for suites about routing and
///         counterparts rather than how the owner is derived (`Transceiver.t.sol` covers that).
///         It never creates an account, so the implementations only have to be non-zero.
contract OwnedTransceiver is AnyGatewayTransceiver {
    function initialize(address owner_) external initializer {
        TransceiverConfig memory c = transceiverConfig(owner_, address(0x1E19), address(0x1E19), address(0x7EA5));
        c.governorHome = Erc7930.encodeEvmChain(block.chainid);
        __TransceiverBase_init(c);
        _transferOwnership(owner_);
    }
}
