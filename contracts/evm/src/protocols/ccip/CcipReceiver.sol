// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {IAny2EVMMessageReceiver} from "@ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Per-user account on a non-home chain.
/// @dev Does not inherit Chainlink's `CCIPReceiver`: its `onlyRouter` duplicates what
///      `GATEWAY_ROLE` already checks, and it carries no `_authenticateSender`-equivalent
///      at all (see the contract-level note on `_ccipReceive` below). Implements
///      `IAny2EVMMessageReceiver.ccipReceive` directly, gated `onlyRole(GATEWAY_ROLE)`.
contract CcipReceiver is ReceiverBase, IAny2EVMMessageReceiver {
    /// @notice CCIP Router on this chain. Set on the implementation; safe because the
    ///         implementation address lives in the proxy's ERC-1967 slot, not its
    ///         initcode, so this never moves a derived account address.
    address public immutable router;

    constructor(address router_) {
        router = router_;
    }

    /// @dev `ReceiverBase.initialize` carries no `gateways` array of its own (unlike a
    ///      transceiver's `__TransceiverBase_init`, a receiver is per-user and its gateway
    ///      is fixed infrastructure, not a per-account choice), so `GATEWAY_ROLE` is granted
    ///      here, before `__ReceiverBase_init`. `grantRole` is
    ///      `onlyInitializing`, so this initializer is the only window it ever gets.
    function initialize(address sourceTransmitter_, Call[] calldata calls)
        external
        override
        initializer
    {
        grantRole(GATEWAY_ROLE, router);
        __ReceiverBase_init(sourceTransmitter_, calls);
    }

    /// @dev `_authenticateSender` is `bytes calldata` and expects an ERC-7930 envelope;
    ///      `message.sender` is `abi.encode(address)`, CCIP's own width, which cannot be
    ///      passed to it (an internal `calldata` parameter cannot bind to a synthesized
    ///      value) and would fail `Erc7930.parseStrict` even if it could. Narrows via
    ///      `isSourceTransmitter` instead, the same shape as LayerZero's receiver, for the
    ///      same reason: the ERC-7930 round trip buys nothing once the provider's own
    ///      sender is already a plain address.
    ///
    /// @dev No provider-side check runs before this. Unlike LayerZero's `lzReceive`, CCIP's
    ///      off-ramp asserts nothing about the source-chain sender (see
    ///      `docs/provider-research.md#4-ccip-as-a-native-binding`), so `isSourceTransmitter`
    ///      below is the only authentication check, matching `_onInbound`'s stated rule with
    ///      no exception to write.
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        onlyRole(GATEWAY_ROLE)
    {
        address sender = abi.decode(message.sender, (address));
        if (!isSourceTransmitter(sender)) revert NotSourceTransmitter();
        _onMessage(message.data);
    }

    /// @notice Declares support for `IAny2EVMMessageReceiver` and `IERC165`.
    /// @dev CCIP's off-ramp checks this before calling `ccipReceive` atomically with any
    ///      token transfer. The default a plain
    ///      `AccessControlEnumerableUpgradeable.supportsInterface` would give (false, since
    ///      it never heard of this interface) makes the off-ramp deliver silently without
    ///      ever calling `ccipReceive` — a message that looks sent and simply never
    ///      arrives, not a revert. See `CCIPReceiver.sol`'s own comment on
    ///      `supportsInterface` at the pinned commit
    ///      (`docs/provider-research.md#4-ccip-as-a-native-binding`).
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override
        returns (bool)
    {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IERC165).interfaceId || super.supportsInterface(interfaceId);
    }
}
