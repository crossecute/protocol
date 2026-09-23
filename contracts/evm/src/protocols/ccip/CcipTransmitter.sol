// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

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
        Client.EVM2AnyMessage memory message = _buildMessage(recipient, payload, attributes);
        return IRouterClient(router).ccipSend{value: value}(selector, message);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint64 selector = _selectorFor(recipient);
        Client.EVM2AnyMessage memory message = _buildMessage(recipient, payload, attributes);
        return IRouterClient(router).getFee(selector, message);
    }

    /// @notice One attribute: CCIP's `EVMExtraArgsV2`, as
    ///         `abi.encodePacked(CCIP_EXTRA_ARGS_ATTRIBUTE, abi.encode(gasLimit,
    ///         allowOutOfOrderExecution))`. Anything else is refused per ERC-7786.
    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE =
        bytes4(keccak256("crossecute.ccip.extraArgs"));

    function supportsAttribute(bytes4 selector) external pure override returns (bool) {
        return selector == CCIP_EXTRA_ARGS_ATTRIBUTE;
    }

    function _selectorFor(bytes memory recipient) internal view returns (uint64) {
        return ICcipSelectorTable(transceiver).selectorFor(Erc7930.chainKey(recipient));
    }

    /// @dev Empty `extraArgs` is a valid default (CCIP's own 200k gas limit applies), not a
    ///      missing one.
    function _buildMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal pure returns (Client.EVM2AnyMessage memory) {
        address receiver = address(bytes20(Erc7930.parseStrict(recipient).addr));
        Client.EVMTokenAmount[] memory noTokens = new Client.EVMTokenAmount[](0);
        return Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: payload,
            tokenAmounts: noTokens,
            feeToken: address(0),
            extraArgs: _extraArgsFrom(attributes)
        });
    }

    function _extraArgsFrom(bytes[] memory attributes) internal pure returns (bytes memory) {
        if (attributes.length == 0) return "";
        if (attributes.length > 1) revert UnknownCcipAttribute(attributes[1]);
        bytes memory attribute = attributes[0];
        if (attribute.length < 4) revert UnknownCcipAttribute(attribute);
        bytes4 selector;
        assembly {
            selector := mload(add(attribute, 32))
        }
        if (selector != CCIP_EXTRA_ARGS_ATTRIBUTE) revert UnknownCcipAttribute(attribute);
        (uint256 gasLimit, bool allowOutOfOrderExecution) = _decodeExtraArgs(attribute);
        return Client._argsToBytes(
            Client.EVMExtraArgsV2({
                gasLimit: gasLimit,
                allowOutOfOrderExecution: allowOutOfOrderExecution
            })
        );
    }

    error UnknownCcipAttribute(bytes attribute);

    function _decodeExtraArgs(bytes memory attribute)
        private
        pure
        returns (uint256 gasLimit, bool allowOutOfOrderExecution)
    {
        uint256 len = attribute.length - 4;
        bytes memory encoded = new bytes(len);
        for (uint256 i; i < len; ++i) {
            encoded[i] = attribute[i + 4];
        }
        (gasLimit, allowOutOfOrderExecution) = abi.decode(encoded, (uint256, bool));
    }

    /// @notice NO GATEWAY IS GRANTED. A real binding grants `GATEWAY_ROLE` to the CCIP
    ///         Router on `CcipHubTransceiver`; the transmitter itself has no `Roles` to
    ///         hold it (R3.1 is answered by having no inbound entry point at all).
}
