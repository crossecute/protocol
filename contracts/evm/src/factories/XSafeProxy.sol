// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

/// @notice The one call an `XSafeProxy` accepts from its deployer. Declared separately
///         so callers have a typed interface and a selector to compute, without the proxy
///         declaring a function that would shadow the implementation's ABI.
interface IXSafeProxy {
    function upgradeInitializeAndLock(address implementation, bytes calldata data)
        external;
}

/// @title XSafeProxy
/// @notice The proxy every xsafe account is deployed as — transmitter and receiver alike.
///
/// @dev IT TAKES NO CONSTRUCTOR ARGUMENTS, AND THAT IS THE ENTIRE POINT. CREATE2 hashes the
///      initcode, so anything baked into it changes the address. A minimal clone cannot be
///      used here for exactly that reason: EIP-1167 embeds the implementation address in
///      its initcode, so a transmitter clone and a receiver clone can never share an
///      address however their deployer and salt are chosen.
///
///      With no arguments the initcode is one constant byte string, identical everywhere.
///      A transmitter deployed by the hub and a receiver deployed by a spoke — same
///      deployer address, same salt, same initcode — therefore land on ONE address, and
///      diverge only in what they are upgraded to afterwards, which the derivation never
///      sees. That is the argument that lets a hub and a spoke share an address, applied
///      one level down.
///
/// @dev THERE IS NO WAY TO UPGRADE WITHOUT LOCKING. The single admin operation upgrades,
///      runs the initializer, and zeroes the admin, in that order and in one call. Not
///      "the deployer is expected to lock afterwards" — there is no reachable state in
///      which an account has a live upgrade key and a real implementation at the same
///      time. That is what makes an upgradeable full-power account acceptable: the key
///      exists for part of one transaction, held by the contract that created the account,
///      and cannot outlive it.
///
/// @dev DISPATCH IS TRANSPARENT-STYLE, WHICH MATTERS AFTER THE LOCK. The admin operation
///      is routed inside `fallback` rather than declared as an external function, because
///      a declared one would shadow that selector on the implementation forever. Once the
///      admin is zeroed no caller can match it — `msg.sender` is never the zero address —
///      so every selector delegates from then on and this is indistinguishable from a
///      plain ERC-1967 proxy.
contract XSafeProxy is Proxy {
    error UnknownAdminCall(bytes4 selector);

    event Locked(address implementation);

    /// @dev The deployer is the admin. Set in storage rather than taken as an argument,
    ///      so it never reaches the initcode.
    constructor() {
        ERC1967Utils.changeAdmin(msg.sender);
    }

    function _implementation() internal view override returns (address) {
        return ERC1967Utils.getImplementation();
    }

    fallback() external payable override {
        address admin = ERC1967Utils.getAdmin();

        // Not the admin — or there is no longer one — so this is an ordinary call.
        if (admin == address(0) || msg.sender != admin) {
            _fallback();
            return;
        }

        if (msg.sig != IXSafeProxy.upgradeInitializeAndLock.selector) {
            revert UnknownAdminCall(msg.sig);
        }

        (address implementation, bytes memory data) =
            abi.decode(msg.data[4:], (address, bytes));

        ERC1967Utils.upgradeToAndCall(implementation, data);

        // The slot is written directly because `ERC1967Utils.changeAdmin` refuses the
        // zero address — it assumes an admin is being handed over rather than retired.
        // Retiring it is exactly what this does, and there is no other way to say so.
        StorageSlot.getAddressSlot(ERC1967Utils.ADMIN_SLOT).value = address(0);
        emit Locked(implementation);
    }
}
