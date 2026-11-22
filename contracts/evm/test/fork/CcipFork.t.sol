// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CcipFixture} from "test/protocols/ccip/CcipFixture.sol";
import {ProviderConduitSetup} from "test/protocols/ProviderBindingSpec.t.sol";
import {Call} from "src/messaging/Call.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {bootstrapPayload} from "test/Harness.sol";
import {createRpcFork} from "test/fork/ForkBlock.sol";
import {ICcipRouterLanes} from "script/deploy/CcipPreflight.sol";

interface ICcipOnRampSequence {
    function getExpectedNextMessageNumber(uint64 destChainSelector) external view returns (uint64);
}

/// @notice Sends a bootstrap and a payload through Ethereum's deployed CCIP Router toward Base.
contract CcipForkTest is ProviderConduitSetup, CcipFixture {
    address internal ccipRouter;
    uint256 internal bootstrapFee;
    ICcipOnRampSequence internal onRamp;

    function setUp() public override {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        ccipRouter = vm.envOr("CCIP_ROUTER_ETHEREUM", address(0));
        if (bytes(rpc).length == 0 || ccipRouter == address(0)) vm.skip(true);
        vm.selectFork(createRpcFork(vm, rpc, "ETH_FORK_BLOCK"));
        vm.setEvmVersion("cancun");
        assertEq(block.chainid, 1);
        assertGt(ccipRouter.code.length, 0);
        onRamp = ICcipOnRampSequence(ICcipRouterLanes(ccipRouter).getOnRamp(BASE_SELECTOR));
        uint64 beforeBootstrap = onRamp.getExpectedNextMessageNumber(BASE_SELECTOR);
        super.setUp();
        assertEq(onRamp.getExpectedNextMessageNumber(BASE_SELECTOR), beforeBootstrap + 1);
    }

    function _ccipRouter() internal view override returns (address) {
        return ccipRouter;
    }

    function _prepareConduit(address transmitter, address) internal override {
        bootstrapFee = TransmitterBase(payable(transmitter))
            .quoteBootstrap(bootstrapPayload(REMOTE_CHAIN_ID, new Call[](0)), _attributes());
        assertGt(bootstrapFee, 0);
    }

    function test_bootstrapAndMessagePayTheirQuotesOnTheDeployedRouter() public {
        TransmitterBase transmitter = TransmitterBase(conduit);
        assertTrue(transmitter.isBootstrappedOn(REMOTE_CHAIN_ID));
        assertEq(1 ether - conduit.balance, bootstrapFee);

        bytes memory recipient = transmitter.recipientOn(REMOTE_CHAIN_ID);
        bytes memory payload = transmitter.payloadForCalls(new Call[](0));
        uint256 quote = transmitter.quoteMessage(recipient, payload, _attributes());
        assertGt(quote, 0);
        uint256 beforeSend = conduit.balance;
        uint64 messageNumber = onRamp.getExpectedNextMessageNumber(BASE_SELECTOR);
        vm.prank(CONDUIT_OWNER);
        transmitter.sendMessage(recipient, payload, _attributes());
        assertEq(onRamp.getExpectedNextMessageNumber(BASE_SELECTOR), messageNumber + 1);
        assertEq(beforeSend - conduit.balance, quote);
    }
}
