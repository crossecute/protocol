// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Conduits} from "src/conduit/Conduits.sol";
import {ProxyInitCode} from "src/conduit/ProxyInitCode.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {Payload} from "src/messaging/Payload.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {
    ILzOftConduitFactory,
    ILzOftConduitFactoryView,
    ILzOftSignedConduitFactory
} from "src/protocols/layerzero/ILzOftConduitFactory.sol";
import {ILzOftCreate} from "src/protocols/layerzero/ILzOftCreate.sol";
import {ILzOftTransmitterInit} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {ILzOftReceiverInit} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftMerkle} from "src/protocols/layerzero/LzOftMerkle.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";

import {SafeViewer} from "src/messaging/signed/SafeViewer.sol";
import {ISignedTransmitterInit} from "src/messaging/outbound/ISignedTransmitter.sol";
import {ISignedReceiverInit} from "src/messaging/inbound/ISignedReceiver.sol";
import {Call} from "src/messaging/Call.sol";

/// @dev A conduit's creation-time identity, which it fixes for life.
interface IConduitIdentity {
    function deployer() external view returns (address);
    function conduitSalt() external view returns (bytes32);
}

/// @title LzOftConduitFactory
/// @notice Creates every `layerzero-oft` conduit: the transmitter on its home, when its
///         operator calls `createTransmitter`, and each receiver, when the conduit's bootstrap
///         arrives as an OFT compose.
///
/// @dev No owner, mutable configuration or upgrade path. Deployed with the logic and treasury
///      addresses, which are the same on every chain, so this has one address
///      everywhere and a conduit has one address everywhere.
///
/// @dev Both modes derive the CREATE2 salt from `(owner, salt, homeChainKey, homeEid, homeOft, destRoot)`.
///      Creation fixes the mode.
///      Any contract can queue a compose for any target, so the bootstrap is trusted only
///      because the delivering OFT proves into the root the message names, and that root is
///      part of the address the receiver is created at: a forged root creates another conduit.
contract LzOftConduitFactory is ILzOftSignedConduitFactory, ILzOftConduitFactoryView, ILzOftCreate, ILayerZeroComposer {
    /// @dev The route committed at conduit creation and its index in the destination tree.
    struct CommittedDestination {
        uint32 eid;
        address oft;
        uint64 index;
    }

    struct Conduit {
        address homeOft;
        uint32 homeEid;
        bytes32 destRoot;
    }

    /// @notice Discriminator for the signed OFT bootstrap compose envelope.
    uint256 public constant SIGNED_BOOTSTRAP = uint256(keccak256("crossecute.layerzero-oft.signed-bootstrap.v1"));

    address public immutable transmitterImplementation;
    address public immutable receiverImplementation;
    address public immutable treasury;
    /// @notice This chain's key, read at deployment, so each chain's copy knows its own chain.
    bytes32 public immutable localChainKey;
    /// @inheritdoc ILzOftConduitFactoryView
    bytes32 public immutable override PROXY_INIT_CODE_HASH = ProxyInitCode.hash();
    address internal immutable _proxyInitCode;

    mapping(address conduit => Conduit) internal _conduits;
    /// @dev Leaf hashes in the order the operator listed them, for rebuilding a proof.
    mapping(address conduit => bytes32[]) internal _leafHashes;
    mapping(address conduit => mapping(bytes32 chainKey => CommittedDestination)) internal _destinations;

    event TransmitterCreated(
        address indexed owner, address indexed conduit, bytes32 salt, uint32 homeEid, address homeOft, bytes32 destRoot
    );
    event ReceiverCreated(address indexed conduit, uint32 homeEid, address localOft);
    event SignedConduitCreated(address indexed conduit);

    error NoImplementation();
    error NoTreasury();
    error NotAnOft(address oft);
    error NoDestinations();
    /// @dev Leaves must be in strictly ascending `chainKey` order, which also refuses a repeat.
    error LeavesNotSorted(uint256 index);
    error BadLeaf(uint256 index);
    error NotADestination(address conduit, bytes32 chainKey);
    error UnknownConduit(address conduit);
    error NotTheEndpoint(address caller);
    error NotTheHomeEid(uint32 srcEid, uint32 homeEid);
    error NotInRoot(bytes32 leaf);
    error NotTheConduit(address composeFrom, address conduit);
    error ValueNotForwarded(address conduit);
    /// @dev The compose carries `Call[]`, which only an EVM chain's factory decodes.
    error NotAnEvmChain(bytes32 chainKey);
    error WrongBootstrapMode();
    error HomeChainMismatch(uint256 sourceChainId, bytes32 homeChainKey);

    constructor(address transmitterImplementation_, address receiverImplementation_, address treasury_) {
        if (transmitterImplementation_.code.length == 0 || receiverImplementation_.code.length == 0) {
            revert NoImplementation();
        }
        transmitterImplementation = transmitterImplementation_;
        receiverImplementation = receiverImplementation_;
        if (treasury_ == address(0)) revert NoTreasury();
        treasury = treasury_;
        localChainKey = ChainKey.local();
        _proxyInitCode = ProxyInitCode.store();
    }

    /* ================================= addresses =============================== */

    function conduitSalt(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 destRoot
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt, homeChainKey, homeEid, homeOft, destRoot));
    }

    /// @inheritdoc ILzOftConduitFactoryView
    function predictConduit(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 destRoot
    ) public view returns (address) {
        return Create2.computeAddress(
            conduitSalt(owner, salt, homeChainKey, homeEid, homeOft, destRoot), PROXY_INIT_CODE_HASH
        );
    }

    /* ================================== home =================================== */

    /// @notice Create the caller's conduit, homed here, reaching exactly `leaves`.
    ///
    /// @dev The owner is `msg.sender`, so nobody can claim the address another party will
    ///      occupy. The home eid is `homeOft`'s endpoint's. Each leaf is checked against
    ///      `homeOft`'s peers now, and again at each send.
    ///      A leaf whose `eid` is another chain's is not caught here, since nothing on this chain
    ///      maps an eid to a chain; that bootstrap's compose fails at the destination.
    function createTransmitter(bytes32 salt, address homeOft, OftLeaf[] calldata leaves)
        external
        override
        returns (address conduit)
    {
        uint32 homeEid = _homeEid(homeOft);
        bytes32[] memory hashes = _requireLeaves(homeOft, homeEid, leaves);
        bytes32 destRoot = LzOftMerkle.root(hashes);

        bool signed = SafeViewer.signedAuthority(msg.sender).length != 0;
        bytes32 s = conduitSalt(msg.sender, salt, localChainKey, homeEid, homeOft, destRoot);
        conduit = Create2.computeAddress(s, PROXY_INIT_CODE_HASH);
        Conduits.requireVacant(conduit, msg.sender, salt);
        Conduits.requireLanded(conduit, Conduits.deploy(s, _proxyInitCode));
        Conduits.arm(
            conduit,
            transmitterImplementation,
            abi.encodeCall(ILzOftTransmitterInit.initialize, (msg.sender, address(this), salt, homeOft))
        );

        if (signed) ISignedTransmitterInit(conduit).initializeSigned();
        _conduits[conduit] = Conduit(homeOft, homeEid, destRoot);
        _leafHashes[conduit] = hashes;
        for (uint256 i; i < leaves.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast,costly-loop) index bounded; one write each
            _destinations[conduit][leaves[i].chainKey] = CommittedDestination(leaves[i].eid, leaves[i].oft, uint64(i));
        }
        emit TransmitterCreated(msg.sender, conduit, salt, homeEid, homeOft, destRoot);
        if (signed) emit SignedConduitCreated(conduit);
    }

    /// @inheritdoc ILzOftConduitFactoryView
    function bootstrapRoute(address conduit, bytes32 chainKey)
        external
        view
        returns (uint32 eid, address dstOft, uint32 homeEid, bytes32 destRoot, bytes32[] memory proof)
    {
        CommittedDestination memory d = _destination(conduit, chainKey);
        Conduit memory a = _conduits[conduit];
        return (d.eid, d.oft, a.homeEid, a.destRoot, LzOftMerkle.proof(_leafHashes[conduit], d.index));
    }

    /// @inheritdoc ILzOftConduitFactory
    function destinationOf(address conduit, bytes32 chainKey) external view returns (uint32 eid, address oft) {
        CommittedDestination memory d = _destination(conduit, chainKey);
        return (d.eid, d.oft);
    }

    /// @notice The bootstrap the calling conduit sends itself, through its home OFT, to this
    ///         factory on the chain `route` names.
    /// @dev The conduit sends it, not this factory: the destination authenticates the conduit as
    ///      the compose's `composeFrom`. `(owner, salt)` must derive the caller with its stored
    ///      fields, so the compose names the conduit the destination will derive.
    function conduitBootstrap(bytes calldata route, address owner, bytes32 salt, bytes calldata body)
        external
        view
        returns (bytes memory recipient, bytes memory message)
    {
        Conduit memory a = _callerConduit();
        _requireDerived(a, owner, salt);
        if (ISignedTransmitterInit(msg.sender).isSigned()) revert WrongBootstrapMode();
        bytes32 chainKey = keccak256(route);
        Erc7930.Interop memory io = Erc7930.parseStrict(route);
        if (io.chainType != Erc7930.CT_EIP155) revert NotAnEvmChain(chainKey);
        CommittedDestination memory d = _destination(msg.sender, chainKey);

        message = LzOftMessage.encodeBootstrap(
            LzOftMessage.Bootstrap(
                owner,
                salt,
                localChainKey,
                a.homeEid,
                a.homeOft,
                a.destRoot,
                LzOftMerkle.proof(_leafHashes[msg.sender], d.index),
                Payload.decodeCalls(body)
            )
        );
        recipient = Erc7930.encode(io.chainType, io.chainRef, abi.encodePacked(address(this)));
    }

    /// @notice Build a signed bootstrap for the calling conduit to send through its own OFT.
    function signedConduitBootstrap(bytes calldata route, bytes calldata body)
        external
        view
        returns (bytes memory recipient, bytes memory message)
    {
        Conduit memory a = _callerConduit();
        address owner = IConduitIdentity(msg.sender).deployer();
        bytes32 salt = IConduitIdentity(msg.sender).conduitSalt();
        _requireDerived(a, owner, salt);
        if (!ISignedTransmitterInit(msg.sender).isSigned()) revert WrongBootstrapMode();
        bytes32 chainKey = ChainKey.fromIdentifier(route);
        CommittedDestination memory d = _destination(msg.sender, chainKey);
        Erc7930.Interop memory io = Erc7930.parseStrict(route);
        if (io.chainType != Erc7930.CT_EIP155) revert NotAnEvmChain(chainKey);
        LzOftMessage.Bootstrap memory b = LzOftMessage.Bootstrap(
            owner,
            salt,
            localChainKey,
            a.homeEid,
            a.homeOft,
            a.destRoot,
            LzOftMerkle.proof(_leafHashes[msg.sender], d.index),
            new Call[](0)
        );
        recipient = Erc7930.encode(io.chainType, io.chainRef, abi.encodePacked(address(this)));
        message = abi.encode(SIGNED_BOOTSTRAP, b, block.chainid, body);
    }

    /// @notice Whether `conduit` was created in signed mode.
    function isSigned(address conduit) external view returns (bool) {
        return _conduits[conduit].homeOft != address(0) && ISignedTransmitterInit(conduit).isSigned();
    }

    function _callerConduit() private view returns (Conduit memory a) {
        a = _conduits[msg.sender];
        if (a.homeOft == address(0)) revert UnknownConduit(msg.sender);
    }

    /// @dev `(owner, salt)` must derive the caller from its stored fields, so the compose names the
    ///      conduit the destination derives.
    function _requireDerived(Conduit memory a, address owner, bytes32 salt) private view {
        address derived = predictConduit(owner, salt, localChainKey, a.homeEid, a.homeOft, a.destRoot);
        if (derived != msg.sender) revert NotTheConduit(msg.sender, derived);
    }

    function _destination(address conduit, bytes32 chainKey) private view returns (CommittedDestination memory d) {
        d = _destinations[conduit][chainKey];
        if (d.oft == address(0)) revert NotADestination(conduit, chainKey);
    }

    /// @notice No receiver is reported: every chain this binding reaches uses Ethereum's CREATE2.
    function reportsReceiver(bytes32) external pure returns (bool) {
        return false;
    }

    /// @notice Where the calling conduit's receiver sits on any destination: its own address,
    ///         since this factory and the salt are the same there.
    /// @dev Read from the caller rather than recomputed from `(owner, salt)`, which would also
    ///      need `homeOft` and the root, and would move if the conduit's owner changed.
    function predictReceiver(bytes32, address, bytes32) external view returns (bytes memory) {
        if (_conduits[msg.sender].homeOft == address(0)) revert UnknownConduit(msg.sender);
        return abi.encodePacked(msg.sender);
    }

    /* =============================== destination ============================== */

    /// @notice Create a receiver from the conduit's bootstrap, delivered as a compose by this
    ///         chain's OFT.
    ///
    /// @dev Checks, in order: the endpoint `_from` uses is the caller; `_from` is this chain's
    ///      leaf in the root the message names; the source eid is the message's `homeEid`, and
    ///      `_from` peers the message's `homeOft` for it, so the packet came from it, verified by
    ///      `_from`'s own DVNs; and `composeFrom` is the conduit the message's fields derive.
    ///      Without the eid check, the conduit's receiver on another chain with the same OFT
    ///      address could send this compose and become the receiver's home.
    ///
    /// @dev The conduit sends no tokens, so the compose carries an amount of 0 and nothing is
    ///      credited here. Any native value the executor attaches goes to the conduit.
    function lzCompose(
        address _from,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    )
        external
        payable
        override
    {
        bytes calldata payload = _message[LzOftMessage.COMPOSE_MSG_OFFSET:];
        if (payload.length >= 32 && abi.decode(payload[:32], (uint256)) == SIGNED_BOOTSTRAP) {
            _createSignedReceiver(_from, _message, payload);
        } else {
            _createReceiver(_from, _message);
        }
    }

    function _createReceiver(address from, bytes calldata message) private {
        (LzOftMessage.Bootstrap memory b, bytes32 s, address conduit, uint32 srcEid) = _authenticate(from, message);
        _forwardValue(conduit);

        Conduits.requireLanded(conduit, Conduits.deploy(s, _proxyInitCode));
        bytes memory init = abi.encodeCall(ILzOftReceiverInit.initialize, (conduit, srcEid, b.homeOft, from, b.calls));
        Conduits.arm(conduit, receiverImplementation, init);
        emit ReceiverCreated(conduit, srcEid, from);
    }

    /// @dev The four checks `lzCompose` names, then the vacancy check, before anything moves.
    function _authenticate(address from, bytes calldata message)
        private
        view
        returns (LzOftMessage.Bootstrap memory b, bytes32 s, address conduit, uint32 srcEid)
    {
        b = LzOftMessage.decodeBootstrap(message[LzOftMessage.COMPOSE_MSG_OFFSET:]);
        (s, conduit, srcEid) = _authenticateBootstrap(from, message, b);
        Conduits.requireVacant(conduit, b.owner, b.salt);
    }

    function _authenticateBootstrap(address from, bytes calldata message, LzOftMessage.Bootstrap memory b)
        private
        view
        returns (bytes32 s, address conduit, uint32 srcEid)
    {
        ILayerZeroEndpointV2 endpoint = IOAppCore(from).endpoint();
        if (msg.sender != address(endpoint)) revert NotTheEndpoint(msg.sender);
        bytes32 leaf = LzOftMerkle.leaf(localChainKey, endpoint.eid(), from);
        if (!MerkleProof.verify(b.proof, b.destRoot, leaf)) revert NotInRoot(leaf);

        srcEid = OFTComposeMsgCodec.srcEid(message);
        if (srcEid != b.homeEid) revert NotTheHomeEid(srcEid, b.homeEid);
        if (b.homeOft == address(0)) revert NotAnOft(address(0));
        LzOftMessage.requirePeer(from, srcEid, b.homeOft);

        s = conduitSalt(b.owner, b.salt, b.homeChainKey, b.homeEid, b.homeOft, b.destRoot);
        conduit = Create2.computeAddress(s, PROXY_INIT_CODE_HASH);
        address composeFrom = ProviderAddress.evmSender(OFTComposeMsgCodec.composeFrom(message));
        if (composeFrom != conduit) revert NotTheConduit(composeFrom, conduit);
    }

    function _createSignedReceiver(address from, bytes calldata message, bytes calldata payload) private {
        (, LzOftMessage.Bootstrap memory b, uint256 sourceChainId, bytes memory body) =
            abi.decode(payload, (uint256, LzOftMessage.Bootstrap, uint256, bytes));
        if (ChainKey.forEvm(sourceChainId) != b.homeChainKey) revert HomeChainMismatch(sourceChainId, b.homeChainKey);
        (bytes32 s, address conduit, uint32 srcEid) = _authenticateBootstrap(from, message, b);
        Conduits.requireVacant(conduit, b.owner, b.salt);
        _forwardValue(conduit);
        Conduits.requireLanded(conduit, Conduits.deploy(s, _proxyInitCode));
        _armSignedReceiver(conduit, srcEid, b.homeOft, from);
        ISignedReceiverInit(conduit).initializeSigned(sourceChainId, b.owner, body);
        emit ReceiverCreated(conduit, srcEid, from);
    }

    function _armSignedReceiver(address conduit, uint32 srcEid, address homeOft, address from) private {
        Conduits.arm(
            conduit,
            receiverImplementation,
            abi.encodeCall(ILzOftReceiverInit.initialize, (conduit, srcEid, homeOft, from, new Call[](0)))
        );
    }

    /// @dev Before the conduit has code: an address with none accepts value without running
    ///      anything, and the bootstrap calls the receiver runs when armed can spend it.
    function _forwardValue(address conduit) private {
        if (msg.value != 0) {
            // forge-lint: disable-next-line(arbitrary-send-eth) the conduit the compose was proven for
            (bool ok,) = conduit.call{value: msg.value}("");
            if (!ok) revert ValueNotForwarded(conduit);
        }
    }

    /* ================================== leaves ================================= */

    function _homeEid(address homeOft) private view returns (uint32) {
        if (homeOft.code.length == 0) revert NotAnOft(homeOft);
        ILayerZeroEndpointV2 endpoint = IOAppCore(homeOft).endpoint();
        if (address(endpoint).code.length == 0) revert NotAnOft(homeOft);
        return endpoint.eid();
    }

    function _requireLeaves(address homeOft, uint32 homeEid, OftLeaf[] calldata leaves)
        private
        view
        returns (bytes32[] memory hashes)
    {
        if (leaves.length == 0) revert NoDestinations();
        hashes = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            OftLeaf calldata l = leaves[i];
            if (i != 0 && l.chainKey <= leaves[i - 1].chainKey) revert LeavesNotSorted(i);
            if (l.chainKey == localChainKey || l.eid == 0 || l.eid == homeEid || l.oft == address(0)) {
                revert BadLeaf(i);
            }
            LzOftMessage.requirePeer(homeOft, l.eid, l.oft);
            hashes[i] = LzOftMerkle.leaf(l.chainKey, l.eid, l.oft);
        }
    }
}
