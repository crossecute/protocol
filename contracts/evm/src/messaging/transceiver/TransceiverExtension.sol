// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverCore, TransceiverConfig} from "src/messaging/transceiver/TransceiverCore.sol";
import {IBootstrapAllowlist} from "src/messaging/transceiver/IBootstrapAllowlist.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";

/// @title TransceiverExtension
/// @notice A transceiver's initialization, owner configuration, float withdrawal, and the views
///         no contract calls. Runs only by `DELEGATECALL` from `TransceiverBase`'s `fallback`, so
///         its storage is the transceiver's and `msg.sender` is the transceiver's caller.
///
/// @dev Provider-agnostic: every provider's transceiver on a chain can name the same one. A
///      chain whose account addresses diverge uses the matching variant in
///      `DivergentTransceiver.sol`, which derives as that chain's `TransceiverBase` does.
///
/// @dev Holds no upgrade path and calls no address it reads from storage except the registry the
///      base already calls. Called directly, it runs against its own empty storage, where every
///      owner and treasury check fails and initialization is disabled.
contract TransceiverExtension is TransceiverCore {
    /// @dev `initializeBase` was not called by the transceiver itself.
    error NotSelf(address caller);
    /// @dev Sending is `TransceiverBase`'s; the extension's copy of `quoteMessage` is unreachable
    ///      through a transceiver, whose own copy answers first.
    error SendsNothing();

    constructor() {
        _disableInitializers();
    }

    /* ================================ initialization ============================== */

    /// @notice Configure and grant the gateways. See `TransceiverBase.__TransceiverBase_init`,
    ///         the only caller.
    ///
    /// @dev Reachable through the transceiver's `fallback` by anyone while it is initializing, so
    ///      it accepts only the transceiver's self-call, as `Roles.grantRole` does (#68).
    function initializeBase(TransceiverConfig memory c, bool addressesDiverge_) external onlyInitializing {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        if (c.transmitterImplementation == address(0)) revert NoAccountImplementation();
        if (c.receiverImplementation == address(0)) revert NoAccountImplementation();
        if (c.treasury == address(0)) revert NoTreasury();
        if (c.governorOwner == address(0)) revert ZeroOwner();

        // The identifier names the owner's home, so it must be the canonical one for its key.
        bytes32 governorHome = keccak256(c.governorHome);
        _requireNames(c.governorHome, governorHome);

        _transmitterImplementation = c.transmitterImplementation;
        emit TransmitterImplementationSet(c.transmitterImplementation);
        _receiverImplementation = c.receiverImplementation;
        emit ReceiverImplementationSet(c.receiverImplementation);
        _addressesDiverge = addressesDiverge_;
        emit AddressesDivergeSet(addressesDiverge_);
        _treasury = c.treasury;

        __Ownable_init(_predictCrossAccount(c.governorOwner, c.governorSalt, governorHome));

        // Born accepting the governor's home as an origin: the owner is the governor's
        // account here, which only a bootstrap from that home can create.
        if (address(c.chainRegistry) != address(0)) {
            _setRouting(c.chainRegistry, c.messageProvider, c.minCounterpartProvenance);
            // Only the owner, which that bootstrap creates, could set a counterpart, so the
            // home's must resolve now or the transceiver is never usable (#32).
            if (governorHome != localChainKey) _counterpartOn(governorHome);
        }
        if (governorHome != localChainKey) _setRoute(governorHome, c.governorHome);

        for (uint256 i; i < c.gateways.length; ++i) {
            if (c.gateways[i] != address(0)) {
                _grantInitialRole(GATEWAY_ROLE, c.gateways[i]);
            }
        }
    }

    /* ================================ configuration ================================ */

    /// @notice Teach this transceiver how a chain is named. Write-once, and the owner's.
    /// @dev A binding wraps this only where it keeps a provider-native id.
    function setRoute(bytes32 chainKey, bytes memory route) public onlyOwner {
        _setRoute(chainKey, route);
    }

    /// @notice Point this transceiver at the registry, name its provider id, and set its
    ///         provenance bar.
    ///
    /// @dev The registry and provider id are write-once, like routes and counterparts:
    ///      repointing either would redirect every future lookup. The same pair again is a
    ///      no-op; a different one reverts `RoutingAlreadySet`.
    ///
    /// @dev `minCounterpartProvenance` stays rebindable and is written on every call: it is
    ///      how the owner reacts to a bridge's standing changing without a redeploy.
    function setRouting(
        IChainRegistryRefs chainRegistry_,
        bytes32 messageProvider_,
        Provenance minCounterpartProvenance_
    ) external onlyOwner {
        _setRouting(chainRegistry_, messageProvider_, minCounterpartProvenance_);
    }

    function _setRouting(
        IChainRegistryRefs chainRegistry_,
        bytes32 messageProvider_,
        Provenance minCounterpartProvenance_
    ) private {
        if (address(_chainRegistry) != address(0)) {
            if (_chainRegistry != chainRegistry_ || _messageProvider != messageProvider_) {
                revert RoutingAlreadySet();
            }
        } else {
            _chainRegistry = chainRegistry_;
            _messageProvider = messageProvider_;
        }

        _minCounterpartProvenance = minCounterpartProvenance_;
        emit RoutingSet(address(chainRegistry_), messageProvider_, minCounterpartProvenance_);
    }

    /// @notice Record where this provider's transceiver sits on another chain.
    ///
    /// @dev Held here, not in the registry, because a location is per (chain, provider) and
    ///      this transceiver is that pair. The registry holds what is common to every provider:
    ///      `provenanceFor(chainKey)`. Write-once: re-pointing a counterpart redirects it.
    /// @param interop Canonical ERC-7930 bytes, so the registry can check it is well-formed
    ///        and on `chainKey`. The address half is stored, since inbound senders are
    ///        compared to it.
    function setCounterpart(bytes32 chainKey, bytes calldata interop) external onlyOwner {
        if (address(_chainRegistry) == address(0)) revert NoChainRegistry();
        if (hasCounterpart(chainKey)) revert CounterpartAlreadySet(chainKey);

        _recordCounterpart(chainKey, interop);
    }

    /// @notice Record the counterpart by recomputing it from the registry's deriver and inputs
    ///         for that chain, rather than by being told.
    /// @dev The inputs were written in an earlier transaction, so `paramsCommitment` puts
    ///      their hash in this one's signed calldata: the signers approve the inputs, not a
    ///      pointer to them.
    /// @param paramsCommitment `keccak256(chainRegistry.deriveParams(chainKey))`.
    function resolveCounterpart(bytes32 chainKey, bytes32 paramsCommitment) external onlyOwner {
        if (address(_chainRegistry) == address(0)) revert NoChainRegistry();
        if (hasCounterpart(chainKey)) revert CounterpartAlreadySet(chainKey);
        if (keccak256(_chainRegistry.deriveParams(chainKey)) != paramsCommitment) {
            revert ParamsCommitmentMismatch(chainKey);
        }

        _recordCounterpart(chainKey, _chainRegistry.expectedTransceiver(chainKey));
    }

    /// @dev The default `_counterpartOn` answers on a `Predetermined` chain is live from the
    ///      moment the chain is graded, so a counterpart recorded later must equal it: otherwise
    ///      `hasCounterpart` being false would let the owner repoint a lane in use.
    function _recordCounterpart(bytes32 chainKey, bytes memory interop) private {
        _chainRegistry.validateLocation(chainKey, interop);
        bytes memory addr = Erc7930.parseStrict(interop).addr;
        if (
            _chainRegistry.provenanceFor(chainKey) == Provenance.Predetermined
                && keccak256(addr) != keccak256(abi.encodePacked(_parityAddress(chainKey)))
        ) revert CounterpartNotParity(chainKey);
        _setCounterpart(chainKey, addr);
    }

    /// @notice Name the contract that decides which accounts may bootstrap. Zero lets every
    ///         account.
    function setBootstrapAllowlist(IBootstrapAllowlist allowlist) external onlyOwner {
        _bootstrapAllowlist = allowlist;
        emit BootstrapAllowlistSet(address(allowlist));
    }

    /// @notice Name who may set bootstrap fees besides the owner. Zero names no one.
    // forge-lint: disable-next-line(missing-zero-check) zero removes the operator
    function setOperator(address operator_) external onlyOwner {
        _operator = operator_;
        emit OperatorSet(operator_);
    }

    /// @notice Set what standing an account up on `chainKey` costs. The owner's or the operator's.
    /// @dev Rebindable: a price redirects nothing. Zero halts bootstraps to a reporting chain.
    function setBootstrapFee(bytes32 chainKey, uint256 fee) external {
        if (msg.sender != _operator && msg.sender != owner()) revert NotOwnerOrOperator(msg.sender);
        _bootstrapFee[chainKey] = fee;
        emit BootstrapFeeSet(chainKey, fee);
    }

    /* =================================== the float ================================= */

    /// @notice Send `amount` of the float to the treasury, at the treasury's call.
    /// @dev Gated, not a permissionless sweep: anyone able to empty the float could make every
    ///      bootstrap here that reports revert.
    function withdraw(uint256 amount) external {
        address to = _treasury;
        if (msg.sender != to) revert NotTreasury(msg.sender);

        emit Withdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed(amount);
    }

    /* ==================================== views ==================================== */

    /// @notice The salt an owner's account deploys at, on every chain. See `_accountSalt`.
    function accountSalt(address owner, bytes32 salt, bytes32 homeChainKey) external pure returns (bytes32) {
        return _accountSalt(owner, salt, homeChainKey);
    }

    /// @notice Where an owner's account lives on this chain, before it exists.
    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey) external view returns (address) {
        return _predictCrossAccount(owner, salt, homeChainKey);
    }

    /// @notice Where `(owner, salt)`'s transmitter lives, before it exists.
    function predictTransmitter(address owner, bytes32 salt) external view returns (address) {
        return _localAccount(owner, salt);
    }

    /// @notice The exact report bytes for `(owner, salt)` and `receiver`, so its cost can be
    ///         quoted with `quoteMessage` before it is owed.
    function reportPayload(address owner, bytes32 salt, address receiver) external view returns (bytes memory) {
        return _reportPayload(owner, salt, receiver);
    }

    function transmitterImplementation() external view returns (address) {
        return _transmitterImplementation;
    }

    function receiverImplementation() external view returns (address) {
        return _receiverImplementation;
    }

    function addressesDiverge() external view returns (bool) {
        return _addressesDiverge;
    }

    function chainRegistry() external view returns (IChainRegistryRefs) {
        return _chainRegistry;
    }

    function messageProvider() external view returns (bytes32) {
        return _messageProvider;
    }

    function minCounterpartProvenance() external view returns (Provenance) {
        return _minCounterpartProvenance;
    }

    function bootstrapFee(bytes32 chainKey) external view returns (uint256) {
        return _bootstrapFee[chainKey];
    }

    function operator() external view returns (address) {
        return _operator;
    }

    function bootstrapAllowlist() external view returns (IBootstrapAllowlist) {
        return _bootstrapAllowlist;
    }

    function treasury() external view returns (address) {
        return _treasury;
    }

    /* =================================== sending =================================== */

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        revert SendsNothing();
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal pure override returns (uint256) {
        revert SendsNothing();
    }
}
