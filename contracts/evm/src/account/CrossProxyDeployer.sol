// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";

/// @notice The CREATE2 salt `CrossProxyDeployer` deploys under for `deployedBy`'s `salt`.
/// @dev The caller is hashed in so that nobody else can deploy at a caller's address first
///      with their own implementation. `ChainRegistry.predictTransceiver` derives with it.
function crossProxySalt(address deployedBy, bytes32 salt) pure returns (bytes32) {
    return keccak256(abi.encode(deployedBy, salt));
}

/// @title CrossProxyDeployer
/// @notice Deploys a `CrossProxy` and arms it in one call, so a transceiver has no window in
///         which another caller could install its logic.
///
/// @dev Deployed through Arachnid's factory with no constructor arguments, so it has one address
///      on every standard EVM chain, and every transceiver it deploys for one caller and salt
///      shares one address too. A `CrossProxy` makes its deployer its admin, which is why the
///      proxy cannot be deployed through Arachnid's factory directly: that factory makes no
///      calls and could never arm it.
contract CrossProxyDeployer {
    event Deployed(address indexed deployedBy, bytes32 salt, address proxy, address implementation);

    function deploy(bytes32 salt, address implementation, bytes calldata data) external returns (address proxy) {
        proxy = Create2.deploy(0, crossProxySalt(msg.sender, salt), type(CrossProxy).creationCode);
        ICrossProxy(proxy).upgradeInitializeAndLock(implementation, data);
        emit Deployed(msg.sender, salt, proxy, implementation);
    }

    function predict(address deployedBy, bytes32 salt) external view returns (address) {
        return Create2.computeAddress(crossProxySalt(deployedBy, salt), keccak256(type(CrossProxy).creationCode));
    }
}
