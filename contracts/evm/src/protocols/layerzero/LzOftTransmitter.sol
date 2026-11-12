// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {SignedTransmitter} from "src/messaging/outbound/SignedTransmitter.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {ILzOftConduitFactory, ILzOftSignedConduitFactory} from "src/protocols/layerzero/ILzOftConduitFactory.sol";

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
///      receiver views, builds each bootstrap's compose (`conduitBootstrap`) and names each
///      destination's eid and OFT. It relays nothing.
///
/// @dev Not an OApp: the OFT is the sender LayerZero sees, so this carries no OApp storage.
contract LzOftTransmitter is SignedTransmitter, ILzOftTransmitterInit {
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

    /// @dev The same factory envelope is quoted and sent by this conduit through its OFT.
    function _quoteSignedBootstrap(bytes32 chainKey, bytes memory body, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256)
    {
        (bytes memory recipient, bytes memory message) =
            ILzOftSignedConduitFactory(transceiver).signedConduitBootstrap(chainKey, body);
        return _quoteMessage(recipient, message, attributes);
    }

    /// @dev Preserve composeFrom and record the destination before the external OFT call.
    function _sendSignedBootstrap(bytes32 chainKey, bytes memory body, bytes[] memory attributes, uint256 fee)
        internal
        override
    {
        (bytes memory recipient, bytes memory message) =
            ILzOftSignedConduitFactory(transceiver).signedConduitBootstrap(chainKey, body);
        _sendMessage(recipient, message, attributes, fee);
    }

    /* ================================= transport =============================== */

    /// @dev Records a bootstrap's destination before the OFT is called, since the call reaches
    ///      arbitrary code.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        (SendParam memory param, bytes32 chainKey, Destination memory d, bool bootstrap) =
            _messageParam(recipient, payload, attributes);
        if (bootstrap) _destinations[chainKey] = d;
        LzOftMessage.send(homeOft, param, value, _refundTo());
        return bytes32(0);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256)
    {
        (SendParam memory param,,,) = _messageParam(recipient, payload, attributes);
        return LzOftMessage.quote(homeOft, param);
    }

    /// @dev The send to a chain with no recorded destination is its bootstrap: `sendMessage`
    ///      reaches only a bootstrapped chain, and the bootstrap records the destination before
    ///      the OFT is called. A bootstrap takes the destination from the factory, which holds
    ///      the same eid and OFT the record would. The peer is checked on every send because
    ///      the OFT's owner can change it.
    function _messageParam(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        private
        view
        returns (SendParam memory param, bytes32 chainKey, Destination memory d, bool bootstrap)
    {
        Erc7930.Interop memory io = Erc7930.parseStrict(recipient);
        chainKey = ChainKey.fromParsed(io);
        address to = Erc7930.toAddress(io);
        d = _destinations[chainKey];
        bootstrap = d.oft == address(0);
        if (bootstrap) {
            (d.eid, d.oft) = ILzOftConduitFactory(transceiver).destinationOf(address(this), chainKey);
        }
        LzOftMessage.requirePeer(homeOft, d.eid, d.oft);
        uint256 gas = bootstrap ? DeliveryGas.BOOTSTRAP : _defaultGas(payload);
        param = LzOftMessage.sendParam(d.eid, to, payload, attributes, gas);
    }
}
