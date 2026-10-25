// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SendParam, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {MockLzEndpoint} from "test/protocols/layerzero/MockLzEndpoint.sol";

/// @notice The send side of an OFT as `OFTCore` behaves: a quote priced per byte of the compose
///         message, a send that refuses less than the quote, and `_debitView`'s dust removal
///         and slippage check, against a decimal conversion rate the test sets.
/// @dev Records each send with its caller, which `OFTMsgCodec` would encode as `composeFrom`.
///      `receivePacket` stands in for `OFTCore._lzReceive` after its DVNs verified a packet:
///      it credits `to`, then queues the compose `OFTComposeMsgCodec` encodes.
contract MockOft {
    struct Sent {
        address from;
        SendParam param;
        uint256 value;
        address refundTo;
    }

    mapping(uint32 => bytes32) public peers;
    address public endpoint;
    uint256 public decimalConversionRate = 1;
    uint256 public feePerByte = 1;

    Sent[] internal _sent;

    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD);
    error InsufficientFee(uint256 required, uint256 supplied);

    constructor(address endpoint_) {
        endpoint = endpoint_;
    }

    function setPeer(uint32 eid, address peer) external {
        peers[eid] = bytes32(uint256(uint160(peer)));
    }

    function setDecimalConversionRate(uint256 rate) external {
        decimalConversionRate = rate;
    }

    function token() external view returns (address) {
        return address(this);
    }

    function quoteSend(SendParam calldata p, bool) external view returns (MessagingFee memory) {
        _debitView(p);
        return MessagingFee(_price(p), 0);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address refundTo)
        external
        payable
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt)
    {
        uint256 sentLD = _debitView(p);
        uint256 required = _price(p);
        if (msg.value < required || fee.nativeFee < required) revert InsufficientFee(required, msg.value);
        _sent.push(Sent(msg.sender, p, msg.value, refundTo));
        receipt.fee = fee;
        oftReceipt = OFTReceipt(sentLD, sentLD);
    }

    mapping(address => uint256) public balanceOf;
    uint64 internal _nonce;

    /// @dev `OFTCore._lzReceive`: credit, then queue the compose with the endpoint.
    function receivePacket(
        uint32 srcEid,
        bytes32 guid,
        address to,
        uint256 amountLD,
        address from,
        bytes memory composeMsg
    ) external returns (bytes memory message) {
        balanceOf[to] += amountLD;
        message = OFTComposeMsgCodec.encode(
            ++_nonce, srcEid, amountLD, abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(from), composeMsg)
        );
        MockLzEndpoint(endpoint).sendCompose(to, guid, 0, message);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function sentLength() external view returns (uint256) {
        return _sent.length;
    }

    function sent(uint256 i) external view returns (Sent memory) {
        return _sent[i];
    }

    function _debitView(SendParam calldata p) internal view returns (uint256 sentLD) {
        sentLD = (p.amountLD / decimalConversionRate) * decimalConversionRate;
        if (sentLD < p.minAmountLD) revert SlippageExceeded(sentLD, p.minAmountLD);
    }

    function _price(SendParam calldata p) internal view returns (uint256) {
        return 1000 + feePerByte * (p.composeMsg.length + p.extraOptions.length);
    }
}
