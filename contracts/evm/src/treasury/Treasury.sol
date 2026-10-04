// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A transceiver's report float, which leaves only at its treasury's call.
interface IReportFloat {
    function withdraw(uint256 amount) external;
}

/// @title Treasury
/// @notice Where a chain's bootstrap fees and report float land, and the one contract that can
///         move them out.
///
/// @dev A destination, not an authority: it configures nothing and reaches no account. Its one
///      outgoing call pulls a transceiver's float, which can only come here. Its owner decides
///      where funds go next; each transceiver's write-once `treasury` decides where they arrive,
///      so a compromised withdrawal path cannot redirect fees at the source.
///
/// @dev One per chain, shared by every provider there. A plain deployment: nothing derives an
///      address from it, so it can be redeployed.
contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Native currency left this treasury.
    event NativeWithdrawn(address indexed to, uint256 amount);

    /// @notice An ERC-20 balance left this treasury.
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice A transceiver's report float was pulled in.
    event FloatCollected(address indexed from, uint256 amount);

    /// @dev A withdrawal to the zero address would burn the balance.
    error ZeroRecipient();

    /// @dev The native transfer failed; carries the recipient's revert reason.
    error NativeTransferFailed(address to, uint256 amount, bytes reason);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Accept fees. A transceiver forwards each with a plain `call` inside the bootstrap
    ///         that charges it, so without this every paid bootstrap would revert.
    receive() external payable {}

    /// @notice Pull `amount` of a transceiver's report float into this treasury.
    /// @dev The transceiver pays only its treasury, so the owner chooses when, not where.
    function collect(IReportFloat from, uint256 amount) external onlyOwner {
        emit FloatCollected(address(from), amount);
        from.withdraw(amount);
    }

    /// @notice Send `amount` of native currency to `to`.
    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroRecipient();

        // `call`, not `transfer`: a msig recipient needs more than the 2300-gas stipend, and
        // there is no state here for a re-entrant call to confuse.
        emit NativeWithdrawn(to, amount);

        (bool ok, bytes memory reason) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount, reason);
    }

    /// @notice Send `amount` of `token` to `to`.
    /// @dev `SafeERC20` for tokens such as USDT whose `transfer` returns nothing.
    function withdrawERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroRecipient();

        token.safeTransfer(to, amount);

        emit TokenWithdrawn(address(token), to, amount);
    }
}
