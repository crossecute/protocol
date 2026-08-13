// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Treasury
/// @notice Where a transceiver's fees land, and the one contract that can move them out.
///
/// @dev IT IS A DESTINATION, NOT AN AUTHORITY. Nothing here configures a transceiver, decides
///      which payloads are authentic, or reaches an account. It holds a balance and hands it
///      to whoever its owner names, which is why it can afford to be this small and why the
///      role that points at it grants nothing beyond being paid.
///
/// @dev THE OWNER IS EXPECTED TO BE THE CROSSECUTE MSIG, and `Ownable` rather than a role
///      because there is nothing here to separate: a treasury has exactly one authority and
///      two operations. `TREASURY_ROLE` on a transceiver names WHERE fees may go; this
///      contract decides where they go NEXT, and the two questions are deliberately answered
///      by different contracts, so a compromised withdrawal path cannot repoint the flow of
///      fees at its source.
///
/// @dev IT IS NOT UPGRADEABLE AND HOLDS NO CREATE2 PROMISE. Nothing derives an address from
///      it and no account's identity depends on it, so it is a plain deployment: a treasury
///      lost on one chain is a treasury redeployed and re-granted, not a population stranded.
contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Native currency left this treasury.
    event NativeWithdrawn(address indexed to, uint256 amount);

    /// @notice An ERC-20 balance left this treasury.
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @dev A withdrawal to the zero address burns the balance, and never on purpose.
    error ZeroRecipient();

    /// @dev The native transfer failed, carrying the recipient's reason out rather than a
    ///      bare boolean.
    error NativeTransferFailed(address to, uint256 amount, bytes reason);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Accept fees. A transceiver's `withdrawFees` is a plain value transfer, so
    ///         without this the withdrawal it is the destination of would revert.
    receive() external payable {}

    /// @notice Send `amount` of native currency to `to`.
    /// @dev AN AMOUNT RATHER THAN "EVERYTHING", because a treasury pays several parties from
    ///      one balance and draining is the special case rather than the operation. `balance`
    ///      is readable, so "everything" costs the caller one read.
    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroRecipient();

        // A call rather than `transfer`: the 2300-gas stipend is not survivable by a msig
        // recipient, and this contract holds no state a re-entrant call could confuse.
        (bool ok, bytes memory reason) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount, reason);

        emit NativeWithdrawn(to, amount);
    }

    /// @notice Send `amount` of `token` to `to`.
    /// @dev `SafeERC20` BECAUSE FEE TOKENS ARE NOT ALWAYS WELL BEHAVED. USDT and friends
    ///      return nothing where the interface says `bool`, and a bare `transfer` on those
    ///      reverts on a call that succeeded.
    function withdrawERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroRecipient();

        token.safeTransfer(to, amount);

        emit TokenWithdrawn(address(token), to, amount);
    }
}
