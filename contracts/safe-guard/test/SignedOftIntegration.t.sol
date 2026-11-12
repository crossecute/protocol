// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {GuardTestBase} from "./GuardTestBase.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SafeHashes} from "../src/SafeHashes.sol";
import {LzOftConduitFactory} from "crossecute/protocols/layerzero/LzOftConduitFactory.sol";
import {LzOftTransmitter} from "crossecute/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftReceiver} from "crossecute/protocols/layerzero/LzOftReceiver.sol";
import {ISignedTransmitter} from "crossecute/messaging/outbound/ISignedTransmitter.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {Erc7930} from "crossecute/addressing/Erc7930.sol";
import {ChainKey} from "crossecute/addressing/ChainKey.sol";
import {SafeAuthorityRecord} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeAuthorityGraph} from "crossecute/messaging/signed/SafeAuthorityGraph.sol";
import {DispatchLeaves} from "crossecute/messaging/signed/DispatchLeaves.sol";
import {SafeTxEvidence, BootstrapLeaf} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {MockLzEndpoint} from "evm-test/protocols/layerzero/MockLzEndpoint.sol";
import {MockOft} from "evm-test/protocols/layerzero/MockOft.sol";

contract OftIntegrationSink {
    uint256 public hits;

    function hit() external {
        ++hits;
    }
}

/// @notice Actual Safe 1.5.0 execution and guard staging through OFT bootstrap and compose delivery.
contract SignedOftIntegrationTest is GuardTestBase {
    uint256 constant HOME = 8453;
    uint256 constant DEST = 42161;
    uint32 constant HOME_EID = 30184;
    uint32 constant DEST_EID = 30110;
    LzOftConduitFactory internal oftFactory;
    MockOft internal oft;

    function _transport(uint256 chain, uint32 eid) internal {
        vm.chainId(chain);
        LzOftTransmitter t = new LzOftTransmitter{salt: bytes32(0)}();
        LzOftReceiver r = new LzOftReceiver{salt: bytes32(0)}();
        oftFactory = new LzOftConduitFactory{salt: bytes32(0)}(address(t), address(r));
        MockLzEndpoint endpoint = new MockLzEndpoint{salt: bytes32(chain)}();
        endpoint.setEid(eid);
        oft = new MockOft{salt: bytes32(chain)}(address(endpoint));
    }

    function _evidence(address to, bytes memory data) internal view returns (SafeTxEvidence memory e) {
        e.signedSafeTx.safeTx.to = to;
        e.signedSafeTx.safeTx.data = data;
        e.signedSafeTx.safeTx.nonce = safe.nonce();
        e.signedSafeTx.signatures = _signFor(safe, _signers(), to, 0, data, Enum.Operation.Call);
    }

    function test_realSafeGuardBootstrapAndComposeShareDirectReplay() public {
        uint256 start = vm.snapshotState();
        _transport(DEST, DEST_EID);
        address dstOft = address(oft);
        vm.revertToState(start);
        start = vm.snapshotState();
        _transport(HOME, HOME_EID);
        oft.setPeer(DEST_EID, dstOft);
        address homeOft = address(oft);
        LzOftConduitFactory.Leaf[] memory leaves = new LzOftConduitFactory.Leaf[](1);
        leaves[0] = LzOftConduitFactory.Leaf(ChainKey.forEvm(DEST), DEST_EID, dstOft);
        assertTrue(
            _exec(
                safe,
                _signers(),
                address(oftFactory),
                0,
                abi.encodeCall(oftFactory.createTransmitter, (bytes32(0), homeOft, leaves)),
                Enum.Operation.Call
            )
        );
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(ChainKey.forEvm(DEST), DEST_EID, dstOft))));
        // Query the created address independently using the live graph commitment.
        address conduit = oftFactory.predictConduit(
            address(safe), bytes32(0), ChainKey.forEvm(HOME), HOME_EID, homeOft, root, keccak256(abi.encode(_records()))
        );
        LzOftTransmitter st = LzOftTransmitter(payable(conduit));
        vm.deal(conduit, 1 ether);
        BootstrapLeaf memory leaf =
            BootstrapLeaf(Erc7930.encodeEvm(DEST, conduit), 0, type(uint256).max, abi.encode(new Call[](0)));
        bytes memory payload = abi.encode(DispatchLeaves.hash(leaf), uint256(0), leaf, new bytes32[](0));
        assertTrue(
            _exec(
                safe,
                _signers(),
                conduit,
                0,
                abi.encodeCall(ISignedTransmitter.bootstrap, (payload, new bytes[](0))),
                Enum.Operation.Call
            )
        );
        assertTrue(st.isBootstrapped(ChainKey.forEvm(DEST)));
        bytes memory bootstrapWire = oft.sent(0).param.composeMsg;
        assertEq(oft.sent(0).from, conduit);
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0x5151), 0, abi.encodeCall(OftIntegrationSink.hit, ()));
        bytes memory data =
            abi.encodeCall(st.sendMessage, (Erc7930.encodeEvm(DEST, conduit), abi.encode(calls), new bytes[](0)));
        SafeTxEvidence memory evidence = _evidence(conduit, data);
        address sourceSafe = address(safe);
        assertTrue(_execWith(safe, conduit, 0, data, Enum.Operation.Call, evidence.signedSafeTx.signatures));
        bytes memory messageWire = oft.sent(1).param.composeMsg;
        assertEq(oft.sent(1).from, conduit);
        vm.revertToState(start);
        _transport(DEST, DEST_EID);
        oft.setPeer(HOME_EID, homeOft);
        OftIntegrationSink effect = new OftIntegrationSink();
        vm.etch(address(0x5151), address(effect).code);
        oft.deliver(HOME_EID, address(oftFactory), bytes32(uint256(uint160(conduit))), bootstrapWire);
        oft.deliver(HOME_EID, conduit, bytes32(uint256(uint160(conduit))), messageWire);
        LzOftReceiver receiver = LzOftReceiver(payable(conduit));
        receiver.submitMessage(evidence);
        assertEq(OftIntegrationSink(address(0x5151)).hits(), 1);
        assertTrue(
            receiver.isMessageExecuted(SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, HOME))
        );
    }

    function _records() internal view returns (SafeAuthorityRecord[] memory) {
        return SafeAuthorityGraph.derive(address(safe));
    }
}
