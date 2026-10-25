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
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {LzOftAccountFactory} from "src/protocols/layerzero/LzOftAccountFactory.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftDeploy, LzOftDestination} from "script/deploy/LzOftDeploy.sol";
import {DeliveryGasMeter} from "test/protocols/DeliveryGasMeter.sol";

/// @dev `OAppOptionsType3`, which this repo does not vendor.
interface IEnforcedOptions {
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}

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

    /// @notice The lzReceive gas in type 3 options: per option, worker id (1), size (2), then
    ///         `size` bytes of option type (1) and data, lzReceive's being type 1 with gas (16).
    function lzReceiveGas(bytes calldata options) external pure returns (uint256 gas) {
        require(uint16(bytes2(options[0:2])) == 3, "type 3 options");
        uint256 i = 2;
        while (i < options.length) {
            uint256 size = uint16(bytes2(options[i + 1:i + 3]));
            if (uint8(options[i]) == 1 && uint8(options[i + 3]) == 1) {
                gas += uint128(bytes16(options[i + 4:i + 20]));
            }
            i += 3 + size;
        }
    }
}

/// @notice frxUSD as Frax deploys it: an account homed on Fraxtal sends through the frxUSD
///         lockbox there, to Ethereum (lockbox) and Arbitrum (OFT).
///
/// @dev Each send runs the real OFT and endpoint on its home fork, with the OFT's own enforced
///      options; each delivery runs the real OFT's `lzReceive`, as its endpoint would after its
///      DVNs verified the packet, then the real endpoint's `lzCompose`. Only the DVNs and the
///      executor are stood in for.
///
/// @dev Addresses from https://docs.frax.com/protocol/crosschain/addresses, and the eids and
///      peers read from each chain, 2026-10-25. Skipped without `FRAXTAL_RPC_URL`,
///      `ETH_RPC_URL` and `ARBITRUM_RPC_URL`; public RPCs are enough.
abstract contract LzOftForkBase is Test {
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
    LzOftAccountFactory factory;
    LzOftTransmitter account;

    /// @dev Leaves the Fraxtal fork selected.
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
        vm.selectFork(fraxtal);
        reader = new PacketReader();
        vm.makePersistent(address(reader));
        return true;
    }

    function _leaves() internal view returns (LzOftAccountFactory.Leaf[] memory) {
        LzOftDestination[] memory destinations = new LzOftDestination[](2);
        destinations[0] = LzOftDestination(1, ETH_EID);
        destinations[1] = LzOftDestination(42161, ARB_EID);
        return LzOftDeploy.leaves(FRAXTAL_OFT, destinations);
    }

    /// @dev On the Fraxtal fork, funded for every send's fee.
    function _createAccount(LzOftAccountFactory.Leaf[] memory leaves) internal {
        factory = LzOftDeploy.factory();
        account = LzOftTransmitter(payable(factory.createTransmitter(SALT, FRAXTAL_OFT, leaves)));
        vm.deal(address(account), 100 ether);
    }

    /// @dev The packet the last call made the home endpoint emit.
    function _sentPacket() internal view returns (bytes memory packet) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ENDPOINT && logs[i].topics[0] == ILayerZeroEndpointV2.PacketSent.selector) {
                (packet,,) = abi.decode(logs[i].data, (bytes, bytes, address));
            }
        }
        assertGt(packet.length, 0, "the endpoint sent a packet");
    }

    function _lzReceive(address dstOft, uint64 nonce, bytes32 guid, bytes memory message) internal {
        vm.prank(ENDPOINT);
        ILayerZeroReceiver(dstOft)
            .lzReceive(
                Origin(FRAXTAL_EID, bytes32(uint256(uint160(FRAXTAL_OFT))), nonce), guid, message, address(this), ""
            );
    }

    /// @dev On the destination fork: the OFT's `lzReceive`, and the compose it queued.
    function _queue(address dstOft, bytes memory packet) internal returns (bytes32 guid, bytes memory composed) {
        uint64 nonce;
        bytes memory message;
        (nonce, guid, message,,,) = reader.read(packet);
        vm.recordLogs();
        _lzReceive(dstOft, nonce, guid, message);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ENDPOINT && logs[i].topics[0] == IMessagingComposer.ComposeSent.selector) {
                (,,,, composed) = abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
            }
        }
        assertGt(composed.length, 0, "the OFT queued the compose");
    }

    /// @dev On the destination fork: `_queue`, then the endpoint's `lzCompose`.
    function _land(address dstOft, address to, bytes memory packet) internal {
        (bytes32 guid, bytes memory composed) = _queue(dstOft, packet);
        ILayerZeroEndpointV2(ENDPOINT).lzCompose(dstOft, to, guid, 0, composed, "");
    }
}

/// @notice A bootstrap to each destination, then a message to Ethereum.
contract LzOftForkTest is LzOftForkBase {
    function _commitCall(bytes32 commitment) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(address(account), 0, abi.encodeCall(ICommitFinalize.commit, (commitment)));
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

        LzOftAccountFactory.Leaf[] memory leaves = _leaves();
        for (uint256 i; i < leaves.length; ++i) {
            assertEq(leaves[i].oft, leaves[i].eid == ETH_EID ? ETH_OFT : ARB_OFT, "the lockbox's peers are Frax's");
        }

        vm.selectFork(ethereum);
        LzOftDeploy.checkOnDestination(leaves[leaves[0].eid == ETH_EID ? 0 : 1], FRAXTAL_EID, FRAXTAL_OFT);
        vm.selectFork(arbitrum);
        LzOftDeploy.checkOnDestination(leaves[leaves[0].eid == ARB_EID ? 0 : 1], FRAXTAL_EID, FRAXTAL_OFT);

        vm.selectFork(fraxtal);
        _createAccount(leaves);

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

/// @notice `layerzero-oft`'s deliveries through frxUSD, measured as `LzOftDeliveryGasTest`
///         measures them against mocks: the endpoint's `lzCompose` into the factory or the
///         receiver against the `DeliveryGas` default the account sends, and the OFT's
///         `lzReceive` against the lzReceive gas the home lockbox enforces for that eid.
/// @dev The lzReceive figure is the OFT's frame alone, without the endpoint's own clearing of
///      the verified payload around it. Its baseline is zero: the OFT's work is the cost.
contract LzOftForkDeliveryGasTest is LzOftForkBase, DeliveryGasMeter {
    /// @dev `OFTCore.SEND_AND_CALL`, a send with a compose message.
    uint16 constant SEND_AND_CALL = 2;

    address dstOft;
    uint64 nonce;
    bytes32 guid;

    function _deliveries(uint256 chainId, uint256 fork, address oft, uint32 eid, string memory chain) internal {
        vm.selectFork(fraxtal);
        uint256 enforced = reader.lzReceiveGas(IEnforcedOptions(FRAXTAL_OFT).enforcedOptions(eid, SEND_AND_CALL));
        vm.recordLogs();
        account.bootstrap(chainId, new Call[](0), new bytes[](0));
        bytes memory packet = _sentPacket();

        vm.selectFork(fork);
        assertEq(address(LzOftDeploy.factory()), address(factory), "one factory address on every chain");
        _deliver(oft, packet, address(factory), enforced, DeliveryGas.BOOTSTRAP, string.concat(chain, ", bootstrap"));
        assertGt(address(account).code.length, 0, "the receiver exists");

        vm.selectFork(fraxtal);
        bytes memory payload = account.payloadForCalls(new Call[](0));
        bytes memory recipient = account.recipientOn(chainId);
        vm.recordLogs();
        account.sendMessage(recipient, payload, new bytes[](0));
        packet = _sentPacket();

        vm.selectFork(fork);
        _deliver(oft, packet, address(account), enforced, DeliveryGas.PAYLOAD, string.concat(chain, ", payload"));
    }

    /// @dev Measures, then delivers for real, so the next message finds the state it would.
    function _deliver(
        address oft,
        bytes memory packet,
        address to,
        uint256 enforced,
        uint256 defaultGas,
        string memory delivery
    ) internal {
        bytes memory message;
        dstOft = oft;
        (nonce, guid, message,,,) = reader.read(packet);
        _assertFits(string.concat(delivery, ", lzReceive"), _minGas(oft, address(0), message), enforced);

        (, bytes memory composed) = _queue(oft, packet);
        // The same compose queued for the baseline, as the OFT would for a send to it.
        vm.prank(oft);
        ILayerZeroEndpointV2(ENDPOINT).sendCompose(noOp, guid, 0, composed);
        _assertFits(string.concat(delivery, ", lzCompose"), _measure(to, address(0), composed), defaultGas);
        ILayerZeroEndpointV2(ENDPOINT).lzCompose(oft, to, guid, 0, composed, "");
    }

    function test_frxUsdDeliveriesFitTheirGas() public {
        // Deployed on the local chain, so carried to each fork from there.
        vm.makePersistent(noOp);
        if (!_forks()) vm.skip(true);
        _createAccount(_leaves());
        _deliveries(1, ethereum, ETH_OFT, ETH_EID, "ethereum");
        _deliveries(42161, arbitrum, ARB_OFT, ARB_EID, "arbitrum");
    }

    /// @dev External so the meter can cap the gas the delivery runs with.
    function lzReceive(bytes calldata message) external {
        _lzReceive(dstOft, nonce, guid, message);
    }

    /// @dev External so the meter can cap the gas the delivery runs with.
    function lzCompose(address to, bytes calldata composed) external {
        ILayerZeroEndpointV2(ENDPOINT).lzCompose(dstOft, to, guid, 0, composed, "");
    }

    function _meteredDelivery(uint256 gas, address to, address, bytes memory message)
        internal
        override
        returns (bool ok)
    {
        bytes memory data = to == dstOft
            ? abi.encodeCall(this.lzReceive, (message))
            : abi.encodeCall(this.lzCompose, (to, message));
        // forge-lint: disable-next-line(return-bomb) this contract returns nothing
        (ok,) = address(this).call{gas: gas}(data);
    }
}
