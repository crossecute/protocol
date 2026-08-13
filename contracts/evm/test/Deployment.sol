// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";

/// @notice The `Deployment` struct every transceiver initializer now takes, built for tests.
///
/// @dev FREE FUNCTIONS RATHER THAN A BASE TEST CONTRACT, so a suite picks them up with an
///      import and keeps whatever it already inherits. Every transceiver in this tree names
///      three things at initialization and can never revisit them, and most tests care about
///      exactly one of the three: spelling the other two out at each call site would bury the
///      subject of the test in ceremony.
library Deploy {
    /// @notice An owner, no treasury, no gateway.
    /// @dev The default for suites about routing, derivation, or manufacture. A zero treasury
    ///      means fees could never be withdrawn, which these tests never ask to do.
    function ownedBy(address owner) internal pure returns (TransceiverBase.Deployment memory) {
        return TransceiverBase.Deployment({
            owner: owner,
            treasury: address(0),
            gateways: new address[](0)
        });
    }

    /// @notice An owner, a treasury, and one transport: what a real deployment names.
    function full(address owner, address treasury, address gateway)
        internal
        pure
        returns (TransceiverBase.Deployment memory)
    {
        address[] memory gateways = new address[](1);
        gateways[0] = gateway;

        return TransceiverBase.Deployment({
            owner: owner,
            treasury: treasury,
            gateways: gateways
        });
    }
}
