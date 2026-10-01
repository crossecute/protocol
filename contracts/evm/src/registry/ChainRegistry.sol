// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVmDeriver} from "src/derivation/VmDeriver.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {IRefValidator} from "src/registry/IRefValidator.sol";
import {ICommitmentScheme, SchemeFold} from "src/registry/ICommitmentScheme.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The CREATE2 inputs a message provider's contracts deploy from.
///
/// @dev One salt per provider, used on every chain, puts that provider's transceiver at one
///      address everywhere: the property `HubTransceiverBase._counterpartOn` falls back on.
///      The salt can be mined for leading zero bytes, which are cheaper in the calldata that
///      names the address.
struct ProviderDeployment {
    /// The mined salt, identical on every chain.
    bytes32 salt;
    /// keccak256 of the transceiver proxy's initcode, which is byte-identical for a hub and a
    /// spoke. Not an implementation's.
    bytes32 transceiverInitCodeHash;
    /// keccak256 of `CrossProxy`'s initcode, the same for a transmitter and a receiver.
    bytes32 accountInitCodeHash;
}

/// @title ChainRegistry
/// @notice The home-chain directory of every chain crossecute talks to, and of what can be
///         known about addresses on each.
///
/// @dev It answers questions about a chain, never about a counterpart: a transceiver's
///      location is per provider and lives on that provider's hub, while how well an address
///      on a chain can be known is the same for every provider, so it is answered here once.
///
/// @dev It holds a directory of chainKeys and message providers, and the per-chain policy a
///      hub consults before recording anything: `provenanceFor`, `validateLocation`,
///      `expectedTransceiver`, and `commitmentFor`. It holds no routes and no counterparts,
///      and nothing reads it on the send path, so a compromised registry cannot misroute a
///      payload.
contract ChainRegistry is OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Arachnid's deterministic deployment proxy, at the same address on every
    ///         standard EVM chain. The default for `create2Factory`.
    address internal constant ARACHNID_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /* ================================= storage ================================= */

    /// Set of keccak256(canonical ERC-7930 chain identifier).
    EnumerableSet.Bytes32Set private _chainKeys;
    /// chainKey => the canonical chain identifier it hashes from.
    mapping(bytes32 => bytes) private _chainIdentifier;

    /// Set of keccak256(message provider name).
    EnumerableSet.Bytes32Set private _messageProviders;
    /// messageProvider => the name it hashes from.
    mapping(bytes32 => string) private _messageProviderName;
    /// messageProvider => the CREATE2 inputs its transceiver and receivers deploy from.
    mapping(bytes32 => ProviderDeployment) private _deployment;
    /// chainKey => the CREATE2 factory to derive against. Zero means `ARACHNID_FACTORY`.
    mapping(bytes32 => address) private _create2Factory;

    /// messageProvider => the local hub transceiver that serves it.
    mapping(bytes32 => address) public localTransceiver;
    /// The reverse: which provider a local hub transceiver serves.
    mapping(address => bytes32) public providerOfTransceiver;

    /// chainKey => the contract that computes addresses on that chain, so callers never
    /// branch on VM.
    mapping(bytes32 => IVmDeriver) public deriverOf;
    /// chainKey => the abi-encoded `(Scheme, bytes)` its deriver expects. Stored so
    /// `expectedTransceiver` takes no inputs.
    mapping(bytes32 => bytes) private _deriveParams;

    /// chainKey => optional value-range validator for what ERC-7930 cannot express, e.g.
    /// Starknet felts.
    mapping(bytes32 => IRefValidator) public validatorOf;
    /// chainKey => what an address claim about this chain is worth, as declared.
    /// @dev `Attested` for chains this contract cannot recompute: Starknet (Pedersen), and
    ///      zkSync and Tron (different CREATE2). Unset falls back to `provenanceFor`'s default.
    mapping(bytes32 => Provenance) public provenanceOf;

    /// chainKey => the primitive that chain's receiver hashes commitments with.
    /// @dev A mapping rather than the `Scheme` enum, which is compiled into every locked
    ///      transmitter and cannot grow. Mutable because nothing enforces with it: a receiver
    ///      checks its own compiled fold.
    mapping(bytes32 => ICommitmentScheme) public commitmentSchemeOf;

    /* ================================== events ================================= */

    event ChainKeyAdded(bytes32 indexed chainKey, bytes chainIdentifier);
    event ChainKeyRemoved(bytes32 indexed chainKey);
    event MessageProviderAdded(bytes32 indexed messageProvider, string name);
    event MessageProviderRemoved(bytes32 indexed messageProvider);
    event LocalTransceiverSet(bytes32 indexed messageProvider, address transceiver);
    event ProviderDeploymentSet(
        bytes32 indexed messageProvider, bytes32 salt, bytes32 transceiverInitCodeHash, bytes32 accountInitCodeHash
    );
    event Create2FactorySet(bytes32 indexed chainKey, address factory);
    event DeriverSet(bytes32 indexed chainKey, address deriver);
    event DeriveParamsSet(bytes32 indexed chainKey, uint8 scheme, bytes32 paramsHash);
    event ValidatorSet(bytes32 indexed chainKey, address validator);
    event ProvenanceSet(bytes32 indexed chainKey, Provenance provenance);
    event CommitmentSchemeSet(bytes32 indexed chainKey, address scheme);

    /* ================================== errors ================================= */

    /// @dev A provider deployment, once recorded, is fixed.
    error AlreadySet();
    error NoCounterpart();
    /// @dev No salt recorded for this provider.
    error NoProviderDeployment();
    error ZeroSalt();
    error ZeroInitCodeHash();
    error UnknownChainKey();
    error UnknownMessageProvider();
    error EmptyName();
    error NoDeriver();
    error NoDeriveParams();
    error DeriverChainMismatch();
    error SchemeNotSupported();
    /// @dev No primitive registered for this chain. Reverting beats returning a digest the
    ///      destination might never match; see `Commitment._hash`.
    error NoCommitmentScheme();

    /* =============================== initializer =============================== */

    constructor() {
        _disableInitializers();
    }

    /// @param owner_ The crossecute msig.
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    /* ================================ directory ================================ */

    /// @notice Register a chain by its ERC-7930 chain identifier.
    /// @dev Takes the envelope, not a hash, so `parseStrict` rejects a non-canonical framing
    ///      before it becomes a permanent key.
    /// @param identifier ERC-7930 bytes. An account envelope is accepted and reduced to
    ///                   its chain identifier form.
    function addChainKey(bytes calldata identifier) external onlyOwner returns (bytes32 chainKey) {
        bytes memory canonical = Erc7930.toChainIdentifier(identifier);
        chainKey = keccak256(canonical);
        if (_chainKeys.add(chainKey)) {
            _chainIdentifier[chainKey] = canonical;
            emit ChainKeyAdded(chainKey, canonical);
        }
    }

    /// @notice Drop a chain from the directory.
    /// @dev Stops onboarding only: `validateLocation` requires membership, so no hub can
    ///      record a new counterpart there. Its identifier and grade stay, so hubs keep
    ///      bootstrapping to it and accepting its reports; removal must not strand accounts.
    ///      Cutting a chain off is `setProvenance`, which still applies after removal.
    function removeChainKey(bytes32 chainKey) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();

        _chainKeys.remove(chainKey);
        emit ChainKeyRemoved(chainKey);
    }

    /// @notice Register a message provider by name; the key is keccak256 of the name.
    function addMessageProvider(string calldata name) external onlyOwner returns (bytes32 messageProvider) {
        if (bytes(name).length == 0) revert EmptyName();
        messageProvider = keccak256(bytes(name));
        if (_messageProviders.add(messageProvider)) {
            _messageProviderName[messageProvider] = name;
            emit MessageProviderAdded(messageProvider, name);
        }
    }

    function removeMessageProvider(bytes32 messageProvider) external onlyOwner {
        if (!_messageProviders.remove(messageProvider)) revert UnknownMessageProvider();
        delete _messageProviderName[messageProvider];
        emit MessageProviderRemoved(messageProvider);
    }

    /* ============================== configuration ============================== */

    /// @notice Record the local hub transceiver that serves one message provider. Zero
    ///         retires the provider's entry.
    function setLocalTransceiver(bytes32 messageProvider, address transceiver_) external onlyOwner {
        if (!_messageProviders.contains(messageProvider)) revert UnknownMessageProvider();

        address prev = localTransceiver[messageProvider];
        if (prev != address(0)) delete providerOfTransceiver[prev];

        localTransceiver[messageProvider] = transceiver_;
        if (transceiver_ != address(0)) providerOfTransceiver[transceiver_] = messageProvider;

        emit LocalTransceiverSet(messageProvider, transceiver_);
    }

    /// @notice Record the CREATE2 inputs a provider's contracts deploy from.
    ///
    /// @dev Write-once: changing it moves the provider's transceiver on every chain and every
    ///      account under it. The identical record again is a no-op.
    ///
    /// @dev Deploys nothing; it lets the hub reproduce the addresses. A record that does not
    ///      match the deployment yields predictions that match nothing.
    function setProviderDeployment(
        bytes32 messageProvider,
        bytes32 salt,
        bytes32 transceiverInitCodeHash,
        bytes32 accountInitCodeHash
    ) external onlyOwner {
        if (!_messageProviders.contains(messageProvider)) {
            revert UnknownMessageProvider();
        }
        if (salt == bytes32(0)) revert ZeroSalt();
        if (transceiverInitCodeHash == bytes32(0) || accountInitCodeHash == bytes32(0)) {
            revert ZeroInitCodeHash();
        }

        ProviderDeployment storage d = _deployment[messageProvider];
        if (d.salt != bytes32(0)) {
            if (
                d.salt != salt || d.transceiverInitCodeHash != transceiverInitCodeHash
                    || d.accountInitCodeHash != accountInitCodeHash
            ) revert AlreadySet();
            return;
        }

        _deployment[messageProvider] = ProviderDeployment({
            salt: salt, transceiverInitCodeHash: transceiverInitCodeHash, accountInitCodeHash: accountInitCodeHash
        });
        emit ProviderDeploymentSet(messageProvider, salt, transceiverInitCodeHash, accountInitCodeHash);
    }

    /// @notice The CREATE2 factory to derive against on one chain.
    /// @dev Defaults to Arachnid's. For chains that run their own factory; a chain whose
    ///      CREATE2 formula differs (zkSync, Tron) is excluded by its provenance instead.
    function setCreate2Factory(bytes32 chainKey, address factory) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        _create2Factory[chainKey] = factory;
        emit Create2FactorySet(chainKey, factory);
    }

    function providerDeployment(bytes32 messageProvider) external view returns (ProviderDeployment memory) {
        return _deployment[messageProvider];
    }

    function create2Factory(bytes32 chainKey) public view returns (address) {
        address f = _create2Factory[chainKey];
        return f == address(0) ? ARACHNID_FACTORY : f;
    }

    /* ========================= PATH 2: salted derivation ======================= */

    /// @notice Where a provider's transceiver lands on `chainKey`, recomputed from the
    ///         recorded factory, salt, and initcode hash.
    function predictTransceiver(bytes32 chainKey, bytes32 messageProvider) public view returns (address) {
        ProviderDeployment memory d = _deployment[messageProvider];
        if (d.salt == bytes32(0)) revert NoProviderDeployment();
        _requireEvmDerivable(chainKey);
        return AddressDerive.create2(create2Factory(chainKey), d.salt, d.transceiverInitCodeHash);
    }

    /// @notice Where an owner's account lands on `chainKey`, before it exists: the
    ///         transceiver from the provider's salt, then the account from the transceiver.
    /// @dev The account salt must match `TransceiverBase.accountSalt`; it is written out
    ///      rather than imported, and `test/SaltedDeployment.t.sol` asserts the two agree.
    function predictCrossAccount(bytes32 chainKey, bytes32 messageProvider, address owner, bytes32 salt)
        external
        view
        returns (address)
    {
        ProviderDeployment memory d = _deployment[messageProvider];
        if (d.salt == bytes32(0)) revert NoProviderDeployment();

        address transceiver = predictTransceiver(chainKey, messageProvider);
        return AddressDerive.create2(transceiver, keccak256(abi.encode(owner, salt)), d.accountInitCodeHash);
    }

    /// @dev Plain CREATE2 derivation holds only on a chain graded `Derived`.
    function _requireEvmDerivable(bytes32 chainKey) private view {
        if (!_isEvmDerivable(chainKey)) revert NoCounterpart();
    }

    function _isEvmDerivable(bytes32 chainKey) private view returns (bool) {
        return uint8(provenanceFor(chainKey)) >= uint8(Provenance.Derived);
    }

    /// @notice What an address claim about `chainKey` is worth, with the default applied.
    /// @dev An undeclared `eip155` chain reads as `Derived`, right for every EVM chain but
    ///      zkSync and Tron, which are declared. An undeclared chain of any other type reads as
    ///      `Unresolved`, the lowest grade. Answers for a removed chain; reverts only for one
    ///      never registered.
    function provenanceFor(bytes32 chainKey) public view returns (Provenance) {
        Provenance declared = provenanceOf[chainKey];
        if (declared != Provenance.Unresolved) return declared;

        bytes memory identifier = _chainIdentifier[chainKey];
        if (identifier.length == 0) revert UnknownChainKey();
        return
            Erc7930.parseStrict(identifier).chainType == Erc7930.CT_EIP155 ? Provenance.Derived : Provenance.Unresolved;
    }

    /// @notice Whether accounts on `chainKey` must report their own address home.
    /// @dev True exactly where this contract cannot recompute addresses, so it cannot
    ///      disagree with the grades. Where a receiver landed is held by its transmitter, not
    ///      here. The hub's side of `SpokeTransceiverBase.addressesDiverge`.
    function requiresReceiverCallback(bytes32 chainKey) external view returns (bool) {
        return !_isEvmDerivable(chainKey);
    }

    /// @notice Check a location against everything this chain says about its addresses: the
    ///         ERC-7930 canonicity rules, that it is on `chainKey`, and the chain's validator.
    /// @dev A hub calls this before recording a counterpart, so one validator per chain serves
    ///      every provider.
    function validateLocation(bytes32 chainKey, bytes calldata interop) external view {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        // `parseStrict` runs inside: rejects bad versions, length mismatches, trailing
        // bytes, and non-minimal eip155 chain references.
        if (Erc7930.chainKey(interop) != chainKey) revert UnknownChainKey();

        IRefValidator v = validatorOf[chainKey];
        if (address(v) != address(0)) v.validateRef(interop);
    }

    /// @notice Attach a value-range validator to a chain.
    function setValidator(bytes32 chainKey, IRefValidator validator) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        validatorOf[chainKey] = validator;
        emit ValidatorSet(chainKey, address(validator));
    }

    /* ========================== commitment preview ============================ */

    /// @notice Teach this registry the primitive `chainKey`'s receiver hashes with.
    /// @dev Rebindable: it redirects nothing, so a wrong primitive must be fixable. Zero
    ///      unregisters, and `commitmentFor` then reverts rather than answer wrongly.
    function setCommitmentScheme(bytes32 chainKey, ICommitmentScheme scheme) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        commitmentSchemeOf[chainKey] = scheme;
        emit CommitmentSchemeSet(chainKey, address(scheme));
    }

    /// @notice Preview the commitment `chainKey`'s receiver will require over `elements`.
    /// @dev For `eth_call` by a signer checking a payload; nothing on-chain may enforce with
    ///      it. The fold is `SchemeFold`'s.
    function commitmentFor(bytes32 chainKey, bytes[] calldata elements) external view returns (bytes32) {
        ICommitmentScheme scheme = commitmentSchemeOf[chainKey];
        if (address(scheme) == address(0)) revert NoCommitmentScheme();
        return SchemeFold.hashCalls(scheme, chainKey, elements);
    }

    /// @notice State what an address claim about `chainKey` is worth.
    /// @dev Declare `Attested` for every chain this one cannot recompute, which also turns on
    ///      `requiresReceiverCallback`. Rebindable, unlike routes and counterparts: re-grading
    ///      is how the owner responds to a bridge's standing changing, including cutting off a
    ///      compromised one without a redeploy. Applies to a removed chain too, since hubs
    ///      still grade it: any chain ever registered can be cut off.
    function setProvenance(bytes32 chainKey, Provenance provenance) external onlyOwner {
        if (_chainIdentifier[chainKey].length == 0) revert UnknownChainKey();
        provenanceOf[chainKey] = provenance;
        emit ProvenanceSet(chainKey, provenance);
    }

    /* ================= PATH 1 (uniform): per-chain derivation ================== */

    /// @notice Point a chain at the contract that computes addresses on it.
    function setDeriver(bytes32 chainKey, IVmDeriver deriver) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        deriverOf[chainKey] = deriver;
        emit DeriverSet(chainKey, address(deriver));
    }

    /// @notice Store the derivation inputs for a chain, checked against its deriver now
    ///         rather than at the first resolve.
    /// @param params abi.encode(VmDeriver.Scheme, bytes): shape is the scheme's business.
    function setDeriveParams(bytes32 chainKey, bytes calldata params) external onlyOwner {
        IVmDeriver d = deriverOf[chainKey];
        if (address(d) == address(0)) revert NoDeriver();

        uint16 ct = Erc7930.parseStrict(_chainIdentifier[chainKey]).chainType;
        (uint8 scheme,) = abi.decode(params, (uint8, bytes));
        if (!d.supportsScheme(ct, scheme)) revert SchemeNotSupported();

        _deriveParams[chainKey] = params;
        emit DeriveParamsSet(chainKey, scheme, keccak256(params));
    }

    /// @notice The transceiver envelope expected on `chainKey`, recomputed now, whatever VM
    ///         that chain runs.
    /// @dev A deriver is external code: without the chainKey re-check a wrong one could return
    ///      another chain's envelope for a hub to record as this chain's counterpart.
    function expectedTransceiver(bytes32 chainKey) public view returns (bytes memory interop) {
        IVmDeriver d = deriverOf[chainKey];
        if (address(d) == address(0)) revert NoDeriver();
        bytes memory params = _deriveParams[chainKey];
        if (params.length == 0) revert NoDeriveParams();

        interop = d.deriveAddress(_chainIdentifier[chainKey], params);
        if (Erc7930.chainKey(interop) != chainKey) revert DeriverChainMismatch();
    }

    /// @notice Every destination at once: the expected transceiver on each registered chain.
    /// @dev Unconfigured or underivable chains yield an empty entry rather than reverting.
    function expectedTransceivers() external view returns (bytes32[] memory keys, bytes[] memory interops) {
        keys = _chainKeys.values();
        uint256 n = keys.length;
        interops = new bytes[](n);

        for (uint256 i; i < n; ++i) {
            if (address(deriverOf[keys[i]]) == address(0)) continue;
            if (_deriveParams[keys[i]].length == 0) continue;
            // forge-lint: disable-next-line(calls-loop) a view self-call; failure is caught
            try this.expectedTransceiver(keys[i]) returns (bytes memory io) {
                interops[i] = io;
            } catch {
                // Leave empty: an underivable chain is expected, not exceptional.
            }
        }
    }

    /// @notice The stored derivation inputs for a chain.
    function deriveParams(bytes32 chainKey) external view returns (bytes memory) {
        return _deriveParams[chainKey];
    }

    /* ============================== directory reads ============================ */

    function chainKeyCount() external view returns (uint256) {
        return _chainKeys.length();
    }

    function chainKeyAt(uint256 i) external view returns (bytes32) {
        return _chainKeys.at(i);
    }

    function chainKeys() external view returns (bytes32[] memory) {
        return _chainKeys.values();
    }

    function hasChainKey(bytes32 chainKey) external view returns (bool) {
        return _chainKeys.contains(chainKey);
    }

    /// @notice The canonical ERC-7930 chain identifier a `chainKey` hashes from.
    function chainIdentifier(bytes32 chainKey) external view returns (bytes memory) {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        return _chainIdentifier[chainKey];
    }

    function messageProviderCount() external view returns (uint256) {
        return _messageProviders.length();
    }

    function messageProviderAt(uint256 i) external view returns (bytes32) {
        return _messageProviders.at(i);
    }

    function messageProviders() external view returns (bytes32[] memory) {
        return _messageProviders.values();
    }

    function hasMessageProvider(bytes32 messageProvider) external view returns (bool) {
        return _messageProviders.contains(messageProvider);
    }

    function messageProviderName(bytes32 messageProvider) external view returns (string memory) {
        if (!_messageProviders.contains(messageProvider)) revert UnknownMessageProvider();
        return _messageProviderName[messageProvider];
    }
}
