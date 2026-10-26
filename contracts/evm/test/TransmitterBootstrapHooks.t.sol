// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {ext} from "test/Harness.sol";
import {Transmitter, HomeTransceiver} from "test/ReceiverReport.t.sol";

/// @dev Sends its own bootstrap, as the `layerzero-oft` conduit will.
contract HookedTransmitter is Transmitter {
    uint256 constant PRICE = 7;

    bytes32 public sentTo;
    uint256 public sentFee;
    uint256 public sentCalls;

    function _quoteBootstrap(bytes32, Call[] calldata, bytes[] calldata) internal pure override returns (uint256) {
        return PRICE;
    }

    function _sendBootstrap(bytes32 chainKey, Call[] calldata calls, bytes[] calldata, uint256 fee) internal override {
        sentTo = chainKey;
        sentFee = fee;
        sentCalls = calls.length;
    }
}

/// @dev `bootstrap` and `quoteBootstrap` both reach a binding's own transport through the two
///      hooks, and the transceiver is not called.
contract TransmitterBootstrapHooksTest is Test {
    HomeTransceiver t;
    HookedTransmitter conduit;

    address msig = address(0x5165);
    address owner = address(0xA11CE);
    bytes32 constant SALT = keccak256("acct");
    uint256 constant DESTINATION = 42161;
    bytes32 destinationKey;

    function setUp() public {
        ChainRegistry registry = new ChainRegistry(msig, unseeded());
        t = new HomeTransceiver();
        t.initialize(msig, address(0x7EA5), address(new HookedTransmitter()));

        vm.startPrank(msig);
        bytes32 provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(t));
        destinationKey = registry.addChainKey(Erc7930.encodeEvmChain(DESTINATION), Provenance.Predetermined);
        vm.stopPrank();

        vm.startPrank(t.owner());
        ext(address(t)).setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        ext(address(t)).setRoute(destinationKey, Erc7930.encodeEvmChain(DESTINATION));
        vm.stopPrank();

        vm.prank(owner);
        conduit = HookedTransmitter(payable(t.createTransmitter(SALT)));
        vm.deal(address(conduit), 1 ether);
    }

    function test_theQuoteIsTheHooks() public view {
        assertEq(conduit.quoteBootstrap(DESTINATION, _calls(), new bytes[](0)), 7);
        assertNotEq(t.quoteBootstrap(destinationKey, owner, SALT, _calls(), new bytes[](0)), 7, "not the transceiver's");
    }

    function test_theSendIsTheHooksAndPaysTheQuote() public {
        vm.prank(owner);
        conduit.bootstrap(DESTINATION, _calls(), new bytes[](0));

        assertEq(conduit.sentTo(), destinationKey);
        assertEq(conduit.sentFee(), 7, "the hook's quote");
        assertEq(conduit.sentCalls(), 1);
        assertTrue(conduit.isBootstrapped(destinationKey), "recorded before the hook ran");
        assertEq(t.lastSendValue(), 0, "the transceiver sent nothing");
    }

    /// @dev The balance check reads the hook's quote, not the transceiver's.
    function test_anUnfundedConduitCannotBootstrapThroughTheHooks() public {
        vm.deal(address(conduit), 6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.InsufficientBalance.selector, 7, 6));
        conduit.bootstrap(DESTINATION, _calls(), new bytes[](0));
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(address(0xCA11), 0, "");
    }
}
