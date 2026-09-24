// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {IWormholeReceiver} from "@wormhole-sdk/interfaces/IWormholeRelayer.sol";

/// @notice Transceiver on every non-home chain.
contract WormholeSpokeTransceiver is SpokeTransceiverBase, IWormholeReceiver {
    address public immutable relayer;

    constructor(address relayer_) {
        relayer = relayer_;
    }

    /// @dev Plain stored value, not `ProviderChainId`: a spoke has exactly one destination.
    uint16 public homeWormholeChain;

    /// @dev Zero is `ProviderChainId`'s unset sentinel, mirrored here.
    error ZeroHomeWormholeChain();
    error UnexpectedSourceChain(uint16 sourceChain);

    /// @param homeWormholeChain_ Wormhole's chain id for the home chain.
    /// @dev Grants `GATEWAY_ROLE` to `relayer` directly — see
    ///      `WormholeHubTransceiver.initialize`.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        uint16 homeWormholeChain_
    ) external initializer {
        if (homeWormholeChain_ == 0) revert ZeroHomeWormholeChain();
        grantRole(GATEWAY_ROLE, relayer);
        homeWormholeChain = homeWormholeChain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, false
        );
    }

    /* ================================== sending =================================== */

    /// @dev No chainKey resolution: `_routeTo`/`_counterpartOn` already refuse every key but
    ///      `homeChainKey`, so `homeWormholeChain` is always the right destination.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return WormholeMessage.send(relayer, homeWormholeChain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return WormholeMessage.quote(relayer, homeWormholeChain, recipient, attributes);
    }

    bytes4 public constant WORMHOLE_GAS_LIMIT_ATTRIBUTE = WormholeMessage.GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev `sourceChain` is checked against `homeWormholeChain` so a sender at the hub's
    ///      address on any other chain is not accepted as the hub; `_authenticateOrigin` (via
    ///      `_onInbound`) then checks the sender itself.
    function receiveWormholeMessages(
        bytes calldata payload,
        bytes[] calldata additionalMessages,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 /* deliveryHash */
    ) external payable override onlyRole(GATEWAY_ROLE) {
        WormholeMessage.requireNoAdditionalMessages(additionalMessages);
        if (sourceChain != homeWormholeChain) revert UnexpectedSourceChain(sourceChain);
        _onInbound(homeRoute(), abi.encodePacked(WormholeMessage.senderOf(sourceAddress)), payload);
    }
}
