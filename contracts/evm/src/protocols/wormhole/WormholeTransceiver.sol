// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {WormholeMessage} from "src/protocols/wormhole/WormholeMessage.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Wormhole on `TransceiverBase`, shared by the plain, zkSync, and Tron variants, which
///         differ only in address derivation.
///
/// @dev The Wormhole chain id is its own `uint16` enumeration, not an EVM chain id, hence the
///      table. Transceivers share one address across parity chains, so the published payload's
///      destination prefix (`WormholeMessage`) is what keeps a VAA for one chain from running
///      on another. See `docs/provider-research.md#6-wormhole-core-vs-the-relayer-are-two-different-bindings`.
abstract contract WormholeTransceiverBase is ProviderTransceiver, IVaaV1Receiver {
    bytes4 public constant WORMHOLE_GAS_LIMIT_ATTRIBUTE = WormholeMessage.GAS_LIMIT_ATTRIBUTE;

    /// @notice Core bridge, Executor quoter router, and relay provider's quoter on this chain.
    ///         On the implementation, so they never reach a derived account address.
    address public immutable coreBridge;
    address public immutable quoterRouter;
    address public immutable quoter;

    constructor(address coreBridge_, address quoterRouter_, address quoter_) {
        if (coreBridge_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        if (quoterRouter_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        if (quoter_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        coreBridge = coreBridge_;
        quoterRouter = quoterRouter_;
        quoter = quoter_;
    }

    /// @dev `executeVAAv1` requires the Core bridge to hold `GATEWAY_ROLE`, though it never
    ///      calls in.
    /// @param governorHomeChain Wormhole's chain id for the governor's home; see
    ///        `ProviderTransceiver._initGovernorHomeId`.
    function __WormholeTransceiver_init(TransceiverConfig memory c, uint16 governorHomeChain)
        internal
        onlyInitializing
    {
        __ProviderTransceiver_init(coreBridge);
        _initGovernorHomeId(c.governorHome, governorHomeChain);
    }

    /// @dev Write-once-if-unset (`ProviderChainId`'s shape).
    function setWormholeChain(bytes32 chainKey, uint16 wormholeChain) external onlyOwner {
        _setProviderId(chainKey, wormholeChain);
    }

    /* ===================================== sending ===================================== */

    /// @dev The Executor router refunds excess to `_refundTo`: the float during a report, the
    ///      caller otherwise.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
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
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint16 setter
        uint16 targetChain = uint16(_providerIdOf(recipient));
        return WormholeMessage.Route(coreBridge, quoterRouter, quoter, targetChain);
    }

    /* ==================================== receiving ==================================== */

    /// @dev Permissionless. Guardian signatures authenticate the emitter, not that it is the
    ///      counterpart, so the base's `_authenticateOrigin` is the only sender check. An
    ///      unmapped emitter chain reverts in the table.
    function executeVAAv1(bytes calldata multiSigVaa) external payable override {
        (uint16 emitterChain, address emitter, bytes calldata payload) =
            WormholeMessage.verify(coreBridge, hasRole(GATEWAY_ROLE, coreBridge), multiSigVaa);
        _onProviderInbound(emitterChain, emitter, payload);
    }

    function vaaConsumed(bytes32 vaaHash) external view returns (bool) {
        return WormholeMessage.consumed(vaaHash);
    }
}

/// @notice The Wormhole transceiver on every chain whose addresses match Ethereum's.
contract WormholeTransceiver is WormholeTransceiverBase {
    constructor(address coreBridge_, address quoterRouter_, address quoter_)
        WormholeTransceiverBase(coreBridge_, quoterRouter_, quoter_)
    {}

    function initialize(TransceiverConfig memory c, uint16 governorHomeChain) external initializer {
        __WormholeTransceiver_init(c, governorHomeChain);
        __TransceiverBase_init(c);
    }
}
