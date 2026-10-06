// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {deployTransceiver} from "test/DeployCrossProxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";

import {CcipZkSyncTransceiver} from "src/protocols/ccip/CcipDivergentTransceiver.sol";
import {CcipReceiver} from "src/protocols/ccip/CcipReceiver.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {transceiverConfig} from "test/protocols/ProviderFixture.sol";
import {ProviderGatewayRoleSpec, ProviderGovernorHomeSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {CcipFixture} from "test/protocols/ccip/CcipFixture.sol";

contract CcipTransceiverInboundTest is ProviderGatewayRoleSpec, CcipFixture {
    /// @dev Answering false makes the off-ramp mark a message executed without delivering it.
    function test_itAnswersSupportsInterface() public view {
        IERC165 t = IERC165(transceiver);
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
                    deployTransceiver(
                        address(new CcipZkSyncHarness(address(router))),
                        abi.encodeCall(
                            CcipZkSyncTransceiver.initialize,
                            (
                                transceiverConfig(address(new CcipReceiver(address(router)))),
                                uint64(0),
                                keccak256("zksolc")
                            )
                        )
                    )
                ))
        );
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("ccip");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(1), Provenance.Unique);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
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

contract CcipGovernorHomeTest is ProviderGovernorHomeSpec, CcipFixture {}
