// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {AllowPolicy} from "policy-engine/policies/AllowPolicy.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {CompatibilityFallbackHandler} from "safe-smart-account/handler/CompatibilityFallbackHandler.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {MultiSendCallOnly} from "safe-smart-account/libraries/MultiSendCallOnly.sol";
import {SignMessageLib} from "safe-smart-account/libraries/SignMessageLib.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";
import {CrossecuteGuardHarness} from "./CrossecuteGuardHarness.sol";

/// @dev Real Safe 1.5.0 proxies, signed with real owner keys. Nothing in the signing or execution
///      path is mocked.
abstract contract SafeFixture is Test {
    /// @dev `keccak256("SafePolicyGuard.PolicyContext.v1")`, restated as an independent oracle.
    bytes32 internal constant POLICY_CONTEXT_TYPE = keccak256("SafePolicyGuard.PolicyContext.v1");

    /// @dev One entry in a Safe signature blob. An EOA owner sets `key`. A child Safe owner sets
    ///      `childKeys` to sign its message directly, or `approved` to send an empty payload that its
    ///      handler checks against `signedMessages`.
    struct Signer {
        address owner;
        uint256 key;
        uint256[] childKeys;
        bool approved;
    }

    Safe internal singleton;
    SafeProxyFactory internal factory;
    CompatibilityFallbackHandler internal handler;
    MultiSendCallOnly internal multiSend;
    SignMessageLib internal signMessageLib;
    AllowPolicy internal allowPolicy;
    CrossecuteGuardHarness internal guard;
    uint256 private _saltNonce;

    function setUp() public virtual {
        singleton = new Safe();
        factory = new SafeProxyFactory();
        handler = new CompatibilityFallbackHandler();
        multiSend = new MultiSendCallOnly();
        signMessageLib = new SignMessageLib();
        allowPolicy = new AllowPolicy();
        guard = new CrossecuteGuardHarness(0, 1 days);
    }

    function _newSafe(address[] memory owners, uint256 threshold) internal returns (Safe safe) {
        bytes memory setup = abi.encodeCall(
            Safe.setup, (owners, threshold, address(0), "", address(handler), address(0), 0, payable(address(0)))
        );
        safe = Safe(payable(address(factory.createProxyWithNonce(address(singleton), setup, ++_saltNonce))));
    }

    function _eoa(uint256 key) internal pure returns (Signer memory signer) {
        signer.owner = vm.addr(key);
        signer.key = key;
    }

    function _child(Safe child, uint256[] memory childKeys) internal pure returns (Signer memory signer) {
        signer.owner = address(child);
        signer.childKeys = childKeys;
    }

    function _approvedChild(Safe child) internal pure returns (Signer memory signer) {
        signer.owner = address(child);
        signer.approved = true;
    }

    function _txHash(Safe safe, address to, uint256 value, bytes memory data, Enum.Operation operation)
        internal
        view
        returns (bytes32)
    {
        return _txHashAt(safe, to, value, data, operation, safe.nonce());
    }

    function _txHashAt(Safe safe, address to, uint256 value, bytes memory data, Enum.Operation operation, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return safe.getTransactionHash(to, value, data, operation, 0, 0, 0, address(0), payable(address(0)), nonce);
    }

    /// @dev Safe's contract-signature layout: 65-byte static entries sorted by owner, then each
    ///      contract owner's length-prefixed payload at the offset its `s` names.
    function _sign(Signer[] memory signers, bytes32 txHash) internal view returns (bytes memory signatures) {
        _sortByOwner(signers);
        bytes memory dynamicPart;
        for (uint256 i = 0; i < signers.length; ++i) {
            Signer memory signer = signers[i];
            if (signer.key != 0) {
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.key, txHash);
                signatures = abi.encodePacked(signatures, r, s, v);
                continue;
            }
            bytes memory payload;
            if (!signer.approved) {
                bytes32 messageHash = handler.getMessageHashForSafe(Safe(payable(signer.owner)), abi.encode(txHash));
                Signer[] memory childSigners = new Signer[](signer.childKeys.length);
                for (uint256 j = 0; j < childSigners.length; ++j) {
                    childSigners[j] = _eoa(signer.childKeys[j]);
                }
                payload = _sign(childSigners, messageHash);
            }
            uint256 offset = signers.length * 65 + dynamicPart.length;
            signatures = abi.encodePacked(signatures, uint256(uint160(signer.owner)), offset, uint8(0));
            dynamicPart = abi.encodePacked(dynamicPart, payload.length, payload);
        }
        signatures = abi.encodePacked(signatures, dynamicPart);
    }

    function _withPolicyContext(bytes memory signatures, bytes memory context) internal pure returns (bytes memory) {
        return abi.encodePacked(signatures, context, context.length, POLICY_CONTEXT_TYPE);
    }

    function _exec(Safe safe, Signer[] memory signers, address to, uint256 value, bytes memory data, Enum.Operation op)
        internal
        returns (bool)
    {
        return _execWith(safe, to, value, data, op, _signFor(safe, signers, to, value, data, op));
    }

    /// @dev Signs before the call, so `vm.expectRevert` can target `execTransaction` itself.
    function _signFor(
        Safe safe,
        Signer[] memory signers,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation op
    ) internal view returns (bytes memory) {
        return _sign(signers, _txHash(safe, to, value, data, op));
    }

    function _execWith(
        Safe safe,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation op,
        bytes memory signatures
    ) internal returns (bool) {
        return safe.execTransaction(to, value, data, op, 0, 0, 0, address(0), payable(address(0)), signatures);
    }

    /// @dev One owner-approved batch: configure policies on `guard_`, then install it, optionally also
    ///      as the module guard. Used unchanged for fresh and already-guarded Safes.
    function _install(
        Safe safe,
        Signer[] memory signers,
        SafePolicyGuard guard_,
        SafePolicyGuard.Configuration[] memory configurations,
        bool moduleGuard
    ) internal {
        bytes memory batch = abi.encodePacked(
            _multiSendEntry(address(guard_), abi.encodeCall(SafePolicyGuard.configureImmediately, (configurations))),
            _multiSendEntry(address(safe), abi.encodeCall(safe.setGuard, (address(guard_))))
        );
        if (moduleGuard) {
            batch = abi.encodePacked(
                batch, _multiSendEntry(address(safe), abi.encodeCall(safe.setModuleGuard, (address(guard_))))
            );
        }
        _exec(
            safe,
            signers,
            address(multiSend),
            0,
            abi.encodeCall(multiSend.multiSend, (batch)),
            Enum.Operation.DelegateCall
        );
    }

    function _multiSendEntry(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }

    function _config(address target, bytes4 selector, Operation operation, address policy)
        internal
        pure
        returns (SafePolicyGuard.Configuration memory)
    {
        return SafePolicyGuard.Configuration(target, selector, operation, policy, "");
    }

    function _sortByOwner(Signer[] memory signers) private pure {
        for (uint256 i = 1; i < signers.length; ++i) {
            for (uint256 j = i; j > 0 && signers[j - 1].owner > signers[j].owner; --j) {
                (signers[j - 1], signers[j]) = (signers[j], signers[j - 1]);
            }
        }
    }
}
