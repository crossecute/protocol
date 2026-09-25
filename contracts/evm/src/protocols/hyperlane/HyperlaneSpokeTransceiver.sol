// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {ProviderOrigin} from "src/protocols/ProviderOrigin.sol";

/// @notice Hyperlane wiring shared by every spoke variant (this file's, and the zkSync/Tron
///         ones in `HyperlaneDivergentSpokeTransceiver.sol`), which differ only in address
///         derivation.
abstract contract HyperlaneSpokeBase is SpokeTransceiverBase, IMessageRecipient {
    address public immutable mailbox;

    constructor(address mailbox_) {
        mailbox = mailbox_;
    }

    /// @dev Plain stored value, not `ProviderChainId`: a spoke has exactly one destination.
    uint32 public homeDomain;

    /// @dev Zero is `ProviderChainId`'s unset sentinel, mirrored here.
    error ZeroHomeDomain();

    /// @param homeDomain_ Hyperlane's domain for the home chain.
    /// @dev Grants `GATEWAY_ROLE` to `mailbox` directly — see
    ///      `HyperlaneHubTransceiver.initialize`.
    function __HyperlaneSpoke_init(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bool addressesDiverge_,
        uint32 homeDomain_
    ) internal onlyInitializing {
        if (homeDomain_ == 0) revert ZeroHomeDomain();
        grantRole(GATEWAY_ROLE, mailbox);
        homeDomain = homeDomain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, addressesDiverge_
        );
    }

    /* ================================== sending =================================== */

    /// @dev No chainKey resolution: `_routeTo`/`_counterpartOn` already refuse every key but
    ///      `homeChainKey`, so `homeDomain` is always the right destination.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        virtual
        override
        returns (bytes32 sendId)
    {
        return HyperlaneMessage.dispatch(mailbox, homeDomain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        virtual
        override
        returns (uint256 nativeFee)
    {
        return HyperlaneMessage.quote(mailbox, homeDomain, recipient, payload, attributes, _refundTo());
    }

    bytes4 public constant HYPERLANE_GAS_LIMIT_ATTRIBUTE = HyperlaneMessage.GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev Origin domain per `ProviderOrigin`; `_authenticateOrigin` checks the sender. See
    ///      `HyperlaneHubTransceiver.handle`.
    function handle(uint32 origin, bytes32 sender, bytes calldata message)
        external
        payable
        override
        onlyRole(GATEWAY_ROLE)
    {
        ProviderOrigin.requireHome(origin, homeDomain);
        _onInbound(homeRoute(), abi.encodePacked(TypeCasts.bytes32ToAddress(sender)), message);
    }
}

/// @notice Transceiver on every non-home chain whose addresses match Ethereum's.
contract HyperlaneSpokeTransceiver is HyperlaneSpokeBase {
    constructor(address mailbox_) HyperlaneSpokeBase(mailbox_) {}

    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        uint32 homeDomain_
    ) external initializer {
        __HyperlaneSpoke_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, false, homeDomain_
        );
    }
}
