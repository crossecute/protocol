// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ZkSyncSpokeTransceiver, TronSpokeTransceiver} from
    "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Spoke on a chain whose CREATE2 formula is not Ethereum's: zkSync Era and Tron.
///         One concrete contract each, chosen at deploy time (see
///         `DivergentSpokeTransceiver.sol`); CCIP wiring in both is identical to
///         `CcipSpokeTransceiver`'s, repeated rather than shared since the two diverge from
///         each other in `predictCrossAccount`/`_deployAccount` and have no common concrete
///         base to hold it.

/// @dev Overrides both `predictCrossAccount` and `_deployAccount`: zkSync diverges in the
///      deployment mechanism as well as the address.
contract CcipZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, IAny2EVMMessageReceiver {
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    uint64 public homeSelector;

    /// @param accountBytecodeHash_ ZKSOLC artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    /// @dev Grants `GATEWAY_ROLE` to `router` directly — see
    ///      `CcipHubTransceiver.initialize`.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint64 homeSelector_
    ) external initializer {
        grantRole(GATEWAY_ROLE, router);
        homeSelector = homeSelector_;
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

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

    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        onlyRole(GATEWAY_ROLE)
    {
        address senderAddr = abi.decode(message.sender, (address));
        _onInbound(homeRoute(), abi.encodePacked(senderAddr), message.data);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}

/// @dev Overrides `predictCrossAccount` only: Tron runs raw-initcode CREATE2 with a
///      different derived address, no different deployment mechanism.
contract CcipTronSpokeTransceiver is TronSpokeTransceiver, IAny2EVMMessageReceiver {
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    uint64 public homeSelector;

    /// @param accountBytecodeHash_ TRON-solc's `CrossProxy` initcode hash, not solc's.
    /// @dev Grants `GATEWAY_ROLE` to `router` directly — see
    ///      `CcipHubTransceiver.initialize`.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint64 homeSelector_
    ) external initializer {
        grantRole(GATEWAY_ROLE, router);
        homeSelector = homeSelector_;
        __SpokeTransceiverBase_init(
            gateways,
            receiverImplementation_,
            homeChainKey_,
            homeChainIdentifier_,
            homeTransceiver_,
            true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

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

    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        onlyRole(GATEWAY_ROLE)
    {
        address senderAddr = abi.decode(message.sender, (address));
        _onInbound(homeRoute(), abi.encodePacked(senderAddr), message.data);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}
