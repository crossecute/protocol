// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice CCIP on `TransceiverBase`, shared by the plain, zkSync, and Tron variants, which
///         differ only in address derivation.
///
/// @dev One Router serves both directions (`ccipSend`/`getFee` and inbound `ccipReceive`), so
///      `GATEWAY_ROLE` names one address, granted at initialization rather than relying on the
///      deployment to list it. See `docs/provider-research.md#4-ccip-as-a-native-binding`.
abstract contract CcipTransceiverBase is ProviderTransceiver, IAny2EVMMessageReceiver {
    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE = CcipMessage.EXTRA_ARGS_ATTRIBUTE;

    /// @notice CCIP Router on this chain. On the implementation, so it never reaches a derived
    ///         account address.
    address public immutable router;

    constructor(address router_) {
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
    function setSelector(bytes32 chainKey, uint64 selector) external onlyOwner {
        _setProviderId(chainKey, selector);
    }

    /* ===================================== sending ===================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint64 setter
        uint64 selector = uint64(_providerIdOf(recipient));
        CcipMessage.send(router, selector, recipient, payload, attributes, value, _defaultGas(payload));
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
        return CcipMessage.quote(router, selector, recipient, payload, attributes, _defaultGas(payload));
    }

    /* ==================================== receiving ==================================== */

    /// @dev CCIP's off-ramp asserts nothing about the source-chain sender, so the base's
    ///      `_authenticateOrigin` is the only check. An unmapped selector reverts in the table.
    function ccipReceive(Client.Any2EVMMessage calldata message) external onlyRole(GATEWAY_ROLE) {
        _onProviderInbound(message.sourceChainSelector, CcipMessage.sender(message), message.data);
    }

    /// @notice Declares support for `IAny2EVMMessageReceiver` and `IERC165`.
    /// @dev CCIP's off-ramp checks this before calling `ccipReceive`, and answering false makes
    ///      it mark the message executed without ever delivering it.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }
}

/// @notice The CCIP transceiver on every chain whose addresses match Ethereum's.
contract CcipTransceiver is CcipTransceiverBase {
    constructor(address router_) CcipTransceiverBase(router_) {}

    function initialize(TransceiverConfig memory c, uint64 governorHomeSelector) external initializer {
        __CcipTransceiver_init(c, governorHomeSelector);
        __TransceiverBase_init(c);
    }
}
