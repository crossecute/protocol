// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {OAppUpgradeable, Origin} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {OAppCoreUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {MessagingFee} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

/// @notice Transceiver on every non-home chain.
/// @dev Both halves of OApp: sends the receiver report home (diverging spokes) and receives
///      every bootstrap.
contract LzSpokeTransceiver is SpokeTransceiverBase, OAppUpgradeable {
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    /// @dev Plain stored value, not `ProviderChainId`: a spoke has exactly one destination.
    uint32 public homeEid;

    /// @dev Zero is LayerZero's unset sentinel (`ProviderChainId`'s convention, mirrored here
    ///      since a spoke's single eid bypasses that mixin entirely).
    error ZeroHomeEid();
    /// @dev `homeTransceiver_` is cast to an `address` below; anything but 20 bytes would
    ///      silently truncate or pad into the wrong peer.
    error InvalidHomeTransceiverLength();

    /// @param homeEid_ LayerZero's id for the home chain. Written directly to OApp peer
    ///        storage here (not via `setPeer`, which is `onlyOwner` — this contract has no
    ///        `Ownable`), since this initializer is the only window it ever gets.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        uint32 homeEid_
    ) external initializer {
        if (homeEid_ == 0) revert ZeroHomeEid();
        if (homeTransceiver_.length != 20) revert InvalidHomeTransceiverLength();
        homeEid = homeEid_;
        __OApp_init(address(this)); // delegate = self, R6.4
        _getOAppCoreStorage().peers[homeEid_] =
            bytes32(uint256(uint160(address(bytes20(homeTransceiver_)))));
        emit PeerSet(homeEid_, bytes32(uint256(uint160(address(bytes20(homeTransceiver_))))));
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            false
        );
    }

    /* ============================ receiver manufacture =========================== */

    /// @dev Adds `homeEid` to the base two-arg shape so `LzReceiver` can set its peer in the
    ///      same locked call.
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

    /* ================================== sending =================================== */

    /// @dev No chainKey resolution: `_routeTo`/`_counterpartOn` already refuse every key but
    ///      `homeChainKey`, so `homeEid` is always the right destination.
    function _sendMessage(
        bytes memory, /* recipient */
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        bytes memory options = _optionsFrom(attributes);
        _lzSend(homeEid, payload, options, MessagingFee(value, 0), _refundTo());
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

    function _optionsFrom(bytes[] memory attributes) internal pure returns (bytes memory options) {
        (, options) = ProviderAttribute.body(attributes, LZ_OPTIONS_ATTRIBUTE, 0);
    }

    /* ================================= receiving =================================== */

    /// @dev R3.3 exception, spoke's half — see `LzReceiver._lzReceive`. `route` is
    ///      `homeRoute()` directly: a spoke has one valid origin, and LayerZero's own peer
    ///      check already constrains `_origin.srcEid` to `homeEid`.
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
