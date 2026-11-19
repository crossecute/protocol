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
import {LzOftDeploy} from "script/deploy/LzOftDeploy.sol";
import {receiverAuthorityPins} from "script/deploy/TransceiverDeploy.sol";

contract ReceiverAuthorityPinsTest is Test {
    function deployReceivers() external returns (address[7] memory receivers) {
        address endpoint = address(0xBEEF);
        receivers = [
            CcipDeploy.receiverImplementation(endpoint),
            HyperlaneDeploy.receiverImplementation(endpoint),
            LzDeploy.receiverImplementation(endpoint),
            WormholeDeploy.receiverImplementation(WormholeDeploy.Endpoints(endpoint, endpoint)),
            OpStackDeploy.receiverImplementation(),
            OpStackInteropDeploy.receiverImplementation(),
            LzOftDeploy.factory(address(0x7EA5)).receiverImplementation()
        ];
    }

    function test_allProvidersUseTheSameDeploymentPins() public {
        (address guard, address multiSend) = receiverAuthorityPins();
        address[7] memory receivers = this.deployReceivers();
        for (uint256 i; i < receivers.length; ++i) {
            SignedReceiver receiver = SignedReceiver(payable(receivers[i]));
            assertEq(receiver.SOURCE_AUTHORITY_GUARD(), guard);
            assertEq(receiver.MULTISEND_CALL_ONLY(), multiSend);
        }
    }

    function validatePins(address guard, address multiSend) external pure returns (address, address) {
        return receiverAuthorityPins(guard, multiSend);
    }

    function test_pinPairValidation() public {
        for (uint256 combination; combination < 4; ++combination) {
            address guard = combination & 1 == 0 ? address(0) : address(0x1234);
            address multiSend = combination & 2 == 0 ? address(0) : address(0x5678);
            if (combination == 1 || combination == 2) {
                vm.expectRevert(
                    abi.encodeWithSelector(DeployCheck.selector, "both receiver authority pins are set or unset")
                );
                this.validatePins(guard, multiSend);
            } else {
                (address actualGuard, address actualMultiSend) = this.validatePins(guard, multiSend);
                assertEq(actualGuard, guard);
                assertEq(actualMultiSend, multiSend);
            }
        }
    }
}
