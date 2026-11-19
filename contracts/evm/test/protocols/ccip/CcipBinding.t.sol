// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {
    ProviderIdTableSpec,
    ProviderWideSenderSpec,
    ProviderSignedLockSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    ProviderTransmitterSpec,
    ProviderTransmitterSendSpec,
    ProviderDefaultGasSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {CcipFixture} from "test/protocols/ccip/CcipFixture.sol";

/// @notice Unlike LayerZero's peer table, CCIP has no provider-side destination-address concept
///         at all, so the recipient's address half (unused by LayerZero) is exactly what becomes
///         `EVM2AnyMessage.receiver` here.
contract CcipTransceiverSendTest is
    ProviderIdTableSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    ProviderDefaultGasSpec,
    CcipFixture
{
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(router.sentLength(), 1);
        assertEq(router.sent(0).destChainSelector, BASE_SELECTOR);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, abi.encode(uint256(1), true));
    }

    function _lastPaid() internal view override returns (uint256) {
        return router.sent(router.sentLength() - 1).value;
    }

    function _lastSentBody() internal view override returns (bytes memory) {
        return router.sent(router.sentLength() - 1).data;
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        router.setFeePerByte(perByte);
    }

    function test_sendUsesTheRecipientsAddressAsTheCcipReceiver() public {
        harness.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        assertEq(router.sent(0).receiver, abi.encode(REMOTE_COUNTERPART));
    }

    /// @dev Previously a short body failed inside `abi.decode` and a long one was truncated.
    function test_extraArgsOfTheWrongLengthAreRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function testFuzz_extraArgsRetainLegacyWireEncoding(uint256 gasLimit, bool outOfOrder) public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, abi.encode(gasLimit, outOfOrder));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
        assertEq(router.sent(0).extraArgs, abi.encodeWithSelector(bytes4(0x181dcf10), gasLimit, outOfOrder));
    }

    function test_extraArgsAttributeBecomesGenericExtraArgsV2() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, abi.encode(uint256(500_000), true));

        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);

        assertEq(
            router.sent(0).extraArgs,
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: true}))
        );
    }
}

/// @notice CCIP reports the source sender; the binding must also match the configured
///         home and source transmitter. Per-source CCV policies do not authorize a sender.
contract CcipReceiveTest is ProviderWideSenderSpec, ProviderSignedLockSpec, CcipFixture {
    function test_proxyExposesRouterAndReceiverInterfaces() public view {
        CcipReceiver r = CcipReceiver(payable(receiver));
        assertEq(r.getRouter(), address(router));
        assertEq(r.router(), address(router));
        assertTrue(r.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(r.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
        assertTrue(r.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(r.supportsInterface(type(IERC165).interfaceId));
        assertFalse(r.supportsInterface(bytes4(0xffffffff)));
    }

    function testFuzz_proxyUsesDefaultCcvAndFullFinality(uint64 selector, bytes memory sender) public view {
        (address[] memory required, address[] memory optional, uint8 threshold, bytes4 finality) =
            CcipReceiver(payable(receiver)).getCCVsAndFinalityConfig(selector, sender);
        assertEq(required.length, 0);
        assertEq(optional.length, 0);
        assertEq(threshold, 0);
        assertEq(finality, bytes4(0));
    }

    /// @dev `abi.decode(sender, (address))` validates the high bytes and reverts without data.
    function _wideSenderRevert(bytes32) internal pure override returns (bytes memory) {
        return "";
    }
}

/// @notice CCIP's off-ramp checks `supportsInterface` before calling `ccipReceive` at all, and
///         a wrong answer fails silently (no revert: the message just never arrives).
contract CcipInterfaceSupportTest is Test {
    function test_receiverSupportsIAny2EVMMessageReceiverAndIERC165() public {
        CcipReceiver receiver = new CcipReceiver(address(0xBEEF), address(0), address(0));
        assertTrue(receiver.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        assertFalse(receiver.supportsInterface(bytes4(0xdeadbeef)));
    }
}

contract CcipTransmitterInboundTest is ProviderTransmitterSpec, CcipFixture {}

contract CcipTransmitterSendTest is ProviderTransmitterSendSpec, CcipFixture {}
