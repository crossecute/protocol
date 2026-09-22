// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {OAppUpgradeable, Origin} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {OAppCoreUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {MessagingFee, MessagingReceipt} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered, shared by every
///         user's transmitter.
/// @dev Inherits the combined `OAppUpgradeable` (unlike `LzTransmitter`/`LzReceiver`): a hub
///      both sends bootstraps and receives diverging spokes' receiver reports.
contract LzHubTransceiver is HubTransceiverBase, OAppUpgradeable, ProviderChainId {
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __OApp_init(address(this)); // delegate = self, R6.4
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /* ============================== the eid table =============================== */

    event EidSet(bytes32 indexed chainKey, uint32 eid);

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape). Adding a spoke also needs
    ///      `setPeer` (inherited, `onlyOwner`) for its transceiver address.
    function setEid(bytes32 chainKey, uint32 eid) external onlyOwner {
        _setProviderId(chainKey, eid);
        emit EidSet(chainKey, eid);
    }

    /// @notice Called externally by every `LzTransmitter` this hub created; see
    ///         `ILzEidTable` there.
    function eidFor(bytes32 chainKey) external view returns (uint32) {
        return uint32(_providerIdFor(chainKey));
    }

    /* ================================== sending =================================== */

    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        uint32 dstEid = uint32(_providerIdFor(Erc7930.chainKey(recipient)));
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
        uint32 dstEid = uint32(_providerIdFor(Erc7930.chainKey(recipient)));
        bytes memory options = _optionsFrom(attributes);
        MessagingFee memory fee = _quote(dstEid, payload, options, false);
        return fee.nativeFee;
    }

    /// @dev Duplicated across LZ bindings rather than shared: no common ancestor for it that
    ///      wouldn't widen `OutboundBase` for every provider.
    bytes4 public constant LZ_OPTIONS_ATTRIBUTE = bytes4(keccak256("crossecute.lz.options"));

    error UnknownLzAttribute(bytes attribute);

    function _optionsFrom(bytes[] memory attributes) internal pure returns (bytes memory) {
        if (attributes.length == 0) return "";
        if (attributes.length > 1) revert UnknownLzAttribute(attributes[1]);
        bytes memory attribute = attributes[0];
        if (attribute.length < 4) revert UnknownLzAttribute(attribute);
        bytes4 selector;
        assembly {
            selector := mload(add(attribute, 32))
        }
        if (selector != LZ_OPTIONS_ATTRIBUTE) revert UnknownLzAttribute(attribute);
        uint256 optLen = attribute.length - 4;
        bytes memory out = new bytes(optLen);
        for (uint256 j; j < optLen; ++j) {
            out[j] = attribute[j + 4];
        }
        return out;
    }

    /* ================================= receiving =================================== */

    /// @dev R3.3 exception, hub's half — see `LzReceiver._lzReceive`. Each spoke has its own
    ///      peer entry (msig-set), so this stays 1:1 per source chain despite N spokes total.
    ///      Translates into `_onInbound`, not `_authenticateSender`, since the hub's inbound
    ///      path is registry-backed (N origins); `_authenticateOrigin` runs unmodified.
    function _lzReceive(
        Origin calldata _origin,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    ) internal override {
        bytes32 chainKey = _chainKeyOfProvider(_origin.srcEid);
        bytes memory route = routeFor(chainKey);
        bytes memory sender = abi.encodePacked(address(uint160(uint256(_origin.sender))));
        _onInbound(route, sender, _message);
    }
}
