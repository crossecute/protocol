// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {
    ILayerZeroEndpointV2,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IMessagingComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingComposer.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {ICommitFinalize, ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {LzOftFactory} from "src/protocols/layerzero/LzOftFactory.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftDeploy, LzOftDestination} from "script/deploy/LzOftDeploy.sol";

/// @dev Reads a packet `EndpointV2` emitted in `PacketSent`, at `PacketV1Codec`'s offsets, and the
///      OFT message inside it at `OFTMsgCodec`'s.
contract PacketReader {
    function read(bytes calldata packet)
        external
        pure
        returns (uint64 nonce, bytes32 guid, bytes memory message, bytes32 sendTo, uint64 amountSD, bytes32 composeFrom)
    {
        nonce = uint64(bytes8(packet[1:9]));
        guid = bytes32(packet[81:113]);
        message = packet[113:];
        sendTo = bytes32(packet[113:145]);
        amountSD = uint64(bytes8(packet[145:153]));
        composeFrom = bytes32(packet[153:185]);
    }
}

/// @notice `layerzero-oft` through frxUSD as Frax deploys it: an account homed on Fraxtal sends
///         through the frxUSD lockbox there, and bootstraps on Ethereum (lockbox) and Arbitrum
///         (OFT), then sends a message to Ethereum.
///
/// @dev Each send runs the real OFT and endpoint on its home fork, with the OFT's own enforced
///      options; each delivery runs the real OFT's `lzReceive`, as its endpoint would after its
///      DVNs verified the packet, then the real endpoint's `lzCompose`. Only the DVNs and the
///      executor are stood in for.
///
/// @dev Addresses from https://docs.frax.com/protocol/crosschain/addresses, and the eids and
///      peers read from each chain, 2026-10-25. Skipped without `FRAXTAL_RPC_URL`,
///      `ETH_RPC_URL` and `ARBITRUM_RPC_URL`; public RPCs are enough.
contract LzOftForkTest is Test {
    uint32 constant FRAXTAL_EID = 30255;
    uint32 constant ETH_EID = 30101;
    uint32 constant ARB_EID = 30110;
    address constant FRAXTAL_OFT = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;
    address constant ETH_OFT = 0x566a6442A5A6e9895B9dCA97cC7879D632c6e4B0;
    address constant ARB_OFT = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    bytes32 constant SALT = keccak256("frxusd");

    PacketReader reader;
    uint256 fraxtal;
    uint256 ethereum;
    uint256 arbitrum;
    LzOftFactory factory;
    LzOftTransmitter account;

    function _forks() internal returns (bool) {
        string memory f = vm.envOr("FRAXTAL_RPC_URL", string(""));
        string memory e = vm.envOr("ETH_RPC_URL", string(""));
        string memory a = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(f).length == 0 || bytes(e).length == 0 || bytes(a).length == 0) return false;
        fraxtal = vm.createFork(f);
        ethereum = vm.createFork(e);
        arbitrum = vm.createFork(a);
        // Frax's contracts use opcodes after `paris`, the version this repo compiles for so its
        // addresses match on every chain. Execution only: the bytecode deployed here is unchanged.
        vm.setEvmVersion("cancun");
        return true;
    }

    function _commitCall(bytes32 commitment) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(address(account), 0, abi.encodeCall(ICommitFinalize.commit, (commitment)));
    }

    /// @dev The packet the last call made the home endpoint emit.
    function _sentPacket() internal returns (bytes memory packet) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ENDPOINT && logs[i].topics[0] == ILayerZeroEndpointV2.PacketSent.selector) {
                (packet,,) = abi.decode(logs[i].data, (bytes, bytes, address));
            }
        }
        assertGt(packet.length, 0, "the endpoint sent a packet");
    }

    /// @dev On the destination fork: the OFT's `lzReceive`, then the endpoint's `lzCompose`.
    function _land(address dstOft, address to, bytes memory packet) internal {
        (uint64 nonce, bytes32 guid, bytes memory message,,,) = reader.read(packet);
        vm.recordLogs();
        vm.prank(ENDPOINT);
        ILayerZeroReceiver(dstOft)
            .lzReceive(
                Origin(FRAXTAL_EID, bytes32(uint256(uint160(FRAXTAL_OFT))), nonce), guid, message, address(this), ""
            );
        bytes memory composed;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ENDPOINT && logs[i].topics[0] == IMessagingComposer.ComposeSent.selector) {
                (,,,, composed) = abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
            }
        }
        assertGt(composed.length, 0, "the OFT queued the compose");
        ILayerZeroEndpointV2(ENDPOINT).lzCompose(dstOft, to, guid, 0, composed, "");
    }

    function _bootstrap(uint256 chainId, uint256 fork, address dstOft) internal {
        vm.selectFork(fraxtal);
        Call[] memory calls = _commitCall(keccak256(abi.encode("bootstrap", chainId)));
        uint256 quote = account.quoteBootstrap(chainId, calls, new bytes[](0));
        assertGt(quote, 0, "the lockbox's enforced options price a compose send");
        vm.recordLogs();
        account.bootstrap(chainId, calls, new bytes[](0));
        bytes memory packet = _sentPacket();
        (,,, bytes32 sendTo, uint64 amountSD, bytes32 composeFrom) = reader.read(packet);
        assertEq(sendTo, bytes32(uint256(uint160(address(factory)))), "to the factory");
        assertEq(amountSD, 0, "no tokens");
        assertEq(composeFrom, bytes32(uint256(uint160(address(account)))), "composeFrom is the account");

        vm.selectFork(fork);
        assertEq(address(LzOftDeploy.factory()), address(factory), "one factory address on every chain");
        _land(dstOft, address(factory), packet);

        LzOftReceiver r = LzOftReceiver(payable(address(account)));
        assertEq(r.sourceTransmitter(), address(account));
        assertEq(r.homeOrigin(), bytes32(uint256(FRAXTAL_EID)));
        assertEq(r.localOft(), dstOft);
        assertTrue(r.isCommitted(keccak256(abi.encode("bootstrap", chainId))), "ran the bootstrap call");
    }

    function test_frxUsdCarriesABootstrapToEachDestinationAndAMessageAfter() public {
        if (!_forks()) vm.skip(true);
        vm.selectFork(fraxtal);
        reader = new PacketReader();
        vm.makePersistent(address(reader));

        LzOftDestination[] memory destinations = new LzOftDestination[](2);
        destinations[0] = LzOftDestination(1, ETH_EID);
        destinations[1] = LzOftDestination(42161, ARB_EID);
        LzOftFactory.Leaf[] memory leaves = LzOftDeploy.leaves(FRAXTAL_OFT, destinations);
        for (uint256 i; i < leaves.length; ++i) {
            assertEq(leaves[i].oft, leaves[i].eid == ETH_EID ? ETH_OFT : ARB_OFT, "the lockbox's peers are Frax's");
        }

        vm.selectFork(ethereum);
        LzOftDeploy.checkOnDestination(leaves[leaves[0].eid == ETH_EID ? 0 : 1], FRAXTAL_EID, FRAXTAL_OFT);
        vm.selectFork(arbitrum);
        LzOftDeploy.checkOnDestination(leaves[leaves[0].eid == ARB_EID ? 0 : 1], FRAXTAL_EID, FRAXTAL_OFT);

        vm.selectFork(fraxtal);
        factory = LzOftDeploy.factory();
        account = LzOftTransmitter(payable(factory.createTransmitter(SALT, FRAXTAL_OFT, leaves)));
        vm.deal(address(account), 100 ether);

        _bootstrap(1, ethereum, ETH_OFT);
        _bootstrap(42161, arbitrum, ARB_OFT);

        // Path A, to the receiver the Ethereum bootstrap created.
        vm.selectFork(fraxtal);
        bytes32 later = keccak256("path A");
        bytes memory recipient = account.recipientOn(1);
        bytes memory payload = account.payloadForCalls(_commitCall(later));
        vm.recordLogs();
        account.sendMessage(recipient, payload, new bytes[](0));
        bytes memory packet = _sentPacket();
        vm.selectFork(ethereum);
        _land(ETH_OFT, address(account), packet);
        assertTrue(ReceiverBase(payable(address(account))).isCommitted(later), "Path A ran on Ethereum");
    }
}
