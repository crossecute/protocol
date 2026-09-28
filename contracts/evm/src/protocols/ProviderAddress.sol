// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice Narrowing a provider's address forms to an EVM address, refusing rather than
///         truncating or padding anything that is not one (R4.3).
library ProviderAddress {
    error UnsupportedRecipient(bytes addr);
    error UnsupportedSender(bytes32 sender);

    /// @notice The receiving address, for a provider that delivers to it as an EVM address
    ///         (CCIP, Hyperlane, Wormhole, OP Stack).
    /// @dev A recipient is only checked against the recorded counterpart, which may be a
    ///      non-EVM address. LayerZero is exempt: it delivers to its recorded peer instead.
    function evmRecipient(bytes memory recipient) internal pure returns (address) {
        bytes memory addr = Erc7930.parseStrict(recipient).addr;
        if (addr.length != 20) revert UnsupportedRecipient(addr);
        return address(bytes20(addr));
    }

    /// @notice A provider-reported 32-byte sender, left-padded when it is an EVM address.
    /// @dev Nonzero high bytes are a non-EVM sender; truncating would let its low 20 bytes
    ///      pass as an unrelated EVM account.
    function evmSender(bytes32 sender) internal pure returns (address) {
        if (uint256(sender) > type(uint160).max) revert UnsupportedSender(sender);
        return address(uint160(uint256(sender)));
    }
}
