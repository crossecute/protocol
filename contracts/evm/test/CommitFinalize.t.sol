// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ICommitFinalize, ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Call, Calls} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {UnsendableHub, UnsendableSpoke, homeTransmitterFor} from "test/Unsendable.sol";

/// @dev Minimal concrete receiver: records what `_execute` was handed.
contract MockReceiver is ReceiverBase {
    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

    bytes[] public executed;

    /// @dev Records and performs. A bootstrap payload's self-call to `commit` only works
    ///      if the receiver really executes, so recording alone would test nothing.
    ///      `isAllowed` is inherited open, which is the base default.
    function _execute(Call[] memory calls) internal override {
        for (uint256 i; i < calls.length; ++i) {
            executed.push(Calls.encode(calls[i]));
        }
        super._execute(calls);
    }

    function executedCount() external view returns (uint256) {
        return executed.length;
    }
}

/// @dev A stand-in transmitter that answers `owner()`.
contract OwnedTransmitter {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @dev A flag the clone can see. Clone storage starts empty and is never written by
///      the test, so the switch is reached through an immutable in the implementation:
///      immutables live in the implementation's bytecode, which is exactly what an
///      EIP-1167 clone delegatecalls into.
contract Switchboard {
    mapping(address receiver => bool) public shouldRevert;

    function set(address receiver, bool v) external {
        shouldRevert[receiver] = v;
    }
}

/// @dev A receiver whose payload can be made to fail, to exercise atomic delivery.
contract RevertingReceiver is ReceiverBase {
    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

    Switchboard public immutable switchboard;
    bytes[] public executed;

    error Nope();

    constructor(Switchboard s) {
        switchboard = s;
    }

    function _execute(Call[] memory calls) internal override {
        if (switchboard.shouldRevert(address(this))) revert Nope();
        for (uint256 i; i < calls.length; ++i) {
            executed.push(Calls.encode(calls[i]));
        }
        super._execute(calls);
    }

    function executedCount() external view returns (uint256) {
        return executed.length;
    }
}

/// @dev Exposes `_bootstrapInbound` through `inbound`, standing in for an authenticated delivery.
contract MockTransceiver is UnsendableSpoke {
    function initialize(address, address receiverImplementation_) external initializer {
        __SpokeTransceiverBase_init(
            new address[](0),
            receiverImplementation_,
            ChainKey.forEvm(1),
            Erc7930.encodeEvmChain(1),
            abi.encodePacked(address(this)), // parity: the hub shares this address
            address(0x7EA5),
            bytes32(0),
            false
        );
    }

    /// @dev Stands in for `_onInbound`, which decodes the envelope and reaches
    ///      `_bootstrapInbound` directly.
    function inbound(address transmitter, Call[] calldata calls) external {
        _bootstrapInbound(
            transmitter, bytes32(0), homeChainKey, homeTransmitterFor(this, transmitter, bytes32(0)), calls
        );
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev A transceiver that adds no authority of its own: the owner is the base's, and the
///      two roles are named at initialization and ungrantable afterwards. If this gates
///      correctly, configuring is `Ownable` and the roles confer nothing, which is the split
///      the design turns on.
contract MsigTransceiver is UnsendableHub {
    function initialize(
        address owner_,
        address treasury_,
        address[] calldata gateways_,
        address receiverImplementation_
    ) external initializer {
        __HubTransceiverBase_init(owner_, treasury_, gateways_, receiverImplementation_);
    }

    /// @dev No blanket gateway answer here, unlike the other harnesses in this file. These
    ///      tests read the member list itself, and OZ's `_grantRole` is a no-op when `hasRole`
    ///      already says yes, so an override that trusted every gateway would leave the list
    ///      empty and the tests measuring nothing.
}

contract CommitFinalizeTest is Test {
    MockTransceiver t;
    MockReceiver receiverImpl;

    address transmitter = address(0x7A11);
    address transmitter2 = address(0x7A12);
    address relayer = address(0xF00D);
    address msig = address(0x5165);
    address treasury = address(0x71EA);
    address gateway = address(0x6A7E);

    function setUp() public {
        receiverImpl = new MockReceiver();
        t = new MockTransceiver();
        t.initialize(msig, address(receiverImpl));
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({target: address(0xF00), value: 0, data: abi.encodeWithSignature("foo(uint256)", 1)});
        calls[1] =
            Call({target: address(0xBA2), value: 0, data: abi.encodeWithSignature("bar(address)", address(0xB0B))});
    }

    function _otherCalls() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: address(0xBA3), value: 0, data: abi.encodeWithSignature("baz(bool)", true)});
    }

    function hashOf(Call[] memory calls) public view returns (bytes32) {
        return Commitment.hashCalls(calls);
    }

    /* ================================ execute ================================= */

    /// @dev A commitment arrives, creating the receiver and pinning the hash in it; then
    ///      anyone supplies the array. Two steps, on purpose: the transceiver holds
    ///      nothing and the receiver holds the approval.
    function _liveReceiver() internal returns (MockReceiver r) {
        Call[] memory calls = _calls();
        r = _arrive(transmitter, calls);
        r.finalize(calls);
    }

    /// @dev Just the arrival half: the receiver exists and holds the commitment.
    ///
    /// @dev The transceiver never commits, so an approval reaches the receiver one of two
    ///      ways: inside the bootstrap payload as a self-call (see `_deferred`), or from
    ///      the source transmitter directly. This uses the second, because bootstrap
    ///      happens once per transmitter and most of these tests need several approvals.
    /// @dev The peer is the account address, not the owner. An owner's transmitter and
    ///      their receivers share one address, so the contract this receiver answers to
    ///      sits at exactly the address the receiver occupies here.
    function _arrive(address owner_, Call[] memory calls) internal returns (MockReceiver r) {
        r = _bootstrapped(t, owner_);
        vm.prank(address(r));
        r.commit(hashOf(calls));
    }

    /// @dev Stand the receiver up if it does not exist. Bootstrap is once per transmitter
    ///      and refuses a second, so this is what repeat arrivals go through.
    function _bootstrapped(MockTransceiver t_, address tx_) internal returns (MockReceiver r) {
        address predicted = t_.predictCrossAccount(tx_, bytes32(0), t_.homeChainKey());
        if (predicted.code.length == 0) t_.inbound(tx_, new Call[](0));
        r = MockReceiver(payable(predicted));
    }

    /// @dev A bootstrap payload that pins a hash instead of running anything.
    function _deferred(address receiver, bytes32 commitment) internal pure returns (Call[] memory boot) {
        boot = new Call[](1);
        boot[0] = Call({target: receiver, value: 0, data: abi.encodeCall(ICommitFinalize.commit, (commitment))});
    }

    /// @dev The point of the path. No commit, no hash, no second transaction: the caller
    ///      already verified upstream, so the receiver takes its word.
    function test_executeRunsCallsWithNoCommitmentAtAll() public {
        MockReceiver r = _liveReceiver();
        assertEq(r.pendingCount(), 0, "nothing pending");

        Call[] memory calls = _otherCalls();
        vm.prank(address(r));
        r.execute(calls);

        assertEq(r.executedCount(), 3, "2 from delivery + 1 from execute");
    }

    /// @dev Skipping the hash check is only safe if the caller is checked instead. This
    ///      is the constraint that replaces the one `finalize` relies on.
    function test_executeIsGatedWhereFinalizeIsNot() public {
        MockReceiver r = _liveReceiver();
        Call[] memory calls = _otherCalls();

        vm.prank(relayer);
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        r.execute(calls);

        // The same relayer may still finalize, because that path proves the payload.
        bytes32 pending = hashOf(calls);
        vm.prank(address(r));
        r.commit(pending);
        vm.prank(relayer);
        r.finalize(calls);
        assertEq(r.executedCount(), 3);
    }

    /// @dev The transceiver is refused, and that is the whole point of the gate. It
    ///      created this receiver and it initialized it; letting it drive one afterwards
    ///      would make it a standing authority over every receiver it had ever created,
    ///      on the chain where it is also the contract that authenticates every inbound
    ///      message. Its one call was `__ReceiverBase_init`, and it already spent it.
    function test_executeRefusesTheParentTransceiver() public {
        MockReceiver r = _liveReceiver();
        assertEq(r.parentTransceiver(), address(t), "it did create this receiver");

        vm.prank(address(t));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        r.execute(_otherCalls());

        vm.prank(address(t));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        r.commit(keccak256("anything"));

        // The transmitter, which is what a receiver actually answers to, still may.
        vm.prank(address(r));
        r.execute(_otherCalls());
        assertEq(r.executedCount(), 3);
    }

    /// @dev The authority argument, made concrete. Anyone who may `execute` could already
    ///      commit any hash and let anyone finalize it, so the short path grants nothing
    ///      the long path did not. The two gates are deliberately the same set.
    function test_executeGrantsNothingCommitDoesNot() public {
        MockReceiver r = _liveReceiver();
        Call[] memory arbitrary = _otherCalls();

        // Long way round: commit, then let an unrelated relayer push it through.
        bytes32 pending = hashOf(arbitrary);
        vm.prank(address(r));
        r.commit(pending);
        vm.prank(relayer);
        r.finalize(arbitrary);
        uint256 viaCommit = r.executedCount();

        // Short way: same caller, same effect, one transaction.
        vm.prank(address(r));
        r.execute(arbitrary);
        assertEq(r.executedCount(), viaCommit + arbitrary.length);
    }

    /// @dev A pending approval must survive an unrelated execution. Consuming it here
    ///      would let one array silently discharge an approval made over another.
    function test_executeLeavesAPendingCommitmentAlone() public {
        MockReceiver r = _liveReceiver();
        Call[] memory approved = _calls();
        bytes32 pending = hashOf(approved);

        vm.prank(address(r));
        r.commit(pending);

        vm.prank(address(r));
        r.execute(_otherCalls());
        assertTrue(r.isCommitted(pending), "approval untouched");

        // And it still requires its own matching array.
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(_otherCalls());
        r.finalize(approved);
        assertEq(r.pendingCount(), 0);
    }

    /// @dev An execution that skipped the hash comparison must be distinguishable
    ///      on-chain from one that did not, or neither can be audited.
    function test_executeEmitsADistinctEvent() public {
        MockReceiver r = _liveReceiver();
        Call[] memory calls = _otherCalls();

        vm.expectEmit(true, false, false, true, address(r));
        emit ReceiverBase.ReceiverExecuted(address(r), calls.length);
        vm.prank(address(r));
        r.execute(calls);
    }

    /// @dev No commitment means nothing else proves intent, so an empty array is refused
    ///      rather than succeeding as a no-op.
    function test_executeRejectsAnEmptyArray() public {
        MockReceiver r = _liveReceiver();
        vm.prank(address(r));
        vm.expectRevert(Executor.EmptyExecution.selector);
        r.execute(new Call[](0));
    }

    /// @dev An empty array is refused before any lookup, so no approval of nothing can exist
    ///      to discharge.
    function test_finalizeRejectsAnEmptyArray() public {
        MockReceiver r = _liveReceiver();
        vm.expectRevert(Commitment.EmptyCommitment.selector);
        r.finalize(new Call[](0));
    }

    /// @dev An uninitialized clone authorizes nobody, so `execute` cannot be front-run
    ///      onto a counterfactual receiver before the transceiver deploys it.
    function test_executeOnAnUninitializedReceiverAuthorizesNobody() public {
        MockReceiver bare = new MockReceiver();
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        bare.execute(_calls());
        vm.prank(address(0));
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        bare.execute(_calls());
    }

    /// @dev A transceiver has no level up to inherit a check from: it is the check. It
    ///      does not inherit `ReceiverBase`, so `execute` is not merely refused, it is
    ///      absent from the ABI. Absence beats a revert: there is no function to reach, so
    ///      no future change to a committer predicate can expose one.
    function test_transceiverHasNoExecuteEntryPoint() public view {
        assertEq(address(t).code.length > 0 ? uint256(0) : uint256(1), 0, "deployed");
        (bool ok,) = address(t).staticcall(abi.encodeWithSignature("execute((address,uint256,bytes)[])", new Call[](0)));
        assertFalse(ok, "no execute on a transceiver");
    }

    /* ============================== transceiver =============================== */

    /// @dev There is no public creation path on a spoke. An account here exists because a
    ///      bootstrap message arrived, and nothing else. An open one would let anyone
    ///      deploy an owner's account empty, one transaction ahead of their bootstrap, and
    ///      permanently deny it: `CrossProxy` arms exactly once.
    function test_aSpokeHasNoPublicCreationPath() public {
        (bool a,) = address(t).call(abi.encodeWithSignature("createReceiver(address)", transmitter));
        assertFalse(a, "no createReceiver(address)");

        (bool b,) = address(t).call(abi.encodeWithSignature("createTransmitter()"));
        assertFalse(b, "and a spoke makes no transmitters either");
    }

    /// @dev An account is created once. A second bootstrap for the same owner reverts
    ///      rather than redeploying or silently doing nothing.
    function test_anOwnerGetsExactlyOneAccount() public {
        address predicted = t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey());
        t.inbound(transmitter, _deferred(predicted, keccak256("p")));

        assertTrue(MockReceiver(payable(predicted)).isCommitted(keccak256("p")), "the bootstrap payload landed");

        vm.expectRevert(
            abi.encodeWithSelector(TransceiverBase.CrossAccountExists.selector, transmitter, bytes32(0), predicted)
        );
        t.inbound(transmitter, _deferred(predicted, keccak256("second")));
    }

    /// @dev Creation is reachable only from an authenticated delivery, so it has no selector
    ///      at all rather than a gated one.
    function test_bootstrapInboundIsNotExternal() public {
        (bool ok,) = address(t)
            .call(
                abi.encodeWithSignature(
                    "bootstrapInbound(address,bytes32,(address,uint256,bytes)[])",
                    transmitter,
                    bytes32(0),
                    new Call[](0)
                )
            );
        assertFalse(ok, "no bootstrapInbound on the ABI");
        assertEq(
            t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey()).code.length, 0, "and nothing was created"
        );
    }

    /// @dev The transceiver has no way to reach a receiver after creating it. Bootstrap is
    ///      for a chain with no receiver; a second one has nowhere to deliver its payload,
    ///      because `initialize` is single-shot and nothing else here talks to a receiver.
    function test_bootstrapRefusesAnExistingReceiver() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);

        vm.expectRevert(
            abi.encodeWithSelector(TransceiverBase.CrossAccountExists.selector, transmitter, bytes32(0), address(r))
        );
        t.inbound(transmitter, _deferred(address(r), keccak256("second")));
    }

    /// @dev The commitment is what manufactures the receiver. Arrival creates the clone
    ///      at its counterfactual address and hands it the hash in one step; the array is
    ///      supplied later, by anyone.
    function test_arrivalDeploysReceiverAtPredictedAddressHoldingTheCommitment() public {
        Call[] memory calls = _calls();
        bytes32 pending = hashOf(calls);
        address predicted = t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey());
        assertEq(predicted.code.length, 0, "not deployed before the first commitment");

        MockReceiver _r_transmitter = _bootstrapped(t, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(pending);

        assertTrue(predicted.code.length != 0, "arrival manufactured it");
        MockReceiver r = MockReceiver(payable(predicted));
        assertEq(r.sourceTransmitter(), address(r));
        assertTrue(r.isCommitted(pending), "and it holds the bridged commitment");
    }

    /// @dev The salt is the owner, their salt, and the home, none of which a payload changes,
    ///      so the address does not move between payloads: it is knowable before the first
    ///      message is ever sent.
    function test_receiverAddressIsStableAcrossPayloads() public {
        address predicted = t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey());

        Call[] memory first = _calls();
        MockReceiver a = _arrive(transmitter, first);
        a.finalize(first);

        Call[] memory second = _otherCalls();
        MockReceiver b = _arrive(transmitter, second);
        b.finalize(second);

        assertEq(address(a), predicted);
        assertEq(address(b), predicted, "same receiver reused for the second payload");
    }

    /// @dev One receiver per transmitter: different transmitters must not share one.
    function test_saltSeparatesTransmitters() public view {
        assertTrue(
            t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey())
                != t.predictCrossAccount(address(0xBEEF), bytes32(0), t.homeChainKey()),
            "transmitter must vary the address"
        );
    }

    /// @dev The commitment lives in the receiver until someone spends it, and anyone may be
    ///      that someone.
    function test_finalizeIsPermissionless() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);

        vm.prank(relayer);
        r.finalize(calls);
        assertEq(r.executedCount(), 2);
    }

    /// @dev Permissionless in who calls, not in what they may supply.
    function test_finalizeRejectsMismatchedCalls() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);

        Call[] memory tampered = _calls();
        tampered[1].data = abi.encodeWithSignature("bar(address)", address(0xBAD));

        vm.prank(relayer);
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(tampered);
    }

    /// @dev The transceiver never executes and never holds. Arrival hands the commitment
    ///      to the receiver and returns; the array shows up in a separate transaction, from
    ///      whoever has it, and runs in the receiver's own context behind its selector
    ///      policy.
    function test_transceiverRelaysAndHoldsNothing() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);

        assertEq(r.executedCount(), 0, "arrival executed nothing of the payload");
        assertTrue(r.isCommitted(hashOf(calls)), "the receiver holds the approval");

        r.finalize(calls);
        assertEq(r.executedCount(), 2, "executed once, in the receiver");
        assertEq(r.pendingCount(), 0);
    }

    /// @dev Creation and the payload are one transaction. The clone is created and its
    ///      payload runs inside `initialize`, so there is no window in which a receiver
    ///      exists with its transmitter set and its payload unperformed, and no second
    ///      call from the transceiver, which has no way to reach a receiver afterwards.
    function test_creationAndPayloadAreOneStep() public {
        Call[] memory calls = _calls();
        bytes32 pending = hashOf(calls);

        vm.recordLogs();
        MockReceiver _r_transmitter = _bootstrapped(t, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(pending);
        MockReceiver r = MockReceiver(payable(t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey())));

        assertTrue(r.isCommitted(pending), "the payload pinned the hash itself");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 inits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ReceiverBase.ReceiverInitialized.selector) ++inits;
        }
        assertEq(inits, 1);
    }

    /// @dev A failing payload never touches the transceiver. Arrival only pins a hash,
    ///      so it cannot fail on the payload's behalf. Execution fails later, at the
    ///      receiver, leaving the approval pinned there for anyone to retry, and the
    ///      transceiver, which is shared by every transmitter, was never involved.
    function test_failingPayloadStrandsOnlyItsOwnReceiver() public {
        Switchboard sw = new Switchboard();
        MockTransceiver rt = new MockTransceiver();
        rt.initialize(msig, address(new RevertingReceiver(sw)));

        Call[] memory calls = _calls();
        bytes32 pending = hashOf(calls);
        address addr = rt.predictCrossAccount(transmitter, bytes32(0), rt.homeChainKey());
        sw.set(addr, true);

        MockReceiver _r_transmitter = _bootstrapped(rt, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(pending);
        RevertingReceiver r = RevertingReceiver(payable(addr));
        assertTrue(r.isCommitted(pending), "arrival succeeded regardless");

        vm.prank(relayer);
        vm.expectRevert(RevertingReceiver.Nope.selector);
        r.finalize(calls);
        assertTrue(r.isCommitted(pending), "approval survives a failed execution");

        // Anyone may retry, and it still fails while the cause stands.
        vm.prank(address(0xCAFE));
        vm.expectRevert(RevertingReceiver.Nope.selector);
        r.finalize(calls);

        // Once the cause clears, the identical array goes through.
        sw.set(addr, false);
        vm.prank(relayer);
        r.finalize(calls);
        assertEq(r.executedCount(), 2);
        assertEq(r.pendingCount(), 0, "consumed only on success");
    }

    /// @dev The bootstrap event names the receiver as well as the transmitter, because
    ///      the receiver is created in the same call and an indexer should not have to
    ///      recompute a CREATE2 address to follow the payload.
    function test_bootstrapEventNamesTheReceiver() public {
        address predicted = t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey());

        vm.recordLogs();
        t.inbound(transmitter, _deferred(predicted, hashOf(_calls())));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != TransceiverBase.CrossAccountCreated.selector) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), transmitter);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), predicted);
        }
        assertTrue(found, "the bootstrap event named both");
    }

    /// @dev Deployment happens once per transmitter, and there is no second bootstrap to
    ///      confuse it with: a later one reverts rather than redeploying.
    function test_receiverDeployedFiresOnceAndCannotRecur() public {
        Call[] memory first = _calls();
        address predicted = t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey());

        vm.expectEmit(true, true, false, true, address(t));
        emit TransceiverBase.CrossAccountCreated(transmitter, predicted, bytes32(0), t.homeChainKey());
        t.inbound(transmitter, _deferred(predicted, hashOf(first)));
        MockReceiver(payable(predicted)).finalize(first);

        vm.expectRevert(
            abi.encodeWithSelector(TransceiverBase.CrossAccountExists.selector, transmitter, bytes32(0), predicted)
        );
        t.inbound(transmitter, _deferred(predicted, hashOf(_otherCalls())));
    }

    function test_cannotFinalizeTwice() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);
        r.finalize(calls);

        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(calls);
    }

    /// @dev The implementation is required at initialization, not discovered missing on
    ///      the first delivery. A transceiver that cannot produce receivers is not a
    ///      half-configured transceiver, it is one that should never have been deployed.
    function test_receiverImplementationIsRequiredAtInitialization() public {
        MockTransceiver bare = new MockTransceiver();
        vm.expectRevert(TransceiverBase.NoAccountImplementation.selector);
        bare.initialize(msig, address(0));
    }

    /// @dev A transceiver is a proxy, not a cloned receiver, and does not inherit the
    ///      clone's `initialize` at all, so there is no one-shot slot for anyone to
    ///      consume, rather than an inherited entry point overridden into reverting.
    function test_transceiverHasNoCloneInitializer() public {
        (bool ok,) = address(t).call(abi.encodeWithSignature("initialize(address,bytes32)", transmitter, bytes32(0)));
        assertFalse(ok, "no clone initializer on a transceiver");
    }

    /// @dev There is no setter. Changing the implementation does not move receivers that
    ///      already exist (clone bytecode fixes the old address at creation), so a change
    ///      silently forks the population into two logic versions. Removing the setter
    ///      makes that a redeploy, which is what it always was.
    function test_receiverImplementationCannotBeChanged() public {
        assertEq(t.receiverImplementation(), address(receiverImpl));

        (bool ok,) = address(t).call(abi.encodeWithSignature("setReceiverImplementation(address)", address(0xDEAD)));
        assertFalse(ok, "no setter on the ABI");

        // Nor through the initializer a second time.
        vm.expectRevert();
        t.initialize(msig, address(0xDEAD));
        assertEq(t.receiverImplementation(), address(receiverImpl), "unchanged");
    }

    /// @dev The transceiver arrives locked. Initializing is what locks it, so there is no
    ///      window between "the real logic is in place" and "nobody can replace it", and no
    ///      operator step that can be forgotten. Exercised behind a real proxy, since UUPS
    ///      refuses upgrades outside one.
    function test_initializingLocksUpgrades() public {
        MockTransceiver proxied = MockTransceiver(
            payable(new ERC1967Proxy(
                    address(new MockTransceiver()),
                    abi.encodeCall(MockTransceiver.initialize, (msig, address(receiverImpl)))
                ))
        );
        assertTrue(proxied.upgradesLocked(), "locked by the initializer, not by a later call");

        // And the admin cannot reopen it: there is no operation that clears the flag, so the
        // authority that would have held the upgrade key has nothing to hold.
        // `new` is hoisted: a CREATE inside the pranked expression consumes the prank.
        address blockedImpl = address(new MockTransceiver());
        vm.prank(msig);
        vm.expectRevert(TransceiverBase.UpgradesAreLocked.selector);
        proxied.upgradeToAndCall(blockedImpl, "");
    }

    /* ============================== authorization ============================= */

    /// @dev Configuring is the owner's, and only the owner's. The one role names transports
    ///      and can call nothing, which is what makes it safe for the set to be permanent.
    function test_theConfiguringAuthorityIsTheOwner() public {
        MsigTransceiver m = _msigTransceiver();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        m.setRouting(IChainRegistryRefs(address(0xDEED)), bytes32(0), Provenance.Derived);

        vm.prank(msig);
        m.setRouting(IChainRegistryRefs(address(0xDEED)), bytes32(0), Provenance.Derived);
        assertEq(address(m.chainRegistry()), address(0xDEED));

        // And the lock it arrived with does not depend on that authority being asked.
        assertTrue(m.upgradesLocked());
    }

    /// @dev The membership is whatever the initializer said, for life. The role has no role
    ///      admin and `DEFAULT_ADMIN_ROLE` is never granted, so `grantRole` has no caller that
    ///      can succeed: not the owner, not the msig, not a gateway.
    function test_theRoleCannotBeGrantedAfterInitialization() public {
        MsigTransceiver m = _msigTransceiver();

        assertEq(m.getRoleMemberCount(m.DEFAULT_ADMIN_ROLE()), 0, "nothing sits above it");

        address[] memory gateways = m.getRoleMembers(m.GATEWAY_ROLE());
        assertEq(gateways.length, 1, "exactly what was named, and nothing acquired since");
        assertEq(gateways[0], gateway);

        // The owner is the strongest caller there is here, and it still cannot.
        // Hoisted: an external call inside a pranked expression consumes the prank.
        bytes32 gatewayRole = m.GATEWAY_ROLE();
        vm.prank(msig);
        vm.expectRevert(Initializable.NotInitializing.selector);
        m.grantRole(gatewayRole, address(0xBADBAD));
    }

    /// @dev A transceiver's transports are fixed in both directions, which is the asymmetry
    ///      against an account. It is shared by every owner on its chain, so dropping a
    ///      gateway here would take every account's bootstrap path with it; an account's is
    ///      one owner's to drop, and `ReceiverBase.revokeGateway` is where that lives.
    function test_aTransceiverCanNeitherAddNorDropAGateway() public {
        MsigTransceiver m = _msigTransceiver();

        (bool found,) = address(m).call(abi.encodeWithSignature("revokeGateway(address)", gateway));
        assertFalse(found, "no revoke entry point on the ABI at all");

        bytes32 gatewayRole = m.GATEWAY_ROLE();
        vm.prank(msig);
        vm.expectRevert();
        m.revokeRole(gatewayRole, gateway);

        assertEq(m.getRoleMembers(gatewayRole).length, 1, "still exactly what it was given");
    }

    /// @dev The treasury is an address the deployment named, and there is no way to move it.
    ///      Fees leave in the transaction that charges them, so there is no accrued balance to
    ///      direct, no `withdrawFees` to gate, and no setter for a compromised owner to reach.
    function test_theTreasuryIsFixedAndThereIsNoWithdrawal() public {
        MsigTransceiver m = _msigTransceiver();
        assertEq(m.treasury(), treasury);

        (bool withdrew,) = address(m).call(abi.encodeWithSignature("withdrawFees(address)", msig));
        assertFalse(withdrew, "no withdrawal entry point at all");

        (bool set,) = address(m).call(abi.encodeWithSignature("setTreasury(address)", address(0xBAD)));
        assertFalse(set, "and no setter");
    }

    /// @dev A fee with nowhere to go is refused where it is set, not where it is charged:
    ///      the mistake surfaces at configuration time rather than burning the fee inside
    ///      somebody's bootstrap.
    function test_aFeeCannotBeSetWithoutATreasury() public {
        address[] memory gateways = new address[](1);
        gateways[0] = gateway;

        MsigTransceiver m = new MsigTransceiver();
        m.initialize(msig, address(0), gateways, address(receiverImpl));

        vm.prank(msig);
        vm.expectRevert(HubTransceiverBase.NoTreasury.selector);
        m.setBootstrapFee(ChainKey.forEvm(8453), 1 ether);
    }

    function _msigTransceiver() internal returns (MsigTransceiver m) {
        address[] memory gateways = new address[](1);
        gateways[0] = gateway;

        m = new MsigTransceiver();
        m.initialize(msig, treasury, gateways, address(receiverImpl));
    }

    /* ======================== isolation between senders ======================= */

    /// @dev An account's approvals live in the account, and isolation is structural. There
    ///      is exactly one receiver per transmitter, because the CREATE2 salt is the
    ///      transmitter, so there is no shared slot and no per-sender bookkeeping to get
    ///      wrong. The transceiver holds no approvals at all.
    function test_anAccountsApprovalsLiveInTheAccount() public {
        t.inbound(
            transmitter, _deferred(t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey()), hashOf(_calls()))
        );

        (bool a,) = address(t).staticcall(abi.encodeWithSignature("pendingOf(address)", transmitter));
        assertFalse(a, "no per-sender mapping on the transceiver");
        (bool b,) = address(t).staticcall(abi.encodeWithSignature("pendingCount()"));
        assertFalse(b, "and no approval map of its own");

        assertTrue(
            MockReceiver(payable(t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey())))
                .isCommitted(hashOf(_calls())),
            "the approval lives with the sender it belongs to"
        );
    }

    function test_sendersHoldSeparatePendingCommitments() public {
        Call[] memory a = _calls();
        Call[] memory b = _otherCalls();

        MockReceiver ra = _arrive(transmitter, a);
        MockReceiver rb = _arrive(transmitter2, b);

        assertTrue(ra != rb, "one receiver per transmitter");
        assertTrue(ra.isCommitted(hashOf(a)));
        assertTrue(rb.isCommitted(hashOf(b)));
    }

    /// @dev A payload that can never execute strands itself and nothing else. One receiver
    ///      per transmitter is what makes that structural rather than bookkeeping.
    function test_oneSendersStuckPayloadDoesNotWedgeAnother() public {
        Switchboard sw = new Switchboard();
        MockTransceiver rt = new MockTransceiver();
        rt.initialize(msig, address(new RevertingReceiver(sw)));

        Call[] memory stuck = _calls();
        Call[] memory fine = _otherCalls();
        address poisoned = rt.predictCrossAccount(transmitter, bytes32(0), rt.homeChainKey());
        sw.set(poisoned, true);

        MockReceiver _r_transmitter = _bootstrapped(rt, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(hashOf(stuck));
        MockReceiver _r_transmitter2 = _bootstrapped(rt, transmitter2);
        vm.prank(address(_r_transmitter2));
        _r_transmitter2.commit(hashOf(fine));

        vm.expectRevert(RevertingReceiver.Nope.selector);
        RevertingReceiver(payable(poisoned)).finalize(stuck);

        // The other sender is entirely unaffected, now and repeatedly.
        RevertingReceiver r2 =
            RevertingReceiver(payable(rt.predictCrossAccount(transmitter2, bytes32(0), rt.homeChainKey())));
        r2.finalize(fine);
        assertEq(r2.executedCount(), 1);

        Call[] memory more = _calls();
        vm.prank(address(_r_transmitter2));
        _r_transmitter2.commit(hashOf(more));
        r2.finalize(more);
        assertEq(r2.executedCount(), 3);

        // And the stuck one is still stuck, in its own receiver, harming nobody.
        assertTrue(RevertingReceiver(payable(poisoned)).isCommitted(hashOf(stuck)));
    }

    /// @dev Even when two senders commit to the identical array, discharging one leaves
    ///      the other pending. They are different contracts, not two entries in a table.
    function test_identicalPayloadsAreStillSeparateApprovals() public {
        Call[] memory calls = _calls();
        MockReceiver ra = _arrive(transmitter, calls);
        MockReceiver rb = _arrive(transmitter2, calls);

        ra.finalize(calls);
        assertEq(ra.pendingCount(), 0);
        assertTrue(rb.isCommitted(hashOf(calls)), "still owed");
        rb.finalize(calls);
        assertEq(rb.pendingCount(), 0);
    }

    /// @dev One sender's payloads do not block each other, in either direction: both are
    ///      recorded, and either may be discharged first. Under the queue this test asserted
    ///      the opposite, and the second payload had to wait for the first.
    function test_oneSendersPayloadsDoNotBlockEachOther() public {
        Call[] memory a = _calls();
        Call[] memory b = _otherCalls();
        MockReceiver r = _arrive(transmitter, a);

        MockReceiver _r_transmitter = _bootstrapped(t, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(hashOf(b));
        assertEq(r.pendingCount(), 2, "both recorded, neither blocked the other");

        // The later approval goes first, which is now allowed rather than refused.
        r.finalize(b);
        assertTrue(r.isCommitted(hashOf(a)), "and the earlier one is untouched");

        r.finalize(a);
        assertEq(r.pendingCount(), 0);
    }

    /// @dev A bootstrap is never deferred: the receiver is created and its payload run in the
    ///      delivery that carries them. A transceiver therefore holds no approvals and runs no
    ///      payload, so no origin can approve, cancel, or finalize anything on the contract
    ///      every account's bootstrap goes through. Absence beats a gate: there is no function
    ///      a future predicate change could expose.
    function test_aTransceiverHoldsNoApprovalsAndRunsNoPayload() public {
        bytes[] memory absent = new bytes[](6);
        absent[0] = abi.encodeWithSignature("commit(bytes32)", keccak256("p"));
        absent[1] = abi.encodeWithSignature("cancel(bytes32)", keccak256("p"));
        absent[2] = abi.encodeWithSignature("finalize((address,uint256,bytes)[])", new Call[](0));
        absent[3] = abi.encodeWithSignature("finalize((address,uint256,bytes)[][])", new Call[][](0));
        absent[4] = abi.encodeWithSignature(
            "receiveMessage(bytes32,bytes,bytes)",
            bytes32(0),
            Erc7930.encodeEvm(1, address(t)),
            Payload.encodeCalls(_calls())
        );
        absent[5] = abi.encodeWithSignature("isAllowed(address,bytes4)", address(t), bytes4(0));

        for (uint256 i; i < absent.length; ++i) {
            vm.prank(gateway);
            (bool ok,) = address(t).call(absent[i]);
            assertFalse(ok, "absent from a transceiver's ABI");
        }
    }

    /// @dev What a deferred first payload looks like instead: the bootstrap creates the
    ///      receiver and runs a payload that approves a hash on the receiver itself, and
    ///      anyone finalizes it there later.
    function test_aDeferredFirstPayloadIsCommittedOnTheReceiver() public {
        address predicted = t.predictCrossAccount(transmitter, bytes32(0), t.homeChainKey());
        Call[] memory later = _calls();

        t.inbound(transmitter, _deferred(predicted, hashOf(later)));
        assertGt(predicted.code.length, 0, "created in the delivery");

        vm.prank(relayer);
        MockReceiver(payable(predicted)).finalize(later);
        assertEq(MockReceiver(payable(predicted)).pendingCount(), 0, "finalized on the receiver");
    }

    /* =============================== receiver ================================= */

    function _deployedReceiver() internal returns (MockReceiver r, Call[] memory calls) {
        calls = _calls();
        r = _arrive(transmitter, calls);
        r.finalize(calls);
    }

    function test_receiverIsInitializedWithTransmitter() public {
        (MockReceiver r,) = _deployedReceiver();
        assertEq(r.sourceTransmitter(), address(r));
        assertEq(r.parentTransceiver(), address(t));
        assertEq(r.pendingCount(), 0, "discharged by the helper");
    }

    function test_isSourceTransmitter() public {
        (MockReceiver r,) = _deployedReceiver();
        assertTrue(r.isSourceTransmitter(address(r)));
        assertFalse(r.isSourceTransmitter(address(0xDEAD)));
        assertFalse(r.isSourceTransmitter(address(0)));
    }

    /// @dev One predicate, one caller. The transmitter is the only party that may drive a
    ///      receiver, and the transceiver that created it is not on the list: its whole
    ///      relationship with a receiver is the initializer it already spent.
    function test_theTransmitterIsTheOnlyAuthority() public {
        (MockReceiver r,) = _deployedReceiver();
        assertTrue(r.isSourceTransmitter(address(r)), "the owning transmitter");
        assertFalse(r.isSourceTransmitter(address(t)), "the parent transceiver may not");
        assertFalse(r.isSourceTransmitter(relayer));
        assertFalse(r.isSourceTransmitter(address(0)));
    }

    /// @dev The deferred payload still works, and this is why: a receiver and its
    ///      transmitter share one address, so the self-call an approving payload makes to
    ///      its own `commit` arrives as the source transmitter. If those two addresses
    ///      ever diverge, this assertion is what fails first.
    function test_aSelfCallIsTheSourceTransmitter() public {
        (MockReceiver r,) = _deployedReceiver();
        assertEq(r.sourceTransmitter(), address(r));
        assertTrue(r.isSourceTransmitter(address(r)));
    }

    function test_receiverCommitIsGated() public {
        (MockReceiver r,) = _deployedReceiver();

        vm.prank(relayer);
        vm.expectRevert(ReceiverBase.NotSourceTransmitter.selector);
        r.commit(keccak256("new"));

        vm.prank(address(r));
        r.commit(keccak256("new"));
        assertTrue(r.isCommitted(keccak256("new")));
    }

    /// @dev Anyone may supply the calls: only the matching array does anything. This is
    ///      the same-chain path, where the transmitter commits and any relayer discharges
    ///      it.
    function test_receiverFinalizeIsPermissionless() public {
        (MockReceiver r,) = _deployedReceiver();
        Call[] memory later = _otherCalls();
        bytes32 pending = hashOf(later);

        vm.prank(address(r));
        r.commit(pending);

        vm.prank(relayer);
        r.finalize(later);
        assertEq(r.executedCount(), 3, "2 on delivery + 1 through commit/finalize");
    }

    /// @dev The opposite of what a single slot did. A second approval joins the first
    ///      rather than colliding with it, so a payload waiting on a slow relayer cannot
    ///      stop the next from being recorded, and with no ordering, cannot stop it from
    ///      being discharged either.
    function test_receiverHoldsSeveralApprovalsAtOnce() public {
        (MockReceiver r,) = _deployedReceiver();

        vm.prank(address(r));
        r.commit(keccak256("first"));
        vm.prank(address(r));
        r.commit(keccak256("other"));

        assertEq(r.pendingCount(), 2, "both recorded, neither overwritten");
        assertTrue(r.isCommitted(keccak256("first")));
        assertTrue(r.isCommitted(keccak256("other")));
    }

    /// @dev Zero is the sentinel for cancelled and absent alike, so it can never be an
    ///      approval.
    function test_receiverStillRefusesAZeroCommitment() public {
        (MockReceiver r,) = _deployedReceiver();

        vm.prank(address(r));
        vm.expectRevert(ReceiverBase.ZeroCommitment.selector);
        r.commit(bytes32(0));
    }

    /// @dev Consecutive payloads reuse the same receiver, each pinned and discharged in
    ///      turn. The clone is created once; every later commitment goes through `commit`.
    function test_consecutivePayloadsReuseTheReceiver() public {
        (MockReceiver r,) = _deployedReceiver();

        Call[] memory second = _otherCalls();
        MockReceiver _r_transmitter = _bootstrapped(t, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(hashOf(second));
        r.finalize(second);

        assertEq(r.executedCount(), 3, "both payloads ran");
        assertEq(r.pendingCount(), 0, "and nothing is queued behind them");
    }

    function test_receiverCannotBeReinitialized() public {
        (MockReceiver r,) = _deployedReceiver();
        vm.expectRevert();
        r.initialize(address(0xDEAD), new Call[](0));
    }

    /// @dev The chain-binding is the receiver's alone now. The transceiver has no array
    ///      to hash, so a commitment built for the wrong destination is accepted on
    ///      arrival, sits looking valid, and fails when someone tries to spend it. The
    ///      check moved later; it did not disappear.
    function test_wrongChainCommitmentIsAcceptedThenUnspendable() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);

        vm.chainId(999);
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(calls);
    }

    function test_receiverCommitmentIsChainBound() public {
        (MockReceiver r,) = _deployedReceiver();
        Call[] memory later = _otherCalls();
        bytes32 pending = hashOf(later);

        vm.prank(address(r));
        r.commit(pending);

        vm.chainId(999);
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(later);
    }
}
