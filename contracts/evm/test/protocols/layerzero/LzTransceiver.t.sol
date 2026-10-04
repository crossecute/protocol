// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";

import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {LzZkSyncTransceiver} from "src/protocols/layerzero/LzDivergentTransceiver.sol";
import {LzReceiver} from "src/protocols/layerzero/LzReceiver.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {ProviderInboundSpec, ProviderGovernorHomeSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {LzSendSuite, LzWriteOncePeerCheck} from "test/protocols/layerzero/LzBinding.t.sol";

function lzConfig(address endpoint) returns (TransceiverConfig memory) {
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: address(0xBEEF),
        receiverImplementation: address(new LzReceiver(endpoint)),
        governorOwner: address(0x5165),
        governorSalt: bytes32(0),
        governorHome: Erc7930.encodeEvmChain(1),
        treasury: address(0x7EA5),
        chainRegistry: IChainRegistryRefs(address(0)),
        messageProvider: bytes32(0),
        minCounterpartProvenance: Provenance.Unresolved
    });
}

/// @notice Exposes the send seam for the shared send suite, and marks each message it handles.
contract LzTransceiverHarness is LzTransceiver {
    event InboundHandled(bytes32 chainKey);

    constructor(address endpoint) LzTransceiver(endpoint) {}

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

function deployLz(address endpoint) returns (LzTransceiverHarness) {
    return LzTransceiverHarness(
        payable(address(
                new ERC1967Proxy(
                    address(new LzTransceiverHarness(endpoint)),
                    abi.encodeCall(LzTransceiver.initialize, (lzConfig(endpoint), uint32(0)))
                )
            ))
    );
}

/// @notice `LzSendSuite` against the plain transceiver.
contract LzTransceiverSendTest is LzSendSuite {
    function _deploy() internal override returns (address, address) {
        LzTransceiverHarness t = deployLz(address(endpoint));
        return (address(t), t.owner());
    }
}

contract LzTransceiverInboundTest is ProviderInboundSpec, LzWriteOncePeerCheck {
    MockLzEndpoint endpoint;
    LzTransceiverHarness t;
    uint32 constant ORIGIN_EID = 30184;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        t = deployLz(address(endpoint));
    }

    function _transceiver() internal view override returns (address) {
        return address(t);
    }

    function _configureOrigin(bytes32 chainKey) internal override {
        vm.startPrank(t.owner());
        t.setEid(chainKey, ORIGIN_EID);
        t.setPeer(ORIGIN_EID, bytes32(uint256(uint160(ORIGIN_TRANSCEIVER))));
        vm.stopPrank();
    }

    function _deliver(address sender, bytes memory message) internal override {
        vm.prank(address(endpoint));
        t.lzReceive(
            Origin({srcEid: ORIGIN_EID, sender: bytes32(uint256(uint160(sender))), nonce: 1}),
            bytes32(0),
            message,
            address(0),
            ""
        );
    }

    /// @dev R3.3: OApp refuses any sender but the eid's peer before the base runs.
    function _wrongSenderRevert(bytes32, address sender) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, ORIGIN_EID, bytes32(uint256(uint160(sender))));
    }

    /// @dev R6: the receiver's peer is its transmitter on the home eid, set before its payload.
    function _assertReceiverConfigured(address receiver, address transmitter) internal view override {
        assertEq(IOAppCore(receiver).peers(ORIGIN_EID), bytes32(uint256(uint160(transmitter))));
    }

    function test_peersAreWriteOnceAndTheOwners() public {
        _assertPeerIsWriteOnce(address(t), t.owner(), ORIGIN_EID);
    }
}

contract LzZkSyncHarness is LzZkSyncTransceiver {
    constructor(address endpoint) LzZkSyncTransceiver(endpoint) {}

    function reportPublic(bytes32 home, address owner, bytes32 salt, address receiver) external {
        _reportReceiver(home, owner, salt, receiver);
    }
}

/// @notice A report is sent inside a delivery, at `msg.value == 0`, from the float. Without
///         `LzTransceiverBase._payNative` it would revert `NotEnoughNative` on every zkSync and
///         Tron account; and its overpayment must return to the float, not the relayer.
contract LzZkSyncTransceiverTest is Test {
    MockLzEndpoint endpoint;
    LzZkSyncHarness t;
    bytes32 constant HASH = keccak256("zksolc-artifact");
    uint32 constant HOME_EID = 30101;

    function setUp() public {
        endpoint = new MockLzEndpoint();
        t = LzZkSyncHarness(
            payable(address(
                    new ERC1967Proxy(
                        address(new LzZkSyncHarness(address(endpoint))),
                        abi.encodeCall(LzZkSyncTransceiver.initialize, (lzConfig(address(endpoint)), uint32(0), HASH))
                    )
                ))
        );
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("layerzero");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(1), Provenance.Attested);

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        t.setRoute(home, Erc7930.encodeEvmChain(1));
        t.setCounterpart(home, Erc7930.encodeEvm(1, address(0xC0DE)));
        t.setEid(home, HOME_EID);
        t.setPeer(HOME_EID, bytes32(uint256(uint160(address(0xC0DE)))));
        vm.stopPrank();
    }

    function test_itAlwaysDiverges() public view {
        assertTrue(t.addressesDiverge());
    }

    function test_aReportSpendsFromTheFloatAndRefundsToIt() public {
        endpoint.setFee(0.01 ether);
        vm.deal(address(t), 1 ether);

        vm.prank(makeAddr("relayer"));
        t.reportPublic(ChainKey.forEvm(1), address(0xA11CE), bytes32(0), address(0x2C));

        (uint32 dstEid,,,, uint256 value, address refundAddress) = endpoint.sent(0);
        assertEq(dstEid, HOME_EID, "to the account's home");
        assertEq(value, 0.01 ether, "the quoted fee, paid from the float");
        assertEq(refundAddress, address(t), "an overpayment returns to the float, not the relayer");
    }
}

/// @notice LayerZero delivers only from a set peer, so the governor home's eid is born with its
///         peer too: the transceiver there, which on a parity chain is this address.
contract LzGovernorHomeTest is ProviderGovernorHomeSpec {
    MockLzEndpoint endpoint = new MockLzEndpoint();
    uint32 constant HOME_EID = 30101;

    function _deployWithGovernorHomeId(uint256 id) internal override returns (address) {
        return _deploy(uint32(id), IChainRegistryRefs(address(0)));
    }

    function _deploy(uint32 eid, IChainRegistryRefs registry) internal returns (address) {
        TransceiverConfig memory c = lzConfig(address(endpoint));
        c.chainRegistry = registry;
        c.messageProvider = keccak256("layerzero");
        c.minCounterpartProvenance = Provenance.Attested;
        return address(
            new ERC1967Proxy(
                address(new LzTransceiverHarness(address(endpoint))), abi.encodeCall(LzTransceiver.initialize, (c, eid))
            )
        );
    }

    function test_theGovernorHomePeerIsBornSet() public {
        ChainRegistry registry = new ChainRegistry(
            address(this),
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(1),
                governorHomeGrade: Provenance.Derived,
                providers: new ProviderSeed[](0)
            })
        );
        address t = _deploy(HOME_EID, IChainRegistryRefs(address(registry)));
        assertEq(IOAppCore(t).peers(HOME_EID), bytes32(uint256(uint160(t))));
    }

    /// @dev On zkSync the transceiver on the home is not at this address, so the peer is the
    ///      registry's prediction from the provider's deployment record.
    function test_aDivergentTransceiversGovernorHomePeerIsThePredictedOne() public {
        ProviderSeed[] memory providers = new ProviderSeed[](1);
        providers[0] = ProviderSeed("layerzero", keccak256("salt"), keccak256("transceiver"), keccak256("account"));
        ChainRegistry registry = new ChainRegistry(
            address(this),
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(1), governorHomeGrade: Provenance.Derived, providers: providers
            })
        );
        TransceiverConfig memory c = lzConfig(address(endpoint));
        c.chainRegistry = IChainRegistryRefs(address(registry));
        c.messageProvider = keccak256("layerzero");
        c.minCounterpartProvenance = Provenance.Attested;
        address t = address(
            new ERC1967Proxy(
                address(new LzZkSyncHarness(address(endpoint))),
                abi.encodeCall(LzZkSyncTransceiver.initialize, (c, HOME_EID, keccak256("zksolc")))
            )
        );

        address there = registry.predictTransceiver(ChainKey.forEvm(1), keccak256("layerzero"));
        assertTrue(there != t, "not this address");
        assertEq(IOAppCore(t).peers(HOME_EID), bytes32(uint256(uint160(there))));
    }

    /// @dev The peer needs the registry to resolve the counterpart, so with none it is the
    ///      owner's to set later, like the rest.
    function test_withNoRegistryThePeerIsLeftToTheOwner() public {
        address t = _deploy(HOME_EID, IChainRegistryRefs(address(0)));
        assertEq(IOAppCore(t).peers(HOME_EID), bytes32(0));
    }
}
