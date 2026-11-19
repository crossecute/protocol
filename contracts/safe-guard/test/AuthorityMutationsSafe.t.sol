// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Call} from "crossecute/messaging/Call.sol";
import {MAX_SAFE_OWNERS} from "crossecute/messaging/authority/AuthorityGraph.sol";
import {AuthorityMutations} from "crossecute/messaging/authority/AuthorityMutations.sol";
import {AuthorityUpdateEncoding} from "crossecute/messaging/authority/AuthorityUpdateEncoding.sol";
import {SafeOwner, SafeAuthorityRecord, OWNER_EOA} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {SafeFixture} from "./SafeFixture.sol";

contract AuthorityMutationsCaller {
    function applyMutations(
        SafeAuthorityRecord memory current,
        Call[] memory mutations,
        SafeAuthorityRecord memory expected
    ) external pure {
        AuthorityMutations.applyMutations(current, mutations, expected);
    }
}

/// @dev Differential check of the shared derivation against a real Safe 1.5.0: each random owner
///      self-call is accepted by the derivation exactly when Safe accepts it and the result has at
///      most 16 owners, and the accepted steps as one batch reproduce Safe's final owners.
contract AuthorityMutationsSafeTest is SafeFixture {
    address internal constant SENTINEL = address(1);
    uint256 internal constant POOL = 20;
    uint256 internal constant STEPS = 12;

    AuthorityMutationsCaller internal caller;
    Safe internal safe;

    function setUp() public override {
        super.setUp();
        caller = new AuthorityMutationsCaller();
    }

    function testFuzz_matchesSafe(uint256 seed) public {
        uint256 initial = 1 + _draw(seed, "count") % MAX_SAFE_OWNERS;
        address[] memory owners = new address[](initial);
        for (uint256 i = 0; i < initial; ++i) {
            owners[i] = _pool(i);
        }
        safe = _newSafe(owners, 1 + _draw(seed, "threshold") % initial);
        SafeAuthorityRecord memory start = _live();

        Call[] memory accepted = new Call[](STEPS);
        uint256 acceptedCount = 0;
        for (uint256 step = 0; step < STEPS; ++step) {
            Call memory mutation = _randomMutation(uint256(keccak256(abi.encode(seed, step))));
            SafeAuthorityRecord memory before = _live();
            uint256 snapshot = vm.snapshotState();
            vm.prank(address(safe));
            (bool safeAccepted,) = address(safe).call(mutation.data);
            SafeAuthorityRecord memory afterStep = _live();

            Call[] memory single = new Call[](1);
            single[0] = mutation;
            try caller.applyMutations(before, single, afterStep) {
                assertTrue(safeAccepted, "derivation accepted what Safe rejected");
                accepted[acceptedCount++] = mutation;
            } catch (bytes memory reason) {
                bytes4 selector = bytes4(reason);
                assertTrue(selector != AuthorityMutations.MutationResultMismatch.selector, "result differs from Safe");
                if (safeAccepted) {
                    assertEq(
                        selector, AuthorityMutations.TooManyOwners.selector, "derivation rejected what Safe accepted"
                    );
                    assertEq(afterStep.owners.length, MAX_SAFE_OWNERS + 1);
                    vm.revertToState(snapshot);
                }
            }
        }

        assembly ("memory-safe") {
            mstore(accepted, acceptedCount)
        }
        if (acceptedCount != 0) caller.applyMutations(start, accepted, _live());
    }

    function _randomMutation(uint256 r) internal view returns (Call memory) {
        address[] memory list = safe.getOwners();
        uint256 count = list.length;
        uint256 threshold = _draw(r, "t") % (count + 3);
        uint256 kind = _draw(r, "op") % 4;
        bytes memory data;
        if (kind == 0) {
            data = abi.encodeWithSelector(AuthorityUpdateEncoding.ADD_OWNER, _newOwner(r), threshold);
        } else if (kind == 1) {
            (address prev, address owner) = _target(r, list);
            data = abi.encodeWithSelector(AuthorityUpdateEncoding.REMOVE_OWNER, prev, owner, threshold);
        } else if (kind == 2) {
            (address prev, address owner) = _target(r, list);
            data = abi.encodeWithSelector(AuthorityUpdateEncoding.SWAP_OWNER, prev, owner, _newOwner(r));
        } else {
            data = abi.encodeWithSelector(AuthorityUpdateEncoding.CHANGE_THRESHOLD, threshold);
        }
        return Call(address(safe), 0, data);
    }

    /// @dev An existing owner with its true predecessor most of the time, otherwise any address.
    function _target(uint256 r, address[] memory list) internal view returns (address prev, address owner) {
        uint256 at = _draw(r, "at") % list.length;
        owner = _draw(r, "bad owner") % 8 == 0 ? _any(_draw(r, "owner")) : list[at];
        prev = _draw(r, "bad prev") % 4 == 0 ? _any(_draw(r, "prev")) : (at == 0 ? SENTINEL : list[at - 1]);
    }

    function _newOwner(uint256 r) internal view returns (address) {
        return _draw(r, "special") % 8 == 0 ? _any(_draw(r, "new")) : _pool(_draw(r, "new"));
    }

    /// @dev Pool members plus zero, the sentinel and the Safe itself.
    function _any(uint256 r) internal view returns (address) {
        uint256 pick = r % (POOL + 3);
        if (pick == POOL) return address(0);
        if (pick == POOL + 1) return SENTINEL;
        if (pick == POOL + 2) return address(safe);
        return _pool(pick);
    }

    function _pool(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i % POOL));
    }

    function _draw(uint256 r, string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(r, label)));
    }

    function _live() internal view returns (SafeAuthorityRecord memory record) {
        address[] memory list = safe.getOwners();
        record.safe = address(safe);
        record.threshold = safe.getThreshold();
        record.owners = new SafeOwner[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            record.owners[i] = SafeOwner(list[i], OWNER_EOA);
        }
    }
}
