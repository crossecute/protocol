// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransceiverDeployment} from "script/deploy/TransceiverDeploy.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {IReceiverInit} from "src/messaging/inbound/ReceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";

/// @notice A transceiver configuration with no registry, homed on Ethereum.
function transceiverConfig(address receiverImplementation) pure returns (TransceiverConfig memory) {
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: address(0xBEEF),
        receiverImplementation: receiverImplementation,
        governorOwner: address(0x5165),
        governorSalt: bytes32(0),
        governorHome: Erc7930.encodeEvmChain(1),
        treasury: address(0x7EA5),
        chainRegistry: IChainRegistryRefs(address(0)),
        messageProvider: bytes32(0),
        minCounterpartProvenance: Provenance.Unknown
    });
}

function toBytes32(address a) pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
}

function defaultReceiverInit(address sourceTransmitter, Call[] memory calls) pure returns (bytes memory) {
    return abi.encodeCall(IReceiverInit.initialize, (sourceTransmitter, calls));
}

/// @title ProviderFixture
/// @notice One provider's mocks, deployments, and delivery path. Every spec in
///         `ProviderBindingSpec.t.sol` inherits this, and a provider's suites inherit its one
///         concrete fixture, so each fact about a provider is written once.
/// @dev No hook here has a default body: Solidity would then require every suite combining a
///      spec with a fixture that overrides it to restate the override.
abstract contract ProviderFixture is Test {
    /// @dev The chain every spec sends to and delivers from.
    uint256 internal constant REMOTE_CHAIN_ID = 8453;

    /// @notice A new implementation of the provider's plain transceiver, wrapped in its harness.
    function _transceiverImplementation() internal virtual returns (address);

    function _receiverImplementation() internal virtual returns (address);

    function _transmitterImplementation() internal virtual returns (address);

    /// @notice Deploy the plain transceiver through the provider's deploy script, naming
    ///         `homeId` as the governor home's provider id.
    function _deploy(TransceiverDeployment memory d, uint256 homeId) internal virtual returns (address);

    /// @notice The address the provider delivers through: its endpoint, router, mailbox, Core
    ///         bridge, or messenger.
    function _gateway() internal view virtual returns (address);

    /// @notice Deliver `message` to `to` through the provider's own path, from `sender` on the
    ///         chain the provider calls `originId`.
    /// @dev Makes exactly one external call, so an expected revert attaches to the delivery.
    function _deliver(address to, uint256 originId, bytes32 sender, bytes memory message) internal virtual;

    /// @notice Call `to`'s delivery entry point directly, from `REMOTE_CHAIN_ID`, rather than
    ///         through the provider. One external call.
    function _deliverBypassingGateway(address to, bytes32 sender, bytes memory message) internal virtual;

    function _setProviderFee(uint256 fee) internal virtual;

    /// @notice What a quote names when the provider's mocks charge `providerFee`.
    function _expectedQuoteFor(uint256 providerFee) internal view virtual returns (uint256);

    /// @notice The provider's id for `REMOTE_CHAIN_ID`; zero for a provider with no id table.
    function _remoteProviderId() internal pure virtual returns (uint256);

    /// @notice Provider-side configuration of transceiver `t` to send to and accept from
    ///         `counterpart` on `REMOTE_CHAIN_ID`, as `t`'s owner.
    function _configureRemote(address t, address counterpart) internal virtual;

    /// @notice The receiver initializer; `defaultReceiverInit` for all but LayerZero.
    function _initializeReceiver(address sourceTransmitter, Call[] memory calls)
        internal
        view
        virtual
        returns (bytes memory);

    function _config() internal returns (TransceiverConfig memory) {
        return transceiverConfig(_receiverImplementation());
    }

    /// @notice A deployment from this contract, salted by the implementation, which each
    ///         fixture deploys fresh, so two deployments in one test do not collide.
    function _deployment(address implementation, TransceiverConfig memory c)
        internal
        view
        returns (TransceiverDeployment memory)
    {
        return TransceiverDeployment({
            deployedBy: address(this),
            salt: bytes32(uint256(uint160(implementation))),
            implementation: implementation,
            config: c
        });
    }

    function _deployTransceiver(TransceiverConfig memory c, uint256 homeId) internal returns (address) {
        return _deploy(_deployment(_transceiverImplementation(), c), homeId);
    }
}

/// @notice For providers whose transceiver keeps a provider id table.
abstract contract ProviderIdFixture is ProviderFixture {
    /// @notice Call `t`'s typed id setter, as whoever the caller pranks.
    function _setProviderId(address t, bytes32 chainKey, uint256 providerId) internal virtual;

    /// @notice Set `t`'s id for `REMOTE_CHAIN_ID`, as its owner.
    function _setRemoteProviderId(address t) internal {
        vm.prank(TransceiverBase(payable(t)).owner());
        _setProviderId(t, ChainKey.forEvm(REMOTE_CHAIN_ID), _remoteProviderId());
    }
}

/// @notice For providers whose sends carry a destination gas limit: every one but
///         `op-stack-l2-l2`, whose relayer chooses the gas.
abstract contract ProviderGasFixture is ProviderIdFixture {
    /// @notice The destination gas the provider recorded for the last send.
    function _lastGasLimit() internal view virtual returns (uint256);

    /// @notice An attribute asking for `gas`, in the binding's own format.
    function _gasAttribute(uint256 gas) internal pure virtual returns (bytes memory);

    /// @notice The big-endian unsigned integer `width` bytes long at `offset` in `b`.
    function _uintAt(bytes memory b, uint256 offset, uint256 width) internal pure returns (uint256 v) {
        for (uint256 i; i < width; ++i) {
            v = (v << 8) | uint8(b[offset + i]);
        }
    }
}
