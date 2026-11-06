// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {proxyDeployer} from "script/deploy/ProxyDeploy.sol";
import {Proxy, IProxy} from "src/conduit/Proxy.sol";

/// @notice A transceiver as production deploys one: a `Proxy` armed with `implementation`
///         and locked in the deploying call. Salted by the implementation, which each fixture
///         deploys fresh, so two fixtures in one test do not collide.
function deployTransceiver(address implementation, bytes memory data) returns (address) {
    return proxyDeployer().deploy(bytes32(uint256(uint160(implementation))), implementation, data);
}

/// @notice A conduit as a transceiver deploys one: a `Proxy` whose deployer, here the
///         calling test, arms it with `implementation` and locks it in one call. The proxy
///         exists before its initializer runs, so a payload calling back into it sees code.
function deployConduit(address implementation, bytes memory data) returns (address proxy) {
    proxy = address(new Proxy());
    IProxy(proxy).upgradeInitializeAndLock(implementation, data);
}
