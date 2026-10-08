// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

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
