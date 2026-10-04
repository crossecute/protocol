// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ChainKey} from "src/addressing/ChainKey.sol";

import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UnsendableTransceiver} from "test/Unsendable.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";

/// @dev Stands in for Arachnid's proxy: CREATE2 with a caller-supplied salt and initcode.
contract MiniFactory {
    function deploy(bytes32 salt, bytes memory initCode) external returns (address a) {
        assembly {
            a := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(a != address(0), "create2 failed");
    }

    function arm(address proxy, address impl, bytes calldata data) external {
        ICrossProxy(proxy).upgradeInitializeAndLock(impl, data);
    }
}

contract SaltedReceiver is ReceiverBase {
    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev Minimal transmitter logic: enough to prove which side armed the account.
contract MiniTransmitter {
    address public owner;
    address public transceiver;
    bytes32 public accountSalt;

    function initialize(address owner_, address transceiver_, bytes32 salt_) external {
        owner = owner_;
        transceiver = transceiver_;
        accountSalt = salt_;
    }
}

/// @dev Where the accounts the transceiver creates receivers for are homed.
function home() pure returns (bytes32) {
    return ChainKey.forEvm(1);
}

/// @dev One transceiver, deployed from one initcode at one salt on every chain: it creates
///      transmitters for accounts homed where it runs and receivers for accounts homed
///      elsewhere.
contract SaltedTransceiver is UnsendableTransceiver {
    function initialize(address governor, address transmitterImpl, address receiverImpl) external initializer {
        __TransceiverBase_init(
            TransceiverConfig({
                gateways: new address[](0),
                transmitterImplementation: transmitterImpl,
                receiverImplementation: receiverImpl,
                governorOwner: governor,
                governorSalt: bytes32(0),
                governorHome: home(),
                treasury: address(0x7EA5)
            }),
            _diverges()
        );
    }

    function _diverges() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Stands in for `_onInbound`, which authenticates and then reaches
    ///      `_bootstrapInbound`. Creates the account directly: the parity check and the report
    ///      are `SymmetricTransceiver.t.sol`'s and `ReceiverReport.t.sol`'s, and these tests are
    ///      about where accounts land. The carried transmitter is where Ethereum's CREATE2
    ///      puts it at home, over this same address.
    function bootstrapFor(address owner_) external returns (address) {
        address carried = Create2.computeAddress(accountSalt(owner_, bytes32(0), home()), CROSS_PROXY_INIT_CODE_HASH);
        return _createCrossAccount(owner_, bytes32(0), home(), carried, new Call[](0));
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

/// @dev A stand-in transmitter that answers `owner()`.
contract OwnedTransmitter {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @notice A provider's salt makes its transceiver (and every account under it) computable
///         on any chain before either exists.
contract SaltedDeploymentTest is Test {
    ChainRegistry registry;
    MiniFactory factory;

    address owner = address(0xA11CE);
    bytes32 provider;
    bytes32 chainKey;

    bytes32 constant SALT = keccak256("crossecute.lz.v1");

    function setUp() public {
        registry = new ChainRegistry(owner);
        factory = new MiniFactory();

        vm.startPrank(owner);
        provider = registry.addMessageProvider("layerzero");
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Derived);
        registry.setCreate2Factory(chainKey, address(factory));
        vm.stopPrank();
    }

    /// @dev One constant, independent of the implementation. `CrossProxy` takes no
    ///      constructor arguments, so every account (transmitter or receiver, on any
    ///      chain) deploys from this exact byte string. That independence is what lets
    ///      two accounts with different logic share an address; an EIP-1167 clone bakes
    ///      the implementation into its initcode and could never manage it.
    function _crossProxyInitCodeHash() internal pure returns (bytes32) {
        return keccak256(type(CrossProxy).creationCode);
    }

    function _record(bytes32 transceiverInitCodeHash, bytes32 receiverInitCodeHash) internal {
        vm.prank(owner);
        registry.setProviderDeployment(provider, SALT, transceiverInitCodeHash, receiverInitCodeHash);
    }

    /* ============================== the whole chain ============================= */

    /// @dev The load-bearing test. Ethereum predicts the transceiver from a recorded salt,
    ///      the transceiver is then actually deployed at that address, it creates a
    ///      receiver, and the receiver lands where Ethereum said it would: all without
    ///      either contract existing when the prediction was made.
    function test_bothAddressesArePredictedBeforeEitherExists() public {
        bytes memory initCode = type(SaltedTransceiver).creationCode;
        address impl = address(new SaltedReceiver());
        _record(keccak256(initCode), _crossProxyInitCodeHash());

        address predictedTransceiver = registry.predictTransceiver(chainKey, provider);
        address ownerOf = address(0x7A11);
        address predictedReceiver =
            registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0), ChainKey.forEvm(1));

        // Nothing is deployed yet.
        assertEq(predictedTransceiver.code.length, 0);
        assertEq(predictedReceiver.code.length, 0);

        // Now deploy for real, through the factory, with that salt.
        address deployed = factory.deploy(SALT, initCode);
        assertEq(deployed, predictedTransceiver, "the transceiver landed where predicted");

        SaltedTransceiver t = SaltedTransceiver(payable(deployed));
        t.initialize(owner, address(new MiniTransmitter()), impl);

        address receiver = t.bootstrapFor(ownerOf);
        assertEq(receiver, predictedReceiver, "and so did its receiver");
        assertTrue(receiver.code.length > 0);
    }

    /// @dev The two sides agree on the salt convention. The registry writes
    ///      `keccak256(abi.encode(ownerOf, bytes32(0)))` out by hand because it runs on Ethereum
    ///      and the transceiver runs on the destination; if those drift, every predicted
    ///      receiver address is wrong and nothing says so until a payload is pinned to one.
    function test_theReceiverSaltMatchesTheTransceiversOwn() public {
        bytes memory initCode = type(SaltedTransceiver).creationCode;
        address impl = address(new SaltedReceiver());
        _record(keccak256(initCode), _crossProxyInitCodeHash());

        SaltedTransceiver t = SaltedTransceiver(payable(factory.deploy(SALT, initCode)));
        t.initialize(owner, address(new MiniTransmitter()), impl);

        address ownerOf = address(0x7A11);
        assertEq(t.accountSalt(ownerOf, bytes32(0), home()), keccak256(abi.encode(ownerOf, bytes32(0), home())));
        assertEq(
            registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0), ChainKey.forEvm(1)),
            t.predictCrossAccount(ownerOf, bytes32(0), home()),
            "one salt convention, two chains"
        );
    }

    /// @dev One salt, one address everywhere. This is the property the whole
    ///      default-counterpart argument rests on, now stated as inputs rather than
    ///      assumed from a local deployment.
    function test_oneSaltGivesOneAddressOnEveryParityChain() public {
        _record(keccak256("initcode"), keccak256("receiver"));

        vm.startPrank(owner);
        bytes32 arb = registry.addChainKey(Erc7930.encodeEvmChain(42161), Provenance.Derived);
        registry.setCreate2Factory(arb, address(factory));
        vm.stopPrank();

        assertEq(
            registry.predictTransceiver(chainKey, provider),
            registry.predictTransceiver(arb, provider),
            "the same salt lands on the same address"
        );
    }

    /// @dev The goal, end to end. The transceiver itself is a `CrossProxy`, deployed from
    ///      one initcode at one salt, so it is the same address on Ethereum and on Base. An
    ///      owner's account then derives from that shared address, so their transmitter at
    ///      home and their receiver elsewhere land on one address too.
    function test_anOwnerHasOneAddressOnBothSides() public {
        address ownerOf = address(0x7A11);
        _record(keccak256(type(CrossProxy).creationCode), _crossProxyInitCodeHash());

        address transceiverAt = registry.predictTransceiver(chainKey, provider);
        address predicted = registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0), ChainKey.forEvm(1));

        uint256 world = vm.snapshotState();

        // ---- a destination: the transceiver arms the account with receiver logic ----
        address destinationAt = factory.deploy(SALT, type(CrossProxy).creationCode);
        assertEq(destinationAt, transceiverAt, "every chain's transceiver shares an address");
        factory.arm(
            destinationAt,
            address(new SaltedTransceiver()),
            abi.encodeCall(
                SaltedTransceiver.initialize, (owner, address(new MiniTransmitter()), address(new SaltedReceiver()))
            )
        );

        address receiver = SaltedTransceiver(payable(destinationAt)).bootstrapFor(ownerOf);
        assertEq(receiver, predicted, "the receiver is where Ethereum said");
        assertEq(SaltedReceiver(payable(receiver)).sourceTransmitter(), predicted, "and its peer is that same address");

        vm.revertToState(world);

        // ---- Ethereum: the same address arms the account with transmitter logic ----
        // The receiver above is homed on chain 1, and an account's home is part of its
        // address, so its home transceiver has to actually run there.
        vm.chainId(1);
        address at = factory.deploy(SALT, type(CrossProxy).creationCode);
        factory.arm(
            at,
            address(new SaltedTransceiver()),
            abi.encodeCall(
                SaltedTransceiver.initialize, (owner, address(new MiniTransmitter()), address(new SaltedReceiver()))
            )
        );

        vm.prank(ownerOf);
        address transmitter = SaltedTransceiver(payable(at)).createTransmitter(bytes32(0));

        assertEq(transmitter, predicted, "the transmitter occupies the address its receivers do");
        assertEq(MiniTransmitter(transmitter).owner(), ownerOf, "and it is theirs");
    }

    /// @dev The salt buys more than one account per owner (one per purpose, per
    ///      counterparty, per mandate), and each keeps the one-address-everywhere property
    ///      independently.
    function test_oneOwnerCanHoldSeveralAccounts() public {
        _record(keccak256(type(CrossProxy).creationCode), _crossProxyInitCodeHash());
        address ownerOf = address(0x7A11);

        address a = registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0), ChainKey.forEvm(1));
        address b = registry.predictCrossAccount(chainKey, provider, ownerOf, keccak256("ops"), ChainKey.forEvm(1));

        assertTrue(a != b, "a different salt is a different account");

        // Each is still the same address on every parity chain.
        vm.startPrank(owner);
        bytes32 arb = registry.addChainKey(Erc7930.encodeEvmChain(42161), Provenance.Derived);
        registry.setCreate2Factory(arb, address(factory));
        vm.stopPrank();

        assertEq(a, registry.predictCrossAccount(arb, provider, ownerOf, bytes32(0), ChainKey.forEvm(1)));
        assertEq(b, registry.predictCrossAccount(arb, provider, ownerOf, keccak256("ops"), ChainKey.forEvm(1)));
    }

    /// @dev One owner's salt cannot reach another owner's account. The owner is hashed in,
    ///      so there is no choice of salt that lands on somebody else's address.
    function testFuzz_theOwnerIsAlwaysPartOfTheSalt(address ownerA, address ownerB, bytes32 saltA, bytes32 saltB)
        public
    {
        vm.assume(ownerA != address(0) && ownerB != address(0));
        vm.assume(ownerA != ownerB);
        _record(keccak256(type(CrossProxy).creationCode), _crossProxyInitCodeHash());

        assertTrue(
            registry.predictCrossAccount(chainKey, provider, ownerA, saltA, ChainKey.forEvm(1))
                != registry.predictCrossAccount(chainKey, provider, ownerB, saltB, ChainKey.forEvm(1)),
            "different owners, different accounts, whatever salt either picks"
        );
    }

    /// @dev The same owner and salt homed on two chains are two accounts. Without the home
    ///      in the salt, the transmitter of one would sit where the other's receiver lands.
    ///      The home is its own field, so no choice of the two salts makes them collide.
    function testFuzz_theHomeIsAlwaysPartOfTheSalt(
        address ownerOf,
        bytes32 saltA,
        bytes32 saltB,
        uint64 homeA,
        uint64 homeB
    ) public {
        vm.assume(ownerOf != address(0));
        vm.assume(homeA != 0 && homeB != 0 && homeA != homeB);
        _record(keccak256(type(CrossProxy).creationCode), _crossProxyInitCodeHash());

        assertTrue(
            registry.predictCrossAccount(chainKey, provider, ownerOf, saltA, ChainKey.forEvm(homeA))
                != registry.predictCrossAccount(chainKey, provider, ownerOf, saltB, ChainKey.forEvm(homeB)),
            "two homes, two accounts, whatever salts the owner picks"
        );
    }

    /// @dev A transceiver's chain is an immutable of its implementation, read when that is
    ///      deployed. A later change of `block.chainid`, as after a chain split, moves neither
    ///      the key nor where its transmitters land, including through the proxy.
    function test_theLocalChainKeyIsFixedAtDeployment() public {
        address at = factory.deploy(SALT, type(CrossProxy).creationCode);
        factory.arm(
            at,
            address(new SaltedTransceiver()),
            abi.encodeCall(
                SaltedTransceiver.initialize, (owner, address(new MiniTransmitter()), address(new SaltedReceiver()))
            )
        );
        SaltedTransceiver t = SaltedTransceiver(payable(at));
        bytes32 atInit = t.localChainKey();
        assertEq(atInit, ChainKey.local());

        address ownerOf = address(0x7A11);
        address predicted = t.predictTransmitter(ownerOf, bytes32(0));

        vm.chainId(block.chainid + 1);
        assertEq(t.localChainKey(), atInit, "the key did not follow the chain id");

        vm.prank(ownerOf);
        assertEq(t.createTransmitter(bytes32(0)), predicted, "and the account landed where it was predicted");
    }

    /// @dev The transceiver creates the caller's account, and `createTransmitter` binds the owner
    ///      to `msg.sender` rather than taking it as an argument.
    function test_createTransmitterUsesTheCallerAndTheirSalt() public {
        address at = factory.deploy(SALT, type(CrossProxy).creationCode);
        factory.arm(
            at,
            address(new SaltedTransceiver()),
            abi.encodeCall(
                SaltedTransceiver.initialize, (owner, address(new MiniTransmitter()), address(new SaltedReceiver()))
            )
        );
        SaltedTransceiver t = SaltedTransceiver(payable(at));

        address ownerOf = address(0x7A11);
        bytes32 userSalt = keccak256("treasury");

        address predicted = t.predictTransmitter(ownerOf, userSalt);

        vm.prank(ownerOf);
        assertEq(t.createTransmitter(userSalt), predicted, "where the view said");
        assertEq(MiniTransmitter(predicted).owner(), ownerOf);

        // A second account for the same owner, under a different salt.
        vm.prank(ownerOf);
        address second = t.createTransmitter(bytes32(0));
        assertTrue(second != predicted);
    }

    /* ================================== mining ================================= */

    /// @dev The reason the salt is stored at all. A transceiver's address is fixed for the
    ///      life of the protocol and appears in calldata forever after: peer tables,
    ///      payload targets, every receiver derived from it. Calldata zero bytes cost 4 gas
    ///      against 16, so a salt ground for leading zeros is a permanent discount.
    ///      Recording the salt is what makes the mined address reproducible here.
    function test_aSaltCanBeMinedForLeadingZeroBytes() public {
        bytes32 initCodeHash = keccak256(type(SaltedTransceiver).creationCode);

        bytes32 mined;
        for (uint256 i = 1; i < 4096; ++i) {
            bytes32 candidate = bytes32(i);
            address a = AddressDerive.create2(address(factory), candidate, initCodeHash);
            if (uint160(a) >> 152 == 0) {
                mined = candidate;
                break;
            }
        }
        assertTrue(mined != bytes32(0), "a leading zero byte is findable by search");

        _record(initCodeHash, keccak256("receiver"));
        vm.prank(owner);
        // The mined salt is what gets recorded; the registry reproduces its address.
        ChainRegistry r2 = _freshRegistryWith(mined, initCodeHash);
        address predicted = r2.predictTransceiver(chainKey, provider);
        assertEq(uint160(predicted) >> 152, 0, "the recorded salt keeps the mined shape");
    }

    /* ================================== guards ================================= */

    function test_aProviderWithNoRecordCannotBePredicted() public {
        vm.expectRevert(ChainRegistry.NoProviderDeployment.selector);
        registry.predictTransceiver(chainKey, provider);
    }

    /// @dev The derivation is only honest where the formula holds. zkSync and Tron are
    ///      `eip155` with different CREATE2 formulas, and their provenance cap is what
    ///      excludes them.
    function test_aChainCappedBelowDerivedIsNotPredicted() public {
        _record(keccak256("initcode"), keccak256("receiver"));

        vm.startPrank(owner);
        bytes32 zk = registry.addChainKey(Erc7930.encodeEvmChain(324), Provenance.Attested);
        vm.stopPrank();

        vm.expectRevert(ChainRegistry.NoCounterpart.selector);
        registry.predictTransceiver(zk, provider);
    }

    function test_aNonEvmChainIsNotPredicted() public {
        _record(keccak256("initcode"), keccak256("receiver"));

        vm.prank(owner);
        bytes32 sol =
            registry.addChainKey(Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708"), Provenance.Unresolved);

        vm.expectRevert(ChainRegistry.NoCounterpart.selector);
        registry.predictTransceiver(sol, provider);
    }

    /// @dev Write-once, because changing it moves every address derived from it: the
    ///      transceiver on every chain and every receiver under all of them.
    function test_theRecordCannotBeRepointed() public {
        _record(keccak256("initcode"), keccak256("receiver"));

        vm.prank(owner);
        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.setProviderDeployment(provider, keccak256("other"), keccak256("initcode"), keccak256("receiver"));

        // Re-writing the identical record is a no-op, not a failure.
        _record(keccak256("initcode"), keccak256("receiver"));
        assertEq(registry.providerDeployment(provider).salt, SALT);
    }

    function test_zeroInputsAreRefused() public {
        vm.startPrank(owner);
        vm.expectRevert(ChainRegistry.ZeroSalt.selector);
        registry.setProviderDeployment(provider, bytes32(0), keccak256("a"), keccak256("b"));

        vm.expectRevert(ChainRegistry.ZeroInitCodeHash.selector);
        registry.setProviderDeployment(provider, SALT, bytes32(0), keccak256("b"));
        vm.stopPrank();
    }

    /* ========================= the recorded derivation ========================= */

    /// @dev A recorded deployment states its inputs rather than assuming parity. A
    ///      transceiver's own fallback (its own address, on a chain graded `Derived`) reaches
    ///      the same answer by assuming the remote deployment matches the local one. This
    ///      reaches it by arithmetic over a factory, salt, and initcode hash that sat in the
    ///      signed calldata that recorded them, and it works before any transceiver exists.
    ///      The zkSync and Tron variants derive their default counterpart from it.
    function test_theRecordedDerivationStatesItsInputs() public {
        _record(keccak256(type(SaltedTransceiver).creationCode), keccak256("receiver"));

        assertEq(
            registry.predictTransceiver(chainKey, provider),
            AddressDerive.create2(
                registry.create2Factory(chainKey), SALT, keccak256(type(SaltedTransceiver).creationCode)
            ),
            "arithmetic over the recorded inputs, not a local address"
        );
    }

    /* ================================== helpers ================================ */

    function _freshRegistryWith(bytes32 salt, bytes32 initCodeHash) internal returns (ChainRegistry r) {
        r = new ChainRegistry(owner);
        vm.startPrank(owner);
        r.addMessageProvider("layerzero");
        r.addChainKey(Erc7930.encodeEvmChain(8453), Provenance.Derived);
        r.setCreate2Factory(chainKey, address(factory));
        r.setProviderDeployment(provider, salt, initCodeHash, keccak256("receiver"));
        vm.stopPrank();
    }
}

/// @dev A transceiver on a chain whose address formula differs from Ethereum's, as zkSync's
///      and Tron's do, emulated on Forge's EVM by transforming the salt in both seams.
contract DivergingSaltedTransceiver is SaltedTransceiver {
    /// @dev Like the zkSync and Tron variants, it declares that it diverges.
    function _diverges() internal pure override returns (bool) {
        return true;
    }

    function predictCrossAccount(address owner_, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override
        returns (address)
    {
        return Create2.computeAddress(
            _diverge(accountSalt(owner_, salt, homeChainKey)), CROSS_PROXY_INIT_CODE_HASH, address(this)
        );
    }

    function _deployAccount(bytes32 salt) internal override returns (address) {
        return Create2.deploy(0, _diverge(salt), type(CrossProxy).creationCode);
    }

    function _diverge(bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(salt, "diverge"));
    }
}

/// @dev Where the receiver's address is not its transmitter's, it must authenticate the
///      transmitter at home rather than itself (#13).
contract DivergentReceiverAuthTest is Test {
    address ownerOf = address(0x7A11);
    DivergingSaltedTransceiver t;
    ReceiverBase receiver;
    address homeTransmitter;

    function setUp() public {
        t = new DivergingSaltedTransceiver();
        t.initialize(address(this), address(new MiniTransmitter()), address(new SaltedReceiver()));
        receiver = ReceiverBase(payable(t.bootstrapFor(ownerOf)));
        // The home transceiver deploys with Ethereum's CREATE2, at this fixture's own address.
        homeTransmitter = Create2.computeAddress(
            t.accountSalt(ownerOf, bytes32(0), home()), t.CROSS_PROXY_INIT_CODE_HASH(), address(t)
        );
    }

    function test_theReceiverAuthenticatesTheHomeTransmitter() public view {
        assertTrue(address(receiver) != homeTransmitter, "the addresses diverge");
        assertEq(receiver.sourceTransmitter(), homeTransmitter, "the transmitter the bootstrap carried");
    }

    function test_aMessageFromTheHomeTransmitterIsAccepted() public {
        receiver.receiveMessage(bytes32(0), Erc7930.encodeEvm(1, homeTransmitter), Payload.encodeCalls(new Call[](0)));
    }

    function test_aMessageFromTheReceiversOwnAddressIsRefused() public {
        bytes memory sender = Erc7930.encodeEvm(1, address(receiver));
        vm.expectRevert(abi.encodeWithSelector(ReceiverBase.SenderIsNotThisAccount.selector, sender));
        receiver.receiveMessage(bytes32(0), sender, Payload.encodeCalls(new Call[](0)));
    }
}
