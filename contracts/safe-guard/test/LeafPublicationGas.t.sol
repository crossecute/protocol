// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {console2} from "forge-std/console2.sol";
import {GuardTestBase} from "./GuardTestBase.sol";
import {MerkleReference} from "./LeafPublication.t.sol";

/// @dev Measures `publishLeaves` execution gas by leaf count, for 448-byte execution leaves. Calldata
///      and the transaction's intrinsic cost are excluded. Reported in contracts/safe-guard/README.md.
contract LeafPublicationGasTest is GuardTestBase {
    function test_gas_publishLeaves() public {
        uint256[4] memory counts = [uint256(1), 3, 16, 256];
        for (uint256 i = 0; i < counts.length; ++i) {
            bytes[] memory leaves = MerkleReference.executionLeaves(counts[i]);
            uint256 before = gasleft();
            guard.publishLeaves(leaves);
            uint256 used = before - gasleft();
            console2.log("leaves", counts[i]);
            console2.log("  publication", used);
        }
    }
}
