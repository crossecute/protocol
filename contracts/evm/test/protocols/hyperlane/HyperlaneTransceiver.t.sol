// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {deployTransceiver} from "test/DeployCrossProxy.sol";
import {TypeCasts} from "@hyperlane/libs/TypeCasts.sol";

import {HyperlaneZkSyncTransceiver} from "src/protocols/hyperlane/HyperlaneDivergentTransceiver.sol";
import {HyperlaneReceiver} from "src/protocols/hyperlane/HyperlaneReceiver.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {transceiverConfig} from "test/protocols/ProviderFixture.sol";
import {ProviderGatewayRoleSpec, ProviderGovernorHomeSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {HyperlaneFixture} from "test/protocols/hyperlane/HyperlaneFixture.sol";

contract HyperlaneTransceiverInboundTest is ProviderGatewayRoleSpec, HyperlaneFixture {}

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
                    deployTransceiver(
                        address(new HyperlaneZkSyncHarness(address(mailbox))),
                        abi.encodeCall(
                            HyperlaneZkSyncTransceiver.initialize,
                            (
                                transceiverConfig(address(new HyperlaneReceiver(address(mailbox)))),
                                uint32(0),
                                keccak256("zksolc")
                            )
                        )
                    )
                ))
        );
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("hyperlane");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(1), Provenance.Unique);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
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

contract HyperlaneGovernorHomeTest is ProviderGovernorHomeSpec, HyperlaneFixture {}
