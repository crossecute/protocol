// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {SourceAuthorityBase} from "./SourceAuthorityBase.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {AuthorityUpdateEncoding} from "crossecute/messaging/authority/AuthorityUpdateEncoding.sol";
import {AuthorityGraph} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {Payload} from "crossecute/messaging/Payload.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {SafeHashes} from "../src/SafeHashes.sol";
import {LzOftConduitFactory} from "crossecute/protocols/layerzero/LzOftConduitFactory.sol";
import {LzOftTransmitter} from "crossecute/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftMessage} from "crossecute/protocols/layerzero/LzOftMessage.sol";
import {LzOftReceiver} from "crossecute/protocols/layerzero/LzOftReceiver.sol";
import {ISignedTransmitter} from "crossecute/messaging/outbound/ISignedTransmitter.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {Erc7930} from "crossecute/addressing/Erc7930.sol";
import {ChainKey} from "crossecute/addressing/ChainKey.sol";

import {SafeTxEvidence, SignedBootstrap} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {MockLzEndpoint} from "evm-test/protocols/layerzero/MockLzEndpoint.sol";
import {MockOft} from "evm-test/protocols/layerzero/MockOft.sol";

contract OftIntegrationSink {
    uint256 public hits;

    function hit() external {
        ++hits;
    }
}

/// @notice Actual Safe 1.5.0 execution and guard staging through OFT bootstrap and compose delivery.
contract SignedOftIntegrationTest is SourceAuthorityBase {
    Safe internal safe;

    function setUp() public override {
        super.setUp();
        uint256[] memory keys = new uint256[](3);
        keys[0] = 0xA11CE;
        keys[1] = 0xB0B;
        keys[2] = 0xC4A5;
        safe = _guarded(keys, 2);
    }

    function _signers() internal pure returns (Signer[] memory signers) {
        signers = new Signer[](2);
        signers[0] = _eoa(0xA11CE);
        signers[1] = _eoa(0xB0B);
    }
    uint256 constant HOME = 8453;
    uint256 constant DEST = 42161;
    uint32 constant HOME_EID = 30184;
    uint32 constant DEST_EID = 30110;
    LzOftConduitFactory internal oftFactory;
    MockOft internal oft;

    function _transport(uint256 chain, uint32 eid) internal {
        vm.chainId(chain);
        LzOftTransmitter t = new LzOftTransmitter{salt: bytes32(0)}();
        LzOftReceiver r = new LzOftReceiver{salt: bytes32(0)}(address(guard), address(multiSend));
        oftFactory = new LzOftConduitFactory{salt: bytes32(0)}(address(t), address(r), address(0x7EA5));
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

    struct Rotation {
        SafeTxEvidence evidence;
        AuthorityGraph graph;
        bytes wire;
    }

    function _rotateAndRelay(LzOftTransmitter st) internal returns (Rotation memory rotation) {
        rotation.graph = _graph(_record(safe));
        rotation.graph.nodes[0].record.threshold = 1;
        Call[] memory mutations = new Call[](1);
        mutations[0] = _call(address(safe), abi.encodeCall(safe.changeThreshold, (1)));
        bytes memory data = _ownershipData(safe, _head(safe), _hash(rotation.graph), mutations);
        rotation.evidence.signedSafeTx.safeTx.to = address(multiSend);
        rotation.evidence.signedSafeTx.safeTx.operation = uint8(Enum.Operation.DelegateCall);
        rotation.evidence.signedSafeTx.safeTx.data = data;
        rotation.evidence.signedSafeTx.safeTx.nonce = safe.nonce();
        rotation.evidence.signedSafeTx.signatures =
            _signFor(safe, _signers(), address(multiSend), 0, data, Enum.Operation.DelegateCall);
        _execOwnershipChange(safe, rotation.graph, mutations, _signers());
        bytes memory submission = abi.encode(rotation.evidence, rotation.graph, new ChildUpdate[](0));
        address relayer = address(0xB0B);
        vm.deal(relayer, 1 ether);
        bytes memory recipient = Erc7930.encodeEvm(DEST, address(st));
        vm.prank(relayer);
        uint256 fee = st.quoteAuthority(recipient, submission, new bytes[](0));
        uint256 balance = address(st).balance;
        vm.prank(relayer);
        // forge-lint: disable-next-line(arbitrary-send-eth) st is the conduit deployed by this fixture
        st.relayAuthority{value: fee + 123}(recipient, submission, new bytes[](0));
        assertEq(relayer.balance, 1 ether - fee);
        assertEq(address(st).balance, balance);
        MockOft.Sent memory sent = oft.sent(2);
        assertEq(sent.value, fee);
        assertEq(sent.refundTo, relayer);
        assertEq(sent.from, address(st));
        rotation.wire = sent.param.composeMsg;
    }

    function test_realSafeGuardBootstrapAndComposeShareDirectReplay() public {
        uint256 start = vm.snapshotState();
        _transport(DEST, DEST_EID);
        address dstOft = address(oft);
        vm.revertToState(start);
        start = vm.snapshotState();
        _transport(HOME, HOME_EID);
        oft.setPeer(DEST_EID, dstOft);
        _activate(safe, _signers());
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
        // Query the created address independently from its route commitment.
        address conduit =
            oftFactory.predictConduit(address(safe), bytes32(0), ChainKey.forEvm(HOME), HOME_EID, homeOft, root);
        LzOftTransmitter st = LzOftTransmitter(payable(conduit));
        vm.deal(conduit, 1 ether);
        bytes memory body = abi.encode(
            SignedBootstrap(
                address(guard),
                guard.selection(address(safe)).updateHead,
                abi.encode(_graph(_record(safe))),
                abi.encode(new Call[](0))
            )
        );
        bytes memory payload = Payload.encodeBootstrap(Erc7930.encodeEvmChain(DEST), body);
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
        assertEq(bootstrapWire.length, 1280, "one three-owner Safe, one route, no setup calls");
        (, LzOftMessage.Bootstrap memory header,,) =
            abi.decode(bootstrapWire, (uint256, LzOftMessage.Bootstrap, uint256, bytes));
        assertEq(bootstrapWire.length - abi.encode(header).length, 928, "overhead over unsigned bootstrap");
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
        Rotation memory rotation = _rotateAndRelay(st);
        SafeTxEvidence memory afterRotation = _evidence(conduit, data);
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
        receiver.submitAuthority(rotation.evidence, rotation.graph, new ChildUpdate[](0));
        oft.deliver(HOME_EID, conduit, bytes32(uint256(uint160(conduit))), rotation.wire);
        assertEq(receiver.selection().authorityHash, AuthorityUpdateEncoding.graphHash(HOME, rotation.graph));
        assertEq(receiver.authorityRecords()[0].threshold, 1);
        receiver.submitMessage(afterRotation);
        assertEq(OftIntegrationSink(address(0x5151)).hits(), 2);
        assertTrue(
            receiver.isMessageExecuted(SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, sourceSafe, HOME))
        );
    }
}
