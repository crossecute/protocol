// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {SignedTransmitter} from "src/messaging/outbound/SignedTransmitter.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";

/// @dev The guard reads the staged selectors from `ISignedTransmitter`; the
///      transmitter must answer them.
contract SignedSelectorsTest is Test {
    function test_theGuardsSelectorsAreTheTransmitters() public pure {
        assertEq(ISignedTransmitter.bootstrap.selector, TransmitterBase.bootstrap.selector);
        assertEq(ISignedTransmitter.registerRoot.selector, SignedTransmitter.registerRoot.selector);
    }
}
