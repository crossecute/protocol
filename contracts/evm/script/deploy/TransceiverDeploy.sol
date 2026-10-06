// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ProviderDeployment} from "src/registry/IChainRegistryRefs.sol";
import {IProviderIdTable} from "src/protocols/ProviderChainId.sol";
import {check, deployCrossProxy} from "script/deploy/CrossProxyDeploy.sol";

/// @notice What every provider's transceiver deploy is given. The implementation is deployed
///         by the caller: production's, or a test's harness around it.
struct TransceiverDeployment {
    address deployedBy;
    bytes32 salt;
    address implementation;
    TransceiverConfig config;
}

/// @notice Deploy a provider's transceiver through `CrossProxyDeployer` and check what its
///         initializer must have established.
/// @param providerGateway The provider contract the initializer grants `GATEWAY_ROLE`, or zero
///        for a binding that checks its endpoint itself (LayerZero).
function deployTransceiverProxy(TransceiverDeployment memory d, bytes memory initData, address providerGateway)
    returns (address t)
{
    t = deployCrossProxy(d.deployedBy, d.salt, d.implementation, initData);
    checkTransceiver(t, d, providerGateway);
}

function checkTransceiver(address t, TransceiverDeployment memory d, address providerGateway) view {
    TransceiverBase tb = TransceiverBase(payable(t));
    TransceiverConfig memory c = d.config;
    bytes32 home = keccak256(c.governorHome);

    check(
        tb.owner() == tb.predictCrossAccount(c.governorOwner, c.governorSalt, home),
        "owner is the governor's account on its home"
    );
    check(tb.treasury() == c.treasury, "treasury");
    check(tb.transmitterImplementation() == c.transmitterImplementation, "transmitter implementation");
    check(tb.receiverImplementation() == c.receiverImplementation, "receiver implementation");
    for (uint256 i; i < c.gateways.length; ++i) {
        if (c.gateways[i] != address(0)) {
            check(tb.hasRole(tb.GATEWAY_ROLE(), c.gateways[i]), "listed gateway holds GATEWAY_ROLE");
        }
    }
    if (providerGateway != address(0)) {
        check(IAccessControl(t).hasRole(tb.GATEWAY_ROLE(), providerGateway), "provider gateway holds GATEWAY_ROLE");
    }
    if (home != tb.localChainKey()) {
        check(keccak256(tb.routeFor(home)) == home, "the governor's home is routed");
    }
    if (address(c.chainRegistry) != address(0)) {
        check(address(tb.chainRegistry()) == address(c.chainRegistry), "registry");
        check(tb.messageProvider() == c.messageProvider, "message provider");
        _checkDeploymentRecord(tb, d);
    }
}

/// @notice R8.4 and C21: where the registry records this provider's deployment, the
///         transceiver was deployed from exactly that record and sits where it predicts.
/// @dev A diverging chain derives addresses its own way and records solc's initcode hash,
///      not its own compiler's (#30), so neither comparison applies there.
function _checkDeploymentRecord(TransceiverBase tb, TransceiverDeployment memory d) view {
    ProviderDeployment memory r = tb.chainRegistry().providerDeployment(d.config.messageProvider);
    if (r.salt == bytes32(0) || tb.addressesDiverge()) return;
    check(r.deployedBy == d.deployedBy, "deployedBy is the recorded one");
    check(r.salt == d.salt, "salt is the recorded one");
    check(r.crossProxyInitCodeHash == tb.CROSS_PROXY_INIT_CODE_HASH(), "recorded initcode hash is solc's (R8.4)");
    // At deployment a registry knows only its seed's home, which it requires `Predetermined`
    // (§6 step 1), and the prediction is the same for every such chain.
    check(
        tb.chainRegistry().predictTransceiver(keccak256(d.config.governorHome), d.config.messageProvider)
            == address(tb),
        "transceiver is where the registry predicts"
    );
}

/// @notice For a binding with a provider id table: the governor home's id is named at birth.
function checkGovernorHomeId(address t, TransceiverConfig memory c, uint256 homeId) view {
    if (homeId == 0) return;
    check(IProviderIdTable(t).providerIdFor(keccak256(c.governorHome)) == homeId, "the governor home's provider id");
}
