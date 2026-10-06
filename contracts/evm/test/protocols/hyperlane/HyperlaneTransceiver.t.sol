// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";

import {HyperlaneZkSyncTransceiver} from "src/protocols/hyperlane/HyperlaneDivergentTransceiver.sol";

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

    function _initializeZkSync(TransceiverConfig memory c, bytes32 hash) internal pure override returns (bytes memory) {
        return abi.encodeCall(HyperlaneZkSyncTransceiver.initialize, (c, uint32(0), hash));
    }

    function _assertReportSent() internal view override {
        MockHyperlaneMailbox.Sent memory s = mailbox.sent(0);
        assertEq(s.destinationDomain, BASE_DOMAIN, "to the account's home");
        assertEq(s.recipientAddress, toBytes32(HOME_TRANSCEIVER), "to its transceiver there");
        assertEq(s.refundTo, zk, "an overpayment returns to the float, not the relayer");
    }
}

contract HyperlaneGovernorHomeTest is ProviderGovernorHomeSpec, HyperlaneFixture {}
