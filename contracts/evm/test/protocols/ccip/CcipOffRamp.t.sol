// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Test} from "forge-std/Test.sol";
import {MessageV1Codec} from "@chainlink/contracts-ccip/contracts/libraries/MessageV1Codec.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {CcipConfig} from "src/protocols/ccip/CcipConfig.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {CcipPolicy} from "src/protocols/ccip/CcipPolicy.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {deployConduit} from "test/DeployProxy.sol";
import {ext} from "test/Harness.sol";
import {ProviderInboundFixture} from "test/protocols/ProviderBindingSpec.t.sol";
import {CcipFixture} from "test/protocols/ccip/CcipFixture.sol";

interface IRealOffRamp {
    struct StaticConfig {
        uint64 localChainSelector;
        uint16 gasForCallExactCheck;
        address rmnRemote;
        address tokenAdminRegistry;
        uint32 maxGasBufferToUpdateState;
    }

    struct SourceConfig {
        address router;
        uint64 sourceChainSelector;
        bool isEnabled;
        bytes[] onRamps;
        address[] defaultCCVs;
        address[] laneMandatedCCVs;
    }
    function applySourceChainConfigUpdates(SourceConfig[] calldata configs) external;
    function getCCVsForMessage(bytes calldata message) external view returns (address[] memory, address[] memory, uint8);
    function execute(bytes calldata message, address[] calldata ccvs, bytes[] calldata proofs, uint32 gasOverride)
        external;
    function getExecutionState(bytes32 id) external view returns (uint8);
    function typeAndVersion() external view returns (string memory);
}

interface IRealRouter {
    struct Ramp {
        uint64 selector;
        address ramp;
    }
    function applyRampUpdates(Ramp[] calldata onRamps, Ramp[] calldata removes, Ramp[] calldata adds) external;
}

contract UncursedRmn {
    function isCursed(bytes16) external pure returns (bool) {
        return false;
    }

    function isCursed() external pure returns (bool) {
        return false;
    }
}

/// @dev A local verifier requires a distinct signer's attestation over the actual message id.
contract SignedTestCcv {
    address private immutable signer;
    uint256 public verified;

    constructor(address signer_) {
        signer = signer_;
    }

    function getInboundImplementation(bytes calldata) external view returns (address) {
        return address(this);
    }

    function verifyMessage(MessageV1Codec.MessageV1 calldata, bytes32 id, bytes calldata proof) external {
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(proof, (uint8, bytes32, bytes32));
        require(ECDSA.recover(id, v, r, s) == signer, "invalid attestation");
        ++verified;
    }
}

contract OffRampTarget {
    uint256 public calls;
    bool public fail;

    function setFail(bool value) external {
        fail = value;
    }

    function run() external payable {
        require(!fail, "retry me");
        ++calls;
    }
}

contract CustomTestExecutor {
    function execute(IRealOffRamp offRamp, bytes calldata message, address[] calldata ccvs, bytes[] calldata proofs)
        external
    {
        offRamp.execute(message, ccvs, proofs, 0);
    }
}

/// @notice The pinned upstream Router and OffRamp, a default and an additional signing CCV, and
///         MessageV1 construction for any local CCIP receiver.
abstract contract CcipOffRampFixture is Test {
    uint64 internal constant SOURCE = 15_971_525_489_660_198_786;
    uint64 internal constant DEST = 5_009_297_550_715_157_269;
    address internal constant ONRAMP = address(0xAAAA);
    IRealOffRamp internal offRamp;
    address internal ccipRouter;
    SignedTestCcv internal defaultCcv;
    SignedTestCcv internal additionalCcv;
    uint64 private nonce;

    function _deployOffRamp() internal {
        // Only the pinned upstream binary needs Cancun opcodes; protocol compilation remains Paris.
        vm.setEvmVersion("cancun");
        UncursedRmn rmn = new UncursedRmn();
        ccipRouter = _deployBinary(
            "router.bin",
            0x4b6f8b62c05cda2a60ff7a65b2ac80fe2ffc49cff2478f8992bb76e2ef8cf3da,
            abi.encode(address(0xBEEF), address(rmn))
        );
        offRamp = IRealOffRamp(
            _deployBinary(
                "offramp.bin",
                0x08915d1a9f0e602dff101c65387a6157e8ce62bc1d56a9efb53d70b04eb12e28,
                abi.encode(IRealOffRamp.StaticConfig(DEST, 5000, address(rmn), address(0xBEEF), 100_000))
            )
        );
        assertEq(offRamp.typeAndVersion(), "OffRamp 2.0.0");
        IRealRouter.Ramp[] memory adds = new IRealRouter.Ramp[](1);
        adds[0] = IRealRouter.Ramp(SOURCE, address(offRamp));
        IRealRouter(ccipRouter).applyRampUpdates(new IRealRouter.Ramp[](0), new IRealRouter.Ramp[](0), adds);
        defaultCcv = new SignedTestCcv(vm.addr(1));
        additionalCcv = new SignedTestCcv(vm.addr(2));
        IRealOffRamp.SourceConfig[] memory configs = new IRealOffRamp.SourceConfig[](1);
        address[] memory defaults = new address[](1);
        defaults[0] = address(defaultCcv);
        bytes[] memory onRamps = new bytes[](1);
        onRamps[0] = abi.encode(ONRAMP);
        configs[0] = IRealOffRamp.SourceConfig(ccipRouter, SOURCE, true, onRamps, defaults, new address[](0));
        offRamp.applySourceChainConfigUpdates(configs);
    }

    function _deployBinary(string memory file, bytes32 expectedHash, bytes memory args)
        private
        returns (address deployed)
    {
        // forge-lint: disable-next-line(unsafe-cheatcode) read only the pinned integration artifact, checked below
        string memory hexCode = vm.readFile(string.concat("test/fixtures/ccip-v2/", file));
        assertEq(sha256(bytes(hexCode)), expectedHash);
        bytes memory code = abi.encodePacked(vm.parseBytes(hexCode), args);
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0), "upstream binary deployment failed");
    }

    function _messageV1(
        address to,
        bytes memory data,
        bytes4 finality,
        uint32 gasLimit,
        address sender,
        address executor
    ) internal returns (bytes memory) {
        MessageV1Codec.MessageV1 memory m;
        m.sourceChainSelector = SOURCE;
        m.destChainSelector = DEST;
        m.messageNumber = ++nonce;
        m.executionGasLimit = 2_000_000;
        m.ccipReceiveGasLimit = gasLimit;
        m.finality = finality;
        address[] memory selected = new address[](1);
        selected[0] = address(defaultCcv);
        m.ccvAndExecutorHash =
            MessageV1Codec._computeCCVAndExecutorHash(selected, executor == address(0) ? address(0xEEEE) : executor);
        m.onRampAddress = abi.encode(ONRAMP);
        m.offRampAddress = abi.encodePacked(address(offRamp));
        m.sender = abi.encode(sender);
        m.receiver = abi.encodePacked(to);
        m.tokenTransfer = new MessageV1Codec.TokenTransferV1[](0);
        m.data = data;
        return MessageV1Codec._encodeMessageV1(m);
    }

    function _proof(bytes memory message, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(message));
        return abi.encode(v, r, s);
    }

    function _attestations(bytes memory message, bool includeAdditional)
        internal
        view
        returns (address[] memory ccvs, bytes[] memory proofs)
    {
        ccvs = new address[](includeAdditional ? 2 : 1);
        proofs = new bytes[](ccvs.length);
        ccvs[0] = address(defaultCcv);
        proofs[0] = _proof(message, 1);
        if (includeAdditional) {
            ccvs[1] = address(additionalCcv);
            proofs[1] = _proof(message, 2);
        }
    }

    function _execute(bytes memory message, bool additional, uint32 gasOverride) internal {
        (address[] memory ccvs, bytes[] memory proofs) = _attestations(message, additional);
        offRamp.execute(message, ccvs, proofs, gasOverride);
    }

    /// @dev Upstream `Internal.MessageExecutionState`: 2 is SUCCESS, 3 is FAILURE.
    function _state(bytes memory message) internal view returns (uint8) {
        return offRamp.getExecutionState(keccak256(message));
    }
}

contract CcipOffRampTest is CcipOffRampFixture {
    address private constant SENDER = address(0xABCD);
    CcipReceiver private receiver;
    OffRampTarget private target;

    function setUp() public {
        _deployOffRamp();
        receiver = CcipReceiver(
            payable(deployConduit(
                    address(new CcipReceiver(ccipRouter, address(0), address(0))),
                    abi.encodeCall(IReceiverInit.initialize, (SENDER, bytes32(uint256(SOURCE)), new Call[](0)))
                ))
        );
        target = new OffRampTarget();
    }

    function _message(bytes4 finality, uint32 gasLimit, uint256 value, address sender, address executor)
        private
        returns (bytes memory)
    {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(target), value, abi.encodeCall(OffRampTarget.run, ()));
        return _messageV1(address(receiver), Payload.encodeCalls(calls), finality, gasLimit, sender, executor);
    }

    function _policy(bool additional, bytes4 allowed) private {
        CcipConfig.Policy memory p;
        p.requiredCCVs = new address[](additional ? 2 : 0);
        if (additional) p.requiredCCVs[1] = address(additionalCcv);
        p.allowedFinalityConfig = allowed;
        vm.prank(SENDER);
        receiver.setCcipPolicy(SOURCE, abi.encode(SENDER), p);
    }

    function test_realOffRampEnforcesDefaultFinalityAndPolicyUpdatesOnPendingMessages() public {
        bytes memory message = _message(bytes4(uint32(32)), 500_000, 0, SENDER, address(0));
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        assertEq(target.calls(), 0);
        _policy(false, bytes4(uint32(32)));
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 2);
        assertEq(target.calls(), 1);
        bytes memory pending = _message(bytes4(uint32(32)), 500_000, 0, SENDER, address(0));
        _policy(false, bytes4(0));
        _execute(pending, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(pending)), 3);
    }

    function test_realOffRampRequiresAdditionalVerifierAndResolvesDefaultPlaceholder() public {
        _policy(true, bytes4(0));
        bytes memory message = _message(bytes4(0), 500_000, 0, SENDER, address(0));
        (address[] memory required,,) = offRamp.getCCVsForMessage(message);
        assertEq(required.length, 2);
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        assertEq(target.calls(), 0);
        _execute(message, true, 0);
        assertEq(target.calls(), 1);
        assertEq(additionalCcv.verified(), 1);
        assertEq(defaultCcv.verified(), 1);
    }

    /// @dev The receiver's only route to its policy is a message that must satisfy that policy.
    function test_anUnsatisfiablePolicyBlocksItsOwnReset() public {
        _policy(true, bytes4(0));
        CcipConfig.Policy memory defaults;
        Call[] memory calls = new Call[](1);
        calls[0] = Call(
            address(receiver), 0, abi.encodeCall(CcipPolicy.setCcipPolicy, (SOURCE, abi.encode(SENDER), defaults))
        );
        bytes memory reset =
            _messageV1(address(receiver), Payload.encodeCalls(calls), bytes4(0), 500_000, SENDER, address(0));

        _execute(reset, false, 0);
        assertEq(_state(reset), 3);
        (address[] memory required,,,) = receiver.getCCVsAndFinalityConfig(SOURCE, abi.encode(SENDER));
        assertEq(required.length, 2);

        _execute(reset, true, 0);
        assertEq(_state(reset), 2);
        (required,,,) = receiver.getCCVsAndFinalityConfig(SOURCE, abi.encode(SENDER));
        assertEq(required.length, 0);
    }

    function test_optionalVerifierThresholdIsEnforcedByUpstreamOffRamp() public {
        CcipConfig.Policy memory p;
        p.optionalCCVs = new address[](1);
        p.optionalCCVs[0] = address(additionalCcv);
        p.optionalThreshold = 1;
        vm.prank(SENDER);
        receiver.setCcipPolicy(SOURCE, abi.encode(SENDER), p);
        bytes memory message = _message(bytes4(0), 500_000, 0, SENDER, address(0));
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        _execute(message, true, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 2);
    }

    function test_invalidAttestationAndWrongSenderCannotDriveReceiver() public {
        bytes memory message = _message(bytes4(0), 500_000, 0, SENDER, address(0));
        (address[] memory ccvs, bytes[] memory proofs) = _attestations(message, false);
        proofs[0] = _proof(message, 2);
        offRamp.execute(message, ccvs, proofs, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        _execute(_message(bytes4(0), 500_000, 0, address(0xBAD), address(0)), false, 0);
        assertEq(target.calls(), 0);
    }

    function test_noExecCanBeExecutedLaterPermissionlesslyWithFundingRetryAndReplayProtection() public {
        bytes memory message = _message(bytes4(0), 500_000, 1 ether, SENDER, Client.NO_EXECUTION_ADDRESS);
        assertEq(target.calls(), 0);
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        vm.deal(address(receiver), 1 ether);
        (address[] memory ccvs, bytes[] memory proofs) = _attestations(message, false);
        vm.prank(address(0x7777));
        offRamp.execute(message, ccvs, proofs, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 2);
        assertEq(target.calls(), 1);
        assertEq(address(target).balance, 1 ether);
        vm.expectRevert();
        offRamp.execute(message, ccvs, proofs, 0);
        assertEq(target.calls(), 1);
    }

    function test_customExecutorAndGasOverrideRetryUseTheSameVerification() public {
        CustomTestExecutor executor = new CustomTestExecutor();
        bytes memory message = _message(bytes4(0), 100, 0, SENDER, address(executor));
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        _execute(message, false, 500_000);
        assertEq(offRamp.getExecutionState(keccak256(message)), 2);
        message = _message(bytes4(0), 500_000, 0, SENDER, address(executor));
        (address[] memory ccvs, bytes[] memory proofs) = _attestations(message, false);
        executor.execute(offRamp, message, ccvs, proofs);
        assertEq(target.calls(), 2);
    }

    function test_defaultPayloadGasDeliversThroughUpstreamRouter() public {
        bytes memory message = _message(bytes4(0), uint32(DeliveryGas.PAYLOAD), 0, SENDER, address(0));
        uint256 beforeGas = gasleft();
        _execute(message, false, 0);
        emit log_named_uint("real OffRamp execution gas, including proof preparation", beforeGas - gasleft());
        assertEq(offRamp.getExecutionState(keccak256(message)), 2);
        assertEq(target.calls(), 1);
    }

    function test_verifiedDeliveryCannotReenterReceiverExecution() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(receiver), 0, abi.encodeCall(ReceiverBase.execute, (new Call[](0))));
        bytes memory message =
            _messageV1(address(receiver), Payload.encodeCalls(calls), bytes4(0), 500_000, SENDER, address(0));
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        assertEq(target.calls(), 0);
    }

    function test_receiverFailureCanBeRetriedAfterTheTargetIsRepaired() public {
        bytes memory message = _message(bytes4(0), 500_000, 0, SENDER, address(0));
        target.setFail(true);
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        (address[] memory ccvs, bytes[] memory proofs) = _attestations(message, false);
        vm.expectRevert();
        offRamp.execute(message, ccvs, proofs, 0);
        target.setFail(false);
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 2);
    }

    function test_actualOffRampFinalityAcceptanceMatrix() public {
        bytes4[4] memory allowed = [bytes4(0), bytes4(uint32(32)), bytes4(0x00010000), bytes4(0x00010020)];
        bytes4[4] memory requested = [bytes4(0), bytes4(0x00010000), bytes4(uint32(32)), bytes4(uint32(33))];
        uint8[4] memory acceptedMasks = [uint8(1), uint8(13), uint8(3), uint8(15)];
        for (uint256 i; i < allowed.length; ++i) {
            _policy(false, allowed[i]);
            for (uint256 j; j < requested.length; ++j) {
                bytes memory message = _message(requested[j], 500_000, 0, SENDER, address(0));
                (bool accepted,) =
                    address(offRamp).staticcall(abi.encodeCall(IRealOffRamp.getCCVsForMessage, (message)));
                assertEq(accepted, (acceptedMasks[i] & (uint256(1) << j)) != 0);
            }
        }
    }

    function test_gatewayRevocationStillBlocksVerifiedDelivery() public {
        address router = receiver.getRouter();
        vm.prank(SENDER);
        receiver.revokeGateway(router);
        bytes memory message = _message(bytes4(0), 500_000, 0, SENDER, address(0));
        _execute(message, false, 0);
        assertEq(offRamp.getExecutionState(keccak256(message)), 3);
        assertEq(target.calls(), 0);
    }
}

/// @notice The transceiver's own `ccipReceive` and policy, which do not come from the upstream
///         helper, driven through the upstream OffRamp.
contract CcipOffRampTransceiverTest is ProviderInboundFixture, CcipFixture, CcipOffRampFixture {
    function setUp() public override {
        _deployOffRamp();
        super.setUp();
    }

    function _ccipRouter() internal view override returns (address) {
        return ccipRouter;
    }

    function _bootstrapFrom(address sender) private returns (bytes memory) {
        return _messageV1(transceiver, _bootstrap(), bytes4(0), 1_000_000, sender, address(0));
    }

    function _receiverCreated(bytes32 chainKey) private view returns (bool) {
        return ext(transceiver).predictConduit(CONDUIT_OWNER, CONDUIT_SALT, chainKey).code.length != 0;
    }

    function test_offRampDeliversABootstrapToTheTransceiver() public {
        bytes32 chainKey = _wire();
        assertTrue(IERC165(transceiver).supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
        bytes memory message = _bootstrapFrom(ORIGIN_TRANSCEIVER);
        _execute(message, false, 0);
        assertEq(_state(message), 2);
        address receiver = ext(transceiver).predictConduit(CONDUIT_OWNER, CONDUIT_SALT, chainKey);
        assertEq(ReceiverBase(payable(receiver)).sourceTransmitter(), ORIGIN_TRANSMITTER);
    }

    function test_offRampRefusesABootstrapFromANonCounterpart() public {
        bytes32 chainKey = _wire();
        bytes memory message = _bootstrapFrom(address(0xBAD));
        _execute(message, false, 0);
        assertEq(_state(message), 3);
        assertFalse(_receiverCreated(chainKey));
    }

    function test_offRampEnforcesTheTransceiversVerifierPolicy() public {
        bytes32 chainKey = _wire();
        CcipConfig.Policy memory p;
        p.requiredCCVs = new address[](2);
        p.requiredCCVs[1] = address(additionalCcv);
        vm.prank(TransceiverBase(payable(transceiver)).owner());
        CcipPolicy(transceiver).setCcipPolicy(SOURCE, abi.encode(ORIGIN_TRANSCEIVER), p);

        bytes memory message = _bootstrapFrom(ORIGIN_TRANSCEIVER);
        _execute(message, false, 0);
        assertEq(_state(message), 3);
        assertFalse(_receiverCreated(chainKey));
        _execute(message, true, 0);
        assertEq(_state(message), 2);
        assertTrue(_receiverCreated(chainKey));
    }
}
