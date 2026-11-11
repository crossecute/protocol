// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {SignedTransmitter} from "src/messaging/outbound/SignedTransmitter.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";

/// @dev The guard reads the staged selectors from `ISignedTransmitter`; the
///      transmitter must answer them.
contract SignedSelectorsTest is Test {
    /// @notice Compare the guard's interface selectors with the transmitter's actual owner-call
    ///         selectors.
    /// @dev Selector-based staging must remain aligned with the implemented ABI as interfaces
    ///      and files are reorganized.
    function test_theGuardsSelectorsAreTheTransmitters() public pure {
        assertEq(ISignedTransmitter.bootstrap.selector, TransmitterBase.bootstrap.selector);
        assertEq(ISignedTransmitter.registerRoot.selector, SignedTransmitter.registerRoot.selector);
    }
}
