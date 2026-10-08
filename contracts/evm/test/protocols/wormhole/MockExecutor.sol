// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The deployed `Executor`'s `requestExecution`, with its real rules: the quote's chains
///         must match, it must not have expired, and everything sent goes to the quote's payee.
///         It neither checks the payment nor refunds.
contract MockExecutor {
    struct Request {
        uint16 dstChain;
        bytes32 dstAddr;
        address refundAddr;
        bytes signedQuote;
        bytes requestBytes;
        bytes relayInstructions;
        uint256 paid;
    }

    error QuoteSrcChainMismatch(uint16 quoteSrcChain, uint16 requestSrcChain);
    error QuoteDstChainMismatch(uint16 quoteDstChain, uint16 requestDstChain);
    error QuoteExpired(uint64 expiryTime);

    uint16 public immutable ourChain;
    Request[] internal _requests;

    constructor(uint16 ourChain_) {
        ourChain = ourChain_;
    }

    function requestsLength() external view returns (uint256) {
        return _requests.length;
    }

    function requests(uint256 i) external view returns (Request memory) {
        return _requests[i];
    }

    function requestExecution(
        uint16 dstChain,
        bytes32 dstAddr,
        address refundAddr,
        bytes calldata signedQuote,
        bytes calldata requestBytes,
        bytes calldata relayInstructions
    ) external payable {
        uint16 quoteSrc = uint16(bytes2(signedQuote[56:58]));
        uint16 quoteDst = uint16(bytes2(signedQuote[58:60]));
        uint64 expiry = uint64(bytes8(signedQuote[60:68]));
        if (quoteSrc != ourChain) revert QuoteSrcChainMismatch(quoteSrc, ourChain);
        if (quoteDst != dstChain) revert QuoteDstChainMismatch(quoteDst, dstChain);
        // forge-lint: disable-next-line(block-timestamp) the Executor's expiry rule
        if (expiry <= block.timestamp) revert QuoteExpired(expiry);
        address payee = address(uint160(uint256(bytes32(signedQuote[24:56]))));
        payable(payee).transfer(msg.value);
        _requests.push(Request(dstChain, dstAddr, refundAddr, signedQuote, requestBytes, relayInstructions, msg.value));
    }
}
