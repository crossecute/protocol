// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";

import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {HyperlaneTransceiver} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneZkSyncTransceiver} from "src/protocols/hyperlane/HyperlaneDivergentTransceiver.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {ProviderInboundSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {HyperlaneSendSuite} from "test/protocols/hyperlane/HyperlaneBinding.t.sol";

function hyperlaneConfig(address mailbox) returns (TransceiverConfig memory) {
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: address(0xBEEF),
        receiverImplementation: address(new HyperlaneReceiver(mailbox)),
        governorOwner: address(0x5165),
        governorSalt: bytes32(0),
        governorHome: ChainKey.forEvm(1),
        treasury: address(0x7EA5)
    });
}

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract HyperlaneTransceiverHarness is HyperlaneTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address mailbox_) HyperlaneTransceiver(mailbox_) {}

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

function deployHyperlane(address mailbox) returns (HyperlaneTransceiverHarness) {
    return HyperlaneTransceiverHarness(
        payable(address(
                new ERC1967Proxy(
                    address(new HyperlaneTransceiverHarness(mailbox)),
                    abi.encodeCall(HyperlaneTransceiver.initialize, (hyperlaneConfig(mailbox)))
                )
            ))
    );
}

/// @notice `HyperlaneSendSuite` against the transceiver that is hub and spoke at once.
contract HyperlaneTransceiverSendTest is HyperlaneSendSuite {
    function _deploy() internal override returns (address, address) {
        HyperlaneTransceiverHarness t = deployHyperlane(address(mailbox));
        return (address(t), t.owner());
    }
}

/// @notice `Mailbox.process` asserts nothing about the source-chain sender, so the base's
///         counterpart check is what refuses a wrong one, and the Mailbox's gateway role is
///         what admits the call.
contract HyperlaneTransceiverInboundTest is ProviderInboundSpec {
    address mailbox = address(0xBEEF);
    HyperlaneTransceiverHarness t;
    uint32 constant ORIGIN_DOMAIN = 8453;

    function setUp() public {
        t = deployHyperlane(mailbox);
    }

    function _transceiver() internal view override returns (address) {
        return address(t);
    }

    function _configureOrigin(bytes32 chainKey) internal override {
        vm.prank(t.owner());
        t.setDomain(chainKey, ORIGIN_DOMAIN);
    }

    function _deliver(address sender, bytes memory message) internal override {
        vm.prank(mailbox);
        t.handle(ORIGIN_DOMAIN, TypeCasts.addressToBytes32(sender), message);
    }

    /// @dev R6: the receiver admits the Mailbox before its payload runs.
    function _assertReceiverConfigured(address receiver, address) internal view override {
        HyperlaneReceiver r = HyperlaneReceiver(payable(receiver));
        assertTrue(r.hasRole(r.GATEWAY_ROLE(), mailbox));
    }

    /// @dev Only the Mailbox may deliver, whatever the message says.
    function test_onlyTheMailboxDelivers() public {
        _wire();
        // Read before the prank: an external call inside the expected error would consume it.
        bytes32 role = t.GATEWAY_ROLE();
        bytes memory message = _bootstrap();

        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xBAD), role)
        );
        t.handle(ORIGIN_DOMAIN, TypeCasts.addressToBytes32(ORIGIN_TRANSCEIVER), message);
    }

    /// @dev The Mailbox is granted the gateway role by the initializer, not by the deployment
    ///      remembering to list it.
    function test_theMailboxIsTheGatewayWithNoneListed() public view {
        assertTrue(t.hasRole(t.GATEWAY_ROLE(), mailbox));
    }
}

contract HyperlaneZkSyncHarness is HyperlaneZkSyncTransceiver {
    constructor(address mailbox_) HyperlaneZkSyncTransceiver(mailbox_) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice A report is sent inside a delivery, at `msg.value == 0`, from the float, and the
///         hooks' overpayment refund must return to the float, not the relayer.
contract HyperlaneZkSyncTransceiverTest is Test {
    MockHyperlaneMailbox mailbox;
    HyperlaneZkSyncHarness t;
    uint32 constant HOME_DOMAIN = 1;

    function setUp() public {
        mailbox = new MockHyperlaneMailbox();
        t = HyperlaneZkSyncHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(new HyperlaneZkSyncHarness(address(mailbox))),
                        abi.encodeCall(
                            HyperlaneZkSyncTransceiver.initialize,
                            (hyperlaneConfig(address(mailbox)), keccak256("zksolc"))
                        )
                    )
                ))
        );
        ChainRegistry registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()), abi.encodeCall(ChainRegistry.initialize, (address(this)))
                )
            )
        );
        bytes32 provider = registry.addMessageProvider("hyperlane");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(1));
        registry.setProvenance(home, Provenance.Attested);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        t.setRoute(home, Erc7930.encodeEvmChain(1));
        t.setCounterpart(home, Erc7930.encodeEvm(1, address(0xC0DE)));
        t.setDomain(home, HOME_DOMAIN);
        vm.stopPrank();
    }

    function test_itAlwaysDiverges() public view {
        assertTrue(t.addressesDiverge());
    }

    function test_aReportSpendsFromTheFloatAndRefundsToIt() public {
        mailbox.setFee(0.01 ether);
        vm.deal(address(t), 1 ether);

        vm.prank(makeAddr("relayer"));
        t.reportPublic(ChainKey.forEvm(1), address(0xA11CE), bytes32(0), address(0x2C));

        MockHyperlaneMailbox.Sent memory s = mailbox.sent(0);
        assertEq(s.destinationDomain, HOME_DOMAIN, "to the account's home");
        assertEq(s.recipientAddress, TypeCasts.addressToBytes32(address(0xC0DE)), "to its transceiver there");
        assertEq(s.value, 0.01 ether, "the quoted fee, paid from the float");
        assertEq(s.refundTo, address(t), "an overpayment returns to the float, not the relayer");
    }
}
