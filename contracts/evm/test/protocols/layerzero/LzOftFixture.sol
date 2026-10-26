// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Call} from "src/messaging/Call.sol";
import {LzOftReceiver, ILzOftReceiverInit} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftTransmitter, ILzOftTransmitterInit} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {ProviderAccountFixture} from "test/protocols/ProviderFixture.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";

/// @notice `layerzero-oft` for the account specs: a delivery is a compose this chain's OFT
///         queues and the endpoint runs, from the account's home eid, with the sender as
///         `composeFrom`.
/// @dev Accounts only: this binding has no transceiver, so it runs no spec that needs one.
abstract contract LzOftFixture is ProviderAccountFixture {
    uint32 internal constant HOME_EID = 30184;
    address internal constant HOME_OFT = address(0x40F7);

    MockLzEndpoint internal endpoint = new MockLzEndpoint();
    MockOft internal localOft;

    constructor() {
        localOft = new MockOft(address(endpoint));
        localOft.setPeer(HOME_EID, HOME_OFT);
    }

    function _receiverImplementation() internal override returns (address) {
        return address(new LzOftReceiver());
    }

    function _transmitterImplementation() internal override returns (address) {
        return address(new LzOftTransmitter());
    }

    function _gateway() internal view override returns (address) {
        return address(endpoint);
    }

    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal override {
        // forge-lint: disable-next-line(unsafe-typecast) an eid
        localOft.deliver(uint32(originId), to, sender, message);
    }

    /// @dev The compose the OFT would have queued, handed to the receiver by this test.
    function _deliverBypassingGateway(address to, bytes32 sender, bytes memory message) internal override {
        bytes memory m = OFTComposeMsgCodec.encode(1, HOME_EID, 0, abi.encodePacked(sender, message));
        LzOftReceiver(payable(to)).lzCompose(address(localOft), bytes32(0), m, address(0), "");
    }

    function _remoteProviderId() internal pure override returns (uint256) {
        return HOME_EID;
    }

    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        view
        override
        returns (bytes memory)
    {
        return abi.encodeCall(
            ILzOftReceiverInit.initialize, (sourceTransmitter, HOME_EID, HOME_OFT, address(localOft), calls)
        );
    }

    function _initializeTransmitter(address owner) internal pure override returns (bytes memory) {
        return abi.encodeCall(ILzOftTransmitterInit.initialize, (owner, address(0xFAC7), bytes32(0), HOME_OFT));
    }
}
