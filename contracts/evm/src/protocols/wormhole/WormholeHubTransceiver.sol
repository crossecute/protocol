// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ProviderChainId} from "src/protocols/ProviderChainId.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered, shared by every
///         user's transmitter.
/// @dev The Wormhole chain id is its own `uint16` enumeration, not an EVM chain id, hence the
///      table. See `docs/provider-research.md#6-wormhole-core-vs-the-relayer-two-different-bindings`.
contract WormholeHubTransceiver is HubTransceiverBase, ProviderChainId, IVaaV1Receiver {
    /// @notice Core bridge, Executor quoter router, and relay provider's quoter on this chain.
    ///         Set on the implementation, not the proxy: harmless, since they never affect a
    ///         derived account address.
    address public immutable coreBridge;
    address public immutable quoterRouter;
    address public immutable quoter;

    constructor(address coreBridge_, address quoterRouter_, address quoter_) {
        coreBridge = coreBridge_;
        quoterRouter = quoterRouter_;
        quoter = quoter_;
    }

    /// @dev Grants `GATEWAY_ROLE` to `coreBridge` directly: `executeVAAv1` requires it, so
    ///      leaving it to `gateways` would allow a deployment that rejects every inbound VAA.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        grantRole(GATEWAY_ROLE, coreBridge);
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /* ============================ the chain-id table ============================= */

    event WormholeChainSet(bytes32 indexed chainKey, uint16 wormholeChain);

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setWormholeChain(bytes32 chainKey, uint16 wormholeChain) external onlyOwner {
        _setProviderId(chainKey, wormholeChain);
        emit WormholeChainSet(chainKey, wormholeChain);
    }

    /// @notice Called externally by every `WormholeTransmitter` this hub created; see
    ///         `IWormholeChainTable` there.
    function wormholeChainFor(bytes32 chainKey) external view returns (uint16) {
        return uint16(_providerIdFor(chainKey));
    }

    /* ================================== sending =================================== */

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return WormholeMessage.send(_route(recipient), recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return WormholeMessage.quote(_route(recipient), recipient, attributes, _refundTo());
    }

    function _route(bytes memory recipient) internal view returns (WormholeMessage.Route memory) {
        uint16 targetChain = uint16(_providerIdFor(Erc7930.chainKey(recipient)));
        return WormholeMessage.Route(coreBridge, quoterRouter, quoter, targetChain);
    }

    bytes4 public constant WORMHOLE_GAS_LIMIT_ATTRIBUTE = WormholeMessage.GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev Guardian signatures authenticate the emitter, not that it is our counterpart, so
    ///      `_authenticateOrigin` (via `_onInbound`) is the only sender check: no R3.3
    ///      exception. An unmapped emitter chain reverts in `_chainKeyOfProvider`.
    function executeVAAv1(bytes calldata multiSigVaa) external payable override {
        (uint16 emitterChain, address emitter, bytes calldata payload) =
            WormholeMessage.verify(coreBridge, hasRole(GATEWAY_ROLE, coreBridge), multiSigVaa);
        bytes memory route = routeFor(_chainKeyOfProvider(emitterChain));
        _onInbound(route, abi.encodePacked(emitter), payload);
    }

    function vaaConsumed(bytes32 vaaHash) external view returns (bool) {
        return WormholeMessage.consumed(vaaHash);
    }
}
