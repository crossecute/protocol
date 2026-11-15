// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeCreationProof} from "@crossecute/safe-guard/authority/AuthorityUpdateTypes.sol";
import {SafeCreation} from "src/messaging/authority/SafeCreation.sol";
import {SAFE_L2_SINGLETON, SAFE_SINGLETON} from "src/messaging/authority/SafeDeployment.sol";
import {OWNER_EOA, OWNER_SAFE, SafeAuthorityRecord, SafeOwner} from "src/messaging/signed/types/SafeAuthorityTypes.sol";

contract SafeCreationHarness {
    function requireCreationRecord(
        uint256 sourceChainId,
        SafeAuthorityRecord memory record,
        SafeCreationProof memory proof
    ) external pure {
        SafeCreation.requireCreationRecord(sourceChainId, record, proof);
    }
}

/// @dev Vectors are Safes the canonical 1.5.0 factory created on Ethereum mainnet, so they check
///      the pinned factory and initcode hashes independently of the library's own formula. Setup
///      delegatecalls and the chain-specific salt are checked against the factory itself in
///      safe-guard's SafeCreationSafe.t.sol.
contract SafeCreationTest is Test {
    // createProxyWithNonce in tx 0x6c9efe48249c3838293b6f38c49462deb85b5b6a85d75ec12b6db589ec852734.
    address internal constant SAFE_A = 0x1Cb18F6152b928c776302c27e8A69Ea89cC7c460;
    uint256 internal constant NONCE_A = 205205040214518786988358032203076234611;
    bytes internal constant INITIALIZER_A =
        hex"b63e800d0000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000003ecbf78a123cdd18dc1f702e63ce46b76f501171000000000000000000000000be0b407782a7599380fa726db315340126d622290000000000000000000000000000000000000000000000000000000000000000";
    // createProxyWithNonce in tx 0xbae7427137f7b80453d0abbfd22c7b693f1938bfcdec02f1c3c0c81fb10bbe1d.
    address internal constant SAFE_B = 0x11160B03594fabcf4C93c64b211dc29FeEE63A6A;
    uint256 internal constant NONCE_B = 291472265368346313963518617591476223724;

    address internal constant OWNER_1 = 0x3ECbF78A123CdD18Dc1F702E63cE46B76f501171;
    address internal constant OWNER_2 = 0xBe0B407782a7599380Fa726db315340126d62229;
    address internal constant OWNER_3 = 0xc7A0168225B141065868ba7142Ae6DD70d9B077C;

    SafeCreationHarness internal harness;

    function setUp() public {
        harness = new SafeCreationHarness();
    }

    function test_mainnetCreations() public view {
        assertEq(INITIALIZER_A, _initializer(_pair(OWNER_1, OWNER_2), 2), "vector encoding");
        harness.requireCreationRecord(1, _record(SAFE_A, _pair(OWNER_1, OWNER_2), 2), _proofA());
        harness.requireCreationRecord(
            1,
            _record(SAFE_B, _pair(OWNER_2, OWNER_3), 2),
            SafeCreationProof(SAFE_SINGLETON, _initializer(_pair(OWNER_2, OWNER_3), 2), NONCE_B)
        );
    }

    function test_ownerKindsAreNotChecked() public view {
        SafeAuthorityRecord memory record = _record(SAFE_A, _pair(OWNER_1, OWNER_2), 2);
        record.owners[1].kind = OWNER_SAFE;
        harness.requireCreationRecord(1, record, _proofA());
    }

    function test_rejectsWrongAddressInputs() public {
        SafeAuthorityRecord memory record = _record(SAFE_A, _pair(OWNER_1, OWNER_2), 2);
        SafeCreationProof memory proof = _proofA();

        proof.saltNonce = NONCE_A + 1;
        _expectAddressMismatch(record, proof);

        proof = _proofA();
        proof.singleton = SAFE_L2_SINGLETON;
        _expectAddressMismatch(record, proof);

        proof = _proofA();
        proof.initializer = _initializer(_pair(OWNER_2, OWNER_1), 2);
        _expectAddressMismatch(record, proof);

        record.safe = SAFE_B;
        _expectAddressMismatch(record, _proofA());
    }

    function test_rejectsUnpinnedSingleton() public {
        SafeCreationProof memory proof = _proofA();
        proof.singleton = address(0xbeef);
        vm.expectRevert(abi.encodeWithSelector(SafeCreation.UnpinnedSingleton.selector, address(0xbeef)));
        harness.requireCreationRecord(1, _record(SAFE_A, _pair(OWNER_1, OWNER_2), 2), proof);
    }

    function test_rejectsRecordMismatch() public {
        _expectRecordMismatch(_record(SAFE_A, _pair(OWNER_2, OWNER_1), 2));
        _expectRecordMismatch(_record(SAFE_A, _pair(OWNER_1, OWNER_2), 1));
        _expectRecordMismatch(_record(SAFE_A, _pair(OWNER_1, OWNER_3), 2));

        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (OWNER_1, OWNER_2, OWNER_3);
        _expectRecordMismatch(_record(SAFE_A, three, 2));
    }

    function _expectAddressMismatch(SafeAuthorityRecord memory record, SafeCreationProof memory proof) internal {
        vm.expectRevert(abi.encodeWithSelector(SafeCreation.CreationAddressMismatch.selector, record.safe));
        harness.requireCreationRecord(1, record, proof);
    }

    function _expectRecordMismatch(SafeAuthorityRecord memory record) internal {
        vm.expectRevert(SafeCreation.CreationRecordMismatch.selector);
        harness.requireCreationRecord(1, record, _proofA());
    }

    function _proofA() internal pure returns (SafeCreationProof memory) {
        return SafeCreationProof(SAFE_SINGLETON, INITIALIZER_A, NONCE_A);
    }

    function _initializer(address[] memory owners, uint256 threshold) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            SafeCreation.SETUP, owners, threshold, address(0), "", address(0), address(0), 0, address(0)
        );
    }

    function _pair(address a, address b) internal pure returns (address[] memory owners) {
        owners = new address[](2);
        (owners[0], owners[1]) = (a, b);
    }

    function _record(address safe, address[] memory owners, uint256 threshold)
        internal
        pure
        returns (SafeAuthorityRecord memory record)
    {
        record.safe = safe;
        record.threshold = threshold;
        record.owners = new SafeOwner[](owners.length);
        for (uint256 i; i < owners.length; ++i) {
            record.owners[i] = SafeOwner(owners[i], OWNER_EOA);
        }
    }
}
