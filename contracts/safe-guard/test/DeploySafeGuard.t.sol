// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeployCheck} from "evm-script/deploy/ProxyDeploy.sol";
import {DeploySafeGuard} from "../script/DeploySafeGuard.s.sol";
import {CrossecuteGuard} from "../src/CrossecuteGuard.sol";
import {SourceAuthorityGuard} from "../src/authority/SourceAuthorityGuard.sol";

contract DeploySafeGuardWithFixture is DeploySafeGuard {
    function _file() internal view override returns (string memory toml) {
        toml = super._file();
        string[5] memory keys =
            [".multi_send_call_only", ".sign_message_lib", ".singleton", ".singleton_l2", ".fallback_handler"];
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory key = string.concat(keys[i], ".code_hash");
            toml = vm.replace(toml, vm.toString(vm.parseTomlBytes32(toml, key)), vm.toString(keccak256(hex"00")));
        }
    }
}

contract DeploySafeGuardTest is Test {
    function test_deploysAtTheReleaseAddressAndVerifiesAllPins() public {
        DeploySafeGuard deployer = new DeploySafeGuardWithFixture();
        SourceAuthorityGuard.Pins memory expected = SourceAuthorityGuard.Pins(
            0xA83c336B20401Af773B6219BA5027174338D1836,
            0x4FfeF8222648872B3dE295Ba1e49110E61f5b5aa,
            0xFf51A5898e281Db6DfC7855790607438dF2ca44b,
            0xEdd160fEBBD92E350D4D398fb636302fccd67C7e,
            0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4
        );
        vm.etch(expected.multiSendCallOnly, hex"00");
        vm.etch(expected.signMessageLib, hex"00");
        vm.etch(expected.singleton, hex"00");
        vm.etch(expected.singletonL2, hex"00");
        vm.etch(expected.fallbackHandler, hex"00");
        address predicted = deployer.predict();
        assertEq(predicted.code.length, 0);
        assertEq(deployer.run(), predicted);
        assertEq(deployer.run(), predicted);
        assertEq(deployer.verify(), predicted);
        CrossecuteGuard guard = CrossecuteGuard(predicted);
        (uint256 delay, uint256 expiry) = guard.configurationTiming(address(this));
        assertEq(delay, 0);
        assertEq(expiry, type(uint256).max);
        assertEq(abi.encode(guard.safePins()), abi.encode(expected));
        assertLe(predicted.code.length, 24_576);

        expected.fallbackHandler = address(1);
        address wrongGuard = address(new CrossecuteGuard(expected));
        vm.etch(predicted, wrongGuard.code);
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "the guard's Safe pins"));
        deployer.verify();
    }

    function test_missingCanonicalSafeRuntimeStopsDeployment() public {
        DeploySafeGuard deployer = new DeploySafeGuard();
        address predicted = deployer.predict();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployCheck.selector, "canonical Safe 1.5.0 runtime required for .multi_send_call_only"
            )
        );
        deployer.run();
        assertEq(predicted.code.length, 0);
    }
}
