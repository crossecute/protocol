// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SignedTransmitter} from "src/messaging/outbound/SignedTransmitter.sol";

/// @notice The fixed outbound fee shared by the two OP Stack bindings.
abstract contract OpStackTransmitterBase is SignedTransmitter {
    function _crossecuteFee(uint256) internal pure override returns (uint256) {
        return 0.0001 ether;
    }
}
