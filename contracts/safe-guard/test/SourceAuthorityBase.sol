// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {SafePolicyGuard} from "policy-engine/SafePolicyGuard.sol";
import {Operation} from "policy-engine/interfaces/Operation.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/libraries/Enum.sol";
import {AuthorityGraph, AuthorityNode} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {AuthorityUpdateEncoding} from "crossecute/messaging/authority/AuthorityUpdateEncoding.sol";
import {ChildUpdate} from "crossecute/messaging/authority/ChildUpdate.sol";
import {Call} from "crossecute/messaging/Call.sol";
import {OWNER_EOA, SafeAuthorityRecord, SafeOwner} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {NestedSafeApproval} from "crossecute/messaging/signed/types/SignedDispatchTypes.sol";
import {AuthorityUpdate} from "../src/authority/AuthorityUpdateTypes.sol";
import {ISourceAuthorityGuard} from "../src/authority/ISourceAuthorityGuard.sol";
import {Batch} from "./Batch.sol";
import {SafeFixture} from "./SafeFixture.sol";

/// @dev Real Safe 1.5.0 proxies with the guard in both slots, and builders for the activation,
///      ownership-change and selectAuthority transactions the guard recognizes. Updates run as
///      `multicall([stageUpdate, execTransaction])` through `Batch`.
abstract contract SourceAuthorityBase is SafeFixture {
    Batch internal batch;
    mapping(bytes32 authorityHash => bytes graph) internal graphWitnesses;

    function setUp() public virtual override {
        super.setUp();
        batch = new Batch();
    }

    /// @dev A Safe with `keys` as owners (in order) installed with both guard slots, not activated.
    function _guarded(uint256[] memory keys, uint256 threshold) internal returns (Safe safe) {
        address[] memory owners = new address[](keys.length);
        Signer[] memory signers = new Signer[](threshold);
        for (uint256 i = 0; i < keys.length; ++i) {
            owners[i] = vm.addr(keys[i]);
        }
        safe = _newSafe(owners, threshold);
        for (uint256 i = 0; i < threshold; ++i) {
            signers[i] = _eoa(keys[i]);
        }
        _install(safe, signers, guard, _permissiveConfig(), true);
    }

    /// @dev The default policies plus any delegatecall, so the guard's own rules are what refuse one.
    function _permissiveConfig() internal view returns (SafePolicyGuard.Configuration[] memory configs) {
        SafePolicyGuard.Configuration[] memory base = _defaultConfig();
        configs = new SafePolicyGuard.Configuration[](base.length + 1);
        for (uint256 i = 0; i < base.length; ++i) {
            configs[i] = base[i];
        }
        configs[base.length] = _config(address(0), bytes4(0), Operation.DELEGATECALL, address(allowPolicy));
    }

    function _record(Safe safe, uint8[] memory kinds) internal view returns (SafeAuthorityRecord memory record) {
        address[] memory owners = safe.getOwners();
        record.safe = address(safe);
        record.threshold = safe.getThreshold();
        record.owners = new SafeOwner[](owners.length);
        for (uint256 i = 0; i < owners.length; ++i) {
            record.owners[i] = SafeOwner(owners[i], kinds.length == 0 ? OWNER_EOA : kinds[i]);
        }
    }

    function _record(Safe safe) internal view returns (SafeAuthorityRecord memory) {
        return _record(safe, new uint8[](0));
    }

    function _graph(SafeAuthorityRecord memory root) internal pure returns (AuthorityGraph memory graph) {
        graph.nodes = new AuthorityNode[](1);
        graph.nodes[0] = AuthorityNode(root, bytes32(0));
    }

    function _graph(SafeAuthorityRecord memory root, SafeAuthorityRecord memory child, bytes32 position)
        internal
        pure
        returns (AuthorityGraph memory graph)
    {
        graph.nodes = new AuthorityNode[](2);
        graph.nodes[0] = AuthorityNode(root, bytes32(0));
        graph.nodes[1] = AuthorityNode(child, position);
    }

    function _hash(AuthorityGraph memory graph) internal view returns (bytes32) {
        return AuthorityUpdateEncoding.graphHash(block.chainid, graph);
    }

    function _head(Safe safe) internal view returns (bytes32) {
        return guard.selection(address(safe)).updateHead;
    }

    /// @dev Stages `graph` and executes `to`/`data` signed by `signers`, whose blob doubles as the
    ///      portable set.
    function _execStaged(
        Safe safe,
        address to,
        bytes memory data,
        Enum.Operation op,
        AuthorityGraph memory graph,
        ChildUpdate[] memory children,
        Signer[] memory signers
    ) internal {
        bytes memory signatures = _sign(signers, _txHash(safe, to, 0, data, op));
        _execStaged(safe, to, data, op, graph, children, signatures, signatures);
    }

    function _execStaged(
        Safe safe,
        address to,
        bytes memory data,
        Enum.Operation op,
        AuthorityGraph memory graph,
        ChildUpdate[] memory children,
        bytes memory executing,
        bytes memory portable
    ) internal {
        batch.run(_stagedCalls(safe, to, data, op, graph, children, executing, portable));
    }

    /// @dev The two calls of an update, built without running them, so a test can expect a revert
    ///      from `batch.run` alone.
    function _stagedCalls(
        Safe safe,
        address to,
        bytes memory data,
        Enum.Operation op,
        AuthorityGraph memory graph,
        ChildUpdate[] memory children,
        bytes memory executing,
        bytes memory portable
    ) internal returns (Batch.Call[] memory calls) {
        graphWitnesses[_hash(graph)] = abi.encode(graph);
        AuthorityGraph memory currentGraph = _currentGraph(safe);
        calls = new Batch.Call[](2);
        calls[0] = Batch.Call(
            address(guard),
            abi.encodeCall(
                guard.stageUpdate, (address(safe), currentGraph, graph, children, portable, new NestedSafeApproval[](0))
            ),
            false
        );
        calls[1] = _executeCall(safe, to, data, op, executing);
    }

    function _currentGraph(Safe safe) internal view returns (AuthorityGraph memory current) {
        bytes32 authorityHash = guard.selection(address(safe)).authorityHash;
        if (authorityHash != bytes32(0)) current = abi.decode(graphWitnesses[authorityHash], (AuthorityGraph));
    }

    function _executeCall(Safe safe, address to, bytes memory data, Enum.Operation op, bytes memory signatures)
        internal
        pure
        returns (Batch.Call memory)
    {
        return Batch.Call(
            address(safe),
            abi.encodeCall(
                Safe.execTransaction, (to, 0, data, op, 0, 0, 0, address(0), payable(address(0)), signatures)
            ),
            false
        );
    }

    function _activationCalls(Safe safe, AuthorityGraph memory graph, Signer[] memory signers)
        internal
        returns (Batch.Call[] memory)
    {
        bytes memory data = abi.encodeCall(ISourceAuthorityGuard.activate, (_hash(graph)));
        bytes memory signatures = _sign(signers, _txHash(safe, address(guard), 0, data, Enum.Operation.Call));
        return _stagedCalls(
            safe, address(guard), data, Enum.Operation.Call, graph, new ChildUpdate[](0), signatures, signatures
        );
    }

    function _activate(Safe safe, AuthorityGraph memory graph, Signer[] memory signers) internal {
        _execStaged(
            safe,
            address(guard),
            abi.encodeCall(ISourceAuthorityGuard.activate, (_hash(graph))),
            Enum.Operation.Call,
            graph,
            new ChildUpdate[](0),
            signers
        );
    }

    function _activate(Safe safe, Signer[] memory signers) internal {
        _activate(safe, _graph(_record(safe)), signers);
    }

    function _ownershipData(Safe safe, bytes32 previous, bytes32 next, Call[] memory mutations)
        internal
        view
        returns (bytes memory)
    {
        return AuthorityUpdateEncoding.ownershipBatchData(
            address(guard), address(safe), AuthorityUpdate(previous, next), mutations
        );
    }

    function _select(Safe safe, AuthorityGraph memory graph, Signer[] memory signers) internal {
        _execStaged(
            safe,
            address(guard),
            abi.encodeCall(ISourceAuthorityGuard.selectAuthority, (AuthorityUpdate(_head(safe), _hash(graph)))),
            Enum.Operation.Call,
            graph,
            new ChildUpdate[](0),
            signers
        );
    }

    function _execOwnershipChange(
        Safe safe,
        AuthorityGraph memory next,
        Call[] memory mutations,
        Signer[] memory signers
    ) internal {
        _execStaged(
            safe,
            address(multiSend),
            _ownershipData(safe, _head(safe), _hash(next), mutations),
            Enum.Operation.DelegateCall,
            next,
            new ChildUpdate[](0),
            signers
        );
    }

    function _call(address target, bytes memory data) internal pure returns (Call memory) {
        return Call(target, 0, data);
    }
}
