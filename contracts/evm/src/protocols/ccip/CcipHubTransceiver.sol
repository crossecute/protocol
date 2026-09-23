// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
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

    /// @dev No receiver implementation, because a hub never makes a receiver. Grants
    ///      `GATEWAY_ROLE` to `router` directly rather than relying on the deployment to
    ///      include it in `gateways`: the address is already known (immutable, set in the
    ///      constructor), and `ccipReceive` is gated on exactly this role, so omitting it
    ///      from `gateways` would deploy successfully and then reject every inbound message.
    ///      `gateways` still exists for naming additional trusted endpoints up front.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        grantRole(GATEWAY_ROLE, router);
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
        Client.EVM2AnyMessage memory message = CcipMessage.build(recipient, payload, attributes);
        return IRouterClient(router).ccipSend{value: value}(selector, message);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        uint64 selector = uint64(_providerIdFor(Erc7930.chainKey(recipient)));
        Client.EVM2AnyMessage memory message = CcipMessage.build(recipient, payload, attributes);
        return IRouterClient(router).getFee(selector, message);
    }

    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE = CcipMessage.EXTRA_ARGS_ATTRIBUTE;

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
    /// @dev See `CcipReceiver.supportsInterface`'s note: CCIP's off-ramp checks this before
    ///      calling `ccipReceive`, and answering false makes it deliver silently.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}
