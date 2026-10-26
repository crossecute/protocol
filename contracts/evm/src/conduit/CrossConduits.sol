// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ICrossProxy} from "src/conduit/CrossProxy.sol";
import {CrossProxyInitCode} from "src/conduit/CrossProxyInitCode.sol";

/// @title CrossConduits
/// @notice The steps every contract that creates conduits takes, in this order: refuse an
///         occupied address, deploy `CrossProxy` by CREATE2, check it landed at the predicted
///         address, then arm and lock it.
///
/// @dev Separate functions rather than one, so a creator on a chain that deploys differently
///      (zkSync) replaces only `deploy`, and so a creator builds its initializer only after the
///      address check, which then reports a mismatch before anything the initializer reads.
library CrossConduits {
    error CrossConduitExists(address owner, bytes32 salt, address conduit);
    /// @dev The prediction and the deployment disagree: a variant on a diverging chain changed
    ///      one and not the other.
    error ConduitAddressMismatch(address predicted, address deployed);

    function requireVacant(address conduit, address owner, bytes32 salt) internal view {
        if (conduit.code.length != 0) revert CrossConduitExists(owner, salt, conduit);
    }

    /// @notice CREATE2 of `CrossProxy`'s initcode, read from the contract `CrossProxyInitCode`
    ///         stored it in.
    function deploy(bytes32 salt, address initCodeStore) internal returns (address) {
        return Create2.deploy(0, salt, CrossProxyInitCode.load(initCodeStore));
    }

    /// @dev Every address the protocol publishes comes from the prediction, so a deployment
    ///      elsewhere reverts here with a reason rather than failing later without one.
    function requireLanded(address predicted, address deployed) internal pure {
        if (deployed != predicted) revert ConduitAddressMismatch(predicted, deployed);
    }

    /// @notice Arm and lock the proxy in one call, so it never has logic and a live upgrade key
    ///         at once.
    function arm(address conduit, address implementation, bytes memory initializer) internal {
        ICrossProxy(conduit).upgradeInitializeAndLock(implementation, initializer);
    }
}
