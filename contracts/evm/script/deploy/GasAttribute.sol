// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {HyperlaneMessage} from "src/protocols/hyperlane/HyperlaneMessage.sol";
import {OpStackMessage} from "src/protocols/op-stack/OpStackMessage.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";

/// @title GasAttribute
/// @notice The one attribute each binding takes to set a message's destination gas.
library GasAttribute {
    /// @dev Type-3 options with one executor `lzReceive` option, as `LzMessage.options` builds
    ///      its default.
    function layerZero(uint256 gas) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast) a destination gas limit
        return abi.encodePacked(LzMessage.OPTIONS_ATTRIBUTE, uint16(3), uint8(1), uint16(17), uint8(1), uint128(gas));
    }

    /// @dev `(gasLimit, allowOutOfOrderExecution)`, which `CcipMessage` packs into EVMExtraArgsV2.
    function ccip(uint256 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, abi.encode(gas, false));
    }

    function hyperlane(uint256 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(HyperlaneMessage.GAS_LIMIT_ATTRIBUTE, gas);
    }

    function opStack(uint256 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(OpStackMessage.MIN_GAS_LIMIT_ATTRIBUTE, gas);
    }

    /// @notice The attributes a multisig sends with over `provider`, for `gas` at the destination.
    /// @dev Wormhole takes no gas without a relay provider's signed quote, which expires before a
    ///      multisig's calldata lands, so its messages are published only, and whoever delivers
    ///      them sets the gas.
    function forMultisig(string memory provider, uint256 gas) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        bytes32 p = keccak256(bytes(provider));
        if (p == keccak256("layerzero")) attrs[0] = layerZero(gas);
        else if (p == keccak256("ccip")) attrs[0] = ccip(gas);
        else if (p == keccak256("hyperlane")) attrs[0] = hyperlane(gas);
        else if (p == keccak256("op-stack-l1-l2")) attrs[0] = opStack(gas);
        else if (p == keccak256("wormhole")) attrs[0] = abi.encodePacked(WormholeMessage.PUBLISH_ONLY_ATTRIBUTE);
        else revert DeployCheck("the provider has a gas attribute");
    }
}
