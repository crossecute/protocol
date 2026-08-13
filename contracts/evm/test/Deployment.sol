// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";

/// @notice The `Deployment` struct every transceiver initializer takes, built for tests.
///
/// @dev A LIBRARY RATHER THAN A BASE TEST CONTRACT, so a suite picks it up with an import and
///      keeps whatever it already inherits. A transceiver names a treasury and a set of
///      transports at initialization and can never revisit either, and most suites care about
///      neither: spelling both out at each call site would bury the subject of the test in
///      ceremony.
library Deploy {
    /// @notice No treasury, no gateway.
    /// @dev The default for suites about routing, derivation, or manufacture. A zero treasury
    ///      means fees could never be withdrawn, which these tests never ask to do. The owner
    ///      is a separate argument to the hub's initializer, and a spoke has none.
    function bare() internal pure returns (TransceiverBase.Deployment memory) {
        return TransceiverBase.Deployment({
            treasury: address(0),
            gateways: new address[](0)
        });
    }

    /// @notice A treasury and one transport: what a real deployment names.
    function full(address treasury, address gateway)
        internal
        pure
        returns (TransceiverBase.Deployment memory)
    {
        address[] memory gateways = new address[](1);
        gateways[0] = gateway;

        return TransceiverBase.Deployment({treasury: treasury, gateways: gateways});
    }
}
