// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

contract CreateHarness {
    function create(address deployer, uint256 nonce) external pure returns (address) {
        return AddressDerive.create(deployer, nonce);
    }

    function minimalBigEndian(uint256 x) external pure returns (bytes memory) {
        return Erc7930.minimalBigEndian(x);
    }
}

/// @notice Covers `AddressDerive.create`, and specifically the RLP nonce encoding, which
///         had no test of any kind.
///
/// @dev THE UNTESTED BRANCH WAS THE INTERESTING ONE. `create3` is the only production
///      caller and it passes a hardcoded nonce of 1, so the `nonce <= 0x7f` arm was the
///      only one anything exercised. The arm above it is the one that reaches for a
///      minimal big-endian encoder, which is exactly the code that was merged with
///      `Erc7930.minimalBigEndian` rather than kept as a private second copy: an
///      unverified merge of two byte-identical bodies is still an unverified merge.
///
/// @dev THE EXPECTED VALUES ARE NOT COMPUTED HERE. They come from `cast compute-address`,
///      an independent implementation in another language, so this asserts agreement with
///      Ethereum rather than agreement with itself.
contract CreateDerivationTest is Test {
    CreateHarness h;

    address constant DEPLOYER = 0x6AC7EA33F8831EA9dcC53393aAA88B25A785DBF0;

    function setUp() public {
        h = new CreateHarness();
    }

    /// @dev The single-byte arms: nonce 0 is RLP `0x80`, and 1..0x7f is the byte itself.
    function test_shortNonces() public view {
        assertEq(h.create(DEPLOYER, 0), 0xcd234A471b72ba2F1Ccf0A70FCABA648a5eeCD8d, "0");
        assertEq(h.create(DEPLOYER, 1), 0x343c43A37D37dfF08AE8C4A11544c718AbB4fCF8, "1");
        assertEq(h.create(DEPLOYER, 127), 0x06d9a77f5E4b311Bae8D559DB9CDB4dF94104aA0, "127");
    }

    /// @dev THE MERGED ENCODER'S ARM. Every nonce here is length-prefixed and encoded
    ///      through `Erc7930.minimalBigEndian`, across one, two, three, and four bytes.
    function test_longNoncesUseTheSharedEncoder() public view {
        assertEq(h.create(DEPLOYER, 128), 0x08e190dcB7b73F5fcDAbb43e102215c83659A76D, "128");
        assertEq(h.create(DEPLOYER, 255), 0x3eF7c1a519E4b4431E317d7839340E3139B03c65, "255");
        assertEq(h.create(DEPLOYER, 256), 0x3837C1Ae70354f670550C746580199Ac6a73Cb0a, "256");
        assertEq(
            h.create(DEPLOYER, 65535), 0x65260EECFf4eDeBaBE134f76F1F39a91Defde56C, "65535"
        );
        assertEq(
            h.create(DEPLOYER, 16777216),
            0x2F7e0b32826965De88a6FeBf0f35f55fdC22B262,
            "16777216"
        );
    }

    /// @dev 127 and 128 straddle the arm boundary, so they must not collide and must not
    ///      be reachable from each other by an off-by-one in the length prefix.
    function test_theArmBoundaryIsNotOffByOne() public view {
        assertTrue(h.create(DEPLOYER, 127) != h.create(DEPLOYER, 128));
        assertEq(h.minimalBigEndian(127).length, 1);
        assertEq(h.minimalBigEndian(128).length, 1);
        assertEq(h.minimalBigEndian(256).length, 2);
    }

    /// @dev The encoder is minimal by definition: no leading zero byte, and zero encodes
    ///      to nothing at all. `create` never reaches it with zero, but the eip155 chain
    ///      reference rule this same function serves depends on both.
    function test_theEncoderIsMinimal() public view {
        assertEq(h.minimalBigEndian(0).length, 0);
        assertEq(h.minimalBigEndian(1), hex"01");
        assertEq(h.minimalBigEndian(8453), hex"2105");
        assertEq(h.minimalBigEndian(type(uint256).max).length, 32);
        for (uint256 i = 1; i < 1000; i++) {
            assertTrue(h.minimalBigEndian(i)[0] != 0, "leading zero byte");
        }
    }

    /// @dev One encoder, two callers: the chain-reference rule and the RLP nonce reach the
    ///      same bytes, which is what makes merging them correct rather than convenient.
    function testFuzz_chainReferenceAndNonceShareOneEncoding(uint256 x) public view {
        bytes memory enc = h.minimalBigEndian(x);
        if (x == 0) {
            assertEq(enc.length, 0);
            return;
        }
        assertTrue(enc[0] != 0);
        uint256 back;
        for (uint256 i; i < enc.length; i++) {
            back = (back << 8) | uint8(enc[i]);
        }
        assertEq(back, x, "round trip");
    }
}
