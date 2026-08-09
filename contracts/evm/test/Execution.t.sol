// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Call, Calls} from "src/messaging/Call.sol";

/// @dev Records what it was called with, and can be made to fail.
contract Target {
    uint256 public pings;
    uint256 public lastValue;
    uint256 public received;

    error Boom(string why);

    function ping(uint256 n) external payable {
        pings += n;
        lastValue = msg.value;
    }

    function nope() external pure {
        revert Boom("target said no");
    }

    receive() external payable {
        received += msg.value;
    }
}

/// @dev Uses the CONCRETE `_execute` (no override), with an openable allowlist.
contract PolicyReceiver is ReceiverBase {
    mapping(address => mapping(bytes4 => bool)) public permitted;

    function allow(address target, bytes4 selector) external {
        permitted[target][selector] = true;
    }

    function isAllowed(address target, bytes4 selector)
        public
        view
        override
        returns (bool)
    {
        return permitted[target][selector];
    }
}

/// @dev A receiver that implements no policy at all, to check the open default.
contract SilentReceiver is ReceiverBase {}

contract ExecutionTest is Test {
    PolicyReceiver r;
    Target t;

    address transmitter = address(0x7A11);
    address relayer = address(0xF00D);

    function setUp() public {
        r = new PolicyReceiver();
        r.initialize(transmitter, new Call[](0));
        t = new Target();
    }

    function _call(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (Call memory)
    {
        return Call({target: target, value: value, data: data});
    }

    function _one(Call memory c) internal pure returns (Call[] memory a) {
        a = new Call[](1);
        a[0] = c;
    }

    /* ================================ allowlist ================================ */

    /// @dev THE DEFAULT ALLOWS EVERYTHING, AND THAT IS NOT A MISSING CHECK. A receiver is
    ///      a full-power account answering to one owner, the same way a Safe is: anything
    ///      that can deliver an authenticated message to it can already make it do
    ///      anything. A `(target, selector)` gate was never what stood between a forged
    ///      message and execution: a compromised bridge could forge a commitment hash
    ///      just as easily as a call array. The policy is a restriction an owner opts
    ///      into.
    function test_aReceiverWithNoPolicyExecutesEverything() public {
        SilentReceiver s = new SilentReceiver();
        s.initialize(transmitter, new Call[](0));

        vm.prank(transmitter);
        s.execute(_one(_call(address(t), 0, abi.encodeCall(Target.ping, (1)))));
        assertEq(t.pings(), 1, "no policy is an open policy, not a closed one");
    }

    /// @dev The gate that actually protects a receiver is on the CALLER, and it is
    ///      unaffected by the policy being open.
    function test_anOpenPolicyStillGatesTheCaller() public {
        SilentReceiver s = new SilentReceiver();
        s.initialize(transmitter, new Call[](0));

        vm.prank(address(0xBAD));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        s.execute(_one(_call(address(t), 0, abi.encodeCall(Target.ping, (1)))));
    }

    function test_permittedCallRuns() public {
        r.allow(address(t), Target.ping.selector);

        vm.prank(transmitter);
        r.execute(_one(_call(address(t), 0, abi.encodeCall(Target.ping, (3)))));
        assertEq(t.pings(), 3);
    }

    /// @dev The policy is per (target, selector), not per selector. The same function on
    ///      a different contract is a different operation: `transfer` on the token you
    ///      meant and `transfer` on one an attacker deployed are not interchangeable.
    function test_policyIsPerTargetNotPerSelector() public {
        r.allow(address(t), Target.ping.selector);
        Target other = new Target();

        bytes memory data = abi.encodeCall(Target.ping, (1));
        vm.prank(transmitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Executor.SelectorNotAllowed.selector,
                address(other),
                Target.ping.selector
            )
        );
        r.execute(_one(_call(address(other), 0, data)));
    }

    /// @dev Under four bytes there is no selector. `bytes4` of a short `bytes` right-pads
    ///      with zeros, so reading one anyway would invent a selector the payload never
    ///      named, and could match an allowlist entry by accident.
    function test_bareTransferUsesTheZeroSelector() public {
        vm.deal(address(r), 1 ether);

        vm.prank(transmitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Executor.SelectorNotAllowed.selector, address(t), bytes4(0)
            )
        );
        r.execute(_one(_call(address(t), 1 ether, "")));

        r.allow(address(t), bytes4(0));
        vm.prank(transmitter);
        r.execute(_one(_call(address(t), 1 ether, "")));
        assertEq(t.received(), 1 ether);
    }

    /* ================================== value ================================== */

    /// @dev The value is INSIDE the committed element, so the approval covers how much
    ///      each target receives: a payload cannot be re-priced at execution time.
    function test_valueComesFromTheCommittedElement() public {
        r.allow(address(t), Target.ping.selector);
        vm.deal(transmitter, 5 ether);

        vm.prank(transmitter);
        r.execute{value: 5 ether}(_one(_call(address(t), 2 ether, abi.encodeCall(Target.ping, (1)))));

        assertEq(t.lastValue(), 2 ether, "the element decides, not the caller");
        assertEq(address(r).balance, 3 ether, "the remainder stays with the receiver");
    }

    /// @dev `finalize` is permissionless and takes no value, so a payload that spends ETH
    ///      has to spend a balance already here. `receive()` is what lets it be put there.
    function test_finalizeSpendsAPreFundedBalance() public {
        r.allow(address(t), Target.ping.selector);
        Call[] memory calls = _one(_call(address(t), 1 ether, abi.encodeCall(Target.ping, (1))));

        vm.prank(transmitter);
        r.commit(hashOf(calls));

        // Nothing to spend yet.
        vm.prank(relayer);
        vm.expectRevert();
        r.finalize(calls);

        (bool ok,) = address(r).call{value: 1 ether}("");
        assertTrue(ok, "receive() accepts a prefund");

        vm.prank(relayer);
        r.finalize(calls);
        assertEq(t.lastValue(), 1 ether);
    }

    /* ============================== all or nothing ============================= */

    /// @dev The commitment approves the array as a UNIT, and `finalize` has already
    ///      cleared it by the time execution runs, so a partial success would discharge
    ///      an approval that was never satisfied, unrepeatably.
    function test_oneFailureRevertsTheWholeBatch() public {
        r.allow(address(t), Target.ping.selector);
        r.allow(address(t), Target.nope.selector);

        Call[] memory calls = new Call[](3);
        calls[0] = _call(address(t), 0, abi.encodeCall(Target.ping, (1)));
        calls[1] = _call(address(t), 0, abi.encodeCall(Target.nope, ()));
        calls[2] = _call(address(t), 0, abi.encodeCall(Target.ping, (1)));

        vm.prank(transmitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Executor.CallFailed.selector,
                uint256(1),
                abi.encodeWithSelector(Target.Boom.selector, "target said no")
            )
        );
        r.execute(calls);

        assertEq(t.pings(), 0, "the first call was rolled back with the rest");
    }

    /// @dev The index and the original reason both survive. The array is approved as a
    ///      unit, so knowing WHICH element failed is the difference between a diagnosable
    ///      payload and a rejected one.
    function test_failureCarriesTheIndexAndTheReason() public {
        r.allow(address(t), Target.nope.selector);

        vm.prank(transmitter);
        try r.execute(_one(_call(address(t), 0, abi.encodeCall(Target.nope, ())))) {
            revert("should have failed");
        } catch (bytes memory err) {
            (uint256 idx, bytes memory reason) =
                abi.decode(_stripSelector(err), (uint256, bytes));
            assertEq(idx, 0);
            assertEq(
                reason, abi.encodeWithSelector(Target.Boom.selector, "target said no")
            );
        }
    }

    function test_callsRunInOrder() public {
        r.allow(address(t), Target.ping.selector);

        Call[] memory calls = new Call[](3);
        calls[0] = _call(address(t), 0, abi.encodeCall(Target.ping, (1)));
        calls[1] = _call(address(t), 0, abi.encodeCall(Target.ping, (10)));
        calls[2] = _call(address(t), 0, abi.encodeCall(Target.ping, (100)));

        vm.prank(transmitter);
        r.execute(calls);
        assertEq(t.pings(), 111);
    }

    /* ================================= helpers ================================= */

    function hashOf(Call[] memory calls) public view returns (bytes32) {
        return Commitment.hashCalls(calls);
    }

    function _stripSelector(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }
}
