// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @notice Minimal endpoint surface the bindings actually call: `quote`, `send`,
///         `setDelegate`, `lzToken`, and the library and config calls `LzMessage` pins a DVN
///         with, authorized as EndpointV2 does (the OApp or its delegate). Not `ILayerZeroEndpointV2` itself — the call sites only
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

    function quote(
        MessagingParams calldata _params,
        address /* _sender */
    )
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

    address public constant SEND_LIBRARY = address(0x5E9D);
    address public constant RECEIVE_LIBRARY = address(0x7EC5);

    mapping(address => mapping(uint32 => address)) public sendLibraryOf;
    mapping(address => mapping(uint32 => address)) public receiveLibraryOf;
    /// oapp => library => eid => config type => the bytes last set.
    mapping(address => mapping(address => mapping(uint32 => mapping(uint32 => bytes)))) internal _configs;

    /// @dev EndpointV2's `LZ_Unauthorized`.
    error Unauthorized();

    function _authorize(address oapp) internal view {
        if (msg.sender != oapp && msg.sender != delegateOf[oapp]) revert Unauthorized();
    }

    function defaultSendLibrary(uint32) external pure returns (address) {
        return SEND_LIBRARY;
    }

    function defaultReceiveLibrary(uint32) external pure returns (address) {
        return RECEIVE_LIBRARY;
    }

    function setSendLibrary(address oapp, uint32 eid, address lib) external {
        _authorize(oapp);
        sendLibraryOf[oapp][eid] = lib;
    }

    function setReceiveLibrary(address oapp, uint32 eid, address lib, uint256) external {
        _authorize(oapp);
        receiveLibraryOf[oapp][eid] = lib;
    }

    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external {
        _authorize(oapp);
        for (uint256 i; i < params.length; ++i) {
            _configs[oapp][lib][params[i].eid][params[i].configType] = params[i].config;
        }
    }

    function configOf(address oapp, address lib, uint32 eid, uint32 configType) external view returns (bytes memory) {
        return _configs[oapp][lib][eid][configType];
    }
}
