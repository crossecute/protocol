// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {DeployLzOft} from "script/DeployLzOft.s.sol";
import {LzOftLeaves} from "script/LzOftLeaves.s.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";
import {MockOft} from "test/protocols/layerzero/MockOft.sol";

/// @notice Both `layerzero-oft` scripts refuse a chain whose CREATE2 is not Ethereum's: there
///         the factory, and every account it creates, would sit at another address.
/// @dev zkSync Era is in `deploy/chains.toml` as `zksync`, with a LayerZero eid.
contract LzOftScriptsTest is Test {
    uint256 constant ZKSYNC = 324;
    uint32 constant ZKSYNC_EID = 30165;

    function test_theFactoryIsNotDeployedOnAZkSyncChain() public {
        DeployLzOft script = new DeployLzOft();
        vm.chainId(ZKSYNC);
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "layerzero-oft deploys only on a parity chain"));
        script.run();
    }

    function test_noLeavesAreBuiltForAZkSyncHome() public {
        LzOftLeaves script = new LzOftLeaves();
        MockLzEndpoint endpoint = new MockLzEndpoint();
        endpoint.setEid(ZKSYNC_EID);
        // forge-lint: disable-next-line(unsafe-cheatcode) the script's inputs are environment variables
        vm.setEnv("LZ_OFT_HOME", vm.toString(address(new MockOft(address(endpoint)))));
        // forge-lint: disable-next-line(unsafe-cheatcode) the script's inputs are environment variables
        vm.setEnv("LZ_OFT_DESTINATIONS", "ethereum");
        vm.chainId(ZKSYNC);
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, "the home is a parity chain"));
        script.run();
    }
}
