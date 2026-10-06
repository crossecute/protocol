// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {deployTransceiver} from "test/DeployCrossProxy.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiverUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";

import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {LzZkSyncTransceiver} from "src/protocols/layerzero/LzDivergentTransceiver.sol";
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
}

/// @notice Without `LzTransceiverBase._payNative` a report would revert `NotEnoughNative` on
///         every zkSync and Tron account.
contract LzZkSyncTransceiverTest is ProviderZkSyncSpec, LzFixture {
    function _zkSyncImplementation() internal override returns (address) {
        return address(new LzZkSyncHarness(address(endpoint)));
    }

    function _initializeZkSync(TransceiverConfig memory c, bytes32 hash) internal pure override returns (bytes memory) {
        return abi.encodeCall(LzZkSyncTransceiver.initialize, (c, uint32(0), hash));
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
        address t = deployTransceiver(
            address(new LzZkSyncHarness(address(endpoint))),
            abi.encodeCall(
                LzZkSyncTransceiver.initialize,
                (_registryConfig(IChainRegistryRefs(address(registry))), HOME_EID, keccak256("zksolc"))
            )
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
