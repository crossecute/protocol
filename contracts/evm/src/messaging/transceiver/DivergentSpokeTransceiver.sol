// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {CrossProxy} from "src/factories/CrossProxy.sol";

/// @title DivergentSpokeTransceiver
/// @notice The two spokes whose chain derives account addresses differently from Ethereum:
///         zkSync Era and Tron. Everything else about them is `SpokeTransceiverBase`.
///
/// @dev THEY ARE `eip155`, WHICH IS WHY THEY NEED A CONTRACT RATHER THAN A FLAG. Nothing
///      about the chain type separates zkSync and Tron from Base, and only the spoke itself
///      knows which formula its chain uses, so the knowledge lives in the bytecode deployed
///      there. This is `SpokeTransceiverBase.addressesDiverge` made operative: that flag
///      says the hub cannot derive these addresses, and these contracts are what can.
///
/// @dev NEITHER CAN BE EXERCISED BY THIS REPO'S TEST SUITE, AND THAT IS NOT A GAP IN THE
///      TESTS. Forge runs an Ethereum EVM, so a deployment here lands at Ethereum's address
///      whatever these predict; what the suite CAN pin is that each override reproduces
///      `AddressDerive`'s formula exactly, that the bytecode hash is write-once, and that a
///      mismatch is refused by `_createCrossAccount`'s guard rather than arming nothing.
///      What remains is deploying one account on Era and on Shasta and comparing: see
///      [todo](../../../../../docs/todo.md#3-blockers-on-specific-paths).
///
/// @dev THE ZKSYNC SIDE COMPILES, CHECKED RATHER THAN ASSUMED. zksolc 1.5.17 over era-solc
///      0.8.28-1.0.2 builds `CrossProxy` and every contract a spoke needs, under both
///      codegens, and emits real EraVM bytecode. It did NOT before `BitcoinDerive` was split
///      out of `AddressDerive`: EraVM has no `ripemd160`, and zksolc rejects the whole
///      compilation unit rather than the unreachable function, so importing `AddressDerive`
///      for `zksyncCreate2` dragged `hash160` in and failed the build.
///
/// @dev BOTH TAKE THEIR ACCOUNT BYTECODE HASH AS AN ARGUMENT, because neither can compute
///      it. `TransceiverBase.CROSS_PROXY_INIT_CODE_HASH` is `keccak256` of SOLC's initcode,
///      and neither chain consumes that: zkSync hashes a zksolc artifact into an EraVM
///      versioned hash, and Tron wants TRON-solc's initcode. The value therefore comes from
///      the build for that chain, is passed at initialization, and is write-once like every
///      other value on a spoke.
abstract contract DivergentSpokeTransceiver is SpokeTransceiverBase {
    /// The hash this chain's deployer keys an account address by, in that chain's own form.
    bytes32 public accountBytecodeHash;

    event AccountBytecodeHashSet(bytes32 accountBytecodeHash);

    error ZeroAccountBytecodeHash();

    /// @param accountBytecodeHash_ For zkSync, `AddressDerive.hashL2Bytecode` over the
    ///        zksolc artifact for `CrossProxy`. For Tron, `keccak256` of TRON-solc's
    ///        `CrossProxy` initcode. Getting it wrong does not misdeliver: every account
    ///        creation on this spoke reverts `AccountAddressMismatch` until it is right.
    function __DivergentSpoke_init(bytes32 accountBytecodeHash_)
        internal
        onlyInitializing
    {
        if (accountBytecodeHash_ == bytes32(0)) revert ZeroAccountBytecodeHash();
        accountBytecodeHash = accountBytecodeHash_;
        emit AccountBytecodeHashSet(accountBytecodeHash_);
    }
}

/// @title ZkSyncSpokeTransceiver
/// @notice A spoke on zkSync Era, which diverges in BOTH seams.
///
/// @dev THE ADDRESS IS A DIFFERENT HASH CHAIN. `zksyncCreate2` folds
///      `keccak256("zksyncCreate2")`, the padded sender, the salt, the EraVM versioned
///      bytecode hash, and the hash of the constructor input. `CrossProxy` takes no
///      constructor arguments, so the last is `keccak256("")` and is a constant here.
///
/// @dev AND THE DEPLOYMENT IS A DIFFERENT MECHANISM, which is the part that cannot be
///      papered over with arithmetic. zkSync cannot deploy raw initcode at all: deployment
///      goes through the `ContractDeployer` system contract against a bytecode hash
///      published in advance, so `Create2.deploy(0, salt, type(CrossProxy).creationCode)`
///      is not a thing that runs there. `new CrossProxy{salt: s}()` is what zksolc lowers
///      into that system call, so it is what this emits.
///
///      THE COMPILER SAYS SO ITSELF: building the base's `_deployAccount` under zksolc warns
///      "EraVM does not use bytecode for contract deployment... please use the `new`
///      operator in Solidity instead of raw create/create2 in assembly". It is a warning
///      rather than an error, so a spoke that forgot this override would build and then fail
///      on the first account, which is what makes the override worth stating loudly.
///
/// @dev COMPILED WITH SOLC IT IS SAFE RATHER THAN CORRECT. `new ... {salt:}` lowers to
///      ordinary CREATE2 under solc, so in this repo's build the deployment lands at
///      Ethereum's address while `predictCrossAccount` returns zkSync's, and the guard
///      refuses. It fails closed here and works only where it is meant to run.
abstract contract ZkSyncSpokeTransceiver is DivergentSpokeTransceiver {
    /// @dev `CrossProxy` takes no constructor arguments, so the input is empty.
    bytes32 internal constant EMPTY_CONSTRUCTOR_INPUT_HASH = keccak256("");

    /// @inheritdoc TransceiverBase
    function predictCrossAccount(address owner, bytes32 salt)
        public
        view
        virtual
        override
        returns (address)
    {
        return AddressDerive.zksyncCreate2(
            address(this),
            accountSalt(owner, salt),
            accountBytecodeHash,
            EMPTY_CONSTRUCTOR_INPUT_HASH
        );
    }

    /// @inheritdoc TransceiverBase
    function _deployAccount(bytes32 salt)
        internal
        virtual
        override
        returns (address)
    {
        return address(new CrossProxy{salt: salt}());
    }
}

/// @title TronSpokeTransceiver
/// @notice A spoke on Tron, which diverges in the formula only.
///
/// @dev ONE BYTE, AND IT IS THE ONE THE DOCS DISAGREE ABOUT. The preimage is EIP-1014's
///      exactly; only the domain separator differs, `0x41` where Ethereum uses `0xff`.
///      Tron's own documentation conflicts on whether the high-level `new {salt:}` form
///      uses `0x41` or `0xff`, and `AddressDerive.tronCreate2` carries that caveat. It is
///      NOT resolved by writing this contract: it is resolved by deploying one account
///      through this spoke on Shasta and comparing. Until that is done, treat a Tron
///      deployment as unverified rather than merely untested.
///
/// @dev THE DEPLOYMENT SEAM IS NOT OVERRIDDEN, because Tron does run raw-initcode CREATE2;
///      it simply derives a different address from it. So the base's `_deployAccount`
///      stands, and only the prediction moves.
abstract contract TronSpokeTransceiver is DivergentSpokeTransceiver {
    /// @inheritdoc TransceiverBase
    function predictCrossAccount(address owner, bytes32 salt)
        public
        view
        virtual
        override
        returns (address)
    {
        return AddressDerive.tronCreate2(
            address(this), accountSalt(owner, salt), accountBytecodeHash
        );
    }
}
