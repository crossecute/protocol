// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {HyperlaneDeploy} from "script/deploy/HyperlaneDeploy.sol";

import {toBytes32} from "test/Harness.sol";
import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {
    ProviderDivergentSpec,
    ProviderGatewayRoleSpec,
    ProviderGovernorHomeSpec,
    ProviderDeliveryGasSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {
    HyperlaneFixture,
    HyperlaneTronHarness,
    HyperlaneZkSyncHarness
} from "test/protocols/hyperlane/HyperlaneFixture.sol";

contract HyperlaneTransceiverInboundTest is ProviderGatewayRoleSpec, HyperlaneFixture {}

abstract contract HyperlaneDivergentTransceiverSpec is ProviderDivergentSpec, HyperlaneFixture {
    function _assertReportSent() internal view override {
        MockHyperlaneMailbox.Sent memory s = mailbox.sent(0);
        assertEq(s.destinationDomain, BASE_DOMAIN, "to the conduit's home");
        assertEq(s.recipientAddress, toBytes32(HOME_TRANSCEIVER), "to its transceiver there");
        assertEq(s.refundTo, divergent, "an overpayment returns to the float");
    }

    /// @dev #63: the report is quoted over the metadata it is sent with, refund address included.
    function test_aReportIsQuotedWithTheRefundAddressItIsSentWith() public {
        mailbox.setFee(0.01 ether);
        mailbox.setRefundSurcharge(divergent, 0.02 ether);
        vm.deal(divergent, 1 ether);
        _sendReportFromFloat();

        assertEq(divergent.balance, 1 ether - 0.03 ether, "the surcharge on the float's own refund address was paid");
    }

    function test_aReportRefundCreditsTheFloat() public {
        mailbox.setFee(0.01 ether);
        mailbox.setSynchronousRebate(0.002 ether);
        vm.deal(divergent, 1 ether);
        _sendReportFromFloat();

        assertEq(divergent.balance, 1 ether - 0.01 ether + 0.002 ether);
    }
}

contract HyperlaneZkSyncTransceiverTest is HyperlaneDivergentTransceiverSpec {
    function _divergentImplementation() internal override returns (address) {
        return address(new HyperlaneZkSyncHarness(address(mailbox)));
    }

    function _deployDivergent(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return HyperlaneDeploy.zkSyncTransceiver(d, address(mailbox), uint32(homeId), CONDUIT_BYTECODE_HASH);
    }
}

contract HyperlaneTronTransceiverTest is HyperlaneDivergentTransceiverSpec {
    function _divergentImplementation() internal override returns (address) {
        return address(new HyperlaneTronHarness(address(mailbox)));
    }

    function _deployDivergent(TransceiverDeployment memory d, uint256 homeId) internal override returns (address) {
        return HyperlaneDeploy.tronTransceiver(d, address(mailbox), uint32(homeId), CONDUIT_BYTECODE_HASH);
    }
}

contract HyperlaneGovernorHomeTest is ProviderGovernorHomeSpec, HyperlaneFixture {}

contract HyperlaneDeliveryGasTest is ProviderDeliveryGasSpec, HyperlaneFixture {}
