// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {HyperlaneDeploy} from "script/deploy/HyperlaneDeploy.sol";

import {toBytes32} from "test/Harness.sol";
import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {
    IReportHarness,
    ProviderZkSyncSpec,
    ProviderGatewayRoleSpec,
    ProviderGovernorHomeSpec,
    ProviderDeliveryGasSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {HyperlaneFixture, HyperlaneZkSyncHarness} from "test/protocols/hyperlane/HyperlaneFixture.sol";

contract HyperlaneTransceiverInboundTest is ProviderGatewayRoleSpec, HyperlaneFixture {}

contract HyperlaneZkSyncTransceiverTest is ProviderZkSyncSpec, HyperlaneFixture {
    function _zkSyncImplementation() internal override returns (address) {
        return address(new HyperlaneZkSyncHarness(address(mailbox)));
    }

    function _deployZkSync(TransceiverDeployment memory d, bytes32 conduitBytecodeHash)
        internal
        override
        returns (address)
    {
        return HyperlaneDeploy.zkSyncTransceiver(d, address(mailbox), 0, conduitBytecodeHash);
    }

    function _assertReportSent() internal view override {
        MockHyperlaneMailbox.Sent memory s = mailbox.sent(0);
        assertEq(s.destinationDomain, BASE_DOMAIN, "to the conduit's home");
        assertEq(s.recipientAddress, toBytes32(HOME_TRANSCEIVER), "to its transceiver there");
        assertEq(s.refundTo, zk, "an overpayment returns to the float, not the relayer");
    }

    /// @dev #63: the report is quoted over the metadata it is sent with, refund address included.
    function test_aReportIsQuotedWithTheRefundAddressItIsSentWith() public {
        mailbox.setFee(0.01 ether);
        mailbox.setRefundSurcharge(zk, 0.02 ether);
        vm.deal(zk, 1 ether);

        vm.prank(makeAddr("relayer"));
        IReportHarness(zk).reportPublic(ChainKey.forEvm(REMOTE_CHAIN_ID), address(0xA11CE), bytes32(0), address(0x2C));

        assertEq(zk.balance, 1 ether - 0.03 ether, "the surcharge on the float's own refund address was paid");
    }
}

contract HyperlaneGovernorHomeTest is ProviderGovernorHomeSpec, HyperlaneFixture {}

contract HyperlaneDeliveryGasTest is ProviderDeliveryGasSpec, HyperlaneFixture {}
