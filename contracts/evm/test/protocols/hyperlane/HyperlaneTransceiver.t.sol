// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {HyperlaneDeploy} from "script/deploy/HyperlaneDeploy.sol";

import {toBytes32} from "test/protocols/ProviderFixture.sol";
import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {
    ProviderZkSyncSpec,
    ProviderGatewayRoleSpec,
    ProviderGovernorHomeSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {HyperlaneFixture, HyperlaneZkSyncHarness} from "test/protocols/hyperlane/HyperlaneFixture.sol";

contract HyperlaneTransceiverInboundTest is ProviderGatewayRoleSpec, HyperlaneFixture {}

contract HyperlaneZkSyncTransceiverTest is ProviderZkSyncSpec, HyperlaneFixture {
    function _zkSyncImplementation() internal override returns (address) {
        return address(new HyperlaneZkSyncHarness(address(mailbox)));
    }

    function _deployZkSync(TransceiverDeployment memory d, bytes32 accountBytecodeHash)
        internal
        override
        returns (address)
    {
        return HyperlaneDeploy.zkSyncTransceiver(d, address(mailbox), 0, accountBytecodeHash);
    }

    function _assertReportSent() internal view override {
        MockHyperlaneMailbox.Sent memory s = mailbox.sent(0);
        assertEq(s.destinationDomain, BASE_DOMAIN, "to the account's home");
        assertEq(s.recipientAddress, toBytes32(HOME_TRANSCEIVER), "to its transceiver there");
        assertEq(s.refundTo, zk, "an overpayment returns to the float, not the relayer");
    }
}

contract HyperlaneGovernorHomeTest is ProviderGovernorHomeSpec, HyperlaneFixture {}
