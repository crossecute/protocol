// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {Call} from "src/messaging/Call.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {ILzOftConduitFactory} from "src/protocols/layerzero/ILzOftConduitFactory.sol";

/// @dev The initializer the factory arms a transmitter with; `LzOftTransmitter.initialize` is
///      overloaded, so it is named here for `abi.encodeCall`.
interface ILzOftTransmitterInit {
    function initialize(address owner, address factory, bytes32 salt, address homeOft) external;
}

/// @notice A `layerzero-oft` conduit on its home: sends every message, its bootstraps
///         included, through its operator's OFT, as the `send` caller the destination
///         authenticates by `composeFrom`.
///
/// @dev Its transceiver is the factory that created it, which answers `TransmitterBase`'s
///      receiver views and holds each destination's leaf and proof. Nothing else is read from
///      it, and it relays nothing.
///
/// @dev Not an OApp: the OFT is the sender LayerZero sees, so this carries no OApp storage.
contract LzOftTransmitter is OwnableTransmitter, ILzOftTransmitterInit {
    bytes4 public constant LZ_OPTIONS_ATTRIBUTE = LzMessage.OPTIONS_ATTRIBUTE;

    struct Destination {
        uint32 eid;
        address oft;
    }

    /// @notice The OFT this conduit sends through, bound into its address by the factory.
    address public homeOft;

    mapping(bytes32 chainKey => Destination) internal _destinations;

    error UseLzOftInitializer();

    /// @dev The factory arms this with `homeOft`, so the plain shape would leave it unset.
    function initialize(address, address, bytes32) external pure override {
        revert UseLzOftInitializer();
    }

    function initialize(
        address owner_,
        address factory_,
        bytes32 salt_,
        // forge-lint: disable-next-line(missing-zero-check) the factory refuses an OFT with no endpoint
        address homeOft_
    )
        external
        override
        initializer
    {
        __OwnableTransmitter_init(owner_, factory_, salt_);
        homeOft = homeOft_;
    }

    /// @notice The eid and OFT a bootstrap recorded for `chainKey`; zero before it.
    function destinationOf(bytes32 chainKey) external view returns (uint32 eid, address oft) {
        Destination memory d = _destinations[chainKey];
        return (d.eid, d.oft);
    }

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == LZ_OPTIONS_ATTRIBUTE;
    }

    /* ================================== Path A ================================= */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        LzOftMessage.send(homeOft, _messageParam(recipient, payload, attributes), value, _refundTo());
        return bytes32(0);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256)
    {
        return LzOftMessage.quote(homeOft, _messageParam(recipient, payload, attributes));
    }

    /// @dev `recipient` is the receiver `sendMessage` already matched to this conduit's record,
    ///      so its chain has a bootstrapped destination. The peer is checked again because the
    ///      OFT's owner can change it after the bootstrap.
    function _messageParam(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        private
        view
        returns (SendParam memory)
    {
        Destination memory d = _destinations[ChainKey.fromIdentifier(recipient)];
        LzOftMessage.requirePeer(homeOft, d.eid, d.oft);
        address receiver = Erc7930.toAddress(Erc7930.parseStrict(recipient));
        return LzOftMessage.sendParam(d.eid, receiver, payload, attributes, _defaultGas(payload));
    }

    /* ================================= bootstrap =============================== */

    function _quoteBootstrap(bytes32 chainKey, Call[] calldata calls, bytes[] calldata attributes)
        internal
        view
        override
        returns (uint256)
    {
        (SendParam memory param,) = _bootstrapParam(chainKey, calls, attributes);
        return LzOftMessage.quote(homeOft, param);
    }

    /// @dev Records the destination before the OFT is called, as `_markBootstrapped` records
    ///      the route: the call reaches arbitrary code.
    function _sendBootstrap(bytes32 chainKey, Call[] calldata calls, bytes[] calldata attributes, uint256 fee)
        internal
        override
    {
        (SendParam memory param, Destination memory d) = _bootstrapParam(chainKey, calls, attributes);
        _destinations[chainKey] = d;
        LzOftMessage.send(homeOft, param, fee, _refundTo());
    }

    /// @dev Sent to the factory on the destination, which derives this conduit from the message
    ///      and proves the delivering OFT into `destRoot`.
    function _bootstrapParam(bytes32 chainKey, Call[] calldata calls, bytes[] calldata attributes)
        private
        view
        returns (SendParam memory param, Destination memory d)
    {
        (uint32 eid, address dstOft, uint32 homeEid, bytes32 destRoot, bytes32[] memory proof) =
            ILzOftConduitFactory(transceiver).bootstrapRoute(address(this), chainKey);
        LzOftMessage.requirePeer(homeOft, eid, dstOft);

        bytes memory compose = LzOftMessage.encodeBootstrap(
            LzOftMessage.Bootstrap(deployer, conduitSalt, ChainKey.local(), homeEid, homeOft, destRoot, proof, calls)
        );
        param = LzOftMessage.sendParam(eid, transceiver, compose, attributes, DeliveryGas.BOOTSTRAP);
        d = Destination(eid, dstOft);
    }
}
