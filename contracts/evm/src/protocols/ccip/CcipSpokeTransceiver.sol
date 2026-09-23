// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Transceiver on every non-home chain.
contract CcipSpokeTransceiver is SpokeTransceiverBase, IAny2EVMMessageReceiver {
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    /// @dev Plain stored value, not `ProviderChainId`: a spoke has exactly one destination.
    uint64 public homeSelector;

    /// @param homeSelector_ CCIP's selector for the home chain.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        uint64 homeSelector_
    ) external initializer {
        homeSelector = homeSelector_;
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            false
        );
    }

    /* ================================== sending =================================== */

    /// @dev No chainKey resolution: `_routeTo`/`_counterpartOn` already refuse every key
    ///      but `homeChainKey`, so `homeSelector` is always the right destination, and
    ///      `_recipientOn(homeChainKey)` (what `recipient` already is, on this path) already
    ///      carries the home transceiver's address for `EVM2AnyMessage.receiver`.
    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        Client.EVM2AnyMessage memory message = _buildMessage(recipient, payload, attributes);
        return IRouterClient(router).ccipSend{value: value}(homeSelector, message);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        Client.EVM2AnyMessage memory message = _buildMessage(recipient, payload, attributes);
        return IRouterClient(router).getFee(homeSelector, message);
    }

    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE =
        bytes4(keccak256("crossecute.ccip.extraArgs"));

    error UnknownCcipAttribute(bytes attribute);

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
        uint256 len = attribute.length - 4;
        bytes memory encoded = new bytes(len);
        for (uint256 i; i < len; ++i) {
            encoded[i] = attribute[i + 4];
        }
        (uint256 gasLimit, bool allowOutOfOrderExecution) =
            abi.decode(encoded, (uint256, bool));
        return Client._argsToBytes(
            Client.EVMExtraArgsV2({
                gasLimit: gasLimit,
                allowOutOfOrderExecution: allowOutOfOrderExecution
            })
        );
    }

    /* ================================= receiving =================================== */

    /// @dev A spoke has one valid origin; CCIP's off-ramp asserts nothing about the
    ///      source-chain sender itself, so `_authenticateOrigin` (reached through
    ///      `_onInbound`) is the only check. `route` is `homeRoute()` directly.
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        onlyRole(GATEWAY_ROLE)
    {
        address senderAddr = abi.decode(message.sender, (address));
        _onInbound(homeRoute(), abi.encodePacked(senderAddr), message.data);
    }

    /// @notice Declares support for `IAny2EVMMessageReceiver` and `IERC165`.
    /// @dev NOT OPTIONAL — see `CcipReceiver.supportsInterface`'s note.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}
