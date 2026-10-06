// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {DeployCheck} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {CcipFixture} from "test/protocols/ccip/CcipFixture.sol";
import {LzFixture, LzZkSyncHarness} from "test/protocols/layerzero/LzFixture.sol";
import {LzDeploy} from "script/deploy/LzDeploy.sol";
import {CrossProxy} from "src/account/CrossProxy.sol";
import {TransceiverConfig} from "src/messaging/transceiver/TransceiverBase.sol";
import {ChainRegistry, RegistrySeed, ProviderSeed} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
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

    /// @dev #46: zkSync and Tron transceivers find a parity chain's transceiver from the
    ///      record, so their registries grade parity chains `Predetermined`; only `other`
    ///      cannot, and a non-parity chain is `Unique` everywhere, its own registry included.
    function test_aParityChainIsPredeterminedFromAnyChainButOther() public pure {
        ChainEntry[4] memory all = [
            ChainEntry("parity", 1, Derivation.Parity),
            ChainEntry("zksync", 324, Derivation.ZkSync),
            ChainEntry("tron", 728126428, Derivation.Tron),
            ChainEntry("other", 7, Derivation.Other)
        ];
        // expected[registry][graded]: P = Predetermined, U = Unique.
        string[4] memory expected = ["PUUU", "PUUU", "PUUU", "UUUU"];
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                Provenance want = bytes(expected[i])[j] == "P" ? Provenance.Predetermined : Provenance.Unique;
                assertEq(
                    uint8(ChainConfig.gradeOf(all[i], all[j])),
                    uint8(want),
                    string.concat(all[i].name, " grading ", all[j].name)
                );
            }
        }
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

/// @notice The grade the configuration gives a chain must be one its transceivers accept.
contract ConfiguredGradesBornConfigureTest is LzFixture {
    /// @dev #46: a zkSync transceiver is born accepting the governor's home only if its
    ///      registry grades that home `Predetermined`, and the configuration must say so.
    function test_aZkSyncTransceiverIsBornAgainstTheConfiguredGradeOfItsHome() public {
        string memory dir = ChainConfig.defaultDir();
        ChainEntry[] memory cs = ChainConfig.chains(dir);
        ChainEntry memory zkSync = ChainConfig.chainWithId(cs, 324);
        ChainEntry memory ethereum = ChainConfig.chainWithId(cs, 1);

        ProviderSeed[] memory providers = new ProviderSeed[](1);
        providers[0] =
            ProviderSeed("layerzero", address(0xDE91), keccak256("salt"), keccak256(type(CrossProxy).creationCode));
        ChainRegistry registry = new ChainRegistry(
            address(this),
            RegistrySeed({
                governorHome: Erc7930.encodeEvmChain(ethereum.chainId),
                governorHomeGrade: ChainConfig.gradeOf(zkSync, ethereum),
                providers: providers
            })
        );
        TransceiverConfig memory c = _config();
        c.chainRegistry = IChainRegistryRefs(address(registry));
        c.messageProvider = keccak256("layerzero");
        c.minCounterpartProvenance = Provenance.Unique;
        uint32 homeEid = uint32(ChainConfig.providerId(dir, cs, "layerzero", ethereum));

        LzDeploy.zkSyncTransceiver(
            _deployment(address(new LzZkSyncHarness(address(endpoint))), c), homeEid, keccak256("zksolc")
        );
    }
}
