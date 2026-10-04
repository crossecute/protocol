// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SymmetricTransceiverBase, TransceiverConfig} from "src/messaging/transceiver/SymmetricTransceiverBase.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice OP Stack on the transceiver that is hub and spoke at once, for one chain pair: an
///         OP Stack chain and its L1. The same contract runs on both sides, so an account
///         homed on either reaches the other.
/// @dev `sendMessage` names no destination chain: each side's messenger reaches only its
///      paired chain, so the destination is which messenger is called, and `ProviderChainId`
///      does not apply. Reaching a second OP Stack chain means a second pair, registered as its
///      own message provider so its transceivers get their own address.
///
/// @dev One pair per provider is also a trust-domain choice. `messageProvider` and
///      `minCounterpartProvenance` describe one trust level for everything an instance
///      reaches; Optimism's and Base's canonical bridges run the same software but fail
///      independently. See `provider-research.md` §2. No zkSync or Tron variant: an OP Stack
///      chain uses Ethereum's CREATE2 formula.
contract OpStackTransceiver is SymmetricTransceiverBase, IOpStackRecipient {
    bytes4 public constant OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE = OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE;

    /// @notice This chain's messenger for the pair, and the chainKey of the chain it reaches.
    ///         On the implementation, so neither reaches a derived account address.
    address public immutable messenger;
    bytes32 public immutable messengerChainKey;

    constructor(address messenger_, bytes32 messengerChainKey_) {
        if (messenger_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        messenger = messenger_;
        messengerChainKey = messengerChainKey_;
    }

    /// @dev Grants `GATEWAY_ROLE` to `messenger`: `receiveOpStackMessage` is gated on it.
    function initialize(TransceiverConfig memory c) external initializer {
        grantRole(GATEWAY_ROLE, messenger);
        __SymmetricTransceiver_init(c);
    }

    /* ===================================== sending ===================================== */

    /// @dev `OpStackMessage` refuses a recipient on any chain but `messengerChainKey`, so a
    ///      bootstrap elsewhere reverts at its quote.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
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

    /* ==================================== receiving ==================================== */

    /// @dev The messenger relays only from `messengerChainKey`, so that is the route. The
    ///      sender is `xDomainMessageSender()` (see `OpStackMessage.sender`), and the base's
    ///      `_authenticateOrigin` is the only sender check.
    function receiveOpStackMessage(bytes calldata payload) external override onlyRole(GATEWAY_ROLE) {
        _onInbound(routeFor(messengerChainKey), abi.encodePacked(OpStackMessage.sender()), payload);
    }
}
