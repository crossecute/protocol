// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @dev `UlnBase.UlnConfig` in LayerZero's message libraries, which are not vendored.
struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

/// @notice Send and quote for every LayerZero sender, and the one attribute they accept:
///         execution options, as `abi.encodePacked(OPTIONS_ATTRIBUTE, rawOptionsBytes)`.
///
/// @dev `send` and `quote` are `public`, so they are deployed once and linked, as
///      `WormholeMessage` is (#29); inlined, they put the zkSync and Tron transceivers over
///      EIP-170. A linked call is a `DELEGATECALL`, so `address(this)` is the OApp and it pays
///      from its own balance.
///
/// @dev They call the endpoint directly rather than OApp's `_lzSend`, whose default
///      `_payNative` requires `msg.value` to equal the fee: an account pays from its balance,
///      a bootstrap from `msg.value` less the transceiver's fee, a report from the float (#55).
library LzMessage {
    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant OPTIONS_ATTRIBUTE = bytes4(keccak256("crossecute.lz.options"));

    /// @dev Returns nothing: a send's id is ERC-7786's zero, and the guid is in the endpoint's
    ///      `PacketSent` event.
    function send(
        // forge-lint: disable-next-line(missing-zero-check) the caller's endpoint, refused at zero in its constructor
        address endpoint,
        uint32 dstEid,
        bytes32 peer,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 defaultGas,
        uint256 value,
        address refundTo
    ) public {
        // The guid is in the endpoint's event.
        // forge-lint: disable-start(unused-return)
        ILayerZeroEndpointV2(endpoint).send{value: value}(
            MessagingParams(dstEid, peer, payload, options(attributes, defaultGas), false), refundTo
        );
        // forge-lint: disable-end(unused-return)
    }

    function quote(
        address endpoint,
        uint32 dstEid,
        bytes32 peer,
        bytes memory payload,
        bytes[] memory attributes,
        uint256 defaultGas
    ) public view returns (uint256) {
        return ILayerZeroEndpointV2(endpoint)
        .quote(MessagingParams(dstEid, peer, payload, options(attributes, defaultGas), false), address(this))
        .nativeFee;
    }

    /// @dev `CONFIG_TYPE_ULN` in LayerZero's `SendUln302` and `ReceiveUln302`.
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    /// @dev `UlnBase.NIL_DVN_COUNT`: no optional DVNs, rather than the default's.
    uint8 internal constant NIL_DVN_COUNT = type(uint8).max;

    /// @notice Verify what this OApp sends to `eid` with `dvn` alone, on today's default send
    ///         library, which it keeps.
    /// @dev For a pathway whose default is LayerZero's dead DVN, which refuses every message
    ///      (#51). The library is pinned because the config is per library: a new default would
    ///      fall back to the dead DVN. `confirmations` 0 keeps the pathway's default. The caller
    ///      must be its own delegate.
    function pinSendDvn(address endpoint, uint32 eid, address dvn) public {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoint);
        address lib = ep.defaultSendLibrary(eid);
        ep.setSendLibrary(address(this), eid, lib);
        ep.setConfig(address(this), lib, _onlyDvn(eid, dvn));
    }

    /// @notice `pinSendDvn` for what this OApp accepts from `eid`.
    function pinReceiveDvn(address endpoint, uint32 eid, address dvn) public {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoint);
        address lib = ep.defaultReceiveLibrary(eid);
        ep.setReceiveLibrary(address(this), eid, lib, 0);
        ep.setConfig(address(this), lib, _onlyDvn(eid, dvn));
    }

    function _onlyDvn(uint32 eid, address dvn) private pure returns (SetConfigParam[] memory params) {
        address[] memory required = new address[](1);
        required[0] = dvn;
        params = new SetConfigParam[](1);
        params[0] = SetConfigParam(
            eid, ULN_CONFIG_TYPE, abi.encode(UlnConfig(0, 1, NIL_DVN_COUNT, 0, required, new address[](0)))
        );
    }

    /// @dev Without the attribute: type-3 options with one executor `lzReceive` option carrying
    ///      `defaultGas` and no value. Empty options revert in the send library
    ///      (`LZ_ULN_InvalidWorkerOptions`), and no OApp here sets enforced options (#50).
    function options(bytes[] memory attributes, uint256 defaultGas) internal pure returns (bytes memory out) {
        bool present;
        (present, out) = ProviderAttribute.body(attributes, OPTIONS_ATTRIBUTE, 0);
        // forge-lint: disable-next-line(unsafe-typecast) a `DeliveryGas` constant
        if (!present) out = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(defaultGas));
    }
}
