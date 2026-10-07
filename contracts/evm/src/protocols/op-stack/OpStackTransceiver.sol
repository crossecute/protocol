// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {OpStackMessage, IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";
import {IOpStackReceiverInit} from "src/protocols/op-stack/OpStackReceiver.sol";

/// @notice OP Stack's `CrossDomainMessenger` on `TransceiverBase`: the `op-stack-l1-l2` provider,
///         between Ethereum and each OP Stack chain. L2 to L2 is `op-stack-l2-l2`.
///
/// @dev Each pair has its own messenger on each side: on an OP Stack chain the
///      `L2CrossDomainMessenger` predeploy, which reaches only Ethereum, and on Ethereum one
///      `L1CrossDomainMessenger` per OP Stack chain. So the provider id for a chain is the
///      address of the messenger that reaches it, held in `ProviderChainId`'s write-once,
///      injective table: one entry on an OP Stack chain, one per chain on Ethereum. The same
///      contract runs on both sides.
///
/// @dev A delivery's origin is the chain of the messenger that called, never anything the
///      message says, so a compromised bridge to one chain can deliver only as that chain.
///      The table is the gate, so no messenger holds `GATEWAY_ROLE`, and a messenger the
///      table does not map is refused before it is asked for the sender.
///
/// @dev No zkSync or Tron variant: an OP Stack chain uses Ethereum's CREATE2 formula.
contract OpStackTransceiver is ProviderTransceiver, IOpStackRecipient {
    bytes4 public constant OP_STACK_MIN_GAS_LIMIT_ATTRIBUTE = OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE;

    /// @param governorHomeMessenger The messenger on this chain that reaches the governor's
    ///        home; see `ProviderTransceiver._initGovernorHomeId`.
    function initialize(TransceiverConfig memory c, address governorHomeMessenger) external initializer {
        _initGovernorHomeId(c.governorHome, uint160(governorHomeMessenger));
        __TransceiverBase_init(c);
    }

    /// @notice Name the messenger on this chain that reaches `chainKey`.
    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setMessenger(bytes32 chainKey, address messenger) external onlyOwner {
        _setProviderId(chainKey, uint160(messenger));
    }

    /// @notice The messenger on this chain that reaches `chainKey`. Reverts when unset.
    function messengerFor(bytes32 chainKey) public view returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast) set through an address setter
        return address(uint160(_providerIdFor(chainKey)));
    }

    /* ===================================== sending ===================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        // forge-lint: disable-next-line(unsafe-typecast) set through an address setter
        return OpStackMessage.send(address(uint160(_providerIdOf(recipient))), recipient, payload, attributes, value);
    }

    /// @dev Zero: see `OpStackMessage`.
    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        _providerIdOf(recipient);
        return OpStackMessage.quote(recipient, attributes);
    }

    /* ==================================== receiving ==================================== */

    /// @dev The caller is mapped to its chain first, so an unmapped caller reverts
    ///      `UnknownProviderId` before `xDomainMessageSender()` is read from it.
    function receiveOpStackMessage(bytes calldata payload) external override {
        bytes32 origin = _chainKeyOfProvider(uint160(msg.sender));
        _onInbound(routeFor(origin), abi.encodePacked(OpStackMessage.sender()), payload);
    }

    /// @inheritdoc TransceiverBase
    /// @dev A receiver's gateway is the messenger here that reaches its account's home.
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
        return abi.encodeCall(IOpStackReceiverInit.initialize, (sourceTransmitter, calls, messengerFor(homeChainKey)));
    }
}
