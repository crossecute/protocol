// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

/// @notice The one call a `CrossProxy` accepts from its deployer. Declared separately so
///         callers have a selector without the proxy shadowing the implementation's ABI.
interface ICrossProxy {
    function upgradeInitializeAndLock(address implementation, bytes calldata data) external;
}

/// @title CrossProxy
/// @notice The proxy every crossecute account is deployed as, transmitter and receiver alike,
///         and every transceiver, through `CrossProxyDeployer`.
///
/// @dev No constructor arguments, so its initcode is one constant and a transmitter (from its
///      home's transceiver) and a receiver (from another chain's) at the same deployer address
///      and salt land on one address. An EIP-1167 clone embeds its implementation in the initcode and could not.
///
/// @dev The single admin operation upgrades, initializes, and zeroes the admin in one call, so
///      no account or transceiver ever has a live upgrade key and real logic at once.
///
/// @dev The admin operation is routed in `fallback`, not declared, so it shadows no selector.
///      Once the admin is zeroed every call delegates, as in a plain ERC-1967 proxy.
contract CrossProxy is Proxy {
    error UnknownAdminCall(bytes4 selector);

    event Locked(address implementation);

    /// @dev The deployer is the admin, set in storage so it never reaches the initcode.
    constructor() {
        ERC1967Utils.changeAdmin(msg.sender);
    }

    function _implementation() internal view override returns (address) {
        return ERC1967Utils.getImplementation();
    }

    fallback() external payable override {
        address admin = ERC1967Utils.getAdmin();

        // Not the admin (or there is no longer one), so this is an ordinary call.
        if (admin == address(0) || msg.sender != admin) {
            _fallback();
            return;
        }

        if (msg.sig != ICrossProxy.upgradeInitializeAndLock.selector) {
            revert UnknownAdminCall(msg.sig);
        }

        (address implementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));

        ERC1967Utils.upgradeToAndCall(implementation, data);

        // Written directly: `ERC1967Utils.changeAdmin` refuses the zero address.
        StorageSlot.getAddressSlot(ERC1967Utils.ADMIN_SLOT).value = address(0);
        emit Locked(implementation);
    }
}
