// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";

/// @notice Transceiver on every non-home chain.
contract HyperlaneSpokeTransceiver is SpokeTransceiverBase, IMessageRecipient {
    address public immutable mailbox;

    constructor(address mailbox_) {
        mailbox = mailbox_;
    }

    /// @dev Plain stored value, not `ProviderChainId`: a spoke has exactly one destination.
    uint32 public homeDomain;

    /// @dev Zero is `ProviderChainId`'s unset sentinel, mirrored here.
    error ZeroHomeDomain();
    error UnexpectedOrigin(uint32 origin);

    /// @param homeDomain_ Hyperlane's domain for the home chain.
    /// @dev Grants `GATEWAY_ROLE` to `mailbox` directly — see
    ///      `HyperlaneHubTransceiver.initialize`.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        uint32 homeDomain_
    ) external initializer {
        if (homeDomain_ == 0) revert ZeroHomeDomain();
        grantRole(GATEWAY_ROLE, mailbox);
        homeDomain = homeDomain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, false
        );
    }

    /* ================================== sending =================================== */

    /// @dev No chainKey resolution: `_routeTo`/`_counterpartOn` already refuse every key but
    ///      `homeChainKey`, so `homeDomain` is always the right destination.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return HyperlaneMessage.dispatch(mailbox, homeDomain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return HyperlaneMessage.quote(mailbox, homeDomain, recipient, payload, attributes, _refundTo());
    }

    bytes4 public constant HYPERLANE_GAS_LIMIT_ATTRIBUTE = HyperlaneMessage.GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev `origin` is checked against `homeDomain` so a sender at the hub's address on any
    ///      other chain is not accepted as the hub; `_authenticateOrigin` (via `_onInbound`)
    ///      then checks the sender itself. See `HyperlaneHubTransceiver.handle`.
    function handle(uint32 origin, bytes32 sender, bytes calldata message)
        external
        payable
        override
        onlyRole(GATEWAY_ROLE)
    {
        if (origin != homeDomain) revert UnexpectedOrigin(origin);
        _onInbound(homeRoute(), abi.encodePacked(TypeCasts.bytes32ToAddress(sender)), message);
    }
}
