// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Erc7930} from "src/addressing/Erc7930.sol";

/// @title StarknetDerive
/// @notice What can and cannot be computed about Starknet from the EVM.
///
/// @dev CONSTANTS ARE SOURCED, NOT RECALLED. All values below come from
///      starkware-libs/cairo-lang:
///        - starknet/definitions/constants.py :: L2_ADDRESS_UPPER_BOUND
///        - starknet/public/abi.py            :: ADDR_BOUND, MASK_250, starknet_keccak
///        - starknet/core/os/contract_address/contract_address.py
///
/// @dev WHAT IS DERIVABLE HERE
///        - `starknetKeccak` / `selector`: masked keccak256. Native opcode, ~free.
///          This is how Starknet entry-point selectors are computed, so a payload
///          targeting a Starknet function CAN commit to its selector on-chain.
///        - Range validation of addresses, class hashes, and felts.
///
/// @dev WHAT IS NOT
///        Contract addresses. The derivation is a Pedersen hash chain:
///            raw = H(H(H(H(H(0, PREFIX), deployer), salt), classHash), ctorHash), 5)
///            address = raw mod L2_ADDRESS_UPPER_BOUND
///        where PREFIX is the felt encoding of the ASCII "STARKNET_CONTRACT_ADDRESS"
///        and H is Pedersen over the STARK curve.
///
///        Pedersen is not merely expensive on the EVM, it is structurally awkward:
///        it needs roughly 500 precomputed curve points (~32KB of constants), which
///        exceeds the EIP-170 contract size limit outright. A real implementation
///        means SSTORE2-chunked tables plus projective-coordinate EC arithmetic over
///        a 252-bit prime, landing somewhere in the 1e5-1e6 gas range with a large
///        verification burden and a silent-failure mode.
///
///        The payoff would be upgrading Starknet from Committed to Derived. Since
///        registering an expectation already puts the predicted address inside the
///        signed payload, that upgrade buys little. RECOMMENDATION: do not build it.
///        Compute the address off-chain, register it as an expectation, and let the
///        registry's provenance cap make the weaker guarantee explicit rather than
///        implicit.
library StarknetDerive {
    /// @dev FIELD_PRIME = 2^251 + 17 * 2^192 + 1
    uint256 internal constant FIELD_PRIME =
        0x0800000000000011000000000000000000000000000000000000000000000001;

    /// @dev L2_ADDRESS_UPPER_BOUND = 2^251 - 256. Note the "- 256": a naive `< 2^251`
    ///      check admits 256 values that can never be a Starknet contract address,
    ///      because `calculate_contract_address_from_hash` reduces mod this bound.
    uint256 internal constant L2_ADDRESS_UPPER_BOUND = (1 << 251) - 256;

    /// @dev MASK_250 = 2^250 - 1
    uint256 internal constant MASK_250 = (1 << 250) - 1;

    /// @dev CONTRACT_ADDRESS_PREFIX = felt encoding of ASCII "STARKNET_CONTRACT_ADDRESS"
    ///      (25 bytes, big-endian). Present so an off-chain derivation can be checked
    ///      against the same constant the contract enforces.
    uint256 internal constant CONTRACT_ADDRESS_PREFIX =
        0x535441524b4e45545f434f4e54524143545f41444452455353;

    error AddressOutOfRange();
    error FeltOutOfRange();
    error ClassHashOutOfRange();
    error BadAddressWidth();

    /// @notice Starknet's keccak variant: keccak256 truncated to 250 bits so the
    ///         result fits a field element.
    /// @dev cairo-lang: `from_bytes(keccak(data)) & MASK_250`.
    function starknetKeccak(bytes memory data) internal pure returns (uint256) {
        return uint256(keccak256(data)) & MASK_250;
    }

    /// @notice Entry-point selector for a function name.
    /// @dev Selectors for `__default__` / `__l1_default__` are 0 by special case;
    ///      that is a caller concern, not encoded here.
    function selector(string memory functionName) internal pure returns (uint256) {
        return starknetKeccak(bytes(functionName));
    }

    /// @notice A contract address must be strictly below L2_ADDRESS_UPPER_BOUND.
    function validateAddress(uint256 addr) internal pure {
        if (addr >= L2_ADDRESS_UPPER_BOUND) revert AddressOutOfRange();
    }

    /// @notice A generic field element must be below FIELD_PRIME. Class hashes use
    ///         this wider bound (CLASS_HASH_UPPER_BOUND == FIELD_SIZE), not the
    ///         address bound.
    function validateFelt(uint256 v) internal pure {
        if (v >= FIELD_PRIME) revert FeltOutOfRange();
    }

    function validateClassHash(uint256 v) internal pure {
        if (v >= FIELD_PRIME) revert ClassHashOutOfRange();
    }

    /// @notice Read a 32-byte Starknet address out of ERC-7930 address bytes.
    function toFelt(bytes memory addr) internal pure returns (uint256 v) {
        if (addr.length != 32) revert BadAddressWidth();
        assembly {
            v := mload(add(addr, 32))
        }
    }
}
