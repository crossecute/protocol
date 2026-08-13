// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Treasury} from "src/treasury/Treasury.sol";

/// @dev The smallest ERC-20 that behaves, plus one that returns nothing on transfer, which is
///      the shape `SafeERC20` exists for and the shape a bare `transfer` gets wrong.
contract Token is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT's shape: it moves the balance and returns no data at all.
contract SilentToken is Token {
    function transfer(address to, uint256 amount) public override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        assembly {
            return(0, 0)
        }
    }
}

contract Rejector {
    receive() external payable {
        revert("no");
    }
}

/// @notice A destination for fees, and one authority over it.
contract TreasuryTest is Test {
    Treasury treasury;

    address msig = address(0x5165);
    address payee = address(0xBEEF);

    function setUp() public {
        treasury = new Treasury(msig);
        vm.deal(address(treasury), 10 ether);
    }

    /// @dev A TRANSCEIVER'S `withdrawFees` IS A PLAIN VALUE TRANSFER, so a treasury that could
    ///      not receive one would revert the withdrawal it is the destination of.
    function test_itAcceptsAPlainTransfer() public {
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(treasury).balance, 11 ether);
    }

    function test_theOwnerMovesNativeCurrency() public {
        vm.prank(msig);
        treasury.withdraw(payee, 3 ether);

        assertEq(payee.balance, 3 ether);
        assertEq(address(treasury).balance, 7 ether, "an amount, not a sweep");
    }

    function test_nobodyElseMovesAnything() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        treasury.withdraw(payee, 1 ether);

        Token t = new Token();
        t.mint(address(treasury), 100);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        treasury.withdrawERC20(t, payee, 100);
    }

    function test_theOwnerMovesTokens() public {
        Token t = new Token();
        t.mint(address(treasury), 100);

        vm.prank(msig);
        treasury.withdrawERC20(t, payee, 40);

        assertEq(t.balanceOf(payee), 40);
        assertEq(t.balanceOf(address(treasury)), 60);
    }

    /// @dev THE REASON FOR `SafeERC20`. A bare `transfer` on a token that returns nothing
    ///      reverts on a call that succeeded, which would strand exactly the tokens most
    ///      likely to be in a treasury.
    function test_aTokenThatReturnsNothingStillMoves() public {
        SilentToken t = new SilentToken();
        t.mint(address(treasury), 100);

        vm.prank(msig);
        treasury.withdrawERC20(t, payee, 100);

        assertEq(t.balanceOf(payee), 100);
    }

    /// @dev A withdrawal to the zero address burns the balance, and never on purpose.
    function test_neitherWithdrawalTakesTheZeroAddress() public {
        Token t = new Token();
        t.mint(address(treasury), 100);

        vm.startPrank(msig);
        vm.expectRevert(Treasury.ZeroRecipient.selector);
        treasury.withdraw(address(0), 1 ether);

        vm.expectRevert(Treasury.ZeroRecipient.selector);
        treasury.withdrawERC20(t, address(0), 100);
        vm.stopPrank();
    }

    /// @dev A RECIPIENT THAT REVERTS CARRIES ITS REASON OUT, rather than arriving as a bare
    ///      false that says nothing about which recipient refused or why.
    function test_aFailedNativeTransferReverts() public {
        address rejector = address(new Rejector());

        vm.prank(msig);
        vm.expectRevert();
        treasury.withdraw(rejector, 1 ether);

        assertEq(address(treasury).balance, 10 ether, "and nothing moved");
    }

    /// @dev Ownership is transferable, because a treasury outlives the msig that deployed it
    ///      more easily than a transceiver outlives its own configuration.
    function test_ownershipTransfers() public {
        vm.prank(msig);
        treasury.transferOwnership(payee);
        assertEq(treasury.owner(), payee);

        vm.prank(payee);
        treasury.withdraw(payee, 1 ether);
        assertEq(payee.balance, 1 ether);
    }
}
