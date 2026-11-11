// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {SignedTransmitter} from "src/messaging/signed/SignedTransmitter.sol";
import {ISignedOwnerCalls} from "src/messaging/signed/ISignedOwnerCalls.sol";

/// @dev The guard reads the staged selectors from the import-free `ISignedOwnerCalls`; the
///      transmitter must answer them.
contract SignedSelectorsTest is Test {
    function test_theGuardsSelectorsAreTheTransmitters() public pure {
        assertEq(ISignedOwnerCalls.bootstrap.selector, TransmitterBase.bootstrap.selector);
        assertEq(ISignedOwnerCalls.registerRoot.selector, SignedTransmitter.registerRoot.selector);
    }
}
