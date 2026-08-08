// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVmDeriver} from "src/derivation/VmDeriver.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {ForeignRef, IForeignRefReceiver, Provenance} from "src/registry/ForeignRef.sol";
import {Move} from "src/addressing/Move.sol";
import {IRefValidator} from "src/registry/IRefValidator.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The CREATE2 inputs a message provider's contracts deploy from.
///
/// @dev THE SALT IS PER PROVIDER, NOT PER CHAIN, AND THAT IS THE WHOLE POINT. One salt used
///      on every chain is what makes a provider's transceiver land on ONE address
///      everywhere — the same property `defaultCounterpart` relies on, but stated as
///      inputs rather than assumed from a local deployment.
///
/// @dev IT EXISTS TO BE MINED. A transceiver is deployed as a proxy and then frozen, so its
///      address is fixed for the life of the protocol and appears in calldata forever
///      after: in peer tables, in payload targets, in every receiver address derived from
///      it. Zero bytes in calldata cost 4 gas against 16 for non-zero, so a salt ground for
///      leading zeros is a permanent discount on every message that names the address. The
///      salt has to be recorded somewhere for that address to be reproducible on the hub;
///      this is that somewhere.
struct ProviderDeployment {
    /// The mined salt, identical on every chain.
    bytes32 salt;
    /// keccak256 of the transceiver PROXY's initcode — deployer as owner, factory as
    /// placeholder implementation. Not an implementation's: the proxy is what the factory
    /// deploys, and it is byte-identical for a hub and a spoke.
    bytes32 transceiverInitCodeHash;
    /// keccak256 of `CrossProxy`'s initcode — the same constant for a transmitter and a
    /// receiver, which is exactly why one owner has one address everywhere.
    bytes32 accountInitCodeHash;
}

/// @title ChainRegistry
/// @notice The home-chain directory of every chain crossecute talks to, the transceiver
///         that reaches each one, and where that transceiver actually lives.
///
/// @dev Two halves that only make sense together:
///
///      DIRECTORY — an enumerable set of `chainKey`, an enumerable set of
///      `messageProvider`, and `chainKey => messageProvider => transceiverId`. All
///      owner-controlled declarations. This half answers "who do I send through".
///
///      IT HOLDS NO PROVIDER ROUTES. A message provider's own name for a chain — a
///      LayerZero eid, a Hyperlane domain — lives on the TRANSCEIVER, because that is the
///      contract that sends and receives. Keeping it here would put a second shared
///      contract in the path of every send and let a compromised one misroute a payload;
///      on the execute-on-arrival path there is no commitment binding the destination, so
///      a wrong id means the payload runs on the wrong chain.
///
///      RESOLUTION — `transceiverId => ForeignRef`, holding the transceiver's location
///      on its own chain. A location is not a declaration; it is a claim with a trust
///      grade, and the grade is the point:
///        1. `resolveEvmCreate2` / `resolveEvmCreate3` — recomputed here. No message,
///           no latency, no bridge trust. The DEFAULT for EVM destinations.
///        2. `predictTransceiver` — CREATE2 from a recorded salt, for EVM destinations
///           that share Ethereum's formula. Also no message and no bridge trust.
///        3. callback alone — the destination asserted it and nothing here checks.
///
///      Collapsing these into one `address` field is how a bridge-security assumption
///      gets laundered into something that looks like a derivation. Read locations
///      through `requireRef` and state the bar you need.
contract ChainRegistry is OwnableUpgradeable, IForeignRefReceiver {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Arachnid's deterministic deployment proxy, at the same address on every
    ///         standard EVM chain. The default for `create2Factory`.
    address internal constant ARACHNID_FACTORY =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /* ================================= storage ================================= */

    /// Set of keccak256(canonical ERC-7930 chain identifier).
    EnumerableSet.Bytes32Set private _chainKeys;
    /// chainKey => the canonical chain identifier it hashes from, kept so the envelope
    /// is recoverable on-chain rather than only off-chain.
    mapping(bytes32 => bytes) private _chainIdentifier;

    /// Set of keccak256(message provider name).
    EnumerableSet.Bytes32Set private _messageProviders;
    /// messageProvider => the name it hashes from.
    mapping(bytes32 => string) private _messageProviderName;
    /// messageProvider => the CREATE2 inputs its transceiver and receivers deploy from.
    mapping(bytes32 => ProviderDeployment) private _deployment;
    /// chainKey => the CREATE2 factory to derive against. Zero means `ARACHNID_FACTORY`.
    mapping(bytes32 => address) private _create2Factory;

    /// chainKey => messageProvider => transceiver id
    mapping(bytes32 => mapping(bytes32 => bytes32)) public transceiverIdOf;


    /// transceiverId => its location on its own chain, with provenance.
    mapping(bytes32 => ForeignRef) private _refs;

    /// messageProvider => the local hub transceiver that serves it. This is both the
    /// callback authority and the address the default counterpart is derived from.
    ///
    /// @dev PER PROVIDER, NOT ONE ADDRESS. A single `sourceTransceiver` meant a second
    ///      provider's hub could never deliver a report, because only one address could
    ///      hold the authority at a time — the directory was keyed per provider while the
    ///      permission was not.
    mapping(bytes32 => address) public localTransceiver;
    /// The reverse: which provider a calling transceiver speaks for.
    ///
    /// @dev THIS IS WHY THE CALLBACK TAKES NO `messageProvider` ARGUMENT. The caller is
    ///      already authenticated as a specific hub, and a hub serves exactly one
    ///      provider, so the provider is a property of `msg.sender` rather than a claim
    ///      the message gets to make about itself.
    mapping(address => bytes32) public providerOfTransceiver;

    /// transceiverId => abi-encoded Move.MoveQualifier. The destination executor
    /// needs the module and function names verbatim; a 32-byte commitment cannot be
    /// reversed into `transceiver::receive_message`.
    mapping(bytes32 => bytes) private _qualifiers;

    /// chainKey => the contract that knows how to compute an address on that chain.
    /// This is what makes resolution uniform: one mapping turns "which destination" into
    /// "which formula", so callers never branch on VM.
    mapping(bytes32 => IVmDeriver) public deriverOf;
    /// chainKey => the abi-encoded `(Scheme, bytes)` blob that chain's deriver expects.
    /// Stored rather than passed so `expectedTransceiver` can be a no-argument read.
    mapping(bytes32 => bytes) private _deriveParams;

    /// chainKey => optional value-range validator (structure is handled by Erc7930;
    /// this catches constraints the envelope cannot express, e.g. Starknet felts).
    mapping(bytes32 => IRefValidator) public validatorOf;
    /// chainKey => strongest provenance this chain can honestly reach.
    /// Unset (Unresolved) means no cap. Starknet must be capped at Committed, because
    /// its address derivation is Pedersen and cannot be recomputed on the EVM at all.
    mapping(bytes32 => Provenance) public maxProvenanceOf;

    /* ================================== events ================================= */

    event ChainKeyAdded(bytes32 indexed chainKey, bytes chainIdentifier);
    event ChainKeyRemoved(bytes32 indexed chainKey);
    event MessageProviderAdded(bytes32 indexed messageProvider, string name);
    event MessageProviderRemoved(bytes32 indexed messageProvider);
    event TransceiverIdSet(
        bytes32 indexed chainKey, bytes32 indexed messageProvider, bytes32 transceiverId
    );
    event LocalTransceiverSet(bytes32 indexed messageProvider, address transceiver);
    event ProviderDeploymentSet(
        bytes32 indexed messageProvider,
        bytes32 salt,
        bytes32 transceiverInitCodeHash,
        bytes32 accountInitCodeHash
    );
    event Create2FactorySet(bytes32 indexed chainKey, address factory);
    event QualifierSet(bytes32 indexed transceiverId, bytes32 qualifierHash);
    event DeriverSet(bytes32 indexed chainKey, address deriver);
    event DeriveParamsSet(bytes32 indexed chainKey, uint8 scheme, bytes32 paramsHash);
    event ValidatorSet(bytes32 indexed chainKey, address validator);
    event MaxProvenanceSet(bytes32 indexed chainKey, Provenance maxProvenance);
    event RefResolved(
        bytes32 indexed slot,
        bytes32 indexed chainKey,
        bytes32 id,
        Provenance provenance,
        bytes interop
    );

    /* ================================== errors ================================= */

    error NotTransceiver();
    /// @dev A reported slot may be written exactly once. A second report for the same
    ///      `(chainKey, transmitter)` is either a replay or a repoint, and neither is
    ///      something a destination gets to do on its own say-so.
    error AlreadyResolved();
    /// @dev A route, once declared, is fixed. Re-pointing it is a redeploy.
    error AlreadySet();
    error NoLocalTransceiver();
    error NoCounterpart();
    /// @dev No salt recorded for this provider, so nothing here can say where its
    ///      transceiver lands.
    error NoProviderDeployment();
    error ZeroSalt();
    error ZeroInitCodeHash();
    error ProvenanceDowngrade();
    error NotResolved();
    error InsufficientProvenance();
    error ProvenanceExceedsChainCap();
    error UnknownChainKey();
    error UnknownMessageProvider();
    error ChainKeyInUse();
    error ZeroTransceiverId();
    error EmptyName();
    error QualifierMismatch();
    error NoQualifier();
    error NoDeriver();
    error NoDeriveParams();
    error DeriverChainMismatch();
    error ParamsCommitmentMismatch();
    error SchemeNotSupported();
    error NoRoute();

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
    /// @dev Takes the envelope rather than a bare hash so the key cannot be a value
    ///      nobody can reproduce, and so `parseStrict` rejects a non-canonical framing
    ///      before it becomes a permanent mapping key.
    /// @param identifier ERC-7930 bytes. An account envelope is accepted and reduced to
    ///                   its chain identifier form.
    function addChainKey(bytes calldata identifier)
        external
        onlyOwner
        returns (bytes32 chainKey)
    {
        bytes memory canonical = Erc7930.toChainIdentifier(identifier);
        chainKey = keccak256(canonical);
        if (_chainKeys.add(chainKey)) {
            _chainIdentifier[chainKey] = canonical;
            emit ChainKeyAdded(chainKey, canonical);
        }
    }

    /// @notice Drop a chain. Refuses while any transceiver location still sits under it,
    ///         so a live route cannot be orphaned by a directory edit.
    function removeChainKey(bytes32 chainKey) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();

        uint256 n = _messageProviders.length();
        for (uint256 i; i < n; ++i) {
            bytes32 mp = _messageProviders.at(i);
            if (transceiverIdOf[chainKey][mp] != bytes32(0)) revert ChainKeyInUse();
        }

        _chainKeys.remove(chainKey);
        delete _chainIdentifier[chainKey];
        emit ChainKeyRemoved(chainKey);
    }

    /// @notice Register a message provider by name; the key is keccak256 of the name.
    function addMessageProvider(string calldata name)
        external
        onlyOwner
        returns (bytes32 messageProvider)
    {
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

    /// @notice Point (chain, provider) at a transceiver. Owner-only, and WRITE-ONCE.
    ///
    /// @dev SET ONCE, BY THE OWNER, OR NOT AT ALL. A transceiver id names the contract
    ///      that every message to that chain authenticates against, so a mutable pointer
    ///      is a standing ability to redirect the whole route — the same argument that
    ///      made `SpokeTransceiverBase._homeTransceiver` an initializer argument rather
    ///      than a setter plus a lock. Writing it once closes the window instead of
    ///      documenting it: there is no reachable state where the value is set and still
    ///      changeable. Moving a route is a new transceiver id.
    ///
    ///      Re-writing the SAME id is a no-op rather than a revert, so a replayed or
    ///      duplicated configuration transaction is not a failure.
    ///
    /// @dev LEAVING IT UNSET IS A CHOICE, NOT AN OMISSION. An unset route falls back to
    ///      the local transceiver's own address on that chain — see `defaultCounterpart`.
    ///      That is the correct default for every EVM chain sharing Ethereum's CREATE2
    ///      formula, which is most of them, so this setter is for the exceptions.
    function setTransceiverId(bytes32 chainKey, bytes32 messageProvider, bytes32 transceiverId)
        external
        onlyOwner
    {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        if (!_messageProviders.contains(messageProvider)) revert UnknownMessageProvider();
        if (transceiverId == bytes32(0)) revert ZeroTransceiverId();

        bytes32 existing = transceiverIdOf[chainKey][messageProvider];
        if (existing != bytes32(0)) {
            if (existing != transceiverId) revert AlreadySet();
            return;
        }

        transceiverIdOf[chainKey][messageProvider] = transceiverId;
        emit TransceiverIdSet(chainKey, messageProvider, transceiverId);
    }

    /* ============================== configuration ============================== */

    /// @notice Register the local hub transceiver that serves one message provider.
    ///
    /// @dev IT DOES TWO JOBS, AND THEY ARE THE SAME FACT. This address is the only caller
    ///      permitted to deliver a resolution callback for `messageProvider`, and it is
    ///      also the address the default counterpart on every EVM chain is derived from —
    ///      because a transceiver is deployed as a proxy through Nick's factory, so hub
    ///      and spoke share initcode and salt and land on the same address wherever
    ///      Ethereum's CREATE2 formula holds.
    ///
    ///      Pass the zero address to retire a provider's transceiver, which also removes
    ///      the default counterpart it backed.
    function setLocalTransceiver(bytes32 messageProvider, address transceiver_)
        external
        onlyOwner
    {
        if (!_messageProviders.contains(messageProvider)) revert UnknownMessageProvider();

        address prev = localTransceiver[messageProvider];
        if (prev != address(0)) delete providerOfTransceiver[prev];

        localTransceiver[messageProvider] = transceiver_;
        if (transceiver_ != address(0)) providerOfTransceiver[transceiver_] = messageProvider;

        emit LocalTransceiverSet(messageProvider, transceiver_);
    }

    /// @notice Record the CREATE2 inputs a provider's contracts deploy from.
    ///
    /// @dev WRITE-ONCE, because changing it moves every address derived from it — the
    ///      transceiver on every chain, and every receiver under every one of those. That
    ///      is a redeploy of the provider's entire footprint, not a config edit. Re-writing
    ///      the identical record is a no-op, so a replayed configuration transaction is not
    ///      a failure.
    ///
    /// @dev IT DOES NOT DEPLOY ANYTHING. The salt is mined and used off-chain by whoever
    ///      calls the factory; this records it so the hub can reproduce the resulting
    ///      addresses. A record that does not match what was actually deployed yields
    ///      predictions that match nothing, which surfaces the first time a counterpart is
    ///      read rather than silently.
    function setProviderDeployment(
        bytes32 messageProvider,
        bytes32 salt,
        bytes32 transceiverInitCodeHash,
        bytes32 accountInitCodeHash
    ) external onlyOwner {
        if (!_messageProviders.contains(messageProvider)) revert UnknownMessageProvider();
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
            salt: salt,
            transceiverInitCodeHash: transceiverInitCodeHash,
            accountInitCodeHash: accountInitCodeHash
        });
        emit ProviderDeploymentSet(
            messageProvider, salt, transceiverInitCodeHash, accountInitCodeHash
        );
    }

    /// @notice The CREATE2 factory to derive against on one chain.
    /// @dev Defaults to Arachnid's, which sits at the same address on every standard EVM
    ///      chain. zk-chains run their own, which is the case this setter exists for —
    ///      though note that a chain whose CREATE2 FORMULA also differs (zkSync, Tron)
    ///      needs more than a different factory address, and is excluded from derivation
    ///      by its provenance cap instead.
    function setCreate2Factory(bytes32 chainKey, address factory) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        _create2Factory[chainKey] = factory;
        emit Create2FactorySet(chainKey, factory);
    }

    function providerDeployment(bytes32 messageProvider)
        external
        view
        returns (ProviderDeployment memory)
    {
        return _deployment[messageProvider];
    }

    function create2Factory(bytes32 chainKey) public view returns (address) {
        address f = _create2Factory[chainKey];
        return f == address(0) ? ARACHNID_FACTORY : f;
    }

    /* ========================= PATH 2: salted derivation ======================= */

    /// @notice Where a provider's transceiver lands on `chainKey`.
    ///
    /// @dev RECOMPUTED FROM THE RECORDED INPUTS, so the answer is `Derived` in the strong
    ///      sense: the factory, salt, and initcode hash are all in the signed calldata of
    ///      the transaction that recorded them, and this is arithmetic over them. It does
    ///      not read a local address and assume the remote one matches.
    function predictTransceiver(bytes32 chainKey, bytes32 messageProvider)
        public
        view
        returns (address)
    {
        ProviderDeployment memory d = _deployment[messageProvider];
        if (d.salt == bytes32(0)) revert NoProviderDeployment();
        _requireEvmDerivable(chainKey);
        return AddressDerive.create2(
            create2Factory(chainKey), d.salt, d.transceiverInitCodeHash
        );
    }

    /// @notice Where an owner's account lands on `chainKey`, before it exists.
    ///
    /// @dev TWO CREATE2 STEPS, AND BOTH INPUTS ARE KNOWN. The transceiver is derived from
    ///      the provider's salt; the account is derived from the transceiver, with the
    ///      `(owner, salt)` pair as its salt. So an account address is computable on
    ///      here for any owner on any parity chain before a single message has crossed —
    ///      and it is the same address their transmitter occupies here, because both deploy the
    ///      same argument-free proxy from the same address at the same salt.
    ///
    ///      The salt must match `TransceiverBase.accountSalt`, which is
    ///      `keccak256(abi.encode(owner, salt))`. It is written out here rather than imported
    ///      because this contract is on the home chain and that one is on the destination;
    ///      `test/SaltedDeployment.t.sol` asserts the two agree.
    function predictCrossAccount(
        bytes32 chainKey,
        bytes32 messageProvider,
        address owner,
        bytes32 salt
    ) external view returns (address) {
        ProviderDeployment memory d = _deployment[messageProvider];
        if (d.salt == bytes32(0)) revert NoProviderDeployment();

        address transceiver = predictTransceiver(chainKey, messageProvider);
        return AddressDerive.create2(
            transceiver, keccak256(abi.encode(owner, salt)), d.accountInitCodeHash
        );
    }

    /// @dev The two conditions under which a plain CREATE2 derivation is honest here:
    ///      the chain is `eip155`, and nothing has declared its addresses unrecomputable.
    ///      zkSync and Tron are `eip155` with different formulas, and their provenance cap
    ///      is what excludes them.
    function _requireEvmDerivable(bytes32 chainKey) private view {
        bytes memory identifier = _chainIdentifier[chainKey];
        if (identifier.length == 0) revert UnknownChainKey();
        if (Erc7930.parseStrict(identifier).chainType != Erc7930.CT_EIP155) {
            revert NoCounterpart();
        }
        Provenance cap = maxProvenanceOf[chainKey];
        if (cap != Provenance.Unresolved && uint8(cap) < uint8(Provenance.Derived)) {
            revert NoCounterpart();
        }
    }

    /// @notice Attach a value-range validator to a chain.
    function setValidator(bytes32 chainKey, IRefValidator validator) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        validatorOf[chainKey] = validator;
        emit ValidatorSet(chainKey, address(validator));
    }

    /// @notice Cap the strongest provenance a chain may be recorded at.
    /// @dev This closes the laundering hole in `resolveDerived`: without a cap, an owner
    ///      could compute a Starknet address off-chain, pass the bytes in, and have it
    ///      stored as `Derived` — a claim that nothing on this chain can support. Set
    ///      Starknet (and Aptos, Cardano, TON, NEAR named accounts) to `Committed` so
    ///      the stronger claim is unrepresentable rather than merely discouraged.
    function setMaxProvenance(bytes32 chainKey, Provenance cap) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        maxProvenanceOf[chainKey] = cap;
        emit MaxProvenanceSet(chainKey, cap);
    }

    /* ====================== PATH 1: local EVM resolution ======================= */

    /// @notice Default path. Derive an EVM CREATE2 address locally and store it.
    /// @dev No message is sent. Because the derivation inputs sit in this transaction's
    ///      calldata, the signers who approved the transaction approved the inputs —
    ///      which is exactly the property the callback paths lack.
    function resolveEvmCreate2(
        bytes32 slot,
        uint256 chainId,
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) external onlyOwner returns (address predicted) {
        predicted = AddressDerive.create2(deployer, salt, initCodeHash);
        _store(slot, Erc7930.encodeEvm(chainId, predicted), Provenance.Derived);
    }

    /// @notice CREATE3 variant: address depends only on (factory, salt), so the same
    ///         salt lands identically on every chain sharing Ethereum's derivation.
    /// @dev Does NOT hold for zkSync or Tron — resolve those with their own formulas
    ///      or through the callback paths.
    function resolveEvmCreate3(bytes32 slot, uint256 chainId, address factory, bytes32 salt)
        external
        onlyOwner
        returns (address predicted)
    {
        predicted = AddressDerive.create3(factory, salt);
        _store(slot, Erc7930.encodeEvm(chainId, predicted), Provenance.Derived);
    }

    /// @notice Escape hatch for non-EVM values computed off this contract but still
    ///         inside this transaction (a Cosmos or Solana derivation performed by a
    ///         caller library, or a Sui address, which is `view` and cannot be `pure`).
    /// @dev Still `Derived`: the caller is the owner and the bytes are transaction
    ///      calldata. `maxProvenanceOf` is what keeps that honest per chain.
    function resolveDerived(bytes32 slot, bytes calldata interop) external onlyOwner {
        _store(slot, interop, Provenance.Derived);
    }

    /* ================= PATH 1 (uniform): per-chain derivation ================== */

    /// @notice Point a chain at the contract that knows how to compute addresses on it.
    /// @dev One mapping is what makes resolution uniform. Callers ask for "the
    ///      transceiver on chain X" and never branch on VM; the branch lives once, in
    ///      the deriver's (ChainType, Scheme) dispatch.
    function setDeriver(bytes32 chainKey, IVmDeriver deriver) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        deriverOf[chainKey] = deriver;
        emit DeriverSet(chainKey, address(deriver));
    }

    /// @notice Store the derivation inputs for a chain.
    /// @dev Held in storage rather than passed per call so `expectedTransceiver` can be
    ///      a no-argument read — the whole point of normalizing. Validated against the
    ///      deriver at wiring time so a scheme/chain mismatch surfaces here rather than
    ///      at the first resolve.
    /// @param params abi.encode(VmDeriver.Scheme, bytes) — shape is the scheme's business.
    function setDeriveParams(bytes32 chainKey, bytes calldata params) external onlyOwner {
        IVmDeriver d = deriverOf[chainKey];
        if (address(d) == address(0)) revert NoDeriver();

        uint16 ct = Erc7930.parseStrict(_chainIdentifier[chainKey]).chainType;
        (uint8 scheme,) = abi.decode(params, (uint8, bytes));
        if (!d.supportsScheme(ct, scheme)) revert SchemeNotSupported();

        _deriveParams[chainKey] = params;
        emit DeriveParamsSet(chainKey, scheme, keccak256(params));
    }

    /// @notice THE UNIFORM READ. The transceiver envelope expected on `chainKey`,
    ///         recomputed from scratch right now, whatever VM that chain runs.
    /// @dev The chainKey re-check is load-bearing: a deriver is external code, and
    ///      without it a wrong or hostile one could return an envelope for a DIFFERENT
    ///      registered chain and have `_store` accept it into this chain's route.
    function expectedTransceiver(bytes32 chainKey)
        public
        view
        returns (bytes memory interop)
    {
        IVmDeriver d = deriverOf[chainKey];
        if (address(d) == address(0)) revert NoDeriver();
        bytes memory params = _deriveParams[chainKey];
        if (params.length == 0) revert NoDeriveParams();

        interop = d.deriveAddress(_chainIdentifier[chainKey], params);
        if (Erc7930.chainKey(interop) != chainKey) revert DeriverChainMismatch();
    }

    /// @notice Every destination at once: the expected transceiver on each registered
    ///         chain for one message provider.
    /// @dev Chains with no deriver, no params, or no route yield empty `interops[i]`
    ///      rather than reverting — one unconfigured chain must not blind the view of
    ///      all the others.
    function expectedTransceivers(bytes32 messageProvider)
        external
        view
        returns (bytes32[] memory keys, bytes32[] memory transceiverIds, bytes[] memory interops)
    {
        keys = _chainKeys.values();
        uint256 n = keys.length;
        transceiverIds = new bytes32[](n);
        interops = new bytes[](n);

        for (uint256 i; i < n; ++i) {
            transceiverIds[i] = transceiverIdOf[keys[i]][messageProvider];
            if (address(deriverOf[keys[i]]) == address(0)) continue;
            if (_deriveParams[keys[i]].length == 0) continue;
            try this.expectedTransceiver(keys[i]) returns (bytes memory io) {
                interops[i] = io;
            } catch {
                // Leave empty: an underivable chain is expected, not exceptional.
            }
        }
    }

    /// @notice Derive and commit the transceiver location for one route.
    /// @dev `paramsCommitment` is not ceremony. `_deriveParams` was written in an EARLIER
    ///      transaction, so without it the signers approving THIS transaction would be
    ///      approving a pointer, not the inputs — and `Derived` specifically claims the
    ///      inputs were approved. Passing the hash puts the exact bytes in the signed
    ///      calldata and keeps the grade honest.
    function resolveTransceiver(
        bytes32 chainKey,
        bytes32 messageProvider,
        bytes32 paramsCommitment
    ) external onlyOwner returns (bytes32 transceiverId, bytes memory interop) {
        transceiverId = transceiverIdOf[chainKey][messageProvider];
        if (transceiverId == bytes32(0)) revert NoRoute();

        bytes memory params = _deriveParams[chainKey];
        if (params.length == 0) revert NoDeriveParams();
        if (keccak256(params) != paramsCommitment) revert ParamsCommitmentMismatch();

        interop = expectedTransceiver(chainKey);
        _store(transceiverId, interop, Provenance.Derived);
    }

    /// @notice The stored derivation inputs for a chain. Hash this to build the
    ///         `paramsCommitment` a `resolveTransceiver` payload must carry.
    function deriveParams(bytes32 chainKey) external view returns (bytes memory) {
        return _deriveParams[chainKey];
    }

    /* ========================= destination receivers ========================== */

    /// @notice Slot holding an account's receiver on one destination chain.
    /// @dev DERIVED, never chosen. Two slot kinds now share `_refs` — transceivers and
    ///      receivers — so each is namespaced by a distinct tag. Without the tag a
    ///      receiver could be written into a transceiver's slot and read back as one.
    ///
    ///      This exists because some chains cannot be derived at all. On Starknet the
    ///      address is a Pedersen hash chain that the EVM cannot recompute at any price,
    ///      so the receiver's address is not predictable here — it is reported back by
    ///      the destination and graded `Attested`, which is an honest description of
    ///      what we actually know.
    /// @dev KEYED BY `(owner, salt)`, WHICH IS WHAT AN ACCOUNT IS. Keying by the
    ///      transmitter's address happens to give the same answer today, since an account
    ///      and its receivers share one address — but it states a relationship that no
    ///      longer holds, and if the two ever diverged the slot would silently point
    ///      somewhere else. The pair is the identity; the address is a derivation of it.
    function receiverSlot(bytes32 chainKey, address owner, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("crossecute.receiver", chainKey, owner, salt));
    }

    /// @notice Where an account's receiver lives on `chainKey`, refusing anything below
    ///         `minProvenance`.
    /// @dev A payload that moves funds should demand more than `Attested`; one that only
    ///      emits an event can live with it. Making the caller state its bar is the point.
    function destinationReceiverOf(
        bytes32 chainKey,
        address owner,
        bytes32 salt,
        Provenance minProvenance
    ) external view returns (bytes memory) {
        ForeignRef memory r = _refs[receiverSlot(chainKey, owner, salt)];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
        if (uint8(r.provenance) < uint8(minProvenance)) revert InsufficientProvenance();
        return Erc7930.parseStrict(r.interop).addr;
    }

    /* =============== PATH 2/3: destination callback with grading =============== */

    /// @notice Invoked by a local hub transceiver on the return message: the destination
    ///         reports where it created something this chain could not compute.
    ///
    /// @dev THE CALLER IS THE AUTHORITY, AND IT NAMES THE PROVIDER. `msg.sender` must be a
    ///      registered `localTransceiver`, and the provider is read back from it rather
    ///      than passed in — a hub serves exactly one provider, so accepting it as an
    ///      argument would let an authenticated caller speak for a provider it does not
    ///      serve.
    ///
    /// @dev THE SLOT IS WRITE-ONCE, AND THAT IS WHAT REPLACED THE EXPECTATION MACHINERY.
    ///      A receiver's address on a given chain is a fact established once, at
    ///      bootstrap; there is no legitimate second report for the same
    ///      `(chainKey, transmitter)`. Refusing one makes a replayed message a no-op and
    ///      makes a compromised bridge unable to repoint a live receiver — which is
    ///      strictly more than the `Committed` grade bought, since that only ever
    ///      confirmed an address the owner had already computed off-chain.
    ///
    /// @dev Grading still happens HERE, not at the caller — a remote party does not get to
    ///      mark its own homework, so no provenance field is accepted over the wire. With
    ///      nothing registered in advance the honest grade is `Attested`: worth exactly
    ///      the security of the bridge that carried it. A reader wanting better than that
    ///      must use a locally derived path.
    ///
    ///      The qualifier arrives WITH the address rather than being read from storage,
    ///      because a Move call target is `address::module::function` and the address
    ///      alone does not identify it.
    function onForeignRefResolved(
        bytes32 slot,
        bytes calldata interop,
        bytes calldata qualifierData
    ) external override {
        bytes32 messageProvider = providerOfTransceiver[msg.sender];
        if (messageProvider == bytes32(0)) revert NotTransceiver();
        if (_refs[slot].provenance != Provenance.Unresolved) revert AlreadyResolved();

        _store(slot, interop, Provenance.Attested);

        // What the destination actually reported, validated against its chain.
        if (qualifierData.length != 0) {
            Move.MoveQualifier memory q = abi.decode(qualifierData, (Move.MoveQualifier));
            Move.validate(q, Erc7930.parseStrict(interop).chainType);
            bytes32 reported = Move.hash(q);

            _refs[slot].qualifierHash = reported;
            _qualifiers[slot] = qualifierData;
            emit QualifierSet(slot, reported);
        }
    }

    /* ================================ Move refs ================================ */

    /// @notice Attach a qualified name to an already-resolved Move transceiver.
    /// @dev A qualifier is a DECLARATION about a deployment convention, not a derived
    ///      value — there is nothing on this chain that could recompute
    ///      `transceiver::receive_message` from an address. It therefore carries no
    ///      provenance of its own and inherits the trust grade of the ref it attaches to.
    function setQualifier(bytes32 transceiverId, Move.MoveQualifier calldata q)
        external
        onlyOwner
    {
        ForeignRef storage r = _refs[transceiverId];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
        uint16 ct = Erc7930.parseStrict(r.interop).chainType;
        Move.validate(q, ct);

        bytes32 qh = Move.hash(q);
        if (r.qualifierHash != bytes32(0) && r.qualifierHash != qh) {
            // Repointing a live call target is a distinct, louder operation than
            // setting one for the first time; force a new transceiver id instead.
            revert QualifierMismatch();
        }
        r.qualifierHash = qh;
        _qualifiers[transceiverId] = abi.encode(q);
        emit QualifierSet(transceiverId, qh);
    }

    /// @notice The qualified name a destination executor needs to build the call.
    function qualifier(bytes32 transceiverId)
        external
        view
        returns (Move.MoveQualifier memory q)
    {
        bytes memory raw = _qualifiers[transceiverId];
        if (raw.length == 0) revert NoQualifier();
        q = abi.decode(raw, (Move.MoveQualifier));
    }

    /// @notice True when this slot's chain type is locally assigned and will need
    ///         re-keying if CASA publishes a different CAIP-350 profile.
    function isProvisional(bytes32 slot) external view returns (bool) {
        ForeignRef memory r = _refs[slot];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
        return Move.isProvisional(Erc7930.parseStrict(r.interop).chainType);
    }

    /* ================================= storage ================================= */

    function _store(bytes32 slot, bytes memory interop, Provenance grade) private {
        if (slot == bytes32(0)) revert ZeroTransceiverId();

        // parseStrict runs inside id()/chainKey(): rejects bad versions, length
        // mismatches, trailing bytes, and non-minimal eip155 chain references.
        bytes32 canonicalId = Erc7930.id(interop);
        bytes32 ck = Erc7930.chainKey(interop);

        // A location on a chain nobody registered is a route to nowhere.
        if (!_chainKeys.contains(ck)) revert UnknownChainKey();

        // Value-range constraints the envelope cannot express.
        IRefValidator v = validatorOf[ck];
        if (address(v) != address(0)) v.validateRef(interop);

        // A chain may not be recorded at a strength it cannot actually reach.
        Provenance cap = maxProvenanceOf[ck];
        if (cap != Provenance.Unresolved && uint8(grade) > uint8(cap)) {
            revert ProvenanceExceedsChainCap();
        }

        ForeignRef storage prev = _refs[slot];
        if (prev.provenance != Provenance.Unresolved) {
            if (uint8(grade) < uint8(prev.provenance)) revert ProvenanceDowngrade();
        }

        // A re-resolution keeps any qualifier already attached: the module and function
        // names are a deployment convention that outlives an address change.
        bytes32 keptQualifier = prev.qualifierHash;
        bytes memory canonicalBytes = Erc7930.parseStrictAndReencode(interop);
        _refs[slot] = ForeignRef({
            id: canonicalId,
            chainKey: ck,
            provenance: grade,
            qualifierHash: keptQualifier,
            interop: canonicalBytes
        });

        emit RefResolved(slot, ck, canonicalId, grade, canonicalBytes);
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

    function messageProviderName(bytes32 messageProvider)
        external
        view
        returns (string memory)
    {
        if (!_messageProviders.contains(messageProvider)) revert UnknownMessageProvider();
        return _messageProviderName[messageProvider];
    }

    /* ============================= resolution reads ============================ */

    function get(bytes32 slot) external view returns (ForeignRef memory r) {
        r = _refs[slot];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
    }

    /// @notice Read, refusing anything below `minProvenance`.
    /// @dev Use this at the point of execution and make the caller state its bar.
    ///      A payload that moves funds should demand `Committed` or `Derived`; one that
    ///      only emits an event can tolerate `Attested`.
    function requireRef(bytes32 slot, Provenance minProvenance)
        external
        view
        returns (ForeignRef memory r)
    {
        r = _refs[slot];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
        if (uint8(r.provenance) < uint8(minProvenance)) revert InsufficientProvenance();
    }

    /// @notice The transceiver's raw address bytes on its own chain — what a destination
    ///         executor needs, since a 32-byte key cannot be turned back into
    ///         `alice.near` or a Move type tag.
    function transceiverLocation(bytes32 transceiverId, Provenance minProvenance)
        external
        view
        returns (bytes memory)
    {
        ForeignRef memory r = _refs[transceiverId];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
        if (uint8(r.provenance) < uint8(minProvenance)) revert InsufficientProvenance();
        return Erc7930.parseStrict(r.interop).addr;
    }

    /// @notice The counterpart a chain gets when the owner has declared nothing.
    ///
    /// @dev TWO WAYS TO KNOW, AND THE STRONGER ONE WINS. If the provider has a recorded
    ///      `ProviderDeployment`, the answer is CREATE2 over the factory, salt, and
    ///      initcode hash — arithmetic over inputs that sit in the signed calldata of the
    ///      transaction that recorded them. Otherwise it falls back to the local
    ///      transceiver's own address, which is the same answer reached by assumption
    ///      rather than by statement: a transceiver is deployed as a PROXY through the
    ///      factory, so hub and spoke share initcode and salt and land together wherever
    ///      Ethereum's CREATE2 formula holds.
    ///
    ///      Both are `Derived`. The recorded path is preferable because it says WHY, and
    ///      because it does not require the hub to exist before a destination can be
    ///      addressed.
    ///
    /// @dev IT IS REFUSED EXACTLY WHERE IT WOULD BE A LIE. Two guards, and each maps to a
    ///      real failure of the parity argument:
    ///
    ///      1. NON-EVM CHAINS. A 20-byte EVM address means nothing on Solana, Sui, or
    ///         Starknet, so anything that is not `eip155` has no default at all.
    ///      2. CHAINS CAPPED BELOW `Derived`. zkSync and Tron are `eip155` with different
    ///         CREATE2 formulas, so parity does NOT hold there even though the chain type
    ///         says it might. `setMaxProvenance` is already the dial that records "this
    ///         chain's addresses cannot be recomputed here", so a cap below `Derived` is
    ///         read as exactly that and the default withdraws. This reuses the existing
    ///         honesty mechanism rather than adding a second flag that could disagree
    ///         with it.
    ///
    ///      Both are opt-out by `setTransceiverId`: a chain with an explicit route never
    ///      consults this.
    function defaultCounterpart(bytes32 chainKey, bytes32 messageProvider)
        public
        view
        returns (bytes memory location)
    {
        if (_deployment[messageProvider].salt != bytes32(0)) {
            return abi.encodePacked(predictTransceiver(chainKey, messageProvider));
        }

        address local = localTransceiver[messageProvider];
        if (local == address(0)) revert NoLocalTransceiver();
        _requireEvmDerivable(chainKey);
        return abi.encodePacked(local);
    }

    /// @notice Route lookup and location read in one call: the whole reason the
    ///         directory and the resolution table live in the same contract.
    ///
    /// @dev AN UNSET ROUTE FALLS BACK TO `defaultCounterpart` RATHER THAN REVERTING. The
    ///      common case — an EVM destination where hub and spoke share an address — needs
    ///      no configuration at all, so requiring it produced a table whose every row said
    ///      the same thing and whose absence was indistinguishable from a real gap.
    ///      The default is graded `Derived`, which is honest: it is recomputed here from
    ///      the local address, with no message and no bridge trust. `defaultCounterpart`
    ///      is where that grade is justified and where it withdraws.
    /// @return transceiverId Zero when the answer came from the default, since no
    ///         `ForeignRef` backs it — a caller that needs a stored ref should check.
    function transceiverFor(
        bytes32 chainKey,
        bytes32 messageProvider,
        Provenance minProvenance
    ) external view returns (bytes32 transceiverId, bytes memory location) {
        transceiverId = transceiverIdOf[chainKey][messageProvider];
        if (transceiverId == bytes32(0)) {
            return (bytes32(0), defaultCounterpart(chainKey, messageProvider));
        }

        ForeignRef memory r = _refs[transceiverId];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
        if (uint8(r.provenance) < uint8(minProvenance)) revert InsufficientProvenance();
        location = Erc7930.parseStrict(r.interop).addr;
    }

    /// @notice Convenience for the common EVM case. Reverts if the slot is not an
    ///         eip155 account with a 20-byte address.
    function evmAddress(bytes32 slot) external view returns (address) {
        ForeignRef memory r = _refs[slot];
        if (r.provenance == Provenance.Unresolved) revert NotResolved();
        return Erc7930.toAddress(Erc7930.parseStrict(r.interop));
    }
}
