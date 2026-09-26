// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Minimal endpoint surface the bindings actually call: `quote`, `send`,
///         `setDelegate`, `lzToken`. Not `ILayerZeroEndpointV2` itself — the call sites only
///         check selector/calldata at the EVM level, so implementing the full 20-plus
///         function interface would be noise. Inbound delivery isn't simulated: tests drive
///         it with `vm.prank(address(endpoint))` + a direct `lzReceive` call.
contract MockLzEndpoint {
    struct Sent {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        uint256 value;
        address refundAddress;
    }

    Sent[] public sent;
    mapping(address => address) public delegateOf;

    MessagingFee public fee;
    uint256 public feePerByte;

    /// @dev EndpointV2 refuses a send paying less than the quote, as this does.
    error InsufficientFee(uint256 required, uint256 supplied);

    function setFee(uint256 nativeFee) external {
        fee = MessagingFee(nativeFee, 0);
    }

    function setFeePerByte(uint256 perByte) external {
        feePerByte = perByte;
    }

    function _priced(bytes calldata message) internal view returns (MessagingFee memory) {
        return MessagingFee(fee.nativeFee + feePerByte * message.length, 0);
    }

    function sentLength() external view returns (uint256) {
        return sent.length;
    }

    function quote(MessagingParams calldata _params, address /* _sender */ )
        external
        view
        returns (MessagingFee memory)
    {
        return _priced(_params.message);
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        MessagingFee memory required = _priced(_params.message);
        if (msg.value < required.nativeFee) revert InsufficientFee(required.nativeFee, msg.value);
        sent.push(
            Sent({
                dstEid: _params.dstEid,
                receiver: _params.receiver,
                message: _params.message,
                options: _params.options,
                value: msg.value,
                refundAddress: _refundAddress
            })
        );
        return MessagingReceipt({
            guid: keccak256(abi.encode(sent.length, _params.dstEid, _params.message)),
            nonce: uint64(sent.length),
            fee: required
        });
    }

    function setDelegate(address _delegate) external {
        delegateOf[msg.sender] = _delegate;
    }

    function lzToken() external pure returns (address) {
        return address(0);
    }
}
