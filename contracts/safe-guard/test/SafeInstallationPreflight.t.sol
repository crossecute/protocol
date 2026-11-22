// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {SafePolicyGuardBase} from "policy-engine/SafePolicyGuardBase.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {SafeL2} from "safe-smart-account/SafeL2.sol";
import {ModuleManager} from "safe-smart-account/base/ModuleManager.sol";
import {CompatibilityFallbackHandler} from "safe-smart-account/handler/CompatibilityFallbackHandler.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {MultiSendCallOnly} from "safe-smart-account/libraries/MultiSendCallOnly.sol";
import {SignMessageLib} from "safe-smart-account/libraries/SignMessageLib.sol";
import {DeployCheck} from "evm-script/deploy/ProxyDeploy.sol";
import {DeploySafeGuard} from "../script/DeploySafeGuard.s.sol";
import {CrossecuteGuard} from "../src/CrossecuteGuard.sol";
import {GuardDiscovery} from "../src/GuardDiscovery.sol";
import {SafeTx} from "../src/ICrossecuteGuard.sol";
import {SafeFixture} from "./SafeFixture.sol";

contract PreflightWithFixture is DeploySafeGuard {
    bool internal _transientStorageSupported = true;

    function mockTransientStorageSupport(bool supported) external {
        _transientStorageSupported = supported;
    }

    function _supportsTransientStorage() internal view override returns (bool) {
        return _transientStorageSupported;
    }

    function _file() internal view override returns (string memory toml) {
        toml = super._file();
        string[5] memory keys =
            [".multi_send_call_only", ".sign_message_lib", ".singleton", ".singleton_l2", ".fallback_handler"];
        for (uint256 i = 0; i < keys.length; ++i) {
            address pin = vm.parseTomlAddress(toml, string.concat(keys[i], ".address"));
            string memory hashKey = string.concat(keys[i], ".code_hash");
            toml = vm.replace(toml, vm.toString(vm.parseTomlBytes32(toml, hashKey)), vm.toString(pin.codehash));
        }
    }
}

contract SafeInstallationPreflightTest is SafeFixture {
    // Safe 1.5.0's storage slots.
    bytes32 private constant MODULE_GUARD_SLOT = 0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;
    bytes32 private constant FALLBACK_HANDLER_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    PreflightWithFixture private script;
    Safe private safe;
    Signer[] private signers;
    address private releaseGuard;

    function setUp() public override {
        super.setUp();
        // forge-lint: disable-next-line(unsafe-cheatcode) use the release pins for the local Safe fixtures
        string memory toml = vm.readFile(string.concat(vm.projectRoot(), "/../evm/deploy/safe-guard.toml"));
        singleton = Safe(payable(_etchPin(toml, ".singleton", address(singleton).code)));
        _etchPin(toml, ".singleton_l2", address(new SafeL2()).code);
        handler = CompatibilityFallbackHandler(_etchPin(toml, ".fallback_handler", address(handler).code));
        multiSend = MultiSendCallOnly(_etchPin(toml, ".multi_send_call_only", address(multiSend).code));
        signMessageLib = SignMessageLib(_etchPin(toml, ".sign_message_lib", address(signMessageLib).code));
        script = new PreflightWithFixture();
        releaseGuard = script.run();

        signers.push(_eoa(123));
        address[] memory owners = new address[](1);
        owners[0] = signers[0].owner;
        safe = _newSafe(owners, 1);
    }

    function test_preflightsAndBuildsTheRealSafeInstallationTransaction() public {
        DeploySafeGuard.Installation memory installation =
            script.prepareInstallation(address(safe), _defaultConfig(), 42, 99);
        assertEq(installation.chainId, block.chainid);
        assertEq(installation.safe, address(safe));
        assertEq(installation.transactionGuard, address(0));
        assertEq(installation.moduleGuard, address(0));

        SafeTx memory tx_ = installation.safeTx;
        assertEq(tx_.to, address(multiSend));
        assertEq(tx_.operation, uint8(Enum.Operation.DelegateCall));
        assertEq(tx_.nonce, safe.nonce());
        assertEq(tx_.value, 0);
        assertEq(tx_.safeTxGas, 0);
        assertEq(tx_.baseGas, 0);
        assertEq(tx_.gasPrice, 0);
        assertEq(tx_.gasToken, address(0));
        assertEq(tx_.refundReceiver, address(0));

        assertTrue(_exec(safe, signers, tx_.to, tx_.value, tx_.data, Enum.Operation(tx_.operation)));
        assertEq(GuardDiscovery.transactionGuard(address(safe)), releaseGuard);
        assertEq(vm.load(address(safe), MODULE_GUARD_SLOT), bytes32(uint256(uint160(releaseGuard))));
        (uint256 delay, uint256 expiry) = CrossecuteGuard(releaseGuard).configurationTiming(address(safe));
        assertEq(delay, 42);
        assertEq(expiry, 99);
        assertTrue(_exec(safe, signers, address(0xbeef), 0, "", Enum.Operation.Call));
    }

    function test_preflightRefusesUnconfirmedEIP1153() public {
        script.mockTransientStorageSupport(false);
        _expectCheck("target RPC must confirm EIP-1153 TSTORE/TLOAD");
    }

    function test_preflightRefusesUnrecognizedSingleton() public {
        vm.store(address(safe), bytes32(0), bytes32(uint256(uint160(address(new Safe())))));
        _expectCheck("Safe proxy must use a pinned Safe 1.5.0 singleton");
    }

    function test_preflightRefusesUnrecognizedFallbackHandler() public {
        vm.store(address(safe), FALLBACK_HANDLER_SLOT, bytes32(0));
        _expectCheck("Safe must use the pinned fallback handler");
    }

    function test_preflightRefusesEnabledModules() public {
        assertTrue(
            _exec(
                safe,
                signers,
                address(safe),
                0,
                abi.encodeCall(ModuleManager.enableModule, (address(0xbeef))),
                Enum.Operation.Call
            )
        );
        _expectCheck("Safe must have no enabled modules");
    }

    function test_preflightRefusesPartialInstallation() public {
        vm.store(address(safe), MODULE_GUARD_SLOT, bytes32(uint256(uint160(releaseGuard))));
        _expectCheck("CrossecuteGuard must be absent from both Safe guard slots");
    }

    function test_preflightIdentifiesAnExistingGuard() public {
        bytes32 guardSlot = bytes32(GuardDiscovery.GUARD_STORAGE_SLOT);
        address oldGuard = address(guard);
        vm.store(address(safe), guardSlot, bytes32(uint256(uint160(oldGuard))));
        DeploySafeGuard.Installation memory installation =
            script.prepareInstallation(address(safe), _defaultConfig(), 0, type(uint256).max);
        assertEq(installation.transactionGuard, oldGuard);
        assertEq(installation.moduleGuard, address(0));
    }

    function _expectCheck(string memory reason) private {
        SafePolicyGuardBase.Configuration[] memory configs = _defaultConfig();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, reason));
        script.prepareInstallation(address(safe), configs, 0, type(uint256).max);
    }

    function _etchPin(string memory toml, string memory pinKey, bytes memory runtime) private returns (address pin) {
        pin = vm.parseTomlAddress(toml, string.concat(pinKey, ".address"));
        vm.etch(pin, runtime);
    }
}
