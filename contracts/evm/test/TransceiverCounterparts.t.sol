// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {deployTransceiver} from "test/DeployCrossProxy.sol";

import {ChainType} from "src/addressing/ChainType.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Move} from "src/addressing/Move.sol";
import {MoveValidator} from "src/validators/MoveValidator.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {OwnedTransceiver} from "test/Unsendable.sol";

/// @notice The counterpart directory after it moved off the registry.
///
/// @dev The split is the point, and it is one line. The transceiver holds where a counterpart is,
///      because that is per provider, and two providers put two transceivers on one chain.
///      The registry holds what a claim about that chain is worth, because that is the same
///      question for every provider, and two transceivers must not answer it differently.
contract TransceiverCounterpartsTest is Test {
    ChainRegistry registry;
    OwnedTransceiver transceiver;

    address owner = address(0xA11CE);
    bytes32 suiChainKey;
    bytes32 provider;
    bytes suiInterop;

    function setUp() public {
        registry = new ChainRegistry(owner, unseeded());
        transceiver = OwnedTransceiver(
            payable(deployTransceiver(
                    address(new OwnedTransceiver()), abi.encodeCall(OwnedTransceiver.initialize, (owner))
                ))
        );

        bytes memory suiChain = Erc7930.encodeChainId(ChainType.SUI, bytes("mainnet"));
        suiInterop = Erc7930.encode(ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("pkg")));

        vm.startPrank(owner);
        suiChainKey = registry.addChainKey(suiChain, Provenance.Unique);
        registry.setValidator(suiChainKey, new MoveValidator());
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(transceiver));
        transceiver.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        vm.stopPrank();
    }

    function _qualifier() internal pure returns (Move.MoveQualifier memory q) {
        q.kind = Move.MoveKind.Entry;
        q.moduleName = "transceiver";
        q.functionName = "receive_message";
    }

    /* ============================== the directory =============================== */

    function test_theTransceiverHoldsTheAddressAndTheRegistryTheGrade() public {
        vm.prank(owner);
        transceiver.setCounterpart(suiChainKey, suiInterop);

        assertEq(transceiver.counterpartOn(suiChainKey), Erc7930.parseStrict(suiInterop).addr);
        assertEq(uint8(registry.provenanceFor(suiChainKey)), uint8(Provenance.Unique));
    }

    /// @dev Two providers, two addresses, one grade. That is the whole reason the two halves
    ///      live where they do: a second transceiver records its own address on the same chain
    ///      without displacing the first, and neither can decide the chain is worth more
    ///      than the registry says.
    function test_twoTransceiversHoldSeparateAddressesAndShareTheGrade() public {
        OwnedTransceiver second = OwnedTransceiver(
            payable(deployTransceiver(
                    address(new OwnedTransceiver()), abi.encodeCall(OwnedTransceiver.initialize, (owner))
                ))
        );
        bytes memory other = Erc7930.encode(ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("other")));

        vm.startPrank(owner);
        bytes32 p2 = registry.addMessageProvider("hyperlane");
        second.setRouting(IChainRegistryRefs(address(registry)), p2, Provenance.Unique);
        transceiver.setCounterpart(suiChainKey, suiInterop);
        second.setCounterpart(suiChainKey, other);
        vm.stopPrank();

        assertTrue(
            keccak256(transceiver.counterpartOn(suiChainKey)) != keccak256(second.counterpartOn(suiChainKey)),
            "each provider its own transceiver"
        );
        assertEq(
            uint8(registry.provenanceFor(suiChainKey)),
            uint8(Provenance.Unique),
            "one grade, and neither transceiver can move it"
        );
    }

    function test_aCounterpartIsWriteOnce() public {
        bytes memory other = Erc7930.encode(ChainType.SUI, bytes("mainnet"), abi.encodePacked(keccak256("other")));
        vm.startPrank(owner);
        transceiver.setCounterpart(suiChainKey, suiInterop);
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.CounterpartAlreadySet.selector, suiChainKey));
        transceiver.setCounterpart(suiChainKey, other);
        vm.stopPrank();
    }

    function test_settingACounterpartIsAdminGated() public {
        vm.expectRevert();
        transceiver.setCounterpart(suiChainKey, suiInterop);
    }

    /// @dev The validator stayed on the registry when the storage left, because what makes
    ///      an address well-formed is a property of the chain. One validator per chain
    ///      serves every provider's transceiver rather than each carrying its own copy.
    function test_theChainsValidatorStillRuns() public {
        // 31 bytes: a Move address is 32, and the envelope alone cannot express that.
        bytes memory short = Erc7930.encode(ChainType.SUI, bytes("mainnet"), new bytes(31));
        vm.prank(owner);
        vm.expectRevert();
        transceiver.setCounterpart(suiChainKey, short);
    }

    function test_aCounterpartOnTheWrongChainIsRefused() public {
        vm.startPrank(owner);
        registry.addChainKey(Erc7930.encodeEvmChain(1), Provenance.Predetermined);
        vm.expectRevert(ChainRegistry.UnknownChainKey.selector);
        transceiver.setCounterpart(suiChainKey, Erc7930.encodeEvm(1, address(0xCAFE)));
        vm.stopPrank();
    }

    /* ============================== Move qualifiers ============================= */

    /// @dev A Move call target is `address::module::function`, so the address alone does not
    ///      name it. The registry holds the rest per provider: nothing on-chain reads it, and a
    ///      transceiver has no room for it (#29).
    function test_aQualifierIsRecordedPerProvider() public {
        vm.prank(owner);
        registry.setQualifier(suiChainKey, provider, _qualifier());

        assertEq(registry.qualifier(suiChainKey, provider).functionName, "receive_message");
    }

    function test_aQualifierNeedsARegisteredProvider() public {
        bytes32 unknown = keccak256("unknown");
        Move.MoveQualifier memory q = _qualifier();
        vm.prank(owner);
        vm.expectRevert(ChainRegistry.UnknownMessageProvider.selector);
        registry.setQualifier(suiChainKey, unknown, q);
    }

    /// @dev Validated against the chain it sits on, so a malformed Move identifier never
    ///      lands and an EVM chain cannot acquire one.
    function test_aMalformedQualifierIsRefused() public {
        Move.MoveQualifier memory q = _qualifier();
        q.moduleName = "not a module name";

        vm.prank(owner);
        vm.expectRevert(Move.BadIdentifier.selector);
        registry.setQualifier(suiChainKey, provider, q);
    }

    function test_anEvmChainCannotHaveAQualifier() public {
        vm.startPrank(owner);
        bytes32 baseKey = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Predetermined);
        vm.expectRevert(Move.NotMoveChain.selector);
        registry.setQualifier(baseKey, provider, _qualifier());
        vm.stopPrank();
    }

    /// @dev Re-setting the same qualifier is a no-op; a different one reverts, because
    ///      re-pointing a live call target is the same operation as re-pointing the address.
    function test_theQualifierIsIdempotentButNotRepointable() public {
        Move.MoveQualifier memory q = _qualifier();
        vm.startPrank(owner);
        registry.setQualifier(suiChainKey, provider, q);
        registry.setQualifier(suiChainKey, provider, q);

        q.functionName = "something_else";
        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.setQualifier(suiChainKey, provider, q);
        vm.stopPrank();
    }

    function test_readingAnAbsentQualifierReverts() public {
        vm.expectRevert(ChainRegistry.NoQualifier.selector);
        registry.qualifier(suiChainKey, provider);
    }
}
