// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {
    OAppReceiverUpgradeable,
    Origin
} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import {OAppCoreUpgradeable} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {LzHomePeer} from "src/protocols/layerzero/LzHomePeer.sol";

/// @dev Extends the base two-arg shape with the eid `sourceTransmitter` lives behind, so its
///      peer can be set in the same locked initializer call.
interface ILzReceiverInit {
    function initialize(address sourceTransmitter, Call[] calldata calls, uint32 homeEid) external;
}

/// @notice Per-user account on a non-home chain.
/// @dev Receiver-only: inherits `OAppReceiverUpgradeable`, not the combined `OAppUpgradeable`
///      — this contract never sends via LayerZero.
contract LzReceiver is ReceiverBase, OAppReceiverUpgradeable, LzHomePeer, ILzReceiverInit {
    constructor(address _endpoint) OAppCoreUpgradeable(_endpoint) {
        if (_endpoint == address(0)) revert ProviderAddress.ZeroEndpoint();
    }

    /// @dev Refused, not just unused: it would skip OApp setup entirely, permanently
    ///      bricking inbound (`NoPeer` forever, no reopening the init window).
    error UseLzInitializer();

    function initialize(address, Call[] calldata) external pure override {
        revert UseLzInitializer();
    }

    /// @dev Provider setup runs before `__ReceiverBase_init`, which executes the payload.
    function initialize(address sourceTransmitter_, Call[] calldata calls, uint32 homeEid)
        external
        override
        initializer
    {
        __OAppReceiver_init(address(this));
        grantRole(GATEWAY_ROLE, address(endpoint));
        _initHomePeer(homeEid, sourceTransmitter_);
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev R3.3 exception: `lzReceive` (not overridden) authenticates via `endpoint`+`peers`
    ///      before this runs, ahead of our own check. Defensible for a 1:1 pairing (one peer,
    ///      set once).
    /// @dev `lzReceive` already pins `msg.sender` to `endpoint`; the role check is what lets
    ///      `revokeGateway(endpoint)` disconnect LayerZero, which the peer check alone never would.
    function _lzReceive(
        Origin calldata _origin,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    )
        internal
        override
    {
        _checkRole(GATEWAY_ROLE);
        _onMessageFrom(ProviderAddress.evmSender(_origin.sender), _message);
    }
}
