// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {VM, check} from "script/deploy/ProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";

/// @notice The Router's lane registry, as CCIP 1.2.0's Router (used by CCIP 1.5, 1.6 and 2.0) exposes it.
interface ICcipRouterLanes {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOnRamp(uint64 destChainSelector) external view returns (address);

    function getOffRamps() external view returns (OffRamp[] memory);
}

interface ITypeAndVersion {
    function typeAndVersion() external view returns (string memory);
}

/// @title CcipPreflight
/// @notice Read-only check that a chain's CCIP lanes to and from every other parity chain run
///         the contract versions `providers/ccip.toml` lists, and quote with the options the
///         bindings send. Run it before the first CCIP transaction on a chain.
/// @dev A router address, a selector, or a quote does not show a lane's version: a legacy lane
///      can still quote. Each lane is therefore resolved to its OnRamp (outbound) and OffRamps
///      (inbound) through the router, and the ramps' `typeAndVersion` is compared with
///      `"<OnRamp|OffRamp> <version>"` for each listed version. An inbound source with several
///      registered OffRamps must have every one supported, since which one executes is the
///      source's choice. Each check sees one chain's router, so a route is verified end to end
///      only by running the check on both of its chains (`PreflightCcip.s.sol` does).
library CcipPreflight {
    /// @dev An arbitrary non-system address: CCIP refuses a receiver in its reserved ranges.
    address internal constant QUOTE_RECEIVER = address(uint160(uint256(keccak256("crossecute.ccip.preflight"))));

    /// @notice Every problem found on `local`'s lanes through `router`, one per line; empty if none.
    function problems(string memory dir, ChainEntry[] memory cs, ChainEntry memory local, address router)
        internal
        view
        returns (string memory out)
    {
        if (router.code.length == 0) {
            return string.concat(local.name, ": CCIP router ", VM.toString(router), " has no code");
        }
        if (ChainConfig.providerId(dir, cs, "ccip", local) == 0) {
            return string.concat(local.name, ": ccip.toml lists no selector");
        }
        string[] memory versions = supportedVersions(dir);
        (bool listed, ICcipRouterLanes.OffRamp[] memory offRamps) = _offRamps(router);
        for (uint256 i; i < cs.length; ++i) {
            ChainEntry memory peer = cs[i];
            if (peer.chainId == local.chainId || peer.derivation != Derivation.Parity) continue;
            uint256 id = ChainConfig.providerId(dir, cs, "ccip", peer);
            if (id == 0) continue;
            // forge-lint: disable-next-line(unsafe-typecast) ccip.toml's id_bits is 64
            uint64 peerSelector = uint64(id);
            string memory outbound = string.concat(local.name, " -> ", peer.name);
            out = join(out, _onRamp(outbound, router, peerSelector, versions));
            out = join(out, _quote(outbound, router, peerSelector));
            string memory inbound = string.concat(peer.name, " -> ", local.name);
            out = join(out, _offRampsFor(inbound, router, peerSelector, versions, listed, offRamps));
        }
    }

    /// @notice Reverts with every problem in `found`, which names the chains, router, ramps,
    ///         observed versions and expected versions.
    function require_(string memory found) internal pure {
        check(bytes(found).length == 0, string.concat("CCIP preflight failed:\n", found));
    }

    /// @notice The versions the deployment supports, from `ccip.toml`'s `versions`.
    function supportedVersions(string memory dir) internal view returns (string[] memory versions) {
        string memory toml = ChainConfig.read(string.concat(dir, "/providers/ccip.toml"));
        check(VM.keyExistsToml(toml, ".versions"), "ccip.toml lists the supported ramp versions");
        versions = VM.parseTomlStringArray(toml, ".versions");
        check(versions.length != 0, "ccip.toml lists at least one ramp version");
    }

    function _onRamp(string memory route, address router, uint64 selector, string[] memory versions)
        private
        view
        returns (string memory)
    {
        try ICcipRouterLanes(router).getOnRamp(selector) returns (address onRamp) {
            return _ramp(route, "OnRamp", router, onRamp, versions);
        } catch {
            return string.concat(route, ": router ", VM.toString(router), " getOnRamp reverts");
        }
    }

    function _offRamps(address router) private view returns (bool, ICcipRouterLanes.OffRamp[] memory) {
        try ICcipRouterLanes(router).getOffRamps() returns (ICcipRouterLanes.OffRamp[] memory rs) {
            return (true, rs);
        } catch {
            return (false, new ICcipRouterLanes.OffRamp[](0));
        }
    }

    function _offRampsFor(
        string memory route,
        address router,
        uint64 source,
        string[] memory versions,
        bool listed,
        ICcipRouterLanes.OffRamp[] memory offRamps
    ) private view returns (string memory out) {
        if (!listed) return string.concat(route, ": router ", VM.toString(router), " getOffRamps reverts");
        bool found;
        for (uint256 i; i < offRamps.length; ++i) {
            if (offRamps[i].sourceChainSelector != source) continue;
            found = true;
            out = join(out, _ramp(route, "OffRamp", router, offRamps[i].offRamp, versions));
        }
        if (!found) out = string.concat(route, ": router ", VM.toString(router), " has no OffRamp for the source");
    }

    function _ramp(string memory route, string memory kind, address router, address ramp, string[] memory versions)
        private
        view
        returns (string memory)
    {
        string memory at = string.concat(kind, " ", VM.toString(ramp), " via router ", VM.toString(router));
        if (ramp == address(0)) return string.concat(route, ": router ", VM.toString(router), " has no ", kind);
        if (ramp.code.length == 0) return string.concat(route, ": ", at, " has no code");
        try ITypeAndVersion(ramp).typeAndVersion() returns (string memory observed) {
            for (uint256 i; i < versions.length; ++i) {
                if (_same(observed, string.concat(kind, " ", versions[i]))) return "";
            }
            return string.concat(route, ": ", at, " reports '", observed, "', expected ", _expected(kind, versions));
        } catch {
            return
                string.concat(route, ": ", at, " has no readable typeAndVersion, expected ", _expected(kind, versions));
        }
    }

    /// @dev The exact options the bindings send when no attribute is given: `GenericExtraArgsV2`
    ///      with the default bootstrap or payload gas and no out-of-order flag.
    function _quote(string memory route, address router, uint64 selector) private view returns (string memory out) {
        uint256[2] memory gases = [DeliveryGas.BOOTSTRAP, DeliveryGas.PAYLOAD];
        for (uint256 i; i < gases.length; ++i) {
            Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
                receiver: abi.encode(QUOTE_RECEIVER),
                data: hex"00",
                tokenAmounts: new Client.EVMTokenAmount[](0),
                feeToken: address(0),
                extraArgs: CcipMessage.extraArgsFrom(new bytes[](0), gases[i])
            });
            // forge-lint: disable-next-line(unused-return) a quote that does not revert is the check
            try IRouterClient(router).getFee(selector, message) returns (uint256) {}
            catch (bytes memory reason) {
                out = join(
                    out,
                    string.concat(
                        route,
                        ": getFee through router ",
                        VM.toString(router),
                        " with gas ",
                        VM.toString(gases[i]),
                        " reverts with ",
                        VM.toString(reason.length < 4 ? reason : abi.encodePacked(bytes4(reason)))
                    )
                );
            }
        }
    }

    function _expected(string memory kind, string[] memory versions) private pure returns (string memory out) {
        for (uint256 i; i < versions.length; ++i) {
            out = string.concat(out, i == 0 ? "'" : " or '", kind, " ", versions[i], "'");
        }
    }

    function join(string memory a, string memory b) internal pure returns (string memory) {
        if (bytes(b).length == 0) return a;
        return bytes(a).length == 0 ? b : string.concat(a, "\n", b);
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
