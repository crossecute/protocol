// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {CcipFixture} from "test/protocols/ccip/CcipFixture.sol";
import {LzFixture} from "test/protocols/layerzero/LzFixture.sol";
import {HyperlaneFixture} from "test/protocols/hyperlane/HyperlaneFixture.sol";
import {WormholeFixture} from "test/protocols/wormhole/WormholeFixture.sol";

interface IRemoteId {
    function remoteProviderId() external pure returns (uint256);
}

/// @dev Each fixture's id for the chain it delivers from.
contract LzIds is LzFixture, IRemoteId {
    function remoteProviderId() external pure returns (uint256) {
        return _remoteProviderId();
    }
}

contract CcipIds is CcipFixture, IRemoteId {
    function remoteProviderId() external pure returns (uint256) {
        return _remoteProviderId();
    }
}

contract HyperlaneIds is HyperlaneFixture, IRemoteId {
    function remoteProviderId() external pure returns (uint256) {
        return _remoteProviderId();
    }
}

contract WormholeIds is WormholeFixture, IRemoteId {
    function remoteProviderId() external pure returns (uint256) {
        return _remoteProviderId();
    }
}

contract ChainConfigTest is Test {
    string[4] PROVIDERS = ["layerzero", "ccip", "hyperlane", "wormhole"];

    function _dir(string memory name) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/test/deploy/config/", name);
    }

    function chains(string memory dir) external view returns (ChainEntry[] memory) {
        return ChainConfig.chains(dir);
    }

    function providerId(string memory dir, string memory provider) external view returns (uint256) {
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        return ChainConfig.providerId(dir, cs, provider, cs[0]);
    }

    function _expect(string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployCheck.selector, what));
    }

    /// @dev Every provider file is read in full by any lookup, so one lookup per file checks it.
    function test_theProductionConfigurationIsWellFormed() public view {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        assertGt(cs.length, 0);
        for (uint256 p; p < PROVIDERS.length; ++p) {
            for (uint256 i; i < cs.length; ++i) {
                ChainConfig.providerId(dir, cs, PROVIDERS[p], cs[i]);
            }
        }
    }

    function test_onlyTwoParityChainsArePredeterminedToEachOther() public pure {
        ChainEntry memory parity = ChainEntry("p", 1, Derivation.Parity);
        ChainEntry memory zk = ChainEntry("z", 324, Derivation.ZkSync);
        ChainEntry memory other = ChainEntry("o", 7, Derivation.Other);
        assertEq(uint8(ChainConfig.gradeOf(parity, parity)), uint8(Provenance.Predetermined));
        assertEq(uint8(ChainConfig.gradeOf(parity, zk)), uint8(Provenance.Unique));
        assertEq(uint8(ChainConfig.gradeOf(zk, parity)), uint8(Provenance.Unique));
        assertEq(uint8(ChainConfig.gradeOf(zk, zk)), uint8(Provenance.Unique), "#33: itself included");
        assertEq(uint8(ChainConfig.gradeOf(other, parity)), uint8(Provenance.Unique));
    }

    /// @dev The provider fixtures deliver from Base; their ids must be production's.
    function test_theFixturesUseProductionsIdsForBase() public {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        ChainEntry memory base = ChainConfig.chainWithId(cs, 8453);
        assertEq(ChainConfig.providerId(dir, cs, "layerzero", base), _remoteId(new LzIds()));
        assertEq(ChainConfig.providerId(dir, cs, "ccip", base), _remoteId(new CcipIds()));
        assertEq(ChainConfig.providerId(dir, cs, "hyperlane", base), _remoteId(new HyperlaneIds()));
        assertEq(ChainConfig.providerId(dir, cs, "wormhole", base), _remoteId(new WormholeIds()));
    }

    function _remoteId(IRemoteId f) internal view returns (uint256) {
        return f.remoteProviderId();
    }

    function test_aDuplicateChainIdIsRefused() public {
        _expect("chain_id is unique");
        this.chains(_dir("duplicate-chain-id"));
    }

    function test_anUnknownDerivationIsRefused() public {
        _expect("derivation is parity, zksync, tron, or other");
        this.chains(_dir("bad-derivation"));
    }

    function test_aProviderIdForAnUnconfiguredChainIsRefused() public {
        _expect("provider ids are keyed by chains.toml names");
        this.providerId(_dir("bad-ids"), "unknown-chain");
    }

    function test_aProviderIdWiderThanItsWidthIsRefused() public {
        _expect("provider id fits id_bits");
        this.providerId(_dir("bad-ids"), "too-wide");
    }

    function test_aDuplicateProviderIdIsRefused() public {
        _expect("provider id is unique");
        this.providerId(_dir("bad-ids"), "duplicate-id");
    }

    function test_aZeroProviderIdIsRefused() public {
        _expect("provider id is nonzero");
        this.providerId(_dir("bad-ids"), "zero-id");
    }
}
