// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {OAppSenderUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";
import {OAppCoreUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {providerIdOf} from "src/protocols/ProviderHubTransceiver.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {LzWriteOncePeer} from "src/protocols/layerzero/LzWriteOncePeer.sol";

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev Sender-only: inherits `OAppSenderUpgradeable`, not the combined `OAppUpgradeable`, so
///      there is no `lzReceive` to override-and-revert for R3.1. Absence, not a guard.
contract LzTransmitter is OwnableTransmitter, OAppSenderUpgradeable, LzWriteOncePeer {
    /// @param _endpoint LayerZero endpoint on this chain. Set on the implementation; safe
    ///        because the implementation address lives in the proxy's ERC-1967 slot, not its
    ///        initcode, so this never moves a derived account address.
    constructor(address _endpoint) OAppCoreUpgradeable(_endpoint) {
        if (_endpoint == address(0)) revert ProviderAddress.ZeroEndpoint();
    }

    /// @dev No peer set here: peers are per-destination, and a one-shot initializer cannot
    ///      know every chain this account will ever reach. The owner calls `setPeer` once per
    ///      destination before its first send there; `LzWriteOncePeer` makes it final.
    function initialize(address owner_, address transceiver_, bytes32 salt_) external override initializer {
        __Ownable_init(owner_);
        // Delegate = self: R6.4, any provider-side authority over an account is the account.
        __OAppSender_init(address(this));
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _checkOwner() internal view override(OwnableTransmitter, OwnableUpgradeable) {
        super._checkOwner();
    }

    /// @dev Resolves the inheritance diamond; the body is `LzWriteOncePeer`'s.
    function setPeer(uint32 eid, bytes32 peer) public override(OAppCoreUpgradeable, LzWriteOncePeer) {
        super.setPeer(eid, peer);
    }

    /// @dev `recipient`'s address half is unused: LayerZero delivers to whatever `setPeer`
    ///      recorded for the eid, not to an address in the payload. Value is exact, not
    ///      `msg.value` (`OutboundBase` widens the primitive for this); `_payNative` reverts
    ///      on any mismatch.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 dstEid = uint32(providerIdOf(transceiver, recipient));
        bytes memory options = LzMessage.options(attributes);
        _lzSend(dstEid, payload, options, MessagingFee(value, 0), _refundTo());
        return bytes32(0);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
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
