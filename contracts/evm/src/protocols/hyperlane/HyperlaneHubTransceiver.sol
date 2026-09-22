// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

/// @notice Transceiver on the home chain. One instance, msig-administered.
/// @dev No provider vocabulary in the route table (ERC-7786). A real binding needs its own
///      chainKey<->domain table: `IMailbox.dispatch` takes a `uint32 destinationDomain`,
///      which is conventionally the EVM chain id but not guaranteed to be (and meaningless
///      for non-EVM chains) — must not be relied on. One Mailbox address serves both
///      `dispatch`/`quoteDispatch` and inbound `process`->`handle`, so `GATEWAY_ROLE` names
///      one address. See `docs/provider-research.md#5-hyperlane-as-a-native-binding`.
contract HyperlaneHubTransceiver is HubTransceiverBase {
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways, transmitterImplementation_);
    }

    /// @notice No gateway granted yet.
    /// @dev No R3.3 exception needed, provided `Router` is skipped: `Mailbox.process`
    ///      authenticates that a message passed its ISM, not which contract sent it on the
    ///      source chain. `_authenticateOrigin` is the only origin check either way — unlike
    ///      LayerZero, whose peer check is inside `_lzReceive` itself.
}
