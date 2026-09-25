// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

/// @notice Transceiver on the home chain, for one OP Stack chain.
/// @dev `sendMessage` names no destination chain: each OP Stack chain has its own messenger,
///      so the destination is which messenger is called. `ProviderChainId` does not apply;
///      reaching a second OP Stack chain means deploying a second instance.
///
/// @dev One instance per chain is a trust-domain choice, not an interface limitation.
///      `messageProvider`/`minCounterpartProvenance` describe one trust level for everything
///      an instance reaches; Optimism's and Base's canonical bridges run the same software but
///      fail independently, so one instance reaching both would make one provenance dial
///      describe two things. See `provider-research.md` §2.
contract OpStackHubTransceiver is HubTransceiverBase, IOpStackRecipient {
    /// @notice The messenger on this chain paired with the one OP Stack chain this instance
    ///         reaches, and that chain's chainKey. Set on the implementation, not the proxy:
    ///         harmless, since neither affects a derived account address.
    address public immutable messenger;
    bytes32 public immutable messengerChainKey;

    constructor(address messenger_, bytes32 messengerChainKey_) {
        messenger = messenger_;
        messengerChainKey = messengerChainKey_;
    }

    /// @dev Grants `GATEWAY_ROLE` to `messenger` directly: `receiveOpStackMessage` is gated on
    ///      exactly this role, so leaving it to `gateways` would allow a deployment that
    ///      rejects every inbound message.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        grantRole(GATEWAY_ROLE, messenger);
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /* ================================== sending =================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return OpStackMessage.send(messenger, messengerChainKey, recipient, payload, attributes, value);
    }

    /// @dev Zero: see `OpStackMessage`.
    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return OpStackMessage.quote(messengerChainKey, recipient, attributes);
    }

    bytes4 public constant OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE = OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev The messenger relays only from `messengerChainKey`, so that is the route. The
    ///      sender is `xDomainMessageSender()` (see `OpStackMessage.sender`), and
    ///      `_authenticateOrigin` (via `_onInbound`) is the only sender check: no R3.3
    ///      exception.
    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        _onInbound(routeFor(messengerChainKey), abi.encodePacked(OpStackMessage.sender()), payload);
    }
}
