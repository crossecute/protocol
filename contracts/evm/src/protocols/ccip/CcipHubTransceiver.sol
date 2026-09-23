// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered, shared by every
///         user's transmitter.
/// @dev One Router address serves both directions (`ccipSend`/`getFee` and inbound
///      `ccipReceive`), so `GATEWAY_ROLE` names one address, not two. See
///      `docs/provider-research.md#4-ccip-as-a-native-binding`.
contract CcipHubTransceiver is
    HubTransceiverBase,
    ProviderChainId,
    IAny2EVMMessageReceiver
{
    /// @notice CCIP Router on this chain. Set on the implementation, not the proxy:
    ///         harmless, since it never affects a derived account address.
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    /// @dev No receiver implementation, because a hub never makes a receiver.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /* ============================ the selector table ============================= */

    event SelectorSet(bytes32 indexed chainKey, uint64 selector);

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setSelector(bytes32 chainKey, uint64 selector) external onlyOwner {
        _setProviderId(chainKey, selector);
        emit SelectorSet(chainKey, selector);
    }

    /// @notice Called externally by every `CcipTransmitter` this hub created; see
    ///         `ICcipSelectorTable` there.
    function selectorFor(bytes32 chainKey) external view returns (uint64) {
        return uint64(_providerIdFor(chainKey));
    }

    /* ================================== sending =================================== */

    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 value
    ) internal override returns (bytes32 sendId) {
        uint64 selector = uint64(_providerIdFor(Erc7930.chainKey(recipient)));
        Client.EVM2AnyMessage memory message = _buildMessage(recipient, payload, attributes);
        return IRouterClient(router).ccipSend{value: value}(selector, message);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint64 selector = uint64(_providerIdFor(Erc7930.chainKey(recipient)));
        Client.EVM2AnyMessage memory message = _buildMessage(recipient, payload, attributes);
        return IRouterClient(router).getFee(selector, message);
    }

    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE =
        bytes4(keccak256("crossecute.ccip.extraArgs"));

    error UnknownCcipAttribute(bytes attribute);

    /// @dev Duplicated across CCIP bindings rather than shared: no common ancestor for it
    ///      that wouldn't widen `OutboundBase` for every provider.
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

    /// @dev No R3.3-style exception needed: CCIP's off-ramp asserts nothing about the
    ///      source-chain sender (see `docs/provider-research.md#4-ccip-as-a-native-binding`),
    ///      so `_authenticateOrigin` (reached through `_onInbound`) is the only check —
    ///      matching `_onInbound`'s stated rule directly, unlike LayerZero.
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        onlyRole(GATEWAY_ROLE)
    {
        bytes32 chainKey = _chainKeyOfProvider(message.sourceChainSelector);
        bytes memory route = routeFor(chainKey);
        address senderAddr = abi.decode(message.sender, (address));
        _onInbound(route, abi.encodePacked(senderAddr), message.data);
    }

    /// @notice Declares support for `IAny2EVMMessageReceiver` and `IERC165`.
    /// @dev NOT OPTIONAL — see `CcipReceiver.supportsInterface`'s note. Same requirement
    ///      here: CCIP's off-ramp checks this before calling `ccipReceive`.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}
