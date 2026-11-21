// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {ARACHNID, arachnidAddress, arachnidDeploy, check} from "evm-script/deploy/ProxyDeploy.sol";
import {CrossecuteGuard} from "../src/CrossecuteGuard.sol";
import {SourceAuthorityGuard} from "../src/authority/SourceAuthorityGuard.sol";

contract DeploySafeGuard is Script {
    bytes32 private constant _FACTORY_CODE_HASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    struct Release {
        address expected;
        SourceAuthorityGuard.Pins pins;
    }

    /// @notice Chain-independent CREATE2 prediction using the release build and constructor inputs.
    function predict() external view returns (address) {
        return arachnidAddress(_initCode(_read(_file()).pins));
    }

    function run() external returns (address guard) {
        string memory toml = _file();
        Release memory release = _read(toml);
        bytes memory initCode = _initCode(release.pins);
        _checkAddress(release, initCode);
        check(ARACHNID.codehash == _FACTORY_CODE_HASH, "Arachnid's factory has the canonical code");
        _checkSafeCode(toml, release.pins);

        vm.startBroadcast();
        guard = arachnidDeploy(initCode);
        vm.stopBroadcast();

        _verifyGuard(release);
    }

    /// @notice Verify the deployed guard and the Safe runtime hashes on the same chain.
    function verify() external view returns (address) {
        string memory toml = _file();
        Release memory release = _read(toml);
        _checkAddress(release, _initCode(release.pins));
        _verifyGuard(release);
        _checkSafeCode(toml, release.pins);
        return release.expected;
    }

    function _file() internal view virtual returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode) the release record is the deployment input
        return vm.readFile(string.concat(vm.projectRoot(), "/../evm/deploy/safe-guard.toml"));
    }

    function _read(string memory toml) private pure returns (Release memory) {
        return Release({
            expected: vm.parseTomlAddress(toml, ".address"),
            pins: SourceAuthorityGuard.Pins({
                multiSendCallOnly: vm.parseTomlAddress(toml, ".multi_send_call_only.address"),
                signMessageLib: vm.parseTomlAddress(toml, ".sign_message_lib.address"),
                singleton: vm.parseTomlAddress(toml, ".singleton.address"),
                singletonL2: vm.parseTomlAddress(toml, ".singleton_l2.address"),
                fallbackHandler: vm.parseTomlAddress(toml, ".fallback_handler.address")
            })
        });
    }

    function _initCode(SourceAuthorityGuard.Pins memory pins) private pure returns (bytes memory) {
        return abi.encodePacked(type(CrossecuteGuard).creationCode, abi.encode(pins));
    }

    function _checkAddress(Release memory release, bytes memory initCode) private pure {
        check(arachnidAddress(initCode) == release.expected, "this build matches the recorded guard address");
    }

    function _checkSafeCode(string memory toml, SourceAuthorityGuard.Pins memory pins) private view {
        _checkCodeHash(toml, ".multi_send_call_only", pins.multiSendCallOnly);
        _checkCodeHash(toml, ".sign_message_lib", pins.signMessageLib);
        _checkCodeHash(toml, ".singleton", pins.singleton);
        _checkCodeHash(toml, ".singleton_l2", pins.singletonL2);
        _checkCodeHash(toml, ".fallback_handler", pins.fallbackHandler);
    }

    function _checkCodeHash(string memory toml, string memory key, address pin) private view {
        check(
            pin.codehash == vm.parseTomlBytes32(toml, string.concat(key, ".code_hash")),
            string.concat("canonical Safe 1.5.0 runtime required for ", key)
        );
    }

    function _verifyGuard(Release memory release) private view {
        CrossecuteGuard guard = CrossecuteGuard(release.expected);
        check(address(guard).code.length != 0, "the release guard has code");
        check(keccak256(abi.encode(guard.safePins())) == keccak256(abi.encode(release.pins)), "the guard's Safe pins");
    }
}
