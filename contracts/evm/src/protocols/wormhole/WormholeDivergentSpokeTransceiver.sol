// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    ZkSyncSpokeTransceiver,
    TronSpokeTransceiver
} from "src/messaging/transceiver/spoke/DivergentSpokeTransceiver.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";

/// @notice Spoke on a chain whose CREATE2 formula is not Ethereum's: zkSync Era and Tron.
///         Wormhole wiring in both is identical to `WormholeSpokeTransceiver`'s, repeated
///         rather than shared since the two have no common concrete base to hold it.

/// @dev Overrides both `predictCrossAccount` and `_deployAccount`: zkSync diverges in the
///      deployment mechanism as well as the address.
contract WormholeZkSyncSpokeTransceiver is ZkSyncSpokeTransceiver, IVaaV1Receiver {
    address public immutable coreBridge;
    address public immutable quoterRouter;
    address public immutable quoter;

    constructor(address coreBridge_, address quoterRouter_, address quoter_) {
        coreBridge = coreBridge_;
        quoterRouter = quoterRouter_;
        quoter = quoter_;
    }

    uint16 public homeWormholeChain;

    error ZeroHomeWormholeChain();
    error UnexpectedEmitterChain(uint16 emitterChain);

    /// @param accountBytecodeHash_ ZKSOLC artifact hash for `CrossProxy`, not
    ///        `CROSS_PROXY_INIT_CODE_HASH` (solc's, meaningless on Era).
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint16 homeWormholeChain_
    ) external initializer {
        if (homeWormholeChain_ == 0) revert ZeroHomeWormholeChain();
        grantRole(GATEWAY_ROLE, coreBridge);
        homeWormholeChain = homeWormholeChain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

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

    function executeVAAv1(bytes calldata multiSigVaa) external payable override {
        (uint16 emitterChain, address emitter, bytes calldata payload) =
            WormholeMessage.verify(coreBridge, hasRole(GATEWAY_ROLE, coreBridge), multiSigVaa);
        if (emitterChain != homeWormholeChain) revert UnexpectedEmitterChain(emitterChain);
        _onInbound(homeRoute(), abi.encodePacked(emitter), payload);
    }

    function vaaConsumed(bytes32 vaaHash) external view returns (bool) {
        return WormholeMessage.consumed(vaaHash);
    }
}

/// @dev Overrides `predictCrossAccount` only: Tron runs raw-initcode CREATE2 with a
///      different derived address, no different deployment mechanism.
contract WormholeTronSpokeTransceiver is TronSpokeTransceiver, IVaaV1Receiver {
    address public immutable coreBridge;
    address public immutable quoterRouter;
    address public immutable quoter;

    constructor(address coreBridge_, address quoterRouter_, address quoter_) {
        coreBridge = coreBridge_;
        quoterRouter = quoterRouter_;
        quoter = quoter_;
    }

    uint16 public homeWormholeChain;

    error ZeroHomeWormholeChain();
    error UnexpectedEmitterChain(uint16 emitterChain);

    /// @param accountBytecodeHash_ TRON-solc's `CrossProxy` initcode hash, not solc's.
    function initialize(
        address[] calldata gateways,
        address receiverImplementation_,
        bytes32 homeChainKey_,
        bytes calldata homeChainIdentifier_,
        bytes calldata homeTransceiver_,
        bytes32 accountBytecodeHash_,
        uint16 homeWormholeChain_
    ) external initializer {
        if (homeWormholeChain_ == 0) revert ZeroHomeWormholeChain();
        grantRole(GATEWAY_ROLE, coreBridge);
        homeWormholeChain = homeWormholeChain_;
        __SpokeTransceiverBase_init(
            gateways, receiverImplementation_, homeChainKey_, homeChainIdentifier_, homeTransceiver_, true
        );
        __DivergentSpoke_init(accountBytecodeHash_);
    }

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

    function executeVAAv1(bytes calldata multiSigVaa) external payable override {
        (uint16 emitterChain, address emitter, bytes calldata payload) =
            WormholeMessage.verify(coreBridge, hasRole(GATEWAY_ROLE, coreBridge), multiSigVaa);
        if (emitterChain != homeWormholeChain) revert UnexpectedEmitterChain(emitterChain);
        _onInbound(homeRoute(), abi.encodePacked(emitter), payload);
    }

    function vaaConsumed(bytes32 vaaHash) external view returns (bool) {
        return WormholeMessage.consumed(vaaHash);
    }
}
