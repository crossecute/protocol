// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {CrossProxyDeployer} from "src/account/CrossProxyDeployer.sol";

address constant ARACHNID = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

/// @notice `CrossProxyDeployer` where production puts it: through Arachnid's factory at salt
///         zero. Deployed on first use.
function crossProxyDeployer() returns (CrossProxyDeployer) {
    bytes memory initCode = type(CrossProxyDeployer).creationCode;
    address at = Create2.computeAddress(bytes32(0), keccak256(initCode), ARACHNID);
    if (at.code.length == 0) {
        (bool ok,) = ARACHNID.call(abi.encodePacked(bytes32(0), initCode));
        require(ok, "arachnid");
    }
    return CrossProxyDeployer(at);
}

/// @notice A transceiver as production deploys one: a `CrossProxy` armed with `implementation`
///         and locked in the deploying call. Salted by the implementation, which each fixture
///         deploys fresh, so two fixtures in one test do not collide.
function deployTransceiver(address implementation, bytes memory data) returns (address) {
    return crossProxyDeployer().deploy(bytes32(uint256(uint160(implementation))), implementation, data);
}
