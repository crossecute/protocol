// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {Call} from "src/messaging/Call.sol";

contract PeerOft {
    mapping(uint32 => bytes32) public peers;

    function setPeer(uint32 eid, address peer) external {
        peers[eid] = bytes32(uint256(uint160(peer)));
    }
}

/// @dev External wrappers so `vm.expectRevert` sees the library's reverts.
contract LzOftMessageHarness {
    function sendParam(uint32 dstEid, address to, bytes memory composeMsg, bytes[] memory attributes, uint256 gas)
        external
        pure
        returns (SendParam memory)
    {
        return LzOftMessage.sendParam(dstEid, to, composeMsg, attributes, gas);
    }

    function requirePeer(address oft, uint32 eid, address expected) external view {
        LzOftMessage.requirePeer(oft, eid, expected);
    }

    function roundTrip(LzOftMessage.Bootstrap memory b) external pure returns (LzOftMessage.Bootstrap memory) {
        return LzOftMessage.decodeBootstrap(LzOftMessage.encodeBootstrap(b));
    }
}

contract LzOftMessageTest is Test {
    LzOftMessageHarness h = new LzOftMessageHarness();
    uint32 constant EID = 30184;
    address constant TO = address(0xFAC7);
    uint256 constant GAS = 200_000;

    function _options(bytes memory raw) internal pure returns (bytes memory) {
        return abi.encodePacked(LzMessage.OPTIONS_ATTRIBUTE, raw);
    }

    function _attrs(bytes memory a) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = a;
    }

    /// @dev Built from `ExecutorOptions`' layout rather than copied from the library: worker id
    ///      1, a 2-byte size that counts the option type, type 3, then `index | gas`.
    function test_theComposeOptionIsExecutorOptionsLayout() public pure {
        bytes memory option = abi.encodePacked(uint16(0), uint128(GAS));
        bytes memory expected = abi.encodePacked(uint16(3), uint8(1), uint16(option.length + 1), uint8(3), option);
        assertEq(LzMessage.defaultComposeOptions(GAS), expected);
    }

    function test_aSendMovesNoTokensAndCarriesTheDefaultCompose() public view {
        SendParam memory p = h.sendParam(EID, TO, hex"c0", new bytes[](0), GAS);
        assertEq(p.dstEid, EID);
        assertEq(p.to, bytes32(uint256(uint160(TO))));
        assertEq(p.amountLD, 0);
        assertEq(p.minAmountLD, 0);
        assertEq(p.extraOptions, LzMessage.defaultComposeOptions(GAS));
        assertEq(p.composeMsg, hex"c0");
        assertEq(p.oftCmd.length, 0);
    }

    function test_theOptionsAttributeReplacesTheDefaultWhole() public view {
        SendParam memory p = h.sendParam(EID, TO, hex"c0", _attrs(_options(hex"0003aa")), GAS);
        assertEq(p.extraOptions, hex"0003aa");
        assertEq(p.amountLD, 0);
    }

    /// @dev One attribute at most, as every LayerZero send takes.
    function test_aSecondAttributeIsRefused() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = _options(hex"0003aa");
        attrs[1] = _options(hex"0003bb");
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attrs[1]));
        h.sendParam(EID, TO, hex"c0", attrs, GAS);
    }

    function test_anotherBindingsAttributeIsRefused() public {
        bytes memory foreign = abi.encodePacked(bytes4(keccak256("crossecute.hyperlane.gasLimit")), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, foreign));
        h.sendParam(EID, TO, hex"c0", _attrs(foreign), GAS);
    }

    function test_aPeerThatStillMatchesPasses() public {
        PeerOft oft = new PeerOft();
        oft.setPeer(EID, TO);
        h.requirePeer(address(oft), EID, TO);
    }

    function test_aChangedPeerIsRefused() public {
        PeerOft oft = new PeerOft();
        oft.setPeer(EID, address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                LzOftMessage.PeerChanged.selector,
                EID,
                bytes32(uint256(uint160(TO))),
                bytes32(uint256(uint160(address(0xBAD))))
            )
        );
        h.requirePeer(address(oft), EID, TO);
    }

    /// @dev The leaf is what OpenZeppelin's `MerkleProof` verifies against a sorted-pair root,
    ///      which is how the factory will check it.
    function test_aLeafProvesIntoASortedPairRoot() public pure {
        bytes32 a = LzOftMessage.leaf(keccak256("eip155:8453"), 30184, address(0xA));
        bytes32 b = LzOftMessage.leaf(keccak256("eip155:42161"), 30110, address(0xB));
        bytes32 root = Hashes.commutativeKeccak256(a, b);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        assertTrue(MerkleProof.verify(proof, root, a));
        assertFalse(
            MerkleProof.verify(proof, root, LzOftMessage.leaf(keccak256("eip155:8453"), 30184, address(0xC))),
            "another OFT on the same chain"
        );
    }

    /// @dev A 64-byte inner node cannot pass as a leaf, since a leaf is hashed twice.
    function test_aLeafIsNotItsSingleHash() public pure {
        bytes32 chainKey = keccak256("eip155:8453");
        assertNotEq(
            LzOftMessage.leaf(chainKey, 30184, address(0xA)),
            keccak256(abi.encode(chainKey, uint32(30184), address(0xA)))
        );
    }

    function test_theBootstrapRoundTrips() public view {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = keccak256("p0");
        proof[1] = keccak256("p1");
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0xCA11), 7, hex"abcd");
        LzOftMessage.Bootstrap memory b = LzOftMessage.Bootstrap(
            address(0xA11CE), keccak256("salt"), keccak256("home"), address(0x0F7), keccak256("root"), proof, calls
        );

        LzOftMessage.Bootstrap memory out = h.roundTrip(b);
        assertEq(keccak256(abi.encode(out)), keccak256(abi.encode(b)));
    }
}
