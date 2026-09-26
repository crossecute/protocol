// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";
import {ProviderOrigin} from "src/protocols/ProviderOrigin.sol";

/// @notice Wormhole wiring shared by every spoke variant (this file's, and the zkSync/Tron
///         ones in `WormholeDivergentSpokeTransceiver.sol`), which differ only in address
///         derivation.
abstract contract WormholeSpokeBase is SpokeTransceiverBase, IVaaV1Receiver {
    address public immutable coreBridge;
    address public immutable quoterRouter;
    address public immutable quoter;

    constructor(address coreBridge_, address quoterRouter_, address quoter_) {
        coreBridge = coreBridge_;
        quoterRouter = quoterRouter_;
        quoter = quoter_;
    }

    /// @dev Plain stored value, not `ProviderChainId`: a spoke has exactly one destination.
    uint16 public homeWormholeChain;

    /// @dev Zero is `ProviderChainId`'s unset sentinel, mirrored here.
    error ZeroHomeWormholeChain();

    /// @param homeWormholeChain_ Wormhole's chain id for the home chain.
    /// @dev Grants `GATEWAY_ROLE` to `coreBridge` directly — see
    ///      `WormholeHubTransceiver.initialize`.
    function __WormholeSpoke_init(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bool addressesDiverge_,
        uint16 homeWormholeChain_
    ) internal onlyInitializing {
        if (homeWormholeChain_ == 0) revert ZeroHomeWormholeChain();
        grantRole(GATEWAY_ROLE, coreBridge);
        homeWormholeChain = homeWormholeChain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, addressesDiverge_
        );
    }

    /* ================================== sending =================================== */

    /// @dev No chainKey resolution: `_routeTo`/`_counterpartOn` already refuse every key but
    ///      `homeChainKey`, so `homeWormholeChain` is always the right destination.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32 sendId)
    {
        return WormholeMessage.send(_route(), recipient, payload, attributes, value, _refundTo());
    }

    function _quoteMessage(bytes memory recipient, bytes memory, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return WormholeMessage.quote(_route(), recipient, attributes, _refundTo());
    }

    function _route() internal view returns (WormholeMessage.Route memory) {
        return WormholeMessage.Route(coreBridge, quoterRouter, quoter, homeWormholeChain);
    }

    bytes4 public constant WORMHOLE_GAS_LIMIT_ATTRIBUTE = WormholeMessage.GAS_LIMIT_ATTRIBUTE;

    /* ================================= receiving =================================== */

    /// @dev Emitter chain per `ProviderOrigin`; `_authenticateOrigin` checks the emitter.
    function executeVAAv1(bytes calldata multiSigVaa) external payable override {
        (uint16 emitterChain, address emitter, bytes calldata payload) =
            WormholeMessage.verify(coreBridge, hasRole(GATEWAY_ROLE, coreBridge), multiSigVaa);
        ProviderOrigin.requireHome(emitterChain, homeWormholeChain);
        _onInbound(homeRoute(), abi.encodePacked(emitter), payload);
    }

    function vaaConsumed(bytes32 vaaHash) external view returns (bool) {
        return WormholeMessage.consumed(vaaHash);
    }
}

/// @notice Transceiver on every non-home chain whose addresses match Ethereum's.
contract WormholeSpokeTransceiver is WormholeSpokeBase {
    constructor(address coreBridge_, address quoterRouter_, address quoter_)
        WormholeSpokeBase(coreBridge_, quoterRouter_, quoter_)
    {}

    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        uint16 homeWormholeChain_
    ) external initializer {
        __WormholeSpoke_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, false, homeWormholeChain_
        );
    }
}
