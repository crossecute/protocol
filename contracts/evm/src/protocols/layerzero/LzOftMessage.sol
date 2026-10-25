// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ProviderAttribute} from "src/protocols/ProviderAttribute.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {Call} from "src/messaging/Call.sol";

/// @notice Send and quote through an operator's OFT, and the formats the `layerzero-oft`
///         binding's two ends agree on: the destination leaf and the bootstrap compose message.
///
/// @dev Two attributes, accepted together: `LzMessage.OPTIONS_ATTRIBUTE`, which replaces the
///      default lzCompose option, and `AMOUNT_ATTRIBUTE`, `abi.encodePacked(selector,
///      abi.encode(amountLD))`, which is 0 when absent.
///
/// @dev `minAmountLD` is `amountLD`, so an amount the OFT would trim (dust) or charge a fee on
///      reverts in `quoteSend` and `send` alike (`OFTCore._debitView`, `SlippageExceeded`)
///      rather than delivering less than the owner approved.
library LzOftMessage {
    // forge-lint: disable-next-line(unsafe-typecast) a selector is the hash's first 4 bytes
    bytes4 internal constant AMOUNT_ATTRIBUTE = bytes4(keccak256("crossecute.lz-oft.amount"));

    /// @dev The OFT no longer names `expected` as its peer for `eid`.
    error PeerChanged(uint32 eid, bytes32 expected, bytes32 actual);

    /// @notice The bootstrap's compose message: what the destination factory derives the
    ///         account from and checks the sending OFT against.
    /// @dev No eid and no destination OFT: the factory proves its own chain key, its endpoint's
    ///      eid and the delivering OFT into `destRoot`, so nothing here names them.
    struct Bootstrap {
        address owner;
        bytes32 salt;
        bytes32 homeChainKey;
        address homeOft;
        bytes32 destRoot;
        bytes32[] proof;
        Call[] calls;
    }

    function supportedAttributes() internal pure returns (bytes4[] memory supported) {
        supported = new bytes4[](2);
        supported[0] = LzMessage.OPTIONS_ATTRIBUTE;
        supported[1] = AMOUNT_ATTRIBUTE;
    }

    /// @notice The one `SendParam` a send and its quote both use.
    function sendParam(uint32 dstEid, address to, bytes memory composeMsg, bytes[] memory attributes, uint256 gas)
        internal
        pure
        returns (SendParam memory)
    {
        uint256 amountLD = amount(attributes);
        return
            SendParam(
                dstEid, bytes32(uint256(uint160(to))), amountLD, amountLD, options(attributes, gas), composeMsg, ""
            );
    }

    /// @dev The fee is paid from this contract's balance, so `value` is the quote, not `msg.value`.
    function send(address oft, SendParam memory param, uint256 value, address refundTo) internal {
        // The guid and the receipt are in the endpoint's and the OFT's events.
        // forge-lint: disable-start(unused-return)
        IOFT(oft).send{value: value}(param, MessagingFee(value, 0), refundTo);
        // forge-lint: disable-end(unused-return)
    }

    function quote(address oft, SendParam memory param) internal view returns (uint256) {
        return IOFT(oft).quoteSend(param, false).nativeFee;
    }

    function amount(bytes[] memory attributes) internal pure returns (uint256) {
        (bool present, bytes memory body) =
            ProviderAttribute.bodyAmong(attributes, AMOUNT_ATTRIBUTE, supportedAttributes());
        if (!present) return 0;
        if (body.length != 32) revert ProviderAttribute.UnsupportedAttribute(abi.encodePacked(AMOUNT_ATTRIBUTE, body));
        return abi.decode(body, (uint256));
    }

    function options(bytes[] memory attributes, uint256 gas) internal pure returns (bytes memory out) {
        bool present;
        (present, out) = ProviderAttribute.bodyAmong(attributes, LzMessage.OPTIONS_ATTRIBUTE, supportedAttributes());
        if (!present) out = LzMessage.composeOptions(gas);
    }

    /// @notice Refuse unless `oft` still names `expected` as its peer for `eid`.
    function requirePeer(address oft, uint32 eid, address expected) internal view {
        bytes32 actual = IOAppCore(oft).peers(eid);
        bytes32 want = bytes32(uint256(uint160(expected)));
        if (actual != want) revert PeerChanged(eid, want, actual);
    }

    /// @notice A destination's leaf in an account's `destRoot`.
    /// @dev Hashed twice, so a 64-byte inner node of the tree is never read as a leaf.
    function leaf(bytes32 chainKey, uint32 eid, address oft) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(chainKey, eid, oft))));
    }

    function encodeBootstrap(Bootstrap memory b) internal pure returns (bytes memory) {
        return abi.encode(b);
    }

    function decodeBootstrap(bytes memory message) internal pure returns (Bootstrap memory) {
        return abi.decode(message, (Bootstrap));
    }
}
