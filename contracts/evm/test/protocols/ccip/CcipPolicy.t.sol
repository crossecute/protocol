// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {GasAttribute} from "script/deploy/GasAttribute.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Test} from "forge-std/Test.sol";
import {CcipConfig} from "src/protocols/ccip/CcipConfig.sol";
import {CcipPolicy} from "src/protocols/ccip/CcipPolicy.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {CcipTransceiver} from "src/protocols/ccip/CcipTransceiver.sol";
import {CcipZkSyncTransceiver, CcipTronTransceiver} from "src/protocols/ccip/CcipDivergentTransceiver.sol";
import {TronTransceiverExtension} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {transceiverExtension, zkSyncTransceiverExtension} from "script/deploy/TransceiverDeploy.sol";
import {transceiverConfig} from "test/Harness.sol";
import {deployConduit} from "test/DeployProxy.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract CcipPolicyTest is Test {
    uint64 private constant SOURCE = 15_971_525_489_660_198_786;
    address private constant SENDER = address(0xABCD);
    address[4] private targets;
    address[4] private authorities;

    function setUp() public {
        MockCcipRouter router = new MockCcipRouter();
        router.configureV3Pricing(1, false);
        CcipReceiver implementation = new CcipReceiver(address(router), address(0), address(0));
        targets[0] = deployConduit(
            address(implementation),
            abi.encodeCall(IReceiverInit.initialize, (SENDER, bytes32(uint256(SOURCE)), new Call[](0)))
        );
        authorities[0] = SENDER;
        TransceiverConfig memory c = transceiverConfig(address(implementation));
        c.governorHome = Erc7930.encodeEvmChain(8453);
        targets[1] = deployConduit(
            address(new CcipTransceiver(address(router), transceiverExtension())),
            abi.encodeCall(CcipTransceiver.initialize, (c, SOURCE))
        );
        targets[2] = deployConduit(
            address(new CcipZkSyncTransceiver(address(router), zkSyncTransceiverExtension())),
            abi.encodeCall(CcipZkSyncTransceiver.initialize, (c, SOURCE, bytes32(uint256(1))))
        );
        targets[3] = deployConduit(
            address(new CcipTronTransceiver(address(router), address(new TronTransceiverExtension()))),
            abi.encodeCall(CcipTronTransceiver.initialize, (c, SOURCE, bytes32(uint256(1))))
        );
        for (uint256 i = 1; i < targets.length; ++i) {
            authorities[i] = CcipTransceiver(payable(targets[i])).owner();
        }
    }

    function _policy() private pure returns (CcipConfig.Policy memory p) {
        p.requiredCCVs = new address[](2);
        p.requiredCCVs[1] = address(0xCC);
        p.optionalCCVs = new address[](2);
        p.optionalCCVs[0] = address(0xDD);
        p.optionalCCVs[1] = address(0xEE);
        p.optionalThreshold = 1;
        p.allowedFinalityConfig = bytes4(0x00010020);
    }

    function _set(uint256 index, uint64 source, address sender, CcipConfig.Policy memory p) private {
        vm.prank(authorities[index]);
        CcipPolicy(targets[index]).setCcipPolicy(source, abi.encode(sender), p);
    }

    function _assertPolicy(uint256 index, uint64 source, address sender, CcipConfig.Policy memory expected)
        private
        view
    {
        (address[] memory required, address[] memory optional, uint8 threshold, bytes4 finality) =
            CcipPolicy(targets[index]).getCCVsAndFinalityConfig(source, abi.encode(sender));
        assertEq(
            abi.encode(required, optional, threshold, finality),
            abi.encode(
                expected.requiredCCVs, expected.optionalCCVs, expected.optionalThreshold, expected.allowedFinalityConfig
            )
        );
    }

    function test_sharedProxyInterfacesDefaultsUpdatesIsolationAndReset() public {
        CcipConfig.Policy memory defaults;
        for (uint256 i; i < targets.length; ++i) {
            assertTrue(IERC165(targets[i]).supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
            _assertPolicy(i, SOURCE, SENDER, defaults);
            _set(i, SOURCE, SENDER, _policy());
            _assertPolicy(i, SOURCE, SENDER, _policy());
            _assertPolicy(i, SOURCE + 1, SENDER, defaults);
            _assertPolicy(i, SOURCE, address(0xBAD), defaults);
            _set(i, SOURCE, SENDER, defaults);
            _assertPolicy(i, SOURCE, SENDER, defaults);
        }
    }

    function test_allTransceiverVariantsQuoteV3OnlyAfterLaneEnablement() public {
        bytes memory recipient = Erc7930.encodeEvm(8453, address(0xC0DE));
        ExtraArgsCodec.GenericExtraArgsV3 memory options;
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = GasAttribute.ccip(options);
        for (uint256 i = 1; i < targets.length; ++i) {
            CcipTransceiver t = CcipTransceiver(payable(targets[i]));
            assertEq(t.quoteMessage(recipient, "payload", new bytes[](0)), 68);
            vm.expectRevert();
            t.quoteMessage(recipient, "payload", attrs);
            vm.prank(authorities[i]);
            t.setCcipV3Lane(SOURCE, true, keccak256("local test lane"));
            assertEq(t.quoteMessage(recipient, "payload", attrs), 19);
            vm.prank(authorities[i]);
            t.setCcipV3Lane(SOURCE, false, bytes32(0));
            vm.expectRevert();
            t.quoteMessage(recipient, "payload", attrs);
        }
    }

    function test_allPolicySettersRejectUnauthorizedCallers() public {
        CcipConfig.Policy memory p = _policy();
        bytes memory sender = abi.encode(SENDER);
        for (uint256 i; i < targets.length; ++i) {
            vm.expectRevert();
            CcipPolicy(targets[i]).setCcipPolicy(SOURCE, sender, p);
        }
    }

    function test_receiverRefusesPolicyKeysItNeverDeliversFrom() public {
        CcipConfig.Policy memory p = _policy();
        vm.startPrank(SENDER);
        vm.expectRevert(CcipPolicy.InvalidCcipPolicy.selector);
        CcipPolicy(targets[0]).setCcipPolicy(SOURCE + 1, abi.encode(SENDER), p);
        vm.expectRevert(CcipPolicy.InvalidCcipPolicy.selector);
        CcipPolicy(targets[0]).setCcipPolicy(SOURCE, abi.encode(address(0xBAD)), p);
        vm.stopPrank();
        for (uint256 i = 1; i < targets.length; ++i) {
            _set(i, SOURCE + 1, address(0xBAD), p);
            _assertPolicy(i, SOURCE + 1, address(0xBAD), p);
        }
    }

    function test_receiverSelfCallCanConfigurePolicy() public {
        CcipConfig.Policy memory p = _policy();
        Call[] memory calls = new Call[](1);
        calls[0] = Call(targets[0], 0, abi.encodeCall(CcipPolicy.setCcipPolicy, (SOURCE, abi.encode(SENDER), p)));
        vm.prank(SENDER);
        ReceiverBase(payable(targets[0])).execute(calls);
        _assertPolicy(0, SOURCE, SENDER, p);
    }

    function test_configurationUsesNamespaceWithoutChangingSequentialOrProxySlots() public {
        for (uint256 i; i < targets.length; ++i) {
            bytes32[40] memory beforeSlots;
            for (uint256 j; j < beforeSlots.length; ++j) {
                beforeSlots[j] = vm.load(targets[i], bytes32(j));
            }
            bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
            bytes32 implementation = vm.load(targets[i], implSlot);
            _set(i, SOURCE, SENDER, _policy());
            for (uint256 j; j < beforeSlots.length; ++j) {
                assertEq(vm.load(targets[i], bytes32(j)), beforeSlots[j]);
            }
            assertEq(vm.load(targets[i], implSlot), implementation);
            bytes32 root = keccak256(abi.encode(uint256(keccak256("crossecute.storage.CcipConfig")) - 1))
                & ~bytes32(uint256(0xff));
            bytes32 key = keccak256(abi.encode(SOURCE, abi.encode(SENDER)));
            assertEq(uint256(vm.load(targets[i], keccak256(abi.encode(key, root)))), 2);
        }
    }

    function test_invalidPoliciesAreRejectedAcrossAllVariants() public {
        for (uint256 i; i < targets.length; ++i) {
            CcipConfig.Policy memory p = _policy();
            p.optionalThreshold = 3;
            _reject(i, SOURCE, abi.encode(SENDER), p);
            p.optionalThreshold = 0;
            _reject(i, SOURCE, abi.encode(SENDER), p);
            p = _policy();
            p.optionalCCVs[0] = address(0);
            _reject(i, SOURCE, abi.encode(SENDER), p);
            p = _policy();
            p.optionalCCVs[0] = p.requiredCCVs[1];
            _reject(i, SOURCE, abi.encode(SENDER), p);
            p = _policy();
            p.allowedFinalityConfig = bytes4(0x00020000);
            _reject(i, SOURCE, abi.encode(SENDER), p);
            p = _policy();
            _reject(i, 0, abi.encode(SENDER), p);
            _reject(i, SOURCE, abi.encode(address(0)), p);
            _reject(i, SOURCE, abi.encodePacked(SENDER), p);
            _reject(i, SOURCE, abi.encode(type(uint256).max), p);
        }
    }

    function test_verifierBoundsAndEmptyOptionalThreshold() public {
        for (uint256 i; i < targets.length; ++i) {
            CcipConfig.Policy memory p;
            p.optionalThreshold = 1;
            _reject(i, SOURCE, abi.encode(SENDER), p);
            p.optionalThreshold = 0;
            p.requiredCCVs = new address[](256);
            _reject(i, SOURCE, abi.encode(SENDER), p);
            p.requiredCCVs = new address[](2);
            p.requiredCCVs[0] = address(0xCC);
            p.requiredCCVs[1] = address(0xCC);
            _reject(i, SOURCE, abi.encode(SENDER), p);
        }
    }

    function _reject(uint256 index, uint64 source, bytes memory sender, CcipConfig.Policy memory p) private {
        vm.prank(authorities[index]);
        vm.expectRevert();
        CcipPolicy(targets[index]).setCcipPolicy(source, sender, p);
    }
}
