// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ReceiverBase, ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Call, Calls} from "src/messaging/Call.sol";

/// @dev Minimal concrete receiver: records what `_execute` was handed.
contract MockReceiver is ReceiverBase {
    bytes[] public executed;

    /// @dev Records AND performs. A bootstrap payload's self-call to `commit` only works
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

/// @dev A stand-in transmitter that answers `owner()`, which is how `createReceiver`
///      identifies who may stand a receiver up.
contract OwnedTransmitter {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @dev A flag the CLONE can see. Clone storage starts empty and is never written by
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

/// @dev Exposes the self-call `commit` and the implementation setter for testing.
contract MockTransceiver is SpokeTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_, address receiverImplementation_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(
            receiverImplementation_,
            ChainKey.forEvm(1),
            abi.encode(uint32(1)),
            abi.encodePacked(address(0xB0BB1E))
        );
    }


    /// @dev The mock supplies its own authority, exactly as a real protocol binding does.
    function _checkAdmin() internal view override {
        _checkOwner();
    }

    /// @dev Stands in for `_onInbound`: the real path decodes the payload and reaches
    ///      `bootstrapInbound` via a self-call.
    function inbound(address transmitter, Call[] calldata calls) external {
        this.bootstrapInbound(transmitter, bytes32(0), calls);
    }
}

/// @dev A transceiver with NO `Ownable` anywhere in its inheritance: authority is a raw
///      comparison. If this compiles and gates correctly, `TransceiverBase` genuinely has
///      no ownership opinion, which is the property that lets a protocol SDK bringing its
///      own `Ownable` (LayerZero's `OAppCore`, a Hyperlane mailbox client) be inherited
///      alongside it without two ownership systems in one contract.
contract MsigTransceiver is HubTransceiverBase {
    address public msigAdmin;

    error NotMsig();

    function initialize(address admin_, address receiverImplementation_)
        external
        initializer
    {
        msigAdmin = admin_;
        __TransceiverBase_init();
    }

    function _checkAdmin() internal view override {
        if (msg.sender != msigAdmin) revert NotMsig();
    }
}

contract CommitFinalizeTest is Test {
    MockTransceiver t;
    MockReceiver receiverImpl;

    address transmitter = address(0x7A11);
    address transmitter2 = address(0x7A12);
    address relayer = address(0xF00D);
    address msig = address(0x5165);

    function setUp() public {
        receiverImpl = new MockReceiver();
        t = new MockTransceiver();
        t.initialize(msig, address(receiverImpl));
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({
            target: address(0xF00),
            value: 0,
            data: abi.encodeWithSignature("foo(uint256)", 1)
        });
        calls[1] = Call({
            target: address(0xBA2),
            value: 0,
            data: abi.encodeWithSignature("bar(address)", address(0xB0B))
        });
    }

    function _otherCalls() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: address(0xBA3),
            value: 0,
            data: abi.encodeWithSignature("baz(bool)", true)
        });
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
    /// @dev THE TRANSCEIVER NEVER COMMITS, so an approval reaches the receiver one of two
    ///      ways: inside the bootstrap payload as a self-call (see `_deferred`), or from
    ///      the source transmitter directly. This uses the second, because bootstrap
    ///      happens once per transmitter and most of these tests need several approvals.
    /// @dev THE PEER IS THE ACCOUNT ADDRESS, NOT THE OWNER. An owner's transmitter and
    ///      their receivers share one address, so the contract this receiver answers to
    ///      sits at exactly the address the receiver occupies here.
    function _arrive(address owner_, Call[] memory calls) internal returns (MockReceiver r) {
        r = _bootstrapped(t, owner_);
        vm.prank(address(r));
        r.commit(hashOf(calls));
    }

    /// @dev Stand the receiver up if it does not exist. Bootstrap is once per transmitter
    ///      and refuses a second, so this is what repeat arrivals go through.
    function _bootstrapped(MockTransceiver t_, address tx_)
        internal
        returns (MockReceiver r)
    {
        address predicted = t_.predictCrossAccount(tx_, bytes32(0));
        if (predicted.code.length == 0) t_.inbound(tx_, new Call[](0));
        r = MockReceiver(payable(predicted));
    }

    /// @dev A bootstrap payload that pins a hash instead of running anything.
    function _deferred(address receiver, bytes32 commitment)
        internal
        pure
        returns (Call[] memory boot)
    {
        boot = new Call[](1);
        boot[0] = Call({
            target: receiver,
            value: 0,
            data: abi.encodeCall(ICommitFinalize.commit, (commitment))
        });
    }

    /// @dev THE POINT OF THE PATH. No commit, no hash, no second transaction: the caller
    ///      already verified upstream, so the receiver takes its word.
    function test_executeRunsCallsWithNoCommitmentAtAll() public {
        MockReceiver r = _liveReceiver();
        assertEq(r.commitment(), bytes32(0), "nothing pending");

        Call[] memory calls = _otherCalls();
        vm.prank(address(t));
        r.execute(calls);

        assertEq(r.executedCount(), 3, "2 from delivery + 1 from execute");
    }

    /// @dev Skipping the hash check is only safe if the caller is checked instead. This
    ///      is the constraint that replaces the one `finalize` relies on.
    function test_executeIsGatedWhereFinalizeIsNot() public {
        MockReceiver r = _liveReceiver();
        Call[] memory calls = _otherCalls();

        vm.prank(relayer);
        vm.expectRevert(ReceiverBase.NotAuthorizedCommitter.selector);
        r.execute(calls);

        // The same relayer may still finalize, because that path proves the payload.
        bytes32 pending = hashOf(calls);
        vm.prank(address(t));
        r.commit(pending);
        vm.prank(relayer);
        r.finalize(calls);
        assertEq(r.executedCount(), 3);
    }

    /// @dev Both committers, for the same reason they may commit: the transceiver relays
    ///      after verifying, the transmitter covers a same-chain deployment.
    function test_executeAllowsBothCommitters() public {
        MockReceiver r = _liveReceiver();

        vm.prank(address(t));
        r.execute(_otherCalls());
        vm.prank(address(r));
        r.execute(_otherCalls());

        assertEq(r.executedCount(), 4);
    }

    /// @dev THE AUTHORITY ARGUMENT, made concrete. Anyone who may `execute` could already
    ///      commit any hash and let anyone finalize it, so the short path grants nothing
    ///      the long path did not. The two gates are deliberately the same set.
    function test_executeGrantsNothingCommitDoesNot() public {
        MockReceiver r = _liveReceiver();
        Call[] memory arbitrary = _otherCalls();

        // Long way round: commit, then let an unrelated relayer push it through.
        bytes32 pending = hashOf(arbitrary);
        vm.prank(address(t));
        r.commit(pending);
        vm.prank(relayer);
        r.finalize(arbitrary);
        uint256 viaCommit = r.executedCount();

        // Short way: same caller, same effect, one transaction.
        vm.prank(address(t));
        r.execute(arbitrary);
        assertEq(r.executedCount(), viaCommit + arbitrary.length);
    }

    /// @dev A pending approval must survive an unrelated execution. Consuming it here
    ///      would let one array silently discharge an approval made over another.
    function test_executeLeavesAPendingCommitmentAlone() public {
        MockReceiver r = _liveReceiver();
        Call[] memory approved = _calls();
        bytes32 pending = hashOf(approved);

        vm.prank(address(t));
        r.commit(pending);

        vm.prank(address(t));
        r.execute(_otherCalls());
        assertEq(r.commitment(), pending, "approval untouched");

        // And it still requires its own matching array.
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(_otherCalls());
        r.finalize(approved);
        assertEq(r.commitment(), bytes32(0));
    }

    /// @dev An execution that skipped the hash comparison must be distinguishable
    ///      on-chain from one that did not, or neither can be audited.
    function test_executeEmitsADistinctEvent() public {
        MockReceiver r = _liveReceiver();
        Call[] memory calls = _otherCalls();

        vm.expectEmit(true, false, false, true, address(r));
        emit ReceiverBase.ReceiverExecuted(address(t), calls.length);
        vm.prank(address(t));
        r.execute(calls);
    }

    /// @dev No commitment means nothing else proves intent, so an empty array is refused
    ///      rather than succeeding as a no-op.
    function test_executeRejectsAnEmptyArray() public {
        MockReceiver r = _liveReceiver();
        vm.prank(address(t));
        vm.expectRevert(Executor.EmptyExecution.selector);
        r.execute(new Call[](0));
    }

    /// @dev An uninitialized clone authorizes nobody, so `execute` cannot be front-run
    ///      onto a counterfactual receiver before the transceiver deploys it.
    function test_executeOnAnUninitializedReceiverAuthorizesNobody() public {
        MockReceiver bare = new MockReceiver();
        vm.expectRevert(ReceiverBase.NotAuthorizedCommitter.selector);
        bare.execute(_calls());
        vm.prank(address(0));
        vm.expectRevert(ReceiverBase.NotAuthorizedCommitter.selector);
        bare.execute(_calls());
    }

    /// @dev A transceiver has no level up to inherit a check from: it IS the check. It
    ///      does not inherit `ReceiverBase`, so `execute` is not merely refused, it is
    ///      absent from the ABI. Absence beats a revert: there is no function to reach, so
    ///      no future change to a committer predicate can expose one.
    function test_transceiverHasNoExecuteEntryPoint() public view {
        assertEq(
            address(t).code.length > 0 ? uint256(0) : uint256(1),
            0,
            "deployed"
        );
        (bool ok,) = address(t).staticcall(
            abi.encodeWithSignature("execute((address,uint256,bytes)[])", new Call[](0))
        );
        assertFalse(ok, "no execute on a transceiver");
    }

    /* ============================== transceiver =============================== */

    /// @dev THERE IS NO PUBLIC CREATION PATH ON A SPOKE. An account here exists because a
    ///      bootstrap message arrived, and nothing else. An open one would let anyone
    ///      deploy an owner's account empty, one transaction ahead of their bootstrap, and
    ///      permanently deny it: `CrossProxy` arms exactly once.
    function test_aSpokeHasNoPublicCreationPath() public {
        (bool a,) = address(t).call(
            abi.encodeWithSignature("createReceiver(address)", transmitter)
        );
        assertFalse(a, "no createReceiver(address)");

        (bool b,) = address(t).call(abi.encodeWithSignature("createTransmitter()"));
        assertFalse(b, "and a spoke makes no transmitters either");
    }

    /// @dev An account is created once. A second bootstrap for the same owner reverts
    ///      rather than redeploying or silently doing nothing.
    function test_anOwnerGetsExactlyOneAccount() public {
        address predicted = t.predictCrossAccount(transmitter, bytes32(0));
        t.inbound(transmitter, _deferred(predicted, keccak256("p")));

        assertEq(
            MockReceiver(payable(predicted)).commitment(),
            keccak256("p"),
            "the bootstrap payload landed"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.CrossAccountExists.selector, transmitter, bytes32(0), predicted
            )
        );
        t.inbound(transmitter, _deferred(predicted, keccak256("second")));
    }

    function test_bootstrapInboundIsSelfCallOnly() public {
        vm.expectRevert();
        t.bootstrapInbound(transmitter, bytes32(0), new Call[](0));
    }

    /// @dev THE TRANSCEIVER HAS NO WAY TO REACH A RECEIVER AFTER CREATING IT. Bootstrap is
    ///      for a chain with no receiver; a second one has nowhere to deliver its payload,
    ///      because `initialize` is single-shot and nothing else here talks to a receiver.
    function test_bootstrapRefusesAnExistingReceiver() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.CrossAccountExists.selector, transmitter, bytes32(0), address(r)
            )
        );
        t.inbound(transmitter, _deferred(address(r), keccak256("second")));
    }

    /// @dev THE COMMITMENT IS WHAT MANUFACTURES THE RECEIVER. Arrival creates the clone
    ///      at its counterfactual address and hands it the hash in one step; the array is
    ///      supplied later, by anyone.
    function test_arrivalDeploysReceiverAtPredictedAddressHoldingTheCommitment() public {
        Call[] memory calls = _calls();
        bytes32 pending = hashOf(calls);
        address predicted = t.predictCrossAccount(transmitter, bytes32(0));
        assertEq(predicted.code.length, 0, "not deployed before the first commitment");

        MockReceiver _r_transmitter = _bootstrapped(t, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(pending);

        assertTrue(predicted.code.length != 0, "arrival manufactured it");
        MockReceiver r = MockReceiver(payable(predicted));
        assertEq(r.sourceTransmitter(), address(r));
        assertEq(r.commitment(), pending, "and it holds the bridged commitment");
    }

    /// @dev The salt is the transmitter alone, so the address does not move between
    ///      payloads: it is knowable before the first message is ever sent.
    function test_receiverAddressIsStableAcrossPayloads() public {
        address predicted = t.predictCrossAccount(transmitter, bytes32(0));

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
    function test_saltSeparatesTransmitters() public {
        assertTrue(
            t.predictCrossAccount(transmitter, bytes32(0)) != t.predictCrossAccount(address(0xBEEF), bytes32(0)),
            "transmitter must vary the address"
        );
    }

    /// @dev The commitment lives in the transceiver until someone spends it, and anyone
    ///      may be that someone.
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

    /// @dev THE TRANSCEIVER NEVER EXECUTES AND NEVER HOLDS. Arrival hands the commitment
    ///      to the receiver and returns; the array shows up in a separate transaction, from
    ///      whoever has it, and runs in the receiver's own context behind its selector
    ///      policy.
    function test_transceiverRelaysAndHoldsNothing() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);

        assertEq(r.executedCount(), 0, "arrival executed nothing of the payload");
        assertEq(r.commitment(), hashOf(calls), "the receiver holds the approval");

        r.finalize(calls);
        assertEq(r.executedCount(), 2, "executed once, in the receiver");
        assertEq(r.commitment(), bytes32(0));
    }

    /// @dev CREATION AND THE PAYLOAD ARE ONE TRANSACTION. The clone is created and its
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
        MockReceiver r = MockReceiver(payable(t.predictCrossAccount(transmitter, bytes32(0))));

        assertEq(r.commitment(), pending, "the payload pinned the hash itself");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 inits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ReceiverBase.ReceiverInitialized.selector) ++inits;
        }
        assertEq(inits, 1);
    }

    /// @dev A FAILING PAYLOAD NEVER TOUCHES THE TRANSCEIVER. Arrival only pins a hash,
    ///      so it cannot fail on the payload's behalf. Execution fails later, at the
    ///      receiver, leaving the approval pinned there for anyone to retry, and the
    ///      transceiver, which is shared by every transmitter, was never involved.
    function test_failingPayloadStrandsOnlyItsOwnReceiver() public {
        Switchboard sw = new Switchboard();
        MockTransceiver rt = new MockTransceiver();
        rt.initialize(msig, address(new RevertingReceiver(sw)));

        Call[] memory calls = _calls();
        bytes32 pending = hashOf(calls);
        address addr = rt.predictCrossAccount(transmitter, bytes32(0));
        sw.set(addr, true);

        MockReceiver _r_transmitter = _bootstrapped(rt, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(pending);
        RevertingReceiver r = RevertingReceiver(payable(addr));
        assertEq(r.commitment(), pending, "arrival succeeded regardless");

        vm.prank(relayer);
        vm.expectRevert(RevertingReceiver.Nope.selector);
        r.finalize(calls);
        assertEq(r.commitment(), pending, "approval survives a failed execution");

        // Anyone may retry, and it still fails while the cause stands.
        vm.prank(address(0xCAFE));
        vm.expectRevert(RevertingReceiver.Nope.selector);
        r.finalize(calls);

        // Once the cause clears, the identical array goes through.
        sw.set(addr, false);
        vm.prank(relayer);
        r.finalize(calls);
        assertEq(r.executedCount(), 2);
        assertEq(r.commitment(), bytes32(0), "consumed only on success");
    }

    /// @dev The bootstrap event names the receiver as well as the transmitter, because
    ///      the receiver is created in the same call and an indexer should not have to
    ///      recompute a CREATE2 address to follow the payload.
    function test_bootstrapEventNamesTheReceiver() public {
        address predicted = t.predictCrossAccount(transmitter, bytes32(0));

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
        address predicted = t.predictCrossAccount(transmitter, bytes32(0));

        vm.expectEmit(true, true, false, false, address(t));
        emit TransceiverBase.CrossAccountCreated(transmitter, predicted, bytes32(0));
        t.inbound(transmitter, _deferred(predicted, hashOf(first)));
        MockReceiver(payable(predicted)).finalize(first);

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.CrossAccountExists.selector, transmitter, bytes32(0), predicted
            )
        );
        t.inbound(transmitter, _deferred(predicted, hashOf(_otherCalls())));
    }

    function test_cannotFinalizeTwice() public {
        Call[] memory calls = _calls();
        MockReceiver r = _arrive(transmitter, calls);
        r.finalize(calls);

        vm.expectRevert(ReceiverBase.NothingCommitted.selector);
        r.finalize(calls);
    }

    /// @dev The implementation is required AT INITIALIZATION, not discovered missing on
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
        (bool ok,) = address(t).call(
            abi.encodeWithSignature(
                "initialize(address,bytes32)", transmitter, bytes32(0)
            )
        );
        assertFalse(ok, "no clone initializer on a transceiver");
    }

    /// @dev THERE IS NO SETTER. Changing the implementation does not move receivers that
    ///      already exist (clone bytecode has the old address baked in), so a change
    ///      silently forks the population into two logic versions. Removing the setter
    ///      makes that a redeploy, which is what it always was.
    function test_receiverImplementationCannotBeChanged() public {
        assertEq(t.receiverImplementation(), address(receiverImpl));

        (bool ok,) = address(t).call(
            abi.encodeWithSignature("setReceiverImplementation(address)", address(0xDEAD))
        );
        assertFalse(ok, "no setter on the ABI");

        // Nor through the initializer a second time.
        vm.expectRevert();
        t.initialize(msig, address(0xDEAD));
        assertEq(t.receiverImplementation(), address(receiverImpl), "unchanged");
    }

    /// @dev The lock is one-way: the proxy must be upgradeable to get off Nick's factory
    ///      implementation, and must not stay that way once the real transceiver is in.
    ///      Exercised behind a real proxy, since UUPS refuses upgrades outside one.
    function test_upgradeLockIsOneWay() public {
        MockTransceiver proxied = MockTransceiver(
            address(
                new ERC1967Proxy(
                    address(new MockTransceiver()),
                    abi.encodeCall(MockTransceiver.initialize, (msig, address(receiverImpl)))
                )
            )
        );
        assertFalse(proxied.upgradesLocked());

        // While unlocked, the owner can still upgrade: that is how the proxy gets off
        // the Arachnid/Nick's-factory implementation in the first place.
        // `new` is hoisted: a CREATE inside the pranked expression consumes the prank.
        address nextImpl = address(new MockTransceiver());
        vm.prank(msig);
        proxied.upgradeToAndCall(nextImpl, "");

        vm.expectRevert();
        proxied.lockUpgrades();

        vm.prank(msig);
        proxied.lockUpgrades();
        assertTrue(proxied.upgradesLocked());

        address blockedImpl = address(new MockTransceiver());
        vm.prank(msig);
        vm.expectRevert(TransceiverBase.UpgradesAreLocked.selector);
        proxied.upgradeToAndCall(blockedImpl, "");
    }

    /* ============================== authorization ============================= */

    /// @dev THE SEAM THAT LETS AN OAPP JOIN. The base declares `_checkAdmin` and never
    ///      implements it, so the authority can be anything the concrete contract already
    ///      has. Here it is a bare address comparison with no OpenZeppelin `Ownable` in
    ///      the tree at all: the same slot a LayerZero `OAppCore` would fill with
    ///      `_checkOwner()`.
    function test_authorityCanBeSuppliedWithoutOwnable() public {
        MsigTransceiver m = new MsigTransceiver();
        m.initialize(msig, address(receiverImpl));

        vm.expectRevert(MsigTransceiver.NotMsig.selector);
        m.setRouting(IChainRegistryRefs(address(0xDEED)), bytes32(0), Provenance.Derived);

        vm.prank(msig);
        m.setRouting(IChainRegistryRefs(address(0xDEED)), bytes32(0), Provenance.Derived);
        assertEq(address(m.chainRegistry()), address(0xDEED));

        // And it gates the upgrade lock too, which is the one that must not be bypassable.
        vm.expectRevert(MsigTransceiver.NotMsig.selector);
        m.lockUpgrades();
        vm.prank(msig);
        m.lockUpgrades();
        assertTrue(m.upgradesLocked());
    }

    /// @dev Two authorities in one contract would mean a transceiver "locked" behind one
    ///      can still be reconfigured through the other. There is exactly one here, and
    ///      the base contributes none of it.
    function test_theOnlyAuthorityIsTheConcreteContracts() public {
        MsigTransceiver m = new MsigTransceiver();
        m.initialize(msig, address(receiverImpl));

        (bool ok,) = address(m).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the base contributes no owner()");
        assertEq(m.msigAdmin(), msig, "only the concrete contract's authority exists");
    }

    /* ======================== isolation between senders ======================= */

    /// @dev THE TRANSCEIVER HOLDS NOTHING, AND ISOLATION IS STRUCTURAL. An approval lives
    ///      in the sender's own receiver, and there is exactly one receiver per transmitter
    ///      because the CREATE2 salt is the transmitter. There is no shared slot and no
    ///      per-sender bookkeeping to get wrong.
    function test_transceiverHoldsNoCommitmentState() public {
        t.inbound(transmitter, _deferred(t.predictCrossAccount(transmitter, bytes32(0)), hashOf(_calls())));

        (bool a,) = address(t).staticcall(
            abi.encodeWithSignature("pendingOf(address)", transmitter)
        );
        assertFalse(a, "no pending mapping");
        (bool b,) = address(t).staticcall(abi.encodeWithSignature("commitment()"));
        assertFalse(b, "no single slot either");

        assertEq(
            MockReceiver(payable(t.predictCrossAccount(transmitter, bytes32(0)))).commitment(),
            hashOf(_calls()),
            "the approval lives with the sender it belongs to"
        );
    }

    function test_sendersHoldSeparatePendingCommitments() public {
        Call[] memory a = _calls();
        Call[] memory b = _otherCalls();

        MockReceiver ra = _arrive(transmitter, a);
        MockReceiver rb = _arrive(transmitter2, b);

        assertTrue(ra != rb, "one receiver per transmitter");
        assertEq(ra.commitment(), hashOf(a));
        assertEq(rb.commitment(), hashOf(b));
    }

    /// @dev A payload that can never execute strands itself and nothing else. One receiver
    ///      per transmitter is what makes that structural rather than bookkeeping.
    function test_oneSendersStuckPayloadDoesNotWedgeAnother() public {
        Switchboard sw = new Switchboard();
        MockTransceiver rt = new MockTransceiver();
        rt.initialize(msig, address(new RevertingReceiver(sw)));

        Call[] memory stuck = _calls();
        Call[] memory fine = _otherCalls();
        address poisoned = rt.predictCrossAccount(transmitter, bytes32(0));
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
        RevertingReceiver r2 = RevertingReceiver(payable(rt.predictCrossAccount(transmitter2, bytes32(0))));
        r2.finalize(fine);
        assertEq(r2.executedCount(), 1);

        Call[] memory more = _calls();
        vm.prank(address(_r_transmitter2));
        _r_transmitter2.commit(hashOf(more));
        r2.finalize(more);
        assertEq(r2.executedCount(), 3);

        // And the stuck one is still stuck, in its own receiver, harming nobody.
        assertEq(RevertingReceiver(payable(poisoned)).commitment(), hashOf(stuck));
    }

    /// @dev Even when two senders commit to the IDENTICAL array, discharging one leaves
    ///      the other pending. They are different contracts, not two entries in a table.
    function test_identicalPayloadsAreStillSeparateApprovals() public {
        Call[] memory calls = _calls();
        MockReceiver ra = _arrive(transmitter, calls);
        MockReceiver rb = _arrive(transmitter2, calls);

        ra.finalize(calls);
        assertEq(ra.commitment(), bytes32(0));
        assertEq(rb.commitment(), hashOf(calls), "still owed");
        rb.finalize(calls);
        assertEq(rb.commitment(), bytes32(0));
    }

    /// @dev One live approval per sender, not a queue. Overlapping payloads from one msig
    ///      would need a nonce and an ordering rule.
    /// @dev One sender's payloads do not block each other from being recorded. Both are
    ///      queued; they are discharged in the order they arrived.
    function test_oneSendersPayloadsQueueBehindEachOther() public {
        Call[] memory a = _calls();
        Call[] memory b = _otherCalls();
        MockReceiver r = _arrive(transmitter, a);

        MockReceiver _r_transmitter = _bootstrapped(t, transmitter);
        vm.prank(address(_r_transmitter));
        _r_transmitter.commit(hashOf(b));
        assertEq(r.pendingCount(), 2, "both recorded, neither blocked the other");

        // FIFO: the second cannot jump the first.
        vm.expectRevert(ReceiverBase.CommitmentMismatch.selector);
        r.finalize(b);

        r.finalize(a);
        assertEq(r.commitment(), hashOf(b), "the second is now at the head");
        r.finalize(b);
        assertEq(r.pendingCount(), 0);
    }

    /// @dev The single-slot entry points cannot say WHOSE commitment they mean, and the
    ///      transceiver has no commitments to mean. Neither was ever inherited.
    function test_transceiverHasNoCommitFinalizeEntryPoints() public {
        (bool a,) = address(t).call(
            abi.encodeWithSignature("finalize(bytes[])", new bytes[](0))
        );
        assertFalse(a, "no finalize(bytes[])");

        (bool b,) = address(t).call(abi.encodeWithSignature("commit(bytes32)", bytes32(0)));
        assertFalse(b, "no commit(bytes32)");

        (bool c,) = address(t).call(
            abi.encodeWithSignature("finalizeTo(address,bytes[])", transmitter, new bytes[](0))
        );
        assertFalse(c, "and nothing to finalize to");
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
        assertEq(r.commitment(), bytes32(0), "discharged by the helper");
    }

    function test_isSourceTransmitter() public {
        (MockReceiver r,) = _deployedReceiver();
        assertTrue(r.isSourceTransmitter(address(r)));
        assertFalse(r.isSourceTransmitter(address(0xDEAD)));
        assertFalse(r.isSourceTransmitter(address(0)));
    }

    /// @dev The transceiver relays each new payload; the transmitter is the owner. Both
    ///      may pin a commitment, nobody else may.
    function test_authorizedCommitters() public {
        (MockReceiver r,) = _deployedReceiver();
        assertTrue(r.isAuthorizedCommitter(address(t)), "the relaying transceiver");
        assertTrue(r.isAuthorizedCommitter(address(r)), "the owning transmitter");
        assertFalse(r.isAuthorizedCommitter(relayer));
        assertFalse(r.isAuthorizedCommitter(address(0)));
    }

    function test_receiverCommitIsGated() public {
        (MockReceiver r,) = _deployedReceiver();

        vm.prank(relayer);
        vm.expectRevert(ReceiverBase.NotAuthorizedCommitter.selector);
        r.commit(keccak256("new"));

        vm.prank(address(r));
        r.commit(keccak256("new"));
        assertEq(r.commitment(), keccak256("new"));
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

    /// @dev A long-lived receiver holds one pending payload at a time.
    /// @dev THE OPPOSITE OF WHAT A SINGLE SLOT DID. A second approval appends rather than
    ///      colliding, so a payload waiting on a slow relayer cannot stop the next from
    ///      being recorded. Both stay outstanding, in order.
    function test_receiverQueuesASecondCommitmentRatherThanRefusingIt() public {
        (MockReceiver r,) = _deployedReceiver();

        vm.prank(address(r));
        uint256 first = r.commit(keccak256("first"));
        vm.prank(address(r));
        uint256 second = r.commit(keccak256("other"));

        assertEq(second, first + 1, "appended, not overwritten");
        assertEq(r.pendingCount(), 2);
        assertEq(r.commitment(), keccak256("first"), "the older one is still next");
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
        assertEq(r.commitment(), bytes32(0), "and nothing is queued behind them");
    }

    function test_receiverCannotBeReinitialized() public {
        (MockReceiver r,) = _deployedReceiver();
        vm.expectRevert();
        r.initialize(address(0xDEAD), new Call[](0));
    }

    /// @dev THE CHAIN-BINDING IS THE RECEIVER'S ALONE NOW. The transceiver has no array
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
