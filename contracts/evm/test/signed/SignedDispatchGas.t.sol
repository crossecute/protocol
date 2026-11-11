// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {SignedReceiver} from "src/messaging/inbound/SignedReceiver.sol";
import {SafeAuthority} from "src/messaging/signed/SafeAuthority.sol";
import {DispatchLeaves} from "src/messaging/signed/DispatchLeaves.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";
import {SafeAuthorityRecord, SafeOwner, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {
    SafeTxEvidence,
    ExecutionLeaf,
    BootstrapLeaf,
    SignedBootstrap,
    NestedSafeApproval,
    WIRE_STANDALONE,
    WIRE_MERKLE
} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {deployConduit} from "test/DeployProxy.sol";
import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {SafeSigs, Sig, Records} from "test/signed/SignedFixtures.sol";
import {Sink} from "test/signed/SignedReceiver.t.sol";

/// @notice Paris/0.8.28 receiver gas and wire sizes, independently of the Cancun guard build.
contract SignedDispatchGasTest is Test {
    address constant SAFE = address(0x5AFE);
    address constant TRANSMITTER = address(0x7777);
    uint256 constant SOURCE = 10;
    MockHyperlaneMailbox mailbox = new MockHyperlaneMailbox();
    Sink sink = new Sink();
    address implementation;

    /// @notice Construct a Safe record whose quorum consists of the supplied child addresses.
    function _parent(address account, address a, address b) internal pure returns (SafeAuthorityRecord memory) {
        SafeOwner[] memory owners = new SafeOwner[](b == address(0) ? 1 : 2);
        owners[0] = SafeOwner(a, OWNER_SAFE);
        if (owners.length == 2) owners[1] = SafeOwner(b, OWNER_SAFE);
        return SafeAuthorityRecord(account, owners.length, owners);
    }

    /// @notice Produce the five canonical benchmark graphs in depth-first traversal order.
    function _records(uint256 shape, uint256 ownerCount) internal pure returns (SafeAuthorityRecord[] memory r) {
        uint256[] memory privateKeys = new uint256[](ownerCount);
        for (uint256 i; i < ownerCount; ++i) {
            privateKeys[i] = i + 1;
        }
        SafeOwner[] memory eoas = Records.eoaOwners(privateKeys);
        if (shape == 0) return Records.list(Records.record(SAFE, 2, eoas));
        address a = address(0x101);
        address b = address(0x102);
        address c = address(0x103);
        if (shape < 3) return Records.list(_parent(SAFE, a, address(0)), Records.record(a, 2, eoas));
        if (shape == 3) {
            return Records.list(_parent(SAFE, a, address(0)), _parent(a, b, address(0)), Records.record(b, 2, eoas));
        }
        if (shape >= 5) {
            uint256[] memory first = new uint256[](13);
            uint256[] memory second = new uint256[](7);
            for (uint256 i; i < first.length; ++i) {
                first[i] = i + 1;
            }
            for (uint256 i; i < second.length; ++i) {
                second[i] = i + 1;
            }
            return Records.list(
                _parent(SAFE, a, b),
                Records.record(a, 10, Records.eoaOwners(first)),
                Records.record(b, 5, Records.eoaOwners(second))
            );
        }
        r = new SafeAuthorityRecord[](4);
        r[0] = _parent(SAFE, a, b);
        r[1] = _parent(a, c, address(0));
        r[2] = Records.record(c, 2, eoas);
        r[3] = _parent(b, c, address(0));
    }

    /// @notice Locate a canonical record for recursive signature generation.
    function _index(SafeAuthorityRecord[] memory r, address account) internal pure returns (uint256) {
        for (uint256 i; i < r.length; ++i) {
            if (r[i].safe == account) return i;
        }
        revert("missing record");
    }

    /// @notice Generate threshold signatures in each nested Safe's correct message domain.
    function _sign(SafeAuthorityRecord[] memory r, uint256 index, bytes32 hash, bool empty)
        internal
        pure
        returns (bytes memory)
    {
        SafeOwner[] memory owners = r[index].owners;
        Sig[] memory sigs = new Sig[](r[index].threshold);
        for (uint256 i; i < sigs.length; ++i) {
            if (owners[i].kind != OWNER_SAFE) {
                sigs[i] = SafeSigs.eoa(i + 1);
            } else {
                bytes memory payload;
                if (!empty) {
                    payload = _sign(
                        r,
                        _index(r, owners[i].owner),
                        SafeHashes.messageHash(abi.encode(hash), owners[i].owner, SOURCE),
                        false
                    );
                }
                sigs[i] = SafeSigs.nested(owners[i].owner, payload);
            }
        }
        return SafeSigs.blob(sigs, hash);
    }

    /// @notice Build exact root evidence and, when needed, an independently signed child approval.
    function _evidence(SafeAuthorityRecord[] memory r, bytes memory data, uint256 nonce, bool empty)
        internal
        pure
        returns (SafeTxEvidence memory e)
    {
        e.signedSafeTx.safeTx.to = TRANSMITTER;
        e.signedSafeTx.safeTx.data = data;
        e.signedSafeTx.safeTx.nonce = nonce;
        bytes32 hash = SafeHashes.transactionHash(e.signedSafeTx.safeTx, SAFE, SOURCE);
        e.signedSafeTx.signatures = _sign(r, 0, hash, empty);
        if (empty) {
            e.nestedApprovals = new NestedSafeApproval[](r[0].owners.length);
            for (uint256 i; i < e.nestedApprovals.length; ++i) {
                address child = r[0].owners[i].owner;
                Sig[] memory sigs = new Sig[](r[_index(r, child)].threshold);
                for (uint256 j; j < sigs.length; ++j) {
                    sigs[j] = SafeSigs.eoa(j + 1);
                }
                e.nestedApprovals[i] = SafeSigs.approval(child, hash, SOURCE, sigs, address(0x5151));
            }
        }
    }

    /// @notice Encode a variable-size application batch without hiding its execution cost.
    function _calls(uint256 count) internal view returns (bytes memory) {
        Call[] memory calls = new Call[](count);
        for (uint256 i; i < count; ++i) {
            calls[i] = Call(address(sink), 0, abi.encodeCall(sink.hit, (hex"1234")));
        }
        return abi.encode(calls);
    }

    /// @notice Reset receiver, implementation, authority-library and target storage access warmth.
    function _cold(address receiver) internal {
        vm.cool(receiver);
        vm.cool(implementation);
        vm.cool(address(SafeAuthority));
        vm.cool(address(sink));
    }

    /// @notice Measure initialization against the graph and return its armed receiver.
    function _initialize(SafeAuthorityRecord[] memory records, bool empty) internal returns (address receiver) {
        implementation = address(new HyperlaneReceiver(address(mailbox)));
        receiver = deployConduit(
            implementation, abi.encodeCall(IReceiverInit.initialize, (TRANSMITTER, bytes32(SOURCE), new Call[](0)))
        );
        BootstrapLeaf memory boot = BootstrapLeaf(
            Erc7930.encodeEvm(block.chainid, receiver), block.timestamp, block.timestamp + 1 days, _calls(0)
        );
        SafeTxEvidence memory e = _evidence(
            records,
            abi.encodeCall(
                ISignedTransmitter.bootstrap,
                (abi.encode(DispatchLeaves.hash(boot), uint256(0), boot, new bytes32[](0)), new bytes[](0))
            ),
            0,
            empty
        );
        bytes memory body = abi.encode(SignedBootstrap(e, records));
        _cold(receiver);
        uint256 g = gasleft();
        SignedReceiver(payable(receiver)).initializeSigned(SOURCE, SAFE, keccak256(abi.encode(records)), body);
        emit log_named_uint("initializeSignedGas", g - gasleft());
        emit log_named_uint("bootstrapBodyBytes", body.length);
    }

    /// @notice Measure a complete authenticated provider call with a prepared wire bundle.
    function _deliver(address receiver, bytes memory wire) internal returns (uint256 used) {
        _cold(receiver);
        vm.prank(address(mailbox));
        uint256 g = gasleft();
        HyperlaneReceiver(payable(receiver)).handle(uint32(SOURCE), bytes32(uint256(uint160(TRANSMITTER))), wire);
        used = g - gasleft();
    }

    /// @notice Build a deterministic sorted-pair proof of the selected depth.
    function _proof(bytes32 root, uint256 depth) internal pure returns (bytes32, bytes32[] memory proof) {
        proof = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            proof[i] = keccak256(abi.encode(i));
            root = root < proof[i] ? keccak256(abi.encode(root, proof[i])) : keccak256(abi.encode(proof[i], root));
        }
        return (root, proof);
    }

    /// @notice Measure full signed initialization and authenticated provider delivery on Paris.
    function _measure(uint256 shape, uint256 ownerCount, uint256 depth, uint256 count, uint256 attributeBytes)
        internal
    {
        vm.warp(1_000_000);
        SafeAuthorityRecord[] memory records = _records(shape, ownerCount);
        address receiver = _initialize(records, (shape == 2 || shape == 6));
        bytes[] memory attrs = new bytes[](attributeBytes == 0 ? 0 : 1);
        if (attrs.length != 0) attrs[0] = new bytes(attributeBytes);
        {
            SafeTxEvidence memory e = _evidence(
                records,
                abi.encodeCall(
                    IERC7786GatewaySource.sendMessage,
                    (Erc7930.encodeEvm(block.chainid, receiver), _calls(count), attrs)
                ),
                1,
                (shape == 2 || shape == 6)
            );
            bytes memory wire = abi.encode(WIRE_STANDALONE, e);
            emit log_named_uint("standaloneGas", _deliver(receiver, wire));
            emit log_named_uint("standaloneBytes", wire.length);
        }
        _merkle(records, receiver, attrs, depth, count, (shape == 2 || shape == 6));
        assertEq(sink.hits(), count * 2);
    }

    /// @notice Measure a Merkle delivery independently from standalone locals.
    function _merkle(
        SafeAuthorityRecord[] memory records,
        address receiver,
        bytes[] memory attrs,
        uint256 depth,
        uint256 count,
        bool empty
    ) internal {
        ExecutionLeaf memory leaf = ExecutionLeaf(
            Erc7930.encodeEvm(block.chainid, receiver),
            0,
            block.timestamp,
            block.timestamp + 1 days,
            _calls(count),
            attrs
        );
        (bytes32 root, bytes32[] memory proof) = _proof(DispatchLeaves.hash(leaf), depth);
        SafeTxEvidence memory e = _evidence(records, abi.encodeCall(ISignedTransmitter.registerRoot, (root)), 2, empty);
        bytes memory wire = abi.encode(WIRE_MERKLE, e, leaf, proof);
        emit log_named_uint("merkleGas", _deliver(receiver, wire));
        emit log_named_uint("merkleBytes", wire.length);
    }

    /// @notice Measure baseline 2-of-3 EOA receiver verification.
    function test_measureEoa() public {
        _measure(0, 3, 0, 1, 0);
    }

    /// @notice Measure one inline nested child.
    function test_measureInline() public {
        _measure(1, 3, 0, 1, 0);
    }

    /// @notice Measure an independently signed cached child approval.
    function test_measureCached() public {
        _measure(2, 3, 0, 1, 0);
    }

    /// @notice Measure two nested Safe levels.
    function test_measureTwoLevel() public {
        _measure(3, 3, 0, 1, 0);
    }

    /// @notice Measure two branches sharing a child.
    function test_measureShared() public {
        _measure(4, 3, 0, 1, 0);
    }

    /// @notice Measure a realistic 2-of-2 parent with 10-of-13 and 5-of-7 inline children.
    function test_measureLargeInline() public {
        _measure(5, 3, 0, 1, 0);
    }

    /// @notice Measure the same realistic graph carrying two independently signed approvals.
    function test_measureLargeCached() public {
        _measure(6, 3, 0, 1, 0);
    }

    /// @notice Combine the realistic approval graph with ten calls, eight siblings and attributes.
    function test_measureLargeCombined() public {
        _measure(6, 3, 8, 10, 256);
    }

    /// @notice Isolate stored owner-count growth at the same 2-signature quorum.
    function test_measureTenOwners() public {
        _measure(0, 10, 0, 1, 0);
    }

    /// @notice Isolate an eight-sibling proof's verification and wire overhead.
    function test_measureProofDepthEight() public {
        _measure(0, 3, 8, 1, 0);
    }

    /// @notice Isolate execution of ten application calls instead of one.
    function test_measureTenCalls() public {
        _measure(0, 3, 0, 10, 0);
    }

    /// @notice Isolate an extra 256 bytes of committed provider attributes.
    function test_measureAttributes256() public {
        _measure(0, 3, 0, 1, 256);
    }
}
