// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVmDeriver} from "src/derivation/VmDeriver.sol";
import {AddressDerive} from "src/derivation/AddressDerive.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Move} from "src/addressing/Move.sol";
import {IRefValidator} from "src/registry/IRefValidator.sol";
import {ICommitmentScheme, SchemeFold} from "src/registry/ICommitmentScheme.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";

/// @notice The CREATE2 inputs a message provider's contracts deploy from.
///
/// @dev THE SALT IS PER PROVIDER, NOT PER CHAIN. One salt used everywhere is what makes a
///      provider's transceiver land on ONE address on every chain: the property
///      `defaultCounterpart` relies on, stated as inputs rather than assumed from a local
///      deployment.
///
/// @dev IT EXISTS TO BE MINED. A transceiver is a proxy that is then frozen, so its address
///      is fixed for the life of the protocol and appears in calldata forever after. Zero
///      bytes cost 4 gas against 16, so a salt ground for leading zeros is a permanent
///      discount on every message that names the address; recording it here is what makes
///      the resulting address reproducible on the hub.
struct ProviderDeployment {
    /// The mined salt, identical on every chain.
    bytes32 salt;
    /// keccak256 of the transceiver PROXY's initcode: deployer as owner, factory as
    /// placeholder implementation. Not an implementation's: the proxy is what the factory
    /// deploys, and it is byte-identical for a hub and a spoke.
    bytes32 transceiverInitCodeHash;
    /// keccak256 of `CrossProxy`'s initcode: the same constant for a transmitter and a
    /// receiver, which is exactly why one owner has one address everywhere.
    bytes32 accountInitCodeHash;
}

/// @title ChainRegistry
/// @notice The home-chain directory of every chain crossecute talks to, and of what can be
///         known about addresses on each.
///
/// @dev IT ANSWERS QUESTIONS ABOUT A CHAIN, AND NOTHING ABOUT A COUNTERPART. That is the
///      whole line, and it decides every field below. Where a provider's transceiver sits
///      on a chain is per provider, since two providers put two transceivers there, so it
///      lives on the hub that sends to it. How well an address on that chain can be known
///      is the same question for every provider, so it is answered once, here, and every
///      hub references it. Two hubs cannot disagree about a chain.
///
///      What that leaves is a DIRECTORY: enumerable sets of `chainKey` and
///      `messageProvider`, the canonical identifier each key hashes from, and the local hub
///      that speaks for each provider.
///
///      Plus the PER-CHAIN POLICY a hub consults before it records anything:
///      `provenanceFor` (what a claim about this chain is worth), `validateLocation` (the
///      value ranges an ERC-7930 envelope cannot express), `expectedTransceiver` (recompute
///      an address from the deriver and inputs recorded for this chain), and
///      `commitmentFor` (the primitive its receiver hashes with).
///
/// @dev IT HOLDS NO ROUTES AND NO COUNTERPARTS, for one reason stated twice: the contract
///      that sends should hold what it needs to send. A registry read on the send path
///      would put a second shared contract there and let a compromised one misroute a
///      payload, and on the execute-on-arrival path there is no commitment binding the
///      destination, so a misroute runs the payload on the wrong chain.
///
/// @dev THE GRADING IS THE POINT, AND IT SITS ONE LEVEL ABOVE THE ADDRESS. Collapsing a
///      location and how well it can be known into one `address` field is how a
///      bridge-security assumption gets laundered into something that looks like a
///      derivation. A hub stores the address; this contract says whether that chain's
///      addresses can be recomputed at all, and a hub below its own bar refuses to send.
contract ChainRegistry is OwnableUpgradeable {
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

    /// messageProvider => the local hub transceiver that serves it. This is both the
    /// callback authority and the address the default counterpart is derived from.
    ///
    /// @dev PER PROVIDER, NOT ONE ADDRESS, so the permission is keyed the way the directory
    ///      already is. A single authorized transceiver would let only one provider's hub
    ///      deliver a report, and a second provider could never be added without displacing
    ///      the first.
    mapping(bytes32 => address) public localTransceiver;
    /// The reverse: which provider a calling transceiver speaks for.
    ///
    /// @dev THIS IS WHY THE CALLBACK TAKES NO `messageProvider` ARGUMENT. The caller is
    ///      already authenticated as a specific hub, and a hub serves exactly one
    ///      provider, so the provider is a property of `msg.sender` rather than a claim
    ///      the message gets to make about itself.
    mapping(address => bytes32) public providerOfTransceiver;

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
    /// chainKey => what an address claim about this chain is worth.
    ///
    /// @dev IT IS A PROPERTY OF THE CHAIN, WHICH IS WHY IT IS HERE AND THE ADDRESS IS NOT.
    ///      Where a provider's transceiver sits on a chain is per-provider and lives on the
    ///      hub that sends there; how much ANY address claim about that chain is worth is
    ///      the same question for every provider, so it is answered once, here, and every
    ///      hub references it. Two hubs on one chain cannot disagree about it.
    ///
    /// @dev `Derived` means this contract can recompute an address on that chain from
    ///      inputs in a signed transaction. `Attested` means it cannot, so the value was
    ///      learned over a bridge and is worth exactly that bridge's security: Starknet,
    ///      whose derivation is Pedersen, and zkSync and Tron, whose CREATE2 formulas
    ///      differ. Unset reads as `Unresolved`, which no bar accepts.
    mapping(bytes32 => Provenance) public provenanceOf;

    /// chainKey => the primitive that chain's receiver hashes commitments with.
    ///
    /// @dev THE ENUM COULD NOT GROW AND THIS CAN. `Scheme` is compiled into every
    ///      transmitter, and a transmitter locks in the call that arms it, so the set of
    ///      primitives an account can name is fixed at its creation, forever: a chain
    ///      onboarded later would be unpreviewable on every account already live. Behind a
    ///      mapping the set grows with one owner transaction.
    ///
    /// @dev SAFE TO MAKE MUTABLE ONLY BECAUSE NOTHING ENFORCES WITH IT. A commitment is
    ///      enforced by the destination's own receiver, never by a read from here. Advisory
    ///      here, enforced there.
    mapping(bytes32 => ICommitmentScheme) public commitmentSchemeOf;

    /* ================================== events ================================= */

    event ChainKeyAdded(bytes32 indexed chainKey, bytes chainIdentifier);
    event ChainKeyRemoved(bytes32 indexed chainKey);
    event MessageProviderAdded(bytes32 indexed messageProvider, string name);
    event MessageProviderRemoved(bytes32 indexed messageProvider);
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
    event ProvenanceSet(bytes32 indexed chainKey, Provenance provenance);
    event CommitmentSchemeSet(bytes32 indexed chainKey, address scheme);

    /* ================================== errors ================================= */

    error NotTransceiver();
    /// @dev A route, once declared, is fixed. Re-pointing it is a redeploy.
    error AlreadySet();
    error NoCounterpart();
    /// @dev No salt recorded for this provider, so nothing here can say where its
    ///      transceiver lands.
    error NoProviderDeployment();
    error ZeroSalt();
    error ZeroInitCodeHash();
    error UnknownChainKey();
    error UnknownMessageProvider();
    error EmptyName();
    error QualifierMismatch();
    error NoQualifier();
    error NoDeriver();
    error NoDeriveParams();
    error DeriverChainMismatch();
    error ParamsCommitmentMismatch();
    error SchemeNotSupported();
    /// @dev No primitive registered for this chain, so nothing here can say what its
    ///      receiver will require. Reverting beats returning a keccak digest the
    ///      destination could never match: the same reason `Commitment._hash` refuses
    ///      to fall back rather than guessing.
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

    /// @notice Drop a chain.
    /// @dev IT CANNOT CHECK FOR A LIVE COUNTERPART, because counterparts live on the hub that
    ///      sends to them. Dropping a chain therefore fails that hub CLOSED rather than
    ///      orphaning it: `provenanceFor` reverts `UnknownChainKey`, which no bar accepts, so
    ///      every send to that chain reverts until it is re-added.
    function removeChainKey(bytes32 chainKey) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();

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

    /* ============================== configuration ============================== */

    /// @notice Register the local hub transceiver that serves one message provider.
    ///
    /// @dev IT DOES TWO JOBS, AND THEY ARE THE SAME FACT. This address is the only caller
    ///      permitted to deliver a resolution callback for `messageProvider`, and it is the
    ///      address the default counterpart is derived from, because hub and spoke share
    ///      proxy initcode and salt and so land together wherever Ethereum's CREATE2 formula
    ///      holds. Pass the zero address to retire a provider, which also removes the
    ///      default counterpart it backed.
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
    /// @dev WRITE-ONCE, because changing it moves every address derived from it: the
    ///      transceiver on every chain and every account under each of those. That is a
    ///      redeploy of the provider's whole footprint. Re-writing the identical record is a
    ///      no-op.
    ///
    /// @dev IT DOES NOT DEPLOY ANYTHING. The salt is mined and used off-chain by whoever
    ///      calls the factory; this records it so the hub can reproduce the addresses. A
    ///      record that does not match what was deployed yields predictions that match
    ///      nothing, which surfaces the first time a counterpart is read.
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
    ///      chain. zk-chains run their own, which is the case this setter exists for,
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
    ///      sense: the factory, salt, and initcode hash were all in the signed calldata that
    ///      recorded them, and this is arithmetic over them rather than a local address
    ///      assumed to match the remote one.
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
    /// @dev TWO CREATE2 STEPS, AND BOTH INPUTS ARE KNOWN: the transceiver from the
    ///      provider's salt, then the account from the transceiver with `(owner, salt)` as
    ///      its salt. So an account address is computable here for any owner on any parity
    ///      chain before a single message has crossed.
    ///
    ///      TRIPWIRE: the salt must match `TransceiverBase.accountSalt`. It is written out
    ///      rather than imported because this contract is on the home chain and that one is
    ///      on the destination; `test/SaltedDeployment.t.sol` asserts the two agree.
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
        if (!_isEvmDerivable(chainKey)) revert NoCounterpart();
    }

    function _isEvmDerivable(bytes32 chainKey) private view returns (bool) {
        return uint8(provenanceFor(chainKey)) >= uint8(Provenance.Derived);
    }

    /// @notice What an address claim about `chainKey` is worth, with the default applied.
    ///
    /// @dev AN UNDECLARED `eip155` CHAIN READS AS `Derived`, WHICH IS THE COMMON CASE NEEDING
    ///      NO CONFIGURATION. Every EVM chain but zkSync and Tron shares Ethereum's CREATE2
    ///      formula, so the default is right for almost all of them and the two exceptions
    ///      are declared. An undeclared chain of any other type reads as `Unresolved`, which
    ///      no bar accepts: nothing here can derive a Solana or Starknet address, so a
    ///      default would be a guess rather than a shortcut, and it must be stated.
    function provenanceFor(bytes32 chainKey) public view returns (Provenance) {
        Provenance declared = provenanceOf[chainKey];
        if (declared != Provenance.Unresolved) return declared;

        bytes memory identifier = _chainIdentifier[chainKey];
        if (identifier.length == 0) revert UnknownChainKey();
        return Erc7930.parseStrict(identifier).chainType == Erc7930.CT_EIP155
            ? Provenance.Derived
            : Provenance.Unresolved;
    }

    /// @notice Whether accounts on `chainKey` must report their own address home.
    ///
    /// @dev THE DIRECTION, NOT THE DATA, AND THAT IS THE WHOLE OF THIS REGISTRY'S PART IN
    ///      THE RECEIVER STORY. Where an account's receiver actually landed is a fact about
    ///      that account, so it is held by the transmitter it answers to, which is also the
    ///      only contract that reads it. What belongs here is which chains cannot be
    ///      answered locally, because that is a property of the CHAIN and it is what this
    ///      directory is for.
    ///
    /// @dev IT IS DERIVED, NOT DECLARED, so it cannot disagree with the caps. A chain needs
    ///      a callback exactly when this contract cannot recompute its addresses: it is not
    ///      `eip155`, or it is capped below `Derived` because its CREATE2 formula differs.
    ///      Those are the same two conditions `defaultCounterpart` withdraws on, read the
    ///      other way round, and a separate flag would be a second source of truth for one
    ///      fact. It is the hub's side of `SpokeTransceiverBase.addressesDiverge`.
    function requiresReceiverCallback(bytes32 chainKey) external view returns (bool) {
        return !_isEvmDerivable(chainKey);
    }

    /// @notice Check a location against everything this chain says about its addresses.
    ///
    /// @dev THE VALIDATION LIVES HERE AND THE STORAGE DOES NOT, because what makes an
    ///      address well-formed is a property of the CHAIN: the ERC-7930 canonicity rules,
    ///      and the value ranges the envelope cannot express (Starknet's felt bound, Move's
    ///      AIP-40 width). A hub calls this before recording a counterpart, so one validator
    ///      per chain serves every provider rather than each hub carrying its own.
    ///
    /// @dev IT ALSO CHECKS THE LOCATION IS ON THE CHAIN IT IS BEING FILED UNDER, which is
    ///      what stops a stored counterpart contradicting its own envelope.
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
    ///
    /// @dev REBINDABLE, UNLIKE `setRoute`. A route is write-once because re-pointing one
    ///      redirects live messages; this points at nothing and redirects nothing, so a wrong
    ///      primitive has to be fixable. It is the only part of the commitment story that can
    ///      be. Passing the zero address unregisters, which makes `commitmentFor` revert
    ///      rather than answer: a signer who cannot get an answer computes one, where a
    ///      signer given a wrong answer approves it.
    function setCommitmentScheme(bytes32 chainKey, ICommitmentScheme scheme)
        external
        onlyOwner
    {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        commitmentSchemeOf[chainKey] = scheme;
        emit CommitmentSchemeSet(chainKey, address(scheme));
    }

    /// @notice PREVIEW. The commitment `chainKey`'s receiver will require over `elements`.
    ///
    /// @dev THIS CONTRACT RESOLVES THE PLUGIN AND NOTHING ELSE. The fold is `SchemeFold`,
    ///      beside the interface, which carries the argument for why it is a second copy of
    ///      `Commitment.hashCalls` rather than a call into it.
    ///
    /// @dev NOTHING ON-CHAIN CALLS THIS, AND NOTHING MAY. A commitment is enforced by the
    ///      destination's receiver against its own frozen fold, never against a mutable
    ///      lookup here. This is read through `eth_call` by a signer checking a payload.
    function commitmentFor(bytes32 chainKey, bytes[] calldata elements)
        external
        view
        returns (bytes32)
    {
        ICommitmentScheme scheme = commitmentSchemeOf[chainKey];
        if (address(scheme) == address(0)) revert NoCommitmentScheme();
        return SchemeFold.hashCalls(scheme, chainKey, elements);
    }

    /// @notice State what an address claim about `chainKey` is worth.
    ///
    /// @dev DECLARE IT BELOW `Derived` FOR EVERY CHAIN THIS ONE CANNOT RECOMPUTE. Starknet's
    ///      derivation is Pedersen, and zkSync and Tron use different CREATE2 formulas while
    ///      still being `eip155`, so the default would read them as `Derived` and be wrong.
    ///      Declaring `Attested` makes the stronger claim unrepresentable rather than merely
    ///      discouraged, and it is what turns `requiresReceiverCallback` on for them.
    function setProvenance(bytes32 chainKey, Provenance provenance) external onlyOwner {
        if (!_chainKeys.contains(chainKey)) revert UnknownChainKey();
        provenanceOf[chainKey] = provenance;
        emit ProvenanceSet(chainKey, provenance);
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
    ///      a no-argument read: the whole point of normalizing. Validated against the
    ///      deriver at wiring time so a scheme/chain mismatch surfaces here rather than
    ///      at the first resolve.
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

    /// @notice Every destination at once: the expected transceiver on each registered chain.
    /// @dev Chains with no deriver or no params yield empty `interops[i]` rather than
    ///      reverting, since one unconfigured chain must not blind the view of the others.
    function expectedTransceivers()
        external
        view
        returns (bytes32[] memory keys, bytes[] memory interops)
    {
        keys = _chainKeys.values();
        uint256 n = keys.length;
        interops = new bytes[](n);

        for (uint256 i; i < n; ++i) {
            if (address(deriverOf[keys[i]]) == address(0)) continue;
            if (_deriveParams[keys[i]].length == 0) continue;
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

    function messageProviderName(bytes32 messageProvider)
        external
        view
        returns (string memory)
    {
        if (!_messageProviders.contains(messageProvider)) revert UnknownMessageProvider();
        return _messageProviderName[messageProvider];
    }
}
