// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOFT, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {LzMessage} from "src/protocols/layerzero/LzMessage.sol";
import {Call} from "src/messaging/Call.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

/// @notice Send and quote through an operator's OFT, and the formats the `layerzero-oft`
///         binding's two ends agree on: the destination leaf and the bootstrap compose message.
///
/// @dev Every send moves no tokens: `amountLD` and `minAmountLD` are 0, as no binding carries
///      value but its fee. The one attribute is `LzMessage.OPTIONS_ATTRIBUTE`, which replaces the
///      default lzCompose option.
library LzOftMessage {
    /// @dev Where the payload starts in the message `OFTCore` composes with: `nonce(8) |
    ///      srcEid(4) | amountLD(32) | composeFrom(32)` precede it. `OFTComposeMsgCodec` keeps
    ///      the offset private and returns the payload in memory, which a receiver cannot pass
    ///      to `_onMessageFrom`.
    uint256 internal constant COMPOSE_MSG_OFFSET = 76;

    /// @dev The OFT no longer names `expected` as its peer for `eid`.
    error PeerChanged(uint32 eid, bytes32 expected, bytes32 actual);

    /// @notice The bootstrap's compose message: what the destination factory derives the
    ///         account from and checks the sending OFT against.
    /// @dev No destination eid or OFT: the factory proves its own chain key, its endpoint's eid
    ///      and the delivering OFT into `destRoot`, so nothing here names them. `homeEid` is
    ///      bound into the address with `homeChainKey`, since nothing on a destination maps one
    ///      to the other.
    struct Bootstrap {
        address owner;
        bytes32 salt;
        bytes32 homeChainKey;
        uint32 homeEid;
        address homeOft;
        bytes32 destRoot;
        bytes32[] proof;
        Call[] calls;
    }

    /// @notice The one `SendParam` a send and its quote both use.
    function sendParam(uint32 dstEid, address to, bytes memory composeMsg, bytes[] memory attributes, uint256 gas)
        internal
        pure
        returns (SendParam memory)
    {
        return SendParam(
            dstEid, bytes32(uint256(uint160(to))), 0, 0, LzMessage.composeOptions(attributes, gas), composeMsg, ""
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

    /// @notice The root `destRoot` is, over `leaves` in the order given.
    /// @dev On a copy, so the caller's leaves are left as they were.
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            level[i] = leaves[i];
        }
        for (uint256 n = level.length; n > 1;) {
            n = _up(level, n);
        }
        return level[0];
    }

    /// @notice The sibling path `root` hashes leaf `index` along, which `MerkleProof.verify`
    ///         checks against it.
    /// @dev `level` is overwritten level by level, so the caller passes a copy.
    function proof(bytes32[] memory level, uint256 index) internal pure returns (bytes32[] memory siblings) {
        bytes32[] memory scratch = new bytes32[](64);
        uint256 depth;
        for (uint256 n = level.length; n > 1; index /= 2) {
            uint256 sibling = index ^ 1;
            if (sibling < n) scratch[depth++] = level[sibling];
            n = _up(level, n);
        }
        siblings = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            siblings[i] = scratch[i];
        }
    }

    /// @dev One level up, in place: neighbours paired with the commutative hash
    ///      `MerkleProof.verify` uses, and an unpaired last node carried up unchanged, so its
    ///      proof skips that level. Returns the new level's length.
    function _up(bytes32[] memory level, uint256 n) private pure returns (uint256) {
        for (uint256 i; i < n / 2; ++i) {
            level[i] = Hashes.commutativeKeccak256(level[2 * i], level[2 * i + 1]);
        }
        if (n % 2 == 1) level[n / 2] = level[n - 1];
        return (n + 1) / 2;
    }
}
