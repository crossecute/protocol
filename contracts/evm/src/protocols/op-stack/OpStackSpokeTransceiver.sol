// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";

/// @notice Transceiver on the OP Stack chain that is not the home chain.
/// @dev Always the parity spoke, no divergent variant: an OP Stack chain runs standard
///      `op-geth` and Ethereum's own CREATE2 formula, unlike zkSync/Tron.
contract OpStackSpokeTransceiver is SpokeTransceiverBase, IOpStackRecipient {
    /// @notice This chain's `CrossDomainMessenger`, paired with the home chain's.
    address public immutable messenger;

    constructor(address messenger_) {
        messenger = messenger_;
    }

    /// @param homeChainKey_ keccak256 of the home chain's ERC-7930 chain identifier.
    /// @param homeChainIdentifier_ That identifier itself; checked against `homeChainKey_`.
    /// @param homeTransceiver_ The hub, in this chain's address format. No setter.
    /// @dev Grants `GATEWAY_ROLE` to `messenger` directly — see
    ///      `OpStackHubTransceiver.initialize`.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_
    ) external initializer {
        grantRole(GATEWAY_ROLE, messenger);
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, false
        );
    }

    /* ================================== sending =================================== */

    /// @dev Only the receiver report would use this, and it never fires here
    ///      (`addressesDiverge` is false); wired anyway so the seam does not revert.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return OpStackMessage.send(messenger, homeChainKey, recipient, payload, attributes, value);
    }

    /// @dev Zero: see `OpStackMessage`.
    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return OpStackMessage.quote(homeChainKey, recipient, attributes);
    }

    bytes4 public constant OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE = OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev The sender is `xDomainMessageSender()` (see `OpStackMessage.sender`), checked
    ///      against the hub by `_authenticateOrigin` via `_onInbound`.
    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        _onInbound(homeRoute(), abi.encodePacked(OpStackMessage.sender()), payload);
    }
}
