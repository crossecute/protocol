// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered, shared by every
///         user's transmitter.
/// @dev One Mailbox serves both `dispatch`/`quoteDispatch` and inbound `process`->`handle`,
///      so `GATEWAY_ROLE` names one address. A Hyperlane domain is conventionally the EVM
///      chain id but not guaranteed to be, hence the domain table. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
contract HyperlaneHubTransceiver is HubTransceiverBase, ProviderChainId, IMessageRecipient {
    /// @notice Hyperlane Mailbox on this chain. Set on the implementation, not the proxy:
    ///         harmless, since it never affects a derived account address.
    address public immutable mailbox;

    constructor(address mailbox_) {
        mailbox = mailbox_;
    }

    /// @dev Grants `GATEWAY_ROLE` to `mailbox` directly: `handle` is gated on exactly this
    ///      role, so leaving it to `gateways` would allow a deployment that rejects every
    ///      inbound message. `gateways` still names any additional trusted endpoints.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        grantRole(GATEWAY_ROLE, mailbox);
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /* ============================== the domain table ============================== */

    event DomainSet(bytes32 indexed chainKey, uint32 domain);

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setDomain(bytes32 chainKey, uint32 domain) external onlyOwner {
        _setProviderId(chainKey, domain);
        emit DomainSet(chainKey, domain);
    }

    /// @notice Called externally by every `HyperlaneTransmitter` this hub created; see
    ///         `IHyperlaneDomainTable` there.
    function domainFor(bytes32 chainKey) external view returns (uint32) {
        return uint32(_providerIdFor(chainKey));
    }

    /* ================================== sending =================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        uint32 domain = uint32(_providerIdFor(Erc7930.chainKey(recipient)));
        return HyperlaneMessage.dispatch(mailbox, domain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint32 domain = uint32(_providerIdFor(Erc7930.chainKey(recipient)));
        return HyperlaneMessage.quote(mailbox, domain, recipient, payload, attributes, _refundTo());
    }

    bytes4 public constant HYPERLANE_GAS_LIMIT_ATTRIBUTE = HyperlaneMessage.GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev No R3.3 exception: `Mailbox.process` verifies the ISM, not the source-chain
    ///      sender, so `_authenticateOrigin` (via `_onInbound`) is the only sender check. An
    ///      unmapped `origin` reverts in `_chainKeyOfProvider`.
    function handle(uint32 origin, bytes32 sender, bytes calldata message)
        external
        payable
        override
        onlyRole(GATEWAY_ROLE)
    {
        bytes memory route = routeFor(_chainKeyOfProvider(origin));
        _onInbound(route, abi.encodePacked(TypeCasts.bytes32ToAddress(sender)), message);
    }
}
