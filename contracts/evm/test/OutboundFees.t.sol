// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OwnableTransmitter} from "src/messaging/outbound/OwnableTransmitter.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {deployConduit} from "test/DeployProxy.sol";
import {MockReceiver} from "test/Transport.t.sol";

contract FeeGateway {
    uint256 public quote = 0.001 ether;
    uint256 public refund;
    uint256 public received;
    bool public fail;

    error ProviderFailed();

    function configure(uint256 quote_, uint256 refund_, bool fail_) external {
        quote = quote_;
        refund = refund_;
        fail = fail_;
    }

    function send() external payable {
        if (fail) revert ProviderFailed();
        received += msg.value;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok);
        }
    }
}

contract FeeTransmitter is OwnableTransmitter {
    FeeGateway public immutable gateway;

    constructor(FeeGateway gateway_) {
        gateway = gateway_;
    }

    // Test-only shortcut for the route and counterpart a successful bootstrap records.
    function recordDestination(uint256 chainId) external {
        bytes32 key = ChainKey.forEvm(chainId);
        _setRoute(key, Erc7930.encodeEvmChain(chainId));
        _setCounterpart(key, abi.encodePacked(address(this)));
    }

    function _quoteMessage(bytes memory, bytes memory, bytes[] memory) internal view override returns (uint256) {
        return gateway.quote();
    }

    function _sendMessage(bytes memory, bytes memory, bytes[] memory, uint256 value)
        internal
        override
        returns (bytes32)
    {
        gateway.send{value: value}();
        return bytes32(0);
    }
}

contract FeeBatchOwner {
    function sendBatch(TransmitterBase transmitter, bytes[] calldata recipients, bytes calldata payload) external {
        for (uint256 i; i < recipients.length; ++i) {
            transmitter.sendMessage(recipients[i], payload, new bytes[](0));
        }
    }
}

contract OutboundFeesTest is Test {
    Treasury public treasury;
    FeeGateway gateway;
    FeeTransmitter transmitter;
    bytes recipient;
    bytes payload;
    bytes[] attributes;

    function setUp() public {
        treasury = new Treasury(address(this));
        gateway = new FeeGateway();
        transmitter = FeeTransmitter(
            payable(deployConduit(
                    address(new FeeTransmitter(gateway)),
                    abi.encodeCall(OwnableTransmitter.initialize, (address(this), address(this), bytes32(0)))
                ))
        );
        transmitter.recordDestination(8453);
        recipient = transmitter.recipientOn(8453);
        Call[] memory calls = new Call[](2);
        calls[0] = Call(address(0xBEEF), 1 ether, "");
        calls[1] = Call(address(0xCAFE), 2 ether, "");
        payload = Payload.encodeCalls(calls);
        vm.deal(address(transmitter), 1 ether);
    }

    function test_quoteAndSendSplitFeesOnceForMultipleCalls() public {
        (uint256 providerFee, uint256 crossecuteFee) = transmitter.quoteMessageBreakdown(recipient, payload, attributes);
        assertEq(providerFee, 0.001 ether);
        assertEq(crossecuteFee, 0.0001 ether);
        assertEq(transmitter.quoteMessage(recipient, payload, attributes), 0.0011 ether);
        transmitter.sendMessage(recipient, payload, attributes);
        assertEq(gateway.received(), providerFee);
        assertEq(address(treasury).balance, crossecuteFee);
        assertEq(address(transmitter).balance, 1 ether - 0.0011 ether);
    }

    function testFuzz_roundsDown(uint128 quote) public {
        gateway.configure(quote, 0, false);
        (uint256 providerFee, uint256 crossecuteFee) = transmitter.quoteMessageBreakdown(recipient, payload, attributes);
        assertEq(providerFee, quote);
        assertEq(crossecuteFee, uint256(quote) / 10);
        uint256 total = uint256(quote) + uint256(quote) / 10;
        assertEq(transmitter.quoteMessage(recipient, payload, attributes), total);
        vm.deal(address(transmitter), total);
        transmitter.sendMessage(recipient, payload, attributes);
        assertEq(gateway.received(), quote);
        assertEq(address(treasury).balance, uint256(quote) / 10);
        assertEq(address(transmitter).balance, 0);
    }

    function test_zeroQuoteHasNoFee() public {
        gateway.configure(0, 0, false);
        assertEq(transmitter.quoteMessage(recipient, payload, attributes), 0);
        transmitter.sendMessage(recipient, payload, attributes);
        assertEq(address(treasury).balance, 0);
        assertEq(address(transmitter).balance, 1 ether);
    }

    function test_providerFundingAloneIsInsufficient() public {
        vm.deal(address(transmitter), 0.001 ether);
        vm.expectRevert(abi.encodeWithSelector(TransmitterBase.InsufficientBalance.selector, 0.0011 ether, 0.001 ether));
        transmitter.sendMessage(recipient, payload, attributes);
        assertEq(address(treasury).balance, 0);
        assertEq(gateway.received(), 0);
    }

    function test_providerRevertRollsBackFee() public {
        gateway.configure(0.001 ether, 0, true);
        vm.expectRevert(FeeGateway.ProviderFailed.selector);
        transmitter.sendMessage(recipient, payload, attributes);
        assertEq(address(treasury).balance, 0);
        assertEq(address(transmitter).balance, 1 ether);
    }

    function test_providerRefundReturnsToTransmitterWithoutReducingFee() public {
        gateway.configure(0.001 ether, 0.0002 ether, false);
        transmitter.sendMessage(recipient, payload, attributes);
        assertEq(address(treasury).balance, 0.0001 ether);
        assertEq(address(transmitter).balance, 1 ether - 0.0009 ether);
        assertEq(address(gateway).balance, 0.0008 ether);
    }

    function test_destinationFailureAndRetryDoNotChangeTheCollectedFee() public {
        MockReceiver receiver = new MockReceiver();
        receiver.initialize(address(transmitter), ChainKey.local(), new Call[](0));
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(gateway), 0, abi.encodeCall(FeeGateway.send, ()));
        bytes memory message = Payload.encodeCalls(calls);
        transmitter.sendMessage(recipient, message, attributes);
        bytes memory sender = Erc7930.encodeEvm(block.chainid, address(transmitter));

        gateway.configure(0.001 ether, 0, true);
        vm.expectRevert();
        receiver.receiveMessage(bytes32(0), sender, message);
        assertEq(address(treasury).balance, 0.0001 ether);
        gateway.configure(0.001 ether, 0, false);
        receiver.receiveMessage(bytes32(0), sender, message);
        assertEq(address(treasury).balance, 0.0001 ether);
        assertEq(address(transmitter).balance, 1 ether - 0.0011 ether);
    }

    function test_threeDestinationsInOneTransactionPayThreeFees() public {
        FeeBatchOwner batch = new FeeBatchOwner();
        bytes[] memory recipients = new bytes[](3);
        for (uint256 i; i < recipients.length; ++i) {
            transmitter.recordDestination(10 + i);
            recipients[i] = transmitter.recipientOn(10 + i);
        }
        transmitter.transferOwnership(address(batch));
        batch.sendBatch(transmitter, recipients, payload);
        assertEq(gateway.received(), 0.003 ether);
        assertEq(address(treasury).balance, 0.0003 ether);
        assertEq(address(transmitter).balance, 1 ether - 0.0033 ether);
    }

    function test_localExecutionCannotSpendCollectedFees() public {
        transmitter.sendMessage(recipient, payload, attributes);
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(0xBEEF), address(transmitter).balance, "");
        transmitter.execute(calls);
        assertEq(address(transmitter).balance, 0);
        assertEq(address(treasury).balance, 0.0001 ether);
        treasury.withdraw(address(0xCAFE), 0.0001 ether);
        assertEq(address(0xCAFE).balance, 0.0001 ether);
    }

    function test_rejectingTreasuryRollsBackSend() public {
        vm.etch(address(treasury), hex"60006000fd");
        vm.expectRevert(
            abi.encodeWithSelector(TransmitterBase.FeeTransferFailed.selector, address(treasury), 0.0001 ether)
        );
        transmitter.sendMessage(recipient, payload, attributes);
        assertEq(gateway.received(), 0);
        assertEq(address(transmitter).balance, 1 ether);
    }
}
