// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Hyperlane on `TransceiverBase`, shared by the plain, zkSync, and Tron variants, which
///         differ only in address derivation.
///
/// @dev One Mailbox serves both `dispatch`/`quoteDispatch` and inbound `process`->`handle`,
///      so `GATEWAY_ROLE` names one address, granted at initialization rather than relying on
///      the deployment to list it. A Hyperlane domain is conventionally the EVM chain id but
///      not guaranteed to be, hence the domain table. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
abstract contract HyperlaneTransceiverBase is ProviderTransceiver, IMessageRecipient {
    bytes4 public constant HYPERLANE_GAS_LIMIT_ATTRIBUTE = HyperlaneMessage.GAS_LIMIT_ATTRIBUTE;

    /// @notice Hyperlane Mailbox on this chain. On the implementation, so it never reaches a
    ///         derived account address.
    address public immutable mailbox;

    constructor(address mailbox_) {
        if (mailbox_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        mailbox = mailbox_;
    }

    function __HyperlaneTransceiver_init() internal onlyInitializing {
        __ProviderTransceiver_init(mailbox);
    }

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setDomain(bytes32 chainKey, uint32 domain) external onlyOwner {
        _setProviderId(chainKey, domain);
    }

    /* ===================================== sending ===================================== */

    /// @dev `_refundTo` is the float during a report and the caller otherwise, so the hooks'
    ///      overpayment refund never lands on a relayer.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 domain = uint32(_providerIdOf(recipient));
        return HyperlaneMessage.dispatch(mailbox, domain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 domain = uint32(_providerIdOf(recipient));
        return HyperlaneMessage.quote(mailbox, domain, recipient, payload, attributes, _refundTo());
    }

    /* ==================================== receiving ==================================== */

    /// @dev `Mailbox.process` verifies the ISM, not the source-chain sender, so the base's
    ///      `_authenticateOrigin` is the only sender check. An unmapped domain reverts in the
    ///      table.
    function handle(uint32 origin, bytes32 sender, bytes calldata message)
        external
        payable
        override
        onlyRole(GATEWAY_ROLE)
    {
        _onProviderInbound(origin, ProviderAddress.evmSender(sender), message);
    }
}

/// @notice The Hyperlane transceiver on every chain whose addresses match Ethereum's.
contract HyperlaneTransceiver is HyperlaneTransceiverBase {
    constructor(address mailbox_) HyperlaneTransceiverBase(mailbox_) {}

    function initialize(TransceiverConfig memory c) external initializer {
        __HyperlaneTransceiver_init();
        __TransceiverBase_init(c);
    }
}
