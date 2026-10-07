// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {OAppUpgradeable, Origin} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {OAppCoreUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {LzHomePeer} from "src/protocols/layerzero/LzHomePeer.sol";
import {LzWriteOncePeer} from "src/protocols/layerzero/LzWriteOncePeer.sol";
import {ILzReceiverInit} from "src/protocols/layerzero/LzReceiver.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {Call} from "src/messaging/Call.sol";

/// @notice LayerZero on `TransceiverBase`, shared by the plain, zkSync, and Tron variants, which
///         differ only in address derivation.
///
/// @dev One OApp sends bootstraps and reports to any configured eid and receives both from
///      any. LayerZero delivers only from a set peer, so the owner sets one per eid, write-once
///      (`LzWriteOncePeer`), as well as the eid itself (`setEid`).
///
/// @dev No `GATEWAY_ROLE` check on delivery: OApp already requires `msg.sender == endpoint`,
///      and a transceiver's gateways cannot be revoked, so the role would only restate it.
abstract contract LzTransceiverBase is ProviderTransceiver, OAppUpgradeable, LzWriteOncePeer, LzHomePeer {
    bytes4 public constant LZ_OPTIONS_ATTRIBUTE = LzMessage.OPTIONS_ATTRIBUTE;

    /// eid => the one DVN pinned for that pathway, both ways. Unset follows LayerZero's
    /// defaults, which only a pathway defaulting to the dead DVN must not do (#51).
    mapping(uint32 => address) public dvnOf;

    event DvnPinned(uint32 indexed eid, address dvn);

    error ZeroDvn();
    error DvnAlreadyPinned(uint32 eid);
    /// @dev The transceiver stays its own delegate, so its endpoint config changes only here.
    error DelegateIsFixed();

    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        if (_endpoint == address(0)) revert ProviderAddress.ZeroEndpoint();
    }

    /// @dev The OApp is its own delegate (R6.4).
    /// @param governorHomeEid LayerZero's eid for the governor's home; see
    ///        `ProviderTransceiver._initGovernorHomeId`.
    /// @param governorHomeDvn This chain's DVN for the home's pathway, or zero for LayerZero's
    ///        defaults. Needed at birth where the default is the dead DVN, since the bootstrap
    ///        that creates the owner arrives over it.
    function __LzTransceiver_init(TransceiverConfig memory c, uint32 governorHomeEid, address governorHomeDvn)
        internal
        onlyInitializing
    {
        __OApp_init(address(this));
        _initGovernorHomeId(c.governorHome, governorHomeEid);
        if (governorHomeDvn != address(0)) _pinDvn(governorHomeEid, governorHomeDvn);
    }

    /// @notice Verify the pathway to and from `eid` with `dvn` alone. Write-once.
    function setDvn(uint32 eid, address dvn) external onlyOwner {
        _pinDvn(eid, dvn);
    }

    function _pinDvn(uint32 eid, address dvn) private {
        if (dvn == address(0)) revert ZeroDvn();
        if (dvnOf[eid] != address(0)) revert DvnAlreadyPinned(eid);
        dvnOf[eid] = dvn;
        LzMessage.pinSendDvn(address(endpoint), eid, dvn);
        LzMessage.pinReceiveDvn(address(endpoint), eid, dvn);
        emit DvnPinned(eid, dvn);
    }

    /// @dev OApp's `setDelegate` is not virtual, so it is refused here: a delegate other than
    ///      this contract could reconfigure every pathway, which `setDvn` keeps write-once.
    function _checkOwner() internal view virtual override {
        if (msg.sig == IOAppCore.setDelegate.selector) revert DelegateIsFixed();
        super._checkOwner();
    }

    /// @notice Set the peer for the governor's home eid to the counterpart there, which
    ///         LayerZero requires before it delivers the bootstrap that creates the owner.
    /// @dev After the base initializer, which sets the registry this resolves through and has
    ///      refused a home whose counterpart does not resolve.
    function _initGovernorHomePeer(TransceiverConfig memory c, uint32 governorHomeEid) internal onlyInitializing {
        bytes32 home = keccak256(c.governorHome);
        if (governorHomeEid == 0 || home == localChainKey || address(c.chainRegistry) == address(0)) return;
        _initHomePeer(governorHomeEid, _evmCounterpartOn(home));
    }

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape). An eid also needs its peer.
    function setEid(bytes32 chainKey, uint32 eid) external onlyOwner {
        _setProviderId(chainKey, eid);
    }

    /// @dev Resolves the inheritance diamond; the body is `LzWriteOncePeer`'s.
    function setPeer(uint32 eid, bytes32 peer) public virtual override(OAppCoreUpgradeable, LzWriteOncePeer) {
        super.setPeer(eid, peer);
    }

    /* =============================== account manufacture ============================== */

    /// @inheritdoc TransceiverBase
    /// @dev A receiver's peer is its transmitter on the account's home, so it is armed with that
    ///      home's eid, from the same table that admitted the bootstrap.
    function _accountInitializer(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        address sourceTransmitter,
        Call[] memory calls
    ) internal view virtual override returns (bytes memory) {
        if (homeChainKey == localChainKey) {
            return super._accountInitializer(owner, salt, homeChainKey, sourceTransmitter, calls);
        }
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 homeEid = uint32(_providerIdFor(homeChainKey));
        return abi.encodeCall(ILzReceiverInit.initialize, (sourceTransmitter, calls, homeEid, dvnOf[homeEid]));
    }

    /* ===================================== sending ===================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 dstEid = uint32(_providerIdOf(recipient));
        LzMessage.send(
            address(endpoint),
            dstEid,
            _getPeerOrRevert(dstEid),
            payload,
            attributes,
            _defaultGas(payload),
            value,
            _refundTo()
        );
        return bytes32(0);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint32 setter
        uint32 dstEid = uint32(_providerIdOf(recipient));
        return
            LzMessage.quote(
                address(endpoint), dstEid, _getPeerOrRevert(dstEid), payload, attributes, _defaultGas(payload)
            );
    }

    /* ==================================== receiving ==================================== */

    /// @dev R3.3 exception: OApp has already refused any sender but the eid's peer. The base
    ///      authenticates again against the counterpart and provenance bar.
    function _lzReceive(
        Origin calldata _origin,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    )
        internal
        override
    {
        _onProviderInbound(_origin.srcEid, ProviderAddress.evmSender(_origin.sender), _message);
    }
}

/// @notice The LayerZero transceiver on every chain whose addresses match Ethereum's.
contract LzTransceiver is LzTransceiverBase {
    constructor(address _endpoint) LzTransceiverBase(_endpoint) {}

    function initialize(TransceiverConfig memory c, uint32 governorHomeEid, address governorHomeDvn)
        external
        initializer
    {
        __LzTransceiver_init(c, governorHomeEid, governorHomeDvn);
        __TransceiverBase_init(c);
        _initGovernorHomePeer(c, governorHomeEid);
    }
}
