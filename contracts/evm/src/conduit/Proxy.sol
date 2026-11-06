// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The one call a `Proxy` accepts from its deployer. Declared separately so
///         callers have a selector without the proxy shadowing the implementation's ABI.
interface IProxy {
    function upgradeInitializeAndLock(address implementation, bytes calldata data) external;
}

/// @title Proxy
/// @notice The proxy every crossecute conduit is deployed as, transmitter and receiver alike,
///         and every transceiver, through `ProxyDeployer`. Its implementation is locked
///         once armed; its owner's authority is unchanged.
///
/// @dev No constructor arguments, so its initcode is one constant and a transmitter (from its
///      home's transceiver) and a receiver (from another chain's) at the same deployer address
///      and salt land on one address. An EIP-1167 clone embeds its implementation in the initcode and could not.
///
/// @dev The deployer can arm the proxy only while no implementation is set. The single admin
///      operation installs the implementation, runs its initializer, and by installing it ends
///      the deployer's ability to arm, so no conduit or transceiver ever has a live upgrade key
///      and real logic at once. An implementation must not write the ERC-1967 implementation
///      slot: clearing it would let the deployer arm again.
///
/// @dev The deployer is an immutable, so it sits in the runtime code and not the initcode: the
///      address is unchanged, but the code hash differs per deployer, and a proxy is verified by
///      its CREATE2 address. A call on an armed proxy reads the implementation slot and nothing else.
///
/// @dev The admin operation is routed in `fallback`, not declared, so it shadows no selector.
///      Once armed every call delegates, as in a plain ERC-1967 proxy.
contract Proxy {
    // forge-lint: disable-next-line(unused-error) reverted in assembly; declared for the ABI
    error UnknownAdminCall(bytes4 selector);

    event Locked(address implementation);

    // ERC1967Utils.IMPLEMENTATION_SLOT and the errors and events the arming call reports, as
    // literals so assembly can read them; `ProxyDifferential` compares every one against
    // the library-built reference.
    //
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // keccak256("Upgraded(address)"), IERC1967
    bytes32 private constant UPGRADED = 0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b;
    // keccak256("Locked(address)")
    bytes32 private constant LOCKED = 0x44427e3003a08f22cf803894075ac0297524e09e521fc1c15bc91741ce3dc159;
    // bytes4(keccak256("upgradeInitializeAndLock(address,bytes)"))
    uint256 private constant ARM = 0x885088b2;
    // bytes4(keccak256("UnknownAdminCall(bytes4)")), declared above
    uint256 private constant UNKNOWN_ADMIN_CALL = 0xf3e81dfa;
    // bytes4(keccak256("ERC1967InvalidImplementation(address)")), as in ERC1967Utils
    uint256 private constant INVALID_IMPLEMENTATION = 0x4c9c8ce3;
    // bytes4(keccak256("ERC1967NonPayable()")), as in ERC1967Utils
    uint256 private constant NON_PAYABLE = 0xb398979f;
    // bytes4(keccak256("FailedCall()")), as in OpenZeppelin's Errors
    uint256 private constant FAILED_CALL = 0xd6bda275;

    address private immutable ADMIN;

    constructor() {
        ADMIN = msg.sender;
    }

    fallback() external payable {
        address current;
        assembly {
            current := sload(IMPLEMENTATION_SLOT) // implementation; zero while the proxy is blank
        }

        // Armed, or not the deployer: an ordinary call. A blank proxy delegates to no code and
        // succeeds. `ADMIN` is read only while blank.
        if (current != address(0) || msg.sender != ADMIN) {
            assembly {
                calldatacopy(0, 0, calldatasize()) // copy the whole call to memory at 0
                let ok := delegatecall(gas(), current, 0, calldatasize(), 0, 0) // run it as this proxy
                returndatacopy(0, 0, returndatasize()) // copy its output, or its revert data, to memory at 0
                if iszero(ok) { revert(0, returndatasize()) } // pass a revert through unchanged
                return(0, returndatasize()) // return its output
            }
        }

        assembly {
            let size := calldatasize() // total bytes of calldata
            let sig := and(calldataload(0), shl(224, 0xffffffff)) // selector, left-aligned; zero-padded if short
            if iszero(eq(sig, shl(224, ARM))) {
                // anything but the arming selector is refused
                mstore(0, shl(224, UNKNOWN_ADMIN_CALL)) // UnknownAdminCall(bytes4), selector left-aligned at 0
                mstore(4, sig) // its argument, the selector received, at 4
                revert(0, 36) // selector and one 32-byte argument
            }

            // abi.decode(msg.data[4:], (address, bytes)), refusing what it refuses. A length over
            // 2^64 reverts with no data here and with Panic(0x41) there.
            if lt(size, 68) { revert(0, 0) } // needs the selector and both head words: 4 + 64
            let implementation := calldataload(4) // first argument
            if shr(160, implementation) { revert(0, 0) } // an address with high bits set is malformed
            let offset := calldataload(36) // second argument: where the bytes sit, counted after the selector
            if gt(offset, 0xffffffffffffffff) { revert(0, 0) } // keeps the additions below from wrapping
            let start := add(offset, 4) // position of the length word in calldata
            let length := calldataload(start) // number of initializer bytes; zero if read past the end
            if gt(length, 0xffffffffffffffff) { revert(0, 0) } // keeps `data + length` from wrapping
            let data := add(start, 32) // where the initializer bytes begin
            if gt(add(data, length), size) { revert(0, 0) } // must end in the calldata; refuses a far start

            if iszero(extcodesize(implementation)) {
                // an implementation with no code, or the zero address, is refused
                mstore(0, shl(224, INVALID_IMPLEMENTATION)) // ERC1967InvalidImplementation(address)
                mstore(4, implementation) // its argument at 4
                revert(0, 36) // selector and one 32-byte argument
            }
            sstore(IMPLEMENTATION_SLOT, implementation) // install it; the slot is now non-zero, which closes arming
            log2(0, 0, UPGRADED, implementation) // Upgraded(address indexed implementation), as ERC-1967

            switch length // with or without an initializer
            case 0 {
                // no initializer
                if callvalue() {
                    // ether would have nowhere to go: refused, as ERC1967Utils does
                    mstore(0, shl(224, NON_PAYABLE)) // ERC1967NonPayable()
                    revert(0, 4) // selector only
                }
            }
            default {
                // run the initializer
                let ptr := mload(0x40) // free memory, so the copy touches nothing in use
                calldatacopy(ptr, data, length) // copy the initializer bytes
                if iszero(delegatecall(gas(), implementation, ptr, length, 0, 0)) {
                    // run it as this proxy; a failure reverts the whole arming
                    if iszero(returndatasize()) {
                        // it reverted with no data
                        mstore(0, shl(224, FAILED_CALL)) // FailedCall(), so the revert is not silent
                        revert(0, 4) // selector only
                    }
                    returndatacopy(ptr, 0, returndatasize()) // copy its revert data
                    revert(ptr, returndatasize()) // pass it through unchanged
                }
            }

            mstore(0, implementation) // the one data word of Locked
            log1(0, 32, LOCKED) // Locked(address implementation)
            return(0, 0) // the arming call returns nothing
        }
    }
}
