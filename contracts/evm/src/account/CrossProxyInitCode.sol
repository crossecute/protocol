// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CrossProxy} from "src/account/CrossProxy.sol";

/// @notice `CrossProxy`'s initcode kept as another contract's code, so a contract that deploys
///         accounts reads it with `EXTCODECOPY` rather than carrying 1.5 KB of it in its own
///         runtime (#70).
///
/// @dev CREATE2 hashes the initcode bytes, not where they were read from, so an account deployed
///      from the loaded copy lands where `CROSS_PROXY_INIT_CODE_HASH` predicts. The stored code is
///      a STOP byte followed by the initcode, so a call to it does nothing.
library CrossProxyInitCode {
    error StoreFailed();

    /// @notice Deploy the code-only contract. `CrossProxy`'s initcode appears only in the caller's
    ///         initcode when this runs from a constructor.
    function store() internal returns (address at) {
        bytes memory runtime = abi.encodePacked(hex"00", type(CrossProxy).creationCode);
        // PUSH4 len, DUP1, PUSH1 14, PUSH1 0, CODECOPY, PUSH1 0, RETURN: copies what follows this
        // 14-byte prefix, `runtime`, and returns it as the new contract's code.
        // forge-lint: disable-next-line(unsafe-typecast) a constant 1.5 KB
        bytes memory creation = abi.encodePacked(hex"63", uint32(runtime.length), hex"80600e6000396000f3", runtime);
        assembly {
            at := create(0, add(creation, 0x20), mload(creation))
        }
        if (at == address(0)) revert StoreFailed();
    }

    /// @notice The initcode `store` kept at `at`.
    function load(address at) internal view returns (bytes memory code) {
        uint256 size = at.code.length - 1;
        code = new bytes(size);
        assembly {
            extcodecopy(at, add(code, 0x20), 1, size)
        }
    }
}
