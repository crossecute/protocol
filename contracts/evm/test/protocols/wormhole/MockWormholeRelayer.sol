// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Relayer surface the bindings call: the 7-arg `sendPayloadToEvm` and the
///         3-arg `quoteEVMDeliveryPrice`. Enforces the real `checkMsgValue` rule (exact
///         payment, else `InvalidMsgValue`). Inbound delivery isn't simulated: tests
///         `vm.prank(address(relayer))` and call `receiveWormholeMessages` directly.
contract MockWormholeRelayer {
    struct Sent {
        uint16 targetChain;
        address targetAddress;
        bytes payload;
        uint256 receiverValue;
        uint256 gasLimit;
        uint16 refundChain;
        address refundAddress;
        uint256 value;
    }

    error InvalidMsgValue(uint256 msgValue, uint256 totalFee);

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

    function quoteEVMDeliveryPrice(uint16, uint256, uint256) external view returns (uint256, uint256) {
        return (fee, 0);
    }

    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes calldata payload,
        uint256 receiverValue,
        uint256 gasLimit,
        uint16 refundChain,
        address refundAddress
    ) external payable returns (uint64) {
        if (msg.value != fee) revert InvalidMsgValue(msg.value, fee);
        _sent.push(
            Sent(targetChain, targetAddress, payload, receiverValue, gasLimit, refundChain, refundAddress, msg.value)
        );
        return uint64(_sent.length);
    }
}
