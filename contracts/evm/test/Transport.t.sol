// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {TransmitterBase, IAccountTransceiver} from
    "src/messaging/outbound/TransmitterBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {IERC7786GatewaySource} from
    "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import {ReceiverBase, ICommitFinalize} from "src/messaging/inbound/ReceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Commitment} from "src/messaging/Commitment.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainType} from "src/addressing/ChainType.sol";

/// @dev Records what reached the wire, so assertions are about the payload rather than a
///      provider's plumbing.
contract MockTransmitter is TransmitterBase, OwnableUpgradeable {
    bytes public sentRecipient;
    bytes public sentPayload;
    uint256 public sentCount;
    uint256 public sentValue;

    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }

    bytes[] public sentAttributes;
    address public sentRefund;

    function attributeCount() external view returns (uint256) {
        return sentAttributes.length;
    }

    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory attributes
    ) internal override returns (bytes32) {
        sentRecipient = recipient;
        sentPayload = payload;
        sentAttributes = attributes;
        sentValue = msg.value;
        sentRefund = _refundTo();
        ++sentCount;
        return bytes32(0);
    }

    /// @dev Priced per byte, which is what every real provider does, so a test can tell a
    ///      quote that read the payload from one that guessed at its size.
    uint256 public constant WEI_PER_BYTE = 7;

    function _quoteMessage(
        bytes memory,
        bytes memory payload,
        bytes[] memory attributes
    ) internal pure override returns (uint256) {
        return payload.length * WEI_PER_BYTE + attributes.length;
    }
}

/// @dev Exposes the inbound funnel a provider adapter would route into.
contract MockReceiver is ReceiverBase {
    function _isAuthorizedGateway(address) internal pure override returns (bool) {
        return true;
    }

    function deliver(bytes calldata payload) external {
        _onMessage(payload);
    }
}

/// @dev Records the bootstrap the transmitter asked for.
/// @dev A spoke-free stand-in for the hub: `TransceiverBase` with the two routing hooks
///      answered directly, so `bootstrap`'s provenance lookup succeeds without a registry.
contract MockTransceiver is TransceiverBase, OwnableUpgradeable {
    bytes public sentPayload;
    uint256 public bootCount;
    address public bootRefund;

    address private _impl;

    function initialize(address owner_, address impl) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        _impl = impl;
    }

    function _checkAdmin() internal view override {
        _checkOwner();
    }

    function _accountImplementation() internal view override returns (address) {
        return _impl;
    }

    function _accountInitializer(address, bytes32, Call[] memory)
        internal
        pure
        override
        returns (bytes memory)
    {
        return "";
    }

    /// @dev Stands in for the registry lookup a real hub's `_route` performs.
    function _counterpartOn(bytes32) internal pure override returns (bytes memory) {
        return abi.encodePacked(address(0xC0DE));
    }

    function _routeTo(bytes32) internal pure override returns (bytes memory) {
        return Erc7930.encodeEvmChain(8453);
    }

    function _handleInbound(bytes32, bytes calldata) internal override {}

    function _authenticateOrigin(bytes memory, bytes memory)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    /// @dev Records the raw payload. Which decoder applies is a property of the
    ///      DESTINATION, so the test picks it: a real spoke knows its own VM.
    bytes[] public sentAttributes;

    function attributeCount() external view returns (uint256) {
        return sentAttributes.length;
    }

    function _sendMessage(bytes memory, bytes memory payload, bytes[] memory attributes)
        internal
        override
        returns (bytes32)
    {
        sentPayload = payload;
        sentAttributes = attributes;
        bootRefund = _refundTo();
        ++bootCount;
        return bytes32(0);
    }

    /// @dev A different rate from the transmitter's, so a bootstrap quote that answered
    ///      from the account instead of delegating to here is visible in the number.
    uint256 public constant WEI_PER_BYTE = 11;

    function _quoteMessage(bytes memory, bytes memory payload, bytes[] memory)
        internal
        pure
        override
        returns (uint256)
    {
        return payload.length * WEI_PER_BYTE;
    }
}

contract Sink {
    uint256 public total;

    function hit(uint256 n) external payable {
        total += n;
    }
}

contract TransportTest is Test {
    MockTransmitter transmitter;
    MockTransceiver hub;
    Sink sink;

    address owner = address(0xA11CE);
    uint256 constant DEST = 8453;
    bytes32 constant SALT = keccak256("acct");

    /// @dev THE ACCOUNT SITS AT THE ADDRESS ITS TRANSCEIVER DERIVES FOR IT, because
    ///      `bootstrap` refuses any caller that is not that address. Sending now requires
    ///      the destination to have been bootstrapped, so the fixture performs the real
    ///      sequence rather than reaching into storage: stand the account up on DEST, then
    ///      send to it.
    function setUp() public {
        hub = new MockTransceiver();
        hub.initialize(address(this), address(new MockTransmitter()));

        address at = hub.predictCrossAccount(owner, SALT);
        vm.etch(at, address(new MockTransmitter()).code);
        transmitter = MockTransmitter(payable(at));
        transmitter.initialize(owner, address(hub), SALT);

        vm.prank(owner);
        transmitter.bootstrap(DEST, new Call[](0), NONE);

        sink = new Sink();
    }

    /// @dev Stand the account up on a non-EVM destination, the way a real deployment does:
    ///      bootstrap records `address(this)` as a presumption, and the owner then writes
    ///      the address the spoke actually reported home. Without the second step the
    ///      account has no reachable receiver there, which is the point of the correction.
    function _bootstrapTo(bytes memory identifier) internal {
        bytes[] memory none = new bytes[](0);
        vm.startPrank(owner);
        transmitter.bootstrapTo(identifier, none, none);
        transmitter.setDestinationReceiver(
            ChainKey.fromIdentifier(identifier), SOL_RECEIVER
        );
        vm.stopPrank();
    }

    /// @dev The account's address on the non-EVM destination, which is not derivable here.
    bytes constant SOL_RECEIVER = hex"0badc0de";

    bytes[] internal NONE;

    /// @dev A non-EVM recipient: the account's address there is not `address(this)` and is
    ///      not derivable here, which is why `sendMessage` only binds the address check on
    ///      eip155 destinations.
    function _solRecipient(bytes memory chainIdentifier)
        internal
        pure
        returns (bytes memory)
    {
        Erc7930.Interop memory io = Erc7930.parseStrict(chainIdentifier);
        return Erc7930.encode(io.chainType, io.chainRef, SOL_RECEIVER);
    }

    function _attrs() internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = hex"c0ffee";
    }

    /// @dev The account's own interoperable address on a chain, computed here rather than
    ///      read off the account, so it costs no external call and cannot swallow a prank.
    function _recip(uint256 chainId) internal view returns (bytes memory) {
        return Erc7930.encodeEvm(chainId, address(transmitter));
    }

    /// @dev One `sendMessage` now, so the tests spell the destination the way the ERC does:
    ///      an interoperable address the account builds for itself.
    function _sendCalls(uint256 chainId, Call[] memory calls) internal {
        transmitter.sendMessage(_recip(chainId), Payload.encodeCalls(calls), NONE);
    }

    function _calls() internal view returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = Call({target: address(sink), value: 0, data: abi.encodeCall(Sink.hit, (1))});
        calls[1] = Call({target: address(sink), value: 0, data: abi.encodeCall(Sink.hit, (2))});
    }

    /* ============================ path A: the payload ========================== */

    /// @dev THE WIRE CARRIES THE PAYLOAD, NOT A COMMITMENT. A call array is executed on
    ///      arrival; there is no digest and no second step unless the payload asks for one.
    function test_sendPutsTheCallArrayOnTheWire() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        _sendCalls(DEST, calls);

        assertEq(transmitter.sentCount(), 1);
        assertEq(ChainKey.fromIdentifier(transmitter.sentRecipient()), ChainKey.forEvm(DEST));
        assertEq(transmitter.sentPayload(), Payload.encodeCalls(calls));
    }

    /// @dev The fee rides with the send; the adapter reads `msg.value`.
    function test_sendForwardsTheBridgeFee() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        transmitter.sendMessage{value: 0.3 ether}(
            _recip(DEST), Payload.encodeCalls(_calls()), NONE
        );
        assertEq(transmitter.sentValue(), 0.3 ether);
    }

    /// @dev ERC-7786 REQUIRES `MessageSent`, AND IT SUPERSEDED OUR OWN EVENT. `Dispatched`
    ///      carried two hashes; this carries the recipient, the payload, the value, and the
    ///      attributes, so there is nothing left for a second event to add.
    function test_theSendEmitsTheStandardEvent() public {
        Call[] memory calls = _calls();

        vm.recordLogs();
        vm.prank(owner);
        _sendCalls(DEST, calls);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IERC7786GatewaySource.MessageSent.selector) continue;
            found = true;
            (bytes memory sender, bytes memory recipient, bytes memory payload,,) =
                abi.decode(logs[i].data, (bytes, bytes, bytes, uint256, bytes[]));
            assertEq(sender, Erc7930.encodeEvm(block.chainid, address(transmitter)));
            assertEq(recipient, _recip(DEST));
            assertEq(payload, Payload.encodeCalls(calls));
        }
        assertTrue(found, "MessageSent is mandatory for a gateway source");
    }

    /// @dev PATH B IS NOT A GATEWAY SOURCE, so it emits its own record, and names the pair
    ///      rather than hashing it: `(chainKey, owner, salt)` is what an account is, and
    ///      what the return leg's registry slot is keyed by.
    function test_bootstrapEmitsItsOwnRecord() public {
        (MockTransceiver t, MockTransmitter acct) = _account();

        vm.expectEmit(true, true, false, true, address(t));
        emit TransceiverBase.BootstrapSent(ChainKey.forEvm(DEST), owner, SALT);
        vm.prank(owner);
        acct.bootstrap(DEST, _calls(), new bytes[](0));
    }

    function test_providerDataTravelsPerSend() public {
        bytes memory opts = hex"0003010011010000000000000000000000000000ea60";

        vm.prank(owner);
        transmitter.sendMessage(_recip(DEST), Payload.encodeCalls(_calls()), _attrs());
        assertEq(transmitter.attributeCount(), 1);

        vm.prank(owner);
        _sendCalls(DEST, _calls());
        assertEq(transmitter.attributeCount(), 0, "no attributes is the default");
    }

    /// @dev Every entry point carries it, in both payload forms and on both paths.
    function test_everyEntryPointCarriesProviderData() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"01";

        _bootstrapTo(sol);

        vm.startPrank(owner);
        transmitter.sendMessage(_recip(DEST), Payload.encodeCalls(_calls()), _attrs());
        assertEq(transmitter.attributeCount(), 1, "typed destination");

        transmitter.sendMessage(_solRecipient(sol), Payload.encodeElements(elements), _attrs());
        assertEq(transmitter.attributeCount(), 1, "opaque destination");
        vm.stopPrank();

        (MockTransceiver t, MockTransmitter acct) = _account();
        vm.startPrank(owner);
        acct.bootstrap(DEST, _calls(), _attrs());
        assertEq(t.attributeCount(), 1, "bootstrap");

        acct.bootstrapTo(sol, elements, _attrs());
        assertEq(t.attributeCount(), 1, "bootstrapTo opaque");
        vm.stopPrank();
    }

    function test_sendIsOwnerGated() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        _sendCalls(DEST, _calls());
    }

    function test_sendRejectsChainZero() public {
        vm.prank(owner);
        vm.expectRevert(Erc7930.EmptyEnvelope.selector);
        _sendCalls(0, _calls());
    }

    /* ========================== path A: naming a chain ========================= */

    /// @dev A recipient carries its own chain, which is what collapsed six send overloads
    ///      into one. The chainKey is read back out of it rather than supplied alongside.
    function test_theRecipientNamesItsOwnChain() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        _sendCalls(DEST, calls);

        assertEq(ChainKey.fromIdentifier(transmitter.sentRecipient()), ChainKey.forEvm(DEST));
        assertEq(transmitter.sentPayload(), Payload.encodeCalls(calls));
    }

    /// @dev AN ACCOUNT'S PEER IS ITSELF, AND THE RECIPIENT IS CHECKED AGAINST THAT. Taking
    ///      the destination as an argument reopened something that used to be structural,
    ///      so a recipient naming anything else on an EVM chain is refused here rather than
    ///      arriving at a contract that is not this account's receiver.
    function test_aRecipientThatIsNotThisAccountIsRefused() public {
        bytes memory notUs = Erc7930.encodeEvm(DEST, address(0xBEEF));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.RecipientIsNotThisAccount.selector, notUs
            )
        );
        transmitter.sendMessage(notUs, Payload.encodeCalls(_calls()), NONE);
    }

    /// @dev THE CHECK BINDS ON EVM AND ONLY THERE, DELIBERATELY. On a non-EVM chain the
    ///      account is not a 20-byte address and is not derivable from here, so there is
    ///      nothing to compare against; the same is true on zkSync and Tron, which is what
    ///      `addressesDiverge` names from the other end. The recipient is the caller's to
    ///      get right there, and this test records that rather than hiding it.
    function test_aNonEvmRecipientIsCheckedAgainstTheRecordedReceiver() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        _bootstrapTo(sol);
        vm.prank(owner);
        transmitter.sendMessage(_solRecipient(sol), Payload.encodeElements(elements), NONE);

        assertEq(
            ChainKey.fromIdentifier(transmitter.sentRecipient()),
            ChainKey.fromIdentifier(sol)
        );
        assertEq(
            transmitter.sentRecipient(), _solRecipient(sol), "the recorded receiver, exactly"
        );
    }

    /// @dev THE CHECK IS UNIVERSAL NOW, WHICH IT COULD NOT BE WHILE IT WAS DERIVED. A
    ///      derived check had to be skipped wherever the account's address is not
    ///      `address(this)`, which left every non-EVM recipient unchecked. Comparing against
    ///      the recorded receiver binds on every chain, so the 32-byte pubkey of somebody
    ///      else's account is refused here rather than on arrival.
    function test_aNonEvmRecipientThatIsNotTheRecordedReceiverIsRefused() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        _bootstrapTo(sol);

        Erc7930.Interop memory io = Erc7930.parseStrict(sol);
        bytes memory impostor = Erc7930.encode(io.chainType, io.chainRef, hex"deadbeef");
        bytes memory payload = Payload.encodeElements(new bytes[](0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.RecipientIsNotThisAccount.selector, impostor
            )
        );
        transmitter.sendMessage(impostor, payload, NONE);
    }

    /// @dev THE PAIRING CHECK IS GONE, AND THIS IS WHERE THAT IS RECORDED. The six
    ///      overloads knew whether they held `Call[]` or `bytes[]`, so a typed payload
    ///      bound for a non-EVM chain and an opaque one bound for an EVM chain were both
    ///      refused before they cost a fee. `bytes payload` cannot be asked which it is, so
    ///      that pairing is now the caller's, and `payloadForCalls` / `payloadForElements`
    ///      exist so it is at least spelled once. This test asserts the loss so nobody
    ///      rediscovers it as a bug.
    function test_aMismatchedPayloadIsNoLongerRefusedLocally() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");

        _bootstrapTo(sol);
        vm.prank(owner);
        // `Call[]` bound for a chain that cannot decode it. This used to revert.
        transmitter.sendMessage(_solRecipient(sol), Payload.encodeCalls(_calls()), NONE);

        assertEq(transmitter.sentCount(), 1, "it left, and will fail on arrival instead");
    }

    /// @dev The envelope is still parsed strictly, so a non-canonical one cannot become a
    ///      chainKey nothing else reproduces.
    function test_aNonCanonicalRecipientIsRejected() public {
        bytes memory bad =
            abi.encodePacked(uint16(1), ChainType.EIP155, uint8(2), hex"0001", uint8(0));

        vm.prank(owner);
        vm.expectRevert(Erc7930.NonMinimalChainRef.selector);
        transmitter.sendMessage(bad, Payload.encodeCalls(_calls()), NONE);
    }

    /* ============================ path A: arrival ============================== */

    /// @dev END TO END. The payload the transmitter put on the wire is the payload the
    ///      receiver runs: no commitment, no second transaction.
    function test_aSentPayloadExecutesOnArrival() public {
        Call[] memory calls = _calls();

        vm.prank(owner);
        _sendCalls(DEST, calls);

        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));
        r.deliver(transmitter.sentPayload());

        assertEq(sink.total(), 3, "the array crossed and ran");
    }

    /// @dev DEFERRING IS THE SAME PATH. A payload whose one element calls the receiver's
    ///      own `commit` pins a hash instead of running anything; anyone supplies the
    ///      matching array later. Nothing on the wire distinguishes the two.
    function test_aDeferredPayloadPinsAHashInsteadOfRunning() public {
        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));

        Call[] memory later = _calls();
        bytes32 hash = Commitment.hashCalls(ChainKey.local(), later);

        Call[] memory deferred = new Call[](1);
        deferred[0] = transmitter.commitmentCall(address(r), hash);

        vm.prank(owner);
        _sendCalls(DEST, deferred);
        r.deliver(transmitter.sentPayload());

        assertEq(sink.total(), 0, "nothing ran on arrival");
        assertEq(r.commitment(), hash, "the payload pinned its own hash");

        vm.prank(address(0xF00D));
        r.finalize(later);
        assertEq(sink.total(), 3, "and anyone discharged it afterwards");
    }

    /* ================================= path B ================================== */

    /// @dev The transmitter states its owner and salt; the transceiver checks the pair
    ///      resolves back to the caller before anything crosses.
    function test_bootstrapStatesTheOwnerAndSalt() public {
        (MockTransceiver t, MockTransmitter acct) = _account();

        vm.prank(owner);
        acct.bootstrap(DEST, _calls(), new bytes[](0));

        (address gotOwner, bytes32 gotSalt,) = _decodeTyped(t.sentPayload());
        assertEq(t.bootCount(), 1);
        assertEq(gotOwner, owner);
        assertEq(gotSalt, SALT);
    }

    /// @dev An account sitting at the address `(owner, SALT)` derives to, which is what
    ///      the transceiver checks `msg.sender` against.
    function _decodeTyped(bytes memory m)
        internal
        pure
        returns (address, bytes32, Call[] memory)
    {
        return abi.decode(m, (address, bytes32, Call[]));
    }

    function _account() internal returns (MockTransceiver t, MockTransmitter acct) {
        t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        address at = t.predictCrossAccount(owner, SALT);
        vm.etch(at, address(new MockTransmitter()).code);
        acct = MockTransmitter(payable(at));
        acct.initialize(owner, address(t), SALT);
    }

    /// @dev A caller that is not the account `(owner, salt)` names cannot bootstrap it,
    ///      so the only account anyone can stand up is the one that answers to them.
    function test_bootstrapRefusesACallerThatIsNotTheAccount() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.NotTheAccount.selector, owner, SALT, address(this)
            )
        );
        t.bootstrap(ChainKey.forEvm(DEST), owner, SALT, _calls(), NONE);
    }

    /* ========================= path B: the two forms =========================== */

    /// @dev A NON-EVM CHAIN NEEDS ITS OWN BOOTSTRAP, because it needs its own payload
    ///      form. The account is stood up the same way; what differs is what it is handed.
    function test_bootstrapToCarriesOpaqueElementsToANonEvmChain() public {
        (MockTransceiver t, MockTransmitter acct) = _account();
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        vm.prank(owner);
        acct.bootstrapTo(sol, elements, new bytes[](0));

        (address gotOwner, bytes32 gotSalt, bytes[] memory got) =
            abi.decode(t.sentPayload(), (address, bytes32, bytes[]));
        assertEq(t.bootCount(), 1);
        assertEq(gotOwner, owner);
        assertEq(gotSalt, SALT);
        assertEq(got[0], hex"0102030405", "and the elements crossed untouched");
    }

    /// @dev THE PAIRING IS ENFORCED WHERE THE CHAIN TYPE IS KNOWN. Downstream everything
    ///      speaks chainKeys, which are hashes and cannot be asked what chain type they
    ///      came from, so this is the last point that could catch it.
    function test_typedBootstrapIsRefusedForANonEvmChain() public {
        (, MockTransmitter acct) = _account();
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");

        vm.prank(owner);
        vm.expectRevert(TransmitterBase.TypedPayloadToNonEvmDestination.selector);
        acct.bootstrapTo(sol, _calls(), new bytes[](0));
    }

    function test_opaqueBootstrapIsRefusedForAnEvmChain() public {
        (, MockTransmitter acct) = _account();
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"0102030405";

        bytes memory identifier = acct.chainIdentifierFor(DEST);

        vm.prank(owner);
        vm.expectRevert(TransmitterBase.OpaquePayloadToEvmDestination.selector);
        acct.bootstrapTo(identifier, elements, new bytes[](0));
    }

    /// @dev The envelope-taking typed form reaches an EVM chain, same as the chain-id one.
    function test_bootstrapToReachesAnEvmChainWithTypedCalls() public {
        (MockTransceiver t, MockTransmitter acct) = _account();

        bytes memory identifier = acct.chainIdentifierFor(DEST);

        vm.prank(owner);
        acct.bootstrapTo(identifier, _calls(), new bytes[](0));
        assertEq(t.bootCount(), 1);
    }

    /// @dev Both forms prove the caller is the account, not just the typed one.
    function test_theOpaqueBootstrapAlsoChecksTheCaller() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));
        bytes[] memory elements = new bytes[](1);
        elements[0] = hex"01";

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.NotTheAccount.selector, owner, SALT, address(this)
            )
        );
        t.bootstrapElements(ChainKey.forEvm(DEST), owner, SALT, elements, NONE);
    }

    /* =============================== the authority ============================= */

    /// @dev THE BASE HAS NO OWNERSHIP OF ITS OWN. It states the requirement (`_owner` and
    ///      `_checkOwner`), and the concrete contract answers from whatever authority it
    ///      already has. That is what lets an account inherit a provider SDK that brings
    ///      its own `Ownable` without two ownership systems living in one contract.
    function test_theBaseContributesNoOwnershipSurface() public view {
        // `TransmitterBase` declares no owner storage and no `owner()`. The one reachable
        // here comes from the concrete contract.
        assertEq(transmitter.owner(), owner);
    }

    /// @dev And its modifier is `onlyAccountOwner`, not `onlyOwner`, two base classes
    ///      declaring one modifier name would force every derived contract to override it,
    ///      which is the same collision the seam exists to avoid, one level down.
    function test_theSeamGatesEveryEntryPoint() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        _sendCalls(DEST, _calls());
        vm.expectRevert();
        transmitter.execute(_calls());
        vm.expectRevert();
        transmitter.bootstrap(DEST, _calls(), NONE);
        vm.stopPrank();
    }

    /* ================================= preview ================================= */

    /// @dev THE TRANSMITTER PREVIEWS EVM DESTINATIONS AND NOTHING ELSE. The portable
    ///      overload that took a `Scheme` is gone: a preview frozen with the account can
    ///      only answer for primitives that existed when the account was created, so
    ///      non-EVM destinations are previewed through `ChainRegistry.commitmentFor`
    ///      instead. What remains still refuses a shape it cannot answer for, rather than
    ///      guessing: a preview you can compute for a message you cannot send is a trap.
    function test_previewRefusesTheShapeItNoLongerAnswersFor() public {
        bytes memory sol = Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708");

        vm.expectRevert(TransmitterBase.TypedPayloadToNonEvmDestination.selector);
        transmitter.commitmentForChain(sol, _calls());
    }

    /// @dev The frozen surface is exactly one primitive wide, which is why it can never
    ///      go stale: every chain that executes `Call[]` hashes with keccak256, and
    ///      `ReceiverBase` enforces that same fold from bytecode frozen alongside it.
    function test_theEvmPreviewNeedsNoSchemeParameter() public view {
        Call[] memory calls = _sinkCallsFor(address(0));
        assertEq(
            transmitter.commitmentForChain(Erc7930.encodeEvmChain(block.chainid), calls),
            Commitment.hashCalls(ChainKey.local(), calls)
        );
    }

    /// @dev And the two legal shapes agree with what the receiver will recompute.
    function test_previewMatchesWhatTheReceiverRequires() public {
        Call[] memory calls = _sinkCallsFor(address(0));
        assertEq(
            transmitter.commitmentFor(block.chainid, calls),
            Commitment.hashCalls(ChainKey.local(), calls),
            "by chain id"
        );
        assertEq(
            transmitter.commitmentForChain(Erc7930.encodeEvmChain(block.chainid), calls),
            Commitment.hashCalls(ChainKey.local(), calls),
            "and by envelope"
        );
    }

    function _sinkCallsFor(address) internal view returns (Call[] memory) {
        return _calls();
    }

    /* ================================ the default ============================== */

    /// @dev A protocol that forgets to implement sending fails loudly on the first
    ///      message rather than reporting success for a payload that never left.
    function test_theDefaultSendReverts() public {
        BareTransmitter bare = _bareAccount();

        vm.prank(owner);
        vm.expectRevert(OutboundBase.SendNotImplemented.selector);
        bare.sendMessage(Erc7930.encodeEvm(DEST, address(bare)), Payload.encodeCalls(_calls()), NONE);
    }

    /// @dev A transmitter with no `_sendMessage`, standing at the address its transceiver
    ///      derives and already bootstrapped on DEST, so a send reaches the default body
    ///      rather than stopping at the bootstrap gate. Bootstrap itself never touches
    ///      `_sendMessage`: it is the transceiver that sends.
    function _bareAccount() internal returns (BareTransmitter bare) {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new BareTransmitter()));

        address at = t.predictCrossAccount(owner, bytes32(0));
        vm.etch(at, address(new BareTransmitter()).code);
        bare = BareTransmitter(payable(at));
        bare.initialize(owner, address(t), bytes32(0));

        vm.prank(owner);
        bare.bootstrap(DEST, new Call[](0), new bytes[](0));
    }

    /* ================================== quote ================================== */

    /// @dev THE SAME ARGUMENT AS `SendNotImplemented`, in the direction that matters more.
    ///      A quote that returned zero would be indistinguishable from a free message, and
    ///      the first thing anyone does with the answer is send exactly that much.
    function test_theDefaultQuoteReverts() public {
        BareTransmitter bare = _bareAccount();

        vm.expectRevert(OutboundBase.QuoteNotImplemented.selector);
        bare.quoteMessage(Erc7930.encodeEvm(DEST, address(bare)), Payload.encodeCalls(_calls()), NONE);
    }

    /// @dev THE QUOTE PRICES THE EXACT BYTES THE SEND PUTS ON THE WIRE. Asserted against
    ///      the payload the send actually recorded, so a quote built from a second,
    ///      drifting encoder fails here rather than in production.
    function test_quotePricesTheExactPayloadTheSendCarries() public {
        Call[] memory calls = _calls();

        uint256 quoted = transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(calls), NONE);

        vm.prank(owner);
        _sendCalls(DEST, calls);

        assertEq(
            quoted,
            transmitter.sentPayload().length * transmitter.WEI_PER_BYTE(),
            "priced the bytes that left"
        );
    }

    /// @dev A LONGER PAYLOAD COSTS MORE, which is the property a caller is relying on. A
    ///      quote that ignored its argument would return one number for both.
    function test_quoteTracksThePayloadSize() public view {
        uint256 small = transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(_oneCall()), NONE);
        uint256 large = transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(_calls()), NONE);
        assertGt(large, small, "two calls cost more than one");
    }

    /// @dev THE OPTIONS ARE MOST OF WHAT A QUOTE PRICES, so they are an argument to it.
    function test_quoteReflectsProviderData() public view {
        uint256 bare = transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(_calls()), NONE);
        uint256 withOptions = transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(_calls()), _attrs());
        assertGt(withOptions, bare);
    }

    /// @dev IT IS A VIEW, WHICH IS THE WHOLE POINT OF IT. The only way a quote is ever
    ///      used is an `eth_call` before the send, so a mutable one is not a quote.
    function test_quoteIsStaticallyCallable() public view {
        (bool ok, bytes memory ret) = address(transmitter).staticcall(
            abi.encodeCall(
                TransmitterBase.quoteMessage,
                (_recip(DEST), Payload.encodeCalls(_calls()), NONE)
            )
        );
        assertTrue(ok, "staticcall succeeded, so it wrote nothing");
        assertEq(abi.decode(ret, (uint256)), transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(_calls()), NONE));
    }

    /// @dev UNGATED, UNLIKE THE SEND IT PRICES. A signer reviewing a payload before the
    ///      owner submits it has to be able to call this.
    function test_quoteIsNotOwnerGated() public {
        vm.prank(address(0xDEAD));
        transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(_calls()), NONE);
    }

    /// @dev THE BOOTSTRAP QUOTE ASKS THE TRANSCEIVER, because the transceiver is what
    ///      sends path B. The two mocks price at different rates, so an answer computed
    ///      locally would not match.
    function test_bootstrapQuoteDelegatesToTheTransceiver() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        MockTransmitter acct = new MockTransmitter();
        acct.initialize(owner, address(t), SALT);

        Call[] memory calls = _calls();
        uint256 quoted = acct.quoteBootstrap(DEST, calls, NONE);

        assertEq(
            quoted,
            Envelope.encodeBootstrap(owner, SALT, calls).length * t.WEI_PER_BYTE(),
            "the transceiver priced its own envelope"
        );
    }

    /// @dev A QUOTE IS TAKEN BEFORE THE ACCOUNT IT PRICES EXISTS, so it cannot carry
    ///      `bootstrap`'s "you must BE the account" check. There is nothing to protect on
    ///      a view that spends nothing.
    function test_bootstrapQuoteDoesNotRequireTheCallerToBeTheAccount() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        vm.prank(address(0xDEAD));
        uint256 quoted = t.quoteBootstrap(
            ChainKey.forEvm(DEST), owner, SALT, _calls(), NONE
        );
        assertGt(quoted, 0);
    }

    /// @dev A RECEIVER HAS NO QUOTE SURFACE, AND THAT IS STRUCTURAL RATHER THAN GATED. It
    ///      does not inherit `OutboundBase` at all, so there is no seam to leave
    ///      unimplemented and no selector to reach: a receiver never sends, so pricing a
    ///      send from one would be pricing a message that has no path.
    function test_aReceiverExposesNoQuote() public {
        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));

        (bool ok,) = address(r).staticcall(
            abi.encodeWithSignature(
                "quoteMessage(bytes,bytes,bytes[])", DEST, _calls(), NONE
            )
        );
        assertFalse(ok, "no such function on a receiver");
    }

    /* ================================== refund ================================= */

    /// @dev THE PARTY WHO OVERPAID IS THE PARTY WHO GETS IT BACK. On path A the sender is
    ///      the owner, because `send` is owner-gated, so the remainder goes to the wallet
    ///      that signed and funded the message.
    function test_pathARefundsToTheOwner() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        transmitter.sendMessage{value: 0.3 ether}(
            _recip(DEST), Payload.encodeCalls(_calls()), NONE
        );
        assertEq(transmitter.sentRefund(), owner);
    }

    /// @dev ON PATH B IT IS THE ACCOUNT, AND NEVER THE TRANSCEIVER. This is the one this
    ///      has to get right: a shared transceiver refunding to itself would pool every
    ///      user's excess into infrastructure with no per-user way out. `bootstrap` refuses
    ///      any caller that is not the account, so the transceiver cannot be its own
    ///      caller and cannot be the refund target.
    function test_pathBRefundsToTheAccountNotTheTransceiver() public {
        (MockTransceiver t, MockTransmitter acct) = _account();

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        acct.bootstrap{value: 0.2 ether}(DEST, _calls(), new bytes[](0));

        assertEq(t.bootRefund(), address(acct), "the account that asked for the message");
        assertTrue(t.bootRefund() != address(t), "never the shared transceiver");
    }

    /// @dev A REFUND IS A PLAIN VALUE TRANSFER, so the account has to be able to take one.
    ///      Without `receive` on the transmitter the refund reverts and takes the bootstrap
    ///      with it, which is the one message that cannot be retried cheaply.
    function test_theAccountCanReceiveARefund() public {
        (, MockTransmitter acct) = _account();

        vm.deal(address(this), 1 ether);
        (bool ok,) = payable(address(acct)).call{value: 0.1 ether}("");
        assertTrue(ok, "the transmitter accepts a refunded fee");
        assertEq(address(acct).balance, 0.1 ether);
    }

    /* ============================== the bootstrap gate ========================= */

    /// @dev A SEND TO A CHAIN THIS ACCOUNT IS NOT ON HAS NOTHING TO ARRIVE AT. The peer
    ///      address holds no code there, so the payload fails on delivery with the fee
    ///      already spent. Refusing locally turns a paid-for failure into a free one.
    function test_sendToAnUnbootstrappedDestinationReverts() public {
        uint256 other = 42161;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.NotBootstrapped.selector, ChainKey.forEvm(other)
            )
        );
        _sendCalls(other, _calls());
    }

    /// @dev And it lifts for that destination once, and only for that destination.
    function test_bootstrappingOneDestinationDoesNotOpenAnother() public {
        uint256 other = 42161;
        assertTrue(transmitter.isBootstrappedOn(DEST));
        assertFalse(transmitter.isBootstrappedOn(other));

        vm.prank(owner);
        transmitter.bootstrap(other, new Call[](0), NONE);

        assertTrue(transmitter.isBootstrappedOn(other));
        vm.prank(owner);
        _sendCalls(other, _calls());
        assertEq(ChainKey.fromIdentifier(transmitter.sentRecipient()), ChainKey.forEvm(other));

        assertFalse(transmitter.isBootstrappedOn(10), "and nothing else moved");
    }

    /// @dev THE GATE IS ON THE CHAINKEY, NOT ON THE SPELLING OF IT. `send(8453)` and
    ///      `sendTo(<eip155:8453 envelope>)` name one destination, so bootstrapping through
    ///      either satisfies both.
    function test_theGateIsKeyedByChainNotByEntryPoint() public {
        vm.prank(owner);
        _sendCalls(DEST, _calls());
        assertEq(ChainKey.fromIdentifier(transmitter.sentRecipient()), ChainKey.forEvm(DEST));
    }

    /// @dev A SECOND BOOTSTRAP CANNOT DELIVER ITS PAYLOAD ANYWAY. `CrossProxy` arms exactly
    ///      once and the receiver's `initialize` is single-shot, so it would burn a fee to
    ///      revert on arrival.
    function test_rebootstrappingIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.AlreadyBootstrapped.selector, ChainKey.forEvm(DEST)
            )
        );
        transmitter.bootstrap(DEST, _calls(), NONE);
    }

    /// @dev Including through the envelope-taking form, which names the same chain.
    function test_rebootstrappingThroughTheOtherFormIsAlsoRefused() public {
        bytes memory identifier = transmitter.chainIdentifierFor(DEST);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.AlreadyBootstrapped.selector, ChainKey.forEvm(DEST)
            )
        );
        transmitter.bootstrapTo(identifier, _calls(), NONE);
    }

    /// @dev THE TWO BUILDERS NAME ONE CHAIN, which is what lets a caller pick an entry point
    ///      on ergonomics rather than on reach. `chainIdentifierFor` is `bootstrapTo`'s
    ///      argument and `recipientOn` is `sendMessage`'s, and the second is the first with
    ///      this account's address appended, so a destination reached by either spelling
    ///      resolves to the same chainKey.
    ///
    ///      It is a real check rather than a tautology because `Erc7930` is a library of
    ///      `internal` functions: off-chain callers cannot reach it, so these two are the
    ///      only way to build either value, and nothing else pins them to each other.
    function testFuzz_theTwoDestinationBuildersAgree(uint256 chainId) public view {
        vm.assume(chainId != 0);

        bytes memory identifier = transmitter.chainIdentifierFor(chainId);
        bytes memory recipient = transmitter.recipientOn(chainId);

        assertEq(ChainKey.fromIdentifier(identifier), ChainKey.forEvm(chainId));
        assertEq(ChainKey.fromIdentifier(recipient), ChainKey.fromIdentifier(identifier));

        Erc7930.Interop memory io = Erc7930.parseStrict(recipient);
        assertEq(io.addr, abi.encodePacked(address(transmitter)));
        assertEq(Erc7930.parseStrict(identifier).addr.length, 0);
    }

    /// @dev THE QUOTES CARRY THE SAME GATE, both ways round. A quote that succeeded where
    ///      its send would fail reports the operation ready when it is not.
    function test_theQuotesRevertWhereTheirSendsWould() public {
        uint256 other = 42161;

        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.NotBootstrapped.selector, ChainKey.forEvm(other)
            )
        );
        transmitter.quoteMessage(_recip(other), Payload.encodeCalls(_calls()), NONE);

        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.AlreadyBootstrapped.selector, ChainKey.forEvm(DEST)
            )
        );
        transmitter.quoteBootstrap(DEST, _calls(), NONE);
    }

    /// @dev And each is answerable in the state its own message belongs to: bootstrap is
    ///      quotable before, send is quotable after.
    function test_eachQuoteIsAnswerableWhenItsMessageIsSendable() public {
        uint256 other = 42161;

        assertGt(transmitter.quoteBootstrap(other, _calls(), NONE), 0, "before");
        assertGt(transmitter.quoteMessage(_recip(DEST), Payload.encodeCalls(_calls()), NONE), 0, "after");
    }

    /// @dev THE FLAG RECORDS A DISPATCH, NOT A DELIVERY, and it is set BEFORE the
    ///      transceiver is called so a re-entrant second bootstrap meets it. If the
    ///      dispatch reverts the whole transaction unwinds and the flag goes with it.
    function test_aFailedBootstrapLeavesNothingRecorded() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        address at = t.predictCrossAccount(owner, SALT);
        vm.etch(at, address(new MockTransmitter()).code);
        MockTransmitter acct = MockTransmitter(payable(at));
        acct.initialize(owner, address(t), SALT);

        // The transceiver has no code path that reverts, so revert the whole call from
        // outside it: an unowned caller cannot bootstrap.
        vm.expectRevert();
        acct.bootstrap(DEST, new Call[](0), new bytes[](0));

        assertFalse(acct.isBootstrappedOn(DEST), "nothing recorded");
    }

    /// @dev `execute` is local, so the gate does not apply: there is no destination and no
    ///      bridge in that path.
    function test_localExecuteIsNotGated() public {
        vm.prank(owner);
        transmitter.execute(_calls());
        assertEq(sink.total(), 3);
    }

    /* ============================ the account's view =========================== */

    /// @dev AN ACCOUNT HOLDS ONE TRANSCEIVER ADDRESS AND ONE INTERFACE OVER IT. `routeTo`
    ///      joins bootstrap and the quotes on `IAccountTransceiver` rather than living on a
    ///      second type, and it answers for a destination the account has not bootstrapped,
    ///      which is the one thing its own table cannot: that table is written by
    ///      `bootstrap`, so before the first message to a chain it holds nothing.
    function test_theAccountInterfaceResolvesARoute() public {
        MockTransceiver t = new MockTransceiver();
        t.initialize(address(this), address(new MockTransmitter()));

        assertEq(
            IAccountTransceiver(address(t)).routeTo(ChainKey.forEvm(DEST)),
            Erc7930.encodeEvmChain(8453),
            "the provider's own name for the chain, opaque"
        );
    }

    /// @dev AN ACCOUNT RECORDS ITS OWN DESTINATIONS RATHER THAN BEING CONFIGURED WITH THEM,
    ///      which is the property the old "an account holds no route table" test was really
    ///      protecting. It does hold one now, but every row is written by `bootstrap` from
    ///      the identifier the caller already supplied: there is no admin surface on the
    ///      account, nothing a msig has to migrate when a destination is added, and no
    ///      provider vocabulary in it.
    function test_theAccountRecordsItsDestinationsRatherThanBeingConfigured() public view {
        assertEq(
            transmitter.routeTo(ChainKey.forEvm(DEST)),
            transmitter.chainIdentifierFor(DEST),
            "the identifier bootstrap was given, stored verbatim"
        );
        assertTrue(transmitter.hasRoute(ChainKey.forEvm(DEST)));
        assertFalse(
            transmitter.hasRoute(ChainKey.forEvm(42161)), "and nothing it was not asked for"
        );
    }

    function _oneCall() internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] =
            Call({target: address(sink), value: 0, data: abi.encodeCall(Sink.hit, (1))});
    }
}

/// @dev No `_sendMessage` override, to exercise the default.
contract BareTransmitter is TransmitterBase, OwnableUpgradeable {
    function initialize(address owner_, address transceiver_, bytes32 salt_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransmitterBase_init(owner_, transceiver_, salt_);
    }

    function _owner() internal view override returns (address) {
        return owner();
    }

    function _checkOwner() internal view override(TransmitterBase, OwnableUpgradeable) {
        OwnableUpgradeable._checkOwner();
    }
}

/// @dev zkSync and Tron are `eip155` chains whose CREATE2 formula differs, so an account's
///      address there is NOT the one it occupies at home. That is the case the whole
///      counterpart table exists for: a derived peer is wrong on exactly these chains, and
///      being `eip155` they cannot be excluded by chain type the way a non-EVM chain is.
contract DivergingDestinationTest is Test {
    MockTransmitter transmitter;
    MockTransceiver hub;

    address owner = address(0xA11CE);
    uint256 constant ZKSYNC = 324;
    /// Where the spoke actually created the receiver, reported home under
    /// `addressesDiverge` and readable from the registry's `receiverSlot`.
    bytes constant DIVERGED = hex"00000000000000000000000000000000deadbeef";

    function setUp() public {
        hub = new MockTransceiver();
        hub.initialize(address(this), address(new MockTransmitter()));
        address at = hub.predictCrossAccount(owner, bytes32(0));
        vm.etch(at, address(new MockTransmitter()).code);
        transmitter = MockTransmitter(payable(at));
        transmitter.initialize(owner, address(hub), bytes32(0));

        vm.prank(owner);
        transmitter.bootstrap(ZKSYNC, new Call[](0), new bytes[](0));
    }

    /// @dev BOOTSTRAP RECORDS A PRESUMPTION, and on a diverging chain it is wrong. Refusing
    ///      the send is correct: the address holds no receiver, so the message would be paid
    ///      for and fail on arrival.
    function test_beforeCorrectionTheDivergedReceiverIsUnreachable() public {
        bytes memory recipient = Erc7930.encodeEvm(ZKSYNC, address(bytes20(DIVERGED)));
        bytes memory payload = transmitter.payloadForCalls(new Call[](0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.RecipientIsNotThisAccount.selector, recipient
            )
        );
        transmitter.sendMessage(recipient, payload, new bytes[](0));
    }

    /// @dev AND AFTER IT, THE REAL RECEIVER IS ADDRESSABLE. This is what the old derived
    ///      check made impossible: it enforced `address(this)` on every `eip155` chain, so
    ///      the only accepted recipient on zkSync was an address holding no code and the
    ///      real one could never be named.
    function test_afterCorrectionTheDivergedReceiverIsReachable() public {
        bytes32 key = ChainKey.forEvm(ZKSYNC);
        bytes memory recipient = Erc7930.encodeEvm(ZKSYNC, address(bytes20(DIVERGED)));
        bytes memory payload = transmitter.payloadForCalls(new Call[](0));

        vm.startPrank(owner);
        transmitter.setDestinationReceiver(key, DIVERGED);
        transmitter.sendMessage(recipient, payload, new bytes[](0));
        vm.stopPrank();

        assertEq(transmitter.sentRecipient(), recipient, "addressed to the real receiver");
        assertEq(transmitter.destinationReceiverOn(key), DIVERGED);
    }

    /// @dev The home address stops being accepted once the real one is recorded, so the two
    ///      cannot both be live and a stale caller fails loudly.
    function test_correctionRevokesTheHomeAddress() public {
        bytes32 key = ChainKey.forEvm(ZKSYNC);
        bytes memory stale = transmitter.recipientOn(ZKSYNC);
        bytes memory payload = transmitter.payloadForCalls(new Call[](0));

        vm.startPrank(owner);
        transmitter.setDestinationReceiver(key, DIVERGED);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.RecipientIsNotThisAccount.selector, stale
            )
        );
        transmitter.sendMessage(stale, payload, new bytes[](0));
        vm.stopPrank();
    }

    /// @dev A receiver that does not share its transmitter's address still authenticates it,
    ///      because it compares against the stored `sourceTransmitter` rather than its own
    ///      address. This is the inbound mirror of the three above.
    function test_aDivergedReceiverAuthenticatesItsOwnTransmitter() public {
        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));
        assertTrue(address(r) != address(transmitter), "addresses diverge, by construction");

        bytes memory sender = Erc7930.encodeEvm(1, address(transmitter));
        r.receiveMessage(bytes32(0), sender, Payload.encodeCalls(new Call[](0)));
    }

    /// @dev And still refuses anyone else, including a sender claiming its own address.
    function test_aDivergedReceiverRefusesAnImpostor() public {
        MockReceiver r = new MockReceiver();
        r.initialize(address(transmitter), new Call[](0));

        bytes memory impostor = Erc7930.encodeEvm(1, address(r));
        bytes memory payload = Payload.encodeCalls(new Call[](0));

        vm.expectRevert(
            abi.encodeWithSelector(ReceiverBase.SenderIsNotThisAccount.selector, impostor)
        );
        r.receiveMessage(bytes32(0), impostor, payload);
    }
}
