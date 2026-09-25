// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice `ExecutorQuoterRouter` surface the bindings call, with its real payment rule:
///         revert `Underpaid` below the quote, refund any excess to `refundAddr`.
contract MockExecutorQuoterRouter {
    struct Request {
        uint16 dstChain;
        bytes32 dstAddr;
        address refundAddr;
        address quoterAddr;
        bytes requestBytes;
        bytes relayInstructions;
        uint256 paid;
    }

    error Underpaid(uint256 provided, uint256 expected);

    uint256 public fee;
    Request[] internal _requests;

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function requestsLength() external view returns (uint256) {
        return _requests.length;
    }

    function requests(uint256 i) external view returns (Request memory) {
        return _requests[i];
    }

    function quoteExecution(uint16, bytes32, address, address, bytes calldata, bytes calldata)
        external
        view
        returns (uint256)
    {
        return fee;
    }

    function requestExecution(
        uint16 dstChain,
        bytes32 dstAddr,
        address refundAddr,
        address quoterAddr,
        bytes calldata requestBytes,
        bytes calldata relayInstructions
    ) external payable {
        if (msg.value < fee) revert Underpaid(msg.value, fee);
        _requests.push(Request(dstChain, dstAddr, refundAddr, quoterAddr, requestBytes, relayInstructions, fee));
        if (msg.value > fee) {
            (bool ok,) = payable(refundAddr).call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
    }
}
