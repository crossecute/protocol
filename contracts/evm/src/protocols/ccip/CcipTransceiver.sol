// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CcipConfig, ICcipLaneConfig} from "src/protocols/ccip/CcipConfig.sol";
import {CcipPolicy} from "src/protocols/ccip/CcipPolicy.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice CCIP on `TransceiverBase`, shared by the standard EVM, zkSync, and Tron variants, which
///         differ only in address derivation.
///
/// @dev One Router serves both directions (`ccipSend`/`getFee` and inbound `ccipReceive`), so
///      `GATEWAY_ROLE` names one address, granted at initialization rather than relying on the
///      deployment to list it.
abstract contract CcipTransceiverBase is ProviderTransceiver, CcipPolicy, IAny2EVMMessageReceiverV2, ICcipLaneConfig {
    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE = CcipMessage.EXTRA_ARGS_ATTRIBUTE;
    bytes4 public constant CCIP_EXTRA_ARGS_V3_ATTRIBUTE = CcipMessage.EXTRA_ARGS_V3_ATTRIBUTE;

    /// @notice CCIP Router on this chain. On the implementation, so it never reaches a derived
    ///         conduit address.
    address public immutable router;

    constructor(address router_, address extension_) TransceiverBase(extension_) {
        if (router_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        router = router_;
    }

    /// @param governorHomeSelector CCIP's selector for the governor's home; see
    ///        `ProviderTransceiver._initGovernorHomeId`.
    function __CcipTransceiver_init(TransceiverConfig memory c, uint64 governorHomeSelector) internal onlyInitializing {
        __ProviderTransceiver_init(router);
        _initGovernorHomeId(c.governorHome, governorHomeSelector);
    }

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setProviderId(bytes32 chainKey, uint64 selector) external onlyOwner {
        _setProviderId(chainKey, selector);
    }

    event CcipV3LaneSet(uint64 indexed destination, bool enabled, bytes32 evidenceHash);
    error MissingCcipLaneEvidence();

    /// @notice Enable V3 only after verifying the outbound lane's deployed version.
    /// @dev evidenceHash commits to the operator's recorded checks; this does not detect versions on-chain.
    function setCcipV3Lane(uint64 destination, bool enabled, bytes32 evidenceHash) external onlyOwner {
        _chainKeyOfProvider(destination);
        if (enabled && evidenceHash == bytes32(0)) revert MissingCcipLaneEvidence();
        CcipConfig.layout().v3Lanes[destination] = enabled;
        emit CcipV3LaneSet(destination, enabled, evidenceHash);
    }

    function ccipV3LaneEnabled(uint64 destination) external view override returns (bool) {
        return CcipConfig.layout().v3Lanes[destination];
    }

    function _authorizeCcipPolicyChange(uint64, address) internal view override {
        _checkOwner();
    }

    function getCCVsAndFinalityConfig(uint64 source, bytes calldata sender)
        public
        view
        override(CcipPolicy, IAny2EVMMessageReceiverV2)
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        )
    {
        return CcipPolicy.getCCVsAndFinalityConfig(source, sender);
    }

    /* ===================================== sending ===================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint64 setter
        uint64 selector = uint64(_providerIdOf(recipient));
        CcipMessage.send(router, selector, recipient, payload, attributes, value, _defaultGas(payload), address(this));
        return bytes32(0);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint64 setter
        uint64 selector = uint64(_providerIdOf(recipient));
        return CcipMessage.quote(router, selector, recipient, payload, attributes, _defaultGas(payload), address(this));
    }

    /* ==================================== receiving ==================================== */

    /// @dev CCIP's off-ramp asserts nothing about the source-chain sender, so the base's
    ///      `_authenticateOrigin` is the only check. An unmapped selector reverts in the table.
    function ccipReceive(Client.Any2EVMMessage calldata message) external onlyRole(GATEWAY_ROLE) {
        _onProviderInbound(message.sourceChainSelector, CcipMessage.sender(message.sender), message.data);
    }

    /// @notice Declares support for `IAny2EVMMessageReceiver` and `IERC165`.
    /// @dev CCIP's off-ramp checks this before calling `ccipReceive`, and answering false makes
    ///      it mark the message executed without ever delivering it.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IAny2EVMMessageReceiverV2).interfaceId || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }
}

/// @notice The CCIP transceiver on every chain whose addresses match Ethereum's.
contract CcipTransceiver is CcipTransceiverBase {
    constructor(address router_, address extension_) CcipTransceiverBase(router_, extension_) {}

    function initialize(TransceiverConfig memory c, uint64 governorHomeSelector) external initializer {
        __CcipTransceiver_init(c, governorHomeSelector);
        __TransceiverBase_init(c);
    }
}
