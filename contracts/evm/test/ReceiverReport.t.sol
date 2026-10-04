// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SymmetricTransceiverBase, TransceiverConfig} from "src/messaging/transceiver/SymmetricTransceiverBase.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";

/// @dev A transmitter with a send that does nothing, so a bootstrap can be dispatched
///      without a provider behind it.
contract Transmitter is OwnableTransmitter {
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
        return bytes32(0);
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal pure override returns (uint256) {
        return 0;
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

contract Receiver is ReceiverBase {
    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev Where every account the reporting side creates is homed.
function home() pure returns (bytes32) {
    return ChainKey.forEvm(1);
}

function config(address governor, address transmitterImpl, address receiverImpl, address treasury)
    pure
    returns (TransceiverConfig memory)
{
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: transmitterImpl,
        receiverImplementation: receiverImpl,
        governorOwner: governor,
        governorSalt: bytes32(0),
        governorHome: home(),
        treasury: treasury
    });
}

/// @dev A transceiver whose divergence flag is an initializer choice, so both arms can be
///      exercised against otherwise identical contracts. A diverging one stands in for the
///      zkSync and Tron variants, whose account creation fails closed on Forge's EVM.
contract ReportingTransceiver is SymmetricTransceiverBase {
    bytes public sentRecipient;
    bytes public sentPayload;
    uint256 public sentValue;
    uint256 public sentCount;

    /// @dev Off by default: a report on a parity chain is the case that must not happen,
    ///      so making it the default means a test asserting silence cannot pass by
    ///      forgetting to configure something.
    bool public sendReverts;

    function initialize(address governor, address impl, bool addressesDiverge_, address treasury_)
        external
        initializer
    {
        __SymmetricTransceiver_init(config(governor, address(0xBEEF), impl, treasury_), addressesDiverge_);
    }

    /// @dev Stands in for a dry float: a provider whose fee cannot be paid reverts here.
    function setSendReverts(bool v) external {
        sendReverts = v;
    }

    error NoBalanceForTheReport();

    /// @dev A provider that charges, so the report is priced rather than handed the whole
    ///      balance. `_reportReceiver` quotes this and sends exactly it.
    uint256 public reportFee;

    function setReportFee(uint256 v) external {
        reportFee = v;
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal view override returns (uint256) {
        return reportFee;
    }

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory, uint256 value)
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

    /// @dev Stands in for `_onInbound`, which reaches `_bootstrapInbound` after
    ///      authenticating the origin. The carried transmitter sits at the receiver's own
    ///      address, as it does on a parity home.
    function inbound(address owner, bytes32 salt, Call[] calldata calls) external {
        _bootstrapInbound(owner, salt, home(), predictCrossAccount(owner, salt, home()), calls);
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev Routes a reporting transceiver to the home, so a report has somewhere to go:
///      `Derived`, with the default counterpart at the transceiver's own address.
abstract contract WiresHome is Test {
    function _wire(ReportingTransceiver s) internal {
        ChainRegistry registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()), abi.encodeCall(ChainRegistry.initialize, (address(this)))
                )
            )
        );
        bytes32 provider = registry.addMessageProvider("test");
        registry.addChainKey(Erc7930.encodeEvmChain(1));

        vm.startPrank(s.owner());
        s.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        s.setRoute(home(), Erc7930.encodeEvmChain(1));
        vm.stopPrank();
    }
}

/// @notice The return leg: which chains report where their receiver landed, and which
///         stay silent because the home already knows.
contract ReceiverReportTest is WiresHome {
    Receiver impl;
    address owner = address(0xA11CE);
    address msig = address(0x5165);
    bytes32 constant SALT = keccak256("acct");

    function setUp() public {
        impl = new Receiver();
    }

    function _remote(bool diverges) internal returns (ReportingTransceiver s) {
        s = new ReportingTransceiver();
        s.initialize(msig, address(impl), diverges, address(0x7EA5));
        _wire(s);
    }

    /* ============================== the parity case ============================ */

    /// @dev The common case sends nothing. On a chain sharing Ethereum's CREATE2 formula
    ///      the home computed this address before the first message ever left, so a report
    ///      would spend a message to restate a derivation it already holds.
    function test_aParityChainReportsNothing() public {
        ReportingTransceiver s = _remote(false);

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentCount(), 0, "no message left");
        assertTrue(s.predictCrossAccount(owner, SALT, home()).code.length != 0, "but the account exists");
    }

    /// @dev And it would be a downgrade, not merely waste. A derivation is `Derived`;
    ///      anything arriving over a bridge is graded `Attested`, which is strictly less.
    function test_theParityChainStillCreatesTheAccountAtThePredictedAddress() public {
        ReportingTransceiver s = _remote(false);
        address predicted = s.predictCrossAccount(owner, SALT, home());

        s.inbound(owner, SALT, new Call[](0));

        assertEq(Receiver(payable(predicted)).sourceTransmitter(), predicted);
    }

    /* ============================ the diverging case =========================== */

    /// @dev Where the home cannot derive it, this chain says so. One message per account
    ///      created, addressed home.
    function test_aDivergingChainReportsTheReceiver() public {
        ReportingTransceiver s = _remote(true);
        address created = s.predictCrossAccount(owner, SALT, home());

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentCount(), 1, "one report");
        assertEq(ChainKey.fromIdentifier(s.sentRecipient()), home(), "addressed home");

        (uint8 kind, address gotOwner, bytes32 gotSalt, bytes memory interop) =
            abi.decode(s.sentPayload(), (uint8, address, bytes32, bytes));
        assertEq(kind, Envelope.RECEIVER_REPORT, "tagged as a report");
        assertEq(gotOwner, owner);
        assertEq(gotSalt, SALT);
        assertEq(
            interop, Erc7930.encodeEvm(block.chainid, created), "canonical ERC-7930 for the receiver on THIS chain"
        );
    }

    /// @dev The report names `(owner, salt)`, not the address alone: the home derives the
    ///      account from it plus the authenticated origin, so no request id is needed.
    function test_theReportCarriesThePairTheHomeKeysOn() public {
        ReportingTransceiver s = _remote(true);

        s.inbound(owner, SALT, new Call[](0));
        (, address a, bytes32 b,) = abi.decode(s.sentPayload(), (uint8, address, bytes32, bytes));

        assertEq(
            keccak256(s.sentPayload()),
            keccak256(
                Envelope.encodeReceiverReport(
                    a, b, Erc7930.encodeEvm(block.chainid, s.predictCrossAccount(a, b, home()))
                )
            )
        );
    }

    /// @dev Two accounts, two reports, each naming its own pair.
    function test_eachAccountReportsItself() public {
        ReportingTransceiver s = _remote(true);

        s.inbound(owner, SALT, new Call[](0));
        s.inbound(owner, keccak256("second"), new Call[](0));

        assertEq(s.sentCount(), 2);
        (,, bytes32 gotSalt,) = abi.decode(s.sentPayload(), (uint8, address, bytes32, bytes));
        assertEq(gotSalt, keccak256("second"), "the most recent one");
    }

    /* ================================= funding ================================= */

    /// @dev A dry float takes the whole bootstrap down, and that is the correct shape.
    ///      The send is nested inside a delivery callback where `msg.value` is zero, so it
    ///      is paid from this contract's balance. Swallowing the failure would create an
    ///      account here that the home chain could never address: `CrossProxy` arms
    ///      exactly once and `initialize` is single-shot, so there is no second bootstrap
    ///      to carry a second report. All or nothing is the only recoverable outcome.
    function test_aFailedReportRevertsTheAccountCreation() public {
        ReportingTransceiver s = _remote(true);
        s.setSendReverts(true);

        vm.expectRevert(ReportingTransceiver.NoBalanceForTheReport.selector);
        s.inbound(owner, SALT, new Call[](0));

        assertEq(
            s.predictCrossAccount(owner, SALT, home()).code.length,
            0,
            "no account, so the bootstrap can be retried once funded"
        );
    }

    /// @notice The report is priced, not handed the balance.
    ///
    /// @dev It used to send `address(this).balance`, which told the provider "take what you
    ///      like" and left a transceiver unable to hold a float for anything else. Quoting first
    ///      means the provider charges what it charges and the rest stays put, which is what
    ///      lets one float fund many reports.
    function test_theReportSendsTheQuotedFeeAndNotTheBalance() public {
        ReportingTransceiver s = _remote(true);
        s.setReportFee(0.1 ether);
        vm.deal(address(s), 5 ether);

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentValue(), 0.1 ether, "exactly the quote");
        assertEq(address(s).balance, 5 ether, "and the float is untouched by the accounting");
    }

    /// @dev The helper is what makes the quote reachable. The payload is built inside a
    ///      delivery callback from the envelope layout, this chain's id, and the address the
    ///      account will land at; without a view producing those exact bytes, anyone funding
    ///      a float would be pricing a guess.
    function test_theReportPayloadHelperMatchesWhatIsSent() public {
        ReportingTransceiver s = _remote(true);
        vm.deal(address(s), 1 ether);

        address receiver = s.predictCrossAccount(owner, SALT, home());
        bytes memory expected = s.reportPayload(owner, SALT, receiver);

        // Priced through the surface `OutboundBase` now exposes, before anything is sent.
        uint256 quoted = s.quoteMessage(Erc7930.encodeEvm(1, address(s)), expected, new bytes[](0));

        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentPayload(), expected, "the helper builds the bytes that went");
        assertEq(s.sentValue(), quoted, "and they were sent at the price it quoted");
    }

    /// @dev And the retry works, which is the property the revert buys. Funded by a plain
    ///      transfer, the way an operator tops a float up, so a transceiver that cannot accept one
    ///      fails here (#17).
    function test_theBootstrapSucceedsOnceTheFloatIsFunded() public {
        ReportingTransceiver s = _remote(true);
        s.setReportFee(1 ether);

        vm.expectRevert(ReportingTransceiver.NoBalanceForTheReport.selector);
        s.inbound(owner, SALT, new Call[](0));

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(s).call{value: 1 ether}("");
        assertTrue(ok, "it accepts its float");
        s.inbound(owner, SALT, new Call[](0));

        assertEq(s.sentCount(), 1);
        assertTrue(s.predictCrossAccount(owner, SALT, home()).code.length != 0);
    }

    /// @dev A transceiver with no treasury could never release its float, so it is refused.
    function test_aZeroTreasuryIsRefused() public {
        ReportingTransceiver s = new ReportingTransceiver();
        vm.expectRevert(HubTransceiverBase.NoTreasury.selector);
        s.initialize(msig, address(impl), true, address(0));
    }

    /// @dev A parity chain never touches the send path at all, so it needs no balance and
    ///      cannot fail this way. That is the point of gating on the flag rather than
    ///      reporting everywhere and tolerating failures.
    function test_aParityChainNeedsNoBalance() public {
        ReportingTransceiver s = _remote(false);
        s.setSendReverts(true);

        s.inbound(owner, SALT, new Call[](0));

        assertTrue(s.predictCrossAccount(owner, SALT, home()).code.length != 0);
    }

    /* ================================ the flag ================================= */

    /// @dev Write-once. Flipping it later would either start restating derivations the
    ///      home holds, or stop reporting addresses it cannot derive, and the second is silent.
    function test_theFlagHasNoSetter() public {
        ReportingTransceiver s = _remote(false);

        (bool ok,) = address(s).call(abi.encodeWithSignature("setAddressesDiverge(bool)", true));
        assertFalse(ok, "no such function");
        assertFalse(s.addressesDiverge());
    }

    function test_theFlagIsReadable() public {
        assertFalse(_remote(false).addressesDiverge());
        assertTrue(_remote(true).addressesDiverge());
    }

    /// @dev It is single-shot along with the rest of the initializer, so a second call
    ///      cannot change it.
    function test_reinitializingIsRefused() public {
        ReportingTransceiver s = _remote(false);

        vm.expectRevert();
        s.initialize(msig, address(impl), true, address(0x7EA5));
        assertFalse(s.addressesDiverge());
    }
}

/* ========================================================================== */

/// @dev The home side: a real transceiver, a real registry, and nothing hand-built.
///      Everything below feeds the reporting side's actual wire bytes into it.
contract HomeTransceiver is SymmetricTransceiverBase {
    function initialize(address governor, address treasury_, address transmitterImplementation_) external initializer {
        __SymmetricTransceiver_init(config(governor, transmitterImplementation_, address(0xBEEF), treasury_));
    }

    /// @dev Records what the base said it may spend, which is `msg.value` minus the fee.
    uint256 public lastSendValue;

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256 value)
        internal
        override
        returns (bytes32)
    {
        lastSendValue = value;
        // Pays a stand-in provider, so nothing the message cost stays here.
        (bool ok,) = address(0xFEE).call{value: value}("");
        require(ok);
        return bytes32(0);
    }

    /// @dev Priced per byte, like every real provider, so the surcharge is visibly on top
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
    function arrive(bytes memory route, bytes memory sender, bytes calldata message) external {
        _onInbound(route, sender, message);
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @notice The report crossing both halves. Every other test of this path builds the
///         message by hand on one side or the other, which cannot catch the two sides
///         drifting apart. An encoder change on the reporting side, and a decoder that still
///         expects the old shape, would leave both files green.
contract ReceiverReportRoundTripTest is WiresHome {
    HomeTransceiver homeSide;
    ReportingTransceiver remote;
    ChainRegistry registry;
    Transmitter account;

    address msig = address(0x5165);
    address owner = address(0xA11CE);
    bytes32 constant SALT = keccak256("acct");
    bytes32 provider;
    bytes32 remoteKey;

    /// @dev A chain the home cannot derive addresses on, because that is the only kind that
    ///      may report. It is `eip155` and capped below `Derived`, which is exactly the
    ///      zkSync and Tron shape: nothing about the chain type separates it from Base, and
    ///      the cap is what records that its CREATE2 formula differs.
    uint256 constant REMOTE_CHAIN = 8453;

    function setUp() public {
        registry = ChainRegistry(
            address(new ERC1967Proxy(address(new ChainRegistry()), abi.encodeCall(ChainRegistry.initialize, (msig))))
        );

        // Each side is deployed under its own chain id, which it records as local.
        vm.chainId(REMOTE_CHAIN);
        remote = new ReportingTransceiver();
        remote.initialize(msig, address(new Receiver()), true, address(0x7EA5));
        _wire(remote);
        vm.chainId(1);

        homeSide = new HomeTransceiver();
        homeSide.initialize(msig, address(0x7EA5), address(new Transmitter()));

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(homeSide));
        remoteKey = registry.addChainKey(Erc7930.encodeEvmChain(REMOTE_CHAIN));
        // Graded `Attested`: the home cannot recompute an address there, which is both why
        // a report is needed and why the report is worth only the bridge that carried it.
        registry.setProvenance(remoteKey, Provenance.Attested);
        vm.stopPrank();

        vm.startPrank(homeSide.owner());
        homeSide.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        homeSide.setCounterpart(remoteKey, Erc7930.encodeEvm(REMOTE_CHAIN, address(remote)));
        homeSide.setRoute(remoteKey, Erc7930.encodeEvmChain(REMOTE_CHAIN));
        vm.stopPrank();

        // The account the report is about. It has to exist and to have been stood up on the
        // reporting chain, because that is what gives it a counterpart slot for that chain.
        vm.startPrank(owner);
        account = Transmitter(payable(homeSide.createTransmitter(SALT)));
        vm.deal(address(account), 1 ether);
        account.bootstrap(REMOTE_CHAIN, new Call[](0), new bytes[](0));
        vm.stopPrank();
    }

    function _report() internal returns (bytes memory produced) {
        vm.chainId(REMOTE_CHAIN);
        remote.inbound(owner, SALT, new Call[](0));
        produced = remote.sentPayload();
        vm.chainId(1);
    }

    /* ======================== bootstrapped vs reachable ======================== */

    /// @notice Regression: a chain that reports is not sendable until it has reported.
    ///
    /// @dev The gap this closes. `bootstrap` used to record a counterpart at dispatch on every
    ///      chain, and on a reporting chain that value was a guess: `address(this)`, which is
    ///      exactly what `recipientOn` builds. So a send made before the report landed matched
    ///      the guess, passed the recipient check, and was addressed at an address holding no
    ///      receiver. It was paid for, and undeliverable. Now nothing is recorded until the report
    ///      arrives.
    function test_aReportingChainIsNotSendableUntilItHasReported() public {
        assertTrue(account.isBootstrapped(remoteKey), "the bootstrap went");
        assertFalse(account.isReachable(remoteKey), "but the receiver is not known yet");

        // Both hoisted: an external call inside the pranked expression consumes the prank,
        // and one inside `expectRevert`'s next call would be the call it measures.
        bytes memory recipient = Erc7930.encodeEvm(REMOTE_CHAIN, address(account));
        bytes memory payload = account.payloadForCalls(new Call[](0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.NotBootstrapped.selector, remoteKey));
        account.sendMessage(recipient, payload, new bytes[](0));

        // The report lands, and only then does the destination become sendable, at the
        // address the remote actually created, not at the guess.
        bytes memory produced = _report();
        address created = remote.predictCrossAccount(owner, SALT, home());
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), produced);

        assertTrue(account.isReachable(remoteKey), "now it is");
        assertEq(account.counterpartOn(remoteKey), abi.encodePacked(created));
    }

    /// @dev And a second bootstrap is still refused in the meantime. The dispatch record is
    ///      what prevents that, which is why it had to become a fact of its own rather than
    ///      being read off the counterpart table.
    function test_aSecondBootstrapIsRefusedWhileTheReportIsOutstanding() public {
        assertFalse(account.isReachable(remoteKey));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.AlreadyBootstrapped.selector, remoteKey));
        account.bootstrap(REMOTE_CHAIN, new Call[](0), new bytes[](0));
    }

    /* ======================== no payload runs on a homeSide ========================= */

    /// @notice Regression: a transceiver on one chain cannot report an address on another, and there
    ///         is no `Call[]` path around that.
    ///
    /// @dev `_onDestinationReceiver` takes its `chainKey` from `_authenticateOrigin`. If an
    ///      authenticated transceiver could deliver a call array, or call the report handler
    ///      directly, it could pin an account's receiver on a chain it has nothing to do with,
    ///      write-once and so unrecoverable. A transceiver runs no payload and the handler is
    ///      internal, so neither entry exists. `test_aChainCannotReportAnAddressOnAnotherChain`
    ///      covers the envelope path.
    function test_noPayloadReachesTheReportHandlerOrTheBalance() public {
        vm.deal(address(homeSide), 5 ether);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(0xF00D), value: 5 ether, data: ""});
        (bool delivered,) = address(homeSide)
            .call(
                abi.encodeWithSignature(
                    "receiveMessage(bytes32,bytes,bytes)",
                    bytes32(0),
                    Erc7930.encodeEvm(REMOTE_CHAIN, address(remote)),
                    Payload.encodeCalls(calls)
                )
            );
        assertFalse(delivered, "no receiveMessage on a transceiver");

        (bool reported,) = address(homeSide)
            .call(
                abi.encodeWithSignature(
                    "onDestinationReceiver(bytes32,address,bytes32,bytes)",
                    remoteKey,
                    owner,
                    SALT,
                    Erc7930.encodeEvm(REMOTE_CHAIN, address(0xBADBAD))
                )
            );
        assertFalse(reported, "no external report handler");

        assertEq(address(homeSide).balance, 5 ether, "the balance is intact");
    }

    /// @dev The whole point of the file. The reporting side creates an account and puts a report
    ///      on the wire; those exact bytes go into the home side; the account answers with the
    ///      address the reporting side actually created. No `Envelope.encode*` in the assertion.
    function test_theReportingSidesBytesDecodeAtHome() public {
        bytes memory produced = _report();
        address created = remote.predictCrossAccount(owner, SALT, home());

        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), produced);

        assertEq(
            account.counterpartOn(remoteKey),
            abi.encodePacked(created),
            "the account recorded the address actually created"
        );
        assertEq(homeSide.destinationReceiverOn(remoteKey, owner, SALT), abi.encodePacked(created));
    }

    /// @dev And it reaches the send path, which is the reason the report moved off the
    ///      registry. The recorded address is the one `sendMessage` will accept, so a chain
    ///      whose receiver cannot be derived is addressable once its report lands, and was
    ///      not before.
    function test_theReportedAddressIsWhatTheSendPathAccepts() public {
        bytes memory produced = _report();
        address created = remote.predictCrossAccount(owner, SALT, home());
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), produced);

        bytes memory recipient = Erc7930.encodeEvm(REMOTE_CHAIN, created);
        bytes memory payload = account.payloadForCalls(new Call[](0));

        vm.prank(owner);
        account.sendMessage(recipient, payload, new bytes[](0));
    }

    /// @dev A replayed report is refused by the account now, not by the registry slot.
    function test_aReplayedReportIsRefused() public {
        bytes memory produced = _report();
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), produced);

        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.ReceiverAlreadyReported.selector, remoteKey));
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), produced);
    }

    /// @dev And there is no override, not even the owner's. An account's peer decides where
    ///      a payload lands, so it is the one value the protocol will not let anyone choose
    ///      after the fact. A wrong report is permanent for that destination, which costs
    ///      only the chain whose transceiver was already compromised to produce it.
    function test_notEvenTheOwnerCanRepointAReportedReceiver() public {
        bytes memory produced = _report();
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), produced);

        address created = remote.predictCrossAccount(owner, SALT, home());
        assertTrue(account.isReceiverPinned(remoteKey));

        (bool ok,) = address(account)
            .call(
                abi.encodeWithSignature(
                    "setDestinationReceiver(bytes32,bytes)", remoteKey, abi.encodePacked(address(0xC0FFEE))
                )
            );
        assertFalse(ok, "no owner override exists");
        assertEq(account.counterpartOn(remoteKey), abi.encodePacked(created));
    }

    /// @dev A chain the home can derive may not report. Its own derivation is `Derived` and a
    ///      claim over a bridge is weaker, so accepting one would let a remote chain replace
    ///      a stronger fact with a poorer one. The registry answers which chains may.
    function test_aDerivableChainMayNotReport() public {
        vm.prank(msig);
        registry.setProvenance(remoteKey, Provenance.Derived);
        assertFalse(registry.requiresReceiverCallback(remoteKey));

        bytes memory produced = _report();
        vm.expectRevert(abi.encodeWithSelector(HubTransceiverBase.ChainDoesNotReport.selector, remoteKey));
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), produced);
    }

    /// @dev A chain may only report addresses on itself. An ERC-7930 envelope names its own
    ///      chain, and the account is keyed by the origin the home authenticated; without
    ///      this a counterpart could contradict its own envelope.
    function test_aChainCannotReportAnAddressOnAnotherChain() public {
        vm.prank(msig);
        bytes32 otherKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));

        bytes memory elsewhere = Envelope.encodeReceiverReport(owner, SALT, Erc7930.encodeEvm(42161, address(0xBAD)));

        vm.expectRevert(abi.encodeWithSelector(HubTransceiverBase.ReportedChainMismatch.selector, remoteKey, otherKey));
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), elsewhere);
    }

    /// @dev And the account keeps the bootstrap presumption, so nothing was half-recorded.
    function test_aRejectedReportLeavesTheAccountUntouched() public {
        vm.prank(msig);
        registry.addChainKey(Erc7930.encodeEvmChain(42161));

        bytes memory elsewhere = Envelope.encodeReceiverReport(owner, SALT, Erc7930.encodeEvm(42161, address(0xBAD)));
        vm.expectRevert();
        homeSide.arrive(Erc7930.encodeEvmChain(REMOTE_CHAIN), abi.encodePacked(address(remote)), elsewhere);

        // Nothing was recorded, which on a reporting chain is the state before the report:
        // the account is bootstrapped there and not yet reachable.
        assertTrue(account.isBootstrapped(remoteKey));
        assertFalse(account.isReachable(remoteKey));
        assertFalse(account.isReceiverPinned(remoteKey));
    }

    /// @dev Only the account's own transceiver may report to it. The home transceiver is trusted for this
    ///      one call because it authenticated the origin; anyone else calling directly is
    ///      not, and the account says so itself rather than relying on the home transceiver being the
    ///      only party that knows the function exists.
    function test_nobodyElseCanReportToTheAccount() public {
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.NotTransceiver.selector, address(this)));
        account.onDestinationReceiverReported(remoteKey, abi.encodePacked(address(0xBAD)));
    }
}

/// @notice The bootstrap fee, which pays for the return leg on the chains that have one.
///
/// @dev It is not a bridge for the money. The fee accrues on the home chain in the home
///      currency; the reporting chain's float needs the destination's currency on the destination. What it
///      buys is that the funding is recovered from the accounts that create the obligation
///      rather than subsidised, and the msig moves it across out of band.
contract BootstrapFeeTest is Test {
    HomeTransceiver t;
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
    address treasury;

    function setUp() public {
        registry = ChainRegistry(
            address(new ERC1967Proxy(address(new ChainRegistry()), abi.encodeCall(ChainRegistry.initialize, (msig))))
        );
        t = new HomeTransceiver();
        // One treasury per chain, named at deployment and never moved.
        treasury = address(new Treasury(msig));
        t.initialize(msig, treasury, address(new Transmitter()));

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(t));
        divergingKey = registry.addChainKey(Erc7930.encodeEvmChain(DIVERGING));
        parityKey = registry.addChainKey(Erc7930.encodeEvmChain(PARITY));
        registry.setProvenance(divergingKey, Provenance.Attested);
        vm.stopPrank();

        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Attested);
        t.setCounterpart(divergingKey, Erc7930.encodeEvm(DIVERGING, address(0xC0DE)));
        t.setRoute(divergingKey, Erc7930.encodeEvmChain(DIVERGING));
        t.setRoute(parityKey, Erc7930.encodeEvmChain(PARITY));
        // Only the chain that reports is charged.
        t.setBootstrapFee(divergingKey, FEE);
        vm.stopPrank();

        vm.prank(owner);
        account = Transmitter(payable(t.createTransmitter(SALT)));
        vm.deal(address(account), 10 ether);
    }

    /// @dev A parity destination pays nothing. It sends no report and creates no obligation,
    ///      so charging it would tax the common case to fund the rare one.
    function test_aParityDestinationIsNotCharged() public {
        assertEq(t.bootstrapFee(parityKey), 0);
        vm.prank(owner);
        account.bootstrap(PARITY, new Call[](0), new bytes[](0));
        assertEq(treasury.balance, 0);
    }

    /// @dev The fee moves in the transaction that charges it. Nothing accrues on the transceiver, so
    ///      there is no balance to direct later and nothing to confuse with a provider refund.
    function test_theFeeGoesStraightToTheTreasury() public {
        vm.prank(owner);
        account.bootstrap(DIVERGING, new Call[](0), new bytes[](0));

        assertEq(treasury.balance, FEE, "paid, not accrued");
        assertEq(address(t).balance, 0, "and the transceiver holds none of it");
    }

    /// @dev The treasury is `Ownable`, so the msig moves it onward from there, which is the
    ///      only place a fee is ever withdrawn from now.
    function test_theMsigMovesFeesOnFromTheTreasury() public {
        vm.prank(owner);
        account.bootstrap(DIVERGING, new Call[](0), new bytes[](0));

        vm.prank(msig);
        Treasury(payable(treasury)).withdraw(msig, FEE);
        assertEq(msig.balance, FEE);
    }

    /// @dev Underpaying reverts rather than eating the provider's payment. The alternative
    ///      is a bootstrap that dispatches with a shortfall taken out of the message fee and
    ///      fails on arrival. The account always pays the quote, so this guards the transceiver's own
    ///      entry point.
    function test_underpayingTheFeeReverts() public {
        vm.deal(address(account), FEE);
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(HubTransceiverBase.InsufficientBootstrapFee.selector, FEE, FEE - 1));
        t.bootstrap{value: FEE - 1}(divergingKey, owner, SALT, new Call[](0), new bytes[](0));
    }

    /// @dev An account that cannot cover the quote, fee included, sends nothing and pays
    ///      nobody.
    function test_anUnfundedAccountCannotBootstrap() public {
        uint256 quote = account.quoteBootstrap(DIVERGING, new Call[](0), new bytes[](0));
        vm.deal(address(account), quote - 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.InsufficientBalance.selector, quote, quote - 1));
        account.bootstrap(DIVERGING, new Call[](0), new bytes[](0));
        assertEq(treasury.balance, 0);
    }

    /// @dev The quote carries it, or it is worse than no quote: a caller would fund the send
    ///      exactly and the bootstrap would revert with the signers already committed.
    function test_theQuoteIncludesTheFee() public view {
        uint256 withFee = t.quoteBootstrap(divergingKey, owner, SALT, new Call[](0), new bytes[](0));
        uint256 withoutFee = t.quoteBootstrap(parityKey, owner, SALT, new Call[](0), new bytes[](0));
        assertEq(withFee - withoutFee, FEE, "exactly the surcharge, on top of the message");
        assertGt(withoutFee, 0, "and the message still costs something");
    }

    /// @dev The account pays exactly its quote, whatever it holds, and the binding is told
    ///      what is left after the fee.
    function test_theAccountPaysTheQuoteAndTheBindingSeesItLessTheFee() public {
        uint256 quote = account.quoteBootstrap(DIVERGING, new Call[](0), new bytes[](0));
        uint256 before = address(account).balance;

        vm.prank(owner);
        account.bootstrap(DIVERGING, new Call[](0), new bytes[](0));

        assertEq(before - address(account).balance, quote, "the quote, not the balance");
        assertEq(t.lastSendValue(), quote - FEE, "message value, fee already taken");
    }

    /// @dev `msg.value` tops the balance up and is not a price: the same quote is paid and
    ///      the rest stays on the account.
    function test_attachedValueStaysOnTheAccount() public {
        vm.deal(address(account), 0);
        vm.deal(owner, 1 ether);
        uint256 quote = account.quoteBootstrap(DIVERGING, new Call[](0), new bytes[](0));

        vm.prank(owner);
        account.bootstrap{value: 1 ether}(DIVERGING, new Call[](0), new bytes[](0));

        assertEq(address(account).balance, 1 ether - quote);
        assertEq(t.lastSendValue(), quote - FEE);
    }

    function test_onlyTheOwnerSetsTheFee() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        t.setBootstrapFee(divergingKey, 1);
    }

    /// @dev The treasury is write-once and there is no fee withdrawal. Together those remove
    ///      the operation a compromised owner would have reached for: no accrued fees, no
    ///      destination to name, and no setter to repoint. The float leaves only at the
    ///      treasury's own call.
    function test_thereIsNoWithdrawalAndNoWayToRepointTheTreasury() public {
        assertEq(t.treasury(), treasury);

        (bool withdrew,) = address(t).call(abi.encodeWithSignature("withdrawFees(address)", msig));
        assertFalse(withdrew);

        (bool set,) = address(t).call(abi.encodeWithSignature("setTreasury(address)", msig));
        assertFalse(set);
    }

    /// @dev A reverting treasury fails the bootstrap rather than silently under-paying the
    ///      Provider. The fee is taken off the top, so a payment that did not happen would
    ///      otherwise leave the message dispatched with the shortfall coming out of it.
    function test_aTreasuryThatRefusesPaymentFailsTheBootstrap() public {
        HomeTransceiver h = new HomeTransceiver();
        address rejecting = address(new Rejector());
        h.initialize(msig, rejecting, address(new Transmitter()));

        vm.startPrank(msig);
        bytes32 second = registry.addMessageProvider("second");
        registry.setLocalTransceiver(second, address(h));
        vm.stopPrank();

        vm.startPrank(h.owner());
        h.setRouting(IChainRegistryRefs(address(registry)), second, Provenance.Attested);
        h.setCounterpart(divergingKey, Erc7930.encodeEvm(DIVERGING, address(0xC0DE)));
        h.setRoute(divergingKey, Erc7930.encodeEvmChain(DIVERGING));
        h.setBootstrapFee(divergingKey, FEE);
        vm.stopPrank();

        vm.prank(owner);
        Transmitter a = Transmitter(payable(h.createTransmitter(SALT)));
        vm.deal(address(a), 1 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HubTransceiverBase.FeeTransferFailed.selector, rejecting, FEE));
        a.bootstrap(DIVERGING, new Call[](0), new bytes[](0));
    }
}

/// @dev Refuses native currency, standing in for a treasury that has been misconfigured.
contract Rejector {
    receive() external payable {
        revert("no");
    }
}
