// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ZkSyncSpokeTransceiver, TronSpokeTransceiver} from
    "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {Call} from "src/messaging/Call.sol";
import {ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {OAppUpgradeable, Origin} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {OAppCoreUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {MessagingFee, MessagingReceipt} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Spoke on a chain whose CREATE2 formula is not Ethereum's: zkSync Era and Tron.
///         One concrete contract each, chosen at deploy time (see
///         `DivergentSpokeTransceiver.sol`); LayerZero wiring in both is identical to
///         `LzSpokeTransceiver`'s, repeated rather than shared since the two diverge from
///         each other in `predictCrossAccount`/`_deployAccount` and have no common concrete
///         base to hold it.

/// @dev Overrides both `predictCrossAccount` and `_deployAccount`: zkSync diverges in the
///      deployment mechanism as well as the address.
contract LzZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, OAppUpgradeable {
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    uint32 public homeEid;

    /// @param accountBytecodeHash_ ZKSOLC artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint32 homeEid_
    ) external initializer {
        homeEid = homeEid_;
        __OApp_init(address(this));
        // Not `setPeer` (onlyOwner; a spoke has no Ownable) — writes the same storage.
        _getOAppCoreStorage().peers[homeEid_] =
            bytes32(uint256(uint160(address(bytes20(homeTransceiver_)))));
        emit PeerSet(homeEid_, bytes32(uint256(uint160(address(bytes20(homeTransceiver_))))));
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        override
        returns (bytes memory)
    {
        return abi.encodeCall(
            ILzReceiverInit.initialize, (predictCrossAccount(owner, salt), calls, homeEid)
        );
    }

    function _sendMessage(
        bytes memory, /* recipient */
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        bytes memory options = _optionsFrom(attributes);
        MessagingReceipt memory receipt =
            _lzSend(homeEid, payload, options, MessagingFee(value, 0), _refundTo());
        return receipt.guid;
    }

    function _quoteMessage(bytes memory, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        bytes memory options = _optionsFrom(attributes);
        MessagingFee memory fee = _quote(homeEid, payload, options, false);
        return fee.nativeFee;
    }

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

    function _lzReceive(
        Origin calldata _origin,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    ) internal override {
        bytes memory sender = abi.encodePacked(address(uint160(uint256(_origin.sender))));
        _onInbound(homeRoute(), sender, _message);
    }
}

/// @dev Overrides `predictCrossAccount` only: Tron runs raw-initcode CREATE2 with a
///      different derived address, no different deployment mechanism.
contract LzTronSpokeTransceiver is TronSpokeTransceiver, OAppUpgradeable {
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    uint32 public homeEid;

    /// @param accountBytecodeHash_ TRON-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint32 homeEid_
    ) external initializer {
        homeEid = homeEid_;
        __OApp_init(address(this));
        // Not `setPeer` (onlyOwner; a spoke has no Ownable) — writes the same storage.
        _getOAppCoreStorage().peers[homeEid_] =
            bytes32(uint256(uint160(address(bytes20(homeTransceiver_)))));
        emit PeerSet(homeEid_, bytes32(uint256(uint160(address(bytes20(homeTransceiver_))))));
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        override
        returns (bytes memory)
    {
        return abi.encodeCall(
            ILzReceiverInit.initialize, (predictCrossAccount(owner, salt), calls, homeEid)
        );
    }

    function _sendMessage(
        bytes memory, /* recipient */
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        bytes memory options = _optionsFrom(attributes);
        MessagingReceipt memory receipt =
            _lzSend(homeEid, payload, options, MessagingFee(value, 0), _refundTo());
        return receipt.guid;
    }

    function _quoteMessage(bytes memory, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        bytes memory options = _optionsFrom(attributes);
        MessagingFee memory fee = _quote(homeEid, payload, options, false);
        return fee.nativeFee;
    }

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

    function _lzReceive(
        Origin calldata _origin,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    ) internal override {
        bytes memory sender = abi.encodePacked(address(uint160(uint256(_origin.sender))));
        _onInbound(homeRoute(), sender, _message);
    }
}
