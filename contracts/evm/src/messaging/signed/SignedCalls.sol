// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {IERC7786GatewaySource} from "src/messaging/IErc7786.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ISignedOwnerCalls} from "src/messaging/signed/ISignedOwnerCalls.sol";
import {BootstrapLeaf} from "src/messaging/signed/ISignedDispatch.sol";
import {Slices} from "src/messaging/signed/Slices.sol";

/// @notice Reading a signed Safe transaction's target and calldata, shared by the transmitter that
///         sends it and the receiver that verifies it, so both decode the same bytes alike.
/// @dev Calldata is decoded as the transmitter's ABI decoder reads it (Q1.4): the selector must
///      match, trailing bytes are ignored, and canonical re-encoding is not required.
library SignedCalls {
    uint8 internal constant CALL = 0;

    /// @dev Not a CALL to `target` with zero `safeTxGas` and `gasPrice`.
    error NotSourceCall(address target);
    error WindowClosed(uint256 validAfter, uint256 deadline);
    /// @dev The destination is not this contract on this chain.
    error WrongDestination(bytes destination);
    /// @dev #108 fixes authority at creation, so every signed counter is zero (#109 advances it).
    error AuthorityCounterMismatch(uint256 counter);
    error EmptySignedPayload();
    /// @dev `registerRoot` is nonpayable on the source transmitter.
    error NonzeroRegistrationValue(uint256 value);

    function requireSourceCall(SafeTx memory safeTx, address target) internal pure {
        if (safeTx.to != target || safeTx.operation != CALL || safeTx.safeTxGas != 0 || safeTx.gasPrice != 0) {
            revert NotSourceCall(target);
        }
    }

    function sendMessageArgs(bytes memory data)
        internal
        pure
        returns (bytes memory recipient, bytes memory payload, bytes[] memory attributes)
    {
        return abi.decode(Slices.arguments(data, IERC7786GatewaySource.sendMessage.selector), (bytes, bytes, bytes[]));
    }

    function registeredRoot(SafeTx memory safeTx) internal pure returns (bytes32) {
        if (safeTx.value != 0) revert NonzeroRegistrationValue(safeTx.value);
        return abi.decode(Slices.arguments(safeTx.data, ISignedOwnerCalls.registerRoot.selector), (bytes32));
    }

    /// @notice The signed `bootstrap(payload, attributes)`, with `payload` unpacked.
    function bootstrapArgs(bytes memory data)
        internal
        pure
        returns (bytes32 root, BootstrapLeaf memory leaf, bytes32[] memory proof, bytes[] memory attributes)
    {
        bytes memory payload;
        (payload, attributes) =
            abi.decode(Slices.arguments(data, ISignedOwnerCalls.bootstrap.selector), (bytes, bytes[]));
        uint256 counter;
        (root, counter, leaf, proof) = abi.decode(payload, (bytes32, uint256, BootstrapLeaf, bytes32[]));
        if (counter != 0) revert AuthorityCounterMismatch(counter);
    }

    /// @notice A new execution's inclusive window, on this chain's time.
    function requireOpen(uint256 validAfter, uint256 deadline) internal view {
        // forge-lint: disable-next-line(block-timestamp) the signed window is on this chain's block time (#108)
        if (validAfter > deadline || block.timestamp < validAfter || block.timestamp > deadline) {
            revert WindowClosed(validAfter, deadline);
        }
    }

    /// @notice Reverts unless `destination` is the ERC-7930 address of `self` on this chain.
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
