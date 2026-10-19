// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Call} from "src/messaging/Call.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {AnyGatewayTransmitter} from "test/Harness.sol";
import {deployAccount} from "test/DeployCrossProxy.sol";

uint256 constant BOOTSTRAP_FEE = 3;
uint256 constant SEND_FEE = 5;

/// @dev Sends pay a flat fee to `sink`, so a send's cost is visible in balances.
contract FeeTransmitter is AnyGatewayTransmitter {
    address public immutable sink;

    constructor(address sink_) {
        sink = sink_;
    }

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256 value)
        internal
        override
        returns (bytes32)
    {
        (bool ok,) = sink.call{value: value}("");
        require(ok);
        return bytes32(0);
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal pure override returns (uint256) {
        return SEND_FEE;
    }
}

/// @notice The transmitter's transceiver, reduced to what the transmitter asks of it. Whether a
///         chain reports its receiver is fixed per chain, as in production, and only a reporting
///         chain is ever reported.
contract StubTransceiver {
    mapping(bytes32 chainKey => bool) public reportsReceiver;
    mapping(bytes32 chainKey => uint256) public bootCount;

    function setReports(bytes32 chainKey) external {
        reportsReceiver[chainKey] = true;
    }

    function bootstrap(bytes32 chainKey, address, bytes32, Call[] calldata, bytes[] calldata) external payable {
        require(msg.value == BOOTSTRAP_FEE);
        ++bootCount[chainKey];
    }

    function quoteBootstrap(bytes32, address, bytes32, Call[] calldata, bytes[] calldata)
        external
        pure
        returns (uint256)
    {
        return BOOTSTRAP_FEE;
    }

    /// @dev A parity chain: the receiver sits at the transmitter's own address.
    function predictReceiver(bytes32, address, bytes32) external view returns (bytes memory) {
        return abi.encodePacked(msg.sender);
    }

    function report(TransmitterBase transmitter, bytes32 chainKey, address receiver) external {
        transmitter.onDestinationReceiverReported(chainKey, abi.encodePacked(receiver));
    }
}

/// @notice The account owner, and the only actor: bootstraps, reports, and sends to a few chains,
///         two of which report their receiver, and tracks what each call must have done.
/// @dev Expectations are written before the call they describe: an unexpected revert undoes
///      them with the call, and `fail-on-revert` reports it.
contract BootstrapHandler is Test {
    uint256 constant CHAINS = 4;

    TransmitterBase public transmitter;
    StubTransceiver public stub;

    mapping(uint256 => bool) public booted;
    mapping(uint256 => bool) public reported;
    uint256 public boots;
    uint256 public sends;

    constructor(StubTransceiver stub_) {
        stub = stub_;
        for (uint256 i; i < CHAINS; ++i) {
            if (reports(i)) stub_.setReports(ChainKey.forEvm(chainId(i)));
        }
    }

    function setTransmitter(TransmitterBase t) external {
        transmitter = t;
    }

    function chainId(uint256 i) public pure returns (uint256) {
        return 1000 + i;
    }

    function reports(uint256 i) public pure returns (bool) {
        return i % 2 == 1;
    }

    function receiverOn(uint256 i) public view returns (address) {
        return reports(i) ? address(uint160(0xEC0000 + i)) : address(transmitter);
    }

    function sendable(uint256 i) public view returns (bool) {
        return booted[i] && (!reports(i) || reported[i]);
    }

    function bootstrap(uint256 seed) external {
        uint256 i = seed % CHAINS;
        bytes32 key = ChainKey.forEvm(chainId(i));
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0xCA11), 0, "");
        if (booted[i]) {
            vm.expectRevert(abi.encodeWithSelector(TransmitterBase.AlreadyBootstrapped.selector, key));
            transmitter.bootstrap(chainId(i), calls, new bytes[](0));
            return;
        }
        booted[i] = true;
        ++boots;
        transmitter.bootstrap(chainId(i), calls, new bytes[](0));
    }

    /// @dev Only the transceiver reports, and only for a chain that reports.
    function report(uint256 seed) external {
        uint256 i = (seed % (CHAINS / 2)) * 2 + 1;
        bytes32 key = ChainKey.forEvm(chainId(i));
        if (!booted[i]) {
            vm.expectRevert(abi.encodeWithSelector(TransmitterBase.NotBootstrapped.selector, key));
        } else if (reported[i]) {
            vm.expectRevert(abi.encodeWithSelector(TransmitterBase.ReceiverAlreadyReported.selector, key));
        } else {
            reported[i] = true;
        }
        stub.report(transmitter, key, receiverOn(i));
    }

    /// @dev A send to a chain with no counterpart is refused before any fee leaves.
    function send(uint256 seed) external {
        uint256 i = seed % CHAINS;
        bytes memory recipient = Erc7930.encodeEvm(chainId(i), receiverOn(i));
        if (!sendable(i)) {
            vm.expectRevert(
                abi.encodeWithSelector(TransmitterBase.NotBootstrapped.selector, ChainKey.forEvm(chainId(i)))
            );
            transmitter.sendMessage(recipient, hex"01", new bytes[](0));
            return;
        }
        ++sends;
        transmitter.sendMessage(recipient, hex"01", new bytes[](0));
    }
}

/// @notice `message-flow.md`: a destination is bootstrapped exactly once per account, and a send
///         to one that has not been is refused locally rather than paid for and failed on
///         arrival. On a reporting chain that holds until the receiver is reported.
contract BootstrapOnceInvariantTest is Test {
    uint256 constant FUNDED = 1 ether;

    BootstrapHandler handler;
    StubTransceiver stub;
    TransmitterBase transmitter;
    address sink = address(0x5111C);

    function setUp() public {
        stub = new StubTransceiver();
        handler = new BootstrapHandler(stub);
        transmitter = TransmitterBase(
            payable(deployAccount(
                    address(new FeeTransmitter(sink)),
                    abi.encodeCall(OwnableTransmitter.initialize, (address(handler), address(stub), bytes32(0)))
                ))
        );
        vm.deal(address(transmitter), FUNDED);
        handler.setTransmitter(transmitter);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = BootstrapHandler.bootstrap.selector;
        selectors[1] = BootstrapHandler.report.selector;
        selectors[2] = BootstrapHandler.send.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_eachDestinationIsBootstrappedOnce() public view {
        for (uint256 i; i < 4; ++i) {
            bytes32 key = ChainKey.forEvm(handler.chainId(i));
            bool booted = handler.booted(i);
            assertEq(transmitter.isBootstrapped(key), booted, "isBootstrapped");
            assertEq(stub.bootCount(key), booted ? 1 : 0, "transceiver bootstraps");
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_aCounterpartExistsOnlyOnceSendable() public view {
        for (uint256 i; i < 4; ++i) {
            bytes32 key = ChainKey.forEvm(handler.chainId(i));
            assertEq(transmitter.hasCounterpart(key), handler.sendable(i), "hasCounterpart");
            assertEq(transmitter.isReceiverPinned(key), handler.reported(i), "isReceiverPinned");
            if (handler.sendable(i)) {
                assertEq(transmitter.counterpartOn(key), abi.encodePacked(handler.receiverOn(i)), "counterpart");
            }
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    function invariant_onlyWhatWasSentWasPaid() public view {
        assertEq(address(stub).balance, handler.boots() * BOOTSTRAP_FEE, "bootstrap fees");
        assertEq(sink.balance, handler.sends() * SEND_FEE, "send fees");
        assertEq(
            address(transmitter).balance,
            FUNDED - handler.boots() * BOOTSTRAP_FEE - handler.sends() * SEND_FEE,
            "the account kept the rest"
        );
    }
}
