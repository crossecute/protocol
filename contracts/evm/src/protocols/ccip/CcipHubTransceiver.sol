// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice The transceiver on the home chain. One instance, administered by the crossecute
///         msig, shared by every user's transmitter.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL, AND THAT IS WHAT ERC-7786 BOUGHT, EXACTLY
///      AS ON THE LAYERZERO TEMPLATE. A gateway takes a recipient that NAMES ITS OWN CHAIN, so
///      there is nothing to translate and the route slot holds that chain's ERC-7930
///      identifier. A native CCIP binding needs a codec and a chainKey table of its own,
///      since `IRouterClient.ccipSend` still takes a `uint64 destChainSelector`, CCIP's own
///      per-chain identifier and not an EVM chain id.
///
/// @dev Does NOT inherit a transmitter, for the same reason as every other binding: a
///      transceiver is shared infrastructure the msig administers and a transmitter is
///      per-user, owned by its user.
///
/// @dev ONE ROUTER ADDRESS SERVES BOTH DIRECTIONS. `IRouterClient` (send: `getFee`,
///      `ccipSend`) and the sole caller CCIP will ever invoke `ccipReceive` from are the same
///      Router contract on a given chain, so `GATEWAY_ROLE` names one address here, not two.
///      See `docs/provider-research.md#4-ccip-as-a-native-binding`.
contract CcipHubTransceiver is HubTransceiverBase {
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
    /// @dev That is the honest state of a binding with no CCIP behind it. A real binding
    ///      grants `GATEWAY_ROLE` to the CCIP Router in the initializer, which is where the
    ///      address is known; the absence fails loudly on the first message rather than
    ///      quietly on a forged one.
    ///
    /// @dev NO WRITTEN R3.3 EXCEPTION IS NEEDED HERE, UNLIKE LAYERZERO'S. Chainlink's own
    ///      `CCIPReceiver.ccipReceive` checks only `msg.sender == i_ccipRouter`
    ///      (transport identity, what `GATEWAY_ROLE` already answers) and asserts nothing
    ///      about who sent the message on the SOURCE chain. That check is left entirely to
    ///      the application. So a CCIP binding that skips `CCIPReceiver` and authenticates
    ///      through `_authenticateOrigin` alone has exactly one origin check, in exactly one
    ///      place, with nothing running ahead of it — the rule `_onInbound`'s NatSpec states,
    ///      with no exception to write down.

}
