// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {MessagingContext} from "src/messaging/MessagingContext.sol";
import {Executor} from "src/messaging/Executor.sol";
import {ReceiverBase, ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {LzHubTransceiver} from "src/protocols/layerzero/LzHubTransceiver.sol";
import {Call, Calls} from "src/messaging/Call.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {Commitment, Scheme} from "src/messaging/Commitment.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

contract MockTransmitter is TransmitterBase {
    bytes32 public sentCommitment;
    bytes32 public sentChainKey;
    uint256 public sentCount;

    function initialize(address owner_, address transceiver_) external initializer {
        __TransmitterBase_init(owner_, transceiver_);
    }

    function _send(bytes32 chainKey, bytes32 commitment) internal override {
        sentChainKey = chainKey;
        sentCommitment = commitment;
        ++sentCount;
    }
}

/// @dev Records what the transmitter executed, and who executed it.
contract Recorder {
    uint256 public total;
    address public lastCaller;

    function hit(uint256 n) external {
        total += n;
        lastCaller = msg.sender;
    }
}

contract MockReceiver is ReceiverBase {
    uint256 public executedCount;

    function isAllowed(address, bytes4) public pure override returns (bool) {
        return true;
    }

    function _execute(Call[] memory calls) internal override {
        executedCount += calls.length;
        super._execute(calls);
    }
}

contract MockTransceiver is SpokeTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_, address receiverImplementation_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(receiverImplementation_, abi.encodePacked(address(0xB0BB1E)));
    }

    function _homeRoute() internal pure override returns (bytes memory) {
        return abi.encode(uint32(1));
    }

    /// @dev The mock supplies its own authority, exactly as a real protocol binding does.
    function _checkAdmin() internal view override {
        _checkOwner();
    }

    function inbound(address transmitter, Call[] calldata calls) external {
        this.bootstrapInbound(transmitter, bytes32(0), calls);
    }
}

contract SubmitTest is Test {
    MockTransmitter transmitter;

    address owner = address(0xA11CE);
    address transceiver = address(0x7BAD);
    uint256 constant SOURCE_CHAIN = 1;
    uint256 constant DEST_CHAIN = 8453;

    function setUp() public {
        vm.chainId(SOURCE_CHAIN);
        transmitter = new MockTransmitter();
        transmitter.initialize(owner, transceiver);
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

    /// @dev A bootstrap payload that pins a hash rather than running anything — the only
    ///      way an approval is left pending, now that the transceiver never commits.
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

    function hashOf(Call[] memory calls) public view returns (bytes32) {
        return Commitment.hashCalls(calls);
    }

    function test_commitSendsTheHashNotTheCalls() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        bytes32 commitment = transmitter.commit(DEST_CHAIN, calls);

        assertEq(transmitter.sentCommitment(), commitment);
        assertEq(transmitter.sentCount(), 1);
    }

    function test_commitIsOwnerGated() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xDEAD)
            )
        );
        transmitter.commit(DEST_CHAIN, _calls());
    }

    /// @dev A zero destination is refused; an empty array is not the transmitter's
    ///      business, because it hashes to a perfectly valid commitment that the receiver
    ///      will happily discharge by executing nothing.
    function test_commitRejectsAZeroDestination() public {
        vm.prank(owner);
        vm.expectRevert(OutboundBase.NoDestination.selector);
        transmitter.commit(uint256(0), _calls());

        vm.prank(owner);
        vm.expectRevert(OutboundBase.NoDestination.selector);
        transmitter.commit(uint256(0), keccak256("h"));
    }

    /// @dev The hash-only overload refuses a zero commitment: it is the sentinel for
    ///      "nothing pending" at the receiver, so bridging one would arrive as an
    ///      approval that reads as absent.
    function test_commitRejectsAZeroCommitment() public {
        vm.prank(owner);
        vm.expectRevert(OutboundBase.ZeroCommitmentOut.selector);
        transmitter.commit(DEST_CHAIN, bytes32(0));
    }

    /// @dev THE LOAD-BEARING PROPERTY. The transmitter runs on the source chain but the
    ///      commitment must be verifiable on the destination, where the receiver folds in
    ///      ITS chain id. Hashing with the local id would produce a commitment nothing on
    ///      the destination can ever match.
    function test_commitmentIsBuiltForTheDestinationNotTheSource() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        bytes32 commitment = transmitter.commit(DEST_CHAIN, calls);

        // What the source chain would produce for itself — must NOT be it.
        assertTrue(commitment != hashOf(calls), "must not use the source chain id");

        // What the destination will compute when it recomputes the hash.
        vm.chainId(DEST_CHAIN);
        assertEq(commitment, hashOf(calls), "must match the destination's hash");
    }

    /// @dev End to end: submit on the source, deliver to the transceiver on the
    ///      destination, finalize, and execute in the cloned receiver.
    function test_endToEndSourceToDestination() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        bytes32 commitment = transmitter.commit(DEST_CHAIN, calls);

        // ---- destination chain ----
        vm.chainId(DEST_CHAIN);
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockReceiver()));

        // The bootstrap arrives naming the OWNER, and the account is derived from it.
        address account = t.predictXSafeAccount(owner, bytes32(0));
        t.inbound(owner, _deferred(account, commitment));

        // Arrival manufactured the receiver and its payload pinned the hash. The array
        // never crossed; an unrelated relayer supplies it here and it is checked against
        // the bridged hash on this chain.
        MockReceiver r = MockReceiver(payable(account));
        assertEq(
            r.sourceTransmitter(), account, "its peer is its own address across chains"
        );
        assertEq(r.commitment(), commitment, "the receiver holds the bridged hash");

        vm.prank(address(0xF00D));
        r.finalize(calls);
        assertEq(
            r.executedCount(),
            3,
            "one self-call to commit on arrival, then the two-call payload"
        );
        assertEq(r.commitment(), bytes32(0), "nothing left pending");
    }

    /// @dev A payload built for one destination cannot be finalized on another.
    function test_payloadDoesNotCrossToAnotherDestination() public {
        Call[] memory calls = _calls();
        vm.prank(owner);
        bytes32 commitment = transmitter.commit(DEST_CHAIN, calls);

        vm.chainId(42161); // a different destination
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockReceiver()));
        address account = t.predictXSafeAccount(owner, bytes32(0));
        t.inbound(owner, _deferred(account, commitment));

        // Arrival cannot tell — it has no array. The mismatch surfaces when the payload
        // is spent, on the chain whose key does not match the one it was built for.
        MockReceiver r = MockReceiver(payable(account));
        vm.expectRevert(MessagingContext.CommitmentMismatch.selector);
        r.finalize(calls);
    }

    function test_commitmentForMatchesCommit() public {
        Call[] memory calls = _calls();
        bytes32 preview = transmitter.commitmentFor(DEST_CHAIN, calls);

        vm.prank(owner);
        assertEq(transmitter.commit(DEST_CHAIN, calls), preview);
    }

    /* =========================== the two commit forms ========================== */

    /// @dev THE DESTINATION CANNOT TELL THEM APART, AND THAT IS THE DESIGN. Both overloads
    ///      put the same thirty-two bytes on the wire; only this chain sees a difference.
    function test_bothOverloadsProduceTheSameWireMessage() public {
        Call[] memory calls = _calls();
        bytes32 hash = transmitter.commitmentFor(DEST_CHAIN, calls);

        vm.prank(owner);
        transmitter.commit(DEST_CHAIN, calls);
        (bytes32 keyA, bytes32 cA) =
            (transmitter.sentChainKey(), transmitter.sentCommitment());

        vm.prank(owner);
        transmitter.commit(DEST_CHAIN, hash);

        assertEq(transmitter.sentChainKey(), keyA);
        assertEq(transmitter.sentCommitment(), cA);
        assertEq(cA, hash);
    }

    /// @dev The private overload is the one whose payload never touches Ethereum. The
    ///      disclosing overload logs the array so an indexer can recover it; the hash-only
    /// @dev IT RUNS THE CALLS ITSELF. There is no receiver on this chain to run them in:
    ///      a transmitter and its receivers share one address across chains, and an
    ///      address holds one contract — so on Ethereum that address is the transmitter.
    ///      Both ends share `Executor`, so the loop and the policy are the same either way.
    function test_executeRunsLocallyInTheTransmitterItself() public {
        Recorder target = new Recorder();
        MockTransmitter local = new MockTransmitter();
        local.initialize(owner, address(0xBEEF));

        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(target), value: 0, data: abi.encodeCall(Recorder.hit, (1))});
        calls[1] = Call({target: address(target), value: 0, data: abi.encodeCall(Recorder.hit, (2))});

        vm.prank(owner);
        local.execute(calls);

        assertEq(target.total(), 3, "the transmitter executed them");
        assertEq(target.lastCaller(), address(local), "in its own context");
        assertEq(local.sentCount(), 0, "and nothing crossed a bridge");
    }

    function test_executeIsOwnerGatedAndRefusesAnEmptyArray() public {
        MockTransmitter local = new MockTransmitter();
        local.initialize(owner, address(0xBEEF));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        local.execute(_calls());

        vm.prank(owner);
        vm.expectRevert(Executor.EmptyExecution.selector);
        local.execute(new Call[](0));
    }

    /// @dev THE HUB CANNOT MAKE A RECEIVER AT ALL. Not gated — absent. Manufacturing lives
    ///      on the spoke, so there is no entry point on this side for a later change to
    ///      expose, and nothing that could collide with the transmitter's own address.
    function test_theHubHasNoReceiverMachinery() public {
        LzHubTransceiver hub = new LzHubTransceiver();
        hub.initialize(address(this), address(new MockTransmitter()));

        (bool a,) = address(hub).call(
            abi.encodeWithSignature("createReceiver(address)", address(this))
        );
        assertFalse(a, "no createReceiver(address)");

        (bool b,) = address(hub).call(
            abi.encodeWithSignature("bootstrapInbound(address,(address,uint256,bytes)[])",
                address(this), new Call[](0))
        );
        assertFalse(b, "no bootstrapInbound either");

        (bool c,) = address(hub).staticcall(
            abi.encodeWithSignature("receiverImplementation()")
        );
        assertFalse(c, "and no receiver implementation to point at one");
    }

    function test_executeIsOwnerGated() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xDEAD)
            )
        );
        transmitter.execute(_calls());
    }

    /* ================================ ownership =============================== */

    /// @dev A transmitter is per-user and its owner is the party that asked the factory
    ///      for it, so standard `Ownable` semantics are what a user expects — including
    ///      transfer, which a hand-rolled immutable `owner` could not offer.
    function test_ownershipIsTransferable() public {
        assertEq(transmitter.owner(), owner);

        address next = address(0xC0FFEE);
        vm.prank(owner);
        transmitter.transferOwnership(next);
        assertEq(transmitter.owner(), next);

        vm.prank(next);
        transmitter.commit(DEST_CHAIN, _calls());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner
            )
        );
        transmitter.commit(DEST_CHAIN, _calls());
    }

    /// @dev `Ownable` rejects the zero owner itself, so the transmitter does not need its
    ///      own check for it.
    function test_zeroOwnerIsRefusedByOwnable() public {
        MockTransmitter fresh = new MockTransmitter();
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)
            )
        );
        fresh.initialize(address(0), transceiver);
    }

    /// @dev THE FOOTGUN THAT COMES WITH `Ownable`. `submit` is the only way to use a
    ///      transmitter and it is owner-gated, so renouncing bricks the contract — and the
    ///      receiver on every destination with it, since the salt is this address.
    ///      Recorded rather than prevented; disabling it is a separate decision.
    function test_renouncingOwnershipBricksTheTransmitter() public {
        vm.prank(owner);
        transmitter.renounceOwnership();
        assertEq(transmitter.owner(), address(0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner
            )
        );
        transmitter.commit(DEST_CHAIN, _calls());
    }

    /* ============================ naming a destination ========================= */

    /// @dev The caller names Base as `8453` and nothing else. What reaches `_send` is the
    ///      chainKey, derived purely — no registry read, no stored table, no hash for a
    ///      signer to verify out of band.
    function test_plainChainIdBecomesAChainKeyWithNoLookup() public {
        vm.prank(owner);
        transmitter.commit(DEST_CHAIN, _calls());
        assertEq(transmitter.sentChainKey(), ChainKey.forEvm(DEST_CHAIN));
    }

    /// @dev The two entry points are the same operation with different spellings of the
    ///      destination, so they must agree wherever both apply.
    function test_commitAndCommitToAgreeOnAnEvmChain() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        bytes32 viaId = transmitter.commit(DEST_CHAIN, calls);
        bytes32 keyViaId = transmitter.sentChainKey();

        vm.prank(owner);
        bytes32 viaEnvelope =
            transmitter.commitTo(Erc7930.encodeEvmChain(DEST_CHAIN), Scheme.Keccak256, calls);

        assertEq(viaId, viaEnvelope);
        assertEq(keyViaId, transmitter.sentChainKey());
    }

    /// @dev The escape hatch that `uint256 destinationChainId` could not express at all:
    ///      a destination with no EVM chain id. Same commitment machinery, same salt on
    ///      the far side — only the spelling of the chain differs.
    function test_nonEvmDestinationIsNameableAtAll() public {
        bytes memory solChain =
            Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        Call[] memory calls = _calls();

        vm.prank(owner);
        bytes32 commitment = transmitter.commitTo(solChain, Scheme.Keccak256, calls);

        assertEq(transmitter.sentChainKey(), ChainKey.fromIdentifier(solChain));
        assertEq(commitment, transmitter.commitmentForChain(solChain, Scheme.Keccak256, calls));
        assertTrue(commitment != transmitter.commitmentFor(DEST_CHAIN, calls));
    }

    /// @dev An account envelope on the destination is accepted and reduced to its chain,
    ///      so a caller holding only a remote address does not have to strip it by hand.
    function test_commitToAcceptsAnAccountEnvelope() public {
        Call[] memory calls = _calls();
        vm.prank(owner);
        bytes32 viaAccount =
            transmitter.commitTo(Erc7930.encodeEvm(DEST_CHAIN, address(0xBEEF)), Scheme.Keccak256, calls);
        assertEq(viaAccount, transmitter.commitmentFor(DEST_CHAIN, calls));
    }

    /// @dev A non-canonical envelope must not become a destination nothing can reproduce.
    function test_commitToRejectsANonCanonicalEnvelope() public {
        // eip155 chain reference with a leading zero byte: a second encoding of chain 1.
        bytes memory bad = abi.encodePacked(
            uint16(1), ChainType.EIP155, uint8(2), hex"0001", uint8(0)
        );
        vm.prank(owner);
        vm.expectRevert(Erc7930.NonMinimalChainRef.selector);
        transmitter.commitTo(bad, Scheme.Keccak256, _calls());
    }

    function test_commitToIsOwnerGatedAndRejectsEmptyInputs() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(0xDEAD)
            )
        );
        transmitter.commitTo(Erc7930.encodeEvmChain(DEST_CHAIN), Scheme.Keccak256, _calls());

        vm.prank(owner);
        vm.expectRevert(OutboundBase.NoDestination.selector);
        transmitter.commitTo("", Scheme.Keccak256, _calls());

        vm.prank(owner);
        vm.expectRevert(OutboundBase.NoDestination.selector);
        transmitter.commitTo(bytes(""), keccak256("h"));
    }
}
