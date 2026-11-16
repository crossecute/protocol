// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeCreationProof} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {AddressDerive} from "../../derivation/AddressDerive.sol";
import {Bytes} from "../signed/Bytes.sol";
import {SafeAuthorityRecord} from "../signed/types/SafeAuthorityTypes.sol";
import {
    SAFE_L2_PROXY_INITCODE_HASH,
    SAFE_L2_SINGLETON,
    SAFE_PROXY_FACTORY,
    SAFE_PROXY_INITCODE_HASH,
    SAFE_SINGLETON,
    SAFE_TO_L2_SETUP
} from "./SafeDeployment.sol";

/// @notice Creation-proof check shared by the source guard and destination registries.
library SafeCreation {
    // Selectors are the first four bytes of the signature hash.
    // forge-lint: disable-next-item(unsafe-typecast)
    bytes4 internal constant SETUP =
        bytes4(keccak256("setup(address[],uint256,address,bytes,address,address,uint256,address)"));
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant SETUP_TO_L2 = bytes4(keccak256("setupToL2(address)"));

    error UnpinnedSingleton(address singleton);
    error CreationAddressMismatch(address safe);
    error SetupCallNotAllowed(address to);
    error CreationRecordMismatch();
    error ZeroCreationThreshold();

    /// @notice Require `record` to hold the owners, in order, and threshold its Safe was created
    ///         with, as `proof` shows.
    /// @dev The Safe address must be the canonical factory's CREATE2 result under the plain or
    ///      the chain-specific salt, so the initializer is the one setup ran with. Owner kinds are
    ///      not checked: they come from the graph. setup's delegatecall is the only other field
    ///      that can change authority, so it must be absent or exactly setupToL2(SafeL2). The
    ///      address derives for any initializer, deployable or not, so a zero threshold, which
    ///      setup refuses and no signature could vote under, is rejected here.
    function requireCreationRecord(
        uint256 sourceChainId,
        SafeAuthorityRecord memory record,
        SafeCreationProof memory proof
    ) internal pure {
        bytes32 initCodeHash;
        if (proof.singleton == SAFE_SINGLETON) initCodeHash = SAFE_PROXY_INITCODE_HASH;
        else if (proof.singleton == SAFE_L2_SINGLETON) initCodeHash = SAFE_L2_PROXY_INITCODE_HASH;
        else revert UnpinnedSingleton(proof.singleton);

        bytes32 initializerHash = keccak256(proof.initializer);
        bytes32 plainSalt = keccak256(abi.encodePacked(initializerHash, proof.saltNonce));
        bytes32 chainSalt = keccak256(abi.encodePacked(initializerHash, proof.saltNonce, sourceChainId));
        if (
            record.safe != AddressDerive.create2(SAFE_PROXY_FACTORY, plainSalt, initCodeHash)
                && record.safe != AddressDerive.create2(SAFE_PROXY_FACTORY, chainSalt, initCodeHash)
        ) revert CreationAddressMismatch(record.safe);

        (address[] memory owners, uint256 threshold, address to, bytes memory data) =
            abi.decode(Bytes.arguments(proof.initializer, SETUP), (address[], uint256, address, bytes));
        if (
            (to != address(0) || data.length != 0)
                && (to != SAFE_TO_L2_SETUP
                    || keccak256(data) != keccak256(abi.encodeWithSelector(SETUP_TO_L2, SAFE_L2_SINGLETON)))
        ) revert SetupCallNotAllowed(to);

        if (threshold == 0) revert ZeroCreationThreshold();
        if (threshold != record.threshold || owners.length != record.owners.length) revert CreationRecordMismatch();
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i] != record.owners[i].owner) revert CreationRecordMismatch();
        }
    }
}
