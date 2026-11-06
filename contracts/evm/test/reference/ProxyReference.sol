// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IProxy} from "src/conduit/Proxy.sol";

/// @notice The previous `Proxy`, written against OpenZeppelin's `ERC1967Utils` and `Proxy`, kept
///         as the behavior the current `Proxy` must match call for call. `ProxyDifferential.t.sol`
///         holds the two together.
contract ProxyReference is Proxy {
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

        if (current != address(0) || msg.sender != ADMIN) _delegate(current);

        if (msg.sig != IProxy.upgradeInitializeAndLock.selector) {
            revert UnknownAdminCall(msg.sig);
        }

        (address implementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));

        ERC1967Utils.upgradeToAndCall(implementation, data);
        emit Locked(implementation);
    }
}
