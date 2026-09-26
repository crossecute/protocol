// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {OAppSenderUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";
import {OAppCoreUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MessagingFee} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {providerIdOf} from "src/protocols/ProviderHubTransceiver.sol";

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev Sender-only: inherits `OAppSenderUpgradeable`, not the combined `OAppUpgradeable`, so
///      there is no `lzReceive` to override-and-revert for R3.1. Absence, not a guard.
contract LzTransmitter is OwnableTransmitter, OAppSenderUpgradeable {
    /// @param _endpoint LayerZero endpoint on this chain. Set on the implementation; safe
    ///        because the implementation address lives in the proxy's ERC-1967 slot, not its
    ///        initcode, so this never moves a derived account address.
    constructor(address _endpoint) OAppCoreUpgradeable(_endpoint) {}

    /// @dev No peer set here: peers are per-destination, and a one-shot initializer cannot
    ///      know every chain this account will ever reach. The owner calls `setPeer` (plain
    ///      `onlyOwner`, unlike `grantRole`'s `onlyInitializing`) the first time it needs one.
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        override
        initializer
    {
        __Ownable_init(owner_);
        // Delegate = self: R6.4, any provider-side authority over an account is the account.
        __OAppSender_init(address(this));
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _checkOwner() internal view override(OwnableTransmitter, OwnableUpgradeable) {
        super._checkOwner();
    }

    /// @dev `recipient`'s address half is unused: LayerZero delivers to whatever `setPeer`
    ///      recorded for the eid, not to an address in the payload. Value is exact, not
    ///      `msg.value` (`OutboundBase` widens the primitive for this); `_payNative` reverts
    ///      on any mismatch.
    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        uint32 dstEid = uint32(providerIdOf(transceiver, recipient));
        bytes memory options = LzMessage.options(attributes);
        _lzSend(dstEid, payload, options, MessagingFee(value, 0), _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint32 dstEid = uint32(providerIdOf(transceiver, recipient));
        bytes memory options = LzMessage.options(attributes);
        MessagingFee memory fee = _quote(dstEid, payload, options, false);
        return fee.nativeFee;
    }

    /// @notice One attribute, `LzMessage.OPTIONS_ATTRIBUTE`. Anything else is refused per ERC-7786.
    bytes4 public constant LZ_OPTIONS_ATTRIBUTE = LzMessage.OPTIONS_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == LZ_OPTIONS_ATTRIBUTE;
    }
}
