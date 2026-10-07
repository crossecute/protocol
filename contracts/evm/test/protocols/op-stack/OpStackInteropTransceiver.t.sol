// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainKey} from "src/addressing/ChainKey.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";

import {ProviderGatewayRoleSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {OpStackInteropFixture} from "test/protocols/op-stack/OpStackInteropFixture.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";

/// @notice The origin is the source chain the messenger reports, and the sender its
///         `crossDomainMessageSender()`, checked by the base against that chain's counterpart.
contract OpStackInteropTransceiverInboundTest is ProviderGatewayRoleSpec, OpStackInteropFixture {
    /// @dev A chain outside the dependency set this transceiver was configured for has no route.
    function test_aDeliveryFromAnUnroutedChainIsRefused() public {
        _wire();
        bytes memory message = _bootstrap();
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, ChainKey.forEvm(7777777)));
        _deliver(transceiver, 7777777, bytes32(uint256(uint160(ORIGIN_TRANSCEIVER))), message);
    }
}

/// @notice Deployment waits for interop: with no code at the predeploy, the shared deploy refuses.
contract OpStackInteropDeployTest is OpStackInteropFixture {
    /// @dev External so that the expected revert attaches to the whole deploy.
    function deploy() external returns (address) {
        return _deployTransceiver(_config(), 0);
    }

    function test_aChainWithoutInteropIsRefused() public {
        vm.etch(address(MESSENGER), "");
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "the L2ToL2CrossDomainMessenger is live here"));
        this.deploy();
    }
}
