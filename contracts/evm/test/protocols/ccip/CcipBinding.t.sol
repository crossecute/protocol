// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";

import {
    ProviderIdTableSpec,
    ProviderWideSenderSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    ProviderTransmitterSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {CcipFixture} from "test/protocols/ccip/CcipFixture.sol";

/// @notice Unlike LayerZero's peer table, CCIP has no provider-side destination-address concept
///         at all, so the recipient's address half (unused by LayerZero) is exactly what becomes
///         `EVM2AnyMessage.receiver` here.
contract CcipTransceiverSendTest is
    ProviderIdTableSpec,
    ProviderEvmRecipientSpec,
    ProviderPayloadPricedSpec,
    CcipFixture
{
    function _assertLastSendTargetedConfiguredDestination() internal view override {
        assertEq(router.sentLength(), 1);
        (uint64 destChainSelector,,,,,) = router.sent(0);
        assertEq(destChainSelector, BASE_SELECTOR);
    }

    function _supportedAttribute() internal pure override returns (bytes memory) {
        return abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, abi.encode(uint256(1), true));
    }

    function _lastPaid() internal view override returns (uint256 value) {
        (,,,,, value) = router.sent(router.sentLength() - 1);
    }

    function _lastSentBody() internal view override returns (bytes memory data) {
        (,, data,,,) = router.sent(router.sentLength() - 1);
    }

    function _setProviderFeePerByte(uint256 perByte) internal override {
        router.setFeePerByte(perByte);
    }

    function test_sendUsesTheRecipientsAddressAsTheCcipReceiver() public {
        harness.sendMessagePublic(_configuredRecipient(), "x", new bytes[](0), 0);
        (, bytes memory receiver,,,,) = router.sent(0);
        assertEq(receiver, abi.encode(REMOTE_COUNTERPART));
    }

    /// @dev Previously a short body failed inside `abi.decode` and a long one was truncated.
    function test_extraArgsOfTheWrongLengthAreRefused() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[0]));
        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);
    }

    function test_extraArgsAttributeBecomesEVMExtraArgsV2() public {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodePacked(CcipMessage.EXTRA_ARGS_ATTRIBUTE, abi.encode(uint256(500_000), true));

        harness.sendMessagePublic(_configuredRecipient(), "x", attrs, 0);

        (,,,, bytes memory extraArgs,) = router.sent(0);
        assertEq(
            extraArgs, Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: true}))
        );
    }
}

/// @notice CCIP's off-ramp asserts nothing about the source-chain sender (unlike LayerZero's
///         `lzReceive`), so `isSourceTransmitter` inside `ccipReceive` is the only
///         authentication check here. `CcipReceiver` keeps no per-origin state, so every
///         non-source sender is refused the same way regardless of `sourceChainSelector`.
contract CcipReceiveTest is ProviderWideSenderSpec, CcipFixture {
    /// @dev `abi.decode(sender, (address))` validates the high bytes and reverts without data.
    function _wideSenderRevert(bytes32) internal pure override returns (bytes memory) {
        return "";
    }
}

/// @notice CCIP's off-ramp checks `supportsInterface` before calling `ccipReceive` at all, and
///         a wrong answer fails silently (no revert: the message just never arrives).
contract CcipInterfaceSupportTest is Test {
    function test_receiverSupportsIAny2EVMMessageReceiverAndIERC165() public {
        CcipReceiver receiver = new CcipReceiver(address(0xBEEF));
        assertTrue(receiver.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        assertFalse(receiver.supportsInterface(bytes4(0xdeadbeef)));
    }
}

contract CcipTransmitterInboundTest is ProviderTransmitterSpec, CcipFixture {}
