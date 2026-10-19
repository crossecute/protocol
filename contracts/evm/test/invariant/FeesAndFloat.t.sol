// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverCore} from "src/messaging/transceiver/TransceiverCore.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Treasury, IReportFloat} from "src/treasury/Treasury.sol";
import {unseeded} from "test/RegistrySeed.sol";
import {
    transceiverConfig,
    ext,
    toBytes32,
    AnyGatewayReceiver,
    AnyGatewayTransceiver,
    AnyGatewayTransmitter
} from "test/Harness.sol";
import {deployTransceiver} from "test/DeployCrossProxy.sol";

uint256 constant PER_BYTE = 1 gwei;
uint256 constant BOOTSTRAP_FEE = 0.01 ether;
address constant PROVIDER = address(0xFEE5);

contract FeeAccount is AnyGatewayTransmitter {}

contract FeeReceiver is AnyGatewayReceiver {}

/// @dev A diverging transceiver's default counterpart on a `Predetermined` chain is the
///      registry's record, as `DivergentTransceiverExtension` has it.
contract RegistryParityExtension is TransceiverExtension {
    function _parityAddress(bytes32 chainKey) internal view override returns (address) {
        return _registryParityAddress(chainKey);
    }
}

/// @notice A diverging transceiver, so it both charges bootstrap fees and pays reports from its
///         float. It derives accounts Ethereum's way, since the zkSync and Tron formulas fail
///         closed on Forge's EVM; nothing here depends on the formula.
contract FloatTransceiver is AnyGatewayTransceiver {
    error NoBalanceForTheReport();

    function initialize(TransceiverConfig memory c) external initializer {
        __TransceiverBase_init(c, true);
    }

    function _newExtension() internal override returns (address) {
        return address(new RegistryParityExtension());
    }

    function _parityAddress(bytes32 chainKey) internal view override returns (address) {
        return _registryParityAddress(chainKey);
    }

    function _quoteMessage(bytes memory, bytes memory payload, bytes[] memory)
        internal
        pure
        override
        returns (uint256)
    {
        return payload.length * PER_BYTE;
    }

    /// @dev Pays the provider exactly `value`, from this contract's balance, as R7.1 requires.
    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256 value)
        internal
        override
        returns (bytes32)
    {
        if (value > address(this).balance) revert NoBalanceForTheReport();
        (bool ok,) = PROVIDER.call{value: value}("");
        require(ok);
        return bytes32(0);
    }

    /// @dev Stands in for a provider adapter routing a delivery into `_onInbound`.
    function arrive(bytes memory route, bytes memory sender, bytes calldata message) external {
        _onInbound(route, sender, message);
    }
}

/// @notice The treasury's owner, every account's owner, and the only actor: bootstraps from a
///         few accounts to three destinations, delivers bootstraps that are reported home from
///         the float, tops the float up, collects it, and makes the calls that must be refused.
/// @dev Expectations are written before the call they describe: an unexpected revert undoes
///      them with the call, and `fail-on-revert` reports it.
contract FloatHandler is Test {
    uint256 constant ACCOUNTS = 4;
    uint256 constant DESTINATIONS = 3;
    uint256 constant FUNDING = 1 ether;
    uint256 constant MAX_FEE = 0.1 ether;
    uint256 constant HOME_CHAIN = 1;

    FloatTransceiver public t;
    Treasury public treasury;
    ChainRegistry public registry;
    bytes32 public provider;

    address[] public accounts;
    mapping(uint256 account => mapping(uint256 destination => bool)) public booted;
    mapping(uint256 destination => uint256) public fee;

    uint256 public feesCharged;
    uint256 public messageFees;
    uint256 public reportFees;
    uint256 public toppedUp;
    uint256 public collected;
    uint256 public inbound;

    constructor(ChainRegistry registry_, bytes32 provider_) {
        registry = registry_;
        provider = provider_;
        treasury = new Treasury(address(this));
    }

    function setTransceiver(FloatTransceiver t_) external {
        t = t_;
        for (uint256 i; i < ACCOUNTS; ++i) {
            address a = t_.createTransmitter(salt(i));
            vm.deal(a, FUNDING);
            accounts.push(a);
        }
        for (uint256 d; d < DESTINATIONS; ++d) {
            fee[d] = reporting(d) ? BOOTSTRAP_FEE : 0;
        }
    }

    function accountsFunded() external pure returns (uint256) {
        return ACCOUNTS * FUNDING;
    }

    function salt(uint256 i) public pure returns (bytes32) {
        return bytes32(i + 1);
    }

    /// zkSync and Tron report their receivers; Arbitrum is `Predetermined` and does not.
    function chainId(uint256 d) public pure returns (uint256) {
        return [uint256(324), 728126428, 42161][d];
    }

    function reporting(uint256 d) public pure returns (bool) {
        return d < 2;
    }

    function calls() public pure returns (Call[] memory c) {
        c = new Call[](1);
        c[0] = Call(address(0xCA11), 0, "");
    }

    function messageFee(uint256 i) public view returns (uint256) {
        return Envelope.encodeBootstrap(address(this), salt(i), toBytes32(accounts[i]), calls()).length * PER_BYTE;
    }

    function bootstrap(uint256 accountSeed, uint256 destinationSeed) external {
        uint256 i = accountSeed % ACCOUNTS;
        uint256 d = destinationSeed % DESTINATIONS;
        TransmitterBase a = TransmitterBase(payable(accounts[i]));
        bytes32 key = ChainKey.forEvm(chainId(d));
        if (booted[i][d]) {
            vm.expectRevert(abi.encodeWithSelector(TransmitterBase.AlreadyBootstrapped.selector, key));
        } else if (reporting(d) && fee[d] == 0) {
            vm.expectRevert(abi.encodeWithSelector(TransceiverCore.NoBootstrapFee.selector, key));
        } else {
            assertEq(a.quoteBootstrap(chainId(d), calls(), new bytes[](0)), messageFee(i) + fee[d], "quote");
            booted[i][d] = true;
            feesCharged += fee[d];
            messageFees += messageFee(i);
        }
        a.bootstrap(chainId(d), calls(), new bytes[](0));
    }

    /// @dev The account calling the transceiver directly with less than the fee.
    function underpay(uint256 accountSeed, uint256 destinationSeed, uint256 value) external {
        uint256 i = accountSeed % ACCOUNTS;
        uint256 d = destinationSeed % DESTINATIONS;
        bytes32 key = ChainKey.forEvm(chainId(d));
        if (fee[d] == 0) return;
        value = bound(value, 0, fee[d] - 1);
        vm.prank(accounts[i]);
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.InsufficientBootstrapFee.selector, fee[d], value));
        t.bootstrap{value: value}(key, address(this), salt(i), calls(), new bytes[](0));
    }

    /// @dev Anyone but the account, paying in full.
    function bootstrapAsStranger(uint256 accountSeed, uint256 destinationSeed) external {
        uint256 i = accountSeed % ACCOUNTS;
        uint256 d = destinationSeed % DESTINATIONS;
        vm.deal(address(this), address(this).balance + MAX_FEE + 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(TransceiverCore.NotTheAccount.selector, address(this), salt(i), address(this))
        );
        t.bootstrap{value: MAX_FEE + 1 ether}(
            ChainKey.forEvm(chainId(d)), address(this), salt(i), calls(), new bytes[](0)
        );
    }

    /// @dev Rebindable at any time, including to zero.
    function setFee(uint256 destinationSeed, uint256 amount) external {
        uint256 d = destinationSeed % DESTINATIONS;
        amount = bound(amount, 0, MAX_FEE);
        fee[d] = amount;
        vm.prank(t.owner());
        ext(address(t)).setBootstrapFee(ChainKey.forEvm(chainId(d)), amount);
    }

    /// @dev A bootstrap from the home arrives, creates a receiver, and is reported home from the
    ///      float. A float that cannot pay reverts the delivery, account creation with it.
    function deliver() external {
        uint256 n = ++inbound;
        address owner = address(uint160(0xA0000 + n));
        bytes32 homeKey = ChainKey.forEvm(HOME_CHAIN);
        address transmitter = registry.predictCrossAccount(homeKey, provider, owner, bytes32(n), homeKey);
        bytes memory message = Envelope.encodeBootstrap(owner, bytes32(n), toBytes32(transmitter), new Call[](0));
        address receiver = ext(address(t)).predictCrossAccount(owner, bytes32(n), homeKey);
        bytes memory counterpart = abi.encodePacked(registry.predictTransceiver(homeKey, provider));
        uint256 cost = ext(address(t)).reportPayload(owner, bytes32(n), receiver).length * PER_BYTE;
        if (address(t).balance < cost) {
            vm.expectRevert(FloatTransceiver.NoBalanceForTheReport.selector);
        } else {
            reportFees += cost;
        }
        t.arrive(Erc7930.encodeEvmChain(HOME_CHAIN), counterpart, message);
    }

    /// @dev Funding out of band: a plain transfer.
    function topUp(uint256 amount) external {
        amount = bound(amount, 0, 0.001 ether);
        vm.deal(address(this), address(this).balance + amount);
        toppedUp += amount;
        (bool ok,) = payable(address(t)).call{value: amount}("");
        require(ok);
    }

    /// @dev The treasury's owner pulls from the float; more than it holds is refused.
    function collect(uint256 amount) external {
        uint256 float = address(t).balance;
        amount = bound(amount, 0, float * 2 + 1);
        if (amount > float) {
            vm.expectRevert(abi.encodeWithSelector(TransceiverCore.WithdrawFailed.selector, amount));
        } else {
            collected += amount;
        }
        treasury.collect(IReportFloat(address(t)), amount);
    }

    function withdrawAsStranger(address caller, uint256 amount) external {
        if (caller == address(treasury)) caller = address(this);
        amount = bound(amount, 0, address(t).balance);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TransceiverCore.NotTreasury.selector, caller));
        ext(address(t)).withdraw(amount);
    }
}

/// @notice `TransceiverCore`'s rules for value: a bootstrap fee lands in the treasury the moment
///         it is charged, the report float leaves only to the treasury or to pay a report, a
///         bootstrap's quote is its message fee plus the destination's fee and is what is
///         charged, and a refused call moves nothing.
contract FeesAndFloatInvariantTest is Test {
    uint256 constant FLOAT = 0.001 ether;

    FloatHandler handler;
    FloatTransceiver t;
    ChainRegistry registry;

    function setUp() public {
        registry = new ChainRegistry(address(this), unseeded());
        bytes32 provider = registry.addMessageProvider("test");
        handler = new FloatHandler(registry, provider);

        TransceiverConfig memory c = transceiverConfig(
            address(0x5165), address(new FeeAccount()), address(new FeeReceiver()), address(handler.treasury())
        );
        t = FloatTransceiver(
            payable(deployTransceiver(
                    address(new FloatTransceiver()), abi.encodeCall(FloatTransceiver.initialize, (c))
                ))
        );
        registry.setLocalTransceiver(provider, address(t));
        // R8.4: the record names the initcode hash every EVM chain deploys accounts from.
        registry.setProviderDeployment(provider, address(0xD1), keccak256("provider"), t.CROSS_PROXY_INIT_CODE_HASH());

        _route(1, Provenance.Predetermined);
        for (uint256 d; d < 3; ++d) {
            _route(handler.chainId(d), handler.reporting(d) ? Provenance.Unique : Provenance.Predetermined);
        }
        vm.startPrank(t.owner());
        ext(address(t)).setRouting(IChainRegistryRefs(address(registry)), provider, Provenance.Unique);
        for (uint256 d; d < 3; ++d) {
            uint256 id = handler.chainId(d);
            ext(address(t)).setRoute(ChainKey.forEvm(id), Erc7930.encodeEvmChain(id));
            if (handler.reporting(d)) {
                ext(address(t)).setCounterpart(ChainKey.forEvm(id), Erc7930.encodeEvm(id, address(0xC0DE)));
                ext(address(t)).setBootstrapFee(ChainKey.forEvm(id), BOOTSTRAP_FEE);
            }
        }
        ext(address(t)).setRoute(ChainKey.forEvm(1), Erc7930.encodeEvmChain(1));
        vm.stopPrank();

        vm.deal(address(t), FLOAT);
        handler.setTransceiver(t);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = FloatHandler.bootstrap.selector;
        selectors[1] = FloatHandler.underpay.selector;
        selectors[2] = FloatHandler.bootstrapAsStranger.selector;
        selectors[3] = FloatHandler.setFee.selector;
        selectors[4] = FloatHandler.deliver.selector;
        selectors[5] = FloatHandler.topUp.selector;
        selectors[6] = FloatHandler.collect.selector;
        selectors[7] = FloatHandler.withdrawAsStranger.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _route(uint256 id, Provenance p) internal {
        registry.addChainKey(Erc7930.encodeEvmChain(id), p);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_feesLandInTheTreasury() public view {
        assertEq(address(handler.treasury()).balance, handler.feesCharged() + handler.collected(), "treasury");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_theFloatLeavesOnlyToTheTreasuryOrAReport() public view {
        assertEq(address(t).balance, FLOAT + handler.toppedUp() - handler.collected() - handler.reportFees(), "float");
        assertEq(PROVIDER.balance, handler.messageFees() + handler.reportFees(), "provider");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_eachAccountPaidExactlyItsQuotes() public view {
        uint256 held;
        for (uint256 i; i < 4; ++i) {
            held += handler.accounts(i).balance;
        }
        assertEq(held, handler.accountsFunded() - handler.feesCharged() - handler.messageFees(), "accounts");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_aQuoteIsTheMessageFeePlusTheBootstrapFee() public view {
        for (uint256 d; d < 3; ++d) {
            bytes32 key = ChainKey.forEvm(handler.chainId(d));
            uint256 fee = handler.fee(d);
            assertEq(ext(address(t)).bootstrapFee(key), fee, "bootstrapFee");
            try t.quoteBootstrap(key, address(handler), handler.salt(0), handler.calls(), new bytes[](0)) returns (
                uint256 quote
            ) {
                assertEq(quote, handler.messageFee(0) + fee, "quote");
            } catch (bytes memory err) {
                assertTrue(handler.reporting(d) && fee == 0, "refused only where the fee is unset");
                assertEq(err, abi.encodeWithSelector(TransceiverCore.NoBootstrapFee.selector, key), "refusal");
            }
        }
    }
}
