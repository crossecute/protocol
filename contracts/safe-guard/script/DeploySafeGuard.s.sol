// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {ARACHNID, arachnidAddress, arachnidDeploy, check} from "evm-script/deploy/ProxyDeploy.sol";
import {SafePolicyGuardBase} from "policy-engine/SafePolicyGuardBase.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {GuardManager} from "safe-smart-account/base/GuardManager.sol";
import {ModuleManager} from "safe-smart-account/base/ModuleManager.sol";
import {MultiSendCallOnly} from "safe-smart-account/libraries/MultiSendCallOnly.sol";
import {CrossecuteGuard} from "../src/CrossecuteGuard.sol";
import {GuardDiscovery} from "../src/GuardDiscovery.sol";
import {SafeTx} from "../src/ICrossecuteGuard.sol";
import {SourceAuthorityGuard} from "../src/authority/SourceAuthorityGuard.sol";

contract DeploySafeGuard is Script {
    bytes32 private constant _FACTORY_CODE_HASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    uint256 private constant _MODULE_GUARD_SLOT = uint256(keccak256("module_manager.module_guard.address"));
    uint256 private constant _FALLBACK_HANDLER_SLOT = uint256(keccak256("fallback_manager.handler.address"));

    struct Release {
        address expected;
        SourceAuthorityGuard.Pins pins;
    }

    struct Installation {
        uint256 chainId;
        address safe;
        address transactionGuard;
        address moduleGuard;
        SafeTx safeTx;
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
        return _verifiedRelease().expected;
    }

    /// @notice Preflight a signed home Safe and return the unsigned installation transaction.
    function prepareInstallation(
        address safeAddress,
        SafePolicyGuardBase.Configuration[] calldata configurations,
        uint256 delay,
        uint256 expiry
    ) external returns (Installation memory installation) {
        check(_supportsTransientStorage(), "target RPC must confirm EIP-1153 TSTORE/TLOAD");
        Release memory release = _verifiedRelease();
        Safe safe = Safe(payable(safeAddress));
        installation.chainId = block.chainid;
        installation.safe = safeAddress;
        _checkSafe(safe, release.pins);
        installation.transactionGuard = _guardSlot(safeAddress, GuardDiscovery.GUARD_STORAGE_SLOT);
        installation.moduleGuard = _guardSlot(safeAddress, _MODULE_GUARD_SLOT);
        check(
            installation.transactionGuard != release.expected && installation.moduleGuard != release.expected,
            "CrossecuteGuard must be absent from both Safe guard slots"
        );
        check(
            delay <= CrossecuteGuard(release.expected).MAX_CONFIGURATION_DELAY(),
            "configuration delay exceeds the limit"
        );
        check(expiry != 0, "configuration expiry must be nonzero");

        bytes memory calls = bytes.concat(
            _call(release.expected, abi.encodeCall(SafePolicyGuardBase.configureImmediately, (configurations))),
            _call(release.expected, abi.encodeCall(CrossecuteGuard.configureTimingImmediately, (delay, expiry))),
            _call(safeAddress, abi.encodeCall(GuardManager.setGuard, (release.expected))),
            _call(safeAddress, abi.encodeCall(ModuleManager.setModuleGuard, (release.expected)))
        );
        installation.safeTx = SafeTx({
            to: release.pins.multiSendCallOnly,
            value: 0,
            data: abi.encodeCall(MultiSendCallOnly.multiSend, (calls)),
            operation: 1,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: address(0),
            nonce: safe.nonce()
        });
    }

    function _supportsTransientStorage() internal virtual returns (bool) {
        // Execute TSTORE(0, 42), then return TLOAD(0) in a word. The RPC executes the creation call on
        // the target VM, independently of the hardfork configured for this Forge script.
        try vm.rpc("eth_call", '[{"data":"0x602a60005d60005c60005260206000f3"},"latest"]') returns (
            bytes memory result
        ) {
            return keccak256(result) == keccak256(abi.encode(uint256(42)));
        } catch {
            return false;
        }
    }

    function _verifiedRelease() private view returns (Release memory release) {
        string memory toml = _file();
        release = _read(toml);
        _checkAddress(release, _initCode(release.pins));
        _verifyGuard(release);
        _checkSafeCode(toml, release.pins);
    }

    function _checkSafe(Safe safe, SourceAuthorityGuard.Pins memory pins) private view {
        address account = address(safe);
        check(account.code.length != 0, "Safe proxy has no code");
        // SafeProxy keeps its singleton in slot zero.
        uint256 singleton = GuardDiscovery.storageWord(account, 0);
        check(
            singleton == uint256(uint160(pins.singleton)) || singleton == uint256(uint160(pins.singletonL2)),
            "Safe proxy must use a pinned Safe 1.5.0 singleton"
        );
        check(
            keccak256(bytes(safe.VERSION())) == keccak256("1.5.0") && safe.getThreshold() != 0,
            "initialized Safe 1.5.0 required"
        );
        check(
            GuardDiscovery.storageWord(account, _FALLBACK_HANDLER_SLOT) == uint256(uint160(pins.fallbackHandler)),
            "Safe must use the pinned fallback handler"
        );
        (address[] memory modules,) = safe.getModulesPaginated(address(1), 1);
        check(modules.length == 0, "Safe must have no enabled modules");
    }

    function _guardSlot(address safe, uint256 slot) private view returns (address guard) {
        uint256 word = GuardDiscovery.storageWord(safe, slot);
        check(word >> 160 == 0, "malformed Safe guard slot");
        guard = address(uint160(word));
        check(guard == address(0) || guard.code.length != 0, "existing Safe guard has no code");
    }

    function _call(address target, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), target, uint256(0), data.length, data);
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
