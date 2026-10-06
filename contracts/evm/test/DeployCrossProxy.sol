// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {crossProxyDeployer} from "script/deploy/CrossProxyDeploy.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";

/// @notice A transceiver as production deploys one: a `CrossProxy` armed with `implementation`
///         and locked in the deploying call. Salted by the implementation, which each fixture
///         deploys fresh, so two fixtures in one test do not collide.
function deployTransceiver(address implementation, bytes memory data) returns (address) {
    return crossProxyDeployer().deploy(bytes32(uint256(uint160(implementation))), implementation, data);
}

/// @notice An account as a transceiver deploys one: a `CrossProxy` whose deployer, here the
///         calling test, arms it with `implementation` and locks it in one call. The proxy
///         exists before its initializer runs, so a payload calling back into it sees code.
function deployAccount(address implementation, bytes memory data) returns (address proxy) {
    proxy = address(new CrossProxy());
    ICrossProxy(proxy).upgradeInitializeAndLock(implementation, data);
}
