// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ISignedTransmitter} from "src/messaging/outbound/ISignedTransmitter.sol";

import {Bytes} from "src/messaging/signed/Bytes.sol";

/// @notice Reading a signed Safe transaction's target and calldata, shared by the transmitter that
///         sends it and the receiver that verifies it, so both decode the same bytes alike.
/// @dev Calldata is decoded as the transmitter's ABI decoder reads it (Q1.4): the selector must
///      match, trailing bytes are ignored, and canonical re-encoding is not required.
library SignedDispatchCalls {
    using Bytes for bytes;
    uint8 internal constant CALL = 0;

    /// @dev Not a CALL to `target` with zero `safeTxGas` and `gasPrice`.
    error NotSourceCall(address target);
    error WindowClosed(uint256 validAfter, uint256 deadline);
    /// @dev The destination is not this contract on this chain.
    error WrongDestination(bytes destination);
    /// @dev #108 fixes authority at creation, so every signed counter is zero (#109 advances it).
    error EmptySignedPayload();
    /// @dev `registerRoot` is nonpayable on the source transmitter.
    error NonzeroRegistrationValue(uint256 value);

    /// @notice Require a CALL to the expected transmitter with zero Safe transaction gas and gas price.
    function requireSourceCall(SafeTx memory safeTx, address target) internal pure {
        if (safeTx.to != target || safeTx.operation != CALL || safeTx.safeTxGas != 0 || safeTx.gasPrice != 0) {
            revert NotSourceCall(target);
        }
    }

    /// @notice Check the `sendMessage` selector and decode its recipient, payload and attributes.
    function sendMessageArgs(bytes memory data)
        internal
        pure
        returns (bytes memory recipient, bytes memory payload, bytes[] memory attributes)
    {
        return abi.decode(data.arguments(IERC7786GatewaySource.sendMessage.selector), (bytes, bytes, bytes[]));
    }

    /// @notice Check a `registerRoot` call and return the root it authorizes.
    /// @dev A nonzero value is refused: `registerRoot` is nonpayable, so the source could not have
    ///      executed such a registration.
    function registeredRoot(SafeTx memory safeTx) internal pure returns (bytes32) {
        if (safeTx.value != 0) revert NonzeroRegistrationValue(safeTx.value);
        return abi.decode(safeTx.data.arguments(ISignedTransmitter.registerRoot.selector), (bytes32));
    }

    /// @notice Require the block time to fall inside the inclusive window; an inverted one never opens.
    function requireOpen(uint256 validAfter, uint256 deadline) internal view {
        // forge-lint: disable-next-line(block-timestamp) the signed window is on this chain's block time (#108)
        if (validAfter > deadline || block.timestamp < validAfter || block.timestamp > deadline) {
            revert WindowClosed(validAfter, deadline);
        }
    }

    /// @notice Require the destination to name this EVM chain and `self`.
    function requireDestination(bytes memory destination, address self) internal view {
        Erc7930.Interop memory io = Erc7930.parseStrict(destination);
        if (
            io.chainType != Erc7930.CT_EIP155 || io.addr.length != 20 || Erc7930.evmChainId(io) != block.chainid
                // forge-lint: disable-next-line(unsafe-typecast) 20 bytes, checked in the same condition
                || address(bytes20(io.addr)) != self
        ) {
            revert WrongDestination(destination);
        }
    }
}
