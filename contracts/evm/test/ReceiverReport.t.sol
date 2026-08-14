// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "test/Deployment.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Roles} from "src/messaging/Roles.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Executor} from "src/messaging/Executor.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ICancel, ICommitFinalize} from "src/messaging/inbound/InboundBase.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";

/// @dev A transmitter with a send that does nothing, so a bootstrap can be dispatched
///      without a provider behind it.
contract Transmitter is TransmitterBase, OwnableUpgradeable {
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

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory)
        internal
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

contract Receiver is ReceiverBase {
    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev A spoke whose divergence flag is a constructor-time choice, so both arms can be
///      exercised against otherwise identical contracts.
contract ReportingSpoke is SpokeTransceiverBase {
    bytes public sentRecipient;
    bytes public sentPayload;
    uint256 public sentValue;
    uint256 public sentCount;

    /// @dev Off by default: a report on a parity chain is the case that must NOT happen,
    ///      so making it the default means a test asserting silence cannot pass by
    ///      forgetting to configure something.
    bool public sendReverts;

    function initialize(address owner_, address impl, bool addressesDiverge_)
        external
        initializer
    {
        __SpokeTransceiverBase_init(
            Deploy.bare(),
            impl,
            ChainKey.forEvm(1),
            Erc7930.encodeEvmChain(1),
            abi.encodePacked(address(0xB0BB1E)),
            addressesDiverge_
        );
    }

    /// @dev Stands in for a dry spoke: a provider whose fee cannot be paid reverts here.
    function setSendReverts(bool v) external {
        sendReverts = v;
    }

    error NoBalanceForTheReport();

    /// @dev A PROVIDER THAT CHARGES, so the report is priced rather than handed the whole
    ///      balance. `_reportReceiver` quotes this and sends exactly it.
    uint256 public reportFee;

    function setReportFee(uint256 v) external {
        reportFee = v;
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory)
        internal
        view
        override
        returns (uint256)
    {
        return reportFee;
    }

    function _sendMessage(
        bytes memory recipient,
        bytes memory payload,
        bytes[] memory,
        uint256 value
    )
        internal
        override
        returns (bytes32)
    {
        if (sendReverts) revert NoBalanceForTheReport();
        // What a real binding does with the value it was handed: refuse if the balance
        // cannot cover the fee the quote named.
        if (value > address(this).balance) revert NoBalanceForTheReport();
        sentRecipient = recipient;
        sentPayload = payload;
        sentValue = value;
        ++sentCount;
        return bytes32(0);
    }

    /// @dev Stands in for `_onInbound`, which reaches `bootstrapInbound` by self-call
    ///      after authenticating the origin.
    function inbound(address owner, bytes32 salt, Call[] calldata calls) external {
        this.bootstrapInbound(owner, salt, calls);
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

/// @notice The return leg: which chains report where their receiver landed, and which
///         stay silent because the hub already knows.
contract ReceiverReportTest is Test {
    Receiver impl;
    address owner = address(0xA11CE);
    address msig = address(0x5165);
    bytes32 constant SALT = keccak256("acct");

    function setUp() public {
        impl = new Receiver();
    }

    function _spoke(bool diverges) internal returns (ReportingSpoke s) {
        s = new ReportingSpoke();
        s.initialize(msig, address(impl), diverges);
    }

    /* ============================== the parity case ============================ */

    /// @dev THE COMMON CASE SENDS NOTHING. On a chain sharing Ethereum's CREATE2 formula
    ///      the hub computed this address before the first message ever left, so a report
    ///      would spend a message to restate a derivation it already holds.
    function test_aParityChainReportsNothing() public {
        ReportingSpoke s = _spoke(false);

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentCount(), 0, "no message left the spoke");
        assertTrue(
            s.predictCrossAccount(owner, SALT).code.length != 0, "but the account exists"
        );
    }

    /// @dev And it would be a DOWNGRADE, not merely waste. A derivation is `Derived`;
    ///      anything arriving over a bridge is graded `Attested`, which is strictly less.
    function test_theParityChainStillCreatesTheAccountAtThePredictedAddress() public {
        ReportingSpoke s = _spoke(false);
        address predicted = s.predictCrossAccount(owner, SALT);

        s.inbound(owner, SALT, new Call[](0));

        assertEq(Receiver(payable(predicted)).sourceTransmitter(), predicted);
    }

    /* ============================ the diverging case =========================== */

    /// @dev WHERE THE HUB CANNOT DERIVE IT, THE SPOKE SAYS SO. One message per account
    ///      created, addressed home.
    function test_aDivergingChainReportsTheReceiver() public {
        ReportingSpoke s = _spoke(true);
        address created = s.predictCrossAccount(owner, SALT);

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentCount(), 1, "one report");
        assertEq(
            ChainKey.fromIdentifier(s.sentRecipient()),
            s.homeChainKey(),
            "addressed home"
        );

        (address gotOwner, bytes32 gotSalt, bytes memory interop) =
            abi.decode(s.sentPayload(), (address, bytes32, bytes));
        assertEq(gotOwner, owner);
        assertEq(gotSalt, SALT);
        assertEq(
            interop,
            Erc7930.encodeEvm(block.chainid, created),
            "canonical ERC-7930 for the receiver on THIS chain"
        );
    }

    /// @dev IT NAMES THE PAIR, NOT THE ADDRESS ALONE. `(owner, salt)` is what an account
    ///      is; the hub derives the registry slot from it plus the origin it already
    ///      authenticated, which is why no request id is needed.
    function test_theReportCarriesThePairTheHubKeysOn() public {
        ReportingSpoke s = _spoke(true);

        s.inbound(owner, SALT, new Call[](0));
        (address a, bytes32 b,) =
            abi.decode(s.sentPayload(), (address, bytes32, bytes));

        assertEq(
            keccak256(s.sentPayload()),
            keccak256(
                Envelope.encodeReceiverReport(
                    a, b, Erc7930.encodeEvm(block.chainid, s.predictCrossAccount(a, b))
                )
            )
        );
    }

    /// @dev Two accounts, two reports, each naming its own pair.
    function test_eachAccountReportsItself() public {
        ReportingSpoke s = _spoke(true);

        s.inbound(owner, SALT, new Call[](0));
        s.inbound(owner, keccak256("second"), new Call[](0));

        assertEq(s.sentCount(), 2);
        (, bytes32 gotSalt,) = abi.decode(s.sentPayload(), (address, bytes32, bytes));
        assertEq(gotSalt, keccak256("second"), "the most recent one");
    }

    /* ================================= funding ================================= */

    /// @dev A DRY SPOKE TAKES THE WHOLE BOOTSTRAP DOWN, AND THAT IS THE CORRECT SHAPE.
    ///      The send is nested inside a delivery callback where `msg.value` is zero, so it
    ///      is paid from this contract's balance. Swallowing the failure would create an
    ///      account here that the home chain could never address: `CrossProxy` arms
    ///      exactly once and `initialize` is single-shot, so there is no second bootstrap
    ///      to carry a second report. All or nothing is the only recoverable outcome.
    function test_aFailedReportRevertsTheAccountCreation() public {
        ReportingSpoke s = _spoke(true);
        s.setSendReverts(true);

        vm.expectRevert(ReportingSpoke.NoBalanceForTheReport.selector);
        s.inbound(owner, SALT, new Call[](0));

        assertEq(
            s.predictCrossAccount(owner, SALT).code.length,
            0,
            "no account, so the bootstrap can be retried once funded"
        );
    }

    /// @notice The report is priced, not handed the balance.
    ///
    /// @dev IT USED TO SEND `address(this).balance`, which told the provider "take what you
    ///      like" and left a spoke unable to hold a float for anything else. Quoting first
    ///      means the provider charges what it charges and the rest stays put, which is what
    ///      lets one spoke fund many reports.
    function test_theReportSendsTheQuotedFeeAndNotTheBalance() public {
        ReportingSpoke s = _spoke(true);
        s.setReportFee(0.1 ether);
        vm.deal(address(s), 5 ether);

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentValue(), 0.1 ether, "exactly the quote");
        assertEq(address(s).balance, 5 ether, "and the float is untouched by the accounting");
    }

    /// @dev THE HELPER IS WHAT MAKES THE QUOTE REACHABLE. The payload is built inside a
    ///      delivery callback from the envelope layout, this chain's id, and the address the
    ///      account will land at; without a view producing those exact bytes, anyone funding
    ///      a spoke would be pricing a guess.
    function test_theReportPayloadHelperMatchesWhatIsSent() public {
        ReportingSpoke s = _spoke(true);
        vm.deal(address(s), 1 ether);

        address receiver = s.predictCrossAccount(owner, SALT);
        bytes memory expected = s.reportPayload(owner, SALT, receiver);

        // Priced through the surface `OutboundBase` now exposes, before anything is sent.
        uint256 quoted = s.quoteMessage(s.homeTransceiver(), expected, new bytes[](0));

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentPayload(), expected, "the helper builds the bytes that went");
        assertEq(s.sentValue(), quoted, "and they were sent at the price it quoted");
    }

    /// @dev And the retry works, which is the property the revert buys.
    function test_theBootstrapSucceedsOnceTheSpokeIsFunded() public {
        ReportingSpoke s = _spoke(true);
        s.setSendReverts(true);

        vm.expectRevert(ReportingSpoke.NoBalanceForTheReport.selector);
        s.inbound(owner, SALT, new Call[](0));

        s.setSendReverts(false);
        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentCount(), 1);
        assertTrue(s.predictCrossAccount(owner, SALT).code.length != 0);
    }

    /// @dev A parity chain never touches the send path at all, so it needs no balance and
    ///      cannot fail this way. That is the point of gating on the flag rather than
    ///      reporting everywhere and tolerating failures.
    function test_aParityChainNeedsNoBalance() public {
        ReportingSpoke s = _spoke(false);
        s.setSendReverts(true);

        s.inbound(owner, SALT, new Call[](0));

        assertTrue(s.predictCrossAccount(owner, SALT).code.length != 0);
    }

    /* ================================ the flag ================================= */

    /// @dev WRITE-ONCE, LIKE EVERY OTHER HOME VALUE ON A SPOKE. Flipping it later would
    ///      either start restating derivations the hub holds, or stop reporting addresses
    ///      it cannot derive, and the second is silent.
    function test_theFlagHasNoSetter() public {
        ReportingSpoke s = _spoke(false);

        (bool ok,) = address(s).call(
            abi.encodeWithSignature("setAddressesDiverge(bool)", true)
        );
        assertFalse(ok, "no such function");
        assertFalse(s.addressesDiverge());
    }

    function test_theFlagIsReadable() public {
        assertFalse(_spoke(false).addressesDiverge());
        assertTrue(_spoke(true).addressesDiverge());
    }

    /// @dev It is single-shot along with the rest of the initializer, so a second call
    ///      cannot change it.
    function test_reinitializingIsRefused() public {
        ReportingSpoke s = _spoke(false);

        vm.expectRevert();
        s.initialize(msig, address(impl), true);
        assertFalse(s.addressesDiverge());
    }
}


/* ========================================================================== */

/// @dev The home side: a real hub, a real registry, and nothing hand-built. Everything
///      below feeds the spoke's ACTUAL wire bytes into it.
contract Hub is HubTransceiverBase {
    function initialize(
        address owner_,
        address treasury_,
        address transmitterImplementation_
    ) external initializer {
        __HubTransceiverBase_init(
            owner_,
            Deployment({treasury: treasury_, gateways: new address[](0)}),
            transmitterImplementation_
        );
    }

    /// @dev Records what the base said it may spend, which is `msg.value` minus the fee.
    uint256 public lastSendValue;

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256 value)
        internal
        override
        returns (bytes32)
    {
        lastSendValue = value;
        return bytes32(0);
    }

    /// @dev Priced per byte, like every real provider, so the surcharge is visibly ON TOP
    ///      of a message price rather than standing in for one.
    function _quoteMessage(bytes memory, bytes memory payload, bytes[] memory)
        internal
        pure
        override
        returns (uint256)
    {
        return payload.length;
    }

    /// @dev Stands in for a provider adapter: translates a callback into the three
    ///      arguments `_onInbound` takes, and does nothing else.
    function arrive(bytes memory route, bytes memory sender, bytes calldata message)
        external
    {
        _onInbound(route, sender, message);
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

/// @notice The report crossing BOTH halves. Every other test of this path builds the
///         message by hand on one side or the other, which cannot catch the two sides
///         drifting apart: an encoder change on the spoke and a decoder that still expects
///         the old shape would leave both files green.
contract ReceiverReportRoundTripTest is Test {
    Hub hub;
    ReportingSpoke spoke;
    ChainRegistry registry;
    Transmitter account;

    address msig = address(0x5165);
    address owner = address(0xA11CE);
    bytes32 constant SALT = keccak256("acct");
    bytes32 provider;
    bytes32 spokeKey;

    /// @dev A chain the hub CANNOT derive addresses on, because that is the only kind that
    ///      may report. It is `eip155` and capped below `Derived`, which is exactly the
    ///      zkSync and Tron shape: nothing about the chain type separates it from Base, and
    ///      the cap is what records that its CREATE2 formula differs.
    uint256 constant SPOKE_CHAIN = 8453;
    uint32 constant SPOKE_EID = 30184;

    function setUp() public {
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (msig))
                )
            )
        );

        hub = new Hub();
        // The msig owns the hub AND is the treasury it may pay: one address here, two
        // facts, and the tests below separate them.
        hub.initialize(msig, msig, address(new Transmitter()));
        spoke = new ReportingSpoke();
        spoke.initialize(msig, address(new Receiver()), true);

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(hub));
        hub.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
        spokeKey = registry.addChainKey(Erc7930.encodeEvmChain(SPOKE_CHAIN));
        // Graded `Attested`: the hub cannot recompute an address there, which is both why
        // a report is needed and why the report is worth only the bridge that carried it.
        registry.setProvenance(spokeKey, Provenance.Attested);
        hub.setCounterpart(spokeKey, Erc7930.encodeEvm(SPOKE_CHAIN, address(spoke)));
        hub.setRoute(spokeKey, Erc7930.encodeEvmChain(SPOKE_CHAIN));
        vm.stopPrank();

        // The account the report is ABOUT. It has to exist and to have been stood up on the
        // spoke, because that is what gives it a counterpart slot for that chain.
        vm.startPrank(owner);
        account = Transmitter(payable(hub.createTransmitter(SALT)));
        account.bootstrap(SPOKE_CHAIN, new Call[](0), new bytes[](0));
        vm.stopPrank();
    }

    function _report() internal returns (bytes memory produced) {
        vm.chainId(SPOKE_CHAIN);
        spoke.inbound(owner, SALT, new Call[](0));
        produced = spoke.sentPayload();
        vm.chainId(1);
    }

    /* ======================== bootstrapped vs reachable ======================== */

    /// @notice REGRESSION: a chain that reports is NOT sendable until it has reported.
    ///
    /// @dev THE GAP THIS CLOSES. `bootstrap` used to record a counterpart at dispatch on every
    ///      chain, and on a reporting chain that value was a guess: `address(this)`, which is
    ///      exactly what `recipientOn` builds. So a send made before the report landed matched
    ///      the guess, passed the recipient check, and was addressed at an address holding no
    ///      receiver — paid for, and undeliverable. Now nothing is recorded until the report
    ///      arrives.
    function test_aReportingChainIsNotSendableUntilItHasReported() public {
        assertTrue(account.isBootstrapped(spokeKey), "the bootstrap went");
        assertFalse(account.isReachable(spokeKey), "but the receiver is not known yet");

        // Both hoisted: an external call inside the pranked expression consumes the prank,
        // and one inside `expectRevert`'s next call would be the call it measures.
        bytes memory recipient = account.recipientOn(SPOKE_CHAIN);
        bytes memory payload = account.payloadForCalls(new Call[](0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(TransmitterBase.NotBootstrapped.selector, spokeKey)
        );
        account.sendMessage(recipient, payload, new bytes[](0));

        // The report lands, and only then does the destination become sendable — at the
        // address the spoke actually created, not at the guess.
        bytes memory produced = _report();
        address created = spoke.predictCrossAccount(owner, SALT);
        hub.arrive(
            Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), produced
        );

        assertTrue(account.isReachable(spokeKey), "now it is");
        assertEq(account.counterpartOn(spokeKey), abi.encodePacked(created));
    }

    /// @dev AND A SECOND BOOTSTRAP IS STILL REFUSED IN THE MEANTIME. The dispatch record is
    ///      what prevents that, which is why it had to become a fact of its own rather than
    ///      being read off the counterpart table.
    function test_aSecondBootstrapIsRefusedWhileTheReportIsOutstanding() public {
        assertFalse(account.isReachable(spokeKey));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(TransmitterBase.AlreadyBootstrapped.selector, spokeKey)
        );
        account.bootstrap(SPOKE_CHAIN, new Call[](0), new bytes[](0));
    }

    /* ===================== what an executed payload may call ==================== */

    /// @notice REGRESSION: a spoke on one chain cannot report an address on another, and the
    ///         `Call[]` path is not a way around that.
    ///
    /// @dev THE ESCALATION THIS CLOSES. `onDestinationReceiver` is self-call gated and takes
    ///      its `chainKey` as an argument, which the envelope path fills from
    ///      `_authenticateOrigin`. Once a transceiver executed arrays, an authenticated spoke
    ///      could send a payload that called it directly with ANY chainKey, pinning an
    ///      account's receiver on a chain it has nothing to do with — write-once, and so
    ///      unrecoverable. `test_aChainCannotReportAnAddressOnAnotherChain` covers the
    ///      envelope path and passed throughout; only this covers the way around it.
    function test_anExecutedPayloadCannotReachOnDestinationReceiver() public {
        uint256 OTHER = 999;
        vm.startPrank(msig);
        bytes32 otherKey = registry.addChainKey(Erc7930.encodeEvmChain(OTHER));
        registry.setProvenance(otherKey, Provenance.Attested);
        hub.setCounterpart(otherKey, Erc7930.encodeEvm(OTHER, address(0xDEAD)));
        hub.setRoute(otherKey, Erc7930.encodeEvmChain(OTHER));
        vm.stopPrank();

        vm.prank(owner);
        account.bootstrap(OTHER, new Call[](0), new bytes[](0));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(hub),
            value: 0,
            data: abi.encodeCall(
                HubTransceiverBase.onDestinationReceiver,
                (otherKey, owner, SALT, Erc7930.encodeEvm(OTHER, address(0xBADBAD)))
            )
        });

        // Refused before the call is made, not by the callee: the allowlist is the check.
        vm.expectRevert(
            abi.encodeWithSelector(
                Executor.SelectorNotAllowed.selector,
                address(hub),
                HubTransceiverBase.onDestinationReceiver.selector
            )
        );
        hub.receiveMessage(
            bytes32(0),
            Erc7930.encodeEvm(SPOKE_CHAIN, address(spoke)),
            Payload.encodeCalls(calls)
        );

        assertFalse(
            account.isReachable(otherKey),
            "nothing was recorded, so no chain got to speak for another"
        );
    }

    /// @notice REGRESSION: an executed payload cannot move the transceiver's balance.
    /// @dev A `Call` carries value, so an unconstrained `_execute` let an authenticated
    ///      counterpart send the fee balance anywhere, around `withdrawFees`, its owner gate,
    ///      the `TREASURY_ROLE` destination check, and the `collectedFees` accounting.
    function test_anExecutedPayloadCannotMoveTheBalance() public {
        vm.deal(address(hub), 5 ether);
        address thief = address(0xF00D);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: thief, value: 5 ether, data: ""});

        vm.expectRevert();
        hub.receiveMessage(
            bytes32(0),
            Erc7930.encodeEvm(SPOKE_CHAIN, address(spoke)),
            Payload.encodeCalls(calls)
        );

        assertEq(thief.balance, 0, "nothing left");
        assertEq(address(hub).balance, 5 ether, "and the fee balance is intact");
    }

    /// @dev THE ALLOWLIST IS TWO ENTRIES, NOT ZERO. The payload the deferred path actually
    ///      sends still lands.
    function test_anExecutedPayloadMayStillApproveAHash() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(hub),
            value: 0,
            data: abi.encodeCall(ICommitFinalize.commit, (keccak256("deferred")))
        });

        hub.receiveMessage(
            bytes32(0),
            Erc7930.encodeEvm(SPOKE_CHAIN, address(spoke)),
            Payload.encodeCalls(calls)
        );

        assertTrue(hub.isCommitted(keccak256("deferred")));
    }

    /// @dev THE WHOLE POINT OF THE FILE. The spoke creates an account and puts a report on
    ///      the wire; those exact bytes go into the hub; the account answers with the
    ///      address the spoke actually created. No `Envelope.encode*` in the assertion.
    function test_theSpokesBytesDecodeOnTheHub() public {
        bytes memory produced = _report();
        address created = spoke.predictCrossAccount(owner, SALT);

        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), produced);

        assertEq(
            account.counterpartOn(spokeKey),
            abi.encodePacked(created),
            "the account recorded the address the spoke actually created"
        );
        assertEq(hub.destinationReceiverOn(spokeKey, owner, SALT), abi.encodePacked(created));
    }

    /// @dev AND IT REACHES THE SEND PATH, which is the reason the report moved off the
    ///      registry. The recorded address is the one `sendMessage` will accept, so a chain
    ///      whose receiver cannot be derived is addressable once its report lands, and was
    ///      not before.
    function test_theReportedAddressIsWhatTheSendPathAccepts() public {
        bytes memory produced = _report();
        address created = spoke.predictCrossAccount(owner, SALT);
        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), produced);

        bytes memory recipient = Erc7930.encodeEvm(SPOKE_CHAIN, created);
        bytes memory payload = account.payloadForCalls(new Call[](0));

        vm.prank(owner);
        account.sendMessage(recipient, payload, new bytes[](0));
    }

    /// @dev A replayed report is refused by the ACCOUNT now, not by the registry slot.
    function test_aReplayedReportIsRefused() public {
        bytes memory produced = _report();
        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), produced);

        vm.expectRevert(
            abi.encodeWithSelector(
                TransmitterBase.ReceiverAlreadyReported.selector, spokeKey
            )
        );
        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), produced);
    }

    /// @dev AND THERE IS NO OVERRIDE, NOT EVEN THE OWNER'S. An account's peer decides where
    ///      a payload lands, so it is the one value the protocol will not let anyone choose
    ///      after the fact. A wrong report is permanent for that destination, which costs
    ///      only the chain whose spoke was already compromised to produce it.
    function test_notEvenTheOwnerCanRepointAReportedReceiver() public {
        bytes memory produced = _report();
        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), produced);

        address created = spoke.predictCrossAccount(owner, SALT);
        assertTrue(account.isReceiverPinned(spokeKey));

        (bool ok,) = address(account).call(
            abi.encodeWithSignature(
                "setDestinationReceiver(bytes32,bytes)",
                spokeKey,
                abi.encodePacked(address(0xC0FFEE))
            )
        );
        assertFalse(ok, "no owner override exists");
        assertEq(account.counterpartOn(spokeKey), abi.encodePacked(created));
    }

    /// @dev A CHAIN THE HUB CAN DERIVE MAY NOT REPORT. Its own derivation is `Derived` and a
    ///      claim over a bridge is weaker, so accepting one would let a remote chain replace
    ///      a stronger fact with a poorer one. The registry answers which chains may.
    function test_aDerivableChainMayNotReport() public {
        vm.prank(msig);
        registry.setProvenance(spokeKey, Provenance.Derived);
        assertFalse(registry.requiresReceiverCallback(spokeKey));

        bytes memory produced = _report();
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.ChainDoesNotReport.selector, spokeKey
            )
        );
        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), produced);
    }

    /// @dev A CHAIN MAY ONLY REPORT ADDRESSES ON ITSELF. An ERC-7930 envelope names its own
    ///      chain, and the account is keyed by the origin the hub authenticated; without
    ///      this a counterpart could contradict its own envelope.
    function test_aChainCannotReportAnAddressOnAnotherChain() public {
        vm.prank(msig);
        bytes32 otherKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));

        bytes memory elsewhere =
            abi.encode(owner, SALT, Erc7930.encodeEvm(42161, address(0xBAD)));

        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.ReportedChainMismatch.selector, spokeKey, otherKey
            )
        );
        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), elsewhere);
    }

    /// @dev And the account keeps the bootstrap presumption, so nothing was half-recorded.
    function test_aRejectedReportLeavesTheAccountUntouched() public {
        vm.prank(msig);
        registry.addChainKey(Erc7930.encodeEvmChain(42161));

        bytes memory elsewhere =
            abi.encode(owner, SALT, Erc7930.encodeEvm(42161, address(0xBAD)));
        vm.expectRevert();
        hub.arrive(Erc7930.encodeEvmChain(SPOKE_CHAIN), abi.encodePacked(address(spoke)), elsewhere);

        // Nothing was recorded, which on a REPORTING chain is the state before the report:
        // the account is bootstrapped there and not yet reachable.
        assertTrue(account.isBootstrapped(spokeKey));
        assertFalse(account.isReachable(spokeKey));
        assertFalse(account.isReceiverPinned(spokeKey));
    }

    /// @dev ONLY THE ACCOUNT'S OWN TRANSCEIVER MAY REPORT TO IT. The hub is trusted for this
    ///      one call because it authenticated the origin; anyone else calling directly is
    ///      not, and the account says so itself rather than relying on the hub being the
    ///      only party that knows the function exists.
    function test_nobodyElseCanReportToTheAccount() public {
        vm.expectRevert(
            abi.encodeWithSelector(TransmitterBase.NotTransceiver.selector, address(this))
        );
        account.onDestinationReceiverReported(spokeKey, abi.encodePacked(address(0xBAD)));
    }
}

/// @notice The bootstrap fee, which pays for the return leg on the chains that have one.
///
/// @dev IT IS NOT A BRIDGE FOR THE MONEY. The fee accrues on the home chain in the home
///      currency; the spoke needs the destination's currency on the destination. What it
///      buys is that the funding is recovered from the accounts that create the obligation
///      rather than subsidised, and the msig moves it across out of band.
contract BootstrapFeeTest is Test {
    Hub hub;
    ChainRegistry registry;
    Transmitter account;

    address msig = address(0x5165);
    address owner = address(0xA11CE);
    bytes32 constant SALT = keccak256("acct");
    bytes32 provider;
    bytes32 divergingKey;
    bytes32 parityKey;

    uint256 constant DIVERGING = 8453;
    uint256 constant PARITY = 42161;
    uint256 constant FEE = 0.05 ether;

    function setUp() public {
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (msig))
                )
            )
        );
        hub = new Hub();
        // The msig owns the hub AND is the treasury it may pay: one address here, two
        // facts, and the tests below separate them.
        hub.initialize(msig, msig, address(new Transmitter()));

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(hub));
        hub.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
        divergingKey = registry.addChainKey(Erc7930.encodeEvmChain(DIVERGING));
        parityKey = registry.addChainKey(Erc7930.encodeEvmChain(PARITY));
        registry.setProvenance(divergingKey, Provenance.Attested);
        hub.setCounterpart(divergingKey, Erc7930.encodeEvm(DIVERGING, address(0xC0DE)));
        hub.setRoute(divergingKey, Erc7930.encodeEvmChain(DIVERGING));
        hub.setRoute(parityKey, Erc7930.encodeEvmChain(PARITY));
        // Only the chain that reports is charged.
        hub.setBootstrapFee(divergingKey, FEE);
        vm.stopPrank();

        vm.prank(owner);
        account = Transmitter(payable(hub.createTransmitter(SALT)));
        vm.deal(owner, 10 ether);
    }

    /// @dev A PARITY DESTINATION PAYS NOTHING. It sends no report and creates no obligation,
    ///      so charging it would tax the common case to fund the rare one.
    function test_aParityDestinationIsNotCharged() public {
        assertEq(hub.bootstrapFee(parityKey), 0);
        vm.prank(owner);
        account.bootstrap(PARITY, new Call[](0), new bytes[](0));
        assertEq(hub.collectedFees(), 0);
    }

    function test_theFeeIsCollectedOnADivergingDestination() public {
        vm.prank(owner);
        account.bootstrap{value: FEE}(DIVERGING, new Call[](0), new bytes[](0));
        assertEq(hub.collectedFees(), FEE, "accrued on the hub");
        assertEq(address(hub).balance, FEE);
    }

    /// @dev UNDERPAYING REVERTS RATHER THAN EATING THE PROVIDER'S PAYMENT. The alternative
    ///      is a bootstrap that dispatches with a shortfall taken out of the message fee and
    ///      fails on arrival, after the signers have committed.
    function test_underpayingTheFeeReverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.InsufficientBootstrapFee.selector, FEE, FEE - 1
            )
        );
        account.bootstrap{value: FEE - 1}(DIVERGING, new Call[](0), new bytes[](0));
    }

    /// @dev THE QUOTE CARRIES IT, or it is worse than no quote: a caller would fund the send
    ///      exactly and the bootstrap would revert with the signers already committed.
    function test_theQuoteIncludesTheFee() public view {
        uint256 withFee = hub.quoteBootstrap(
            divergingKey, owner, SALT, new Call[](0), new bytes[](0)
        );
        uint256 withoutFee = hub.quoteBootstrap(
            parityKey, owner, SALT, new Call[](0), new bytes[](0)
        );
        assertEq(withFee - withoutFee, FEE, "exactly the surcharge, on top of the message");
        assertGt(withoutFee, 0, "and the message still costs something");
    }

    /// @dev THE BINDING IS TOLD WHAT IS LEFT, not `msg.value`. Reading `msg.value` would
    ///      overpay the provider by the fee, or refund the fee to the sender.
    function test_theBindingSeesTheValueMinusTheFee() public {
        vm.prank(owner);
        account.bootstrap{value: FEE + 1 ether}(DIVERGING, new Call[](0), new bytes[](0));
        assertEq(hub.lastSendValue(), 1 ether, "message value, fee already taken");
    }

    function test_onlyTheOwnerSetsTheFeeAndWithdraws() public {
        bytes memory notOwner = abi.encodeWithSelector(
            OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)
        );

        vm.expectRevert(notOwner);
        hub.setBootstrapFee(divergingKey, 1);
        vm.expectRevert(notOwner);
        hub.withdrawFees(msig);
    }

    /// @dev THE FEE GOES TO THE TREASURY, NOT WHEREVER THE OWNER SAYS. Gating the call and
    ///      leaving the destination free would make this the one privileged operation that
    ///      moves value to an arbitrary address, so a single compromised owner transaction
    ///      empties the balance somewhere that funds no spoke. And the owner cannot widen the
    ///      set, since `TREASURY_ROLE` has no role admin.
    function test_theFeeCannotBeWithdrawnToANonTreasury() public {
        vm.prank(owner);
        account.bootstrap{value: FEE}(DIVERGING, new Call[](0), new bytes[](0));

        // Hoisted: `hub.TREASURY_ROLE()` is an external call, and one inside the pranked
        // expression would consume the prank and refuse on the CALLER instead of on `to`.
        address sink = address(0xF11);
        bytes memory notTreasurySink = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, sink, hub.TREASURY_ROLE()
        );

        vm.prank(msig);
        vm.expectRevert(notTreasurySink);
        hub.withdrawFees(sink);

        assertEq(hub.collectedFees(), FEE, "and nothing moved");
    }

    function test_withdrawingMovesOnlyTheAccruedFees() public {
        vm.prank(owner);
        account.bootstrap{value: FEE}(DIVERGING, new Call[](0), new bytes[](0));
        // A provider refund landing on the transceiver is not a fee and must survive.
        vm.deal(address(hub), address(hub).balance + 3 ether);

        vm.prank(msig);
        uint256 moved = hub.withdrawFees(msig);

        assertEq(moved, FEE);
        assertEq(msig.balance, FEE);
        assertEq(address(hub).balance, 3 ether, "the refund stayed");
        assertEq(hub.collectedFees(), 0);
    }

    function test_withdrawingNothingReverts() public {
        vm.prank(msig);
        vm.expectRevert(HubTransceiverBase.NothingToWithdraw.selector);
        hub.withdrawFees(msig);
    }
}
