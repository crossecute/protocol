// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {LzDeploy} from "script/deploy/LzDeploy.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiverUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

import {toBytes32} from "test/protocols/ProviderFixture.sol";
import {
    ProviderZkSyncSpec,
    ProviderInboundSpec,
    ProviderGovernorHomeSpec
} from "test/protocols/ProviderBindingSpec.t.sol";
import {LzWriteOncePeerCheck} from "test/protocols/layerzero/LzBinding.t.sol";
import {LzFixture, LzZkSyncHarness} from "test/protocols/layerzero/LzFixture.sol";
import {LzTransceiver, LzTransceiverBase} from "src/protocols/layerzero/LzTransceiver.sol";
import {LzMessage, UlnConfig} from "src/protocols/layerzero/LzMessage.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

address constant DVN = address(0xD7);

/// @notice The ULN config `LzMessage` pins: `dvn` alone, no optional DVNs, default confirmations.
function onlyDvn(address dvn) pure returns (bytes memory) {
    address[] memory required = new address[](1);
    required[0] = dvn;
    return abi.encode(UlnConfig(0, 1, LzMessage.NIL_DVN_COUNT, 0, required, new address[](0)));
}

contract LzTransceiverInboundTest is ProviderInboundSpec, LzWriteOncePeerCheck, LzFixture {
    /// @dev R3.3: OApp refuses any sender but the eid's peer before the base runs.
    function _wrongSenderRevert(bytes32, address sender) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, BASE_EID, toBytes32(sender));
    }

    function _bypassRevert(address caller) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(OAppReceiverUpgradeable.OnlyEndpoint.selector, caller);
    }

    /// @dev R6: the receiver's peer is its transmitter on the home eid, set before its payload.
    function _assertReceiverConfigured(address receiver, address transmitter) internal view override {
        super._assertReceiverConfigured(receiver, transmitter);
        assertEq(IOAppCore(receiver).peers(BASE_EID), toBytes32(transmitter));
    }

    function test_peersAreWriteOnceAndTheOwners() public {
        _assertPeerIsWriteOnce(transceiver, TransceiverBase(payable(transceiver)).owner(), BASE_EID);
    }

    /// @dev #51: a receiver whose home's pathway the transceiver pinned is created with that DVN
    ///      on its receive side, before its payload runs. A receiver never sends.
    function test_aReceiverIsBornWithTheDvnPinnedForItsHome() public {
        bytes32 chainKey = _wire();
        vm.prank(TransceiverBase(payable(transceiver)).owner());
        LzTransceiver(payable(transceiver)).setDvn(BASE_EID, DVN);

        _deliverTo(transceiver, ORIGIN_TRANSCEIVER, _bootstrap());

        address receiver =
            TransceiverBase(payable(transceiver)).predictCrossAccount(ACCOUNT_OWNER, ACCOUNT_SALT, chainKey);
        assertEq(endpoint.receiveLibraryOf(receiver, BASE_EID), endpoint.RECEIVE_LIBRARY());
        assertEq(
            endpoint.configOf(receiver, endpoint.RECEIVE_LIBRARY(), BASE_EID, LzMessage.ULN_CONFIG_TYPE), onlyDvn(DVN)
        );
        assertEq(endpoint.sendLibraryOf(receiver, BASE_EID), address(0));
    }
}

/// @notice #51: a pathway whose LayerZero default is the dead DVN is pinned to one DVN, both
///         ways, write-once, and the transceiver's delegate cannot move.
contract LzDvnTest is LzFixture {
    LzTransceiver internal t;

    function setUp() public {
        t = LzTransceiver(payable(_deployTransceiver(_config(), 0)));
    }

    function _assertPinned(address oapp, uint32 eid) internal view {
        assertEq(endpoint.sendLibraryOf(oapp, eid), endpoint.SEND_LIBRARY(), "the default send library, kept");
        assertEq(endpoint.receiveLibraryOf(oapp, eid), endpoint.RECEIVE_LIBRARY(), "and receive library");
        assertEq(endpoint.configOf(oapp, endpoint.SEND_LIBRARY(), eid, LzMessage.ULN_CONFIG_TYPE), onlyDvn(DVN));
        assertEq(endpoint.configOf(oapp, endpoint.RECEIVE_LIBRARY(), eid, LzMessage.ULN_CONFIG_TYPE), onlyDvn(DVN));
    }

    function test_setDvnPinsBothDirections() public {
        vm.prank(t.owner());
        t.setDvn(BASE_EID, DVN);
        assertEq(t.dvnOf(BASE_EID), DVN);
        _assertPinned(address(t), BASE_EID);
    }

    function test_aPinnedDvnIsFinal() public {
        address owner = t.owner();
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        t.setDvn(BASE_EID, DVN);

        vm.startPrank(owner);
        vm.expectRevert(LzTransceiverBase.ZeroDvn.selector);
        t.setDvn(BASE_EID, address(0));
        t.setDvn(BASE_EID, DVN);
        vm.expectRevert(abi.encodeWithSelector(LzTransceiverBase.DvnAlreadyPinned.selector, BASE_EID));
        t.setDvn(BASE_EID, DVN);
        vm.expectRevert(abi.encodeWithSelector(LzTransceiverBase.DvnAlreadyPinned.selector, BASE_EID));
        t.setDvn(BASE_EID, address(0xD8));
        vm.stopPrank();
    }

    /// @dev Otherwise the owner could name another delegate and reconfigure any pathway.
    function test_theDelegateIsFixed() public {
        address owner = t.owner();
        vm.prank(owner);
        vm.expectRevert(LzTransceiverBase.DelegateIsFixed.selector);
        t.setDelegate(owner);
        assertEq(endpoint.delegateOf(address(t)), address(t));
    }

    /// @dev The bootstrap that creates the owner arrives over the home's pathway, so where that
    ///      pathway needs a DVN the transceiver is born with it.
    function test_aTransceiverIsBornWithItsHomesDvn() public {
        address born = LzDeploy.transceiver(_deployment(_transceiverImplementation(), _config()), BASE_EID, DVN);
        assertEq(LzTransceiver(payable(born)).dvnOf(BASE_EID), DVN);
        _assertPinned(born, BASE_EID);
    }
}

/// @notice A report is sent at `msg.value == 0` from the float, which OApp's `_lzSend` would
///         refuse with `NotEnoughNative`; `LzMessage.send` pays the endpoint directly (#55).
contract LzZkSyncTransceiverTest is ProviderZkSyncSpec, LzFixture {
    function _zkSyncImplementation() internal override returns (address) {
        return address(new LzZkSyncHarness(address(endpoint)));
    }

    function _deployZkSync(TransceiverDeployment memory d, bytes32 accountBytecodeHash)
        internal
        override
        returns (address)
    {
        return LzDeploy.zkSyncTransceiver(d, 0, address(0), accountBytecodeHash);
    }

    function _assertReportSent() internal view override {
        (uint32 dstEid,,,,, address refundAddress) = endpoint.sent(0);
        assertEq(dstEid, BASE_EID, "to the account's home");
        assertEq(refundAddress, zk, "an overpayment returns to the float, not the relayer");
    }
}

/// @notice LayerZero delivers only from a set peer, so the governor home's eid is born with its
///         peer too: the transceiver there, which on a parity chain is this address.
contract LzGovernorHomeTest is ProviderGovernorHomeSpec, LzFixture {
    uint32 constant HOME_EID = 30101;

    function _registryConfig(IChainRegistryRefs registry) internal returns (TransceiverConfig memory c) {
        c = _config();
        c.chainRegistry = registry;
        c.messageProvider = keccak256("layerzero");
        c.minCounterpartProvenance = Provenance.Unique;
    }

    function _homeSeed(ProviderSeed[] memory providers) internal returns (ChainRegistry) {
        return new ChainRegistry(
            address(this),
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(1),
                governorHomeGrade: Provenance.Predetermined,
                providers: providers
            })
        );
    }

    function test_theGovernorHomePeerIsBornSet() public {
        ChainRegistry registry = _homeSeed(new ProviderSeed[](0));
        address t = _deployTransceiver(_registryConfig(IChainRegistryRefs(address(registry))), HOME_EID);
        assertEq(IOAppCore(t).peers(HOME_EID), toBytes32(t));
    }

    /// @dev On zkSync the transceiver on the home is not at this address, so the peer is the
    ///      registry's prediction from the provider's deployment record.
    function test_aDivergentTransceiversGovernorHomePeerIsThePredictedOne() public {
        ProviderSeed[] memory providers = new ProviderSeed[](1);
        providers[0] = ProviderSeed("layerzero", address(0xDE91), keccak256("salt"), keccak256("account"));
        ChainRegistry registry = _homeSeed(providers);
        address t = LzDeploy.zkSyncTransceiver(
            _deployment(
                address(new LzZkSyncHarness(address(endpoint))), _registryConfig(IChainRegistryRefs(address(registry)))
            ),
            HOME_EID,
            address(0),
            keccak256("zksolc")
        );

        address there = registry.predictTransceiver(ChainKey.forEvm(1), keccak256("layerzero"));
        assertTrue(there != t, "not this address");
        assertEq(IOAppCore(t).peers(HOME_EID), toBytes32(there));
    }

    /// @dev The peer needs the registry to resolve the counterpart, so with none it is the
    ///      owner's to set later, like the rest.
    function test_withNoRegistryThePeerIsLeftToTheOwner() public {
        address t = _deployTransceiver(_registryConfig(IChainRegistryRefs(address(0))), HOME_EID);
        assertEq(IOAppCore(t).peers(HOME_EID), bytes32(0));
    }
}
