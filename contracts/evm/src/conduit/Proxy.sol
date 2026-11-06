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
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant UPGRADED = 0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b;
    bytes32 private constant LOCKED = 0x44427e3003a08f22cf803894075ac0297524e09e521fc1c15bc91741ce3dc159;
    uint256 private constant ARM = 0x885088b2;
    uint256 private constant UNKNOWN_ADMIN_CALL = 0xf3e81dfa;
    uint256 private constant INVALID_IMPLEMENTATION = 0x4c9c8ce3;
    uint256 private constant NON_PAYABLE = 0xb398979f;
    uint256 private constant FAILED_CALL = 0xd6bda275;

    address private immutable ADMIN;

    constructor() {
        ADMIN = msg.sender;
    }

    fallback() external payable {
        address current;
        assembly {
            current := sload(IMPLEMENTATION_SLOT)
        }

        // Armed, or not the deployer: an ordinary call. `ADMIN` is read only while blank.
        if (current != address(0) || msg.sender != ADMIN) {
            assembly {
                calldatacopy(0, 0, calldatasize())
                let ok := delegatecall(gas(), current, 0, calldatasize(), 0, 0)
                returndatacopy(0, 0, returndatasize())
                if iszero(ok) { revert(0, returndatasize()) }
                return(0, returndatasize())
            }
        }

        assembly {
            let size := calldatasize()
            let sig := and(calldataload(0), shl(224, 0xffffffff))
            if iszero(eq(sig, shl(224, ARM))) {
                mstore(0, shl(224, UNKNOWN_ADMIN_CALL))
                mstore(4, sig)
                revert(0, 36)
            }

            // abi.decode(msg.data[4:], (address, bytes)), refusing what it refuses. A length over
            // 2^64 reverts with no data here and with Panic(0x41) there.
            if lt(size, 68) { revert(0, 0) }
            let implementation := calldataload(4)
            if shr(160, implementation) { revert(0, 0) }
            let offset := calldataload(36)
            if gt(offset, 0xffffffffffffffff) { revert(0, 0) }
            let start := add(offset, 4)
            let length := calldataload(start)
            if gt(length, 0xffffffffffffffff) { revert(0, 0) }
            let data := add(start, 32)
            if gt(add(data, length), size) { revert(0, 0) }

            if iszero(extcodesize(implementation)) {
                mstore(0, shl(224, INVALID_IMPLEMENTATION))
                mstore(4, implementation)
                revert(0, 36)
            }
            sstore(IMPLEMENTATION_SLOT, implementation)
            log2(0, 0, UPGRADED, implementation)

            switch length
            case 0 {
                if callvalue() {
                    mstore(0, shl(224, NON_PAYABLE))
                    revert(0, 4)
                }
            }
            default {
                let ptr := mload(0x40)
                calldatacopy(ptr, data, length)
                if iszero(delegatecall(gas(), implementation, ptr, length, 0, 0)) {
                    if iszero(returndatasize()) {
                        mstore(0, shl(224, FAILED_CALL))
                        revert(0, 4)
                    }
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }

            mstore(0, implementation)
            log1(0, 32, LOCKED)
            return(0, 0)
        }
    }
}
