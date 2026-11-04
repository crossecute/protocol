// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {unseeded} from "test/RegistrySeed.sol";
import {crossProxyDeployer} from "script/deploy/CrossProxyDeploy.sol";
import {CrossProxyDeployer} from "src/conduit/CrossProxyDeployer.sol";
import {CrossProxy} from "src/conduit/CrossProxy.sol";
import {Sym, Rcv, RecordingTransmitter} from "test/Transceiver.t.sol";
import {transceiverConfig, ext} from "test/Harness.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Call} from "src/messaging/Call.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";

/// @notice Chains deployed before and after a deployer rotation, each simulated as a state
///         snapshot of one EVM. Ethereum and Base are deployed by `D1` and Optimism by `D2`, so
///         the transceiver sits at one address on the first two and at another on the third.
contract DeployerRotationTest is Test {
    uint256 constant ETH = 1;
    uint256 constant BASE = 8453;
    uint256 constant OP = 10;
    bytes32 constant SALT = keccak256("account");
    bytes32 constant TRANSCEIVER_SALT = keccak256("provider");

    address constant D1 = address(0xD1);
    address constant D2 = address(0xD2);
    address msig = address(0x5165);
    address alice = address(0xA11CE);

    CrossProxyDeployer factory;

    function setUp() public {
        factory = crossProxyDeployer();
    }

    function _key(uint256 chainId) internal pure returns (bytes32) {
        return ChainKey.forEvm(chainId);
    }

    function _route(uint256 chainId) internal pure returns (bytes memory) {
        return Erc7930.encodeEvmChain(chainId);
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](0);
    }

    /// @dev Where the transceiver of the generation deployed by `deployer` sits.
    function _at(address deployer) internal view returns (address) {
        return factory.predict(deployer, TRANSCEIVER_SALT);
    }

    /// @dev A registry as every chain applies the same governance: Ethereum and Base added under
    ///      `D1`, a rotation to `D2`, then Optimism under `D2`. `opLive` marks every remote chain
    ///      live; otherwise they are left pending.
    function _registry(uint256 chainId, bool opLive) internal returns (ChainRegistry r, bytes32 provider) {
        r = new ChainRegistry(address(this), unseeded());
        provider = r.addMessageProvider("test");
        r.setProviderDeployment(provider, TRANSCEIVER_SALT, keccak256(type(CrossProxy).creationCode));
        r.setCurrentDeployer(D1);
        r.addChainKey(_route(ETH), Provenance.Predetermined);
        r.addChainKey(_route(BASE), Provenance.Predetermined);
        r.addProviderOnChain(_key(ETH), provider, D1);
        r.addProviderOnChain(_key(BASE), provider, D1);
        r.setCurrentDeployer(D2);
        r.addChainKey(_route(OP), Provenance.Predetermined);
        r.addProviderOnChain(_key(OP), provider, D2);

        uint256[3] memory chains = [ETH, BASE, OP];
        for (uint256 i; i < 3; ++i) {
            if (opLive && chains[i] != chainId) r.markLive(_key(chains[i]), provider);
        }
    }

    /// @dev The chain's transceiver, deployed by `deployer`, with the other chains routed.
    function _chain(uint256 chainId, address deployer, bool live) internal returns (Sym t, ChainRegistry r) {
        vm.chainId(chainId);
        bytes32 provider;
        (r, provider) = _registry(chainId, live);

        TransceiverConfig memory c = transceiverConfig(
            msig, address(new RecordingTransmitter()), address(new Rcv()), address(new Treasury(address(this)))
        );
        c.chainRegistry = IChainRegistryRefs(address(r));
        c.messageProvider = provider;
        c.minCounterpartProvenance = Provenance.Unique;

        address implementation = address(new Sym());
        bytes memory init = abi.encodeCall(Sym.initialize, (c));
        vm.prank(deployer);
        t = Sym(payable(factory.deploy(TRANSCEIVER_SALT, implementation, init)));

        uint256[3] memory chains = [ETH, BASE, OP];
        // Ethereum is routed at birth as the governor's home.
        vm.startPrank(t.owner());
        for (uint256 i; i < 3; ++i) {
            if (chains[i] == chainId || chains[i] == ETH) continue;
            ext(address(t)).setRoute(_key(chains[i]), _route(chains[i]));
        }
        vm.stopPrank();
    }

    function _bootstrap(Sym from, uint256 toChain) internal returns (address transmitter) {
        transmitter = ext(address(from)).predictTransmitter(alice, SALT);
        uint256 quote = from.quoteBootstrap(_key(toChain), alice, SALT, _calls(), new bytes[](0));
        vm.deal(transmitter, quote);
        vm.prank(transmitter);
        from.bootstrap{value: quote}(_key(toChain), alice, SALT, _calls(), new bytes[](0));
    }

    /* ============================== two generations ============================== */

    function test_transceiversOfTwoGenerationsSitAtTwoAddresses() public {
        uint256 world = vm.snapshotState();
        (Sym eth, ChainRegistry ethRegistry) = _chain(ETH, D1, true);
        bytes32 provider = ext(address(eth)).messageProvider();
        assertEq(address(eth), _at(D1));
        assertEq(ethRegistry.predictTransceiver(_key(BASE), provider), _at(D1), "Base, deployed before the rotation");
        assertEq(ethRegistry.predictTransceiver(_key(OP), provider), _at(D2), "Optimism, deployed after it");

        vm.revertToState(world);
        (Sym op,) = _chain(OP, D2, true);
        assertEq(address(op), _at(D2));
        assertTrue(_at(D1) != _at(D2));
    }

    /// @dev A conduit homed on a first-generation chain bootstraps a second-generation one. The
    ///      home derives the receiver under the destination's transceiver, the destination
    ///      accepts the carried transmitter because it matches what the registry says the home
    ///      derives, and the two conduits sit at different addresses.
    function test_aFirstGenerationChainBootstrapsASecondGenerationOne() public {
        uint256 world = vm.snapshotState();
        (Sym eth, ChainRegistry ethRegistry) = _chain(ETH, D1, true);
        address transmitter = _bootstrap(eth, OP);
        bytes memory sent = eth.sentPayload();
        assertEq(eth.sentRecipient(), Erc7930.encodeEvm(OP, _at(D2)), "to the transceiver the registry predicts");
        address predictedReceiver =
            ethRegistry.predictCrossConduit(_key(OP), ext(address(eth)).messageProvider(), alice, SALT, _key(ETH));

        vm.revertToState(world);
        (Sym op,) = _chain(OP, D2, true);
        op.arrive(_route(ETH), abi.encodePacked(_at(D1)), sent);

        address receiver = ext(address(op)).predictCrossConduit(alice, SALT, _key(ETH));
        assertEq(receiver, predictedReceiver, "where the home predicted it");
        assertTrue(receiver != transmitter, "not at its transmitter's address");
        assertEq(ReceiverBase(payable(receiver)).sourceTransmitter(), transmitter, "and answers to it");
    }

    function test_aSecondGenerationChainBootstrapsAFirstGenerationOne() public {
        uint256 world = vm.snapshotState();
        (Sym op,) = _chain(OP, D2, true);
        address transmitter = _bootstrap(op, ETH);
        bytes memory sent = op.sentPayload();
        assertEq(op.sentRecipient(), Erc7930.encodeEvm(ETH, _at(D1)), "to the first generation's address");

        vm.revertToState(world);
        (Sym eth,) = _chain(ETH, D1, true);
        eth.arrive(_route(OP), abi.encodePacked(_at(D2)), sent);

        address receiver = ext(address(eth)).predictCrossConduit(alice, SALT, _key(OP));
        assertEq(ReceiverBase(payable(receiver)).sourceTransmitter(), transmitter);
    }

    function test_twoChainsOfOneGenerationStillShareAnAddress() public {
        uint256 world = vm.snapshotState();
        (Sym base,) = _chain(BASE, D1, true);
        address transmitter = _bootstrap(base, ETH);
        bytes memory sent = base.sentPayload();

        vm.revertToState(world);
        (Sym eth,) = _chain(ETH, D1, true);
        eth.arrive(_route(BASE), abi.encodePacked(address(eth)), sent);
        assertEq(ext(address(eth)).predictCrossConduit(alice, SALT, _key(BASE)), transmitter, "one address");
    }

    /// @dev A sender is authenticated at the address its own generation puts it at, so the other
    ///      generation's address, or this chain's own, is no counterpart.
    function test_aSenderAtTheWrongGenerationsAddressIsRefused() public {
        uint256 world = vm.snapshotState();
        (Sym op,) = _chain(OP, D2, true);
        _bootstrap(op, ETH);
        bytes memory sent = op.sentPayload();

        vm.revertToState(world);
        (Sym eth,) = _chain(ETH, D1, true);
        bytes memory sender = abi.encodePacked(_at(D1));
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.NotCounterpart.selector, _key(OP)));
        eth.arrive(_route(OP), sender, sent);
    }

    /// @dev The transmitter a bootstrap carries must be the one the home derives. One derived
    ///      under the wrong generation of the home's transceiver is refused, so a receiver is never
    ///      answerable to a conduit its home did not create.
    function test_aCarriedTransmitterFromTheWrongGenerationIsRefused() public {
        (Sym op,) = _chain(OP, D2, true);
        address derivedUnderAnotherGeneration = ext(address(op)).predictCrossConduit(alice, SALT, _key(ETH));
        address expected = _expectedTransmitterOnEth();
        assertTrue(expected != derivedUnderAnotherGeneration);

        bytes memory forged =
            Envelope.encodeBootstrap(alice, SALT, bytes32(uint256(uint160(derivedUnderAnotherGeneration))), _calls());
        bytes memory sender = abi.encodePacked(_at(D1));
        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverCore.SourceTransmitterMismatch.selector, expected, derivedUnderAnotherGeneration
            )
        );
        op.arrive(_route(ETH), sender, forged);
    }

    function _expectedTransmitterOnEth() internal returns (address transmitter) {
        uint256 world = vm.snapshotState();
        (Sym eth,) = _chain(ETH, D1, true);
        transmitter = ext(address(eth)).predictTransmitter(alice, SALT);
        vm.revertToState(world);
        vm.chainId(OP);
    }

    /* ================================ the live gate ============================== */

    /// @dev Nothing is sent to a chain whose transceiver is not marked live, a bootstrap or its
    ///      quote, and both succeed once it is.
    function test_aBootstrapAndItsQuoteAreRefusedUntilTheChainIsLive() public {
        (Sym eth, ChainRegistry registry) = _chain(ETH, D1, false);
        address transmitter = ext(address(eth)).predictTransmitter(alice, SALT);
        bytes memory notLive = abi.encodeWithSelector(OutboundBase.DestinationNotLive.selector, _key(OP));

        vm.expectRevert(notLive);
        eth.quoteBootstrap(_key(OP), alice, SALT, _calls(), new bytes[](0));
        vm.deal(transmitter, 1 ether);
        vm.prank(transmitter);
        vm.expectRevert(notLive);
        eth.bootstrap(_key(OP), alice, SALT, _calls(), new bytes[](0));
        assertFalse(eth.isLive(_key(OP)));

        registry.markLive(_key(OP), ext(address(eth)).messageProvider());
        assertTrue(eth.isLive(_key(OP)));
        _bootstrap(eth, OP);
        assertEq(eth.sentCount(), 1);
    }

    /// @dev A chain added under the old deployer and not yet deployed is rekeyed after a rotation.
    ///      While it is pending nothing is sent, and once live the destination is the new
    ///      deployer's address and never the retired key's.
    function test_aChainRekeyedAfterRotationIsSentToAtTheNewDeployersAddress() public {
        (Sym eth, ChainRegistry registry) = _chain(ETH, D1, false);
        bytes32 provider = ext(address(eth)).messageProvider();
        registry.rekeyPending(_key(BASE), provider, D2);
        assertEq(registry.predictTransceiver(_key(BASE), provider), _at(D2), "the retired key's address is dropped");

        vm.expectRevert(abi.encodeWithSelector(OutboundBase.DestinationNotLive.selector, _key(BASE)));
        eth.quoteBootstrap(_key(BASE), alice, SALT, _calls(), new bytes[](0));

        registry.markLive(_key(BASE), provider);
        _bootstrap(eth, BASE);
        assertEq(eth.sentRecipient(), Erc7930.encodeEvm(BASE, _at(D2)));
        assertTrue(keccak256(eth.sentRecipient()) != keccak256(Erc7930.encodeEvm(BASE, _at(D1))));
    }
}
