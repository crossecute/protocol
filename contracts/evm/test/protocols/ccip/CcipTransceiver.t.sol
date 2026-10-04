// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";

import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {CcipTransceiver} from "src/protocols/ccip/CcipTransceiver.sol";
import {CcipZkSyncTransceiver} from "src/protocols/ccip/CcipDivergentTransceiver.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {ProviderInboundSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {CcipSendSuite} from "test/protocols/ccip/CcipBinding.t.sol";

function ccipConfig(address router) returns (TransceiverConfig memory) {
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: address(0xBEEF),
        receiverImplementation: address(new CcipReceiver(router)),
        governorOwner: address(0x5165),
        governorSalt: bytes32(0),
        governorHome: ChainKey.forEvm(1),
        treasury: address(0x7EA5)
    });
}

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract CcipTransceiverHarness is CcipTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address router_) CcipTransceiver(router_) {}

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

function deployCcip(address router) returns (CcipTransceiverHarness) {
    return CcipTransceiverHarness(
        payable(address(
                new ERC1967Proxy(
                    address(new CcipTransceiverHarness(router)),
                    abi.encodeCall(CcipTransceiver.initialize, (ccipConfig(router)))
                )
            ))
    );
}

function ccipMessage(uint64 selector, address sender, bytes memory data) pure returns (Client.Any2EVMMessage memory) {
    return Client.Any2EVMMessage({
        messageId: bytes32(0),
        sourceChainSelector: selector,
        sender: abi.encode(sender),
        data: data,
        destTokenAmounts: new Client.EVMTokenAmount[](0)
    });
}

/// @notice `CcipSendSuite` against the transceiver that is hub and spoke at once.
contract CcipTransceiverSendTest is CcipSendSuite {
    function _deploy() internal override returns (address, address) {
        CcipTransceiverHarness t = deployCcip(address(router));
        return (address(t), t.owner());
    }
}

/// @notice CCIP's off-ramp asserts nothing about the sender, so the base's counterpart check is
///         what refuses a wrong one, and the router's gateway role is what admits the call.
contract CcipTransceiverInboundTest is ProviderInboundSpec {
    address router = address(0xBEEF);
    CcipTransceiverHarness t;
    uint64 constant ORIGIN_SELECTOR = 15_971_525_489_660_198_786;

    function setUp() public {
        t = deployCcip(router);
    }

    function _transceiver() internal view override returns (address) {
        return address(t);
    }

    function _configureOrigin(bytes32 chainKey) internal override {
        vm.prank(t.owner());
        t.setSelector(chainKey, ORIGIN_SELECTOR);
    }

    function _deliver(address sender, bytes memory message) internal override {
        vm.prank(router);
        t.ccipReceive(ccipMessage(ORIGIN_SELECTOR, sender, message));
    }

    /// @dev Only the router may deliver, whatever the message says.
    function test_onlyTheRouterDelivers() public {
        _wire();
        // Read before the prank: an external call inside the expected error would consume it.
        bytes32 role = t.GATEWAY_ROLE();
        bytes memory message = _bootstrap();

        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xBAD), role)
        );
        t.ccipReceive(ccipMessage(ORIGIN_SELECTOR, ORIGIN_TRANSCEIVER, message));
    }

    /// @dev The router is granted the gateway role by the initializer, not by the deployment
    ///      remembering to list it.
    function test_theRouterIsTheGatewayWithNoneListed() public view {
        assertTrue(t.hasRole(t.GATEWAY_ROLE(), router));
    }

    /// @dev Answering false makes the off-ramp mark a message executed without delivering it.
    function test_itAnswersSupportsInterface() public view {
        assertTrue(t.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(t.supportsInterface(type(IERC165).interfaceId));
        assertFalse(t.supportsInterface(bytes4(0xdeadbeef)));
    }
}

contract CcipZkSyncHarness is CcipZkSyncTransceiver {
    constructor(address router_) CcipZkSyncTransceiver(router_) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice A report is sent inside a delivery, at `msg.value == 0`, from the float.
contract CcipZkSyncTransceiverTest is Test {
    MockCcipRouter router;
    CcipZkSyncHarness t;
    uint64 constant HOME_SELECTOR = 5_009_297_550_715_157_269;

    function setUp() public {
        router = new MockCcipRouter();
        t = CcipZkSyncHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(new CcipZkSyncHarness(address(router))),
                        abi.encodeCall(
                            CcipZkSyncTransceiver.initialize, (ccipConfig(address(router)), keccak256("zksolc"))
                        )
                    )
                ))
        );
        ChainRegistry registry = new ChainRegistry(address(this));
        bytes32 provider = registry.addMessageProvider("ccip");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(1), Provenance.Attested);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        t.setRoute(home, Erc7930.encodeEvmChain(1));
        t.setCounterpart(home, Erc7930.encodeEvm(1, address(0xC0DE)));
        t.setSelector(home, HOME_SELECTOR);
        vm.stopPrank();
    }

    function test_itAlwaysDiverges() public view {
        assertTrue(t.addressesDiverge());
    }

    function test_itAnswersSupportsInterface() public view {
        assertTrue(t.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
    }

    function test_aReportSpendsFromTheFloat() public {
        router.setFee(0.01 ether);
        vm.deal(address(t), 1 ether);

        vm.prank(makeAddr("relayer"));
        t.reportPublic(ChainKey.forEvm(1), address(0xA11CE), bytes32(0), address(0x2C));

        (uint64 selector, bytes memory receiver,,,, uint256 value) = router.sent(0);
        assertEq(selector, HOME_SELECTOR, "to the account's home");
        assertEq(receiver, abi.encode(address(0xC0DE)), "to its transceiver there");
        assertEq(value, 0.01 ether, "the quoted fee, paid from the float");
    }
}
