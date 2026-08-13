// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice The transceiver on the home chain. One instance, administered by the crossecute
///         msig, shared by every user's transmitter.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL, AND THAT IS WHAT ERC-7786 BOUGHT. A
///      gateway takes a recipient that NAMES ITS OWN CHAIN, so there is nothing to translate
///      and the route slot holds that chain's ERC-7930 identifier, which `setRoute` is
///      already typed for. A native SDK binding would need a codec and a chainKey table of
///      its own, since `_lzSend` still takes a `uint32`.
///
/// @dev Does NOT inherit a transmitter. A transceiver is shared infrastructure the msig
///      administers and a transmitter is per-user, owned by its user; merging them would give
///      one contract two authorities over the same entry points.
contract LzHubTransceiver is HubTransceiverBase {
    /// @dev NO RECEIVER IMPLEMENTATION, because a hub never makes a receiver. The
    ///      manufacturing half lives on the spoke; see `TransceiverBase`.
    function initialize(
        address owner_,
        Deployment calldata deployment,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, deployment, transmitterImplementation_);
    }

    /// @notice NO GATEWAY IS GRANTED, so this contract accepts and sends through nothing.
    /// @dev That is the honest state of a binding with no LayerZero behind it. A real binding
    ///      grants `GATEWAY_ROLE` to its endpoint in the initializer, which is where the
    ///      address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.

}
