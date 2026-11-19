// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SignedReceiver} from "src/messaging/inbound/SignedReceiver.sol";
import {DeployCheck} from "script/deploy/ProxyDeploy.sol";
import {CcipDeploy} from "script/deploy/CcipDeploy.sol";
import {HyperlaneDeploy} from "script/deploy/HyperlaneDeploy.sol";
import {LzDeploy} from "script/deploy/LzDeploy.sol";
import {WormholeDeploy} from "script/deploy/WormholeDeploy.sol";
import {OpStackDeploy} from "script/deploy/OpStackDeploy.sol";
import {OpStackInteropDeploy} from "script/deploy/OpStackInteropDeploy.sol";

contract ReceiverAuthorityPinsTest is Test {
    function deployReceivers() external returns (address[6] memory receivers) {
        address endpoint = address(0xBEEF);
        receivers = [
            CcipDeploy.receiverImplementation(endpoint),
            HyperlaneDeploy.receiverImplementation(endpoint),
            LzDeploy.receiverImplementation(endpoint),
            WormholeDeploy.receiverImplementation(WormholeDeploy.Endpoints(endpoint, endpoint)),
            OpStackDeploy.receiverImplementation(),
            OpStackInteropDeploy.receiverImplementation()
        ];
    }

    function test_allProvidersUseTheSameDeploymentPins() public {
        for (uint256 enabled; enabled < 2; ++enabled) {
            address guard = enabled == 0 ? address(0) : address(0x1234);
            address multiSend = enabled == 0 ? address(0) : address(0x5678);
            _setPins(guard, multiSend);
            address[6] memory receivers = this.deployReceivers();
            for (uint256 i; i < receivers.length; ++i) {
                SignedReceiver receiver = SignedReceiver(payable(receivers[i]));
                assertEq(receiver.SOURCE_AUTHORITY_GUARD(), guard);
                assertEq(receiver.MULTISEND_CALL_ONLY(), multiSend);
            }
        }
        _setPins(address(0), address(0));
    }

    function test_aPartialPinConfigurationFailsBeforeDeployment() public {
        _setPins(address(0x1234), address(0));
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "both receiver authority pins are set or unset"));
        this.deployReceivers();
        _setPins(address(0), address(0));
    }

    function _setPins(address guard, address multiSend) private {
        // forge-lint: disable-start(unsafe-cheatcode) fixture-only deployment environment, reset after each test
        vm.setEnv("CROSSECUTE_AUTHORITY_GUARD", vm.toString(guard));
        vm.setEnv("CROSSECUTE_MULTISEND_CALL_ONLY", vm.toString(multiSend));
        // forge-lint: disable-end(unsafe-cheatcode)
    }
}
