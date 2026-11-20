// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployCheck} from "script/deploy/ProxyDeploy.sol";
import {CcipPreflight} from "script/deploy/CcipPreflight.sol";
import {ChainConfig, ChainEntry} from "script/deploy/ChainConfig.sol";
import {MockCcipRamp, MockCcipRouter} from "test/protocols/ccip/MockCcipRouter.sol";
import {installCcipLanes} from "test/deploy/CcipLanes.sol";

/// @notice `CcipPreflight` on Base, a parity chain whose peers in `deploy/` are Ethereum, Arbitrum,
///         Optimism and Fraxtal (zkSync is not a parity chain).
contract CcipPreflightTest is Test {
    uint256 internal constant BASE = 8453;
    MockCcipRouter internal router;
    string internal dir;
    ChainEntry[] internal cs;

    function setUp() public {
        vm.chainId(BASE);
        dir = ChainConfig.defaultDir();
        ChainEntry[] memory all = ChainConfig.chains(dir);
        for (uint256 i; i < all.length; ++i) {
            cs.push(all[i]);
        }
        router = new MockCcipRouter();
        installCcipLanes(router, "2.0.0");
    }

    function _problems() internal view returns (string memory) {
        return CcipPreflight.problems(dir, cs, ChainConfig.chainWithId(cs, BASE), address(router));
    }

    function _selector(string memory name) internal view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast) ccip.toml's id_bits is 64
        return uint64(ChainConfig.providerId(dir, cs, "ccip", ChainConfig.chainNamed(cs, name)));
    }

    function _mentions(string memory found, string memory part) internal pure returns (bool) {
        return vm.contains(found, part);
    }

    function test_everyLaneOnTheSupportedVersionPasses() public view {
        assertEq(_problems(), "");
    }

    function test_theVersionsComeFromTheConfiguration() public view {
        string[] memory v = CcipPreflight.supportedVersions(dir);
        assertEq(v.length, 1);
        assertEq(v[0], "2.0.0");
    }

    function test_aLegacyOnRampNamesTheRouteRampAndVersions() public {
        address legacy = address(new MockCcipRamp("EVM2EVMOnRamp 1.5.0"));
        router.setLane(_selector("ethereum"), legacy, address(new MockCcipRamp("OffRamp 2.0.0")));
        string memory found = _problems();
        assertTrue(_mentions(found, "base -> ethereum"));
        assertTrue(_mentions(found, vm.toString(legacy)));
        assertTrue(_mentions(found, vm.toString(address(router))));
        assertTrue(_mentions(found, "reports 'EVM2EVMOnRamp 1.5.0'"));
        assertTrue(_mentions(found, "expected 'OnRamp 2.0.0'"));
    }

    function test_aLegacyOffRampIsReportedOnItsInboundRoute() public {
        router.setLane(
            _selector("arbitrum"), address(new MockCcipRamp("OnRamp 2.0.0")), address(new MockCcipRamp("OffRamp 1.6.0"))
        );
        string memory found = _problems();
        assertTrue(_mentions(found, "arbitrum -> base"));
        assertTrue(_mentions(found, "reports 'OffRamp 1.6.0'"));
        assertFalse(_mentions(found, "base -> arbitrum"));
    }

    /// @dev Live routers keep every superseded OffRamp registered beside the current one.
    function test_aSupersededOffRampBesideASupportedOneIsAccepted() public {
        router.addOffRamp(_selector("optimism"), address(new MockCcipRamp("EVM2EVMOffRamp 1.5.0")));
        router.addOffRamp(_selector("optimism"), address(new MockCcipRamp("OffRamp 1.6.0")));
        assertEq(_problems(), "");
    }

    function test_onlyLegacyOffRampsAreAllReported() public {
        router.clearOffRamps();
        router.addOffRamp(_selector("optimism"), address(new MockCcipRamp("EVM2EVMOffRamp 1.5.0")));
        router.addOffRamp(_selector("optimism"), address(new MockCcipRamp("OffRamp 1.6.0")));
        string memory found = _problems();
        assertTrue(_mentions(found, "reports 'EVM2EVMOffRamp 1.5.0'"));
        assertTrue(_mentions(found, "reports 'OffRamp 1.6.0'"));
    }

    function test_aLaneWithoutRampsIsReported() public {
        router.setLane(_selector("ethereum"), address(0), address(0));
        string memory found = _problems();
        assertTrue(_mentions(found, "base -> ethereum: router"));
        assertTrue(_mentions(found, "has no OnRamp"));
        assertTrue(_mentions(found, "ethereum -> base: router"));
        assertTrue(_mentions(found, "has no OffRamp"));
    }

    function test_aRouterWithoutAnOffRampForTheSourceIsReported() public {
        router.clearOffRamps();
        assertTrue(_mentions(_problems(), "has no OffRamp for the source"));
    }

    function test_aRampWithoutCodeOrVersionIsUnverifiable() public {
        router.setLane(_selector("ethereum"), address(0xBEEF), address(router));
        string memory found = _problems();
        assertTrue(_mentions(found, "has no code"));
        assertTrue(_mentions(found, "has no readable typeAndVersion"));
    }

    function test_aQuoteThatRevertsIsReportedWithItsSelector() public {
        router.setUnsupported(_selector("optimism"), true);
        string memory found = _problems();
        assertTrue(_mentions(found, "base -> optimism: getFee"));
        assertTrue(_mentions(found, "gas 1000000"));
        assertTrue(_mentions(found, "gas 200000"));
        assertTrue(_mentions(found, "0xae236d9c"));
    }

    /// @dev A legacy lane that requires out-of-order execution rejects the options the bindings send.
    function test_aLaneRequiringOutOfOrderRejectsTheDefaultOptions() public {
        router.setRequireOutOfOrder(true);
        string memory found = _problems();
        assertTrue(_mentions(found, "base -> ethereum: getFee"));
        assertTrue(_mentions(found, "base -> arbitrum: getFee"));
    }

    function test_aRouterWithoutCodeIsReported() public view {
        string memory found = CcipPreflight.problems(dir, cs, ChainConfig.chainWithId(cs, BASE), address(0xBEEF));
        assertTrue(_mentions(found, "CCIP router 0x000000000000000000000000000000000000bEEF has no code"));
    }

    function test_aRouterWithoutTheRegistryGettersIsReportedNotReverted() public {
        MockCcipRamp notARouter = new MockCcipRamp("Router");
        string memory found = CcipPreflight.problems(dir, cs, ChainConfig.chainWithId(cs, BASE), address(notARouter));
        assertTrue(_mentions(found, "getOnRamp reverts"));
        assertTrue(_mentions(found, "getOffRamps reverts"));
    }

    function test_anotherLocalChainChecksItsOwnPeers() public {
        vm.chainId(10);
        installCcipLanes(router, "2.0.0");
        router.setUnsupported(_selector("base"), true);
        string memory found = CcipPreflight.problems(dir, cs, ChainConfig.chainWithId(cs, 10), address(router));
        assertTrue(_mentions(found, "optimism -> base: getFee"));
        assertFalse(_mentions(found, "optimism -> ethereum"));
    }

    /// @dev Chainlink carries no lane between Fraxtal and Arbitrum, so `ccip.toml` blocks the pair
    ///      and neither end is checked for it.
    function test_aBlockedPairIsNotChecked() public {
        vm.chainId(42161);
        installCcipLanes(router, "2.0.0");
        router.setUnsupported(_selector("fraxtal"), true);
        router.addOffRamp(_selector("fraxtal"), address(new MockCcipRamp("EVM2EVMOffRamp 1.5.0")));
        assertEq(CcipPreflight.problems(dir, cs, ChainConfig.chainWithId(cs, 42161), address(router)), "");
    }

    function test_aCarriedPairWithFraxtalIsChecked() public {
        router.setUnsupported(_selector("fraxtal"), true);
        assertTrue(_mentions(_problems(), "base -> fraxtal: getFee"));
    }

    function test_requireRevertsWithEveryProblem() public {
        router.setUnsupported(_selector("ethereum"), true);
        router.setUnsupported(_selector("optimism"), true);
        string memory found = _problems();
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, string.concat("CCIP preflight failed:\n", found)));
        this.requireClear(found);
    }

    function requireClear(string memory found) external pure {
        CcipPreflight.require_(found);
    }

    function test_requireAcceptsNoProblems() public pure {
        CcipPreflight.require_("");
    }
}
