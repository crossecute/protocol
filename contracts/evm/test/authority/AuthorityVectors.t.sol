// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {AuthorityEntry, AuthorityGraph} from "src/messaging/authority/AuthorityGraph.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {ChildUpdate} from "src/messaging/authority/ChildUpdate.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {SignedReceiver} from "src/messaging/inbound/SignedReceiver.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {Call} from "src/messaging/Call.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {deployConduit} from "test/DeployProxy.sol";
import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";

/// @dev Replays docs/vectors/safe-authority-updates-109.json, which cast generates without the
///      Solidity encoders. Each receiver vector seeds a real SignedReceiver from its encoded
///      bootstrap, checks the encoders agree with the vector's hashes and batch calldata, then
///      submits the encoded submission and checks the stated verdict.
contract AuthorityVectorsTest is Test {
    address private constant TRANSMITTER = address(0x7777);
    uint32 private constant HOME_DOMAIN = 10;

    string private json;
    MockHyperlaneMailbox private mailbox;

    function setUp() public {
        // forge-lint: disable-next-line(unsafe-cheatcode) reads the checked-in vector file
        json = vm.readFile(string.concat(vm.projectRoot(), "/../../docs/vectors/safe-authority-updates-109.json"));
        mailbox = new MockHyperlaneMailbox();
    }

    function _at(string memory list, uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(list, "[", vm.toString(i), "]", field);
    }

    /// @dev Each JSON cheatcode copies the whole file, so metering would charge the reads, not
    ///      the code under test; no assertion here depends on gas.
    function test_cryptoVectorsMatchSafeHashesAndSigners() public {
        vm.pauseGasMetering();
        uint256 i;
        for (; vm.keyExistsJson(json, _at(".cryptoVectors", i, "")); ++i) {
            string memory p = _at(".cryptoVectors", i, "");
            address safe = vm.parseJsonAddress(json, string.concat(p, ".safe"));
            uint256 chainId = vm.parseJsonUint(json, string.concat(p, ".chainId"));
            bytes32 digest = vm.parseJsonBytes32(json, string.concat(p, ".digest"));
            if (vm.keyExistsJson(json, string.concat(p, ".safeTx"))) {
                assertEq(SafeHashes.transactionHash(_safeTx(string.concat(p, ".safeTx")), safe, chainId), digest);
            } else {
                bytes32 parent = vm.parseJsonBytes32(json, string.concat(p, ".parentHash"));
                assertEq(SafeSignaturesUtils.nestedHash(parent, safe, chainId), digest);
            }
            address signer = vm.parseJsonAddress(json, string.concat(p, ".expectedSigner"));
            assertEq(_recover(digest, vm.parseJsonBytes(json, string.concat(p, ".rawSafeSignature"))), signer);
            assertEq(_recover(digest, vm.parseJsonBytes(json, string.concat(p, ".ethSignSafeSignature"))), signer);
        }
        assertEq(i, 5);
    }

    function test_receiverVectors() public {
        vm.pauseGasMetering();
        uint256 snapshot = vm.snapshotState();
        uint256 i;
        for (; vm.keyExistsJson(json, _at(".receiverVectors", i, "")); ++i) {
            string memory p = _at(".receiverVectors", i, "");
            emit log_named_string("vector", vm.parseJsonString(json, string.concat(p, ".id")));
            _replay(p);
            assertTrue(vm.revertToState(snapshot));
        }
        assertGt(i, 0);
    }

    function _replay(string memory p) private {
        uint256 chainId = vm.parseJsonUint(json, string.concat(p, ".sourceChainId"));
        address safe = vm.parseJsonAddress(json, string.concat(p, ".sourceSafe"));
        SignedReceiver r = _seed(p, chainId, safe);
        bytes32 seededHead = r.selection().updateHead;
        bytes32 seededGraph = r.authorityGraph();

        (SafeTxEvidence memory evidence, AuthorityGraph memory graph, ChildUpdate[] memory children) = abi.decode(
            vm.parseJsonBytes(json, string.concat(p, ".submission")), (SafeTxEvidence, AuthorityGraph, ChildUpdate[])
        );
        _checkEncoders(string.concat(p, ".update"), chainId, safe, evidence.signedSafeTx.safeTx);
        _checkEntries(
            string.concat(p, ".newGraph.entries"),
            chainId,
            AuthorityUpdateEncoding.entries(graph),
            string.concat(p, ".newGraph.graphHash")
        );
        for (uint256 k; k < children.length; ++k) {
            string memory c = _at(string.concat(p, ".childUpdates"), k, "");
            _checkEncoders(c, chainId, children[k].sourceSafe, children[k].evidence.signedSafeTx.safeTx);
            _checkEntries(
                string.concat(c, ".newGraphEntries"),
                chainId,
                children[k].newGraphEntries,
                string.concat(c, ".newAuthorityHash")
            );
            assertEq(
                AuthorityUpdateEncoding.recordHash(children[k].newRecord), children[k].newGraphEntries[0].recordHash
            );
        }

        string memory expect = string.concat(p, ".expect");
        if (keccak256(bytes(vm.parseJsonString(json, string.concat(expect, ".result")))) == keccak256("accept")) {
            r.submitAuthority(evidence, graph, children);
            assertEq(r.selection().updateHead, vm.parseJsonBytes32(json, string.concat(expect, ".updateHead")));
            assertEq(r.authorityGraph(), vm.parseJsonBytes32(json, string.concat(expect, ".authorityHash")));
            return;
        }
        if (vm.keyExistsJson(json, string.concat(expect, ".revertData"))) {
            vm.expectRevert(vm.parseJsonBytes(json, string.concat(expect, ".revertData")));
        } else {
            vm.expectPartialRevert(bytes4(vm.parseJsonBytes(json, string.concat(expect, ".errorSelector"))));
        }
        r.submitAuthority(evidence, graph, children);
        assertEq(r.selection().updateHead, seededHead);
        assertEq(r.authorityGraph(), seededGraph);
    }

    function _seed(string memory p, uint256 chainId, address safe) private returns (SignedReceiver r) {
        address guard = vm.parseJsonAddress(json, string.concat(p, ".guard"));
        address multiSend = vm.parseJsonAddress(json, string.concat(p, ".multiSendCallOnly"));
        r = SignedReceiver(
            payable(deployConduit(
                    address(new HyperlaneReceiver(address(mailbox), guard, multiSend)),
                    abi.encodeCall(
                        IReceiverInit.initialize, (TRANSMITTER, bytes32(uint256(HOME_DOMAIN)), new Call[](0))
                    )
                ))
        );
        r.initializeSigned(chainId, safe, vm.parseJsonBytes(json, string.concat(p, ".bootstrap.encoded")));
        assertEq(r.selection().updateHead, vm.parseJsonBytes32(json, string.concat(p, ".bootstrap.updateHead")));
        assertEq(r.authorityGraph(), vm.parseJsonBytes32(json, string.concat(p, ".bootstrap.graph.graphHash")));
    }

    /// @dev The SafeTx hash, and for an ownership change the batch calldata rebuilt from the
    ///      vector's listed mutations.
    function _checkEncoders(string memory u, uint256 chainId, address safe, SafeTx memory safeTx) private view {
        assertEq(
            SafeHashes.transactionHash(safeTx, safe, chainId),
            vm.parseJsonBytes32(json, string.concat(u, ".safeTxHash"))
        );
        if (!vm.keyExistsJson(json, string.concat(u, ".mutations[0]"))) return;
        uint256 n;
        while (vm.keyExistsJson(json, _at(string.concat(u, ".mutations"), n, ""))) ++n;
        Call[] memory mutations = new Call[](n);
        for (uint256 i; i < n; ++i) {
            string memory m = _at(string.concat(u, ".mutations"), i, "");
            mutations[i] = Call(
                vm.parseJsonAddress(json, string.concat(m, ".target")),
                vm.parseJsonUint(json, string.concat(m, ".value")),
                vm.parseJsonBytes(json, string.concat(m, ".data"))
            );
        }
        AuthorityUpdate memory update = AuthorityUpdate(
            vm.parseJsonBytes32(json, string.concat(u, ".previousUpdateHash")),
            vm.parseJsonBytes32(json, string.concat(u, ".newAuthorityHash"))
        );
        address guard = vm.parseJsonAddress(json, ".receiverVectors[0].guard");
        assertEq(AuthorityUpdateEncoding.ownershipBatchData(guard, safe, update, mutations), safeTx.data);
    }

    function _checkEntries(string memory list, uint256 chainId, AuthorityEntry[] memory entries, string memory hashKey)
        private
        view
    {
        for (uint256 i; i < entries.length; ++i) {
            assertEq(entries[i].recordHash, vm.parseJsonBytes32(json, _at(list, i, ".recordHash")));
            assertEq(entries[i].position, vm.parseJsonBytes32(json, _at(list, i, ".position")));
        }
        assertFalse(vm.keyExistsJson(json, _at(list, entries.length, "")));
        assertEq(AuthorityUpdateEncoding.graphHash(chainId, entries), vm.parseJsonBytes32(json, hashKey));
    }

    function _safeTx(string memory t) private view returns (SafeTx memory safeTx) {
        safeTx.to = vm.parseJsonAddress(json, string.concat(t, ".to"));
        safeTx.value = vm.parseJsonUint(json, string.concat(t, ".value"));
        safeTx.data = vm.parseJsonBytes(json, string.concat(t, ".data"));
        safeTx.operation = uint8(vm.parseJsonUint(json, string.concat(t, ".operation")));
        safeTx.safeTxGas = vm.parseJsonUint(json, string.concat(t, ".safeTxGas"));
        safeTx.baseGas = vm.parseJsonUint(json, string.concat(t, ".baseGas"));
        safeTx.gasPrice = vm.parseJsonUint(json, string.concat(t, ".gasPrice"));
        safeTx.gasToken = vm.parseJsonAddress(json, string.concat(t, ".gasToken"));
        safeTx.refundReceiver = vm.parseJsonAddress(json, string.concat(t, ".refundReceiver"));
        safeTx.nonce = vm.parseJsonUint(json, string.concat(t, ".nonce"));
    }

    function _recover(bytes32 digest, bytes memory signature) private pure returns (address) {
        (bytes32 r, bytes32 s) = abi.decode(signature, (bytes32, bytes32));
        return SafeSignaturesUtils.recover(digest, r, s, uint8(signature[64]));
    }
}
