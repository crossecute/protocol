// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderHubTransceiver} from "src/protocols/ProviderHubTransceiver.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered, shared by every
///         user's transmitter.
/// @dev One Mailbox serves both `dispatch`/`quoteDispatch` and inbound `process`->`handle`,
///      so `GATEWAY_ROLE` names one address. A Hyperlane domain is conventionally the EVM
///      chain id but not guaranteed to be, hence the domain table. See
///      `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
contract HyperlaneHubTransceiver is ProviderHubTransceiver, IMessageRecipient {
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
        __ProviderHub_init(owner_, treasury_, gateways, transmitterImplementation_, mailbox);
    }

    /* ============================== the domain table ============================== */

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setDomain(bytes32 chainKey, uint32 domain) external onlyOwner {
        _setProviderId(chainKey, domain);
    }

    /* ================================== sending =================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        uint32 domain = uint32(_providerIdOf(recipient));
        return HyperlaneMessage.dispatch(mailbox, domain, recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint32 domain = uint32(_providerIdOf(recipient));
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
        _onProviderInbound(origin, ProviderAddress.evmSender(sender), message);
    }
}
