// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {SafeTx} from "@crossecute/safe-guard/ICrossecuteGuard.sol";
import {SafeHashes} from "@crossecute/safe-guard/SafeHashes.sol";
import {SafeRecord, OwnerEntry, NestedApproval, OWNER_EOA, OWNER_SAFE} from "src/messaging/signed/ISignedDispatch.sol";

/// @notice An independent Merkle builder for the dispatch tree: sorted pairs, the unpaired last
///         hash of a level carried up, a single leaf as its own root.
library MerkleBuilder {
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _up(level);
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        bytes32[] memory scratch = new bytes32[](64);
        uint256 n;
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) scratch[n++] = level[sibling];
            level = _up(level);
            index /= 2;
        }
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = scratch[i];
        }
    }

    function _up(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < level.length / 2; ++i) {
            bytes32 a = level[2 * i];
            bytes32 b = level[2 * i + 1];
            next[i] = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        }
        if (level.length % 2 == 1) next[next.length - 1] = level[level.length - 1];
    }
}

/// @notice One entry of a Safe signature blob before encoding.
struct Sig {
    address owner;
    // EOA: `pk` signs; `prefixed` uses the eth_sign digest (v + 4). Safe: `payload` is the
    // child's own blob, empty for an approval.
    uint8 kind;
    uint256 pk;
    bool prefixed;
    bytes payload;
}

/// @notice Builds Safe 1.5.0 signature blobs, owners ascending, contract payloads after the
///         static part.
library SafeSigs {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function eoa(uint256 pk) internal pure returns (Sig memory s) {
        s.owner = VM.addr(pk);
        s.kind = OWNER_EOA;
        s.pk = pk;
    }

    function prefixed(uint256 pk) internal pure returns (Sig memory s) {
        s = eoa(pk);
        s.prefixed = true;
    }

    function nested(address child, bytes memory payload) internal pure returns (Sig memory s) {
        s.owner = child;
        s.kind = OWNER_SAFE;
        s.payload = payload;
    }

    function blob(Sig[] memory sigs, bytes32 hash) internal pure returns (bytes memory out) {
        _sort(sigs);
        bytes memory dynamicPart;
        uint256 staticLength = sigs.length * 65;
        for (uint256 i; i < sigs.length; ++i) {
            Sig memory s = sigs[i];
            if (s.kind == OWNER_SAFE) {
                uint256 offset = staticLength + dynamicPart.length;
                out = abi.encodePacked(out, bytes32(uint256(uint160(s.owner))), bytes32(offset), uint8(0));
                dynamicPart = abi.encodePacked(dynamicPart, uint256(s.payload.length), s.payload);
            } else if (s.prefixed) {
                bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
                (uint8 v, bytes32 r, bytes32 ss) = VM.sign(s.pk, digest);
                out = abi.encodePacked(out, r, ss, v + 4);
            } else {
                (uint8 v, bytes32 r, bytes32 ss) = VM.sign(s.pk, hash);
                out = abi.encodePacked(out, r, ss, v);
            }
        }
        out = abi.encodePacked(out, dynamicPart);
    }

    function one(Sig memory a) internal pure returns (Sig[] memory s) {
        s = new Sig[](1);
        s[0] = a;
    }

    function two(Sig memory a, Sig memory b) internal pure returns (Sig[] memory s) {
        s = new Sig[](2);
        (s[0], s[1]) = (a, b);
    }

    function _sort(Sig[] memory sigs) private pure {
        for (uint256 i = 1; i < sigs.length; ++i) {
            Sig memory key = sigs[i];
            uint256 j = i;
            while (j > 0 && sigs[j - 1].owner > key.owner) {
                sigs[j] = sigs[j - 1];
                --j;
            }
            sigs[j] = key;
        }
    }

    /// @notice A child's signed `signMessage(abi.encode(parentHash))` approval, as a guard caches it.
    function approval(address child, bytes32 parentHash, uint256 chainId, Sig[] memory childSigs, address lib)
        internal
        pure
        returns (NestedApproval memory a)
    {
        SafeTx memory t;
        t.to = lib;
        t.data = abi.encodeWithSelector(bytes4(0x85a5affe), abi.encode(parentHash));
        t.operation = 1;
        t.nonce = 7;
        a.childSafe = child;
        a.messageHash = SafeHashes.messageHash(abi.encode(parentHash), child, chainId);
        a.approval.safeTx = t;
        a.approval.signatures = blob(childSigs, SafeHashes.transactionHash(t, child, chainId));
    }
}

/// @notice `SafeRecord` builders.
library Records {
    function eoaOwners(uint256[] memory pks) internal pure returns (OwnerEntry[] memory owners) {
        owners = new OwnerEntry[](pks.length);
        for (uint256 i; i < pks.length; ++i) {
            owners[i] = OwnerEntry(Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).addr(pks[i]), OWNER_EOA);
        }
    }

    function record(address safe, uint256 threshold, OwnerEntry[] memory owners)
        internal
        pure
        returns (SafeRecord memory)
    {
        return SafeRecord(safe, threshold, owners);
    }

    function list(SafeRecord memory a) internal pure returns (SafeRecord[] memory r) {
        r = new SafeRecord[](1);
        r[0] = a;
    }

    function list(SafeRecord memory a, SafeRecord memory b) internal pure returns (SafeRecord[] memory r) {
        r = new SafeRecord[](2);
        (r[0], r[1]) = (a, b);
    }

    function list(SafeRecord memory a, SafeRecord memory b, SafeRecord memory c)
        internal
        pure
        returns (SafeRecord[] memory r)
    {
        r = new SafeRecord[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function pks(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory p) {
        p = new uint256[](3);
        (p[0], p[1], p[2]) = (a, b, c);
    }

    function pks(uint256 a, uint256 b) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        (p[0], p[1]) = (a, b);
    }
}
