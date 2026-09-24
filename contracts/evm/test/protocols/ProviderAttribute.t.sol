// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";

/// @dev External wrappers so `vm.expectRevert` sees the library's reverts.
contract ProviderAttributeHarness {
    function body(bytes[] memory attributes, bytes4 selector, uint256 bodyLength)
        external
        pure
        returns (bool, bytes memory)
    {
        return ProviderAttribute.body(attributes, selector, bodyLength);
    }

    function uintValue(bytes[] memory attributes, bytes4 selector, uint256 max, uint256 defaultValue)
        external
        pure
        returns (uint256)
    {
        return ProviderAttribute.uintValue(attributes, selector, max, defaultValue);
    }
}

contract ProviderAttributeTest is Test {
    ProviderAttributeHarness h = new ProviderAttributeHarness();
    bytes4 constant SEL = bytes4(keccak256("crossecute.test.attribute"));

    function _attrs(bytes memory a) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = a;
    }

    function _attrs(bytes memory a, bytes memory b) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](2);
        attrs[0] = a;
        attrs[1] = b;
    }

    function _expectUnsupported(bytes memory attribute) internal {
        vm.expectRevert(abi.encodeWithSelector(ProviderAttribute.UnsupportedAttribute.selector, attribute));
    }

    /* =================================== body ==================================== */

    function test_bodyAbsentWhenNoAttributes() public view {
        (bool present, bytes memory out) = h.body(new bytes[](0), SEL, 0);
        assertFalse(present);
        assertEq(out.length, 0);
    }

    function test_bodyReturnsTheBytesAfterTheSelector() public view {
        (bool present, bytes memory out) = h.body(_attrs(abi.encodePacked(SEL, hex"c0ffee")), SEL, 0);
        assertTrue(present);
        assertEq(out, hex"c0ffee");
    }

    function test_bodyLengthZeroAcceptsAnEmptyBody() public view {
        (bool present, bytes memory out) = h.body(_attrs(abi.encodePacked(SEL)), SEL, 0);
        assertTrue(present);
        assertEq(out.length, 0);
    }

    function test_bodyRefusesAWrongSelector() public {
        bytes memory a = abi.encodePacked(bytes4(0xdeadbeef), hex"00");
        _expectUnsupported(a);
        h.body(_attrs(a), SEL, 0);
    }

    function test_bodyRefusesAnAttributeShorterThanASelector() public {
        bytes memory a = hex"0102";
        _expectUnsupported(a);
        h.body(_attrs(a), SEL, 0);
    }

    function test_bodyRefusesTheWrongExactLength() public {
        bytes memory a = abi.encodePacked(SEL, uint256(1));
        _expectUnsupported(a);
        h.body(_attrs(a), SEL, 64);
    }

    function test_bodyRefusesAWellFormedExtra() public {
        bytes memory extra = abi.encodePacked(SEL, hex"02");
        _expectUnsupported(extra);
        h.body(_attrs(abi.encodePacked(SEL, hex"01"), extra), SEL, 0);
    }

    /// @dev The ordering this library exists for: with both malformed-first and an extra, the
    ///      malformed first is reported.
    function test_bodyReportsAMalformedFirstBeforeAnExtra() public {
        bytes memory bad = abi.encodePacked(bytes4(0xdeadbeef), hex"01");
        _expectUnsupported(bad);
        h.body(_attrs(bad, abi.encodePacked(SEL, hex"02")), SEL, 0);
    }

    /* ================================= uintValue ================================== */

    function test_uintValueDefaultsWhenNoAttributes() public view {
        assertEq(h.uintValue(new bytes[](0), SEL, type(uint32).max, 7), 7);
    }

    function test_uintValueReturnsTheEncodedValue() public view {
        assertEq(h.uintValue(_attrs(abi.encodePacked(SEL, uint256(500_000))), SEL, type(uint32).max, 7), 500_000);
    }

    function test_uintValueAcceptsExactlyTheMax() public view {
        assertEq(
            h.uintValue(_attrs(abi.encodePacked(SEL, uint256(type(uint32).max))), SEL, type(uint32).max, 0),
            type(uint32).max
        );
    }

    function test_uintValueRefusesAboveTheMax() public {
        bytes memory a = abi.encodePacked(SEL, uint256(type(uint32).max) + 1);
        _expectUnsupported(a);
        h.uintValue(_attrs(a), SEL, type(uint32).max, 0);
    }

    function test_uintValueRefusesTheWrongLength() public {
        bytes memory a = abi.encodePacked(SEL, uint128(1));
        _expectUnsupported(a);
        h.uintValue(_attrs(a), SEL, type(uint256).max, 0);
    }

    function test_uintValueRefusesAWrongSelector() public {
        bytes memory a = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        _expectUnsupported(a);
        h.uintValue(_attrs(a), SEL, type(uint256).max, 0);
    }

    function test_uintValueRefusesAWellFormedExtra() public {
        bytes memory extra = abi.encodePacked(SEL, uint256(2));
        _expectUnsupported(extra);
        h.uintValue(_attrs(abi.encodePacked(SEL, uint256(1)), extra), SEL, type(uint256).max, 0);
    }

    /// @dev Out of range counts as malformed, so it too is reported ahead of an extra.
    function test_uintValueReportsAnOutOfRangeFirstBeforeAnExtra() public {
        bytes memory bad = abi.encodePacked(SEL, uint256(type(uint32).max) + 1);
        _expectUnsupported(bad);
        h.uintValue(_attrs(bad, abi.encodePacked(SEL, uint256(2))), SEL, type(uint32).max, 0);
    }

    function test_uintValueReportsAMalformedFirstBeforeAnExtra() public {
        bytes memory bad = abi.encodePacked(bytes4(0xdeadbeef), uint256(1));
        _expectUnsupported(bad);
        h.uintValue(_attrs(bad, abi.encodePacked(SEL, uint256(2))), SEL, type(uint256).max, 0);
    }
}
