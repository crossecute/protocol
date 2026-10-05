// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {CrossProxyDeployer} from "src/account/CrossProxyDeployer.sol";
import {crossProxyDeployer} from "test/DeployCrossProxy.sol";

contract Logic {
    uint256 public value;

    function initialize(uint256 value_) external {
        value = value_;
    }

    function fail() external pure {
        revert("init failed");
    }
}

contract CrossProxyDeployerTest is Test {
    CrossProxyDeployer deployer;
    bytes32 constant SALT = keccak256("transceiver");

    function setUp() public {
        deployer = crossProxyDeployer();
    }

    /// @dev `ChainRegistry.CROSS_PROXY_DEPLOYER` is this literal. A change to the deployer's
    ///      bytecode moves it and fails here first.
    function test_itSitsWhereTheRegistryDerivesAgainst() public view {
        assertEq(address(deployer), 0x49731f3c3b6Fbdb54f6c2d7614cAdd7957A8249C);
    }

    function test_itArmsAndLocksInTheDeployingCall() public {
        address proxy = deployer.deploy(SALT, address(new Logic()), abi.encodeCall(Logic.initialize, (7)));

        assertEq(proxy, deployer.predict(address(this), SALT), "where it said");
        assertEq(Logic(proxy).value(), 7, "initialized");
        assertEq(vm.load(proxy, ERC1967Utils.ADMIN_SLOT), bytes32(0), "no admin left");
    }

    /// @dev The salt is bound to its caller, so another caller cannot take this address first
    ///      with its own implementation.
    function test_anotherCallerCannotTakeTheAddress() public {
        address mine = deployer.predict(address(this), SALT);

        address impl = address(new Logic());
        vm.prank(address(0xBAD));
        address theirs = deployer.deploy(SALT, impl, abi.encodeCall(Logic.initialize, (666)));

        assertTrue(theirs != mine, "a different address");
        assertEq(mine.code.length, 0, "mine is still free");
        assertEq(deployer.deploy(SALT, address(new Logic()), abi.encodeCall(Logic.initialize, (7))), mine);
    }

    /// @dev A failing initializer takes the deployment with it, so no unarmed proxy is left
    ///      at the address.
    function test_aFailingInitializerLeavesNothing() public {
        address impl = address(new Logic());
        vm.expectRevert("init failed");
        deployer.deploy(SALT, impl, abi.encodeCall(Logic.fail, ()));
        assertEq(deployer.predict(address(this), SALT).code.length, 0);
    }
}
