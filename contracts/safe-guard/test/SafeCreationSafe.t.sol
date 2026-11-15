// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafeCreation} from "crossecute/messaging/authority/SafeCreation.sol";
import {
    SAFE_L2_PROXY_INITCODE_HASH,
    SAFE_L2_SINGLETON,
    SAFE_PROXY_FACTORY,
    SAFE_PROXY_INITCODE_HASH,
    SAFE_SINGLETON,
    SAFE_TO_L2_SETUP
} from "crossecute/messaging/authority/SafeDeployment.sol";
import {SafeOwner, SafeAuthorityRecord, OWNER_EOA} from "crossecute/messaging/signed/types/SafeAuthorityTypes.sol";
import {Bytes} from "crossecute/messaging/signed/Bytes.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {SafeL2} from "safe-smart-account/SafeL2.sol";
import {SafeToL2Setup} from "safe-smart-account/libraries/SafeToL2Setup.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";
import {SafeCreationProof} from "../src/authority/AuthorityUpdateTypes.sol";

contract SafeCreationCaller {
    function requireCreationRecord(
        uint256 sourceChainId,
        SafeAuthorityRecord memory record,
        SafeCreationProof memory proof
    ) external pure {
        SafeCreation.requireCreationRecord(sourceChainId, record, proof);
    }
}

contract SetupNoop {
    fallback() external {}
}

/// @dev Runs the canonical Safe 1.5.0 factory's mainnet runtime code at its pinned address, so the
///      library is checked against the proxies that factory actually deploys. The singletons and
///      SafeToL2Setup are this repo's 1.5.0 builds etched at their pinned addresses: only their
///      addresses enter the proxy initcode, and they run setup.
contract SafeCreationSafeTest is Test {
    /// @dev Codehash of the factory in safe-deployments' v1.5.0 safe_proxy_factory.json.
    bytes32 internal constant FACTORY_CODEHASH = 0x967dae4cda22b0c9ef7f31b010bdc1ceb0af9904b0c3dc060b5302e4c18a4529;
    /// @dev eth_getCode of SAFE_PROXY_FACTORY on Ethereum mainnet, read 2026-11-15.
    bytes internal constant FACTORY_CODE =
        hex"608060405234801561001057600080fd5b50600436106100625760003560e01c80631688f0b9146100675780631a334b0b146101765780633408e470146102855780634662f9d6146102a357806353e5d935146103b2578063ec9e80bb14610435575b600080fd5b61014a6004803603606081101561007d57600080fd5b81019080803573ffffffffffffffffffffffffffffffffffffffff169060200190929190803590602001906401000000008111156100ba57600080fd5b8201836020820111156100cc57600080fd5b803590602001918460018302840111640100000000831117156100ee57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600081840152601f19601f82011690508083019250505050505050919291929080359060200190929190505050610544565b604051808273ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b6102596004803603606081101561018c57600080fd5b81019080803573ffffffffffffffffffffffffffffffffffffffff169060200190929190803590602001906401000000008111156101c957600080fd5b8201836020820111156101db57600080fd5b803590602001918460018302840111640100000000831117156101fd57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600081840152601f19601f820116905080830192505050505050509192919290803590602001909291905050506105f8565b604051808273ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b61028d6106f6565b6040518082815260200191505060405180910390f35b610386600480360360608110156102b957600080fd5b81019080803573ffffffffffffffffffffffffffffffffffffffff169060200190929190803590602001906401000000008111156102f657600080fd5b82018360208201111561030857600080fd5b8035906020019184600183028401116401000000008311171561032a57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600081840152601f19601f82011690508083019250505050505050919291929080359060200190929190505050610703565b604051808273ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b6103ba6107f2565b6040518080602001828103825283818151815260200191508051906020019080838360005b838110156103fa5780820151818401526020810190506103df565b50505050905090810190601f1680156104275780820380516001836020036101000a031916815260200191505b509250505060405180910390f35b6105186004803603606081101561044b57600080fd5b81019080803573ffffffffffffffffffffffffffffffffffffffff1690602001909291908035906020019064010000000081111561048857600080fd5b82018360208201111561049a57600080fd5b803590602001918460018302840111640100000000831117156104bc57600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600081840152601f19601f8201169050808301925050505050505091929192908035906020019092919050505061081d565b604051808273ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b600080838051906020012083604051602001808381526020018281526020019250505060405160208183030381529060405280519060200120905061058a8585836108e0565b91508173ffffffffffffffffffffffffffffffffffffffff167f4f51faf6c4561ff95f067657e43439f0f856d97c04d9ec9070a6199ad418e23586604051808273ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a2509392505050565b600061060584848461081d565b90508073ffffffffffffffffffffffffffffffffffffffff167f7a1c96f74273709828c0e67ab96189772005d3b4948bc6902693eb21e4e2cc6a85858561064a6106f6565b604051808573ffffffffffffffffffffffffffffffffffffffff16815260200180602001848152602001838152602001828103825285818151815260200191508051906020019080838360005b838110156106b2578082015181840152602081019050610697565b50505050905090810190601f1680156106df5780820380516001836020036101000a031916815260200191505b509550505050505060405180910390a29392505050565b6000804690508091505090565b6000610710848484610544565b90508073ffffffffffffffffffffffffffffffffffffffff167f6e78ae8c51534f0b801d7aa7cce5a2113f3c3368c61b06fa61415f361d400431858585604051808473ffffffffffffffffffffffffffffffffffffffff16815260200180602001838152602001828103825284818151815260200191508051906020019080838360005b838110156107af578082015181840152602081019050610794565b50505050905090810190601f1680156107dc5780820380516001836020036101000a031916815260200191505b5094505050505060405180910390a29392505050565b60606040518060200161080490610b00565b6020820181038252601f19601f82011660405250905090565b6000808380519060200120836108316106f6565b6040516020018084815260200183815260200182815260200193505050506040516020818303038152906040528051906020012090506108728585836108e0565b91508173ffffffffffffffffffffffffffffffffffffffff167f4f51faf6c4561ff95f067657e43439f0f856d97c04d9ec9070a6199ad418e23586604051808273ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390a2509392505050565b60006108eb84610aed565b61095d576040517f08c379a000000000000000000000000000000000000000000000000000000000815260040180806020018281038252601f8152602001807f53696e676c65746f6e20636f6e7472616374206e6f74206465706c6f7965640081525060200191505060405180910390fd5b60006040518060200161096f90610b00565b6020820181038252601f19601f820116604052508573ffffffffffffffffffffffffffffffffffffffff166040516020018083805190602001908083835b602083106109d057805182526020820191506020810190506020830392506109ad565b6001836020036101000a038019825116818451168082178552505050505050905001828152602001925050506040516020818303038152906040529050828151826020016000f59150600073ffffffffffffffffffffffffffffffffffffffff168273ffffffffffffffffffffffffffffffffffffffff161415610abc576040517f08c379a00000000000000000000000000000000000000000000000000000000081526004018080602001828103825260138152602001807f437265617465322063616c6c206661696c65640000000000000000000000000081525060200191505060405180910390fd5b600084511115610ae5576000808551602087016000865af1610ae4576040513d6000823e3d81fd5b5b509392505050565b600080823b905060008111915050919050565b6101b680610b0e8339019056fe608060405234801561001057600080fd5b506040516101b63803806101b68339818101604052602081101561003357600080fd5b8101908080519060200190929190505050600073ffffffffffffffffffffffffffffffffffffffff168173ffffffffffffffffffffffffffffffffffffffff1614156100ca576040517f08c379a00000000000000000000000000000000000000000000000000000000081526004018080602001828103825260228152602001806101946022913960400191505060405180910390fd5b806000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff16021790555050607b806101196000396000f3fe608060405260005463a619486e60003560e01c14156024578060601b606c5260206060f35b3660008037600080366000845af43d6000803e806040573d6000fd5b3d6000f3fea2646970667358221220e61834ebd2d8cd909d362bf67c47ef58fd665df38e6dd036ce65611101d072e964736f6c63430007060033496e76616c69642073696e676c65746f6e20616464726573732070726f7669646564a2646970667358221220c459ca945b94a10bbb10ebb35ee4a4e094cf6d9bfba97f85efb09c47cc9bac0a64736f6c63430007060033";
    uint256 internal constant POOL = 20;

    SafeCreationCaller internal caller;
    SafeProxyFactory internal factory = SafeProxyFactory(SAFE_PROXY_FACTORY);

    function setUp() public {
        assertEq(keccak256(FACTORY_CODE), FACTORY_CODEHASH, "factory code");
        vm.etch(SAFE_PROXY_FACTORY, FACTORY_CODE);
        vm.etch(SAFE_SINGLETON, address(new Safe()).code);
        vm.etch(SAFE_L2_SINGLETON, address(new SafeL2()).code);
        vm.etch(SAFE_TO_L2_SETUP, address(new SafeToL2Setup()).code);
        caller = new SafeCreationCaller();
    }

    function test_initcodeHashesMatchFactory() public view {
        bytes memory code = factory.proxyCreationCode();
        assertEq(keccak256(abi.encodePacked(code, uint256(uint160(SAFE_SINGLETON)))), SAFE_PROXY_INITCODE_HASH);
        assertEq(keccak256(abi.encodePacked(code, uint256(uint160(SAFE_L2_SINGLETON)))), SAFE_L2_PROXY_INITCODE_HASH);
    }

    /// @dev Every factory creation with setup and no delegatecall or setupToL2(SafeL2) is accepted
    ///      under its live owners and threshold; a chain-specific one only for its own chain.
    function testFuzz_acceptsFactoryCreations(uint256 seed) public {
        uint256 count = 1 + _draw(seed, "count") % 16;
        address[] memory owners = new address[](count);
        uint256 first = _draw(seed, "first");
        for (uint256 i = 0; i < count; ++i) {
            owners[i] = address(uint160(0x1000 + (first + i) % POOL));
        }
        address singleton = _draw(seed, "singleton") % 2 == 0 ? SAFE_SINGLETON : SAFE_L2_SINGLETON;
        bool toL2 = _draw(seed, "toL2") % 2 == 0;
        bytes memory initializer = _initializer(
            owners,
            1 + _draw(seed, "threshold") % count,
            toL2 ? SAFE_TO_L2_SETUP : address(0),
            toL2 ? abi.encodeCall(SafeToL2Setup.setupToL2, (SAFE_L2_SINGLETON)) : bytes("")
        );
        SafeCreationProof memory proof = SafeCreationProof(singleton, initializer, _draw(seed, "nonce"));
        bool chainSpecific = _draw(seed, "salt") % 2 == 0;
        address safe = _create(proof, chainSpecific);

        SafeAuthorityRecord memory record = _live(safe);
        caller.requireCreationRecord(block.chainid, record, proof);
        if (chainSpecific) {
            vm.expectRevert(abi.encodeWithSelector(SafeCreation.CreationAddressMismatch.selector, safe));
            caller.requireCreationRecord(block.chainid + 1, record, proof);
        }
    }

    function test_rejectsOtherSetupDelegatecall() public {
        address noop = address(new SetupNoop());
        _expectSetupRejected(noop, hex"01", noop);
        _expectSetupRejected(noop, abi.encodeCall(SafeToL2Setup.setupToL2, (SAFE_L2_SINGLETON)), noop);
        _expectSetupRejected(
            SAFE_TO_L2_SETUP, abi.encodeCall(SafeToL2Setup.setupToL2, (SAFE_SINGLETON)), SAFE_TO_L2_SETUP
        );
    }

    /// @dev Safe skips setup's delegatecall when to is zero, but the proof keeps one form.
    function test_rejectsDataWithoutTarget() public {
        _expectSetupRejected(address(0), hex"01", address(0));
    }

    /// @dev The factory skips the initializer call when it is empty, leaving setup open to anyone.
    function test_rejectsUninitializedProxy() public {
        SafeCreationProof memory proof = SafeCreationProof(SAFE_SINGLETON, "", 1);
        address safe = _create(proof, false);
        SafeAuthorityRecord memory record;
        record.safe = safe;
        vm.expectRevert(abi.encodeWithSelector(Bytes.WrongSelector.selector, SafeCreation.SETUP));
        caller.requireCreationRecord(block.chainid, record, proof);
    }

    function _expectSetupRejected(address to, bytes memory data, address reported) internal {
        address[] memory owners = new address[](1);
        owners[0] = address(0x1000);
        SafeCreationProof memory proof = SafeCreationProof(SAFE_SINGLETON, _initializer(owners, 1, to, data), 7);
        address safe = _create(proof, false);
        SafeAuthorityRecord memory record = _live(safe);
        vm.expectRevert(abi.encodeWithSelector(SafeCreation.SetupCallNotAllowed.selector, reported));
        caller.requireCreationRecord(block.chainid, record, proof);
    }

    function _create(SafeCreationProof memory proof, bool chainSpecific) internal returns (address) {
        return chainSpecific
            ? address(factory.createChainSpecificProxyWithNonce(proof.singleton, proof.initializer, proof.saltNonce))
            : address(factory.createProxyWithNonce(proof.singleton, proof.initializer, proof.saltNonce));
    }

    function _initializer(address[] memory owners, uint256 threshold, address to, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(Safe.setup, (owners, threshold, to, data, address(0), address(0), 0, payable(address(0))));
    }

    function _live(address safe) internal view returns (SafeAuthorityRecord memory record) {
        address[] memory list = Safe(payable(safe)).getOwners();
        record.safe = safe;
        record.threshold = Safe(payable(safe)).getThreshold();
        record.owners = new SafeOwner[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            record.owners[i] = SafeOwner(list[i], OWNER_EOA);
        }
    }

    function _draw(uint256 r, string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(r, label)));
    }
}
