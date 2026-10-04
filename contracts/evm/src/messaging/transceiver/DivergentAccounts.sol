// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {CrossProxy} from "src/account/CrossProxy.sol";

/// @title DivergentAccounts
/// @notice Account derivation for the chains whose CREATE2 differs from Ethereum's: zkSync Era
///         and Tron. Shared by every transceiver deployed there.
///
/// @dev Both are `eip155`, so only the transceiver's own bytecode can know its chain's formula.
///
/// @dev Forge runs Ethereum's EVM, so the suite pins only that each override reproduces
///      `AddressDerive`'s formula, that the bytecode hash is write-once, and that a mismatch
///      is refused by `_createCrossAccount`. Deploying one account on Era and on Shasta is
///      still open: see [todo](../../../../../docs/todo.md#2-chain-checks-before-mainnet).
///
/// @dev zksolc 1.5.17 over era-solc 0.8.28-1.0.2 builds `CrossProxy` and every contract a
///      transceiver needs. `BitcoinDerive` is split from `AddressDerive` for this: EraVM has no
///      `ripemd160`, and zksolc rejects a compilation unit that contains it at all.
///
/// @dev Not a `TransceiverBase`: a mixin that did inherit it would meet every transceiver base's
///      own overrides in a diamond. Each transceiver overrides `predictCrossAccount` and
///      `_deployAccount` with a one-line call into the helpers below.
abstract contract DivergentAccounts is Initializable {
    /// The hash this chain's deployer keys an account address by, in that chain's own form.
    /// @dev Write-once. Not `CROSS_PROXY_INIT_CODE_HASH`, which hashes the local compiler's
    ///      `creationCode` and is not what either deployer keys by: zkSync hashes a zksolc
    ///      artifact into an EraVM versioned hash, and Tron uses TRON-solc's initcode.
    bytes32 public accountBytecodeHash;

    event AccountBytecodeHashSet(bytes32 accountBytecodeHash);

    error ZeroAccountBytecodeHash();

    /// @param accountBytecodeHash_ For zkSync, `AddressDerive.hashL2Bytecode` over the
    ///        zksolc artifact for `CrossProxy`. For Tron, `keccak256` of Tron-solc's
    ///        `CrossProxy` initcode. Getting it wrong does not misdeliver: every account
    ///        creation reverts `AccountAddressMismatch` until it is right.
    function __DivergentAccounts_init(bytes32 accountBytecodeHash_) internal onlyInitializing {
        if (accountBytecodeHash_ == bytes32(0)) revert ZeroAccountBytecodeHash();
        accountBytecodeHash = accountBytecodeHash_;
        emit AccountBytecodeHashSet(accountBytecodeHash_);
    }
}

/// @title ZkSyncAccounts
/// @notice zkSync Era, which diverges in both seams.
///
/// @dev The address: `zksyncCreate2` folds `keccak256("zksyncCreate2")`, the padded sender,
///      the salt, the EraVM versioned bytecode hash, and the constructor-input hash, which is
///      the constant `keccak256("")` for the argument-free `CrossProxy`.
///
/// @dev The deployment: EraVM cannot deploy raw initcode; `new CrossProxy{salt: s}()` is what
///      zksolc lowers into the `ContractDeployer` system call. zksolc only warns on the base's
///      `Create2.deploy`, so a transceiver missing this override would build and fail on its
///      first account.
///
/// @dev Under solc, `new ... {salt:}` is ordinary CREATE2, so in this repo's build the
///      deployment lands at Ethereum's address and the guard refuses: it fails closed.
abstract contract ZkSyncAccounts is DivergentAccounts {
    /// @dev `CrossProxy` takes no constructor arguments, so the input is empty.
    bytes32 internal constant EMPTY_CONSTRUCTOR_INPUT_HASH = keccak256("");

    /// @notice Where this contract deploys an account at `accountSalt` on Era.
    function _zkSyncAccount(bytes32 accountSalt) internal view returns (address) {
        return
            AddressDerive.zksyncCreate2(address(this), accountSalt, accountBytecodeHash, EMPTY_CONSTRUCTOR_INPUT_HASH);
    }

    /// @notice Deploy an account the way Era can: through the `ContractDeployer` system call.
    function _zkSyncDeploy(bytes32 accountSalt) internal returns (address) {
        return address(new CrossProxy{salt: accountSalt}());
    }
}

/// @title TronAccounts
/// @notice Tron, which diverges in the formula only.
///
/// @dev EIP-1014's preimage with `0x41` in place of `0xff`. Tron's documentation conflicts on
///      which byte the high-level `new {salt:}` form uses (see `AddressDerive.tronCreate2`);
///      until one account is deployed on Shasta and compared, a Tron deployment is unverified.
///
/// @dev Tron runs raw-initcode CREATE2, so the base's `_deployAccount` stands.
abstract contract TronAccounts is DivergentAccounts {
    /// @notice Where this contract deploys an account at `accountSalt` on Tron.
    function _tronAccount(bytes32 accountSalt) internal view returns (address) {
        return AddressDerive.tronCreate2(address(this), accountSalt, accountBytecodeHash);
    }
}
