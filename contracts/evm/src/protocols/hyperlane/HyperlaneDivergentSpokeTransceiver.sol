// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ZkSyncSpokeTransceiver,
    TronSpokeTransceiver
} from "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";
import {ProviderOrigin} from "src/protocols/ProviderOrigin.sol";

/// @notice Spoke on a chain whose CREATE2 formula is not Ethereum's: zkSync Era and Tron.
///         Hyperlane wiring in both is identical to `HyperlaneSpokeTransceiver`'s, repeated
///         rather than shared since the two have no common concrete base to hold it.

/// @dev Overrides both `predictCrossAccount` and `_deployAccount`: zkSync diverges in the
///      deployment mechanism as well as the address.
contract HyperlaneZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, IMessageRecipient {
    address public immutable mailbox;

    constructor(address mailbox_) {
        mailbox = mailbox_;
    }

    uint32 public homeDomain;

    error ZeroHomeDomain();

    /// @param accountBytecodeHash_ ZKSOLC artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint32 homeDomain_
    ) external initializer {
        if (homeDomain_ == 0) revert ZeroHomeDomain();
        grantRole(GATEWAY_ROLE, mailbox);
        homeDomain = homeDomain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

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

/// @dev Overrides `predictCrossAccount` only: Tron runs raw-initcode CREATE2 with a
///      different derived address, no different deployment mechanism.
contract HyperlaneTronSpokeTransceiver is TronSpokeTransceiver, IMessageRecipient {
    address public immutable mailbox;

    constructor(address mailbox_) {
        mailbox = mailbox_;
    }

    uint32 public homeDomain;

    error ZeroHomeDomain();

    /// @param accountBytecodeHash_ TRON-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint32 homeDomain_
    ) external initializer {
        if (homeDomain_ == 0) revert ZeroHomeDomain();
        grantRole(GATEWAY_ROLE, mailbox);
        homeDomain = homeDomain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

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
