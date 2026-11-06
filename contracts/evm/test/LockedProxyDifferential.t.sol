// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {LockedProxy, ILockedProxy} from "src/conduit/LockedProxy.sol";
import {LockedProxyReference} from "test/reference/LockedProxyReference.sol";
import {LogicA, LogicB, Echo, Failing} from "test/LockedProxy.t.sol";

contract EmptyRevert {
    fallback() external payable {
        assembly {
            revert(0, 0)
        }
    }
}

/// @dev The admin of both proxies, so the same call can be made as the admin to each.
contract DifferentialFactory {
    function makeProxy() external returns (address) {
        return address(new LockedProxy());
    }

    function makeReference() external returns (address) {
        return address(new LockedProxyReference());
    }

    function send(address proxy, bytes calldata data) external payable returns (bool ok, bytes memory ret) {
        (ok, ret) = proxy.call{value: msg.value}(data);
    }
}

/// @notice `LockedProxy` and `LockedProxyReference` answer every call alike: the same success,
///         return data, logs, implementation slot, balance, and proxy storage, on a blank proxy
///         and after it is armed.
contract LockedProxyDifferentialTest is Test {
    DifferentialFactory factory;
    address proxy;
    address ref;
    address[] targets;

    function setUp() public {
        factory = new DifferentialFactory();
        proxy = factory.makeProxy();
        ref = factory.makeReference();
        delete targets;
        targets.push(address(new LogicA()));
        targets.push(address(new Echo()));
        targets.push(address(new Failing()));
        targets.push(address(new EmptyRevert()));
        targets.push(address(0xBEEF));
        targets.push(address(0));
        targets.push(address(1));
        targets.push(address(0x20));
    }

    function _send(address p, bool asAdmin, bytes memory data, uint256 value)
        internal
        returns (bool ok, bytes memory ret, VmSafe.Log[] memory logs)
    {
        vm.recordLogs();
        vm.deal(address(this), value);
        if (asAdmin) {
            (ok, ret) = factory.send{value: value}(p, data);
        } else {
            (ok, ret) = p.call{value: value}(data);
        }
        logs = vm.getRecordedLogs();
    }

    /// @dev What `abi.decode` reverts with on calldata it refuses: nothing, or `Panic(0x41)` for a
    ///      length too large to allocate. The two are one outcome, a refused call that changes nothing.
    function _isDecodeFailure(bytes memory ret) internal pure returns (bool) {
        return ret.length == 0 || keccak256(ret) == keccak256(abi.encodeWithSignature("Panic(uint256)", 0x41));
    }

    function _step(bool asAdmin, bytes memory data, uint256 value) internal {
        (bool okP, bytes memory retP, VmSafe.Log[] memory logsP) = _send(proxy, asAdmin, data, value);
        (bool okR, bytes memory retR, VmSafe.Log[] memory logsR) = _send(ref, asAdmin, data, value);

        assertEq(okP, okR, "success");
        if (!okP && !okR && _isDecodeFailure(retR)) {
            assertTrue(_isDecodeFailure(retP), "a decode failure stays one");
        } else {
            assertEq(retP, retR, "return data");
        }
        assertEq(logsP.length, logsR.length, "log count");
        for (uint256 i; i < logsP.length && i < logsR.length; ++i) {
            assertEq(keccak256(abi.encode(logsP[i].topics)), keccak256(abi.encode(logsR[i].topics)), "topics");
            assertEq(logsP[i].data, logsR[i].data, "log data");
        }
        assertEq(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT), vm.load(ref, ERC1967Utils.IMPLEMENTATION_SLOT));
        assertEq(proxy.balance, ref.balance, "balance");
        assertEq(vm.load(proxy, bytes32(0)), vm.load(ref, bytes32(0)), "storage slot 0");
        assertEq(vm.load(proxy, bytes32(uint256(1))), vm.load(ref, bytes32(uint256(1))), "storage slot 1");
    }

    /// @dev Calls made after the first one: a second arm, from the admin and from a stranger,
    ///      and one the implementation answers.
    function _followUp(bytes memory armTo) internal {
        _step(true, armTo, 0);
        _step(false, armTo, 0);
        _step(true, abi.encodeWithSignature("value()"), 0);
        _step(false, abi.encodeWithSignature("value()"), 0);
    }

    function _initData(uint8 pick, bytes memory tail) internal pure returns (bytes memory) {
        pick %= 5;
        if (pick == 0) return "";
        if (pick == 1) return abi.encodeCall(LogicA.initialize, (7));
        if (pick == 2) return abi.encodeCall(Failing.initialize, ());
        if (pick == 3) return hex"01";
        return tail;
    }

    function _armCall(address impl, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(ILockedProxy.upgradeInitializeAndLock, (impl, data));
    }

    function _word(bytes memory cd, uint256 offset) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(add(cd, 32), offset))
        }
    }

    function _setWord(bytes memory cd, uint256 offset, uint256 w) internal pure {
        assembly {
            mstore(add(add(cd, 32), offset), w)
        }
    }

    /// @dev One of: unchanged, truncated, a word flipped, junk appended, the address word dirtied,
    ///      the offset word replaced, cut at a boundary, the length word made small. Together they reach every branch of `abi.decode`.
    function _mutate(bytes memory cd, uint8 mutation, uint256 mask, bytes memory junk)
        internal
        pure
        returns (bytes memory)
    {
        mutation %= 8;
        if (mutation == 1) {
            uint256 n = mask % (cd.length + 1);
            assembly {
                mstore(cd, n)
            }
        } else if (mutation == 2 && cd.length >= 36) {
            uint256 offset = 4 + (mask % ((cd.length - 4) / 32)) * 32;
            _setWord(cd, offset, _word(cd, offset) ^ uint256(keccak256(abi.encode(mask))));
        } else if (mutation == 3) {
            cd = bytes.concat(cd, junk);
        } else if (mutation == 4 && cd.length >= 36) {
            _setWord(cd, 4, _word(cd, 4) | (mask << 160));
        } else if (mutation == 5 && cd.length >= 68) {
            uint256 big = type(uint256).max;
            uint256[8] memory offsets = [big, big - 3, big - 20, uint256(1) << 64, (uint256(1) << 64) - 1, 0, 31, mask];
            _setWord(cd, 36, offsets[mask % 8]);
        } else if (mutation == 6) {
            uint256[7] memory cuts = [uint256(4), 35, 36, 67, 68, 99, 100];
            uint256 n = cuts[mask % 7];
            if (n < cd.length) {
                assembly {
                    mstore(cd, n)
                }
            }
        } else if (mutation == 7 && cd.length >= 100) {
            uint256 big = type(uint256).max;
            uint256[8] memory lengths =
                [big, big - 31, big - 35, uint256(1) << 64, (uint256(1) << 64) - 1, 0, 1, mask % 70];
            _setWord(cd, 68, lengths[mask % 8]);
        }
        return cd;
    }

    /* ================================================================================ */

    /// @dev A valid arming call to each kind of target, with each kind of initializer.
    function test_everyTargetAndInitializerMatches() public {
        for (uint256 i; i < targets.length; ++i) {
            for (uint8 j; j < 5; ++j) {
                setUp();
                bytes memory data = _initData(j, hex"deadbeef");
                bytes memory cd = _armCall(targets[i], data);
                _step(true, cd, 0);
                _followUp(_armCall(address(new LogicB()), ""));
            }
        }
    }

    function testFuzz_armingMatches(
        bool asAdmin,
        uint8 implPick,
        uint8 initPick,
        bytes calldata tail,
        uint8 mutation,
        uint256 mask,
        uint96 value
    ) public {
        bytes memory cd = _armCall(targets[implPick % targets.length], _initData(initPick, tail));
        _step(asAdmin, _mutate(cd, mutation, mask, tail), value);
        _followUp(_armCall(address(new LogicB()), ""));
    }

    function testFuzz_rawCalldataMatches(bool asAdmin, bytes calldata raw, uint96 value) public {
        _step(asAdmin, raw, value);
        _followUp(_armCall(targets[0], ""));
    }

    /// @dev Calldata that starts with the arming selector but is otherwise random.
    function testFuzz_selectorThenRandomBytesMatches(bool asAdmin, bytes calldata rest, uint96 value) public {
        _step(asAdmin, bytes.concat(ILockedProxy.upgradeInitializeAndLock.selector, rest), value);
        _followUp(_armCall(targets[0], ""));
    }
}
