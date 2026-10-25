// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VmSafe} from "forge-std/Vm.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Call} from "src/messaging/Call.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {Payload} from "src/messaging/Payload.sol";
import {LzOftFactory} from "src/protocols/layerzero/LzOftFactory.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {DeliveryGasMeter} from "test/protocols/DeliveryGasMeter.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";

/// @notice `layerzero-oft`'s deliveries against its `DeliveryGas` defaults, which it sends as
///         lzCompose gas, measured as `ProviderDeliveryGasSpec` measures every other binding's.
///         Its lzReceive gas is the OFT's own, in the operator's enforced options.
/// @dev A delivery is the compose the destination OFT queues and the endpoint runs, so the
///      measurement is the factory's or the receiver's frame. Coverage builds unoptimized and is
///      exempt.
contract LzOftDeliveryGasTest is DeliveryGasMeter {
    uint32 constant HOME_EID = 30255;
    uint32 constant DEST_EID = 30101;
    address constant HOME_OFT = address(0x40F7);
    address constant OWNER = address(0xA11CE);
    bytes32 constant SALT = keccak256("account");
    bytes32 homeKey = ChainKey.forEvm(252);

    MockLzEndpoint endpoint;
    MockOft oft;
    LzOftFactory factory;

    function setUp() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) vm.skip(true);
        endpoint = new MockLzEndpoint();
        endpoint.setEid(DEST_EID);
        oft = new MockOft(address(endpoint));
        oft.setPeer(HOME_EID, HOME_OFT);
        factory = new LzOftFactory(address(new LzOftTransmitter()), address(new LzOftReceiver()));
    }

    /// @dev This chain's leaf first, then `n - 1` others, so the proof has `ceil(log2 n)` words.
    function _bootstrap(uint256 n, Call[] memory calls) internal view returns (address account, bytes memory) {
        bytes32[] memory leaves = new bytes32[](n);
        leaves[0] = LzOftMessage.leaf(factory.localChainKey(), DEST_EID, address(oft));
        for (uint256 i = 1; i < n; ++i) {
            leaves[i] = keccak256(abi.encode("another destination", i));
        }
        bytes32 destRoot = LzOftMessage.root(leaves);
        bytes32[] memory proof = LzOftMessage.proof(leaves, 0);
        account = factory.predictAccount(OWNER, SALT, homeKey, HOME_EID, HOME_OFT, destRoot);
        return (
            account,
            LzOftMessage.encodeBootstrap(
                LzOftMessage.Bootstrap(OWNER, SALT, homeKey, HOME_EID, HOME_OFT, destRoot, proof, calls)
            )
        );
    }

    function test_aBootstrapWithOneDestinationAndNoCallsFitsTheDefault() public {
        (address account, bytes memory message) = _bootstrap(1, new Call[](0));
        _assertFits(
            "bootstrap, 1 destination, no calls", _measure(address(factory), account, message), DeliveryGas.BOOTSTRAP
        );
    }

    /// @dev Eight destinations add three proof words; one call to an address with no code adds
    ///      the per-call cost.
    function test_aBootstrapWithEightDestinationsAndOneCallFitsTheDefault() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(0xBEEF), value: 0, data: ""});
        (address account, bytes memory message) = _bootstrap(8, calls);
        _assertFits(
            "bootstrap, 8 destinations, one call", _measure(address(factory), account, message), DeliveryGas.BOOTSTRAP
        );
    }

    /// @dev The receiver's overhead only: `PAYLOAD` also pays for the caller's calls.
    function test_aPayloadWithNoCallsFitsTheDefault() public {
        (address account, bytes memory message) = _bootstrap(1, new Call[](0));
        this.deliver(address(factory), account, message);
        assertGt(account.code.length, 0, "the receiver exists");
        bytes memory payload = Payload.encodeCalls(new Call[](0));
        _assertFits("payload, no calls", _measure(account, account, payload), DeliveryGas.PAYLOAD);
    }

    /// @dev External so a test can cap the gas the delivery runs with.
    function deliver(address to, address sender, bytes calldata message) external {
        oft.deliver(HOME_EID, to, bytes32(uint256(uint160(sender))), message);
    }

    function _meteredDelivery(uint256 gas, address to, address sender, bytes memory message)
        internal
        override
        returns (bool ok)
    {
        // forge-lint: disable-next-line(return-bomb) this contract returns nothing
        (ok,) = address(this).call{gas: gas}(abi.encodeCall(this.deliver, (to, sender, message)));
    }
}
