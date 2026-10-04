// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {OpStackReceiver} from "src/protocols/op-stack/OpStackReceiver.sol";
import {IOpStackRecipient} from "src/protocols/op-stack/OpStackMessage.sol";
import {IOpStackMessengerSource} from "src/protocols/op-stack/OpStackTransmitter.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";

import {MockCrossDomainMessenger} from "test/protocols/op-stack/MockCrossDomainMessenger.sol";
import {ProviderInboundSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {OpStackSendSuite} from "test/protocols/op-stack/OpStackBinding.t.sol";

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract OpStackTransceiverHarness is OpStackTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address messenger_, bytes32 messengerChainKey_) OpStackTransceiver(messenger_, messengerChainKey_) {}

    function sendMessagePublic(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        external
        payable
        returns (bytes32)
    {
        return _sendMessage(recipient, payload, attributes, value);
    }

    function quoteMessagePublic(bytes memory recipient, bytes memory payload) external view returns (uint256) {
        return _quoteMessage(recipient, payload, new bytes[](0));
    }

    function _handleInbound(bytes32 origin, bytes calldata message) internal override {
        emit InboundHandled(origin);
        super._handleInbound(origin, message);
    }
}

function opStackConfig(address messenger) returns (TransceiverConfig memory) {
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: address(0xBEEF),
        receiverImplementation: address(new OpStackReceiver(messenger)),
        governorOwner: address(0x5165),
        governorSalt: bytes32(0),
        governorHome: Erc7930.encodeEvmChain(1),
        treasury: address(0x7EA5),
        chainRegistry: IChainRegistryRefs(address(0)),
        messageProvider: bytes32(0),
        minCounterpartProvenance: Provenance.Unresolved
    });
}

function deployOpStack(address messenger, uint256 pairedChainId) returns (OpStackTransceiverHarness) {
    return OpStackTransceiverHarness(
        payable(address(
                new ERC1967Proxy(
                    address(new OpStackTransceiverHarness(messenger, ChainKey.forEvm(pairedChainId))),
                    abi.encodeCall(OpStackTransceiver.initialize, (opStackConfig(messenger)))
                )
            ))
    );
}

/// @notice `OpStackSendSuite` against the plain transceiver.
contract OpStackTransceiverSendTest is OpStackSendSuite {
    function _deploy() internal override returns (address) {
        return address(deployOpStack(address(messenger), BASE));
    }
}

/// @notice The sender is `xDomainMessageSender()`, checked by the base against the paired
///         chain's counterpart; the messenger's gateway role is what admits the call.
contract OpStackTransceiverInboundTest is ProviderInboundSpec {
    MockCrossDomainMessenger messenger;
    OpStackTransceiverHarness t;

    function setUp() public {
        messenger = new MockCrossDomainMessenger();
        t = deployOpStack(address(messenger), ORIGIN_CHAIN_ID);
    }

    function _transceiver() internal view override returns (address) {
        return address(t);
    }

    /// @dev Nothing to configure: the paired chain is an implementation immutable.
    function _configureOrigin(bytes32) internal override {}

    function _deliverTo(address transceiver, address sender, bytes memory message) internal override {
        messenger.relay(sender, transceiver, abi.encodeCall(IOpStackRecipient.receiveOpStackMessage, (message)));
    }

    function _deployBornConfigured(IChainRegistryRefs registry, address governorOwner, bytes32 governorSalt)
        internal
        override
        returns (address)
    {
        TransceiverConfig memory c = opStackConfig(address(messenger));
        c.governorOwner = governorOwner;
        c.governorSalt = governorSalt;
        c.governorHome = Erc7930.encodeEvmChain(ORIGIN_CHAIN_ID);
        c.chainRegistry = registry;
        c.messageProvider = keccak256("under-test");
        c.minCounterpartProvenance = Provenance.Attested;
        return address(
            new ERC1967Proxy(
                address(new OpStackTransceiver(address(messenger), ChainKey.forEvm(ORIGIN_CHAIN_ID))),
                abi.encodeCall(OpStackTransceiver.initialize, (c))
            )
        );
    }

    /// @dev R6: the receiver admits the messenger before its payload runs.
    function _assertReceiverConfigured(address receiver, address) internal view override {
        OpStackReceiver r = OpStackReceiver(payable(receiver));
        assertTrue(r.hasRole(r.GATEWAY_ROLE(), address(messenger)));
    }

    function test_onlyTheMessengerDelivers() public {
        _wire();
        bytes32 role = t.GATEWAY_ROLE();
        bytes memory message = _bootstrap();

        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xBAD), role)
        );
        t.receiveOpStackMessage(message);
    }

    /// @dev The paired chain is the only origin, and with no route recorded for it nothing is
    ///      accepted, even from the counterpart's address.
    function test_nothingIsAcceptedBeforeThePairedChainIsRouted() public {
        bytes32 paired = ChainKey.forEvm(ORIGIN_CHAIN_ID);
        bytes memory message = _bootstrap();
        vm.expectRevert(abi.encodeWithSelector(OutboundBase.NoRouteFor.selector, paired));
        _deliver(ORIGIN_TRANSCEIVER, message);
    }

    /// @dev `OpStackTransmitter` reads its messenger and paired chain from the transceiver that
    ///      created it.
    function test_itAnswersWhatItsTransmittersRead() public view {
        assertEq(IOpStackMessengerSource(address(t)).messenger(), address(messenger));
        assertEq(IOpStackMessengerSource(address(t)).messengerChainKey(), ChainKey.forEvm(ORIGIN_CHAIN_ID));
    }
}
