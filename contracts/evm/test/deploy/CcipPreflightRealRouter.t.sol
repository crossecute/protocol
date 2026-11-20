// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CcipPreflight} from "script/deploy/CcipPreflight.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {MockCcipRamp} from "test/protocols/ccip/MockCcipRouter.sol";
import {CcipOffRampFixture, IRealRouter} from "test/protocols/ccip/CcipOffRamp.t.sol";

/// @dev The one ramp surface the pinned Router calls on an OnRamp to price a send.
contract PricingOnRamp is MockCcipRamp {
    constructor(string memory version) MockCcipRamp(version) {}

    function getFee(uint64, Client.EVM2AnyMessage calldata) external pure returns (uint256) {
        return 1;
    }
}

/// @notice `CcipPreflight` against the pinned upstream Router and OffRamp 2.0.0, whose registry
///         getters and `typeAndVersion` the mocks only imitate. Local chain is Ethereum, whose
///         selector is the fixture's `DEST`.
contract CcipPreflightRealRouterTest is CcipOffRampFixture {
    string internal dir;
    ChainEntry[] internal cs;

    function setUp() public {
        vm.chainId(1);
        _deployOffRamp();
        dir = ChainConfig.defaultDir();
        ChainEntry[] memory all = ChainConfig.chains(dir);
        for (uint256 i; i < all.length; ++i) {
            cs.push(all[i]);
        }
        // Base's lane is the fixture's: the real OffRamp. Arbitrum and Optimism get ramps that only report versions.
        IRealRouter.Ramp[] memory onRamps = new IRealRouter.Ramp[](3);
        IRealRouter.Ramp[] memory offRamps = new IRealRouter.Ramp[](2);
        onRamps[0] = IRealRouter.Ramp(SOURCE, address(new PricingOnRamp("OnRamp 2.0.0")));
        string[2] memory others = ["arbitrum", "optimism"];
        for (uint256 i; i < others.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) ccip.toml's id_bits is 64
            uint64 selector = uint64(ChainConfig.providerId(dir, cs, "ccip", ChainConfig.chainNamed(cs, others[i])));
            onRamps[i + 1] = IRealRouter.Ramp(selector, address(new PricingOnRamp("OnRamp 2.0.0")));
            offRamps[i] = IRealRouter.Ramp(selector, address(new MockCcipRamp("OffRamp 2.0.0")));
        }
        IRealRouter(ccipRouter).applyRampUpdates(onRamps, new IRealRouter.Ramp[](0), offRamps);
    }

    function _problems() internal view returns (string memory) {
        return CcipPreflight.problems(dir, cs, ChainConfig.chainWithId(cs, 1), ccipRouter);
    }

    function test_theRealRouterAndOffRampPass() public view {
        assertEq(_problems(), "");
    }

    function test_aLegacyOnRampBehindTheRealRouterIsReported() public {
        IRealRouter.Ramp[] memory swap = new IRealRouter.Ramp[](1);
        swap[0] = IRealRouter.Ramp(SOURCE, address(new PricingOnRamp("EVM2EVMOnRamp 1.5.0")));
        IRealRouter(ccipRouter).applyRampUpdates(swap, new IRealRouter.Ramp[](0), new IRealRouter.Ramp[](0));
        string memory found = _problems();
        assertTrue(vm.contains(found, "ethereum -> base"));
        assertTrue(vm.contains(found, "reports 'EVM2EVMOnRamp 1.5.0'"));
    }

    function test_aLaneTheRealRouterDoesNotServeIsReported() public {
        IRealRouter.Ramp[] memory removed = new IRealRouter.Ramp[](1);
        removed[0] = IRealRouter.Ramp(SOURCE, address(0));
        IRealRouter(ccipRouter).applyRampUpdates(removed, new IRealRouter.Ramp[](0), new IRealRouter.Ramp[](0));
        string memory found = _problems();
        assertTrue(vm.contains(found, "ethereum -> base"));
        assertTrue(vm.contains(found, "has no OnRamp"));
        assertTrue(vm.contains(found, "getFee"));
    }
}
