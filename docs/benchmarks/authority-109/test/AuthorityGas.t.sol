// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SafeAuthority, SafeAuthorityState} from "src/messaging/signed/SafeAuthority.sol";
import {SafeSignaturesUtils} from "src/messaging/signed/SafeSignaturesUtils.sol";
import {SafeAuthorityRecord, SafeOwner, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {SafeSigs, Sig} from "fixtures/SignedFixtures.sol";

import {SafeTx, SignedSafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {SafeTxEvidence, WIRE_STANDALONE} from "src/messaging/signed/types/SignedDispatchTypes.sol";
import {Call} from "src/messaging/Call.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

contract GasAuthorityHarness {
    using SafeAuthority for SafeAuthorityState;
    SafeAuthorityState internal state;

    function store(SafeAuthorityRecord[] memory records) external {
        state.store(records, 1);
    }

    function verify(bytes32 hash, bytes memory signatures) external view {
        state.verify(hash, signatures, new NestedSafeApproval[](0));
    }
}

contract AuthorityGasBench is Test {
    uint256 private nextPk;
    uint256 private ownerEntries;
    uint256 private maxDepth;
    bytes32 private constant HASH = keccak256("Crossecute #109 baseline gas benchmark");

    function safeAt(uint256 index) internal pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    // parents[0] is unused; every remaining parent precedes its child. Child indices
    // are preordered DFS, matching production canonical enumeration.
    struct BuildContext {
        uint256[] parents;
        uint256[] eoas;
        SafeAuthorityRecord[] records;
    }

    function build(uint256 node, uint256 depth, bytes32 hash, BuildContext memory ctx) internal returns (bytes memory) {
        if (depth > maxDepth) maxDepth = depth;
        uint256 children;
        for (uint256 j = node + 1; j < ctx.parents.length; ++j) {
            if (ctx.parents[j] == node) ++children;
        }
        uint256 count = children + ctx.eoas[node];
        SafeOwner[] memory owners = new SafeOwner[](count);
        Sig[] memory sigs = new Sig[](count);
        uint256 at;
        for (uint256 j = node + 1; j < ctx.parents.length; ++j) {
            if (ctx.parents[j] != node) continue;
            address child = safeAt(j);
            bytes memory payload = build(j, depth + 1, SafeSignaturesUtils.nestedHash(hash, child, 1), ctx);
            owners[at] = SafeOwner(child, OWNER_SAFE);
            sigs[at++] = SafeSigs.nested(child, payload);
        }
        for (uint256 j; j < ctx.eoas[node]; ++j) {
            uint256 pk = nextPk++;
            owners[at] = SafeOwner(vm.addr(pk), OWNER_EOA);
            sigs[at++] = SafeSigs.eoa(pk);
        }
        ctx.records[node] = SafeAuthorityRecord(safeAt(node), count, owners);
        ownerEntries += count;
        return SafeSigs.blob(sigs, hash);
    }

    function measure(string memory name, uint256[] memory parents, uint256[] memory eoas) internal {
        nextPk = 1000;
        SafeAuthorityRecord[] memory records = new SafeAuthorityRecord[](parents.length);
        bytes memory signatures = build(0, 0, HASH, BuildContext(parents, eoas, records));
        GasAuthorityHarness harness = new GasAuthorityHarness();
        storeCold(harness, records);
        (uint256 cold, uint256 warm, uint256 intrinsic, uint256 callBytes) = verifyGas(harness, signatures);
        uint256[9] memory values = [
            nextPk - 1000,
            parents.length - 1,
            maxDepth,
            ownerEntries,
            signatures.length,
            callBytes,
            cold,
            warm,
            intrinsic
        ];
        string memory row = string.concat("BENCH,", name);
        for (uint256 i; i < values.length; ++i) {
            row = string.concat(row, ",", vm.toString(values[i]));
        }
        console2.log(row);
        console2.log(
            string.concat(
                "WIRE,",
                name,
                ",",
                vm.toString(transferWireBytes(signatures, false)),
                ",",
                vm.toString(transferWireBytes(signatures, true))
            )
        );
        // Negative control: benchmark must actually authenticate signatures.
        vm.expectRevert();
        harness.verify(bytes32(uint256(HASH) ^ 1), signatures);
    }

    // ABI size fixture only: the proof was authenticated over HASH, not this
    // transfer. Its byte length is unchanged by signing the transfer's own digest.
    function transferWireBytes(bytes memory signatures, bool erc20) internal pure returns (uint256) {
        Call[] memory calls = new Call[](1);
        calls[0] = erc20
            ? Call(address(0xCAFE), 0, abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xBEEF), uint256(1 ether)))
            : Call(address(0xBEEF), 1 ether, hex"");
        SafeTx memory txData;
        txData.to = address(0xF001);
        txData.nonce = 1;
        txData.data = abi.encodeWithSelector(
            bytes4(keccak256("sendMessage(bytes,bytes,bytes[])")),
            Erc7930.encodeEvm(8453, address(0xD001)),
            abi.encode(calls),
            new bytes[](0)
        );
        SafeTxEvidence memory evidence = SafeTxEvidence(SignedSafeTx(txData, signatures), new NestedSafeApproval[](0));
        return abi.encode(WIRE_STANDALONE, evidence).length;
    }

    function storeCold(GasAuthorityHarness harness, SafeAuthorityRecord[] memory records) internal {
        vm.record();
        harness.store(records);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(harness));
        for (uint256 i; i < reads.length; ++i) {
            vm.coolSlot(address(harness), reads[i]);
        }
        for (uint256 i; i < writes.length; ++i) {
            vm.coolSlot(address(harness), writes[i]);
        }
        vm.cool(address(harness));
        vm.cool(address(SafeAuthority));
    }

    function verifyGas(GasAuthorityHarness harness, bytes memory signatures)
        internal
        view
        returns (uint256 cold, uint256 warm, uint256 intrinsic, uint256 callBytes)
    {
        bytes memory callData = abi.encodeCall(harness.verify, (HASH, signatures));
        callBytes = callData.length;
        intrinsic = 21000;
        for (uint256 i; i < callData.length; ++i) {
            intrinsic += callData[i] == 0 ? 4 : 16;
        }
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory reason) = address(harness).staticcall(callData);
        cold = beforeGas - gasleft();
        require(ok, string(reason));
        beforeGas = gasleft();
        (ok, reason) = address(harness).staticcall(callData);
        warm = beforeGas - gasleft();
        require(ok, string(reason));
    }

    function fanout(uint256 total, uint256 children, bool perSafe) internal {
        uint256[] memory parents = new uint256[](children + 1);
        uint256[] memory eoas = new uint256[](children + 1);
        if (children == 0) {
            eoas[0] = total;
        } else if (perSafe) {
            eoas[0] = total - children;
            for (uint256 j = 1; j <= children; ++j) {
                eoas[j] = total;
            }
        } else {
            for (uint256 j = 1; j <= children; ++j) {
                eoas[j] = total / children + (j <= total % children ? 1 : 0);
            }
        }
        measure(
            string.concat(perSafe ? "per_safe_" : "total_", vm.toString(total), "_fanout_", vm.toString(children)),
            parents,
            eoas
        );
    }

    function chain(uint256 total, uint256 children) internal {
        uint256[] memory parents = new uint256[](children + 1);
        uint256[] memory eoas = new uint256[](children + 1);
        for (uint256 j = 1; j <= children; ++j) {
            parents[j] = j - 1;
        }
        eoas[children] = total;
        measure(string.concat("total_", vm.toString(total), "_chain_", vm.toString(children)), parents, eoas);
    }

    function test_total_16_fanout_0() public {
        fanout(16, 0, false);
    }

    function test_total_16_fanout_1() public {
        fanout(16, 1, false);
    }

    function test_total_16_fanout_2() public {
        fanout(16, 2, false);
    }

    function test_total_16_fanout_4() public {
        fanout(16, 4, false);
    }

    function test_total_16_fanout_8() public {
        fanout(16, 8, false);
    }

    function test_total_16_chain_2() public {
        chain(16, 2);
    }

    function test_total_16_chain_4() public {
        chain(16, 4);
    }

    function test_total_16_chain_8() public {
        chain(16, 8);
    }

    function test_per_safe_16_fanout_1() public {
        fanout(16, 1, true);
    }

    function test_per_safe_16_fanout_2() public {
        fanout(16, 2, true);
    }

    function test_per_safe_16_fanout_4() public {
        fanout(16, 4, true);
    }

    function test_total_24_fanout_0() public {
        fanout(24, 0, false);
    }

    function test_total_24_fanout_1() public {
        fanout(24, 1, false);
    }

    function test_total_24_fanout_2() public {
        fanout(24, 2, false);
    }

    function test_total_24_fanout_4() public {
        fanout(24, 4, false);
    }

    function test_total_24_fanout_8() public {
        fanout(24, 8, false);
    }

    function test_total_24_chain_2() public {
        chain(24, 2);
    }

    function test_total_24_chain_4() public {
        chain(24, 4);
    }

    function test_total_24_chain_8() public {
        chain(24, 8);
    }

    function test_per_safe_24_fanout_1() public {
        fanout(24, 1, true);
    }

    function test_per_safe_24_fanout_2() public {
        fanout(24, 2, true);
    }

    function test_per_safe_24_fanout_4() public {
        fanout(24, 4, true);
    }

    function test_total_32_fanout_0() public {
        fanout(32, 0, false);
    }

    function test_total_32_fanout_1() public {
        fanout(32, 1, false);
    }

    function test_total_32_fanout_2() public {
        fanout(32, 2, false);
    }

    function test_total_32_fanout_4() public {
        fanout(32, 4, false);
    }

    function test_total_32_fanout_8() public {
        fanout(32, 8, false);
    }

    function test_total_32_chain_2() public {
        chain(32, 2);
    }

    function test_total_32_chain_4() public {
        chain(32, 4);
    }

    function test_total_32_chain_8() public {
        chain(32, 8);
    }

    function test_total_32_chain_16() public {
        chain(32, 16);
    }

    function test_per_safe_32_fanout_1() public {
        fanout(32, 1, true);
    }

    function test_per_safe_32_fanout_2() public {
        fanout(32, 2, true);
    }

    function test_per_safe_32_fanout_4() public {
        fanout(32, 4, true);
    }

    function test_per_safe_32_fanout_8() public {
        fanout(32, 8, true);
    }

    function test_per_safe_32_fanout_16() public {
        fanout(32, 16, true);
    }

    function test_per_safe_32_fanout_32() public {
        fanout(32, 32, true);
    }

    function test_per_safe_32_fanout_3() public {
        fanout(32, 3, true);
    }

    function test_per_safe_16_fanout_3() public {
        fanout(16, 3, true);
    }

    function test_per_safe_16_fanout_6() public {
        fanout(16, 6, true);
    }

    function test_per_safe_16_fanout_7() public {
        fanout(16, 7, true);
    }

    function test_per_safe_16_fanout_8() public {
        fanout(16, 8, true);
    }

    function test_per_safe_16_fanout_16() public {
        fanout(16, 16, true);
    }
}
