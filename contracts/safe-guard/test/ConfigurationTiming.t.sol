// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {PolicyEngine} from "policy-engine/core/PolicyEngine.sol";
import {SafePolicyGuardBase} from "policy-engine/SafePolicyGuardBase.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {CrossecuteGuard} from "../src/CrossecuteGuard.sol";
import {GuardTestBase} from "./GuardTestBase.sol";

contract ConfigurationTimingTest is GuardTestBase {
    uint256 private constant START = 100 days;
    uint256 private constant FOREVER = type(uint256).max;

    function setUp() public override {
        super.setUp();
        vm.warp(START);
    }

    function test_defaultAndSafeOverridesAreIndependent() public {
        Safe first = _installWithTiming(2 days, 1 days);
        Safe second = _installWithTiming(3 days, 1 hours);
        _assertTiming(safe, 0, FOREVER);
        _assertTiming(first, 2 days, 1 days);
        _assertTiming(second, 3 days, 1 hours);

        SafePolicyGuardBase.Configuration[] memory configs = _configs(address(0x1234));
        bytes32 root = _requestPolicy(safe, configs);
        _requestPolicy(first, configs);
        _requestPolicy(second, configs);
        assertEq(guard.rootConfigured(address(safe), root), START);
        assertEq(guard.rootConfigured(address(first), root), START + 2 days);
        assertEq(guard.rootConfigured(address(second), root), START + 3 days);

        _applyPolicy(safe, configs);
        assertEq(guard.rootExpiry(address(safe), root), 0);
        assertEq(guard.rootExpiry(address(first), root), 1 days);
        assertEq(guard.rootExpiry(address(second), root), 1 hours);

        bytes32 timingRoot = guard.timingConfigurationRoot(0, FOREVER);
        _request(first, timingRoot);
        vm.warp(START + 2 days);
        _expectSafeRevert(
            second,
            abi.encodeCall(CrossecuteGuard.applyConfigurationTiming, (0, FOREVER)),
            abi.encodeWithSelector(SafePolicyGuardBase.RootNotConfigured.selector, timingRoot)
        );
        _applyTiming(first, 0, FOREVER);
        _assertTiming(first, 0, FOREVER);
        _assertTiming(second, 3 days, 1 hours);
    }

    function test_finiteWindowIncludesMaturityAndExcludesExpiry() public {
        Safe guarded = _installWithTiming(2 days, 1 hours);
        SafePolicyGuardBase.Configuration[] memory atStart = _configs(address(0x1234));
        SafePolicyGuardBase.Configuration[] memory beforeEnd = _configs(address(0x1235));
        SafePolicyGuardBase.Configuration[] memory atEnd = _configs(address(0x1236));
        _requestPolicy(guarded, atStart);
        _requestPolicy(guarded, beforeEnd);
        bytes32 root = _requestPolicy(guarded, atEnd);

        vm.warp(START + 2 days - 1);
        _expectPolicyRevert(guarded, atStart, SafePolicyGuardBase.RootConfigurationPending.selector);
        vm.warp(START + 2 days);
        _applyPolicy(guarded, atStart);
        (, address configured) = guard.getPolicy(address(guarded), address(0x1234), "", Operation.CALL);
        assertEq(configured, address(allowPolicy));
        vm.warp(START + 2 days + 1 hours - 1);
        _applyPolicy(guarded, beforeEnd);
        vm.warp(START + 2 days + 1 hours);
        _expectPolicyRevert(guarded, atEnd, SafePolicyGuardBase.RootConfigurationExpired.selector);
        _request(guarded, root);
        assertEq(guard.rootConfigured(address(guarded), root), START + 4 days + 1 hours);
    }

    function test_loweringDelayAndExtendingExpiryPreservesPendingRequests() public {
        Safe guarded = _installWithTiming(2 days, 1 days);
        _request(guarded, guard.timingConfigurationRoot(0, FOREVER));
        bytes memory applyTiming = abi.encodeCall(CrossecuteGuard.applyConfigurationTiming, (0, FOREVER));
        _expectSafeRevert(
            guarded,
            abi.encodeCall(CrossecuteGuard.configureTimingImmediately, (0, FOREVER)),
            abi.encodeWithSelector(PolicyEngine.GuardTargetDenied.selector)
        );
        vm.warp(START + 2 days - 1);
        _expectSafeRevert(
            guarded, applyTiming, abi.encodeWithSelector(SafePolicyGuardBase.RootConfigurationPending.selector)
        );

        SafePolicyGuardBase.Configuration[] memory original = _configs(address(0x1234));
        SafePolicyGuardBase.Configuration[] memory fresh = _configs(address(0x1235));
        bytes32 oldRoot = _requestPolicy(guarded, original);
        vm.warp(START + 2 days);
        _applyTiming(guarded, 0, FOREVER);
        _expectPolicyRevert(guarded, original, SafePolicyGuardBase.RootConfigurationPending.selector);
        assertEq(guard.rootConfigured(address(guarded), oldRoot), START + 4 days - 1);
        assertEq(guard.rootExpiry(address(guarded), oldRoot), 1 days);

        bytes32 freshRoot = _requestPolicy(guarded, fresh);
        assertEq(guard.rootConfigured(address(guarded), freshRoot), START + 2 days);
        assertEq(guard.rootExpiry(address(guarded), freshRoot), FOREVER);
        vm.warp(START + 5 days - 1);
        _expectPolicyRevert(guarded, original, SafePolicyGuardBase.RootConfigurationExpired.selector);
        _applyPolicy(guarded, fresh);
    }

    function test_expiryChangeDoesNotReviveAnExpiredRootOrShortenAnUnlimitedRoot() public {
        _request(safe, guard.timingConfigurationRoot(0, 1 hours));
        SafePolicyGuardBase.Configuration[] memory unlimited = _configs(address(0x1234));
        _requestPolicy(safe, unlimited);
        _applyTiming(safe, 0, 1 hours);

        SafePolicyGuardBase.Configuration[] memory finite = _configs(address(0x1235));
        _requestPolicy(safe, finite);
        vm.warp(START + 1 hours);
        _expectPolicyRevert(safe, finite, SafePolicyGuardBase.RootConfigurationExpired.selector);
        _applyPolicy(safe, unlimited);
        _request(safe, guard.timingConfigurationRoot(0, FOREVER));
        _applyTiming(safe, 0, FOREVER);
        _expectPolicyRevert(safe, finite, SafePolicyGuardBase.RootConfigurationExpired.selector);
    }

    function test_installationAsModuleGuardBlocksImmediateTimingChanges() public {
        Safe guarded = _newEoaSafe();
        _guardCall(guarded, abi.encodeCall(CrossecuteGuard.configureTimingImmediately, (2 days, 1 days)));
        assertTrue(
            _exec(
                guarded,
                _signers(),
                address(guarded),
                0,
                abi.encodeCall(guarded.setModuleGuard, (address(guard))),
                Enum.Operation.Call
            )
        );
        _expectSafeRevert(
            guarded,
            abi.encodeCall(CrossecuteGuard.configureTimingImmediately, (0, FOREVER)),
            abi.encodeWithSelector(SafePolicyGuardBase.GuardAlreadyEnabled.selector)
        );
        _assertTiming(guarded, 2 days, 1 days);
    }

    function test_zeroExpiryRejectedBeforeAndAfterInstallation() public {
        _expectSafeRevert(
            _newEoaSafe(),
            abi.encodeCall(CrossecuteGuard.configureTimingImmediately, (0, 0)),
            abi.encodeWithSelector(SafePolicyGuardBase.ZeroExpiryNotAllowed.selector)
        );
        bytes32 root = guard.timingConfigurationRoot(0, 0);
        _request(safe, root);
        _expectSafeRevert(
            safe,
            abi.encodeCall(CrossecuteGuard.applyConfigurationTiming, (0, 0)),
            abi.encodeWithSelector(SafePolicyGuardBase.ZeroExpiryNotAllowed.selector)
        );
        assertEq(guard.rootExpiry(address(safe), root), FOREVER);
        _assertTiming(safe, 0, FOREVER);
    }

    function test_delayAboveMaximumRejectedBeforeAndAfterInstallation() public {
        uint256 delay = guard.MAX_CONFIGURATION_DELAY() + 1;
        bytes memory reason = abi.encodeWithSelector(CrossecuteGuard.ConfigurationDelayTooLong.selector);
        _expectSafeRevert(
            _newEoaSafe(), abi.encodeCall(CrossecuteGuard.configureTimingImmediately, (delay, FOREVER)), reason
        );

        bytes32 root = guard.timingConfigurationRoot(delay, FOREVER);
        _request(safe, root);
        _expectSafeRevert(safe, abi.encodeCall(CrossecuteGuard.applyConfigurationTiming, (delay, FOREVER)), reason);
        assertEq(guard.rootExpiry(address(safe), root), FOREVER);
        _assertTiming(safe, 0, FOREVER);
    }

    function test_maximumDelayCanMatureAndApplyARequest() public {
        uint256 delay = guard.MAX_CONFIGURATION_DELAY();
        Safe guarded = _installWithTiming(delay, FOREVER);
        SafePolicyGuardBase.Configuration[] memory configs = _configs(address(0x1234));
        bytes32 root = _requestPolicy(guarded, configs);
        assertEq(guard.rootConfigured(address(guarded), root), START + delay);
        vm.warp(START + delay);
        _applyPolicy(guarded, configs);
    }

    function _installWithTiming(uint256 delay, uint256 expiry) private returns (Safe guarded) {
        guarded = _newEoaSafe();
        bytes memory installation = abi.encodePacked(
            _multiSendEntry(
                address(guard), abi.encodeCall(CrossecuteGuard.configureTimingImmediately, (delay, expiry))
            ),
            _multiSendEntry(address(guarded), abi.encodeCall(guarded.setGuard, (address(guard))))
        );
        assertTrue(
            _exec(
                guarded,
                _signers(),
                address(multiSend),
                0,
                abi.encodeCall(multiSend.multiSend, (installation)),
                Enum.Operation.DelegateCall
            )
        );
    }

    function _configs(address target) private view returns (SafePolicyGuardBase.Configuration[] memory configs) {
        configs = new SafePolicyGuardBase.Configuration[](1);
        configs[0] = _config(target, bytes4(0), Operation.CALL, address(allowPolicy));
    }

    function _assertTiming(Safe guarded, uint256 delay, uint256 expiry) private view {
        (uint256 effectiveDelay, uint256 effectiveExpiry) = guard.configurationTiming(address(guarded));
        assertEq(effectiveDelay, delay);
        assertEq(effectiveExpiry, expiry);
    }

    function _requestPolicy(Safe guarded, SafePolicyGuardBase.Configuration[] memory configs)
        private
        returns (bytes32 root)
    {
        root = keccak256(abi.encode(configs));
        _request(guarded, root);
    }

    function _request(Safe guarded, bytes32 root) private {
        _guardCall(guarded, abi.encodeCall(SafePolicyGuardBase.requestConfiguration, (root)));
    }

    function _applyPolicy(Safe guarded, SafePolicyGuardBase.Configuration[] memory configs) private {
        _guardCall(guarded, abi.encodeCall(SafePolicyGuardBase.applyConfiguration, (configs)));
    }

    function _applyTiming(Safe guarded, uint256 delay, uint256 expiry) private {
        _guardCall(guarded, abi.encodeCall(CrossecuteGuard.applyConfigurationTiming, (delay, expiry)));
    }

    function _guardCall(Safe guarded, bytes memory data) private {
        assertTrue(_exec(guarded, _signers(), address(guard), 0, data, Enum.Operation.Call));
    }

    function _expectPolicyRevert(Safe guarded, SafePolicyGuardBase.Configuration[] memory configs, bytes4 reason)
        private
    {
        _expectSafeRevert(
            guarded, abi.encodeCall(SafePolicyGuardBase.applyConfiguration, (configs)), abi.encodeWithSelector(reason)
        );
    }

    function _expectSafeRevert(Safe guarded, bytes memory data, bytes memory reason) private {
        bytes memory sigs = _signFor(guarded, _signers(), address(guard), 0, data, Enum.Operation.Call);
        vm.expectRevert(reason);
        _execWith(guarded, address(guard), 0, data, Enum.Operation.Call, sigs);
    }
}
