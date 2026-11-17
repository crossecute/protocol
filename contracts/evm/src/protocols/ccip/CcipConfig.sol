// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library CcipConfig {
    error InvalidCcipVerifiers();

    function validateCCVs(address[] memory ccvs) internal pure {
        if (ccvs.length > type(uint8).max) revert InvalidCcipVerifiers();
        for (uint256 i; i < ccvs.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (ccvs[i] == ccvs[j]) revert InvalidCcipVerifiers();
            }
        }
    }

    struct Policy {
        address[] requiredCCVs;
        address[] optionalCCVs;
        uint8 optionalThreshold;
        bytes4 allowedFinalityConfig;
    }

    /// @custom:storage-location erc7201:crossecute.storage.CcipConfig
    struct Layout {
        mapping(bytes32 => Policy) policies;
        mapping(uint64 => bool) v3Lanes;
    }

    // keccak256(abi.encode(uint256(keccak256("crossecute.storage.CcipConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT = 0x9f1afc8cdfee5c3ad7755e8a6e5a17be67970013b52ff2ebc2d83b0e1a156500;

    function layout() internal pure returns (Layout storage state) {
        bytes32 slot = SLOT;
        assembly {
            state.slot := slot
        }
    }

    function policyKey(uint64 source, bytes memory sender) internal pure returns (bytes32) {
        return keccak256(abi.encode(source, sender));
    }
}

interface ICcipLaneConfig {
    function ccipV3LaneEnabled(uint64 destination) external view returns (bool);
}
