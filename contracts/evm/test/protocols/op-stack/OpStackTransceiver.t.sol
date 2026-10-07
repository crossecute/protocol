// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainKey} from "src/addressing/ChainKey.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";

import {ProviderInboundSpec, ProviderGovernorHomeSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {OpStackFixture} from "test/protocols/op-stack/OpStackFixture.sol";

/// @notice The origin is the chain of the messenger that called, through the table, and the
///         sender is that messenger's `xDomainMessageSender()`, checked by the base against
///         the origin's counterpart.
contract OpStackTransceiverInboundTest is ProviderInboundSpec, OpStackFixture {
    /// @dev The table is the gate, and it maps the caller before asking it for the sender:
    ///      an EOA would fail the sender read with no error data, not this one.
    function _bypassRevert(address caller) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, uint256(uint160(caller)));
    }

    /// @dev A mapped messenger whose chain has no route delivers nothing.
    function test_nothingIsAcceptedFromAMessengerWhoseChainIsUnrouted() public {
        bytes32 remote = ChainKey.forEvm(REMOTE_CHAIN_ID);
        address owner = TransceiverBase(payable(transceiver)).owner();
        vm.prank(owner);
        OpStackTransceiver(payable(transceiver)).setMessenger(remote, REMOTE_MESSENGER);
        bytes memory message = _bootstrap();
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, remote));
        _deliverTo(transceiver, ORIGIN_TRANSCEIVER, message);
    }

    /// @dev `OpStackTransmitter` sends through what the transceiver's table answers here.
    function test_itAnswersWhatItsTransmittersRead() public {
        _wire();
        assertEq(
            OpStackTransceiver(payable(transceiver)).messengerFor(ChainKey.forEvm(REMOTE_CHAIN_ID)), REMOTE_MESSENGER
        );
    }
}

contract OpStackGovernorHomeTest is ProviderGovernorHomeSpec, OpStackFixture {}
