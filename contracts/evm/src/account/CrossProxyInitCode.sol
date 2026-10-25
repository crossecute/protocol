// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CrossProxy} from "src/account/CrossProxy.sol";

/// @notice `CrossProxy`'s initcode held by another contract, which returns it to any call, so a
///         contract that deploys accounts reads it rather than carrying 1.5 KB of it in its own
///         runtime (#70).
///
/// @dev CREATE2 hashes the initcode bytes, not where they were read from, so an account deployed
///      from the loaded copy lands where `CROSS_PROXY_INIT_CODE_HASH` predicts.
///
/// @dev Read by `STATICCALL` rather than `EXTCODECOPY`, which zksolc refuses to compile: every
///      contract a zkSync variant's imports reach is compiled for EraVM, the plain transceivers
///      among them.
library CrossProxyInitCode {
    error StoreFailed();

    /// @notice What every CREATE2 prediction of an account hashes.
    function hash() internal pure returns (bytes32) {
        return keccak256(type(CrossProxy).creationCode);
    }

    /// @notice Deploy the code-only contract. `CrossProxy`'s initcode appears only in the caller's
    ///         initcode when this runs from a constructor.
    function store() internal returns (address at) {
        bytes memory initCode = type(CrossProxy).creationCode;
        // PUSH2 len, DUP1, PUSH1 12, PUSH1 0, CODECOPY, PUSH1 0, RETURN: on any call, returns what
        // follows this 12-byte prefix, the initcode.
        // forge-lint: disable-next-line(unsafe-typecast) a constant 1.5 KB
        bytes memory runtime = abi.encodePacked(hex"61", uint16(initCode.length), hex"80600c6000396000f3", initCode);
        // The same prefix shape, 14 bytes with PUSH4: returns `runtime` as the new contract's code.
        // forge-lint: disable-next-line(unsafe-typecast) a constant 1.5 KB
        bytes memory creation = abi.encodePacked(hex"63", uint32(runtime.length), hex"80600e6000396000f3", runtime);
        assembly {
            at := create(0, add(creation, 0x20), mload(creation))
        }
        if (at == address(0)) revert StoreFailed();
    }

    /// @notice The initcode `store` kept at `at`.
    function load(address at) internal view returns (bytes memory code) {
        bool ok;
        (ok, code) = at.staticcall("");
        if (!ok || code.length == 0) revert StoreFailed();
    }
}
