// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StarknetDerive} from "src/derivation/StarknetDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {IRefValidator} from "src/registry/IRefValidator.sol";

/// @title StarknetValidator
/// @notice Rejects Starknet references whose address is a well-formed 32-byte value
///         that no Starknet contract can ever occupy.
/// @dev This is the constraint the 7930 envelope structurally cannot catch: length is
///      correct, framing is canonical, and the value is still impossible.
contract StarknetValidator is IRefValidator {
    function validateRef(bytes calldata interop) external pure override {
        Erc7930.Interop memory io = Erc7930.parseStrict(interop);
        // A zero-length address is a Chain Identifier, which has no felt to bound.
        if (io.addr.length == 0) return;
        StarknetDerive.validateAddress(StarknetDerive.toFelt(io.addr));
    }
}
