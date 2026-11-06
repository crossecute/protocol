// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Proxy, IProxy} from "src/conduit/Proxy.sol";

// Where `ProxyDeployer` sits: Arachnid's factory at salt zero, so the same address on every
// standard EVM chain. A `Predetermined` chain is one whose transceivers were deployed through it
// (#33). A literal, since a zkSync or Tron registry's compiler would derive another;
// `ProxyDeployer.t.sol` pins it to solc's build.
address constant PROXY_DEPLOYER = 0x415DaAF39EB13593a0Fe5E140bc97C4C9a63e116;

/// @notice The CREATE2 salt `ProxyDeployer` deploys under for `deployedBy`'s `salt`, where
///         `deployedBy` is the account that calls `deploy`.
/// @dev The caller is hashed in so that nobody else can deploy at a caller's address first
///      with their own implementation. `ChainRegistry.predictTransceiver` derives with it.
function proxySalt(address deployedBy, bytes32 salt) pure returns (bytes32) {
    return keccak256(abi.encode(deployedBy, salt));
}

/// @title ProxyDeployer
/// @notice Deploys a `Proxy` and arms it in one call, so a transceiver has no window in
///         which another caller could install its logic.
///
/// @dev Deployed through Arachnid's factory with no constructor arguments, so it has one address
///      on every standard EVM chain, and every transceiver it deploys for one caller and salt
///      shares one address too. A `Proxy` makes its deployer its admin, which is why the
///      proxy cannot be deployed through Arachnid's factory directly: that factory makes no
///      calls and could never arm it.
contract ProxyDeployer {
    event Deployed(address indexed deployedBy, bytes32 salt, address proxy, address implementation);

    function deploy(bytes32 salt, address implementation, bytes calldata data) external returns (address proxy) {
        proxy = Create2.deploy(0, proxySalt(msg.sender, salt), type(Proxy).creationCode);
        IProxy(proxy).upgradeInitializeAndLock(implementation, data);
        emit Deployed(msg.sender, salt, proxy, implementation);
    }

    function predict(address deployedBy, bytes32 salt) external view returns (address) {
        return Create2.computeAddress(proxySalt(deployedBy, salt), keccak256(type(Proxy).creationCode));
    }
}
