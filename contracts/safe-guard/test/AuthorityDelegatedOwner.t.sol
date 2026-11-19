// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {ISignatureValidator} from "safe-smart-account/interfaces/ISignatureValidator.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {AuthorityGraph} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {SafeQuorum} from "crossecute/messaging/signed/SafeQuorum.sol";
import {AuthorityUpdate} from "../src/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "../src/authority/ISourceAuthorityGuard.sol";
import {SourceAuthorityBase} from "./SourceAuthorityBase.sol";
import {Batch} from "./Batch.sol";

contract DelegatedSignatureOwner is ISignatureValidator {
    function isValidSignature(bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract AuthorityDelegatedOwnerTest is SourceAuthorityBase {
    uint256 private constant KEY = 0x7702;

    function testDelegatedEoaKeepsEcdsaAuthorityAndCannotUseContractSignatures() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = KEY;
        Safe safe = _guarded(keys, 1);
        Signer[] memory signers = new Signer[](1);
        signers[0] = _eoa(KEY);
        _activate(safe, signers);
        AuthorityGraph memory graph = _graph(_record(safe));
        bytes32 previous = _head(safe);
        bytes memory data =
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(previous, _hash(graph))));
        bytes32 digest = _txHash(safe, address(guard), 0, data, Enum.Operation.Call);
        bytes memory ecdsa = _sign(signers, digest);
        address owner = vm.addr(KEY);
        bytes memory contractSignature =
            abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(uint256(65)), uint8(0), uint256(0));
        Batch.Call[] memory calls = _stagedCalls(
            safe,
            address(guard),
            data,
            Enum.Operation.Call,
            graph,
            new ChildUpdate[](0),
            contractSignature,
            contractSignature
        );
        // Only the test execution fork changes; the guard remains compiled for Cancun.
        string memory original = vm.getEvmVersion();
        vm.setEvmVersion("prague");
        vm.signAndAttachDelegation(address(new DelegatedSignatureOwner()), KEY);
        assertEq(DelegatedSignatureOwner(owner).isValidSignature(digest, ""), bytes4(0x1626ba7e));
        assertEq(owner.code.length, 23);
        safe.checkSignatures(address(0), digest, contractSignature);
        uint256 nonce = safe.nonce();
        vm.expectRevert(abi.encodeWithSelector(SafeQuorum.NotAnOwner.selector, address(safe), owner));
        batch.run(calls);
        assertEq(safe.nonce(), nonce);
        assertEq(_head(safe), previous);
        assertEq(guard.publishedAuthority(address(safe), digest), bytes32(0));
        _execStaged(safe, address(guard), data, Enum.Operation.Call, graph, new ChildUpdate[](0), ecdsa, ecdsa);
        assertEq(_head(safe), digest);
        vm.setEvmVersion(original);
    }
}
