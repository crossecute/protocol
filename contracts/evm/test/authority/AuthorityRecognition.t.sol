// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {AuthorityUpdate} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "@crossecute/safe-guard/authority/ISourceAuthorityGuard.sol";
import {Call} from "src/messaging/Call.sol";
import {AuthorityRecognition} from "src/messaging/authority/AuthorityRecognition.sol";
import {AuthorityUpdateEncoding} from "src/messaging/authority/AuthorityUpdateEncoding.sol";
import {ReceiverAuthority} from "src/messaging/authority/ReceiverAuthority.sol";

contract AuthorityRecognitionTest is Test {
    address internal constant GUARD = address(0x1234);
    address internal constant MULTISEND = address(0x5678);
    address internal constant SAFE = address(0xA);

    function recognize(SafeTx memory safeTx) external pure returns (ReceiverAuthority.RecognizedUpdate memory) {
        return AuthorityRecognition.recognize(GUARD, MULTISEND, SAFE, safeTx);
    }

    function _update() internal pure returns (AuthorityUpdate memory) {
        return AuthorityUpdate(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function _mutations() internal pure returns (Call[] memory mutations) {
        mutations = new Call[](1);
        mutations[0] = Call(SAFE, 0, abi.encodeWithSelector(AuthorityUpdateEncoding.CHANGE_THRESHOLD, uint256(1)));
    }

    function testOwnershipBatch() public view {
        SafeTx memory safeTx;
        safeTx.to = MULTISEND;
        safeTx.operation = 1;
        safeTx.data = AuthorityUpdateEncoding.ownershipBatchData(GUARD, SAFE, _update(), _mutations());
        ReceiverAuthority.RecognizedUpdate memory r = this.recognize(safeTx);
        assertEq(uint8(r.kind), uint8(ReceiverAuthority.UpdateKind.OwnershipChange));
        assertEq(r.update.newAuthorityHash, bytes32(uint256(2)));
        assertEq(r.mutations.length, 1);
    }

    function testSelectAuthority() public view {
        SafeTx memory safeTx;
        safeTx.to = GUARD;
        safeTx.data = abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (_update()));
        ReceiverAuthority.RecognizedUpdate memory r = this.recognize(safeTx);
        assertEq(uint8(r.kind), uint8(ReceiverAuthority.UpdateKind.Selection));
        assertEq(r.update.previousUpdateHash, bytes32(uint256(1)));
    }

    function testActivation() public view {
        SafeTx memory safeTx;
        safeTx.to = GUARD;
        safeTx.data = abi.encodeCall(ISourceAuthorityGuard.activate, (bytes32(uint256(3))));
        assertEq(uint8(this.recognize(safeTx).kind), uint8(ReceiverAuthority.UpdateKind.Activation));
    }

    function testRejectsEveryOtherShape() public {
        SafeTx memory safeTx;
        safeTx.to = MULTISEND;
        safeTx.operation = 0;
        safeTx.data = AuthorityUpdateEncoding.ownershipBatchData(GUARD, SAFE, _update(), _mutations());
        vm.expectRevert(AuthorityRecognition.NotAnAuthorityCall.selector);
        this.recognize(safeTx);

        safeTx.operation = 1;
        safeTx.value = 1;
        vm.expectRevert(AuthorityRecognition.NotAnAuthorityCall.selector);
        this.recognize(safeTx);

        safeTx.value = 0;
        safeTx.to = address(0x9999);
        vm.expectRevert(AuthorityRecognition.NotAnAuthorityCall.selector);
        this.recognize(safeTx);

        safeTx.to = GUARD;
        safeTx.operation = 1;
        safeTx.data = abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (_update()));
        vm.expectRevert(AuthorityRecognition.NotAnAuthorityCall.selector);
        this.recognize(safeTx);

        safeTx.operation = 0;
        safeTx.data = abi.encodeCall(ISourceAuthorityGuard.executed, (SAFE, bytes32(0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                AuthorityRecognition.UnknownGuardSelector.selector, ISourceAuthorityGuard.executed.selector
            )
        );
        this.recognize(safeTx);
    }
}
