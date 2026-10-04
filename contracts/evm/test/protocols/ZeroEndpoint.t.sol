// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {CcipHubTransceiver} from "src/protocols/ccip/CcipHubTransceiver.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {CcipSpokeTransceiver} from "src/protocols/ccip/CcipSpokeTransceiver.sol";
import {CcipTransmitter} from "src/protocols/ccip/CcipTransmitter.sol";
import {HyperlaneHubTransceiver} from "src/protocols/hyperlane/HyperlaneHubTransceiver.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {HyperlaneSpokeTransceiver} from "src/protocols/hyperlane/HyperlaneSpokeTransceiver.sol";
import {HyperlaneTransceiver} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneTransmitter} from "src/protocols/hyperlane/HyperlaneTransmitter.sol";
import {LzHubTransceiver} from "src/protocols/layerzero/LzHubTransceiver.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {LzSpokeTransceiver} from "src/protocols/layerzero/LzSpokeTransceiver.sol";
import {LzTransmitter} from "src/protocols/layerzero/LzTransmitter.sol";
import {OpStackHubTransceiver} from "src/protocols/op-stack/OpStackHubTransceiver.sol";
import {OpStackReceiver} from "src/protocols/op-stack/OpStackReceiver.sol";
import {OpStackSpokeTransceiver} from "src/protocols/op-stack/OpStackSpokeTransceiver.sol";
import {WormholeHubTransceiver} from "src/protocols/wormhole/WormholeHubTransceiver.sol";
import {WormholeReceiver} from "src/protocols/wormhole/WormholeReceiver.sol";
import {WormholeSpokeTransceiver} from "src/protocols/wormhole/WormholeSpokeTransceiver.sol";
import {WormholeTransmitter} from "src/protocols/wormhole/WormholeTransmitter.sol";

/// @notice Every provider endpoint a constructor takes is immutable, so each refuses zero.
contract ZeroEndpointTest is Test {
    address constant E = address(0xE0);

    function test_singleEndpointConstructorsRefuseZero() public {
        bytes[16] memory code = [
            type(CcipHubTransceiver).creationCode,
            type(CcipReceiver).creationCode,
            type(CcipSpokeTransceiver).creationCode,
            type(CcipTransmitter).creationCode,
            type(HyperlaneHubTransceiver).creationCode,
            type(HyperlaneReceiver).creationCode,
            type(HyperlaneSpokeTransceiver).creationCode,
            type(HyperlaneTransceiver).creationCode,
            type(HyperlaneTransmitter).creationCode,
            type(LzHubTransceiver).creationCode,
            type(LzReceiver).creationCode,
            type(LzSpokeTransceiver).creationCode,
            type(LzTransmitter).creationCode,
            type(OpStackReceiver).creationCode,
            type(OpStackSpokeTransceiver).creationCode,
            type(WormholeReceiver).creationCode
        ];
        for (uint256 i; i < code.length; ++i) {
            _assertRefusesOnlyZero(code[i], abi.encode(address(0)), abi.encode(E));
        }
    }

    function test_opStackHubRefusesAZeroMessenger() public {
        bytes memory code = type(OpStackHubTransceiver).creationCode;
        _assertRefusesOnlyZero(code, abi.encode(address(0), bytes32(uint256(1))), abi.encode(E, bytes32(uint256(1))));
    }

    /// @dev Core bridge, executor router, and quoter, each zeroed in turn.
    function test_wormholeRefusesAnyZeroEndpoint() public {
        bytes[3] memory code = [
            type(WormholeHubTransceiver).creationCode,
            type(WormholeSpokeTransceiver).creationCode,
            type(WormholeTransmitter).creationCode
        ];
        for (uint256 i; i < code.length; ++i) {
            bytes memory good = abi.encode(E, E, E);
            _assertRefusesOnlyZero(code[i], abi.encode(address(0), E, E), good);
            _assertRefusesOnlyZero(code[i], abi.encode(E, address(0), E), good);
            _assertRefusesOnlyZero(code[i], abi.encode(E, E, address(0)), good);
        }
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
