// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {LzOftConduitFactory} from "src/protocols/layerzero/LzOftConduitFactory.sol";
import {LzOftReceiver} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftTransmitter} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {receiverAuthorityPins} from "script/deploy/TransceiverDeploy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ARACHNID, arachnidDeploy, check} from "script/deploy/ProxyDeploy.sol";

/// @notice A destination as an operator names it: its EVM chain id and LayerZero eid.
struct LzOftDestination {
    uint256 chainId;
    uint32 eid;
}

/// @title LzOftDeploy
/// @notice The `layerzero-oft` contracts, deployed where production puts them, and the checks a
///         conduit's destination list must pass, shared by the scripts and the fork test.
library LzOftDeploy {
    /// @notice The factory, deployed with its logic through Arachnid's factory at salt zero on
    ///         first use, so all three sit at one address on every chain that runs the same
    ///         build, receiver pins and treasury.
    function factory(address treasury) internal returns (LzOftConduitFactory f) {
        (address guard, address multiSendCallOnly) = receiverAuthorityPins();
        return factory(treasury, guard, multiSendCallOnly);
    }

    function factory(address treasury, address guard, address multiSendCallOnly)
        internal
        returns (LzOftConduitFactory f)
    {
        (bytes memory transmitterCode, bytes memory receiverCode, bytes memory factoryCode) =
            _initcode(treasury, guard, multiSendCallOnly);
        address t = arachnidDeploy(transmitterCode);
        address r = arachnidDeploy(receiverCode);
        f = LzOftConduitFactory(arachnidDeploy(factoryCode));
        check(f.transmitterImplementation() == t, "the factory arms transmitters with the logic beside it");
        check(f.receiverImplementation() == r, "the factory arms receivers with the logic beside it");
        check(f.treasury() == treasury, "the factory fixes the fee treasury");
        check(f.localChainKey() == ChainKey.local(), "the factory names this chain");
    }

    function predictFactory(address treasury) internal view returns (address) {
        (address guard, address multiSendCallOnly) = receiverAuthorityPins();
        return predictFactory(treasury, guard, multiSendCallOnly);
    }

    /// @notice The factory address for this treasury and receiver authority pins.
    function predictFactory(address treasury, address guard, address multiSendCallOnly)
        internal
        pure
        returns (address)
    {
        (,, bytes memory factoryCode) = _initcode(treasury, guard, multiSendCallOnly);
        return _at(factoryCode);
    }

    function requireFactory(address treasury, address expected) internal view {
        check(expected != address(0), "the release's factory address is supplied");
        check(
            predictFactory(treasury) == expected,
            "the deployment inputs yield the factory address recorded for the release"
        );
    }

    function _initcode(address treasury, address guard, address multiSendCallOnly)
        private
        pure
        returns (bytes memory transmitterCode, bytes memory receiverCode, bytes memory factoryCode)
    {
        transmitterCode = type(LzOftTransmitter).creationCode;
        receiverCode = abi.encodePacked(type(LzOftReceiver).creationCode, abi.encode(guard, multiSendCallOnly));
        factoryCode = abi.encodePacked(
            type(LzOftConduitFactory).creationCode,
            abi.encode(_at(transmitterCode), _at(receiverCode), treasury)
        );
    }

    function _at(bytes memory initCode) private pure returns (address) {
        return Create2.computeAddress(bytes32(0), keccak256(initCode), ARACHNID);
    }

    /// @notice The leaves `createTransmitter` takes for `destinations`, read from `homeOft`'s
    ///         peers on this chain, in the ascending `chainKey` order it requires.
    function leaves(address homeOft, LzOftDestination[] memory destinations)
        internal
        view
        returns (LzOftConduitFactory.Leaf[] memory out)
    {
        out = new LzOftConduitFactory.Leaf[](destinations.length);
        for (uint256 i; i < destinations.length; ++i) {
            bytes32 peer = IOAppCore(homeOft).peers(destinations[i].eid);
            check(peer != bytes32(0) && uint256(peer) >> 160 == 0, "the home OFT peers an EVM OFT for the eid");
            out[i] = LzOftConduitFactory.Leaf(
                ChainKey.forEvm(destinations[i].chainId), destinations[i].eid, address(uint160(uint256(peer)))
            );
        }
        for (uint256 i = 1; i < out.length; ++i) {
            for (uint256 j = i; j > 0 && out[j - 1].chainKey > out[j].chainKey; --j) {
                (out[j - 1], out[j]) = (out[j], out[j - 1]);
            }
        }
    }

    /// @notice On the destination's own chain: the leaf names this chain, its OFT's endpoint
    ///         has the leaf's eid, and the OFT peers `homeOft` back.
    /// @dev The home factory cannot check the first two, so a leaf that fails them would be
    ///      bound into the conduit's address and its bootstrap would never land.
    function checkOnDestination(LzOftConduitFactory.Leaf memory leaf, uint32 homeEid, address homeOft) internal view {
        check(leaf.chainKey == ChainKey.local(), "the leaf names the chain it is checked on");
        check(IOAppCore(leaf.oft).endpoint().eid() == leaf.eid, "the destination OFT's endpoint has the leaf's eid");
        check(
            IOAppCore(leaf.oft).peers(homeEid) == bytes32(uint256(uint160(homeOft))),
            "the destination OFT peers the home OFT"
        );
    }
}
