// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {CrossecuteGuard} from "../src/CrossecuteGuard.sol";

/// @dev Exposes a Safe's raw transient record so tests can check that cleanup zeroes every word.
///      Transient storage only survives within one transaction, so a test reads it from inside the
///      same `Batch` that ran the execution.
contract CrossecuteGuardHarness is CrossecuteGuard {
    constructor(uint256 delay, uint256 expiry) CrossecuteGuard(delay, expiry) {}

    function recordWords(address safe, uint256 signatureWords) external view returns (uint256[] memory words) {
        bytes32 safeId = _safeId(safe);
        words = new uint256[](_SIG_WORDS + signatureWords);
        for (uint256 i = 0; i < words.length; ++i) {
            words[i] = _tload(safeId, i);
        }
    }

    error RecordNotCleared(uint256 word);

    function requireCleared(address safe, uint256 signatureWords) external view {
        uint256[] memory words = this.recordWords(safe, signatureWords);
        for (uint256 i = 0; i < words.length; ++i) {
            require(words[i] == 0, RecordNotCleared(i));
        }
    }
}
