// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {IWormholeReceiver} from "@wormhole-sdk/interfaces/IWormholeRelayer.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered, shared by every
///         user's transmitter.
/// @dev One Relayer serves both `sendPayloadToEvm`/`quoteEVMDeliveryPrice` and inbound
///      `receiveWormholeMessages`, so `GATEWAY_ROLE` names one address. The Wormhole chain
///      id is its own `uint16` enumeration, not an EVM chain id, hence the table. See
///      `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`.
contract WormholeHubTransceiver is HubTransceiverBase, ProviderChainId, IWormholeReceiver {
    /// @notice Wormhole Relayer on this chain. Set on the implementation, not the proxy:
    ///         harmless, since it never affects a derived account address.
    address public immutable relayer;

    constructor(address relayer_) {
        relayer = relayer_;
    }

    /// @dev Grants `GATEWAY_ROLE` to `relayer` directly: `receiveWormholeMessages` is gated on
    ///      exactly this role, so leaving it to `gateways` would allow a deployment that
    ///      rejects every inbound message.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        grantRole(GATEWAY_ROLE, relayer);
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /* ============================ the chain-id table ============================= */

    event WormholeChainSet(bytes32 indexed chainKey, uint16 wormholeChain);

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setWormholeChain(bytes32 chainKey, uint16 wormholeChain) external onlyOwner {
        _setProviderId(chainKey, wormholeChain);
        emit WormholeChainSet(chainKey, wormholeChain);
    }

    /// @notice Called externally by every `WormholeTransmitter` this hub created; see
    ///         `IWormholeChainTable` there.
    function wormholeChainFor(bytes32 chainKey) external view returns (uint16) {
        return uint16(_providerIdFor(chainKey));
    }

    /* ================================== sending =================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        uint16 targetChain = uint16(_providerIdFor(Erc7930.chainKey(recipient)));
        return WormholeMessage.send(relayer, targetChain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint16 targetChain = uint16(_providerIdFor(Erc7930.chainKey(recipient)));
        return WormholeMessage.quote(relayer, targetChain, recipient, attributes);
    }

    bytes4 public constant WORMHOLE_GAS_LIMIT_ATTRIBUTE = WormholeMessage.GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev No R3.3 exception: the Relayer authenticates the delivery VAA, not the source-chain
    ///      sender, so `_authenticateOrigin` (via `_onInbound`) is the only sender check. An
    ///      unmapped `sourceChain` reverts in `_chainKeyOfProvider`.
    function receiveWormholeMessages(
        bytes calldata payload,
        bytes[] calldata additionalMessages,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 /* deliveryHash */
    ) external payable override onlyRole(GATEWAY_ROLE) {
        WormholeMessage.requireNoAdditionalMessages(additionalMessages);
        bytes memory route = routeFor(_chainKeyOfProvider(sourceChain));
        _onInbound(route, abi.encodePacked(WormholeMessage.senderOf(sourceAddress)), payload);
    }
}
