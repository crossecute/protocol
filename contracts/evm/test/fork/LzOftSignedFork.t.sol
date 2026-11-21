// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";
import {SafeAuthorityGraph} from "src/messaging/signed/SafeAuthorityGraph.sol";
import {SafeAuthorityRecord} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {SafeTxEvidence} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {LzOftConduitFactory} from "src/protocols/layerzero/LzOftConduitFactory.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftDeploy} from "script/deploy/LzOftDeploy.sol";
import {toBytes32} from "test/Harness.sol";
import {Records, SafeSigs} from "test/signed/SignedFixtures.sol";
import {StubGuard, StubSafe} from "test/signed/StubSafe.sol";
import {LzOftForkBase} from "test/fork/LzOftFork.t.sol";

/// @notice Real frxUSD OFT transport with a staged source Safe and cryptographic receiver checks.
contract LzOftSignedForkTest is LzOftForkBase {
    uint256 private constant FRAXTAL_CHAIN_ID = 252;
    uint256 private constant BOOTSTRAP_GAS = 1_500_000;
    uint256 private constant MESSAGE_GAS = 600_000;
    address private constant TREASURY = address(0x7EA5);
    address private constant MULTISEND_CALL_ONLY = address(0xCA11);
    bytes32 private constant AUTHORITY_HEAD = bytes32(uint256(1));

    StubSafe private safe;
    StubGuard private guard;
    bytes32 private authorityHash;
    uint256 private nonce;

    function test_frxUsdCarriesSignedBootstrapsAndMessagesFromFraxtal() public {
        if (!_forks()) vm.skip(true);
        assertEq(block.chainid, FRAXTAL_CHAIN_ID);
        _createSignedConduit();
        _roundTrip(ethereum, 1, ETH_OFT);
        _roundTrip(arbitrum, 42161, ARB_OFT);
    }

    function _createSignedConduit() private {
        guard = new StubGuard();
        safe = new StubSafe();
        address[] memory owners = new address[](2);
        owners[0] = vm.addr(1);
        owners[1] = vm.addr(2);
        safe.setOwners(owners, 2);
        safe.setGuard(address(guard));
        authorityHash = Records.graphHash(FRAXTAL_CHAIN_ID, SafeAuthorityGraph.derive(address(safe)));
        guard.setSelection(address(safe), AUTHORITY_HEAD, authorityHash);

        factory = LzOftDeploy.factory(TREASURY, address(guard), MULTISEND_CALL_ONLY);
        LzOftConduitFactory.Leaf[] memory leaves = _leaves();
        bytes memory result =
            safe.exec(address(factory), 0, abi.encodeCall(factory.createTransmitter, (SALT, FRAXTAL_OFT, leaves)));
        conduit = LzOftTransmitter(payable(abi.decode(result, (address))));
        assertTrue(conduit.isSigned());
        vm.deal(address(conduit), 100 ether);
    }

    function _roundTrip(uint256 fork, uint256 chainId, address oft) private {
        vm.selectFork(fraxtal);
        bytes32 setup = keccak256(abi.encode("signed OFT setup", chainId));
        bytes memory packet = _bootstrap(chainId, setup);

        vm.selectFork(fork);
        assertEq(block.chainid, chainId);
        assertEq(address(LzOftDeploy.factory(TREASURY, address(guard), MULTISEND_CALL_ONLY)), address(factory));
        _compose(oft, address(factory), packet, BOOTSTRAP_GAS);

        LzOftReceiver receiver = LzOftReceiver(payable(address(conduit)));
        assertEq(receiver.authorityGraph(), authorityHash);
        assertEq(receiver.selection().updateHead, AUTHORITY_HEAD);
        assertEq(receiver.homeOft(), FRAXTAL_OFT);
        assertEq(receiver.localOft(), oft);
        assertTrue(receiver.isCommitted(setup));

        vm.selectFork(fraxtal);
        bytes32 effect = keccak256(abi.encode("signed OFT message", chainId));
        SafeTxEvidence memory evidence = _sign(
            abi.encodeCall(
                conduit.sendMessage, (conduit.recipientOn(chainId), _calls(effect), _attributes(MESSAGE_GAS))
            )
        );
        bytes32 digest = _digest(evidence);
        packet = _send(evidence, conduit.quoteMessageSigned(evidence), address(conduit));

        vm.selectFork(fork);
        assertFalse(receiver.isMessageExecuted(digest));
        _compose(oft, address(receiver), packet, MESSAGE_GAS);
        assertTrue(receiver.isCommitted(effect));
        assertTrue(receiver.isMessageExecuted(digest));
        receiver.submitMessage(evidence);
    }

    function _bootstrap(uint256 chainId, bytes32 effect) private returns (bytes memory) {
        SafeAuthorityRecord[] memory records = SafeAuthorityGraph.derive(address(safe));
        bytes memory body = Records.bootstrap(address(guard), records, _calls(effect));
        bytes memory payload = Payload.encodeBootstrap(Erc7930.encodeEvmChain(chainId), body);
        bytes[] memory attributes = _attributes(BOOTSTRAP_GAS);
        return _send(
            _sign(abi.encodeCall(ISignedTransmitter.bootstrap, (payload, attributes))),
            conduit.quoteBootstrap(payload, attributes),
            address(factory)
        );
    }

    function _calls(bytes32 effect) private view returns (bytes memory) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(conduit), 0, abi.encodeCall(ICommitFinalize.commit, (effect)));
        return abi.encode(calls);
    }

    function _attributes(uint256 gas) private pure returns (bytes[] memory attributes) {
        attributes = new bytes[](1);
        attributes[0] = abi.encodePacked(LzMessage.OPTIONS_ATTRIBUTE, LzMessage.defaultComposeOptions(gas));
    }

    function _digest(SafeTxEvidence memory evidence) private view returns (bytes32) {
        return SafeHashes.transactionHash(evidence.signedSafeTx.safeTx, address(safe), FRAXTAL_CHAIN_ID);
    }

    function _sign(bytes memory data) private returns (SafeTxEvidence memory evidence) {
        evidence.signedSafeTx.safeTx.to = address(conduit);
        evidence.signedSafeTx.safeTx.data = data;
        evidence.signedSafeTx.safeTx.nonce = nonce++;
        evidence.signedSafeTx.signatures =
            SafeSigs.blob(SafeSigs.two(SafeSigs.eoa(1), SafeSigs.eoa(2)), _digest(evidence));
    }

    function _send(SafeTxEvidence memory evidence, uint256 quote, address to) private returns (bytes memory packet) {
        assertGt(quote, 0);
        uint256 balance = address(conduit).balance;
        guard.stage(address(safe), evidence.signedSafeTx.safeTx, evidence.signedSafeTx.signatures);
        vm.recordLogs();
        safe.exec(address(conduit), 0, evidence.signedSafeTx.safeTx.data);
        packet = _sentPacket();
        (,,, bytes32 sendTo, uint64 amountSD, bytes32 composeFrom) = reader.read(packet);
        assertEq(sendTo, toBytes32(to));
        assertEq(amountSD, 0);
        assertEq(composeFrom, toBytes32(address(conduit)));
        assertEq(balance - address(conduit).balance, quote);
        emit log_named_uint("quote paid (wei)", quote);
        emit log_named_uint("LayerZero packet bytes", packet.length);
    }

    function _compose(address oft, address to, bytes memory packet, uint256 gas) private {
        (bytes32 guid, bytes memory composed) = _queue(oft, packet);
        ILayerZeroEndpointV2(ENDPOINT).lzCompose{gas: gas}(oft, to, guid, 0, composed, "");
    }
}
