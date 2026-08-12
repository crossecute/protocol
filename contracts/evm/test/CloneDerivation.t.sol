// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VmDeriver} from "src/derivation/VmDeriver.sol";
import {ChainType} from "src/addressing/ChainType.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {Call} from "src/messaging/Call.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {
    DivergentSpokeTransceiver,
    ZkSyncSpokeTransceiver,
    TronSpokeTransceiver
} from "src/messaging/transceiver/DivergentSpokeTransceiver.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @dev Something with code, to clone.
contract Impl {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Predicting a RECEIVER address on a destination chain. Receivers are EIP-1167
///         clones, so this is what closes the gap between "we know where the transceiver
///         is" and "we know where the receiver will be".
contract CloneDerivationTest is Test {
    VmDeriver deriver;
    Impl impl;

    function setUp() public {
        deriver = new VmDeriver();
        impl = new Impl();
    }

    /// @dev THE LOAD-BEARING CHECK. The 55-byte EIP-1167 layout is hardcoded in
    ///      `AddressDerive.cloneInitCodeHash`. If OpenZeppelin's proxy bytecode ever differs
    ///      from it (including a future optimized variant) every predicted receiver
    ///      address is silently wrong. So it is checked against OZ, not against itself.
    function test_cloneInitCodeHashMatchesOpenZeppelin() public {
        bytes32 salt = keccak256("transmitter-x");
        address ozPredicted =
            Clones.predictDeterministicAddress(address(impl), salt, address(this));
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

        bytes memory params = abi.encode(
            VmDeriver.Scheme.EvmClone,
            abi.encode(destTransceiver, destReceiverImpl, salt)
        );
        bytes memory interop =
            deriver.deriveAddress(Erc7930.encodeEvmChain(8453), params);

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

        bytes memory evmOut = deriver.deriveAddress(
            Erc7930.encodeEvmChain(1), abi.encode(VmDeriver.Scheme.EvmClone, inner)
        );
        bytes memory tronOut = deriver.deriveAddress(
            tronChain, abi.encode(VmDeriver.Scheme.TronClone, inner)
        );

        assertTrue(
            Erc7930.toAddress(Erc7930.parseStrict(evmOut))
                != Erc7930.toAddress(Erc7930.parseStrict(tronOut)),
            "0x41 vs 0xff must produce different addresses"
        );
        assertEq(
            Erc7930.toAddress(Erc7930.parseStrict(tronOut)),
            AddressDerive.tronCreate2(
                destTransceiver, salt, AddressDerive.cloneInitCodeHash(destReceiverImpl)
            )
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
        assertFalse(
            deriver.supportsScheme(ChainType.STARKNET, uint8(VmDeriver.Scheme.EvmClone))
        );
    }

    function test_cloneInitCodeHashIsExposed() public view {
        assertEq(
            deriver.cloneInitCodeHash(address(impl)),
            AddressDerive.cloneInitCodeHash(address(impl))
        );
    }
}

/// @dev A spoke on a chain whose CREATE2 formula differs from Ethereum's: zkSync and Tron
///      are `eip155`, so nothing about the chain type separates them, and only the spoke
///      itself knows. Both seams must be overridden together, and this is what happens when
///      they are not.
contract DivergingFormulaTransceiver is TransceiverBase, OwnableUpgradeable {
    address private _impl;
    /// Stands in for a chain-specific derivation: any answer other than Ethereum's.
    bool public overridePrediction;

    function initialize(address owner_, address impl) external initializer {
        __Ownable_init(owner_);
        __TransceiverBase_init();
        _impl = impl;
    }

    function setOverridePrediction(bool v) external {
        overridePrediction = v;
    }

    function predictCrossAccount(address owner, bytes32 salt)
        public
        view
        override
        returns (address)
    {
        if (!overridePrediction) return super.predictCrossAccount(owner, salt);
        // A different formula, standing in for zkSync's `zksyncCreate2` hash chain or
        // Tron's prefix. `_deployAccount` is deliberately NOT overridden to match.
        return address(uint160(uint256(keccak256(abi.encode("other", owner, salt)))));
    }

    function create(address owner, bytes32 salt) external returns (address) {
        return _createCrossAccount(owner, salt, new Call[](0));
    }

    function _checkAdmin() internal view override { _checkOwner(); }
    function _accountImplementation() internal view override returns (address) { return _impl; }
    function _accountInitializer(address, bytes32, Call[] memory)
        internal pure override returns (bytes memory) { return ""; }
    function _counterpartOn(bytes32) internal pure override returns (bytes memory) {
        return abi.encodePacked(address(0xC0DE));
    }
    function _routeTo(bytes32) internal pure override returns (bytes memory) {
        return Erc7930.encodeEvmChain(8453);
    }
    function _handleInbound(bytes32, bytes calldata) internal override {}
    function _authenticateOrigin(bytes memory, bytes memory)
        internal pure override returns (bytes32) { return bytes32(0); }
}

contract DivergingFormulaTest is Test {
    DivergingFormulaTransceiver t;
    address owner = address(0xA11CE);

    function setUp() public {
        t = new DivergingFormulaTransceiver();
        t.initialize(address(this), address(new MinimalAccount()));
    }

    /// @dev The parity path is untouched: prediction and deployment agree, so the guard
    ///      never fires and the account arms normally.
    function test_theParityPathIsUnaffected() public {
        address predicted = t.predictCrossAccount(owner, bytes32(0));
        assertEq(t.create(owner, bytes32(0)), predicted);
        assertTrue(predicted.code.length != 0, "armed");
    }

    /// @dev OVERRIDING ONE SEAM AND NOT THE OTHER IS CAUGHT BY NAME. Before the guard this
    ///      reverted anyway, but only because arming a codeless address trips Solidity's
    ///      `extcodesize` check, which carries no reason data at all.
    function test_aHalfOverriddenDerivationIsRefusedByName() public {
        t.setOverridePrediction(true);
        address predicted = t.predictCrossAccount(owner, bytes32(0));
        address wouldDeployTo = Create2.computeAddress(
            keccak256(abi.encode(owner, bytes32(0))),
            t.CROSS_PROXY_INIT_CODE_HASH(),
            address(t)
        );
        assertTrue(predicted != wouldDeployTo, "the two formulas disagree, by construction");

        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.AccountAddressMismatch.selector, predicted, wouldDeployTo
            )
        );
        t.create(owner, bytes32(0));
    }

    /// @dev And the account is not left half-created: the whole call unwinds, so nothing
    ///      exists at either address and the bootstrap stays retryable.
    function test_aMismatchLeavesNothingBehind() public {
        t.setOverridePrediction(true);
        address wouldDeployTo = Create2.computeAddress(
            keccak256(abi.encode(owner, bytes32(0))),
            t.CROSS_PROXY_INIT_CODE_HASH(),
            address(t)
        );

        vm.expectRevert();
        t.create(owner, bytes32(0));

        assertEq(wouldDeployTo.code.length, 0, "no stranded proxy holding a live admin key");
        assertEq(t.predictCrossAccount(owner, bytes32(0)).code.length, 0);
    }
}

contract MinimalAccount {
    function initialize() external {}
}

contract ZkSpoke is ZkSyncSpokeTransceiver, OwnableUpgradeable {
    address private _impl;
    function initialize(address o, address impl, bytes32 h, bytes32 homeKey, bytes memory homeId, bytes memory hub)
        external initializer
    {
        __Ownable_init(o);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(impl, homeKey, homeId, hub, true);
        __DivergentSpoke_init(h);
        _impl = impl;
    }
    function create(address o, bytes32 s) external returns (address) {
        return _createCrossAccount(o, s, new Call[](0));
    }
    function _checkAdmin() internal view override { _checkOwner(); }
}

contract TronSpoke is TronSpokeTransceiver, OwnableUpgradeable {
    function initialize(address o, address impl, bytes32 h, bytes32 homeKey, bytes memory homeId, bytes memory hub)
        external initializer
    {
        __Ownable_init(o);
        __TransceiverBase_init();
        __SpokeTransceiverBase_init(impl, homeKey, homeId, hub, true);
        __DivergentSpoke_init(h);
    }
    function create(address o, bytes32 s) external returns (address) {
        return _createCrossAccount(o, s, new Call[](0));
    }
    function _checkAdmin() internal view override { _checkOwner(); }
}

/// @dev What this suite CAN establish about a diverging spoke, running on an Ethereum EVM:
///      that each override reproduces `AddressDerive`'s formula exactly, that it does NOT
///      reproduce Ethereum's, and that the guard refuses rather than arming nothing. What
///      it cannot establish is that the target chain's own deployer agrees, which is an
///      on-chain check against Era and Shasta.
contract DivergentSpokeTest is Test {
    address owner = address(0xA11CE);
    bytes32 constant HASH = keccak256("zksolc-or-tronsolc-artifact");
    bytes32 constant SALT = bytes32(0);
    address constant HUB = address(0xC0FFEE);

    function _zk() internal returns (ZkSpoke s) {
        s = new ZkSpoke();
        s.initialize(
            address(this), address(new MinimalAccount()), HASH,
            ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), abi.encodePacked(HUB)
        );
    }

    function _tron() internal returns (TronSpoke s) {
        s = new TronSpoke();
        s.initialize(
            address(this), address(new MinimalAccount()), HASH,
            ChainKey.forEvm(1), Erc7930.encodeEvmChain(1), abi.encodePacked(HUB)
        );
    }

    function testFuzz_zkSyncReproducesTheEraFormula(address o, bytes32 salt) public {
        vm.assume(o != address(0));
        ZkSpoke s = _zk();
        assertEq(
            s.predictCrossAccount(o, salt),
            AddressDerive.zksyncCreate2(
                address(s), s.accountSalt(o, salt), HASH, keccak256("")
            )
        );
    }

    function testFuzz_tronReproducesTheTronFormula(address o, bytes32 salt) public {
        vm.assume(o != address(0));
        TronSpoke s = _tron();
        assertEq(
            s.predictCrossAccount(o, salt),
            AddressDerive.tronCreate2(address(s), s.accountSalt(o, salt), HASH)
        );
    }

    /// @dev The whole point: neither answers what Ethereum's formula would.
    function test_neitherMatchesEthereum() public {
        ZkSpoke z = _zk();
        TronSpoke t = _tron();
        address ethZ = Create2.computeAddress(
            z.accountSalt(owner, SALT), z.CROSS_PROXY_INIT_CODE_HASH(), address(z)
        );
        address ethT = Create2.computeAddress(
            t.accountSalt(owner, SALT), t.CROSS_PROXY_INIT_CODE_HASH(), address(t)
        );
        assertTrue(z.predictCrossAccount(owner, SALT) != ethZ, "zkSync diverges");
        assertTrue(t.predictCrossAccount(owner, SALT) != ethT, "Tron diverges");
        assertTrue(
            z.predictCrossAccount(owner, SALT) != t.predictCrossAccount(owner, SALT),
            "and from each other"
        );
    }

    /// @dev ON AN ETHEREUM EVM BOTH FAIL CLOSED, which is the property that makes shipping
    ///      them before the on-chain check safe. The deployer here uses Ethereum's formula,
    ///      the prediction does not, and the guard names both halves.
    function test_bothFailClosedOnAnEthereumEvm() public {
        ZkSpoke z = _zk();
        vm.expectRevert(
            abi.encodeWithSelector(
                TransceiverBase.AccountAddressMismatch.selector,
                z.predictCrossAccount(owner, SALT),
                Create2.computeAddress(
                    z.accountSalt(owner, SALT), z.CROSS_PROXY_INIT_CODE_HASH(), address(z)
                )
            )
        );
        z.create(owner, SALT);
    }

    /// @dev EVERY ARGUMENT IS BUILT BEFORE THE CHEATCODE. `vm.expectRevert` applies to the
    ///      NEXT CALL, and `new MinimalAccount()` is a call: left inline it consumes the
    ///      expectation and the test fails on the wrong line. The same trap catches
    ///      `vm.prank`, and it is silent whenever the pranked call happens to succeed.
    function test_theBytecodeHashIsWriteOnceAndNonZero() public {
        address impl = address(new MinimalAccount());
        bytes memory homeId = Erc7930.encodeEvmChain(1);
        bytes memory hub = abi.encodePacked(HUB);
        bytes32 homeKey = ChainKey.forEvm(1);

        ZkSpoke s = new ZkSpoke();
        vm.expectRevert(DivergentSpokeTransceiver.ZeroAccountBytecodeHash.selector);
        s.initialize(address(this), impl, bytes32(0), homeKey, homeId, hub);

        ZkSpoke ok = _zk();
        assertEq(ok.accountBytecodeHash(), HASH);
        vm.expectRevert();
        ok.initialize(address(this), impl, keccak256("other"), homeKey, homeId, hub);
    }
}

/// @notice L1 -> L2 sender aliasing, which Arbitrum, zkSync Era and the OP Stack's
///         `OptimismPortal` all apply with the same constant.
///
/// @dev THE ROUND TRIP IS THE EASY HALF. What these pin is the two properties that make the
///      undo direction dangerous to use: it wraps, so it cannot tell whether it was needed,
///      and it is not an involution, so applying it in the wrong direction is silent.
contract AddressAliasTest is Test {
    /// Arbitrum's `AddressAliasHelper.OFFSET`, verbatim.
    uint160 constant ARBITRUM_OFFSET = uint160(0x1111000000000000000000000000000000001111);

    function test_theOffsetIsArbitrums() public pure {
        assertEq(
            AddressDerive.applyL1ToL2Alias(address(0)),
            address(ARBITRUM_OFFSET),
            "same constant as AddressAliasHelper"
        );
    }

    function testFuzz_theTwoDirectionsRoundTrip(address l1) public pure {
        assertEq(AddressDerive.undoL1ToL2Alias(AddressDerive.applyL1ToL2Alias(l1)), l1);
        assertEq(AddressDerive.applyL1ToL2Alias(AddressDerive.undoL1ToL2Alias(l1)), l1);
    }

    /// @dev IT WRAPS, WHICH IS WHY THERE IS NO "WAS THIS ALIASED" PREDICATE. Undoing an
    ///      alias that was never applied returns a perfectly well-formed address rather than
    ///      reverting, so a binding that gets the direction wrong authenticates against a
    ///      value belonging to nobody and simply never matches.
    function testFuzz_undoingAnUnaliasedAddressIsSilent(address raw) public pure {
        address wrong = AddressDerive.undoL1ToL2Alias(raw);

        assertTrue(wrong != raw, "it moved");
        // And it is indistinguishable from a real answer: it round-trips like one.
        assertEq(AddressDerive.applyL1ToL2Alias(wrong), raw);
    }

    /// @dev EXACTLY ONE INPUT UNDOES TO ZERO, and it is the offset itself. Found by fuzzing
    ///      an assertion that no input did. It is worth pinning because it is the whole
    ///      extent of what a zero check on the result would buy: one address out of 2^160,
    ///      which is not a defence against getting the direction wrong.
    function test_onlyTheOffsetItselfUndoesToZero() public pure {
        assertEq(
            AddressDerive.undoL1ToL2Alias(address(ARBITRUM_OFFSET)),
            address(0),
            "the one case"
        );
        assertTrue(AddressDerive.undoL1ToL2Alias(address(1)) != address(0));
    }

    function testFuzz_nothingElseUndoesToZero(address raw) public pure {
        vm.assume(raw != address(ARBITRUM_OFFSET));
        assertTrue(AddressDerive.undoL1ToL2Alias(raw) != address(0));
    }

    /// @dev AND IT IS NOT AN INVOLUTION, so applying the same direction twice does not
    ///      cancel. This is what a symmetric binding would do to the L2 -> L1 path, where
    ///      the sender arrives unaliased.
    function testFuzz_applyingTwiceIsNotIdentity(address l1) public pure {
        address twice = AddressDerive.applyL1ToL2Alias(AddressDerive.applyL1ToL2Alias(l1));
        assertTrue(twice != l1, "double-aliasing is a different address");
    }

    /// @dev THE CASE A BINDING ACTUALLY FACES. A transmitter at T on the home chain reaches
    ///      an L2 receiver as T + OFFSET; `ReceiverBase` compares against `sourceTransmitter`,
    ///      which is T, so the binding must undo before handing the sender over.
    function testFuzz_itRecoversWhatReceiverBaseCompares(address transmitter) public pure {
        address asSeenOnL2 = AddressDerive.applyL1ToL2Alias(transmitter);
        assertTrue(asSeenOnL2 != transmitter, "the raw sender would not match");
        assertEq(AddressDerive.undoL1ToL2Alias(asSeenOnL2), transmitter);
    }
}
