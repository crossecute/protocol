// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Call} from "src/messaging/Call.sol";
import {Payload} from "src/messaging/Payload.sol";
import {DeliveryGas} from "src/messaging/DeliveryGas.sol";
import {TransmitterBase} from "src/messaging/outbound/TransmitterBase.sol";
import {TransceiverBase} from "src/messaging/transceiver/TransceiverBase.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {LzTransceiverBase} from "src/protocols/layerzero/LzTransceiver.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {CcipTransceiverBase} from "src/protocols/ccip/CcipTransceiver.sol";
import {HyperlaneTransceiverBase} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {WormholeTransceiver} from "src/protocols/wormhole/WormholeTransceiver.sol";
import {OpStackTransceiver} from "src/protocols/op-stack/OpStackTransceiver.sol";
import {DeployCheck, check} from "script/deploy/CrossProxyDeploy.sol";
import {ChainConfig, ChainEntry, Derivation} from "script/deploy/ChainConfig.sol";
import {OpStackConfig} from "script/deploy/OpStackDeploy.sol";
import {OpStackInteropConfig} from "script/deploy/OpStackInteropDeploy.sol";
import {Governance, GovernanceConfig, ChainDeploy} from "script/deploy/ChainDeploy.sol";
import {GasAttribute} from "script/deploy/GasAttribute.sol";

/// @notice A transaction for the governor's owner, or anyone, to submit.
struct Tx {
    address to;
    uint256 value;
    bytes data;
}

/// @notice A (provider, chain) pair that is `Pending` in every registry, for `rotateDeployer`.
struct PendingPair {
    uint256 chainId;
    string provider;
}

/// @notice What the plan is computed from.
struct Plan {
    string dir;
    /// Every configured chain, for reading the provider files, which are keyed by all of them.
    ChainEntry[] all;
    /// The chains the plan configures: parity chains only.
    ChainEntry[] chains;
    Governance g;
    /// `isOn` for each chain and provider, row-major by chain, computed once in `load`: reading
    /// the provider files for every pair on every call exhausts memory.
    bool[] deployed;
}

/// @title GovernancePlan
/// @notice Steps 3 to 6 of `docs/provider-spec.md` §6 for the parity chains in `deploy/`, as the
///         transactions that carry them: the N × N tables every transceiver needs about every
///         other chain, and every chain's registry entries through its timelock.
///
/// @dev Computed from `deploy/` alone, with no chain read, so the same commit always yields the
///      same bytes. Every address is predicted: step 1's from `governance.toml`, a provider's
///      transceiver from its record, and the governor's conduit under a provider from both.
///      These hold on parity chains, which is why zkSync and Tron are left out.
///
/// @dev The order is forced. A transceiver's route and provider id need nothing, but a LayerZero
///      peer needs the chain graded in that chain's registry, and a bootstrap needs the
///      destination graded at home. So: the home is prepared and its registry scheduled; after
///      the delay its registry executes, then its peers are set and every other chain is
///      bootstrapped with a payload that sets its routes and ids and schedules its registry;
///      after that delay, each registry executes and the peers there are sent.
library GovernancePlan {
    /// @dev Destination gas per configuration call, above what the message itself needs.
    ///      `GovernancePlanTest` holds every call's measured cost at least 10% below it.
    uint256 internal constant CALL_GAS = 100_000;
    /// @dev Destination gas per entry of a timelock batch, which `scheduleBatch` hashes and logs.
    uint256 internal constant SCHEDULE_ENTRY_GAS = 25_000;

    function load(string memory dir, string memory governanceFile) internal view returns (Plan memory p) {
        p.dir = dir;
        p.all = ChainConfig.chains(dir);
        p.g = GovernanceConfig.read(governanceFile, p.all);
        GovernanceConfig.requireSet(p.g);
        uint256 n;
        for (uint256 i; i < p.all.length; ++i) {
            if (p.all[i].derivation == Derivation.Parity) ++n;
        }
        p.chains = new ChainEntry[](n);
        n = 0;
        for (uint256 i; i < p.all.length; ++i) {
            if (p.all[i].derivation != Derivation.Parity) continue;
            p.chains[n++] = p.all[i];
            // Its lanes need no id and are not built here; a listed chain must not be skipped.
            check(!OpStackInteropConfig.isMember(dir, p.all, p.all[i]), "op-stack-l2-l2 lanes are not scripted");
        }
        p.deployed = new bool[](p.chains.length * p.g.providers.length);
        for (uint256 i; i < p.chains.length; ++i) {
            for (uint256 j; j < p.g.providers.length; ++j) {
                p.deployed[i * p.g.providers.length + j] = isOn(p, p.g.providers[j].name, p.chains[i]);
            }
        }
        // Each proposer's conduit exists on a chain only once it is bootstrapped there, and the
        // first one's bootstrap is what schedules that chain's registry.
        for (uint256 i; i < p.chains.length; ++i) {
            if (p.chains[i].chainId == p.g.home.chainId) continue;
            for (uint256 j; j < 2; ++j) {
                check(idFor(p, p.g.proposers[j], p.g.home, p.chains[i]) != 0, "each proposer reaches every chain");
            }
        }
    }

    /* ================================ addresses =============================== */

    /// @notice `provider`'s transceiver, at its record's address on every parity chain.
    function transceiver(Plan memory p, string memory provider) internal pure returns (address) {
        return ChainDeploy.transceiver(p.g, provider);
    }

    /// @notice The governor's transmitter at home under `provider`, and its receiver elsewhere.
    function governor(Plan memory p, string memory provider) internal pure returns (address) {
        return ChainDeploy.governorConduit(p.g, provider);
    }

    /* ================================== lanes ================================= */

    /// @notice `provider`'s id for `remote` as `local`'s transceiver names it, or zero where it
    ///         does not connect the two.
    function idFor(Plan memory p, string memory provider, ChainEntry memory local, ChainEntry memory remote)
        internal
        view
        returns (uint256)
    {
        if (local.chainId == remote.chainId) return 0;
        if (_is(provider, "op-stack-l1-l2")) return uint160(OpStackConfig.messenger(p.dir, p.all, local, remote));
        if (_is(provider, "op-stack-l2-l2")) return 0;
        if (ChainConfig.providerId(p.dir, p.all, provider, local) == 0) return 0;
        return ChainConfig.providerId(p.dir, p.all, provider, remote);
    }

    /// @notice Whether step 2 deployed `provider` on `chain`: off the home, only where it reaches
    ///         the home, which a transceiver's birth requires.
    function isOn(Plan memory p, string memory provider, ChainEntry memory chain) internal view returns (bool) {
        if (chain.chainId != p.g.home.chainId) return idFor(p, provider, chain, p.g.home) != 0;
        for (uint256 i; i < p.chains.length; ++i) {
            if (idFor(p, provider, chain, p.chains[i]) != 0) return true;
        }
        return false;
    }

    /// @notice `setRoute` and the id setter on `local`'s transceiver for every chain the provider
    ///         connects it to, but the home, which it was born with.
    function laneCalls(Plan memory p, string memory provider, ChainEntry memory local)
        internal
        view
        returns (Call[] memory calls)
    {
        address t = transceiver(p, provider);
        for (uint256 i; i < p.chains.length; ++i) {
            ChainEntry memory remote = p.chains[i];
            uint256 id = idFor(p, provider, local, remote);
            if (id == 0 || remote.chainId == p.g.home.chainId) continue;
            bytes32 key = ChainKey.forEvm(remote.chainId);
            calls = _push(
                calls,
                Call(t, 0, abi.encodeCall(TransceiverExtension.setRoute, (key, Erc7930.encodeEvmChain(remote.chainId))))
            );
            calls = _push(calls, Call(t, 0, _idSetter(provider, key, id)));
        }
    }

    /// @notice LayerZero's peers on `local` for the chains `laneCalls` names. A peer must be the
    ///         counterpart there, which on a parity chain is the transceiver's own address.
    function peerCalls(Plan memory p, ChainEntry memory local) internal view returns (Call[] memory calls) {
        if (!_hasProvider(p, "layerzero") || !isOn(p, "layerzero", local)) return calls;
        address t = transceiver(p, "layerzero");
        for (uint256 i; i < p.chains.length; ++i) {
            uint256 eid = idFor(p, "layerzero", local, p.chains[i]);
            if (eid == 0 || p.chains[i].chainId == p.g.home.chainId) continue;
            // forge-lint: disable-next-line(unsafe-typecast) layerzero.toml's id_bits is 32
            calls = _push(calls, Call(t, 0, abi.encodeCall(IOAppCore.setPeer, (uint32(eid), _word(t)))));
        }
    }

    function _idSetter(string memory provider, bytes32 key, uint256 id) private pure returns (bytes memory) {
        // forge-lint: disable-start(unsafe-typecast) each id fits its provider's id_bits
        if (_is(provider, "layerzero")) return abi.encodeCall(LzTransceiverBase.setEid, (key, uint32(id)));
        if (_is(provider, "ccip")) return abi.encodeCall(CcipTransceiverBase.setSelector, (key, uint64(id)));
        if (_is(provider, "hyperlane")) return abi.encodeCall(HyperlaneTransceiverBase.setDomain, (key, uint32(id)));
        if (_is(provider, "wormhole")) return abi.encodeCall(WormholeTransceiver.setWormholeChain, (key, uint16(id)));
        if (_is(provider, "op-stack-l1-l2")) {
            return abi.encodeCall(OpStackTransceiver.setMessenger, (key, address(uint160(id))));
        }
        // forge-lint: disable-end(unsafe-typecast)
        revert DeployCheck("the provider has an id setter");
    }

    /* ================================ registries ============================== */

    /// @notice `local`'s registry entries: every parity chain graded as `ChainConfig.gradeOf`
    ///         grades it, each provider added on every chain it was deployed to under the
    ///         first-generation deployer, those but the home marked live, and each provider's
    ///         transceiver here. Entries the seed already holds are no-ops.
    /// @dev A chain is marked live in the batch the proposers schedule, so the delay is the window
    ///      for checking each deployment independently of the deployer (`deploy/README.md`).
    function registryBatch(Plan memory p, ChainEntry memory local)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        address registry = address(ChainDeploy.predict(p.g).registry);
        Call[] memory calls = new Call[](p.chains.length * (1 + 2 * p.g.providers.length) + p.g.providers.length);
        uint256 n = _chainCalls(p, local, registry, calls, 0);
        n = _providerCalls(p, local, registry, calls, n);
        n = _transceiverCalls(p, local, registry, calls, n);
        targets = new address[](n);
        values = new uint256[](n);
        payloads = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (targets[i], payloads[i]) = (calls[i].target, calls[i].data);
        }
    }

    function _chainCalls(Plan memory p, ChainEntry memory local, address registry, Call[] memory calls, uint256 n)
        private
        view
        returns (uint256)
    {
        for (uint256 i; i < p.chains.length; ++i) {
            bytes memory data = abi.encodeCall(
                ChainRegistry.addChainKey,
                (Erc7930.encodeEvmChain(p.chains[i].chainId), ChainConfig.gradeOf(local, p.chains[i]))
            );
            calls[n++] = Call(registry, 0, data);
        }
        return n;
    }

    /// @dev Adds each provider deployed on a chain under the first-generation deployer, and marks it
    ///      live unless the seed already did (the home) or the chain is `local`, which never sends
    ///      to itself.
    function _providerCalls(Plan memory p, ChainEntry memory local, address registry, Call[] memory calls, uint256 n)
        private
        view
        returns (uint256)
    {
        uint256 providers = p.g.providers.length;
        for (uint256 i; i < p.chains.length; ++i) {
            bytes32 key = ChainKey.forEvm(p.chains[i].chainId);
            bool live = p.chains[i].chainId != p.g.home.chainId && p.chains[i].chainId != local.chainId;
            for (uint256 j; j < providers; ++j) {
                if (!p.deployed[i * providers + j]) continue;
                bytes32 provider = keccak256(bytes(p.g.providers[j].name));
                bytes memory add = abi.encodeCall(ChainRegistry.addProviderOnChain, (key, provider, p.g.deployer));
                calls[n++] = Call(registry, 0, add);
                if (live) calls[n++] = Call(registry, 0, abi.encodeCall(ChainRegistry.markLive, (key, provider)));
            }
        }
        return n;
    }

    function _transceiverCalls(Plan memory p, ChainEntry memory local, address registry, Call[] memory calls, uint256 n)
        private
        view
        returns (uint256)
    {
        for (uint256 i; i < p.g.providers.length; ++i) {
            string memory name = p.g.providers[i].name;
            if (!isOn(p, name, local)) continue;
            bytes memory data =
                abi.encodeCall(ChainRegistry.setLocalTransceiver, (keccak256(bytes(name)), transceiver(p, name)));
            calls[n++] = Call(registry, 0, data);
        }
        return n;
    }

    /// @notice The call a proposer makes to schedule `local`'s registry batch.
    function scheduleRegistry(Plan memory p, ChainEntry memory local) internal view returns (Call memory) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = registryBatch(p, local);
        return Call(
            address(ChainDeploy.predict(p.g).timelock),
            0,
            abi.encodeCall(
                TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), bytes32(0), p.g.timelockDelay)
            )
        );
    }

    /// @notice The transaction anyone submits on `local` once its timelock's delay has passed.
    function executeRegistry(Plan memory p, ChainEntry memory local) internal view returns (Tx memory) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = registryBatch(p, local);
        return Tx(
            address(ChainDeploy.predict(p.g).timelock),
            0,
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), bytes32(0)))
        );
    }

    /* ============================= deployer rotation ========================== */

    /// @notice One registry's rotation: `setCurrentDeployer(newDeployer)`, then `rekeyPending` to it
    ///         for each pair in `pending`, in one timelock batch, so no later call can run first.
    /// @dev The same batch goes to every registry. A pair is `Pending` in all of them or in none.
    function rotationBatch(Plan memory p, address newDeployer, PendingPair[] memory pending)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        address registry = address(ChainDeploy.predict(p.g).registry);
        uint256 n = 1 + pending.length;
        targets = new address[](n);
        values = new uint256[](n);
        payloads = new bytes[](n);
        payloads[0] = abi.encodeCall(ChainRegistry.setCurrentDeployer, (newDeployer));
        for (uint256 i; i < pending.length; ++i) {
            payloads[1 + i] = abi.encodeCall(
                ChainRegistry.rekeyPending,
                (ChainKey.forEvm(pending[i].chainId), keccak256(bytes(pending[i].provider)), newDeployer)
            );
        }
        for (uint256 i; i < n; ++i) {
            targets[i] = registry;
        }
    }

    function scheduleRotation(Plan memory p, address newDeployer, PendingPair[] memory pending)
        internal
        view
        returns (Call memory)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            rotationBatch(p, newDeployer, pending);
        return Call(
            address(ChainDeploy.predict(p.g).timelock),
            0,
            abi.encodeCall(
                TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), bytes32(0), p.g.timelockDelay)
            )
        );
    }

    /// @notice The transaction anyone submits on any chain once its timelock's delay has passed.
    function executeRotation(Plan memory p, address newDeployer, PendingPair[] memory pending)
        internal
        view
        returns (Tx memory)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            rotationBatch(p, newDeployer, pending);
        return Tx(
            address(ChainDeploy.predict(p.g).timelock),
            0,
            abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), bytes32(0)))
        );
    }

    /// @notice By the governor's owner on the home: schedule the rotation on the home's registry
    ///         through the first proposer's transmitter.
    function rotateHome(Plan memory p, address newDeployer, PendingPair[] memory pending)
        internal
        view
        returns (Tx[] memory txs)
    {
        Call[] memory schedule = new Call[](1);
        schedule[0] = scheduleRotation(p, newDeployer, pending);
        txs = new Tx[](1);
        txs[0] = _execute(p, p.g.proposers[0], schedule);
    }

    /// @notice By the governor's owner: schedule the rotation on every other chain, one message
    ///         each from the first proposer's transmitter to its receiver there, which is a
    ///         proposer of that chain's timelock.
    function rotateRemote(Plan memory p, address newDeployer, PendingPair[] memory pending)
        internal
        view
        returns (Tx[] memory txs)
    {
        string memory name = p.g.proposers[0];
        address conduit = governor(p, name);
        Call[] memory schedule = new Call[](1);
        schedule[0] = scheduleRotation(p, newDeployer, pending);
        uint256 gas = DeliveryGas.PAYLOAD + CALL_GAS + (1 + pending.length) * SCHEDULE_ENTRY_GAS;
        for (uint256 i; i < p.chains.length; ++i) {
            if (p.chains[i].chainId == p.g.home.chainId) continue;
            bytes memory data = abi.encodeCall(
                TransmitterBase.sendMessage,
                (
                    Erc7930.encodeEvm(p.chains[i].chainId, conduit),
                    Payload.encodeCalls(schedule),
                    GasAttribute.forMultisig(name, gas)
                )
            );
            txs = _push(txs, Tx(conduit, 0, data));
        }
    }

    /* ================================== phases ================================ */

    /// @notice Step 3, by the governor's owner at home: create its transmitter under every
    ///         provider there, set each transceiver's routes and ids, and schedule the home
    ///         registry through the first proposer's transmitter.
    function prepareHome(Plan memory p) internal view returns (Tx[] memory txs) {
        ChainEntry memory home = p.g.home;
        for (uint256 i; i < p.g.providers.length; ++i) {
            string memory name = p.g.providers[i].name;
            if (!isOn(p, name, home)) continue;
            txs = _push(txs, Tx(transceiver(p, name), 0, abi.encodeCall(TransceiverBase.createTransmitter, (p.g.salt))));
            Call[] memory lanes = laneCalls(p, name, home);
            if (lanes.length != 0) txs = _push(txs, _execute(p, name, lanes));
        }
        Call[] memory schedule = new Call[](1);
        schedule[0] = scheduleRegistry(p, home);
        txs = _push(txs, _execute(p, p.g.proposers[0], schedule));
    }

    /// @notice Steps 4 and 5, by the governor's owner at home once its registry has executed:
    ///         set the home's LayerZero peers, then bootstrap every other chain under every
    ///         provider that connects it to the home. Each bootstrap's payload sets that
    ///         transceiver's routes and ids, and the first proposer's also schedules that chain's
    ///         registry. Each transmitter pays from its balance, which must hold the quotes.
    function bootstrap(Plan memory p) internal view returns (Tx[] memory txs) {
        ChainEntry memory home = p.g.home;
        Call[] memory peers = peerCalls(p, home);
        if (peers.length != 0) txs = _push(txs, _execute(p, "layerzero", peers));
        for (uint256 i; i < p.chains.length; ++i) {
            ChainEntry memory x = p.chains[i];
            if (x.chainId == home.chainId) continue;
            for (uint256 j; j < p.g.providers.length; ++j) {
                Tx[] memory more = _bootstrapTxs(p, p.g.providers[j].name, x);
                for (uint256 k; k < more.length; ++k) {
                    txs = _push(txs, more[k]);
                }
            }
        }
    }

    /// @dev For LayerZero, first the transmitter's own peer there, for the messages `connect`
    ///      sends.
    function _bootstrapTxs(Plan memory p, string memory name, ChainEntry memory x)
        private
        view
        returns (Tx[] memory txs)
    {
        uint256 id = idFor(p, name, p.g.home, x);
        if (id == 0) return txs;
        address conduit = governor(p, name);
        if (_is(name, "layerzero")) {
            // forge-lint: disable-next-line(unsafe-typecast) layerzero.toml's id_bits is 32
            txs = _push(txs, Tx(conduit, 0, abi.encodeCall(IOAppCore.setPeer, (uint32(id), _word(conduit)))));
        }
        Call[] memory calls = laneCalls(p, name, x);
        uint256 gas = DeliveryGas.BOOTSTRAP + calls.length * CALL_GAS;
        if (_is(name, p.g.proposers[0])) {
            calls = _push(calls, scheduleRegistry(p, x));
            gas += scheduleGas(p, x);
        }
        bytes memory data =
            abi.encodeCall(TransmitterBase.bootstrap, (x.chainId, calls, GasAttribute.forMultisig(name, gas)));
        txs = _push(txs, Tx(conduit, 0, data));
    }

    /// @notice Step 5's LayerZero peers off the home, by the governor's owner once each chain's
    ///         registry has executed: one message per chain.
    function connect(Plan memory p) internal view returns (Tx[] memory txs) {
        for (uint256 i; i < p.chains.length; ++i) {
            ChainEntry memory x = p.chains[i];
            if (x.chainId == p.g.home.chainId) continue;
            Call[] memory peers = peerCalls(p, x);
            if (peers.length == 0) continue;
            address lz = governor(p, "layerzero");
            bytes memory data = abi.encodeCall(
                TransmitterBase.sendMessage,
                (
                    Erc7930.encodeEvm(x.chainId, lz),
                    Payload.encodeCalls(peers),
                    GasAttribute.forMultisig("layerzero", DeliveryGas.PAYLOAD + peers.length * CALL_GAS)
                )
            );
            txs = _push(txs, Tx(lz, 0, data));
        }
    }

    function scheduleGas(Plan memory p, ChainEntry memory local) internal view returns (uint256) {
        (address[] memory targets,,) = registryBatch(p, local);
        return CALL_GAS + targets.length * SCHEDULE_ENTRY_GAS;
    }

    /* ================================= helpers ================================ */

    function _execute(Plan memory p, string memory provider, Call[] memory calls) private pure returns (Tx memory) {
        return Tx(governor(p, provider), 0, abi.encodeCall(TransmitterBase.execute, (calls)));
    }

    function _hasProvider(Plan memory p, string memory name) private pure returns (bool) {
        for (uint256 i; i < p.g.providers.length; ++i) {
            if (_is(p.g.providers[i].name, name)) return true;
        }
        return false;
    }

    function _is(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _word(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _push(Call[] memory xs, Call memory x) private pure returns (Call[] memory out) {
        out = new Call[](xs.length + 1);
        for (uint256 i; i < xs.length; ++i) {
            out[i] = xs[i];
        }
        out[xs.length] = x;
    }

    function _push(Tx[] memory xs, Tx memory x) private pure returns (Tx[] memory out) {
        out = new Tx[](xs.length + 1);
        for (uint256 i; i < xs.length; ++i) {
            out[i] = xs[i];
        }
        out[xs.length] = x;
    }
}
