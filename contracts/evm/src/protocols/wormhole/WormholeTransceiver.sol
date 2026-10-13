// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ProviderTransceiver} from "src/protocols/ProviderTransceiver.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {WormholeMessage, IWormholeQuoters} from "src/protocols/wormhole/WormholeMessage.sol";
import {IVaaV1Receiver} from "@wormhole-sdk/interfaces/IExecutor.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";

/// @notice Wormhole on `TransceiverBase`. Wormhole reaches neither zkSync Era nor Tron, so there
///         are no divergent variants and no Wormhole transceiver sends a receiver report.
///
/// @dev The Wormhole chain id is its own `uint16` enumeration, not an EVM chain id, hence the
///      table. Transceivers share one address across parity chains, so the published payload's
///      destination prefix (`WormholeMessage`) is what keeps a VAA for one chain from running
///      on another. See `docs/provider-research.md#6-wormhole-core-vs-the-relayer-are-two-different-bindings`.
contract WormholeTransceiver is ProviderTransceiver, IVaaV1Receiver, IWormholeQuoters {
    bytes4 public constant WORMHOLE_EXECUTION_ATTRIBUTE = WormholeMessage.EXECUTION_ATTRIBUTE;
    bytes4 public constant WORMHOLE_DEFERRED_ATTRIBUTE = WormholeMessage.DEFERRED_ATTRIBUTE;

    /// @dev Escrow left in the balance by a deferred send is not the float.
    error EscrowNotWithdrawable(uint256 amount, uint256 withdrawable);

    /// @notice Core bridge and Executor on this chain. On the implementation, so they never
    ///         reach a derived account address.
    address public immutable coreBridge;
    address public immutable executor;

    constructor(address coreBridge_, address executor_) {
        if (coreBridge_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        if (executor_ == address(0)) revert ProviderAddress.ZeroEndpoint();
        coreBridge = coreBridge_;
        executor = executor_;
    }

    /// @param quoter The relay provider quoter deferred executions on this chain, and on the
    ///        transmitters this transceiver creates, may be paid under.
    function initialize(TransceiverConfig memory c, uint16 governorHomeChain, address quoter) external initializer {
        __WormholeTransceiver_init(c, governorHomeChain);
        __TransceiverBase_init(c);
        WormholeMessage.setQuoter(quoter, true);
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

    /// @notice Approve or revoke a quoter, as one rotates or another provider is added.
    function setQuoter(address quoter, bool approved) external onlyOwner {
        WormholeMessage.setQuoter(quoter, approved);
    }

    function isQuoter(address quoter) external view returns (bool) {
        return WormholeMessage.isQuoter(quoter);
    }

    /* ===================================== sending ===================================== */

    /// @notice Request execution of a message a deferred send published here. Permissionless;
    ///         see `WormholeMessage.requestDeferred`.
    function requestDeferredExecution(uint64 sequence, bytes calldata signedQuote) external {
        WormholeMessage.requestDeferred(coreBridge, executor, address(this), sequence, signedQuote);
    }

    function withdraw(uint256 amount) public override {
        uint256 withdrawable = address(this).balance - WormholeMessage.escrowed();
        if (amount > withdrawable) revert EscrowNotWithdrawable(amount, withdrawable);
        super.withdraw(amount);
    }

    /// @dev The excess over the quote is refunded to `_refundTo`, the caller.
    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes, uint256 value)
        internal
        override
        returns (bytes32)
    {
        return WormholeMessage.send(
            _route(recipient), recipient, payload, attributes, value, _refundTo(), _defaultGas(payload)
        );
    }

    function _quoteMessage(bytes memory recipient, bytes memory payload, bytes[] memory attributes)
        internal
        view
        override
        returns (uint256 nativeFee)
    {
        return WormholeMessage.quote(_route(recipient), recipient, attributes, _defaultGas(payload));
    }

    function _route(bytes memory recipient) internal view returns (WormholeMessage.Route memory) {
        // forge-lint: disable-next-line(unsafe-typecast) set through a uint16 setter
        uint16 targetChain = uint16(_providerIdOf(recipient));
        return WormholeMessage.Route(coreBridge, executor, targetChain);
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
