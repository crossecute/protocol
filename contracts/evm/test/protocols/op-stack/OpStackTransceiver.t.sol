// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOpStackMessengerSource} from "src/protocols/op-stack/OpStackTransmitter.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";

import {ProviderGatewayRoleSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {OpStackFixture} from "test/protocols/op-stack/OpStackFixture.sol";

/// @notice The sender is `xDomainMessageSender()`, checked by the base against the paired
///         chain's counterpart; the messenger's gateway role is what admits the call.
contract OpStackTransceiverInboundTest is ProviderGatewayRoleSpec, OpStackFixture {
    /// @dev The paired chain is the only origin, and with no route recorded for it nothing is
    ///      accepted, even from the counterpart's address.
    function test_nothingIsAcceptedBeforeThePairedChainIsRouted() public {
        bytes32 paired = ChainKey.forEvm(REMOTE_CHAIN_ID);
        bytes memory message = _bootstrap();
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, paired));
        _deliverTo(transceiver, ORIGIN_TRANSCEIVER, message);
    }

    /// @dev `OpStackTransmitter` reads its messenger and paired chain from the transceiver that
    ///      created it.
    function test_itAnswersWhatItsTransmittersRead() public view {
        assertEq(IOpStackMessengerSource(transceiver).messenger(), address(messenger));
        assertEq(IOpStackMessengerSource(transceiver).messengerChainKey(), ChainKey.forEvm(REMOTE_CHAIN_ID));
    }
}
