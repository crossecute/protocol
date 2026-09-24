// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OAppSenderUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";
import {OAppCoreUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MessagingFee, MessagingReceipt} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

/// @dev A transmitter has no eid table of its own: it's per-user and locked after creation,
///      so it reads the shared, owner-updatable table on `LzHubTransceiver` (via
///      `TransmitterBase.transceiver`) live, on every send.
interface ILzEidTable {
    function eidFor(bytes32 chainKey) external view returns (uint32);
}

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev Sender-only: inherits `OAppSenderUpgradeable`, not the combined `OAppUpgradeable`, so
///      there is no `lzReceive` to override-and-revert for R3.1. Absence, not a guard.
contract LzTransmitter is TransmitterBase, OAppSenderUpgradeable {
    /// @param _endpoint LayerZero endpoint on this chain. Set on the implementation; safe
    ///        because the implementation address lives in the proxy's ERC-1967 slot, not its
    ///        initcode, so this never moves a derived account address.
    constructor(address _endpoint) OAppCoreUpgradeable(_endpoint) {}

    /// @dev No peer set here: peers are per-destination, and a one-shot initializer cannot
    ///      know every chain this account will ever reach. The owner calls `setPeer` (plain
    ///      `onlyOwner`, unlike `grantRole`'s `onlyInitializing`) the first time it needs one.
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        // Delegate = self: R6.4, any provider-side authority over an account is the account.
        __OAppSender_init(address(this));
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
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
        uint32 dstEid = _eidFor(recipient);
        bytes memory options = _optionsFrom(attributes);
        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, options, MessagingFee(value, 0), _refundTo());
        return receipt.guid;
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint32 dstEid = _eidFor(recipient);
        bytes memory options = _optionsFrom(attributes);
        MessagingFee memory fee = _quote(dstEid, payload, options, false);
        return fee.nativeFee;
    }

    /// @notice One attribute: LZ execution options, as `abi.encodePacked(LZ_OPTIONS_ATTRIBUTE,
    ///         rawOptionsBytes)`. Anything else is refused per ERC-7786.
    bytes4 public constant LZ_OPTIONS_ATTRIBUTE = bytes4(keccak256("crossecute.lz.options"));

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == LZ_OPTIONS_ATTRIBUTE;
    }

    function _eidFor(bytes memory recipient) internal view returns (uint32) {
        return ILzEidTable(transceiver).eidFor(Erc7930.chainKey(recipient));
    }

    /// @dev Empty options is a valid default (LZ's executor applies its own gas limit), not
    ///      a missing one.
    function _optionsFrom(bytes[] memory attributes) internal pure returns (bytes memory options) {
        (, options) = ProviderAttribute.body(attributes, LZ_OPTIONS_ATTRIBUTE, 0);
    }
}
