// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";

/// @dev A transmitter has no selector table of its own: it's per-user and locked after
///      creation, so it reads the shared, owner-updatable table on `CcipHubTransceiver` (via
///      `TransmitterBase.transceiver`) live, on every send.
interface ICcipSelectorTable {
    function selectorFor(bytes32 chainKey) external view returns (uint64);
}

/// @notice Per-user transmitter, created by `HubTransceiverBase.createTransmitter`.
/// @dev Sender-only: no `ccipReceive` inherited or implemented, so R3.1 is answered by
///      absence rather than a guard.
contract CcipTransmitter is TransmitterBase, OwnableUpgradeable {
    /// @notice CCIP Router on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its
    ///         initcode, so this never moves a derived account address.
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    /// @dev `recipient`'s address half IS used, unlike LayerZero's peer table: CCIP has no
    ///      provider-side peer concept, so `EVM2AnyMessage.receiver` names the destination
    ///      exactly the way `_recipientOn` already resolved it. `feeToken` is always
    ///      `address(0)` (native payment; P8).
    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        uint64 selector = _selectorFor(recipient);
        Client.EVM2AnyMessage memory message = CcipMessage.build(recipient, payload, attributes);
        IRouterClient(router).ccipSend{value: value}(selector, message);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint64 selector = _selectorFor(recipient);
        Client.EVM2AnyMessage memory message = CcipMessage.build(recipient, payload, attributes);
        return IRouterClient(router).getFee(selector, message);
    }

    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE = CcipMessage.EXTRA_ARGS_ATTRIBUTE;

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == CCIP_EXTRA_ARGS_ATTRIBUTE;
    }

    function _selectorFor(bytes memory recipient) internal view returns (uint64) {
        return ICcipSelectorTable(transceiver).selectorFor(Erc7930.chainKey(recipient));
    }

    /// @notice No gateway is granted here: the Router holds `GATEWAY_ROLE` on the hub,
    ///         spokes, and receivers; the transmitter has no inbound entry point (R3.1).
}
