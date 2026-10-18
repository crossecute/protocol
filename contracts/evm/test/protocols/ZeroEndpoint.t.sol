// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {CcipTransceiver} from "src/protocols/ccip/CcipTransceiver.sol";
import {CcipTransmitter} from "src/protocols/ccip/CcipTransmitter.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {HyperlaneTransceiver} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneTransmitter} from "src/protocols/hyperlane/HyperlaneTransmitter.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {OpStackReceiver, IOpStackReceiverInit} from "src/protocols/op-stack/OpStackReceiver.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {Call} from "src/messaging/Call.sol";
import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {WormholeTransmitter} from "src/protocols/wormhole/WormholeTransmitter.sol";
import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {OpStackInteropTransceiver} from "src/protocols/op-stack/OpStackInteropTransceiver.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {transceiverExtension} from "script/deploy/TransceiverDeploy.sol";

/// @notice Every provider endpoint a constructor takes is immutable, so each refuses zero, as
///         does the messenger OP Stack's receiver takes at initialization. A transceiver's
///         extension is immutable too, and must have code.
contract ZeroEndpointTest is Test {
    address constant E = address(0xE0);

    function test_singleEndpointConstructorsRefuseZero() public {
        bytes[7] memory code = [
            type(CcipReceiver).creationCode,
            type(CcipTransmitter).creationCode,
            type(HyperlaneReceiver).creationCode,
            type(HyperlaneTransmitter).creationCode,
            type(LzReceiver).creationCode,
            type(LzTransmitter).creationCode,
            type(WormholeReceiver).creationCode
        ];
        for (uint256 i; i < code.length; ++i) {
            _assertRefusesOnlyZero(code[i], abi.encode(address(0)), abi.encode(E));
        }

        address extension = transceiverExtension();
        bytes[3] memory transceivers = [
            type(CcipTransceiver).creationCode,
            type(HyperlaneTransceiver).creationCode,
            type(LzTransceiver).creationCode
        ];
        for (uint256 i; i < transceivers.length; ++i) {
            _assertRefusesOnlyZero(transceivers[i], abi.encode(address(0), extension), abi.encode(E, extension));
        }
    }

    /// @dev Every selector a transceiver does not declare runs in its extension, so one without
    ///      code would answer every such call with success and no data.
    function test_transceiversRefuseAnExtensionWithoutCode() public {
        bytes[6] memory code = [
            abi.encodePacked(type(CcipTransceiver).creationCode, abi.encode(E)),
            abi.encodePacked(type(HyperlaneTransceiver).creationCode, abi.encode(E)),
            abi.encodePacked(type(LzTransceiver).creationCode, abi.encode(E)),
            abi.encodePacked(type(WormholeTransceiver).creationCode, abi.encode(E, E)),
            type(OpStackTransceiver).creationCode,
            type(OpStackInteropTransceiver).creationCode
        ];
        address[2] memory codeless = [address(0), address(0xE7)];
        for (uint256 i; i < code.length; ++i) {
            for (uint256 j; j < codeless.length; ++j) {
                (address deployed, bytes memory reason) = _create(abi.encodePacked(code[i], abi.encode(codeless[j])));
                assertEq(deployed, address(0));
                assertEq(reason, abi.encodeWithSelector(TransceiverBase.NoExtension.selector));
            }
        }
    }

    /// @dev OP Stack's receiver takes its messenger at initialization rather than in its
    ///      constructor, so it refuses zero there.
    function test_opStackReceiverRefusesAZeroMessenger() public {
        address impl = address(new OpStackReceiver());
        address proxy = address(new CrossProxy());
        vm.expectRevert(ProviderAddress.ZeroEndpoint.selector);
        ICrossProxy(proxy)
            .upgradeInitializeAndLock(
                impl, abi.encodeCall(IOpStackReceiverInit.initialize, (address(0xABCD), new Call[](0), address(0)))
            );
    }

    /// @dev The core bridge and the Executor, each zeroed in turn.
    function test_wormholeRefusesAnyZeroEndpoint() public {
        bytes memory transmitter = type(WormholeTransmitter).creationCode;
        _assertRefusesOnlyZero(transmitter, abi.encode(address(0), E), abi.encode(E, E));
        _assertRefusesOnlyZero(transmitter, abi.encode(E, address(0)), abi.encode(E, E));

        address extension = transceiverExtension();
        bytes memory transceiver = type(WormholeTransceiver).creationCode;
        bytes memory good = abi.encode(E, E, extension);
        _assertRefusesOnlyZero(transceiver, abi.encode(address(0), E, extension), good);
        _assertRefusesOnlyZero(transceiver, abi.encode(E, address(0), extension), good);
    }

    function _assertRefusesOnlyZero(bytes memory code, bytes memory zeroArgs, bytes memory goodArgs) internal {
        (address deployed, bytes memory reason) = _create(abi.encodePacked(code, zeroArgs));
        assertEq(deployed, address(0));
        assertEq(reason, abi.encodeWithSelector(ProviderAddress.ZeroEndpoint.selector));

        (deployed,) = _create(abi.encodePacked(code, goodArgs));
        assertTrue(deployed != address(0));
    }

    function _create(bytes memory initcode) internal returns (address deployed, bytes memory reason) {
        assembly {
            deployed := create(0, add(initcode, 32), mload(initcode))
            reason := mload(0x40)
            mstore(reason, returndatasize())
            returndatacopy(add(reason, 32), 0, returndatasize())
            mstore(0x40, add(add(reason, 32), returndatasize()))
        }
    }
}
