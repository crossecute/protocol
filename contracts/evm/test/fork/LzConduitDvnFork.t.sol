// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {LzFixture} from "test/protocols/layerzero/LzFixture.sol";
import {ProviderConduitSetup} from "test/protocols/ProviderBindingSpec.t.sol";
import {bootstrapPayload} from "test/Harness.sol";
import {createRpcFork} from "test/fork/ForkBlock.sol";

/// @notice #94 with the real `LzTransmitter` and Ethereum's real endpoint. The transceiver sends and
///         prices a conduit's bootstrap, so that needs the transceiver's DVN pin, which governance
///         sets. A message after the bootstrap is the conduit's own send: it cannot quote toward
///         Fraxtal on the dead-DVN default, quotes and sends once its owner calls `setDvn`, and
///         another conduit is unaffected by that pin.
/// @dev Skipped without `ETH_RPC_URL`; reads and local execution only, so a public RPC is enough.
///      `ETH_FORK_BLOCK` pins a block. The fixture's endpoint is the real one, so only the
///      conduit fixture's setup runs here, not the specs that read the mock's records.
contract LzConduitDvnForkTest is ProviderConduitSetup, LzFixture {
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32 constant FRAXTAL_EID = 30255;
    address constant ETHEREUM_DVN = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;

    address internal transceiver;

    function _remoteEid() internal pure override returns (uint32) {
        return FRAXTAL_EID;
    }

    function setUp() public override {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.selectFork(createRpcFork(vm, rpc, "ETH_FORK_BLOCK"));
        endpoint = MockLzEndpoint(ENDPOINT);
        super.setUp();
    }

    function _stack(address dvn) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = dvn;
    }

    /// @dev Runs between the conduit's creation and its bootstrap. Governance pins the
    ///      transceiver, which sends the bootstrap; the conduit's own pathway stays on the default.
    function _prepareConduit(address conduit_, address) internal override {
        transceiver = TransmitterBase(payable(conduit_)).transceiver();
        _peerWithItsReceiver(conduit_, CONDUIT_OWNER);
        bytes memory payload = bootstrapPayload(REMOTE_CHAIN_ID, new Call[](0));
        vm.expectRevert();
        this.quoteBootstrapExternal(conduit_);

        vm.prank(TransceiverBase(payable(transceiver)).owner());
        LzTransceiver(payable(transceiver)).setDvn(FRAXTAL_EID, ETHEREUM_DVN);
        assertGt(
            TransmitterBase(payable(conduit_)).quoteBootstrap(payload, _attributes()),
            0,
            "the transceiver's pin prices the bootstrap"
        );
    }

    /// @dev External so `expectRevert` sees the call.
    function quoteBootstrapExternal(address conduit_) external view returns (uint256) {
        return TransmitterBase(payable(conduit_))
            .quoteBootstrap(bootstrapPayload(REMOTE_CHAIN_ID, new Call[](0)), _attributes());
    }

    /// @dev External so `expectRevert` sees the call.
    function quoteMessageExternal(address conduit_) external view returns (uint256) {
        bytes memory recipient = TransmitterBase(payable(conduit_)).recipientOn(REMOTE_CHAIN_ID);
        return
            TransmitterBase(payable(conduit_))
                .quoteMessage(recipient, Payload.encodeCalls(new Call[](0)), _attributes());
    }

    function _packetSent(Vm.Log[] memory logs) private pure returns (bool sent) {
        for (uint256 i; i < logs.length; ++i) {
            sent =
                sent || (logs[i].emitter == ENDPOINT && logs[i].topics[0] == ILayerZeroEndpointV2.PacketSent.selector);
        }
    }

    function test_theBootstrapWentOutOnTheTransceiversPinAlone() public view {
        assertTrue(TransmitterBase(conduit).isBootstrappedOn(REMOTE_CHAIN_ID));
        assertLt(conduit.balance, 1 ether, "the conduit paid for it");
    }

    function test_aMessageNeedsTheOwnersSetDvn() public {
        vm.expectRevert();
        this.quoteMessageExternal(conduit);

        vm.prank(CONDUIT_OWNER);
        LzTransmitter(conduit).setDvn(FRAXTAL_EID, _stack(ETHEREUM_DVN), new address[](0), 0);
        assertGt(this.quoteMessageExternal(conduit), 0);

        bytes memory recipient = TransmitterBase(conduit).recipientOn(REMOTE_CHAIN_ID);
        vm.recordLogs();
        vm.prank(CONDUIT_OWNER);
        TransmitterBase(conduit).sendMessage(recipient, Payload.encodeCalls(new Call[](0)), _attributes());
        assertTrue(_packetSent(vm.getRecordedLogs()), "the real endpoint sent a packet");
    }

    function test_anotherConduitsMessageStillNeedsItsOwnersSetDvn() public {
        vm.prank(CONDUIT_OWNER);
        LzTransmitter(conduit).setDvn(FRAXTAL_EID, _stack(ETHEREUM_DVN), new address[](0), 0);

        vm.prank(CONDUIT_OWNER);
        address payable other = payable(TransceiverBase(payable(transceiver)).createTransmitter(bytes32(uint256(1))));
        vm.deal(other, 1 ether);
        _peerWithItsReceiver(other, CONDUIT_OWNER);
        vm.prank(CONDUIT_OWNER);
        TransmitterBase(other).bootstrap(bootstrapPayload(REMOTE_CHAIN_ID, new Call[](0)), _attributes());

        vm.expectRevert();
        this.quoteMessageExternal(other);
        assertGt(this.quoteMessageExternal(conduit), 0, "the first conduit's pin is its own");
    }
}
