// SPDX-License-Identifier: MIT

// Vendored, unmodified, from smartcontractkit/ccip @ 171f9f0c
// (contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol).
// MIT-tagged in its own SPDX header, distinct from the BUSL-1.1 router/off-ramp
// infrastructure this repo only ever calls. See
// docs/provider-research.md#4-ccip-as-a-native-binding.

pragma solidity ^0.8.0;

import {Client} from "../libraries/Client.sol";

/// @notice Application contracts that intend to receive messages from
/// the router should implement this interface.
interface IAny2EVMMessageReceiver {
  /// @notice Called by the Router to deliver a message.
  /// If this reverts, any token transfers also revert. The message
  /// will move to a FAILED state and become available for manual execution.
  /// @param message CCIP Message
  /// @dev Note ensure you check the msg.sender is the OffRampRouter
  function ccipReceive(
    Client.Any2EVMMessage calldata message
  ) external;
}
