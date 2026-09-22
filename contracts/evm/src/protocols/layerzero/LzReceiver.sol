// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {OAppReceiverUpgradeable, Origin} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import {OAppCoreUpgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";

/// @dev Extends the base two-arg shape with the eid `sourceTransmitter` lives behind, so its
///      peer can be set in the same locked initializer call.
interface ILzReceiverInit {
    function initialize(address sourceTransmitter, Call[] calldata calls, uint32 homeEid)
        external;
}

/// @notice Per-user account on a non-home chain.
/// @dev Receiver-only: inherits `OAppReceiverUpgradeable`, not the combined `OAppUpgradeable`
///      — this contract never sends via LayerZero.
contract LzReceiver is ReceiverBase, OAppReceiverUpgradeable, ILzReceiverInit {
    constructor(address _endpoint) OAppCoreUpgradeable(_endpoint) {}

    /// @dev Refused, not just unused: it would skip OApp setup entirely, permanently
    ///      bricking inbound (`NoPeer` forever, no reopening the init window).
    error UseLzInitializer();

    function initialize(address, Call[] calldata) external pure override {
        revert UseLzInitializer();
    }

    /// @dev Provider setup before `__ReceiverBase_init`, per its own note (needs to run
    ///      before `_execute`). `setPeer` is written directly to storage, not called: it's
    ///      `onlyOwner` and this contract has no `Ownable` — this initializer is the only
    ///      window peer configuration ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls, uint32 homeEid)
        external
        override
        initializer
    {
        __OAppReceiver_init(address(this));
        _getOAppCoreStorage().peers[homeEid] = bytes32(uint256(uint160(sourceTransmitter_)));
        emit PeerSet(homeEid, bytes32(uint256(uint160(sourceTransmitter_))));
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev R3.3 exception: `lzReceive` (not overridden) authenticates via `endpoint`+`peers`
    ///      before this runs, ahead of our own check. Defensible for a 1:1 pairing (one peer,
    ///      set once). Narrows via `isSourceTransmitter` rather than `_authenticateSender`,
    ///      since `_origin.sender` is already a plain address and the ERC-7930 round trip
    ///      buys nothing here.
    function _lzReceive(
        Origin calldata _origin,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    ) internal override {
        address sender = address(uint160(uint256(_origin.sender)));
        if (!isSourceTransmitter(sender)) revert NotSourceTransmitter();
        _onMessage(_message);
    }
}
