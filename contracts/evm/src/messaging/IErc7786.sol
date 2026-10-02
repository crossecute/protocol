// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

/// @title IErc7786
/// @notice ERC-7786's two interfaces, vendored: the send surface `TransmitterBase` implements
///         and the receive surface `ReceiverBase` implements.
///
/// @dev Copied from `@openzeppelin/contracts/interfaces/draft-IERC7786.sol` at v5.5.0;
///      only this header and the file name differ. Vendored because the ERC is a draft and
///      these selectors and the event topic are this protocol's ABI: an upstream change becomes
///      a reviewed edit rather than a side effect of a dependency bump.
///
/// @dev OpenZeppelin's types and these are distinct to Solidity. Integrators import from
///      here; a binding whose SDK returns OpenZeppelin's variant casts through the address.

/// @dev Interface for ERC-7786 source gateways.
interface IERC7786GatewaySource {
    /// @dev Emitted when a message is created. If `sendId` is zero, no further processing is
    ///      necessary. If `sendId` is not zero, then further (gateway specific, and
    ///      non-standardized) action is required.
    event MessageSent(
        bytes32 indexed sendId,
        bytes sender, // Binary Interoperable Address
        bytes recipient, // Binary Interoperable Address
        bytes payload,
        uint256 value,
        bytes[] attributes
    );

    /// @dev Thrown when a message creation fails because of an unsupported attribute.
    error UnsupportedAttribute(bytes4 selector);

    /// @dev Whether an attribute is supported or not.
    function supportsAttribute(bytes4 selector) external view returns (bool);

    /// @dev Endpoint for creating a new message. If the message requires further (gateway
    ///      specific) processing before it can be sent to the destination chain, then a
    ///      non-zero `sendId` must be returned. Otherwise, the message MUST be sent and this
    ///      function must return 0.
    ///
    ///      MUST emit a {MessageSent} event.
    ///
    ///      If any of the `attributes` is not supported, this function SHOULD revert with an
    ///      {UnsupportedAttribute} error. Other errors SHOULD revert with errors not
    ///      specified in ERC-7786.
    function sendMessage(
        bytes calldata recipient, // Binary Interoperable Address
        bytes calldata payload,
        bytes[] calldata attributes
    )
        external
        payable
        returns (bytes32 sendId);
}

/// @dev Interface for the ERC-7786 client contract (receiver).
interface IERC7786Recipient {
    /// @dev Endpoint for receiving a cross-chain message. May be called directly by the
    ///      gateway.
    function receiveMessage(
        bytes32 receiveId,
        bytes calldata sender, // Binary Interoperable Address
        bytes calldata payload
    )
        external
        payable
        returns (bytes4);
}
