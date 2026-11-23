// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {ILzOftConduitFactory} from "src/protocols/layerzero/ILzOftConduitFactory.sol";
import {LzOftConduitAddress} from "src/protocols/layerzero/LzOftConduitAddress.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {LzOftConduitFactoryBase} from "test/protocols/layerzero/LzOftConduitFactory.t.sol";

/// @dev External wrapper so `vm.expectRevert` sees the library's reverts.
contract LzOftConduitAddressHarness {
    function requireDestinations(ILzOftConduitFactory.Destination[] memory d, bytes32 homeChainKey, uint32 homeEid)
        external
        pure
    {
        LzOftConduitAddress.requireDestinations(d, homeChainKey, homeEid);
    }
}

/// @dev The offline derivation against the factory that binds the same values on chain.
contract LzOftConduitAddressTest is LzOftConduitFactoryBase {
    LzOftConduitAddressHarness h;

    function setUp() public {
        _chain(HOME, HOME_EID);
        h = new LzOftConduitAddressHarness();
    }

    function _list(uint256 n) internal returns (ILzOftConduitFactory.Destination[] memory d) {
        d = new ILzOftConduitFactory.Destination[](n);
        for (uint256 i; i < n; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) n is small
            uint32 eid = uint32(40_000 + i);
            address dst = address(uint160(0xD000 + i));
            oft.setPeer(eid, dst);
            d[i] = ILzOftConduitFactory.Destination(bytes32(i + 1), eid, dst);
        }
    }

    function testFuzz_theOfflineRootAndAddressAreTheFactorys(uint8 count) public {
        ILzOftConduitFactory.Destination[] memory d = _list(bound(count, 1, 12));
        bytes32 root = LzOftConduitAddress.destRoot(d, homeKey, HOME_EID);
        address predicted = LzOftConduitAddress.predictConduit(
            address(factory), factory.PROXY_INIT_CODE_HASH(), owner, SALT, homeKey, HOME_EID, address(oft), root
        );
        assertEq(
            LzOftConduitAddress.conduitSalt(owner, SALT, homeKey, HOME_EID, address(oft), root),
            factory.conduitSalt(owner, SALT, homeKey, HOME_EID, address(oft), root)
        );
        assertEq(predicted, factory.predictConduit(owner, SALT, homeKey, HOME_EID, address(oft), root));

        vm.prank(owner);
        LzOftTransmitter conduit = LzOftTransmitter(payable(factory.createTransmitter(SALT, address(oft), d)));
        assertEq(address(conduit), predicted);
        for (uint256 i; i < d.length; ++i) {
            (,,, bytes32 r, bytes32[] memory proof) = factory.bootstrapRoute(address(conduit), d[i].chainKey);
            assertEq(r, root);
            assertTrue(MerkleProof.verify(proof, root, LzOftConduitAddress.leafHash(d[i])));
        }
    }

    /// @dev Each list the offline check refuses, the factory refuses with the same error.
    function test_theOfflineCheckRefusesWhatTheFactoryRefuses() public {
        ILzOftConduitFactory.Destination[][] memory bad = new ILzOftConduitFactory.Destination[][](6);
        bad[0] = new ILzOftConduitFactory.Destination[](0);
        bad[1] = _list(2);
        (bad[1][0], bad[1][1]) = (bad[1][1], bad[1][0]);
        bad[2] = _list(2);
        bad[2][1] = bad[2][0];
        bad[3] = _list(1);
        bad[3][0].chainKey = homeKey;
        bad[4] = _list(1);
        bad[4][0].eid = HOME_EID;
        oft.setPeer(HOME_EID, bad[4][0].oft);
        bad[5] = _list(1);
        bad[5][0].oft = address(0);
        for (uint256 i; i < bad.length; ++i) {
            bytes memory offline;
            try h.requireDestinations(bad[i], homeKey, HOME_EID) {
                revert("the offline check accepted");
            } catch (bytes memory err) {
                offline = err;
            }
            vm.prank(owner);
            vm.expectRevert(offline);
            factory.createTransmitter(SALT, address(oft), bad[i]);
        }
    }

    /// @dev Hashed twice, so a 64-byte internal node is never a leaf preimage.
    function test_theLeafHashIsTheDoubleHashOfTheFields() public pure {
        ILzOftConduitFactory.Destination memory d =
            ILzOftConduitFactory.Destination(keccak256("eip155:8453"), 30184, address(0xA));
        assertEq(LzOftConduitAddress.leafHash(d), keccak256(abi.encode(keccak256(abi.encode(d)))));
    }

    /// @dev The leaf is what OpenZeppelin's `MerkleProof` verifies against a sorted-pair root,
    ///      which is how the factory will check it.
    function test_aLeafProvesIntoASortedPairRoot() public pure {
        bytes32 a = LzOftConduitAddress.leafHash(
            ILzOftConduitFactory.Destination(keccak256("eip155:8453"), 30184, address(0xA))
        );
        bytes32 b = LzOftConduitAddress.leafHash(
            ILzOftConduitFactory.Destination(keccak256("eip155:42161"), 30110, address(0xB))
        );
        bytes32 root = Hashes.commutativeKeccak256(a, b);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        assertTrue(MerkleProof.verify(proof, root, a));
        assertFalse(
            MerkleProof.verify(
                proof,
                root,
                LzOftConduitAddress.leafHash(
                    ILzOftConduitFactory.Destination(keccak256("eip155:8453"), 30184, address(0xC))
                )
            ),
            "another OFT on the same chain"
        );
    }
}
