// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

/// @notice Does nothing with whatever reaches it: the baseline a delivery's cost is measured
///         against.
contract NoOpReceiver {
    fallback() external payable {}
}

/// @title DeliveryGasMeter
/// @notice What a delivery costs: the smallest gas limit on the call into a fixture's delivery
///         under which it succeeds, every account it touches cold, less the same for the same
///         message delivered to `NoOpReceiver`.
/// @dev What is left runs inside the receiving frame, scaled up by 64/63 at the gateway's
///      call, so it slightly overstates the gas limit a gateway must pass. Shared by
///      `ProviderDeliveryGasSpec` and the bindings it cannot run, so every number in
///      deploy/CHECKS.md §4 is measured one way.
abstract contract DeliveryGasMeter is Test {
    uint256 internal constant MEASURE_CEILING = 5_000_000;

    address internal noOp = address(new NoOpReceiver());

    /// @notice Deliver `message` to `to` from `sender` under a gas limit of `gas`, through one
    ///         external call, and say whether it succeeded.
    function _meteredDelivery(uint256 gas, address to, address sender, bytes memory message)
        internal
        virtual
        returns (bool);

    function _assertFits(string memory delivery, uint256 measured, uint256 defaultGas) internal {
        emit log_named_uint(delivery, measured);
        assertLe(measured * 11 / 10, defaultGas, delivery);
    }

    function _measure(address to, address sender, bytes memory message) internal returns (uint256) {
        return _minGas(to, sender, message) - _minGas(noOp, sender, message);
    }

    /// @notice The smallest gas limit under which `message` reaches `to` from `sender`, every
    ///         account it touches cold. State is left as it was.
    function _minGas(address to, address sender, bytes memory message) internal returns (uint256 hi) {
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        _meteredDelivery(MEASURE_CEILING, to, sender, message);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 lo;
        hi = MEASURE_CEILING;
        assertTrue(_coldDeliveryWith(hi, snapshot, accesses, to, sender, message), "it succeeds at the ceiling");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_coldDeliveryWith(mid, snapshot, accesses, to, sender, message)) hi = mid;
            else lo = mid;
        }
        vm.revertToState(snapshot);
    }

    /// @dev This contract is left warm: it is the caller, and a gateway is warm the same way.
    function _coldDeliveryWith(
        uint256 gas,
        uint256 snapshot,
        Vm.AccountAccess[] memory accesses,
        address to,
        address sender,
        bytes memory message
    ) private returns (bool) {
        vm.revertToState(snapshot);
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != address(this)) vm.cool(accesses[i].account);
        }
        return _meteredDelivery(gas, to, sender, message);
    }
}
