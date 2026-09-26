// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice `CrossDomainMessenger` surface the bindings call, with `relayMessage`'s calling
///         convention: `relay` sets `xDomainMessageSender` to the origin-side `sender`, calls
///         `target` with `message` as raw calldata, then resets it. `message` is whatever the
///         origin-side caller chose; only `sender` is the messenger's own fact.
contract MockCrossDomainMessenger {
    struct Sent {
        address sender;
        address target;
        bytes message;
        uint32 minGasLimit;
        uint256 value;
    }

    address internal constant DEFAULT_L2_SENDER = 0x000000000000000000000000000000000000dEaD;
    address internal xDomainMsgSender = DEFAULT_L2_SENDER;
    uint256 public messageNonce;
    Sent[] internal _sent;

    function sent(uint256 i) external view returns (Sent memory) {
        return _sent[i];
    }

    function sentLength() external view returns (uint256) {
        return _sent.length;
    }

    function sendMessage(address target, bytes calldata message, uint32 minGasLimit) external payable {
        _sent.push(Sent(msg.sender, target, message, minGasLimit, msg.value));
        messageNonce++;
    }

    function xDomainMessageSender() external view returns (address) {
        require(xDomainMsgSender != DEFAULT_L2_SENDER, "CrossDomainMessenger: xDomainMessageSender is not set");
        return xDomainMsgSender;
    }

    /// @dev Bubbles the target's revert so tests can assert on it; the real messenger records
    ///      it in `failedMessages` instead.
    function relay(address sender, address target, bytes calldata message) external {
        xDomainMsgSender = sender;
        (bool ok, bytes memory ret) = target.call(message);
        xDomainMsgSender = DEFAULT_L2_SENDER;
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
