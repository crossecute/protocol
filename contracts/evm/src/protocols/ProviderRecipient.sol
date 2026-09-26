// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The receiving address for a provider that delivers only to EVM addresses (CCIP,
///         Hyperlane, Wormhole, OP Stack as bound here).
/// @dev A recipient is only checked against the recorded counterpart, which may be a non-EVM
///      address, and a cast to 20 bytes would silently truncate or pad it into a different
///      receiver. LayerZero is exempt: it delivers to the peer it recorded, never to this.
library ProviderRecipient {
    error UnsupportedRecipient(bytes addr);

    function evmAddress(bytes memory recipient) internal pure returns (address) {
        bytes memory addr = Erc7930.parseStrict(recipient).addr;
        if (addr.length != 20) revert UnsupportedRecipient(addr);
        return address(bytes20(addr));
    }
}
