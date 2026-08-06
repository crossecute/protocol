// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainType} from "src/addressing/ChainType.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @title Move
/// @notice Reference extension for Move chains (Aptos, Movement, Sui).
///
/// @dev WHY THIS EXISTS. Two gaps the ERC-7930 envelope cannot close on its own:
///
///      1. NO ASSIGNED CHAIN TYPE. As of writing, the CASA namespace registry defines
///         CAIP-350 profiles for exactly four namespaces: eip155 (0x0000), bip122
///         (0x0001), solana (0x0002), starknet (0x0003). `aptos/` and `sui/` have
///         CAIP-2 profiles only — no CAIP-10, no CAIP-350. There is therefore no
///         standard ChainType and no standard address serialization for Move chains.
///         The values below are PROVISIONAL. See the migration note.
///
///      2. A MOVE MODULE HAS NO ADDRESS. A transceiver on Aptos is
///         `account_address::module_name`; on Sui it is a function in a package.
///         The 32-byte account or package ID fits the envelope's Address field, but
///         the qualified name does not, and no amount of length-prefixing changes
///         that — it is a different kind of thing, not a longer address.
///
/// @dev DESIGN: SEPARATION OF ADDRESS AND QUALIFICATION.
///      The 7930 Address field carries ONLY the 32-byte account/package ID, which is
///      almost certainly what a future CAIP-350 profile will specify. Everything else
///      — module name, function name, type arguments, Sui package lineage — lives in
///      a MoveQualifier attached alongside. When CASA assigns real chain types, only
///      the ChainType constants change; the qualifier structure is untouched.
///
/// @dev MIGRATION. Registry keys are `keccak256(envelope)`, and the envelope contains
///      the ChainType. If CASA assigns Aptos or Sui a value different from the
///      provisional ones here, EVERY id for those chains changes. That is a
///      re-keying migration across the registry, not a config edit. Provisional types
///      are deliberately confined to the 0xFF00..0xFFFF range so `isProvisional` can
///      flag affected refs, and so a collision with a CASA assignment (which allocates
///      upward from 0x0000) is implausible rather than merely unlikely.
library Move {
    /* ========================= provisional chain types ======================== */

    /// @dev All values below are allocated in `ChainType`, which is the one table for
    ///      the whole repo. These are aliases kept for readability at the call sites.
    uint16 internal constant PROVISIONAL_FLOOR = ChainType.PROVISIONAL_FLOOR;

    /// @dev Aptos-Move address semantics: 32-byte AccountAddress, SHA3-256 derivation.
    ///      Movement shares this profile and is distinguished by ChainReference, not
    ///      by ChainType — the address format is identical, which is the same basis
    ///      CASA uses to group networks under one namespace.
    uint16 internal constant CT_PROV_APTOS = ChainType.APTOS;

    /// @dev Sui-Move: 32-byte address/ObjectID, BLAKE2b-256 derivation.
    uint16 internal constant CT_PROV_SUI = ChainType.SUI;

    /// @dev Chain references (UTF-8, following the Starknet profile's convention of
    ///      using the CAIP-2 reference string directly rather than an integer).
    bytes internal constant REF_APTOS_MAINNET = "mainnet";
    bytes internal constant REF_MOVEMENT_MAINNET = "movement-mainnet";
    bytes internal constant REF_SUI_MAINNET = "mainnet";

    uint256 internal constant MOVE_ADDRESS_BYTES = 32;

    function isProvisional(uint16 chainType) internal pure returns (bool) {
        return chainType >= PROVISIONAL_FLOOR;
    }

    function isMoveChain(uint16 chainType) internal pure returns (bool) {
        return chainType == CT_PROV_APTOS || chainType == CT_PROV_SUI;
    }

    /* ============================== qualification ============================= */

    enum MoveKind {
        Unset,
        /// A plain account address. No module, no function.
        Account,
        /// An object (Aptos Object<T>, Sui ObjectID). No module, no function.
        Object,
        /// A published package (Sui) or the publishing account (Aptos).
        Package,
        /// `address::module_name`.
        Module,
        /// `address::module_name::function_name`, optionally with type arguments.
        /// This is what a transceiver call target actually is.
        Entry
    }

    /// @notice Everything about a Move reference that is not the 32-byte address.
    struct MoveQualifier {
        MoveKind kind;
        /// Move Identifier. Empty unless kind is Module or Entry.
        string moduleName;
        /// Move Identifier. Empty unless kind is Entry.
        string functionName;
        /// BCS-serialized `Vec<TypeTag>`. Empty if the entry takes no type arguments.
        /// Opaque here — serialize off-chain; do not build BCS in Solidity.
        bytes typeArgs;
        /// SUI ONLY. A package upgrade mints a NEW package ID, but types retain the
        /// ORIGINAL package ID in their StructTag while calls target the latest. A
        /// single id would silently mean the wrong thing after the first upgrade, so
        /// the envelope address holds the CALL target (latest) and this holds type
        /// identity (original). Zero when not applicable.
        bytes32 originalPackageId;
        /// SUI ONLY. A shared-object reference is `(ObjectID, initial_shared_version)`;
        /// the ID alone is not enough to construct a call. Zero if not shared.
        uint64 initialSharedVersion;
    }

    error BadKind();
    error ModuleNameRequired();
    error ModuleNameForbidden();
    error FunctionNameRequired();
    error FunctionNameForbidden();
    error TypeArgsForbidden();
    error BadIdentifier();
    error SuiOnlyField();
    error BadMoveAddressLength();
    error NotMoveChain();

    /// @notice Commitment over a qualifier, for inclusion in a signed payload.
    /// @dev abi.encode (not encodePacked): fixed field framing, so no two distinct
    ///      qualifiers can produce the same preimage by shifting bytes between the
    ///      variable-length fields.
    function hash(MoveQualifier memory q) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                uint8(q.kind),
                q.moduleName,
                q.functionName,
                q.typeArgs,
                q.originalPackageId,
                q.initialSharedVersion
            )
        );
    }

    /// @notice Structural validation of a qualifier against its chain.
    function validate(MoveQualifier memory q, uint16 chainType) internal pure {
        if (!isMoveChain(chainType)) revert NotMoveChain();
        if (q.kind == MoveKind.Unset) revert BadKind();

        bool wantsModule = (q.kind == MoveKind.Module || q.kind == MoveKind.Entry);
        bool wantsFunction = (q.kind == MoveKind.Entry);

        if (wantsModule) {
            if (bytes(q.moduleName).length == 0) revert ModuleNameRequired();
            requireIdentifier(q.moduleName);
        } else if (bytes(q.moduleName).length != 0) {
            revert ModuleNameForbidden();
        }

        if (wantsFunction) {
            if (bytes(q.functionName).length == 0) revert FunctionNameRequired();
            requireIdentifier(q.functionName);
        } else if (bytes(q.functionName).length != 0) {
            revert FunctionNameForbidden();
        }

        // Type arguments attach to a call, not to a bare address or module.
        if (!wantsFunction && q.typeArgs.length != 0) revert TypeArgsForbidden();

        // Sui-only fields must be zero on Aptos, or the same logical reference could
        // be expressed two ways and hash to two different commitments.
        if (chainType != CT_PROV_SUI) {
            if (q.originalPackageId != bytes32(0)) revert SuiOnlyField();
            if (q.initialSharedVersion != 0) revert SuiOnlyField();
        }
    }

    /// @notice Move Identifier charset: ASCII, first character a letter or underscore,
    ///         remainder alphanumeric or underscore.
    /// @dev This is a canonicity guard, not decoration. Without it a module name could
    ///      carry whitespace, a homoglyph, or a trailing NUL and still produce a
    ///      well-formed commitment that no Move VM will ever resolve.
    function requireIdentifier(string memory s) internal pure {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        if (n == 0 || n > 255) revert BadIdentifier();

        bytes1 c0 = b[0];
        bool okFirst = (c0 >= 0x41 && c0 <= 0x5a) // A-Z
            || (c0 >= 0x61 && c0 <= 0x7a) // a-z
            || c0 == 0x5f; // _
        if (!okFirst) revert BadIdentifier();

        for (uint256 i = 1; i < n; ++i) {
            bytes1 c = b[i];
            bool okRest = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)
                || (c >= 0x30 && c <= 0x39) // 0-9
                || c == 0x5f;
            if (!okRest) revert BadIdentifier();
        }
    }

    /* ================================ encoding ================================ */

    /// @notice Build the 7930 envelope for a Move address. The address field holds the
    ///         32-byte account/package ID and nothing else.
    function encodeMove(uint16 chainType, bytes memory chainRef, bytes32 addr)
        internal
        pure
        returns (bytes memory)
    {
        if (!isMoveChain(chainType)) revert NotMoveChain();
        return Erc7930.encode(chainType, chainRef, abi.encodePacked(addr));
    }

    function encodeAptos(bytes memory chainRef, bytes32 addr)
        internal
        pure
        returns (bytes memory)
    {
        return encodeMove(CT_PROV_APTOS, chainRef, addr);
    }

    function encodeSui(bytes memory chainRef, bytes32 addr)
        internal
        pure
        returns (bytes memory)
    {
        return encodeMove(CT_PROV_SUI, chainRef, addr);
    }

    function toAddress(bytes memory addrField) internal pure returns (bytes32 v) {
        if (addrField.length != MOVE_ADDRESS_BYTES) revert BadMoveAddressLength();
        assembly {
            v := mload(add(addrField, 32))
        }
    }
}
