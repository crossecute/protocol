// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";

/// @notice The per-user LayerZero transmitter on Ethereum, cloned by
///         `TransmitterFactory`.
///
/// @dev It holds no registry pointer and knows no eids. `send(8453, calls)` derives the
///      destination chainKey purely and hands it to `_sendMessage`; the provider binding is
///      what turns that into an endpoint id. A user adding a destination changes nothing
///      here.
contract LzTransmitter is TransmitterBase {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }
}
