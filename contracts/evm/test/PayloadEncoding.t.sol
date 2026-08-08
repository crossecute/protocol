// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Call, Calls} from "src/messaging/Call.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainType} from "src/addressing/ChainType.sol";

/// @dev A target that records what it was called with, so an assertion can be about the
///      call that actually landed rather than about a return value.
contract Sink {
    uint256 public pokes;
    uint256 public lastValue;
    bytes public lastData;

    function poke(uint256 x) external payable {
        pokes += x;
        lastValue = msg.value;
        lastData = msg.data;
    }

    receive() external payable {}
}

/// @dev A receiver with an open policy, so these tests are about encoding rather than
///      about `isAllowed`.
contract OpenReceiver is ReceiverBase {
    function isAllowed(address, bytes4) public pure override returns (bool) {
        return true;
    }
}

/// @dev Reaches the library through external calls so `calldata` parameters are genuine
///      calldata, which is what the production path uses.
contract PayloadHarness {
    function decodeCalls(bytes calldata wire) external pure returns (Call[] memory) {
        return Payload.decodeCalls(wire);
    }

    function decodeElements(bytes calldata wire) external pure returns (bytes[] memory) {
        return Payload.decodeElements(wire);
    }

    function isTypedDestination(bytes calldata identifier) external pure returns (bool) {
        return Payload.isTypedDestination(identifier);
    }

    function hashElements(bytes32 chainKey, bytes[] calldata elements)
        external
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(chainKey, elements);
    }

    function hashCalls(bytes32 chainKey, Call[] calldata calls)
        external
        pure
        returns (bytes32)
    {
        return Commitment.hashCalls(chainKey, calls);
    }
}

contract PayloadEncodingTest is Test {
    PayloadHarness harness;
    Sink sink;

    bytes32 constant DEST = keccak256("destination.chain");

    function setUp() public {
        harness = new PayloadHarness();
        sink = new Sink();
    }

    /* =============================== the equivalence ============================ */

    /// THE PROPERTY EVERYTHING ELSE RESTS ON. An EVM destination receives `Call[]` and a
    /// non-EVM one receives opaque `bytes[]`, so the same logical payload is serialized two
    /// different ways depending on where it is going — and it must approve to one hash
    /// either way. If these diverge, a payload approved off-chain in the portable form
    /// silently stops matching, and it fails only on a live message.
    function test_typedAndOpaqueProduceTheSameCommitment() public view {
        Call[] memory calls = _calls();

        assertEq(
            harness.hashCalls(DEST, calls),
            harness.hashElements(DEST, Calls.encodeAll(calls)),
            "typed and opaque must commit identically"
        );
    }

    function testFuzz_typedAndOpaqueProduceTheSameCommitment(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 chainKey
    ) public view {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: value, data: data});

        assertEq(
            harness.hashCalls(chainKey, calls),
            harness.hashElements(chainKey, Calls.encodeAll(calls)),
            "equivalence must not depend on the values"
        );
    }

    /// The equivalence survives the wire. The two encodings share no bytes, and the
    /// framing never enters the hash — which is what lets the wire format change without
    /// invalidating a single commitment.
    function test_theWireFramingIsNotPartOfTheCommitment() public view {
        Call[] memory calls = _calls();

        bytes memory typedWire = Payload.encodeCalls(calls);
        bytes memory opaqueWire = Payload.encodeElements(Calls.encodeAll(calls));

        assertTrue(
            keccak256(typedWire) != keccak256(opaqueWire), "the blobs are not identical"
        );
        assertEq(
            harness.hashCalls(DEST, calls),
            harness.hashElements(DEST, Calls.encodeAll(calls)),
            "but they approve the same thing"
        );
    }

    /* ============================ the struct-encoding trap ====================== */

    /// `abi.encode(struct)` prepends an offset word, because a struct with a dynamic
    /// member encodes as a dynamic tuple. Encoding the STRUCT rather than the FIELDS is
    /// the mistake that breaks the equivalence above, and it is invisible by inspection.
    function test_encodingTheStructIsNotEncodingTheFields() public pure {
        Call memory c = Call({target: address(0xBEEF), value: 1, data: hex"deadbeef"});

        assertTrue(
            keccak256(abi.encode(c)) != keccak256(Calls.encode(c)),
            "the two differ, which is why Calls.encode exists"
        );
        assertEq(
            Calls.hash(c),
            keccak256(abi.encode(c.target, c.value, c.data)),
            "hash must equal the field encoding"
        );
        assertEq(Calls.hash(c), keccak256(Calls.encode(c)), "hash equals keccak of encode");
    }

    function testFuzz_elementRoundTrips(address target, uint256 value, bytes memory data)
        public
        pure
    {
        Call memory c = Call({target: target, value: value, data: data});
        Call memory back = Calls.decode(Calls.encode(c));

        assertEq(back.target, target);
        assertEq(back.value, value);
        assertEq(back.data, data);
    }

    /* ================================= the wire ================================= */

    function test_theTypedWireRoundTrips() public view {
        Call[] memory calls = _calls();
        Call[] memory back = harness.decodeCalls(Payload.encodeCalls(calls));

        assertEq(back.length, calls.length);
        for (uint256 i; i < calls.length; ++i) {
            assertEq(back[i].target, calls[i].target);
            assertEq(back[i].value, calls[i].value);
            assertEq(back[i].data, calls[i].data);
        }
    }

    function test_theOpaqueWireRoundTrips() public view {
        bytes[] memory elements = Calls.encodeAll(_calls());
        bytes[] memory back = harness.decodeElements(Payload.encodeElements(elements));

        assertEq(back.length, elements.length);
        for (uint256 i; i < elements.length; ++i) {
            assertEq(back[i], elements[i]);
        }
    }

    /// THERE IS NO TAG, AND NOTHING NEEDS ONE. The form is a property of the destination:
    /// an EVM chain always gets `Call[]`, everything else always gets `bytes[]`. Both
    /// sides know which before a byte is written, so a field saying so would carry a value
    /// each already holds — the same reason `Envelope` has no message-type field.
    function test_theFormIsDecidedByTheDestination() public view {
        assertTrue(
            harness.isTypedDestination(Erc7930.encodeEvmChain(8453)),
            "an EVM destination takes typed calls"
        );
        assertFalse(
            harness.isTypedDestination(
                Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708")
            ),
            "everything else takes opaque elements"
        );
        assertFalse(
            harness.isTypedDestination(
                Erc7930.encodeChainId(ChainType.STARKNET, bytes("SN_MAIN"))
            )
        );
    }

    /// @dev THE REASON THE TAG COULD GO, STATED AS A TEST RATHER THAN A COMMENT. Feeding a
    ///      receiver the wrong encoding fails rather than being misread — but note this is
    ///      a property of how these two layouts happen to collide, not a promise the ABI
    ///      decoder makes. What actually prevents the misread is that no path sends opaque
    ///      elements to an EVM receiver. If one is ever added, the tag has to come back.
    function test_theTwoEncodingsDoNotDecodeAsEachOther() public {
        Call[] memory calls = _calls();

        vm.expectRevert();
        harness.decodeCalls(Payload.encodeElements(Calls.encodeAll(calls)));

        vm.expectRevert();
        harness.decodeElements(Payload.encodeCalls(calls));
    }

    /// An element built for another VM is not `(address, uint256, bytes)`. On an EVM
    /// receiver that must fail rather than execute something invented from the bytes.
    function test_aNonEvmElementDoesNotDecodeAsACall() public {
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        vm.expectRevert();
        harness.decodeCalls(Payload.encodeElements(elements));
    }

    /// ...but it still HASHES, which is the property that keeps the commitment layer
    /// portable: the hub can approve a payload for a VM whose calls it cannot parse.
    function test_aNonEvmElementStillCommits() public view {
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        bytes[] memory roundTripped =
            harness.decodeElements(Payload.encodeElements(elements));

        assertEq(
            harness.hashElements(DEST, roundTripped),
            harness.hashElements(DEST, elements),
            "hashing never parses an element"
        );
    }

    /* ========================== against a real receiver ========================= */

    /// THE EQUIVALENCE, END TO END. The receiver's entry point takes `Call[]` only — an
    /// EVM receiver executes EVM calls and nothing else — but the approval it discharges
    /// may have been computed over the canonical OPAQUE elements, which is what
    /// VM-agnostic off-chain tooling produces. This is the case that would break silently
    /// if `Calls.encode` ever stopped matching the opaque element.
    function test_anOpaqueApprovalIsDischargedByTypedCalls() public {
        Call[] memory calls = _sinkCalls();

        // Built the way portable tooling builds it: over opaque elements.
        bytes32 commitment =
            Commitment.hashCalls(ChainKey.local(), Calls.encodeAll(calls));

        OpenReceiver r = new OpenReceiver();
        r.initialize(address(this), new Call[](0));
        r.commit(commitment);
        r.finalize(calls);

        assertEq(sink.pokes(), 3, "the typed array satisfied the opaque approval");
    }

    /// The typed path carries `value` from inside the committed element, not from
    /// `msg.value` — the approval covers how much the target receives.
    function test_theTypedPathSpendsTheCommittedValue() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(sink),
            value: 1 ether,
            data: abi.encodeCall(Sink.poke, (1))
        });

        OpenReceiver r = new OpenReceiver();
        r.initialize(address(this), new Call[](0));
        r.commit(Commitment.hashCalls(ChainKey.local(), calls));
        vm.deal(address(r), 1 ether);

        r.finalize(calls);
        assertEq(sink.lastValue(), 1 ether, "value came from the element");
        assertEq(address(sink).balance, 1 ether);
    }

    /// `execute` skips the hash comparison, so the gate is on the caller instead. There
    /// is exactly one entry point to gate, which is the point of dropping the opaque one.
    function test_executeIsGatedOnTheCaller() public {
        OpenReceiver r = new OpenReceiver();
        r.initialize(address(this), new Call[](0));

        vm.prank(address(0xBAD));
        vm.expectRevert(ReceiverBase.NotAuthorizedCommitter.selector);
        r.execute(_sinkCalls());
    }

    /// The receiver exposes ONE execution shape. An opaque array is not an alternative
    /// spelling of the entry point — it has no selector here at all.
    function test_thereIsNoOpaqueEntryPoint() public {
        OpenReceiver r = new OpenReceiver();
        r.initialize(address(this), new Call[](0));

        (bool ok,) = address(r).call(
            abi.encodeWithSignature("execute(bytes[])", Calls.encodeAll(_sinkCalls()))
        );
        assertFalse(ok, "there is no execute(bytes[])");

        (ok,) = address(r).call(
            abi.encodeWithSignature("finalize(bytes[])", Calls.encodeAll(_sinkCalls()))
        );
        assertFalse(ok, "there is no finalize(bytes[])");
    }

    /* ================================== helpers ================================= */

    function _calls() internal view returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({
            target: address(sink),
            value: 0,
            data: abi.encodeCall(Sink.poke, (1))
        });
        calls[1] = Call({target: address(0xC0FFEE), value: 7, data: hex""});
    }

    function _sinkCalls() internal view returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({
            target: address(sink),
            value: 0,
            data: abi.encodeCall(Sink.poke, (1))
        });
        calls[1] = Call({
            target: address(sink),
            value: 0,
            data: abi.encodeCall(Sink.poke, (2))
        });
    }
}
