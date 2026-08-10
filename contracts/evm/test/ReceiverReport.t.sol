// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/ForeignRef.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/SpokeTransceiverBase.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";

contract Receiver is ReceiverBase {
    function _isAuthorizedGateway(address) internal pure override returns (bool) {
        return true;
    }
}

/// @dev A spoke whose divergence flag is a constructor-time choice, so both arms can be
///      exercised against otherwise identical contracts.
contract ReportingSpoke is SpokeTransceiverBase, OwnableUpgradeable {
    bytes public sentRecipient;
    bytes public sentPayload;
    uint256 public sentCount;

    /// @dev Off by default: a report on a parity chain is the case that must NOT happen,
    ///      so making it the default means a test asserting silence cannot pass by
    ///      forgetting to configure something.
    bool public sendReverts;

    function initialize(address owner_, address impl, bool addressesDiverge_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(
            impl,
            ChainKey.forEvm(1),
            Erc7930.encodeEvmChain(1),
            abi.encodePacked(address(0xB0BB1E)),
            addressesDiverge_
        );
    }

    function _checkAdmin() internal view override {
        _checkOwner();
    }

    /// @dev Stands in for a dry spoke: a provider whose fee cannot be paid reverts here.
    function setSendReverts(bool v) external {
        sendReverts = v;
    }

    error NoBalanceForTheReport();

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory)
        internal
        override
        returns (bytes32)
    {
        if (sendReverts) revert NoBalanceForTheReport();
        sentRecipient = recipient;
        sentPayload = payload;
        ++sentCount;
        return bytes32(0);
    }

    /// @dev Stands in for `_onInbound`, which reaches `bootstrapInbound` by self-call
    ///      after authenticating the origin.
    function inbound(address owner, bytes32 salt, Call[] calldata calls) external {
        this.bootstrapInbound(owner, salt, calls);
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
contract Hub is HubTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
    }

    function _checkAdmin() internal view override {
        _checkOwner();
    }

    /// @dev Stands in for a provider adapter: translates a callback into the three
    ///      arguments `_onInbound` takes, and does nothing else.
    function arrive(bytes memory route, bytes memory sender, bytes calldata message)
        external
    {
        _onInbound(route, sender, message);
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

    address msig = address(0x5165);
    address owner = address(0xA11CE);
    bytes32 constant SALT = keccak256("acct");
    bytes32 provider;
    bytes32 spokeKey;

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
        hub.initialize(msig);
        spoke = new ReportingSpoke();
        spoke.initialize(msig, address(new Receiver()), true);

        vm.startPrank(msig);
        provider = registry.addMessageProvider("layerzero");
        registry.setLocalTransceiver(provider, address(hub));
        hub.setRouting(
            IChainRegistryRefs(address(registry)), provider, Provenance.Attested
        );
        spokeKey = registry.addChainKey(Erc7930.encodeEvmChain(SPOKE_CHAIN));
        registry.setTransceiverId(spokeKey, provider, keccak256("spoke.ref"));
        vm.stopPrank();

        // The spoke's own location, learned rather than derived, so `Attested`.
        vm.prank(address(hub));
        registry.onForeignRefResolved(
            keccak256("spoke.ref"), Erc7930.encodeEvm(SPOKE_CHAIN, address(spoke)), ""
        );
        vm.prank(msig);
        hub.setRoute(spokeKey, abi.encode(SPOKE_EID));
    }

    /// @dev THE WHOLE POINT OF THE FILE. The spoke creates an account and puts a report on
    ///      the wire; those exact bytes go into the hub; the hub answers with the address
    ///      the spoke actually created. No `Envelope.encode*` anywhere in the assertion.
    function test_theSpokesBytesDecodeOnTheHub() public {
        vm.chainId(SPOKE_CHAIN);
        spoke.inbound(owner, SALT, new Call[](0));
        bytes memory produced = spoke.sentPayload();
        address created = spoke.predictCrossAccount(owner, SALT);

        vm.chainId(1);
        hub.arrive(abi.encode(SPOKE_EID), abi.encodePacked(address(spoke)), produced);

        assertEq(
            hub.destinationReceiverOn(spokeKey, owner, SALT),
            abi.encodePacked(created),
            "the hub recorded the address the spoke actually created"
        );
    }

    /// @dev The slot is derived from the AUTHENTICATED origin plus the stated pair, so the
    ///      ref the hub stores agrees with the chain it came from.
    function test_theStoredRefAgreesWithTheOriginChain() public {
        vm.chainId(SPOKE_CHAIN);
        spoke.inbound(owner, SALT, new Call[](0));
        bytes memory produced = spoke.sentPayload();

        vm.chainId(1);
        hub.arrive(abi.encode(SPOKE_EID), abi.encodePacked(address(spoke)), produced);

        bytes32 slot = registry.receiverSlot(spokeKey, owner, SALT);
        assertEq(registry.get(slot).chainKey, spokeKey, "ref chain == slot chain");
        assertEq(uint8(registry.get(slot).provenance), uint8(Provenance.Attested));
    }

    /// @dev A replayed report is a no-op rather than a repoint: the slot is write-once.
    function test_aReplayedReportIsRefused() public {
        vm.chainId(SPOKE_CHAIN);
        spoke.inbound(owner, SALT, new Call[](0));
        bytes memory produced = spoke.sentPayload();

        vm.chainId(1);
        hub.arrive(abi.encode(SPOKE_EID), abi.encodePacked(address(spoke)), produced);

        vm.expectRevert(ChainRegistry.AlreadyResolved.selector);
        hub.arrive(abi.encode(SPOKE_EID), abi.encodePacked(address(spoke)), produced);
    }

    /// @dev A CHAIN MAY ONLY REPORT ADDRESSES ON ITSELF. An ERC-7930 envelope names its own
    ///      chain, and the slot is keyed by the origin the hub authenticated; without this
    ///      check the registry stored a ref whose recorded chain contradicted the slot it
    ///      sat in, readable as an account on one chain and filed under another.
    function test_aChainCannotReportAnAddressOnAnotherChain() public {
        vm.startPrank(msig);
        bytes32 otherKey = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        vm.stopPrank();

        bytes memory elsewhere = abi.encode(
            owner, SALT, Erc7930.encodeEvm(42161, address(0xBAD))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HubTransceiverBase.ReportedChainMismatch.selector, spokeKey, otherKey
            )
        );
        hub.arrive(abi.encode(SPOKE_EID), abi.encodePacked(address(spoke)), elsewhere);
    }

    /// @dev And the slot it would have written stays empty, so nothing was half-recorded.
    function test_aRejectedReportLeavesTheSlotUnresolved() public {
        vm.prank(msig);
        registry.addChainKey(Erc7930.encodeEvmChain(42161));

        bytes memory elsewhere = abi.encode(
            owner, SALT, Erc7930.encodeEvm(42161, address(0xBAD))
        );
        vm.expectRevert();
        hub.arrive(abi.encode(SPOKE_EID), abi.encodePacked(address(spoke)), elsewhere);

        vm.expectRevert(ChainRegistry.NotResolved.selector);
        hub.destinationReceiverOn(spokeKey, owner, SALT);
    }
}
