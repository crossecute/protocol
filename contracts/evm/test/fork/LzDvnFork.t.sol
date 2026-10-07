// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";

/// @notice An OApp that is its own delegate, as every LayerZero contract here is.
contract SelfDelegatedOApp {
    function pinSendDvn(address endpoint, uint32 eid, address dvn) external {
        LzMessage.pinSendDvn(endpoint, eid, dvn);
    }
}

/// @notice #51 against Ethereum's real endpoint: zkSync's pathway refuses every quote on the
///         dead-DVN default, and quotes once `LzMessage` pins LayerZero Labs' DVN. Skipped without
///         `ETH_RPC_URL`; reads only, so a public RPC is enough.
contract LzDvnForkTest is Test {
    ILayerZeroEndpointV2 constant ENDPOINT = ILayerZeroEndpointV2(0x1a44076050125825900e736c501f859c50fE728c);
    uint32 constant ZKSYNC_EID = 30165;
    address constant LZ_LABS_DVN = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;

    function test_aPinnedDvnMakesTheZkSyncPathwayQuotable() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        SelfDelegatedOApp oapp = new SelfDelegatedOApp();
        MessagingParams memory params = MessagingParams(
            ZKSYNC_EID, bytes32(uint256(1)), hex"00", LzMessage.options(new bytes[](0), 1_000_000), false
        );

        vm.expectRevert();
        ENDPOINT.quote(params, address(oapp));

        oapp.pinSendDvn(address(ENDPOINT), ZKSYNC_EID, LZ_LABS_DVN);
        assertGt(ENDPOINT.quote(params, address(oapp)).nativeFee, 0);
    }
}
