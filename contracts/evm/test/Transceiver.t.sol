// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {crossProxyDeployer} from "test/DeployTransceiver.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Treasury, IReportFloat} from "src/treasury/Treasury.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {MockTransmitter} from "test/Transport.t.sol";

/// @dev The transport every test transceiver here shares: it records what it was asked to send.
abstract contract SymHarness is TransceiverBase {
    bytes public sentRecipient;
    bytes public sentPayload;
    uint256 public sentValue;
    uint256 public sentCount;
    address public sentRefundTo;

    function _sendMessage(bytes memory recipient, bytes memory payload, bytes[] memory, uint256 value)
        internal
        override
        returns (bytes32)
    {
        require(value <= address(this).balance, "unfunded");
        sentRecipient = recipient;
        sentPayload = payload;
        sentValue = value;
        sentRefundTo = _refundTo();
        ++sentCount;
        return bytes32(0);
    }

    /// @dev One wei per byte, so a quote is checkable by hand.
    function _quoteMessage(bytes memory, bytes memory payload, bytes[] memory)
        internal
        pure
        override
        returns (uint256)
    {
        return payload.length;
    }

    function arrive(bytes memory route, bytes memory sender, bytes calldata message) external {
        _onInbound(route, sender, message);
    }
}

contract Sym is SymHarness {
    function initialize(TransceiverConfig memory c) external initializer {
        __TransceiverBase_init(c);
    }

    /// @dev A diverging chain on Forge's EVM, standing in for the zkSync and Tron variants,
    ///      whose account creation fails closed here.
    function initializeDiverging(TransceiverConfig memory c, bool diverges) external initializer {
        __TransceiverBase_init(c, diverges);
    }
}

contract Rcv is ReceiverBase {}

/// @dev Transmitter logic that records what its transceiver tells it.
contract RecordingTransmitter {
    address public owner;
    address public transceiver;
    bytes32 public reportedChain;
    bytes public reportedReceiver;

    function initialize(address owner_, address transceiver_, bytes32) external {
        owner = owner_;
        transceiver = transceiver_;
    }

    function onDestinationReceiverReported(bytes32 chainKey, bytes calldata receiver) external {
        require(msg.sender == transceiver, "not the transceiver");
        reportedChain = chainKey;
        reportedReceiver = receiver;
    }
}

/// @dev Two chains simulated in one EVM: each is a state snapshot, and the transceiver lands
///      at one address on both because it is deployed from one initcode at one salt, as a
///      provider's transceivers are. Its `localChainKey` is read at deployment, so each copy
///      knows its own chain.
contract TransceiverTest is Test {
    uint256 constant ETH = 1;
    uint256 constant BASE = 8453;
    uint256 constant ZK = 324;
    bytes32 constant SALT = keccak256("account");
    bytes32 constant TRANSCEIVER_SALT = keccak256("provider");

    address msig = address(0x5165);
    address alice = address(0xA11CE);
    address zkTransceiver = address(0x2C);

    function _key(uint256 chainId) internal pure returns (bytes32) {
        return ChainKey.forEvm(chainId);
    }

    function _route(uint256 chainId) internal pure returns (bytes memory) {
        return Erc7930.encodeEvmChain(chainId);
    }

    /// @dev Stands this chain up: a registry, a treasury, and the transceiver, configured by
    ///      its owner for the two other chains. Ethereum and Base are `Predetermined`; zkSync is
    ///      `Unique`, with its transceiver at its own address.
    function _chain(uint256 chainId, bool diverges) internal returns (Sym t) {
        return _chainWith(chainId, diverges, address(new RecordingTransmitter()));
    }

    function _chainWith(uint256 chainId, bool diverges, address transmitterImplementation) internal returns (Sym t) {
        vm.chainId(chainId);
        ChainRegistry registry = new ChainRegistry(address(this), unseeded());
        Treasury treasury = new Treasury(address(this));
        bytes32 provider = registry.addMessageProvider("test");

        TransceiverConfig memory c = TransceiverConfig({
            gateways: new address[](0),
            transmitterImplementation: transmitterImplementation,
            receiverImplementation: address(new Rcv()),
            governorOwner: msig,
            governorSalt: bytes32(0),
            governorHome: _route(ETH),
            treasury: address(treasury),
            chainRegistry: IChainRegistryRefs(address(0)),
            messageProvider: bytes32(0),
            minCounterpartProvenance: Provenance.Unknown
        });
        t = _deploySym(abi.encodeCall(Sym.initializeDiverging, (c, diverges)));

        uint256[3] memory chains = [ETH, BASE, ZK];
        vm.startPrank(t.owner());
        t.setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        for (uint256 i; i < 3; ++i) {
            if (chains[i] == chainId) continue;
            vm.stopPrank();
            registry.addChainKey(_route(chains[i]), chains[i] == ZK ? Provenance.Unique : Provenance.Predetermined);
            vm.startPrank(t.owner());
            t.setRoute(_key(chains[i]), _route(chains[i]));
            if (chains[i] == ZK) t.setCounterpart(_key(ZK), Erc7930.encodeEvm(ZK, zkTransceiver));
        }
        vm.stopPrank();
    }

    /// @dev As production deploys a transceiver, so the seeded deployment record predicts where
    ///      it lands: a `CrossProxy` through `CrossProxyDeployer`, armed in the same call.
    function _deploySym(bytes memory init) internal returns (Sym) {
        return Sym(payable(crossProxyDeployer().deploy(TRANSCEIVER_SALT, address(new Sym()), init)));
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](0);
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /* =================================== identity ================================= */

    /// @dev The owner is the msig's own account on each chain, derived rather than typed: its
    ///      transmitter at home, and at that same address on every parity chain.
    function test_theOwnerIsTheMsigsOwnAccount() public {
        uint256 world = vm.snapshotState();
        Sym eth = _chain(ETH, false);
        address onEth = eth.owner();
        assertEq(onEth, eth.predictTransmitter(msig, bytes32(0)), "the msig's transmitter at home");

        vm.revertToState(world);
        Sym base = _chain(BASE, false);
        assertEq(base.owner(), onEth, "and its receiver on a parity chain, at the same address");
    }

    function test_anAccountHomedHereGetsATransmitter() public {
        Sym t = _chain(BASE, false);

        vm.prank(alice);
        address account = t.createTransmitter(SALT);

        assertEq(account, t.predictCrossAccount(alice, SALT, _key(BASE)));
        assertEq(RecordingTransmitter(account).owner(), alice, "transmitter logic, owned by its caller");
    }

    /// @dev #28: a chain other than the governor's home has no owner until a bootstrap from
    ///      that home creates the governor's receiver, so its transceiver is born able to
    ///      accept it: a seeded registry, and the routing and route for that home at
    ///      initialization. No owner call happens on Base before the receiver exists.
    function test_aFreshChainAcceptsTheBootstrapThatCreatesItsOwner() public {
        uint256 world = vm.snapshotState();

        Sym eth = _chain(ETH, false);
        address governor = eth.owner();
        vm.prank(governor);
        eth.bootstrap(_key(BASE), msig, bytes32(0), _calls(), new bytes[](0));
        bytes memory sent = eth.sentPayload();
        bytes32 crossProxyInitCodeHash = eth.CROSS_PROXY_INIT_CODE_HASH();

        vm.revertToState(world);
        vm.chainId(BASE);
        ProviderSeed[] memory providers = new ProviderSeed[](1);
        providers[0] = ProviderSeed("test", address(this), TRANSCEIVER_SALT, crossProxyInitCodeHash);
        ChainRegistry registry = new ChainRegistry(
            address(this),
            RegistrySeed({governorHome: _route(ETH), governorHomeGrade: Provenance.Predetermined, providers: providers})
        );
        Sym base = _deploySym(
            abi.encodeCall(
                Sym.initialize,
                TransceiverConfig({
                    gateways: new address[](0),
                    transmitterImplementation: address(new RecordingTransmitter()),
                    receiverImplementation: address(new Rcv()),
                    governorOwner: msig,
                    governorSalt: bytes32(0),
                    governorHome: _route(ETH),
                    treasury: address(new Treasury(address(this))),
                    chainRegistry: IChainRegistryRefs(address(registry)),
                    messageProvider: keccak256("test"),
                    minCounterpartProvenance: Provenance.Unique
                })
            )
        );
        assertEq(address(base), address(eth), "one address on both chains");
        assertEq(registry.predictTransceiver(_key(ETH), keccak256("test")), address(base), "where the record predicts");
        assertEq(base.owner().code.length, 0, "the owner does not exist yet");

        base.arrive(_route(ETH), abi.encodePacked(address(base)), sent);

        address owner = base.owner();
        assertEq(owner, governor, "the governor's receiver sits on its transmitter's address");
        assertEq(ReceiverBase(payable(owner)).sourceTransmitter(), governor, "and answers to it");
        vm.prank(owner);
        base.setRoute(_key(ZK), _route(ZK));
        assertEq(base.routeFor(_key(ZK)), _route(ZK), "and it configures the rest");
    }

    /* ============================ a bootstrap end to end =========================== */

    /// @dev The whole path between two transceivers: an account homed on Base
    ///      bootstraps Ethereum, and its receiver there lands on its transmitter's address and
    ///      answers to it.
    function test_aBootstrapCrossesBetweenTwoChains() public {
        uint256 world = vm.snapshotState();

        Sym base = _chain(BASE, false);
        address transmitter = base.predictTransmitter(alice, SALT);
        uint256 quote = base.quoteBootstrap(_key(ETH), alice, SALT, _calls(), new bytes[](0));
        vm.deal(transmitter, quote);
        vm.prank(transmitter);
        base.bootstrap{value: quote}(_key(ETH), alice, SALT, _calls(), new bytes[](0));

        bytes memory sent = base.sentPayload();
        assertEq(base.sentRecipient(), Erc7930.encodeEvm(ETH, address(base)), "to the transceiver on Ethereum");
        assertEq(base.sentRefundTo(), transmitter, "a bootstrap's overpayment refunds the account");

        vm.revertToState(world);
        Sym eth = _chain(ETH, false);
        assertEq(address(eth), address(base), "one address on both chains");
        eth.arrive(_route(BASE), abi.encodePacked(address(eth)), sent);

        address receiver = eth.predictCrossAccount(alice, SALT, _key(BASE));
        assertEq(receiver, transmitter, "the receiver sits on its transmitter's address");
        assertEq(ReceiverBase(payable(receiver)).sourceTransmitter(), transmitter, "and answers to it");
    }

    /// @dev This chain is never a destination: an account homed here is its transmitter.
    function test_aBootstrapToThisChainIsRefused() public {
        Sym t = _chain(BASE, false);
        address transmitter = t.predictTransmitter(alice, SALT);

        vm.prank(transmitter);
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.IsLocalChain.selector, _key(BASE)));
        t.bootstrap(_key(BASE), alice, SALT, _calls(), new bytes[](0));
    }

    /// @dev The same refusal through a real transmitter, whose bootstrap asks the transceiver
    ///      about the destination before anything is sent.
    function test_aTransmitterCannotBootstrapItsOwnChain() public {
        Sym t = _chainWith(BASE, false, address(new MockTransmitter()));
        vm.prank(alice);
        MockTransmitter account = MockTransmitter(payable(t.createTransmitter(SALT)));
        vm.deal(address(account), 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.IsLocalChain.selector, _key(BASE)));
        account.bootstrap(BASE, _calls(), new bytes[](0));
    }

    function test_theElementsFormIsRefusedOnAnEvmChain() public {
        Sym t = _chain(ETH, false);
        bytes memory m = Envelope.encodeBootstrapElements(alice, SALT, _word(address(t)), new bytes[](1));

        vm.expectRevert(
            abi.encodeWithSelector(
                Envelope.UnexpectedEnvelopeKind.selector, Envelope.BOOTSTRAP, Envelope.BOOTSTRAP_ELEMENTS
            )
        );
        t.arrive(_route(BASE), abi.encodePacked(address(t)), m);
    }

    /* ================================== parity =================================== */

    /// @dev From a `Predetermined` home the receiver must sit on its transmitter's address.
    function test_aReceiverOffItsTransmitterIsRefusedFromADerivedHome() public {
        Sym t = _chain(ETH, false);
        address wrong = address(0xBAD);
        bytes memory m = Envelope.encodeBootstrap(alice, SALT, _word(wrong), _calls());

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.ParityBroken.selector, t.predictCrossAccount(alice, SALT, _key(BASE)), wrong
            )
        );
        t.arrive(_route(BASE), abi.encodePacked(address(t)), m);
    }

    /// @dev The case the check exists for: an origin whose provider id is mapped to the wrong
    ///      chain. The carried transmitter is right for its real home, but the receiver lands
    ///      under the mapped one, so every account from there would be unreachable.
    function test_anOriginMappedToTheWrongChainRefusesItsFirstBootstrap() public {
        Sym t = _chain(ETH, false);
        address realTransmitter = t.predictCrossAccount(alice, SALT, _key(10));
        bytes memory m = Envelope.encodeBootstrap(alice, SALT, _word(realTransmitter), _calls());

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.ParityBroken.selector, t.predictCrossAccount(alice, SALT, _key(BASE)), realTransmitter
            )
        );
        t.arrive(_route(BASE), abi.encodePacked(address(t)), m);
    }

    /// @dev A zkSync home keeps its transmitter at a zkSync address, so the receiver here is
    ///      elsewhere by design and answers to the carried address.
    function test_aUniqueHomeIsNotHeldToParity() public {
        Sym t = _chain(ETH, false);
        address zkTransmitter = address(0x2CA11);
        bytes memory m = Envelope.encodeBootstrap(alice, SALT, _word(zkTransmitter), _calls());

        t.arrive(_route(ZK), abi.encodePacked(zkTransceiver), m);

        address receiver = t.predictCrossAccount(alice, SALT, _key(ZK));
        assertEq(ReceiverBase(payable(receiver)).sourceTransmitter(), zkTransmitter);
    }

    /* ================================== reports ================================== */

    /// @dev Where this chain diverges, every receiver is reported to its home, paid from the
    ///      float, and a provider's refund of that payment returns to the float.
    function test_aDivergingChainReportsToTheHomeFromItsFloat() public {
        Sym t = _chain(ETH, true);
        vm.deal(address(t), 1 ether);
        bytes memory m = Envelope.encodeBootstrap(alice, SALT, _word(address(0x7A)), _calls());

        t.arrive(_route(BASE), abi.encodePacked(address(t)), m);

        address receiver = t.predictCrossAccount(alice, SALT, _key(BASE));
        assertEq(t.sentCount(), 1, "one report");
        assertEq(t.sentRecipient(), Erc7930.encodeEvm(BASE, address(t)), "to the home");
        assertEq(t.sentPayload(), t.reportPayload(alice, SALT, receiver));
        assertEq(t.sentRefundTo(), address(t), "the report's overpayment returns to the float");

        // Outside a report, a bootstrap's overpayment refunds the account again.
        address transmitter = t.predictTransmitter(alice, SALT);
        uint256 quote = t.quoteBootstrap(_key(BASE), alice, SALT, _calls(), new bytes[](0));
        vm.deal(transmitter, quote);
        vm.prank(transmitter);
        t.bootstrap{value: quote}(_key(BASE), alice, SALT, _calls(), new bytes[](0));
        assertEq(t.sentRefundTo(), transmitter);
    }

    /// @dev The same contract receives reports for the accounts homed here.
    function test_aReportReachesTheAccountHomedHere() public {
        Sym t = _chain(ETH, false);
        vm.prank(alice);
        address account = t.createTransmitter(SALT);

        bytes memory zkReceiver = Erc7930.encodeEvm(ZK, address(0x2CBEEF));
        t.arrive(_route(ZK), abi.encodePacked(zkTransceiver), Envelope.encodeReceiverReport(alice, SALT, zkReceiver));

        assertEq(RecordingTransmitter(account).reportedChain(), _key(ZK));
        assertEq(RecordingTransmitter(account).reportedReceiver(), abi.encodePacked(address(0x2CBEEF)));
    }

    /* ================================== the float ================================= */

    function test_theFloatLeavesOnlyToTheTreasury() public {
        Sym t = _chain(ETH, false);
        vm.deal(address(t), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(TransceiverBase.NotTreasury.selector, address(this)));
        t.withdraw(1 ether);

        Treasury treasury = Treasury(payable(t.treasury()));
        treasury.collect(IReportFloat(address(t)), 1 ether);
        assertEq(address(treasury).balance, 1 ether);
        assertEq(address(t).balance, 0);
    }

    /* ============================== initialization =============================== */

    function test_initializationRefusesMissingPieces() public {
        TransceiverConfig memory c = TransceiverConfig({
            gateways: new address[](0),
            transmitterImplementation: address(new RecordingTransmitter()),
            receiverImplementation: address(0),
            governorOwner: msig,
            governorSalt: bytes32(0),
            governorHome: _route(ETH),
            treasury: address(1),
            chainRegistry: IChainRegistryRefs(address(0)),
            messageProvider: bytes32(0),
            minCounterpartProvenance: Provenance.Unknown
        });

        Sym fresh = new Sym();
        vm.expectRevert(TransceiverBase.NoAccountImplementation.selector);
        fresh.initialize(c);

        c.receiverImplementation = address(new Rcv());
        c.treasury = address(0);
        fresh = new Sym();
        vm.expectRevert(TransceiverBase.NoTreasury.selector);
        fresh.initialize(c);

        c.treasury = address(1);
        c.governorOwner = address(0);
        fresh = new Sym();
        vm.expectRevert(TransceiverBase.ZeroOwner.selector);
        fresh.initialize(c);
    }
}
