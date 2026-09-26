// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Mailbox surface the bindings call: the 4-arg `dispatch`/`quoteDispatch`.
///         Refunds overpayment the way the IGP hook does: to the StandardHookMetadata
///         `refundAddress` when present, else to the dispatching contract. Inbound delivery
///         isn't simulated: tests `vm.prank(address(mailbox))` and call `handle` directly.
contract MockHyperlaneMailbox {
    struct Sent {
        uint32 destinationDomain;
        bytes32 recipientAddress;
        bytes body;
        bytes metadata;
        uint256 value;
        address refundTo;
    }

    Sent[] internal _sent;
    uint256 public fee;

    function setFee(uint256 nativeFee) external {
        fee = nativeFee;
    }

    function sentLength() external view returns (uint256) {
        return _sent.length;
    }

    function sent(uint256 i) external view returns (Sent memory) {
        return _sent[i];
    }

    uint256 public feePerByte;

    function setFeePerByte(uint256 perByte) external {
        feePerByte = perByte;
    }

    function quoteDispatch(uint32, bytes32, bytes calldata body, bytes calldata) public view returns (uint256) {
        return fee + feePerByte * body.length;
    }

    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata body, bytes calldata metadata)
        external
        payable
        returns (bytes32)
    {
        uint256 required = quoteDispatch(destinationDomain, recipientAddress, body, metadata);
        require(msg.value >= required, "insufficient fee");
        address refundTo = metadata.length >= 86 ? address(bytes20(metadata[66:86])) : msg.sender;
        _sent.push(Sent(destinationDomain, recipientAddress, body, metadata, msg.value, refundTo));
        if (msg.value > required) {
            (bool ok,) = refundTo.call{value: msg.value - required}("");
            require(ok, "refund failed");
        }
        return keccak256(abi.encode(_sent.length, destinationDomain, body));
    }
}
