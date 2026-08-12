// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ChainRegistry, ProviderDeployment} from "src/registry/ChainRegistry.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {SpokeTransceiverBase} from "src/messaging/transceiver/spoke/SpokeTransceiverBase.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {Call} from "src/messaging/Call.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";

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
    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
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

/// @dev A hub deployed from the SAME initcode as the spoke, so both land on one address.
contract HubForAccounts is HubTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_, address impl) external initializer {
        __Ownable_init(owner_);
        __HubTransceiverBase_init(owner_, impl);
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

/// @dev A SPOKE, because receivers are made on the spoke side. A hub has no
///      `createReceiver` to call at all.
contract SaltedTransceiver is SpokeTransceiverBase, OwnableUpgradeable {
    function initialize(address owner_, address impl) external initializer {
        __Ownable_init(owner_);
        __SpokeTransceiverBase_init(
            owner_,
            impl,
            ChainKey.forEvm(1),
            Erc7930.encodeEvmChain(1),
            abi.encodePacked(address(0xB0BB1E)),
            false
        );
    }


    /// @dev Stands in for `_onInbound`, which authenticates and then self-calls.
    function bootstrapFor(address owner_) external returns (address) {
        this.bootstrapInbound(owner_, bytes32(0), new Call[](0));
        return predictCrossAccount(owner_, bytes32(0));
    }

    /// @dev A HARNESS TRUSTS ANY GATEWAY, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }

}

/// @dev A transmitter that answers `owner()`, which is how `createReceiver` decides who
///      may stand a receiver up.
contract OwnedTransmitter {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @notice A provider's salt makes its transceiver (and every receiver under it)
///         computable on the hub before either exists.
contract SaltedDeploymentTest is Test {
    ChainRegistry registry;
    MiniFactory factory;

    address owner = address(0xA11CE);
    bytes32 provider;
    bytes32 chainKey;

    bytes32 constant SALT = keccak256("crossecute.lz.v1");

    function setUp() public {
        registry = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (owner))
                )
            )
        );
        factory = new MiniFactory();

        vm.startPrank(owner);
        provider = registry.addMessageProvider("layerzero");
        chainKey = registry.addChainKey(Erc7930.encodeEvmChain(8453));
        registry.setCreate2Factory(chainKey, address(factory));
        vm.stopPrank();
    }

    /// @dev ONE CONSTANT, INDEPENDENT OF THE IMPLEMENTATION. `CrossProxy` takes no
    ///      constructor arguments, so every account (transmitter or receiver, on any
    ///      chain) deploys from this exact byte string. That independence is what lets
    ///      two accounts with different logic share an address; an EIP-1167 clone bakes
    ///      the implementation into its initcode and could never manage it.
    function _crossProxyInitCodeHash() internal pure returns (bytes32) {
        return keccak256(type(CrossProxy).creationCode);
    }

    function _record(bytes32 transceiverInitCodeHash, bytes32 receiverInitCodeHash)
        internal
    {
        vm.prank(owner);
        registry.setProviderDeployment(
            provider, SALT, transceiverInitCodeHash, receiverInitCodeHash
        );
    }

    /* ============================== the whole chain ============================= */

    /// @dev THE LOAD-BEARING TEST. Ethereum predicts the transceiver from a recorded salt,
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
            registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0));

        // Nothing is deployed yet.
        assertEq(predictedTransceiver.code.length, 0);
        assertEq(predictedReceiver.code.length, 0);

        // Now deploy for real, through the factory, with that salt.
        address deployed = factory.deploy(SALT, initCode);
        assertEq(deployed, predictedTransceiver, "the transceiver landed where predicted");

        SaltedTransceiver t = SaltedTransceiver(payable(deployed));
        t.initialize(owner, impl);

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
        t.initialize(owner, impl);

        address ownerOf = address(0x7A11);
        assertEq(t.accountSalt(ownerOf, bytes32(0)), keccak256(abi.encode(ownerOf, bytes32(0))));
        assertEq(
            registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0)),
            t.predictCrossAccount(ownerOf, bytes32(0)),
            "one salt convention, two chains"
        );
    }

    /// @dev One salt, one address everywhere. This is the property the whole
    ///      default-counterpart argument rests on, now stated as inputs rather than
    ///      assumed from a local deployment.
    function test_oneSaltGivesOneAddressOnEveryParityChain() public {
        _record(keccak256("initcode"), keccak256("receiver"));

        vm.startPrank(owner);
        bytes32 arb = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        registry.setCreate2Factory(arb, address(factory));
        vm.stopPrank();

        assertEq(
            registry.predictTransceiver(chainKey, provider),
            registry.predictTransceiver(arb, provider),
            "the same salt lands on the same address"
        );
    }

    /// @dev THE GOAL, END TO END. The transceiver itself is an `CrossProxy`, deployed
    ///      from one initcode at one salt, so the hub on Ethereum and the spoke on Base
    ///      are the same address, and they differ only in the logic each is armed with.
    ///      An owner's account then derives from that shared address, so their transmitter
    ///      and their receiver land on one address too.
    function test_anOwnerHasOneAddressOnBothSides() public {
        address ownerOf = address(0x7A11);
        _record(keccak256(type(CrossProxy).creationCode), _crossProxyInitCodeHash());

        address transceiverAt = registry.predictTransceiver(chainKey, provider);
        address predicted = registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0));

        uint256 world = vm.snapshotState();

        // ---- destination chain: the spoke arms the account with receiver logic ----
        address spokeAt = factory.deploy(SALT, type(CrossProxy).creationCode);
        assertEq(spokeAt, transceiverAt, "hub and spoke share an address");
        factory.arm(
            spokeAt,
            address(new SaltedTransceiver()),
            abi.encodeCall(SaltedTransceiver.initialize, (owner, address(new SaltedReceiver())))
        );

        address receiver = SaltedTransceiver(payable(spokeAt)).bootstrapFor(ownerOf);
        assertEq(receiver, predicted, "the receiver is where Ethereum said");
        assertEq(
            SaltedReceiver(payable(receiver)).sourceTransmitter(),
            predicted,
            "and its peer is that same address"
        );

        vm.revertToState(world);

        // ---- Ethereum: the hub arms the SAME address with transmitter logic ----
        address hubAt = factory.deploy(SALT, type(CrossProxy).creationCode);
        factory.arm(
            hubAt,
            address(new HubForAccounts()),
            abi.encodeCall(HubForAccounts.initialize, (owner, address(new MiniTransmitter())))
        );

        vm.prank(ownerOf);
        address transmitter = HubForAccounts(payable(hubAt)).createTransmitter(bytes32(0));

        assertEq(
            transmitter, predicted, "the transmitter occupies the address its receivers do"
        );
        assertEq(MiniTransmitter(transmitter).owner(), ownerOf, "and it is theirs");
    }

    /// @dev THE SALT BUYS MORE THAN ONE ACCOUNT PER OWNER (one per purpose, per
    ///      counterparty, per mandate), and each keeps the one-address-everywhere property
    ///      independently.
    function test_oneOwnerCanHoldSeveralAccounts() public {
        _record(keccak256(type(CrossProxy).creationCode), _crossProxyInitCodeHash());
        address ownerOf = address(0x7A11);

        address a = registry.predictCrossAccount(chainKey, provider, ownerOf, bytes32(0));
        address b = registry.predictCrossAccount(chainKey, provider, ownerOf, keccak256("ops"));

        assertTrue(a != b, "a different salt is a different account");

        // Each is still the same address on every parity chain.
        vm.startPrank(owner);
        bytes32 arb = registry.addChainKey(Erc7930.encodeEvmChain(42161));
        registry.setCreate2Factory(arb, address(factory));
        vm.stopPrank();

        assertEq(a, registry.predictCrossAccount(arb, provider, ownerOf, bytes32(0)));
        assertEq(b, registry.predictCrossAccount(arb, provider, ownerOf, keccak256("ops")));
    }

    /// @dev ONE OWNER'S SALT CANNOT REACH ANOTHER OWNER'S ACCOUNT. The pair is hashed, so
    ///      there is no choice of salt that lands on somebody else's address.
    function testFuzz_theOwnerIsAlwaysPartOfTheSalt(
        address ownerA,
        address ownerB,
        bytes32 saltA,
        bytes32 saltB
    ) public {
        vm.assume(ownerA != address(0) && ownerB != address(0));
        vm.assume(ownerA != ownerB);
        _record(keccak256(type(CrossProxy).creationCode), _crossProxyInitCodeHash());

        assertTrue(
            registry.predictCrossAccount(chainKey, provider, ownerA, saltA)
                != registry.predictCrossAccount(chainKey, provider, ownerB, saltB),
            "different owners, different accounts, whatever salt either picks"
        );
    }

    /// @dev The hub creates the caller's account, and `createTransmitter` binds the owner
    ///      to `msg.sender` rather than taking it as an argument.
    function test_createTransmitterUsesTheCallerAndTheirSalt() public {
        address hubAt = factory.deploy(SALT, type(CrossProxy).creationCode);
        factory.arm(
            hubAt,
            address(new HubForAccounts()),
            abi.encodeCall(HubForAccounts.initialize, (owner, address(new MiniTransmitter())))
        );
        HubForAccounts hub = HubForAccounts(payable(hubAt));

        address ownerOf = address(0x7A11);
        bytes32 userSalt = keccak256("treasury");

        address predicted = hub.predictTransmitter(ownerOf, userSalt);

        vm.prank(ownerOf);
        assertEq(hub.createTransmitter(userSalt), predicted, "where the view said");
        assertEq(MiniTransmitter(predicted).owner(), ownerOf);

        // A second account for the same owner, under a different salt.
        vm.prank(ownerOf);
        address second = hub.createTransmitter(bytes32(0));
        assertTrue(second != predicted);
    }

    /* ================================== mining ================================= */

    /// @dev THE REASON THE SALT IS STORED AT ALL. A transceiver's address is fixed for the
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
        bytes32 zk = registry.addChainKey(Erc7930.encodeEvmChain(324));
        registry.setProvenance(zk, Provenance.Attested);
        vm.stopPrank();

        vm.expectRevert(ChainRegistry.NoCounterpart.selector);
        registry.predictTransceiver(zk, provider);
    }

    function test_aNonEvmChainIsNotPredicted() public {
        _record(keccak256("initcode"), keccak256("receiver"));

        vm.prank(owner);
        bytes32 sol = registry.addChainKey(
            Erc7930.encodeChainId(ChainType.SOLANA, hex"0102030405060708")
        );

        vm.expectRevert(ChainRegistry.NoCounterpart.selector);
        registry.predictTransceiver(sol, provider);
    }

    /// @dev WRITE-ONCE, because changing it moves every address derived from it: the
    ///      transceiver on every chain and every receiver under all of them.
    function test_theRecordCannotBeRepointed() public {
        _record(keccak256("initcode"), keccak256("receiver"));

        vm.prank(owner);
        vm.expectRevert(ChainRegistry.AlreadySet.selector);
        registry.setProviderDeployment(
            provider, keccak256("other"), keccak256("initcode"), keccak256("receiver")
        );

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

    /// @dev A RECORDED DEPLOYMENT STATES ITS INPUTS RATHER THAN ASSUMING PARITY. The hub's
    ///      own fallback (its own address, on a chain graded `Derived`) reaches the same
    ///      answer by assuming the remote deployment matches the local one; this reaches it
    ///      by arithmetic over a factory, salt, and initcode hash that sat in the signed
    ///      calldata that recorded them, and it works before a hub exists at all. A deploy
    ///      script computes it here and writes it with `HubTransceiverBase.setCounterpart`.
    function test_theRecordedDerivationStatesItsInputs() public {
        _record(keccak256(type(SaltedTransceiver).creationCode), keccak256("receiver"));

        assertEq(
            registry.predictTransceiver(chainKey, provider),
            AddressDerive.create2(
                registry.create2Factory(chainKey),
                SALT,
                keccak256(type(SaltedTransceiver).creationCode)
            ),
            "arithmetic over the recorded inputs, not a local address"
        );
    }

    /* ================================== helpers ================================ */

    function _freshRegistryWith(bytes32 salt, bytes32 initCodeHash)
        internal
        returns (ChainRegistry r)
    {
        r = ChainRegistry(
            address(
                new ERC1967Proxy(
                    address(new ChainRegistry()),
                    abi.encodeCall(ChainRegistry.initialize, (owner))
                )
            )
        );
        vm.startPrank(owner);
        r.addMessageProvider("layerzero");
        r.addChainKey(Erc7930.encodeEvmChain(8453));
        r.setCreate2Factory(chainKey, address(factory));
        r.setProviderDeployment(provider, salt, initCodeHash, keccak256("receiver"));
        vm.stopPrank();
    }
}
