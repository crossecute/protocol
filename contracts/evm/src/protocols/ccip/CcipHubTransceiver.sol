// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered.
/// @dev No provider vocabulary in the route table (ERC-7786). A real binding needs its own
///      chainKey<->selector table, since `IRouterClient.ccipSend` takes a `uint64
///      destChainSelector`. One Router address serves both `ccipSend`/`getFee` and inbound
///      `ccipReceive`, so `GATEWAY_ROLE` names one address, not two. See
///      `docs/provider-research.md#4-ccip-as-a-native-binding`.
contract CcipHubTransceiver is HubTransceiverBase {
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /// @notice No gateway granted yet.
    /// @dev No R3.3-style exception needed here, unlike LayerZero: `CCIPReceiver.ccipReceive`
    ///      only checks `msg.sender == i_ccipRouter` (transport identity) and asserts nothing
    ///      about the source-chain sender. A binding authenticating via `_authenticateOrigin`
    ///      alone has exactly one origin check, matching `_onInbound`'s stated rule.
}
