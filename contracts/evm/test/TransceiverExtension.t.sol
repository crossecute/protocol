// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {
    DivergentTransceiver,
    TronTransceiver,
    TronTransceiverExtension
} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {transceiverConfig, ext} from "test/Harness.sol";

/// @dev The send seams, unused here.
abstract contract Unsent is TransceiverBase {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        revert();
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal pure override returns (uint256) {
        revert();
    }
}

/// @dev A plain transceiver paired with whichever extension the test names.
contract PairedPlain is Unsent {
    constructor(address extension_) TransceiverBase(extension_) {}

    function initialize(TransceiverConfig memory c) external initializer {
        __TransceiverBase_init(c);
    }
}

/// @dev A Tron transceiver paired with whichever extension the test names.
contract PairedTron is TronTransceiver, Unsent {
    constructor(address extension_) TransceiverBase(extension_) {}

    function initialize(TransceiverConfig memory c) external initializer {
        __DivergentTransceiver_init(c, keccak256("tron-solc CrossProxy"));
    }

    function _predictCrossConduit(address owner, bytes32 salt, bytes32 homeChainKey)
        internal
        view
        override(TransceiverCore, TronTransceiver)
        returns (address)
    {
        return super._predictCrossConduit(owner, salt, homeChainKey);
    }

    function _parityAddress(bytes32 chainKey)
        internal
        view
        override(TransceiverCore, DivergentTransceiver)
        returns (address)
    {
        return super._parityAddress(chainKey);
    }
}

/// @dev Calls `initializeBase` on a transceiver from outside it.
contract InitCaller {
    function initializeBaseOf(address transceiver, TransceiverConfig memory c) external {
        TransceiverExtension(transceiver).initializeBase(c, false);
    }
}

/// @dev Reaches `initializeBase` while its own initializer is open, from another contract.
contract ReenteredInit is Unsent {
    constructor(address extension_) TransceiverBase(extension_) {}

    function initialize(TransceiverConfig memory c, InitCaller caller) external initializer {
        caller.initializeBaseOf(address(this), c);
    }
}

/// @notice The pairing a transceiver and its extension must hold, and the extension's refusals
///         when reached any way but through its transceiver.
contract TransceiverExtensionTest is Test {
    address governor = address(0x5165);

    function _config() internal pure returns (TransceiverConfig memory) {
        return transceiverConfig(address(0x5165), address(0xBEEF), address(0xBEE2), address(0x7EA5));
    }

    function test_aMatchedPairInitializes() public {
        PairedPlain plain = new PairedPlain(address(new TransceiverExtension()));
        plain.initialize(_config());
        PairedTron tron = new PairedTron(address(new TronTransceiverExtension()));
        tron.initialize(_config());

        bytes32 governorHome = keccak256(_config().governorHome);
        assertEq(plain.owner(), ext(address(plain)).predictCrossConduit(governor, bytes32(0), governorHome));
        assertEq(tron.owner(), ext(address(tron)).predictCrossConduit(governor, bytes32(0), governorHome));
        assertTrue(plain.owner() != tron.owner(), "the two formulas differ, so a mismatch is visible");
    }

    /// @dev The extension derives the owner, so one of another chain type would arm every
    ///      conduit at an address this contract never creates.
    function test_anExtensionOfAnotherChainTypeIsRefused() public {
        PairedTron tron = new PairedTron(address(new TransceiverExtension()));
        vm.expectRevert(TransceiverBase.ExtensionMismatch.selector);
        tron.initialize(_config());

        PairedPlain plain = new PairedPlain(address(new TronTransceiverExtension()));
        vm.expectRevert(TransceiverBase.ExtensionMismatch.selector);
        plain.initialize(_config());
    }

    function test_anExtensionDeployedUnderAnotherChainIdIsRefused() public {
        uint256 here = block.chainid;
        vm.chainId(10);
        address elsewhere = address(new TransceiverExtension());
        vm.chainId(here);

        PairedPlain plain = new PairedPlain(elsewhere);
        vm.expectRevert(TransceiverBase.ExtensionMismatch.selector);
        plain.initialize(_config());
    }

    /// @dev The fallback admits anyone, so while the transceiver is initializing only its own
    ///      call may configure it.
    function test_initializeBaseRefusesAnyCallerButTheTransceiver() public {
        InitCaller caller = new InitCaller();
        ReenteredInit t = new ReenteredInit(address(new TransceiverExtension()));
        vm.expectRevert(abi.encodeWithSelector(TransceiverExtension.NotSelf.selector, address(caller)));
        t.initialize(_config(), caller);
    }

    function test_initializeBaseClosesWithInitialization() public {
        PairedPlain plain = new PairedPlain(address(new TransceiverExtension()));
        plain.initialize(_config());

        vm.expectRevert(Initializable.NotInitializing.selector);
        ext(address(plain)).initializeBase(_config(), false);
        vm.prank(address(plain));
        vm.expectRevert(Initializable.NotInitializing.selector);
        ext(address(plain)).initializeBase(_config(), false);
    }

    /// @dev Called directly, the extension runs on its own storage: no owner, no treasury, and
    ///      initialization disabled.
    function test_theExtensionAloneFailsClosed() public {
        TransceiverExtension e = new TransceiverExtension();

        vm.prank(address(e));
        vm.expectRevert(Initializable.NotInitializing.selector);
        e.initializeBase(_config(), false);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        e.setRouting(IChainRegistryRefs(address(0xDEED)), bytes32(0), Provenance.Predetermined);

        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.NotTreasury.selector, address(this)));
        e.withdraw(0);

        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.NotOwnerOrOperator.selector, address(this)));
        e.setBootstrapFee(bytes32(0), 1);
    }

    function test_aSelectorNeitherDeclaresReverts() public {
        PairedPlain plain = new PairedPlain(address(new TransceiverExtension()));
        plain.initialize(_config());

        (bool ok, bytes memory data) = address(plain).call(abi.encodeWithSignature("nothing()"));
        assertFalse(ok);
        assertEq(data.length, 0);
    }
}
