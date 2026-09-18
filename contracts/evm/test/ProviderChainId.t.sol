// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";

/// @notice A harness exposing the internal seam, standing in for a real binding's typed
///         `setEid`/`setSelector`/`setDomain` wrapper. The mixin does not know or care which
///         provider calls it; this harness exercises it directly, the way each binding's own
///         test suite exercises it through its typed wrapper instead.
contract ProviderChainIdHarness is ProviderChainId {
    function setProviderId(bytes32 chainKey, uint256 providerId) external {
        _setProviderId(chainKey, providerId);
    }

    function providerIdFor(bytes32 chainKey) external view returns (uint256) {
        return _providerIdFor(chainKey);
    }

    function chainKeyOfProvider(uint256 providerId) external view returns (bytes32) {
        return _chainKeyOfProvider(providerId);
    }
}

contract ProviderChainIdTest is Test {
    ProviderChainIdHarness table;

    bytes32 constant BASE_KEY = keccak256("base");
    bytes32 constant ARB_KEY = keccak256("arbitrum");

    function setUp() public {
        table = new ProviderChainIdHarness();
    }

    function test_recordsBothDirections() public {
        table.setProviderId(BASE_KEY, 30184);

        assertEq(table.providerIdFor(BASE_KEY), 30184);
        assertEq(table.chainKeyOfProvider(30184), BASE_KEY);
        assertTrue(table.hasProviderId(BASE_KEY));
    }

    /// @dev A replayed configuration transaction is not a failure, mirroring
    ///      `OutboundBase._setRoute`'s own idempotent-same-value shape.
    function test_settingTheSameIdTwiceIsANoOp() public {
        table.setProviderId(BASE_KEY, 30184);
        table.setProviderId(BASE_KEY, 30184);

        assertEq(table.providerIdFor(BASE_KEY), 30184);
    }

    /// @dev Repointing would resolve every future send to a different remote endpoint than
    ///      every prior one addressed: a redeploy, not a config edit.
    function test_settingADifferentIdReverts() public {
        table.setProviderId(BASE_KEY, 30184);

        vm.expectRevert(
            abi.encodeWithSelector(ProviderChainId.ProviderIdAlreadySet.selector, BASE_KEY)
        );
        table.setProviderId(BASE_KEY, 99);
    }

    /// @dev Two chains sharing one provider id would let an inbound delivery from either be
    ///      attributed to the other: the reverse index has to be injective.
    function test_twoChainsCannotShareOneProviderId() public {
        table.setProviderId(BASE_KEY, 30184);

        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.ProviderIdInUse.selector, 30184));
        table.setProviderId(ARB_KEY, 30184);
    }

    function test_zeroChainKeyReverts() public {
        vm.expectRevert(ProviderChainId.NoDestination.selector);
        table.setProviderId(bytes32(0), 30184);
    }

    /// @dev Zero is the unset sentinel on both sides, so it can never be a valid input: no
    ///      provider in scope names a live chain 0.
    function test_zeroProviderIdReverts() public {
        vm.expectRevert(ProviderChainId.ZeroProviderId.selector);
        table.setProviderId(BASE_KEY, 0);
    }

    function test_unconfiguredChainKeyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ProviderChainId.NoProviderIdFor.selector, BASE_KEY)
        );
        table.providerIdFor(BASE_KEY);
    }

    function test_unknownProviderIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ProviderChainId.UnknownProviderId.selector, 30184));
        table.chainKeyOfProvider(30184);
    }

    /// @dev The three real widths this mixin has to hold without narrowing: LayerZero's
    ///      uint32 eid, CCIP's uint64 selector, Hyperlane's uint32 domain.
    function test_holdsEveryProviderWidthWithoutNarrowing() public {
        table.setProviderId(BASE_KEY, uint256(type(uint32).max));
        assertEq(table.providerIdFor(BASE_KEY), uint256(type(uint32).max));

        table.setProviderId(ARB_KEY, uint256(type(uint64).max));
        assertEq(table.providerIdFor(ARB_KEY), uint256(type(uint64).max));
    }
}
