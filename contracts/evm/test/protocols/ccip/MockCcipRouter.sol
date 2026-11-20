// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/// @notice The two ramp getters the deploy preflight reads, reporting a configured `typeAndVersion`.
contract MockCcipRamp {
    string public typeAndVersion;

    constructor(string memory version) {
        typeAndVersion = version;
    }
}

/// @notice Minimal Router surface the bindings actually call: `getFee`, `ccipSend`, and the lane
///         registry `CcipPreflight` reads. Inbound
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

    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    Sent[] internal _sent;
    uint256 public fee;
    mapping(uint64 => address) public getOnRamp;
    OffRamp[] internal _offRamps;
    /// @dev A `getFee` for this selector reverts, as a Router does for a lane it does not serve.
    mapping(uint64 => bool) public unsupported;
    /// @dev A legacy lane can require `allowOutOfOrderExecution = true` and reject the default.
    bool public requireOutOfOrder;
    error ExtraArgsOutOfOrderExecutionMustBeTrue();

    /// @notice Make `onRamp` the one for sends to `selector` and `offRamp` the only one for
    ///         deliveries from it.
    function setLane(uint64 selector, address onRamp, address offRamp) external {
        getOnRamp[selector] = onRamp;
        for (uint256 i = _offRamps.length; i > 0; --i) {
            if (_offRamps[i - 1].sourceChainSelector != selector) continue;
            _offRamps[i - 1] = _offRamps[_offRamps.length - 1];
            _offRamps.pop();
        }
        _offRamps.push(OffRamp(selector, offRamp));
    }

    function clearOffRamps() external {
        delete _offRamps;
    }

    function addOffRamp(uint64 selector, address offRamp) external {
        _offRamps.push(OffRamp(selector, offRamp));
    }

    function setRequireOutOfOrder(bool value) external {
        requireOutOfOrder = value;
    }

    function setUnsupported(uint64 selector, bool value) external {
        unsupported[selector] = value;
    }

    function getOffRamps() external view returns (OffRamp[] memory) {
        return _offRamps;
    }

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
    uint256 public feePerExtraArgByte;
    bool public rejectV3;
    error V3Rejected();
    error UnsupportedDestinationChain(uint64 destChainSelector);

    function configureV3Pricing(uint256 perByte, bool reject) external {
        feePerExtraArgByte = perByte;
        rejectV3 = reject;
    }

    /// @dev The Router refuses a send paying less than `getFee`, as this does.
    error InsufficientFeeTokenAmount();

    function setFeePerByte(uint256 perByte) external {
        feePerByte = perByte;
    }

    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage memory message)
        public
        view
        returns (uint256)
    {
        if (unsupported[destinationChainSelector]) {
            revert UnsupportedDestinationChain(destinationChainSelector);
        }
        if (requireOutOfOrder && bytes4(message.extraArgs) == bytes4(0x181dcf10)) {
            bytes memory body = new bytes(message.extraArgs.length - 4);
            for (uint256 i; i < body.length; ++i) {
                body[i] = message.extraArgs[i + 4];
            }
            (, bool outOfOrder) = abi.decode(body, (uint256, bool));
            if (!outOfOrder) revert ExtraArgsOutOfOrderExecutionMustBeTrue();
        }
        if (rejectV3 && bytes4(message.extraArgs) == bytes4(0xa69dd4aa)) revert V3Rejected();
        return fee + feePerByte * message.data.length + feePerExtraArgByte * message.extraArgs.length;
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
