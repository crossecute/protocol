// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice The transceiver on the home chain. One instance, administered by the crossecute
///         msig, shared by every user's transmitter.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL, AND THAT IS WHAT ERC-7786 BOUGHT, EXACTLY
///      AS ON THE LAYERZERO TEMPLATE. A gateway takes a recipient that NAMES ITS OWN CHAIN, so
///      there is nothing to translate and the route slot holds that chain's ERC-7930
///      identifier. A native Hyperlane binding needs a codec and a chainKey table of its own,
///      since `IMailbox.dispatch` still takes a `uint32 destinationDomain`, Hyperlane's own
///      per-chain identifier. It is conventionally the EVM chain id for EVM chains, but that
///      is a convention this protocol must not rely on: it is not true for non-EVM chains,
///      and nothing enforces it even where it usually holds.
///
/// @dev Does NOT inherit a transmitter, for the same reason as every other binding: a
///      transceiver is shared infrastructure the msig administers and a transmitter is
///      per-user, owned by its user.
///
/// @dev ONE MAILBOX ADDRESS SERVES BOTH DIRECTIONS. `dispatch`/`quoteDispatch` (send) and
///      `process` (the permissionless relay call that verifies the ISM and then calls this
///      contract's `handle`) live on the same `Mailbox` contract, so `GATEWAY_ROLE` names one
///      address here, not two. See `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
contract HyperlaneHubTransceiver is HubTransceiverBase {
    /// @dev NO RECEIVER IMPLEMENTATION, because a hub never makes a receiver. The
    ///      manufacturing half lives on the spoke; see `TransceiverBase`.
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /// @notice NO GATEWAY IS GRANTED, so this contract accepts and sends through nothing.
    /// @dev That is the honest state of a binding with no Hyperlane behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the Hyperlane Mailbox in the initializer, which is where
    ///      the address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.
    ///
    /// @dev NO WRITTEN R3.3 EXCEPTION IS NEEDED HERE, PROVIDED `Router` IS SKIPPED. Hyperlane's
    ///      `Mailbox.process` authenticates only that a message passed its ISM before calling
    ///      `handle` — a statement about the MESSAGE, not about which contract sent it on the
    ///      source chain. The per-domain peer check (`Router._routers`) is a separate,
    ///      optional layer this repo does not adopt (see `HyperlaneReceiver`). So, bound this
    ///      way, `_authenticateOrigin` is the only check on who the counterpart is, in exactly
    ///      one place, matching `_onInbound`'s stated rule with no exception to write down —
    ///      unlike LayerZero, whose peer check is inside `_lzReceive` itself and cannot be
    ///      opted out of without forking the receive path.

}
