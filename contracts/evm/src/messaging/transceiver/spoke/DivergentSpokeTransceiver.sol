// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {CrossProxy} from "src/account/CrossProxy.sol";

/// @title DivergentSpokeTransceiver
/// @notice The spokes whose chain derives account addresses differently from Ethereum:
///         zkSync Era and Tron. Everything else about them is `SpokeTransceiverBase`.
///
/// @dev Both are `eip155`, so only the spoke's own bytecode can know its chain's formula:
///      these are what make `SpokeTransceiverBase.addressesDiverge` operative.
///
/// @dev Forge runs Ethereum's EVM, so the suite pins only that each override reproduces
///      `AddressDerive`'s formula, that the bytecode hash is write-once, and that a mismatch
///      is refused by `_createCrossAccount`. Deploying one account on Era and on Shasta is
///      still open: see [todo](../../../../../../docs/todo.md#3-smaller-open-questions).
///
/// @dev zksolc 1.5.17 over era-solc 0.8.28-1.0.2 builds `CrossProxy` and every contract a
///      spoke needs. `BitcoinDerive` is split from `AddressDerive` for this: EraVM has no
///      `ripemd160`, and zksolc rejects a compilation unit that contains it at all.
///
/// @dev Each takes its account bytecode hash at initialization, write-once, since
///      `CROSS_PROXY_INIT_CODE_HASH` is solc's and neither chain consumes it: zkSync hashes a
///      zksolc artifact into an EraVM versioned hash, and Tron uses TRON-solc's initcode.
abstract contract DivergentSpokeTransceiver is SpokeTransceiverBase {
    /// The hash this chain's deployer keys an account address by, in that chain's own form.
    bytes32 public accountBytecodeHash;

    event AccountBytecodeHashSet(bytes32 accountBytecodeHash);

    error ZeroAccountBytecodeHash();

    /// @param accountBytecodeHash_ For zkSync, `AddressDerive.hashL2Bytecode` over the
    ///        zksolc artifact for `CrossProxy`. For Tron, `keccak256` of TRON-solc's
    ///        `CrossProxy` initcode. Getting it wrong does not misdeliver: every account
    ///        creation on this spoke reverts `AccountAddressMismatch` until it is right.
    function __DivergentSpoke_init(bytes32 accountBytecodeHash_) internal onlyInitializing {
        if (accountBytecodeHash_ == bytes32(0)) revert ZeroAccountBytecodeHash();
        accountBytecodeHash = accountBytecodeHash_;
        emit AccountBytecodeHashSet(accountBytecodeHash_);
    }
}

/// @title ZkSyncSpokeTransceiver
/// @notice A spoke on zkSync Era, which diverges in BOTH seams.
///
/// @dev The address: `zksyncCreate2` folds `keccak256("zksyncCreate2")`, the padded sender,
///      the salt, the EraVM versioned bytecode hash, and the constructor-input hash, which is
///      the constant `keccak256("")` for the argument-free `CrossProxy`.
///
/// @dev The deployment: EraVM cannot deploy raw initcode; `new CrossProxy{salt: s}()` is what
///      zksolc lowers into the `ContractDeployer` system call. zksolc only warns on the base's
///      `Create2.deploy`, so a spoke missing this override would build and fail on its first
///      account.
///
/// @dev Under solc, `new ... {salt:}` is ordinary CREATE2, so in this repo's build the
///      deployment lands at Ethereum's address and the guard refuses: it fails closed.
abstract contract ZkSyncSpokeTransceiver is DivergentSpokeTransceiver {
    /// @dev `CrossProxy` takes no constructor arguments, so the input is empty.
    bytes32 internal constant EMPTY_CONSTRUCTOR_INPUT_HASH = keccak256("");

    /// @inheritdoc TransceiverBase
    function predictCrossAccount(address owner, bytes32 salt) public view virtual override returns (address) {
        return AddressDerive.zksyncCreate2(
            address(this), accountSalt(owner, salt), accountBytecodeHash, EMPTY_CONSTRUCTOR_INPUT_HASH
        );
    }

    /// @inheritdoc TransceiverBase
    function _deployAccount(bytes32 salt) internal virtual override returns (address) {
        return address(new CrossProxy{salt: salt}());
    }
}

/// @title TronSpokeTransceiver
/// @notice A spoke on Tron, which diverges in the formula only.
///
/// @dev EIP-1014's preimage with `0x41` in place of `0xff`. Tron's documentation conflicts on
///      which byte the high-level `new {salt:}` form uses (see `AddressDerive.tronCreate2`);
///      until one account is deployed through this spoke on Shasta and compared, a Tron
///      deployment is unverified.
///
/// @dev Tron runs raw-initcode CREATE2, so the base's `_deployAccount` stands.
abstract contract TronSpokeTransceiver is DivergentSpokeTransceiver {
    /// @inheritdoc TransceiverBase
    function predictCrossAccount(address owner, bytes32 salt) public view virtual override returns (address) {
        return AddressDerive.tronCreate2(address(this), accountSalt(owner, salt), accountBytecodeHash);
    }
}
