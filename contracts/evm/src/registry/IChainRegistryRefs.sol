// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Provenance} from "src/registry/Provenance.sol";

/// @notice The CREATE2 inputs a message provider's contracts share on every chain.
///
/// @dev The caller that deploys a transceiver is per (provider, chain), held by the registry: one
///      salt and caller put a transceiver at one address, and a rotated deployer moves only the
///      chains added after it. The salt can be mined for leading zero bytes, which are cheaper in
///      the calldata that names the address.
struct ProviderDeployment {
    /// The mined salt every deployer passes to `LockedProxyDeployer.deploy`.
    bytes32 salt;
    /// keccak256 of `LockedProxy`'s initcode as solc builds it: transceivers and conduits are
    /// both `LockedProxy`. Recorded rather than computed, since a zkSync or Tron registry's
    /// own compiler builds a different one.
    bytes32 lockedProxyInitCodeHash;
}

/// @notice Whether sends may reach a provider's transceiver on a chain.
/// @dev `Pending` is recorded and predicted but not sent to; `Live` is set by the registry's owner
///      once the deployment there was checked independently of the deployer.
enum Status {
    None,
    Pending,
    Live
}

/// @notice The slice of `ChainRegistry` a transceiver needs: where remote things live, and how
///         much each claim about them is worth.
///
/// @dev Routes live on the transceiver. What it reads here is provenance, suspension, derived
///      counterpart addresses, location validation, and which chains must report their
///      receivers.
interface IChainRegistryRefs {
    /// @notice What an address claim about `chainKey` is worth. Chain-scoped, so every
    ///         provider's transceiver reads the same answer.
    function provenanceFor(bytes32 chainKey) external view returns (Provenance);

    /// @notice Whether every transceiver on this chain refuses `chainKey`.
    function isSuspended(bytes32 chainKey) external view returns (bool);

    /// @notice The transceiver address this registry recomputes for `chainKey`, from the
    ///         deriver and inputs recorded for that chain. A transceiver stores the result.
    function expectedTransceiver(bytes32 chainKey) external view returns (bytes memory);

    /// @notice The CREATE2 inputs `messageProvider`'s contracts share; a zero salt means none is
    ///         recorded.
    function providerDeployment(bytes32 messageProvider) external view returns (ProviderDeployment memory);

    /// @notice Where a provider's transceiver lands on `chainKey`, recomputed from the recorded
    ///         factory, that chain's deployer, salt, and initcode hash. Reverts for a chain not
    ///         graded `Predetermined`, and for one the provider was never added on.
    function predictTransceiver(bytes32 chainKey, bytes32 messageProvider) external view returns (address);

    /// @notice Whether sends to `messageProvider`'s transceiver on `chainKey` are allowed.
    function isLive(bytes32 chainKey, bytes32 messageProvider) external view returns (bool);

    /// @notice Who deployed, or will deploy, `messageProvider`'s transceiver on `chainKey`; zero
    ///         where it was never added.
    function deployedBy(bytes32 chainKey, bytes32 messageProvider) external view returns (address);

    /// @notice The deployer a provider added on a chain from now on is recorded under.
    function currentDeployer() external view returns (address);

    /// @notice The canonical ERC-7930 chain identifier `chainKey` hashes from.
    function chainIdentifier(bytes32 chainKey) external view returns (bytes memory);

    /// @notice Reverts unless `interop` is a well-formed address on `chainKey`.
    function validateLocation(bytes32 chainKey, bytes calldata interop) external view;

    /// @notice The derivation inputs recorded for `chainKey`. Hash this to build the
    ///         `paramsCommitment` a `resolveCounterpart` transaction must carry.
    function deriveParams(bytes32 chainKey) external view returns (bytes memory);

    /// @notice Whether conduits on `chainKey` must report their own address home, which is
    ///         the only thing this directory says about receivers. Where one actually landed
    ///         is held by the transmitter that sends to it.
    function requiresReceiverCallback(bytes32 chainKey) external view returns (bool);
}
