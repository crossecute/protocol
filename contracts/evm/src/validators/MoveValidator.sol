// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Move} from "src/addressing/Move.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IRefValidator} from "src/registry/IRefValidator.sol";

/// @title MoveValidator
/// @notice Per-chain validator for Move references.
/// @dev Enforces the fixed 32-byte address width. Move addresses have a short display
///      form (`0x1` and the zero-padded 32-byte form are the SAME address, AIP-40),
///      which has caused real production bugs. Accepting a short form here would give
///      one address two distinct registry keys, so anything but 32 bytes is rejected.
contract MoveValidator is IRefValidator {
    function validateRef(bytes calldata interop) external pure override {
        Erc7930.Interop memory io = Erc7930.parseStrict(interop);
        if (!Move.isMoveChain(io.chainType)) revert Move.NotMoveChain();
        // Zero-length address is a Chain Identifier, which has no address to check.
        if (io.addr.length == 0) return;
        if (io.addr.length != Move.MOVE_ADDRESS_BYTES) {
            revert Move.BadMoveAddressLength();
        }
    }
}
