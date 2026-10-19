// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {CROSS_PROXY_DEPLOYER, CrossProxyDeployer} from "src/account/CrossProxyDeployer.sol";

/// @dev Shared by every deploy, in tests and on chain, so a check written here holds in both.
///      Forge runs both, so the cheatcode address is present to read proxy slots.
Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

address constant ARACHNID = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

/// @notice A deploy check failed; `what` names the property.
error DeployCheck(string what);

function check(bool ok, string memory what) pure {
    if (!ok) revert DeployCheck(what);
}

/// @notice `initCode` deployed through Arachnid's factory at salt zero, on first use, so it sits
///         at one address on every chain that runs the same initcode.
function arachnidDeploy(bytes memory initCode) returns (address at) {
    at = Create2.computeAddress(bytes32(0), keccak256(initCode), ARACHNID);
    if (at.code.length == 0) {
        check(ARACHNID.code.length != 0, "Arachnid's factory is deployed");
        (bool ok,) = ARACHNID.call(abi.encodePacked(bytes32(0), initCode));
        check(ok && at.code.length != 0, "deployed through Arachnid's factory");
    }
}

/// @notice `CrossProxyDeployer` where production puts it: through Arachnid's factory at salt
///         zero, deployed on first use, which is `CROSS_PROXY_DEPLOYER`.
/// @dev `forge coverage` builds unoptimized, so its deployer lands elsewhere; it is copied to
///      `CROSS_PROXY_DEPLOYER`, which is sound because the deployer holds no storage. Never true
///      in a broadcast.
function crossProxyDeployer() returns (CrossProxyDeployer) {
    address at = arachnidDeploy(type(CrossProxyDeployer).creationCode);
    if (at != CROSS_PROXY_DEPLOYER && VM.isContext(VmSafe.ForgeContext.Coverage)) {
        if (CROSS_PROXY_DEPLOYER.code.length == 0) VM.etch(CROSS_PROXY_DEPLOYER, at.code);
        at = CROSS_PROXY_DEPLOYER;
    }
    return CrossProxyDeployer(at);
}

/// @notice Deploy a `CrossProxy` for `deployedBy` at `salt`, armed with `implementation` and
///         `data` and locked in the same call.
/// @param deployedBy The account making the `deploy` call: the test contract, or the
///        broadcaster. It is hashed into the address, so naming the wrong one fails here.
function deployCrossProxy(address deployedBy, bytes32 salt, address implementation, bytes memory data)
    returns (address proxy)
{
    check(implementation.code.length != 0, "implementation has code");
    CrossProxyDeployer deployer = crossProxyDeployer();
    address predicted = deployer.predict(deployedBy, salt);
    proxy = deployer.deploy(salt, implementation, data);
    check(proxy == predicted, "proxy is where deployedBy and salt predict");
    check(_slot(proxy, ERC1967Utils.IMPLEMENTATION_SLOT) == implementation, "proxy runs the implementation");
    check(_slot(proxy, ERC1967Utils.ADMIN_SLOT) == address(0), "proxy is locked");
}

function _slot(address proxy, bytes32 slot) view returns (address) {
    return address(uint160(uint256(VM.load(proxy, slot))));
}
