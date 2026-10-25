// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {check, DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {LzOftDeploy, LzOftDestination} from "script/deploy/LzOftDeploy.sol";
import {LzOftFactory} from "src/protocols/layerzero/LzOftFactory.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";

/// @title LzOftLeaves
/// @notice The destination list a `layerzero-oft` account is created with, built and checked.
///         Reads nothing it is not told and sends nothing: the operator passes the result to
///         `LzOftFactory.createTransmitter`.
///
/// @dev Run on the home chain. From the environment: `LZ_OFT_HOME`, the operator's OFT here, and
///      `LZ_OFT_DESTINATIONS`, comma-separated `deploy/chains.toml` names. Each destination's eid
///      comes from `deploy/providers/layerzero.toml` and its OFT from the home OFT's peers. Each
///      is then checked on its own chain over `<NAME>_RPC_URL`, the one check the home factory
///      cannot make: that the eid is that chain's.
contract LzOftLeaves is Script {
    function run() external returns (LzOftFactory.Leaf[] memory leaves, bytes32 destRoot) {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        address homeOft = vm.envAddress("LZ_OFT_HOME");
        uint32 homeEid = IOAppCore(homeOft).endpoint().eid();
        ChainEntry memory home = ChainConfig.chainWithId(cs, block.chainid);
        check(home.derivation == Derivation.Parity, "the home is a parity chain");
        check(ChainConfig.providerId(dir, cs, "layerzero", home) == homeEid, "the home OFT's eid is layerzero.toml's");

        string[] memory names = vm.envString("LZ_OFT_DESTINATIONS", ",");
        LzOftDestination[] memory destinations = new LzOftDestination[](names.length);
        for (uint256 i; i < names.length; ++i) {
            ChainEntry memory c = ChainConfig.chainNamed(cs, names[i]);
            check(c.derivation == Derivation.Parity, "a destination is a parity chain");
            uint256 eid = ChainConfig.providerId(dir, cs, "layerzero", c);
            check(eid != 0, "layerzero reaches the destination");
            // forge-lint: disable-next-line(unsafe-typecast) checked against id_bits = 32
            destinations[i] = LzOftDestination(c.chainId, uint32(eid));
        }
        leaves = LzOftDeploy.leaves(homeOft, destinations);

        uint256 homeFork = vm.activeFork();
        for (uint256 i; i < leaves.length; ++i) {
            string memory name = _nameOf(cs, leaves[i].chainKey);
            vm.createSelectFork(vm.envString(string.concat(vm.toUppercase(name), "_RPC_URL")));
            LzOftDeploy.checkOnDestination(leaves[i], homeEid, homeOft);
        }
        vm.selectFork(homeFork);

        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            hashes[i] = LzOftMessage.leaf(leaves[i].chainKey, leaves[i].eid, leaves[i].oft);
            console2.log(_nameOf(cs, leaves[i].chainKey), leaves[i].eid, leaves[i].oft);
        }
        destRoot = LzOftMessage.root(hashes);
        console2.log("leaves, abi-encoded for createTransmitter:");
        console2.logBytes(abi.encode(leaves));
        console2.log("destRoot:");
        console2.logBytes32(destRoot);
    }

    function _nameOf(ChainEntry[] memory cs, bytes32 chainKey) private pure returns (string memory) {
        for (uint256 i; i < cs.length; ++i) {
            if (chainKey == ChainKey.forEvm(cs[i].chainId)) return cs[i].name;
        }
        revert DeployCheck("a leaf's chain is in chains.toml");
    }
}
