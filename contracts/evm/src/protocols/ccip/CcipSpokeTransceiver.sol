// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProviderOrigin} from "src/protocols/ProviderOrigin.sol";

/// @notice CCIP wiring shared by every spoke variant (this file's, and the zkSync/Tron ones in
///         `CcipDivergentSpokeTransceiver.sol`), which differ only in address derivation.
abstract contract CcipSpokeBase is SpokeTransceiverBase, IAny2EVMMessageReceiver {
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    /// @dev Plain stored value, not `ProviderChainId`: a spoke has exactly one destination.
    uint64 public homeSelector;

    /// @param homeSelector_ CCIP's selector for the home chain.
    /// @dev Grants `GATEWAY_ROLE` to `router` directly rather than relying on the
    ///      deployment to include it in `gateways` — see `CcipHubTransceiver.initialize`.
    function __CcipSpoke_init(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bool addressesDiverge_,
        uint64 homeSelector_
    ) internal onlyInitializing {
        grantRole(GATEWAY_ROLE, router);
        homeSelector = homeSelector_;
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            addressesDiverge_
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
        Client.EVM2AnyMessage memory message = CcipMessage.build(recipient, payload, attributes);
        IRouterClient(router).ccipSend{value: value}(homeSelector, message);
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        Client.EVM2AnyMessage memory message = CcipMessage.build(recipient, payload, attributes);
        return IRouterClient(router).getFee(homeSelector, message);
    }

    bytes4 public constant CCIP_EXTRA_ARGS_ATTRIBUTE = CcipMessage.EXTRA_ARGS_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev Origin chain per `ProviderOrigin`. CCIP's off-ramp asserts nothing about the sender;
    ///      `_authenticateOrigin` checks it.
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        onlyRole(GATEWAY_ROLE)
    {
        ProviderOrigin.requireHome(message.sourceChainSelector, homeSelector);
        address senderAddr = abi.decode(message.sender, (address));
        _onInbound(homeRoute(), abi.encodePacked(senderAddr), message.data);
    }

    /// @notice Declares support for `IAny2EVMMessageReceiver` and `IERC165`.
    /// @dev See `CcipReceiver.supportsInterface`'s note: CCIP's off-ramp checks this before
    ///      calling `ccipReceive`, and answering false makes it deliver silently.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}

/// @notice Transceiver on every non-home chain whose addresses match Ethereum's.
contract CcipSpokeTransceiver is CcipSpokeBase {
    constructor(address router_) CcipSpokeBase(router_) {}

    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        uint64 homeSelector_
    ) external initializer {
        __CcipSpoke_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, false, homeSelector_
        );
    }
}
