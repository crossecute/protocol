// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CoreBridgeVM, GuardianSignature} from "@wormhole-sdk/interfaces/ICoreBridge.sol";

/// @notice Core bridge surface the bindings call. `parseAndVerifyVM` parses a real VAA v1
///         layout (signatures are not checked; a non-v1 version, or `setInvalid`, fails it) and
///         returns `hash` as Core does, keccak256(keccak256(body)).
contract MockWormholeCore {
    uint16 public chainId;
    uint256 public messageFee;
    bool public invalid;
    bytes public payloadOverride;
    bool public overridePayload;
    mapping(address => uint64) public nextSequence;

    struct Published {
        address emitter;
        bytes payload;
        uint8 consistencyLevel;
        uint256 value;
    }

    Published[] internal _published;

    constructor(uint16 chainId_) {
        chainId = chainId_;
    }

    function setMessageFee(uint256 fee) external {
        messageFee = fee;
    }

    function setInvalid(bool invalid_) external {
        invalid = invalid_;
    }

    /// @dev Makes Core report a payload different from the one in the VAA bytes.
    function setPayloadOverride(bytes calldata payload) external {
        payloadOverride = payload;
        overridePayload = true;
    }

    function publishedLength() external view returns (uint256) {
        return _published.length;
    }

    function published(uint256 i) external view returns (Published memory) {
        return _published[i];
    }

    function publishMessage(uint32, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence)
    {
        require(msg.value == messageFee, "invalid fee");
        _published.push(Published(msg.sender, payload, consistencyLevel, msg.value));
        sequence = nextSequence[msg.sender]++;
    }

    function parseAndVerifyVM(bytes calldata vaa)
        external
        view
        returns (CoreBridgeVM memory vm, bool valid, string memory reason)
    {
        uint256 body = 6 + uint256(uint8(vaa[5])) * 66;
        vm.version = uint8(vaa[0]);
        vm.emitterChainId = uint16(bytes2(vaa[body + 8:body + 10]));
        vm.emitterAddress = bytes32(vaa[body + 10:body + 42]);
        vm.sequence = uint64(bytes8(vaa[body + 42:body + 50]));
        vm.consistencyLevel = uint8(vaa[body + 50]);
        vm.payload = vaa[body + 51:];
        if (overridePayload) vm.payload = payloadOverride;
        vm.signatures = new GuardianSignature[](0);
        vm.hash = keccak256(abi.encodePacked(keccak256(vaa[body:])));
        if (vm.version != 1) return (vm, false, "VM version incompatible");
        if (invalid) return (vm, false, "VM signature invalid");
        return (vm, true, "");
    }
}
