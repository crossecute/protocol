// SPDX-License-Identifier: MIT OR Apache-2.0

// Vendored, unmodified, from hyperlane-xyz/hyperlane-monorepo @ 983831f6
// (solidity/contracts/interfaces/IMessageRecipient.sol).
// MIT OR Apache-2.0, like the rest of its source repo. No OpenZeppelin imports, unlike
// MailboxClient/Router. See docs/provider-research.md#5-hyperlane-as-a-native-binding.

pragma solidity >=0.6.11;

interface IMessageRecipient {
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _message
    ) external payable;
}
