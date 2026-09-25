// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {OpStackMessage} from "src/protocols/op-stack/OpStackMessage.sol";

/// @dev What a transmitter reads from the `OpStackHubTransceiver` that created it: the one
///      messenger it sends through, and the one chain that messenger reaches.
interface IOpStackMessengerSource {
    function messenger() external view returns (address);
    function messengerChainKey() external view returns (bytes32);
}

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev Sender-only: no `receiveOpStackMessage`, so R3.1 is answered by absence rather than a
///      guard. Binds to `ICrossDomainMessenger`, not `OptimismPortal`: the messenger un-aliases
///      the sender, so `AddressDerive.undoL1ToL2Alias` stays unused. See
///      `docs/provider-research.md#7-op-stack-as-a-native-binding`.
contract OpStackTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_) external initializer {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        IOpStackMessengerSource hub = IOpStackMessengerSource(transceiver);
        return OpStackMessage.send(hub.messenger(), hub.messengerChainKey(), recipient, payload, attributes, value);
    }

    /// @dev Zero: see `OpStackMessage`.
    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return OpStackMessage.quote(IOpStackMessengerSource(transceiver).messengerChainKey(), recipient, attributes);
    }

    bytes4 public constant OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE = OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE;
    }
}
