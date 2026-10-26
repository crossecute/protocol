// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SendParam, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";

/// @notice An OFT as the `layerzero-oft` binding uses one: no tokens move, a quote is priced
///         per byte of the compose message and options, and a send refuses less than the quote.
/// @dev Records each send with its caller, which `OFTMsgCodec` would encode as `composeFrom`.
///      `receivePacket` stands in for `OFTCore._lzReceive` after its DVNs verified a packet: it
///      queues the compose `OFTComposeMsgCodec` encodes, with an amount of 0. `deliver` also
///      runs it, as the executor would.
contract MockOft {
    struct Sent {
        address from;
        SendParam param;
        uint256 value;
        address refundTo;
    }

    mapping(uint32 => bytes32) public peers;
    address public endpoint;
    uint256 public feePerByte = 1;

    Sent[] internal _sent;
    uint64 internal _nonce;

    error InsufficientFee(uint256 required, uint256 supplied);

    constructor(address endpoint_) {
        endpoint = endpoint_;
    }

    function setPeer(uint32 eid, address peer) external {
        peers[eid] = bytes32(uint256(uint160(peer)));
    }

    function quoteSend(SendParam calldata p, bool) external view returns (MessagingFee memory) {
        return MessagingFee(_price(p), 0);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address refundTo)
        external
        payable
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt)
    {
        uint256 required = _price(p);
        if (msg.value < required || fee.nativeFee < required) revert InsufficientFee(required, msg.value);
        _sent.push(Sent(msg.sender, p, msg.value, refundTo));
        receipt.fee = fee;
        oftReceipt = OFTReceipt(p.amountLD, p.amountLD);
    }

    function receivePacket(uint32 srcEid, bytes32 guid, address to, address from, bytes memory composeMsg)
        external
        returns (bytes memory message)
    {
        message = OFTComposeMsgCodec.encode(
            ++_nonce, srcEid, 0, abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(from), composeMsg)
        );
        MockLzEndpoint(endpoint).sendCompose(to, guid, 0, message);
    }

    /// @notice `receivePacket` and the executor's `lzCompose` in one call, so a test's expected
    ///         revert attaches to the delivery. `composeFrom` is 32 bytes, as the codec carries it.
    function deliver(uint32 srcEid, address to, bytes32 composeFrom, bytes memory composeMsg) external {
        bytes32 guid = keccak256(abi.encode(address(this), _nonce + 1));
        bytes memory message = OFTComposeMsgCodec.encode(++_nonce, srcEid, 0, abi.encodePacked(composeFrom, composeMsg));
        MockLzEndpoint(endpoint).sendCompose(to, guid, 0, message);
        MockLzEndpoint(endpoint).lzCompose(address(this), to, guid, 0, message, "");
    }

    function sentLength() external view returns (uint256) {
        return _sent.length;
    }

    function sent(uint256 i) external view returns (Sent memory) {
        return _sent[i];
    }

    function _price(SendParam calldata p) internal view returns (uint256) {
        return 1000 + feePerByte * (p.composeMsg.length + p.extraOptions.length);
    }
}
