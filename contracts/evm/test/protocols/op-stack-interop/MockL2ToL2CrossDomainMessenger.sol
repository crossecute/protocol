// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice `L2ToL2CrossDomainMessenger` surface the binding calls. `relay` stands in for
///         `relayMessage`: it sets the context to the origin's sender and chain, calls `target`
///         with `message` as raw calldata, then clears it. `sendMessage` returns a non-zero
///         hash, as the predeploy does, so a binding that passed it on would be caught.
contract MockL2ToL2CrossDomainMessenger {
    struct Sent {
        uint256 destination;
        address target;
        bytes message;
        address sender;
    }

    error NotEntered();
    error MessageDestinationSameChain();

    Sent[] internal _sent;
    bool internal _entered;
    address internal _sender;
    uint256 internal _source;

    function sendMessage(uint256 destination, address target, bytes calldata message) external returns (bytes32) {
        if (destination == block.chainid) revert MessageDestinationSameChain();
        _sent.push(Sent(destination, target, message, msg.sender));
        return keccak256(abi.encode(destination, target, message, _sent.length));
    }

    function sent(uint256 i) external view returns (Sent memory) {
        return _sent[i];
    }

    function sentLength() external view returns (uint256) {
        return _sent.length;
    }

    function crossDomainMessageContext() external view returns (address, uint256) {
        if (!_entered) revert NotEntered();
        return (_sender, _source);
    }

    /// @dev Bubbles the target's revert so tests can assert on it.
    function relay(uint256 source, address sender, address target, bytes calldata message) external {
        (_entered, _sender, _source) = (true, sender, source);
        (bool ok, bytes memory ret) = target.call(message);
        (_entered, _sender, _source) = (false, address(0), 0);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
