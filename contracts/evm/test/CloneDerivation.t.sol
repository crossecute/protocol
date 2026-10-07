// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Test} from "forge-std/Test.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VmDeriver} from "src/derivation/VmDeriver.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {TransceiverBase, TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {DivergentAccounts} from "src/messaging/transceiver/DivergentAccounts.sol";
import {LzTransceiver} from "src/protocols/layerzero/LzTransceiver.sol";
import {LzZkSyncTransceiver, LzTronTransceiver} from "src/protocols/layerzero/LzDivergentTransceiver.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {UnsendableTransceiver} from "test/Unsendable.sol";

/// @dev Something with code, to clone.
contract Impl {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Predicting a receiver address on a destination chain. Receivers are EIP-1167
///         clones, so this is what closes the gap between "we know where the transceiver
///         is" and "we know where the receiver will be".
contract CloneDerivationTest is Test {
    VmDeriver deriver;
    Impl impl;

    function setUp() public {
        deriver = new VmDeriver();
        impl = new Impl();
    }

    /// @dev The load-bearing check. The 55-byte EIP-1167 layout is hardcoded in
    ///      `AddressDerive.cloneInitCodeHash`. If OpenZeppelin's proxy bytecode ever differs
    ///      from it (including a future optimized variant) every predicted receiver
    ///      address is silently wrong. So it is checked against OZ, not against itself.
    function test_cloneInitCodeHashMatchesOpenZeppelin() public view {
        bytes32 salt = keccak256("transmitter-x");
        address ozPredicted = Clones.predictDeterministicAddress(address(impl), salt, address(this));
        address ours = AddressDerive.clone2(address(this), address(impl), salt);
        assertEq(ours, ozPredicted, "clone initcode layout must match OZ");
    }

    /// @dev And against a clone that actually exists, not just against OZ's own math.
    function test_matchesAnActuallyDeployedClone() public {
        bytes32 salt = keccak256("transmitter-y");
        address deployed = Clones.cloneDeterministic(address(impl), salt);
        assertEq(AddressDerive.clone2(address(this), address(impl), salt), deployed);
        assertEq(Impl(deployed).ping(), 1, "the clone is live");
    }

    /// @dev Ethereum predicting a receiver on Base, with no message and no bridge trust.
    function test_evmCloneThroughDeriver() public view {
        address destTransceiver = address(0x7BAD);
        address destReceiverImpl = address(0xBEEF);
        bytes32 salt = keccak256(abi.encode(address(0x7A11))); // receiverSalt(transmitter)

        bytes memory params = abi.encode(VmDeriver.Scheme.EvmClone, abi.encode(destTransceiver, destReceiverImpl, salt));
        bytes memory interop = deriver.deriveAddress(Erc7930.encodeEvmChain(8453), params);

        assertEq(
            Erc7930.toAddress(Erc7930.parseStrict(interop)),
            AddressDerive.clone2(destTransceiver, destReceiverImpl, salt)
        );
    }

    /// @dev Same inputs, different domain byte: Tron must not collide with Ethereum.
    function test_tronCloneDiffersFromEvmClone() public view {
        address destTransceiver = address(0x7BAD);
        address destReceiverImpl = address(0xBEEF);
        bytes32 salt = keccak256("s");

        bytes memory inner = abi.encode(destTransceiver, destReceiverImpl, salt);
        bytes memory tronChain = Erc7930.encodeEvmChain(728126428);

        bytes memory evmOut =
            deriver.deriveAddress(Erc7930.encodeEvmChain(1), abi.encode(VmDeriver.Scheme.EvmClone, inner));
        bytes memory tronOut = deriver.deriveAddress(tronChain, abi.encode(VmDeriver.Scheme.TronClone, inner));

        assertTrue(
            Erc7930.toAddress(Erc7930.parseStrict(evmOut)) != Erc7930.toAddress(Erc7930.parseStrict(tronOut)),
            "0x41 vs 0xff must produce different addresses"
        );
        assertEq(
            Erc7930.toAddress(Erc7930.parseStrict(tronOut)),
            AddressDerive.tronCreate2(destTransceiver, salt, AddressDerive.cloneInitCodeHash(destReceiverImpl))
        );
    }

    /// @dev Clones are an EVM construct. EraVM only deploys bytecode whose hash has been
    ///      published, and a 55-byte EVM proxy is not valid EraVM bytecode: a zkSync
    ///      "clone" is a real zksolc proxy, derived with `ZkSyncCreate2` instead.
    function test_cloneSchemesAreEvmOnly() public view {
        assertTrue(deriver.supportsScheme(ChainType.EIP155, uint8(VmDeriver.Scheme.EvmClone)));
        assertTrue(deriver.supportsScheme(ChainType.EIP155, uint8(VmDeriver.Scheme.TronClone)));
        assertFalse(deriver.supportsScheme(ChainType.SOLANA, uint8(VmDeriver.Scheme.EvmClone)));
        assertFalse(deriver.supportsScheme(ChainType.SUI, uint8(VmDeriver.Scheme.EvmClone)));
        assertFalse(deriver.supportsScheme(ChainType.STARKNET, uint8(VmDeriver.Scheme.EvmClone)));
    }

    function test_cloneInitCodeHashIsExposed() public view {
        assertEq(deriver.cloneInitCodeHash(address(impl)), AddressDerive.cloneInitCodeHash(address(impl)));
    }
}

/// @dev A transceiver on a chain whose CREATE2 formula differs from Ethereum's: zkSync and
///      Tron are `eip155`, so nothing about the chain type separates them, and only the
///      transceiver itself knows. Both seams must be overridden together, and this is what happens when
///      they are not.
contract DivergingFormulaTransceiver is UnsendableTransceiver {
    /// Stands in for a chain-specific derivation: any answer other than Ethereum's.
    bool public overridePrediction;

    /// @dev `create` makes an account homed here, so `impl` is the transmitter logic.
    function initialize(address impl) external initializer {
        TransceiverConfig memory c = config(impl);
        c.transmitterImplementation = impl;
        __TransceiverBase_init(c);
    }

    function setOverridePrediction(bool v) external {
        overridePrediction = v;
    }

    function predictCrossAccount(address owner, bytes32 salt, bytes32 homeChainKey)
        public
        view
        override
        returns (address)
    {
        if (!overridePrediction) return super.predictCrossAccount(owner, salt, homeChainKey);
        // A different formula, standing in for zkSync's `zksyncCreate2` hash chain or
        // Tron's prefix. `_deployAccount` is deliberately not overridden to match.
        return address(uint160(uint256(keccak256(abi.encode("other", owner, salt)))));
    }

    function create(address owner, bytes32 salt) external returns (address) {
        return _createCrossAccount(owner, salt, localChainKey, address(0), new Call[](0));
    }

    /// @dev `MinimalAccount` takes no arguments.
    function _accountInitializer(address, bytes32, bytes32, address, Call[] memory)
        internal
        pure
        override
        returns (bytes memory)
    {
        return "";
    }

    /// @dev A harness trusts any gateway, which no deployment may do. Overriding the
    ///      membership read rather than granting a role keeps each test on its own subject.
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return role == GATEWAY_ROLE || super.hasRole(role, account);
    }
}

contract DivergingFormulaTest is Test {
    DivergingFormulaTransceiver t;
    address owner = address(0xA11CE);

    function setUp() public {
        t = new DivergingFormulaTransceiver();
        t.initialize(address(new MinimalAccount()));
    }

    /// @dev The parity path is untouched: prediction and deployment agree, so the guard
    ///      never fires and the account arms normally.
    function test_theParityPathIsUnaffected() public {
        address predicted = t.predictCrossAccount(owner, bytes32(0), t.localChainKey());
        assertEq(t.create(owner, bytes32(0)), predicted);
        assertTrue(predicted.code.length != 0, "armed");
    }

    /// @dev Overriding one seam and not the other is caught by name. Before the guard this
    ///      reverted anyway, but only because arming a codeless address trips Solidity's
    ///      `extcodesize` check, which carries no reason data at all.
    function test_aHalfOverriddenDerivationIsRefusedByName() public {
        t.setOverridePrediction(true);
        address predicted = t.predictCrossAccount(owner, bytes32(0), t.localChainKey());
        address wouldDeployTo = Create2.computeAddress(
            keccak256(abi.encode(owner, bytes32(0), t.localChainKey())), t.CROSS_PROXY_INIT_CODE_HASH(), address(t)
        );
        assertTrue(predicted != wouldDeployTo, "the two formulas disagree, by construction");

        vm.expectRevert(
            abi.encodeWithSelector(TransceiverBase.AccountAddressMismatch.selector, predicted, wouldDeployTo)
        );
        t.create(owner, bytes32(0));
    }

    /// @dev And the account is not left half-created: the whole call unwinds, so nothing
    ///      exists at either address and the bootstrap stays retryable.
    function test_aMismatchLeavesNothingBehind() public {
        t.setOverridePrediction(true);
        address wouldDeployTo = Create2.computeAddress(
            keccak256(abi.encode(owner, bytes32(0), t.localChainKey())), t.CROSS_PROXY_INIT_CODE_HASH(), address(t)
        );

        vm.expectRevert();
        t.create(owner, bytes32(0));

        assertEq(wouldDeployTo.code.length, 0, "no stranded proxy holding a live admin key");
        assertEq(t.predictCrossAccount(owner, bytes32(0), t.localChainKey()).code.length, 0);
    }
}

contract MinimalAccount {
    function initialize() external {}
}

/// @dev Where the accounts in these tests are homed: anywhere but this chain.
function home() pure returns (bytes32) {
    return ChainKey.forEvm(1);
}

function config(address receiverImplementation) pure returns (TransceiverConfig memory) {
    return TransceiverConfig({
        gateways: new address[](0),
        transmitterImplementation: address(0xBEEF),
        receiverImplementation: receiverImplementation,
        governorOwner: address(0x5165),
        governorSalt: bytes32(0),
        governorHome: Erc7930.encodeEvmChain(1),
        treasury: address(0x7EA5),
        chainRegistry: IChainRegistryRefs(address(0)),
        messageProvider: bytes32(0),
        minCounterpartProvenance: Provenance.Unknown
    });
}

/// @dev The shipped contracts, with one function added. Everything about initialization,
///      the divergence flag and the bytecode hash is inherited rather than restated, so
///      these exercise the initializer a deployment actually calls: a stand-in that
///      reimplemented it could pass while the real one was never wired to anything.
contract ZkHarness is LzZkSyncTransceiver {
    constructor(address _endpoint) LzZkSyncTransceiver(_endpoint) {}

    function create(address o, bytes32 s) external returns (address) {
        return _createCrossAccount(o, s, home(), address(0x7A11), new Call[](0));
    }
}

contract TronHarness is LzTronTransceiver {
    constructor(address _endpoint) LzTronTransceiver(_endpoint) {}
}

/// @dev What this suite can establish about a diverging transceiver, running on an Ethereum
///      EVM: that each override reproduces `AddressDerive`'s formula exactly, that it does not
///      reproduce Ethereum's, and that the guard refuses rather than arming nothing. What
///      it cannot establish is that the target chain's own deployer agrees. The formulas are
///      checked against Era's `ContractDeployer` and java-tron's source (deploy/CHECKS.md §1);
///      the real artifacts' hashes need a deployment on Era and Shasta.
contract DivergentTransceiverTest is Test {
    address owner = address(0xA11CE);

    bytes32 constant HASH = keccak256("zksolc-or-tronsolc-artifact");
    bytes32 constant SALT = bytes32(0);
    address ENDPOINT = address(new MockLzEndpoint());

    function _zk() internal returns (ZkHarness s) {
        s = new ZkHarness(ENDPOINT);
        s.initialize(config(address(new MinimalAccount())), 0, address(0), HASH);
    }

    function _tron() internal returns (TronHarness s) {
        s = new TronHarness(ENDPOINT);
        s.initialize(config(address(new MinimalAccount())), 0, address(0), HASH);
    }

    function testFuzz_zkSyncReproducesTheEraFormula(address o, bytes32 salt) public {
        vm.assume(o != address(0));
        ZkHarness s = _zk();
        assertEq(
            s.predictCrossAccount(o, salt, home()),
            AddressDerive.zksyncCreate2(address(s), s.accountSalt(o, salt, home()), HASH, keccak256(""))
        );
    }

    function testFuzz_tronReproducesTheTronFormula(address o, bytes32 salt) public {
        vm.assume(o != address(0));
        TronHarness s = _tron();
        assertEq(
            s.predictCrossAccount(o, salt, home()),
            AddressDerive.tronCreate2(address(s), s.accountSalt(o, salt, home()), HASH)
        );
    }

    /// @dev The whole point: neither answers what Ethereum's formula would.
    function test_neitherMatchesEthereum() public {
        ZkHarness z = _zk();
        TronHarness t = _tron();
        address ethZ =
            Create2.computeAddress(z.accountSalt(owner, SALT, home()), z.CROSS_PROXY_INIT_CODE_HASH(), address(z));
        address ethT =
            Create2.computeAddress(t.accountSalt(owner, SALT, home()), t.CROSS_PROXY_INIT_CODE_HASH(), address(t));
        assertTrue(z.predictCrossAccount(owner, SALT, home()) != ethZ, "zkSync diverges");
        assertTrue(t.predictCrossAccount(owner, SALT, home()) != ethT, "Tron diverges");
        assertTrue(
            z.predictCrossAccount(owner, SALT, home()) != t.predictCrossAccount(owner, SALT, home()),
            "and from each other"
        );
    }

    /// @dev On an Ethereum EVM both fail closed, which is the property that makes shipping
    ///      them before the on-chain check safe. The deployer here uses Ethereum's formula,
    ///      the prediction does not, and the guard names both halves.
    function test_bothFailClosedOnAnEthereumEvm() public {
        ZkHarness z = _zk();
        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.AccountAddressMismatch.selector,
                z.predictCrossAccount(owner, SALT, home()),
                Create2.computeAddress(z.accountSalt(owner, SALT, home()), z.CROSS_PROXY_INIT_CODE_HASH(), address(z))
            )
        );
        z.create(owner, SALT);
    }

    /// @dev Every argument is built before the cheatcode. `vm.expectRevert` applies to the
    ///      next call, and `new MinimalAccount()` is a call: left inline it consumes the
    ///      expectation and the test fails on the wrong line. The same trap catches
    ///      `vm.prank`, and it is silent whenever the pranked call happens to succeed.
    function test_theBytecodeHashIsWriteOnceAndNonZero() public {
        TransceiverConfig memory c = config(address(new MinimalAccount()));

        ZkHarness s = new ZkHarness(ENDPOINT);
        vm.expectRevert(DivergentAccounts.ZeroAccountBytecodeHash.selector);
        s.initialize(c, 0, address(0), bytes32(0));

        ZkHarness ok = _zk();
        assertEq(ok.accountBytecodeHash(), HASH);
        vm.expectRevert();
        ok.initialize(c, 0, address(0), keccak256("other"));
    }
}

/// @notice L1 -> L2 sender aliasing, which Arbitrum, zkSync Era and the OP Stack's
///         `OptimismPortal` all apply with the same constant.
///
/// @dev The round trip is the easy half. What these pin is the two properties that make the
///      undo direction dangerous to use: it wraps, so it cannot tell whether it was needed,
///      and it is not an involution, so applying it in the wrong direction is silent.
contract AddressAliasTest is Test {
    /// Arbitrum's `AddressAliasHelper.OFFSET`, verbatim.
    uint160 constant ARBITRUM_OFFSET = uint160(0x1111000000000000000000000000000000001111);

    function test_theOffsetIsArbitrums() public pure {
        assertEq(
            AddressDerive.applyL1ToL2Alias(address(0)), address(ARBITRUM_OFFSET), "same constant as AddressAliasHelper"
        );
    }

    function testFuzz_theTwoDirectionsRoundTrip(address l1) public pure {
        assertEq(AddressDerive.undoL1ToL2Alias(AddressDerive.applyL1ToL2Alias(l1)), l1);
        assertEq(AddressDerive.applyL1ToL2Alias(AddressDerive.undoL1ToL2Alias(l1)), l1);
    }

    /// @dev It wraps, which is why there is no "was this aliased" predicate. Undoing an
    ///      alias that was never applied returns a perfectly well-formed address rather than
    ///      reverting, so a binding that gets the direction wrong authenticates against a
    ///      value belonging to nobody and simply never matches.
    function testFuzz_undoingAnUnaliasedAddressIsSilent(address raw) public pure {
        address wrong = AddressDerive.undoL1ToL2Alias(raw);

        assertTrue(wrong != raw, "it moved");
        // And it is indistinguishable from a real answer: it round-trips like one.
        assertEq(AddressDerive.applyL1ToL2Alias(wrong), raw);
    }

    /// @dev Exactly one input undoes to zero, and it is the offset itself. Found by fuzzing
    ///      an assertion that no input did. It is worth pinning because it is the whole
    ///      extent of what a zero check on the result would buy: one address out of 2^160,
    ///      which is not a defence against getting the direction wrong.
    function test_onlyTheOffsetItselfUndoesToZero() public pure {
        assertEq(AddressDerive.undoL1ToL2Alias(address(ARBITRUM_OFFSET)), address(0), "the one case");
        assertTrue(AddressDerive.undoL1ToL2Alias(address(1)) != address(0));
    }

    function testFuzz_nothingElseUndoesToZero(address raw) public pure {
        vm.assume(raw != address(ARBITRUM_OFFSET));
        assertTrue(AddressDerive.undoL1ToL2Alias(raw) != address(0));
    }

    /// @dev And it is not an involution, so applying the same direction twice does not
    ///      cancel. This is what a symmetric binding would do to the L2 -> L1 path, where
    ///      the sender arrives unaliased.
    function testFuzz_applyingTwiceIsNotIdentity(address l1) public pure {
        address twice = AddressDerive.applyL1ToL2Alias(AddressDerive.applyL1ToL2Alias(l1));
        assertTrue(twice != l1, "double-aliasing is a different address");
    }

    /// @dev The case a binding actually faces. A transmitter at T on the home chain reaches
    ///      an L2 receiver as T + offset; `ReceiverBase` compares against `sourceTransmitter`,
    ///      which is T, so the binding must undo before handing the sender over.
    function testFuzz_itRecoversWhatReceiverBaseCompares(address transmitter) public pure {
        address asSeenOnL2 = AddressDerive.applyL1ToL2Alias(transmitter);
        assertTrue(asSeenOnL2 != transmitter, "the raw sender would not match");
        assertEq(AddressDerive.undoL1ToL2Alias(asSeenOnL2), transmitter);
    }
}

/// @dev `TransceiverConfig` as it was before #26.
struct ConfigWithFlag {
    address[] gateways;
    address transmitterImplementation;
    address receiverImplementation;
    address governorOwner;
    bytes32 governorSalt;
    bytes32 governorHome;
    address treasury;
    bool addressesDiverge;
}

/// @dev The flag and the formula cannot disagree, because neither is an argument any more.
///      A transceiver that reported divergence while deriving addresses Ethereum's way, or the
///      reverse, was the one state that cannot be right; picking the contract picks both.
contract DivergenceIsNotConfigurableTest is Test {
    address owner = address(0xA11CE);
    bytes32 constant HASH = keccak256("artifact");
    address ENDPOINT = address(new MockLzEndpoint());

    function _config() internal returns (TransceiverConfig memory) {
        return config(address(new MinimalAccount()));
    }

    /// @dev #26: the flag was a config field, so a plain transceiver could be initialized to
    ///      report every receiver while deriving Ethereum's way. The field is gone, and with it
    ///      the initializer that took it: the old shape, well formed, finds no function.
    function test_theParityTransceiverCannotBeToldToDiverge() public {
        LzTransceiver s = new LzTransceiver(ENDPOINT);
        TransceiverConfig memory c = _config();
        ConfigWithFlag memory old = ConfigWithFlag(
            c.gateways,
            c.transmitterImplementation,
            c.receiverImplementation,
            c.governorOwner,
            c.governorSalt,
            keccak256(c.governorHome),
            c.treasury,
            true
        );
        bytes4 withFlag =
            bytes4(keccak256("initialize((address[],address,address,address,bytes32,bytes32,address,bool))"));
        (bool ok,) = address(s).call(abi.encodeWithSelector(withFlag, old));
        assertFalse(ok, "no initializer takes the flag");

        s.initialize(_config(), 0, address(0));
        assertFalse(s.addressesDiverge());
        assertEq(
            s.predictCrossAccount(owner, bytes32(0), home()),
            Create2.computeAddress(
                s.accountSalt(owner, bytes32(0), home()), s.CROSS_PROXY_INIT_CODE_HASH(), address(s)
            ),
            "and it derives the way the home recomputes"
        );
    }

    /// @dev The variants set the flag themselves.
    function test_theDivergentTransceiversAlwaysReportDivergence() public {
        LzZkSyncTransceiver zk = new LzZkSyncTransceiver(ENDPOINT);
        zk.initialize(_config(), 0, address(0), HASH);
        LzTronTransceiver tron = new LzTronTransceiver(ENDPOINT);
        tron.initialize(_config(), 0, address(0), HASH);

        assertTrue(zk.addressesDiverge(), "set by the variant, and true");
        assertTrue(tron.addressesDiverge());
        assertEq(zk.accountBytecodeHash(), HASH, "the initializer wired it");
        assertEq(tron.accountBytecodeHash(), HASH);

        // And each derives its own way, not Ethereum's.
        address ethWay = Create2.computeAddress(
            zk.accountSalt(owner, bytes32(0), home()), zk.CROSS_PROXY_INIT_CODE_HASH(), address(zk)
        );
        assertTrue(zk.predictCrossAccount(owner, bytes32(0), home()) != ethWay);
    }

    /// @dev The bytecode hash has no setter, so a transceiver initialized without one cannot
    ///      acquire it later: the initializer refuses zero, which is the only way in.
    function test_thereIsNoSetterForTheBytecodeHash() public {
        LzZkSyncTransceiver zk = new LzZkSyncTransceiver(ENDPOINT);
        zk.initialize(_config(), 0, address(0), HASH);

        (bool ok,) = address(zk).call(abi.encodeWithSignature("setAccountBytecodeHash(bytes32)", keccak256("other")));
        assertFalse(ok, "no setter on the ABI");
    }
}
