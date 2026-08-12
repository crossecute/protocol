// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title GatewayBound
/// @notice Which transport this contract trusts, declared once and answered in one place.
///
/// @dev IT IS SHARED BECAUSE THE TWO DIRECTIONS MUST NAME THE SAME GATEWAY. A contract that
///      accepted deliveries from one address while sending through another would be trusting
///      two transports and authenticating against one, and nothing would say so: the send
///      would work, the return path would work, and only a message from the second gateway
///      would be silently refused. One declaration per contract makes that unrepresentable.
///
/// @dev `ReceiverBase` CANNOT REACH IT THROUGH `OutboundBase`, which is why this is its own
///      file rather than a member of either. A receiver never sends, so it deliberately does
///      not inherit the outbound half; but it is the contract with the strictest need to know
///      which gateway is real, since `receiveMessage` is `external` and this check is one of
///      the two things standing in front of it.
///
/// @dev DECLARED, NOT IMPLEMENTED, for the same reason `isAdmin` is on the transceiver:
///      which gateway is trusted is a property of the protocol binding, and a base that
///      guessed would either name a contract that does not exist on this chain or accept one
///      that should not be trusted.
abstract contract GatewayBound {
    /// @dev Something that is not a gateway this contract trusts tried to deliver a message,
    ///      or a binding tried to send through one.
    error NotAuthorizedGateway(address gateway);

    /// @notice Whether `gateway` may carry this contract's messages, in either direction.
    function _isAuthorizedGateway(address gateway) internal view virtual returns (bool);

    /// @notice The same question, for a caller checking before it spends anything.
    function isAuthorizedGateway(address gateway) external view returns (bool) {
        return _isAuthorizedGateway(gateway);
    }

    /// @notice Revert unless `gateway` is the one this contract trusts.
    ///
    /// @dev THE INBOUND SIDE CALLS THIS AND THE OUTBOUND SIDE SHOULD. A receiver's
    ///      `receiveMessage` is `external`, so the check is load-bearing there and the base
    ///      performs it. On the way out the base cannot: `_sendMessage` is the binding's, and
    ///      only the binding knows which address it is about to call. What this gives that
    ///      side is the same answer, so a binding that asserts against it before sending
    ///      cannot drift from the one its receiver enforces.
    function _requireAuthorizedGateway(address gateway) internal view {
        if (!_isAuthorizedGateway(gateway)) revert NotAuthorizedGateway(gateway);
    }
}
