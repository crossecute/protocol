// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@ccip/libraries/Client.sol";

/// @notice Minimal Router surface the bindings actually call: `getFee`, `ccipSend`. Inbound
///         delivery isn't simulated: tests drive it with `vm.prank(address(router))` + a
///         direct `ccipReceive` call, the same shape `MockLzEndpoint` uses for LayerZero.
contract MockCcipRouter {
    struct Sent {
        uint64 destChainSelector;
        bytes receiver;
        bytes data;
        address feeToken;
        bytes extraArgs;
        uint256 value;
    }

    Sent[] internal _sent;
    uint256 public fee;

    function setFee(uint256 nativeFee) external {
        fee = nativeFee;
    }

    function sentLength() external view returns (uint256) {
        return _sent.length;
    }

    function sent(uint256 i)
        external
        view
        returns (uint64 destChainSelector, bytes memory receiver, bytes memory data, address feeToken, bytes memory extraArgs, uint256 value)
    {
        Sent storage s = _sent[i];
        return (s.destChainSelector, s.receiver, s.data, s.feeToken, s.extraArgs, s.value);
    }

    uint256 public feePerByte;

    /// @dev The Router refuses a send paying less than `getFee`, as this does.
    error InsufficientFeeTokenAmount();

    function setFeePerByte(uint256 perByte) external {
        feePerByte = perByte;
    }

    function getFee(uint64, /* destinationChainSelector */ Client.EVM2AnyMessage memory message)
        public
        view
        returns (uint256)
    {
        return fee + feePerByte * message.data.length;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        if (msg.value < getFee(destinationChainSelector, message)) revert InsufficientFeeTokenAmount();
        _sent.push(
            Sent({
                destChainSelector: destinationChainSelector,
                receiver: message.receiver,
                data: message.data,
                feeToken: message.feeToken,
                extraArgs: message.extraArgs,
                value: msg.value
            })
        );
        return keccak256(abi.encode(_sent.length, destinationChainSelector, message.data));
    }
}
