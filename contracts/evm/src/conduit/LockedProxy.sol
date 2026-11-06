// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @notice The one call a `LockedProxy` accepts from its deployer. Declared separately so
///         callers have a selector without the proxy shadowing the implementation's ABI.
interface ILockedProxy {
    function upgradeInitializeAndLock(address implementation, bytes calldata data) external;
}

/// @title LockedProxy
/// @notice The proxy every crossecute conduit is deployed as, transmitter and receiver alike,
///         and every transceiver, through `LockedProxyDeployer`.
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
contract LockedProxy is Proxy {
    error UnknownAdminCall(bytes4 selector);

    event Locked(address implementation);

    address private immutable ADMIN;

    constructor() {
        ADMIN = msg.sender;
    }

    function _implementation() internal view override returns (address) {
        return ERC1967Utils.getImplementation();
    }

    fallback() external payable override {
        address current = _implementation();

        // Armed, or not the deployer: an ordinary call, and `_delegate` does not return.
        // `ADMIN` is read only while blank.
        if (current != address(0) || msg.sender != ADMIN) _delegate(current);

        if (msg.sig != ILockedProxy.upgradeInitializeAndLock.selector) {
            revert UnknownAdminCall(msg.sig);
        }

        (address implementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));

        ERC1967Utils.upgradeToAndCall(implementation, data);
        emit Locked(implementation);
    }
}
