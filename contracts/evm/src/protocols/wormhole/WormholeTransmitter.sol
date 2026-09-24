// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";

/// @dev A transmitter has no chain-id table of its own: it's per-user and locked after
///      creation, so it reads the shared, owner-updatable table on `WormholeHubTransceiver`
///      (via `TransmitterBase.transceiver`) live, on every send.
interface IWormholeChainTable {
    function wormholeChainFor(bytes32 chainKey) external view returns (uint16);
}

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev Sender-only: no `receiveWormholeMessages`, so R3.1 is answered by absence rather than
///      a guard. Targets the Relayer, not bare Core, which names no destination and prices no
///      delivery (see `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`).
contract WormholeTransmitter is TransmitterBase, OwnableUpgradeable {
    /// @notice Wormhole Relayer on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its initcode,
    ///         so this never moves a derived account address.
    address public immutable relayer;

    constructor(address relayer_) {
        relayer = relayer_;
    }

    function initialize(address owner_, address transceiver_, bytes32 salt_) external initializer {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return
            WormholeMessage.send(
                relayer, _wormholeChainFor(recipient), recipient, payload, attributes, value, _refundTo()
            );
    }

    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return WormholeMessage.quote(relayer, _wormholeChainFor(recipient), recipient, attributes);
    }

    bytes4 public constant WORMHOLE_GAS_LIMIT_ATTRIBUTE = WormholeMessage.GAS_LIMIT_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == WORMHOLE_GAS_LIMIT_ATTRIBUTE;
    }

    function _wormholeChainFor(bytes memory recipient) internal view returns (uint16) {
        return IWormholeChainTable(transceiver).wormholeChainFor(Erc7930.chainKey(recipient));
    }
}
