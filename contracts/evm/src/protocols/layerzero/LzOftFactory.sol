// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {CrossAccounts} from "src/account/CrossAccounts.sol";
import {CrossProxyInitCode} from "src/account/CrossProxyInitCode.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {ILzOftFactory} from "src/protocols/layerzero/ILzOftFactory.sol";
import {ILzOftTransmitterInit} from "src/protocols/layerzero/LzOftTransmitter.sol";
import {ILzOftReceiverInit} from "src/protocols/layerzero/LzOftReceiver.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";

/// @title LzOftFactory
/// @notice Creates every `layerzero-oft` account: the transmitter on its home, when its
///         operator calls `createTransmitter`, and each receiver, when the account's bootstrap
///         arrives as an OFT compose.
///
/// @dev No owner, no configuration and no upgrade path. Deployed with the logic addresses as its
///      only arguments, which are themselves the same on every chain, so this has one address
///      everywhere and an account has one address everywhere.
///
/// @dev An account's CREATE2 salt binds `(owner, salt, homeChainKey, homeEid, homeOft, destRoot)`.
///      Any contract can queue a compose for any target, so the bootstrap is trusted only
///      because the delivering OFT proves into the root the message names, and that root is
///      part of the address the receiver is created at: a forged root creates another account.
contract LzOftFactory is ILzOftFactory, ILayerZeroComposer {
    /// @notice One destination, as the operator lists it at creation.
    struct Leaf {
        bytes32 chainKey;
        uint32 eid;
        address oft;
    }

    struct Destination {
        uint32 eid;
        address oft;
        uint64 index;
    }

    struct Account {
        address homeOft;
        uint32 homeEid;
        bytes32 destRoot;
    }

    address public immutable transmitterImplementation;
    address public immutable receiverImplementation;
    /// @notice This chain's key, read at deployment, so each chain's copy knows its own chain.
    bytes32 public immutable localChainKey;
    bytes32 public immutable CROSS_PROXY_INIT_CODE_HASH = CrossProxyInitCode.hash();
    address internal immutable _crossProxyInitCode;

    mapping(address account => Account) internal _accounts;
    /// @dev Leaf hashes in the order the operator listed them, for rebuilding a proof.
    mapping(address account => bytes32[]) internal _leafHashes;
    mapping(address account => mapping(bytes32 chainKey => Destination)) internal _destinations;

    event TransmitterCreated(
        address indexed owner, address indexed account, bytes32 salt, uint32 homeEid, address homeOft, bytes32 destRoot
    );
    event ReceiverCreated(address indexed account, uint32 homeEid, address localOft);

    error NoImplementation();
    error NotAnOft(address oft);
    error NoDestinations();
    /// @dev Leaves must be in strictly ascending `chainKey` order, which also refuses a repeat.
    error LeavesNotSorted(uint256 index);
    error BadLeaf(uint256 index);
    error NotADestination(address account, bytes32 chainKey);
    error UnknownAccount(address account);
    error NotTheEndpoint(address caller);
    error NotTheHomeEid(uint32 srcEid, uint32 homeEid);
    error NotInRoot(bytes32 leaf);
    error NotTheAccount(address composeFrom, address account);
    error ValueNotForwarded(address account);

    constructor(address transmitterImplementation_, address receiverImplementation_) {
        if (transmitterImplementation_.code.length == 0 || receiverImplementation_.code.length == 0) {
            revert NoImplementation();
        }
        transmitterImplementation = transmitterImplementation_;
        receiverImplementation = receiverImplementation_;
        localChainKey = ChainKey.local();
        _crossProxyInitCode = CrossProxyInitCode.store();
    }

    /* ================================= addresses =============================== */

    function accountSalt(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 destRoot
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt, homeChainKey, homeEid, homeOft, destRoot));
    }

    function predictAccount(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 destRoot
    ) public view returns (address) {
        return Create2.computeAddress(
            accountSalt(owner, salt, homeChainKey, homeEid, homeOft, destRoot), CROSS_PROXY_INIT_CODE_HASH
        );
    }

    /* ================================== home =================================== */

    /// @notice Create the caller's account, homed here, reaching exactly `leaves`.
    ///
    /// @dev The owner is `msg.sender`, so nobody can claim the address another party will
    ///      occupy. The home eid is `homeOft`'s endpoint's. Each leaf is checked against
    ///      `homeOft`'s peers now, and again at each send.
    ///      A leaf whose `eid` is another chain's is not caught here, since nothing on this chain
    ///      maps an eid to a chain; that bootstrap's compose fails at the destination.
    function createTransmitter(bytes32 salt, address homeOft, Leaf[] calldata leaves)
        external
        returns (address account)
    {
        uint32 homeEid = _homeEid(homeOft);
        bytes32[] memory hashes = _checkLeaves(homeOft, homeEid, leaves);
        bytes32 destRoot = LzOftMessage.root(hashes);

        bytes32 s = accountSalt(msg.sender, salt, localChainKey, homeEid, homeOft, destRoot);
        account = Create2.computeAddress(s, CROSS_PROXY_INIT_CODE_HASH);
        CrossAccounts.requireVacant(account, msg.sender, salt);
        CrossAccounts.requireLanded(account, CrossAccounts.deploy(s, _crossProxyInitCode));
        CrossAccounts.arm(
            account,
            transmitterImplementation,
            abi.encodeCall(ILzOftTransmitterInit.initialize, (msg.sender, address(this), salt, homeOft))
        );

        _accounts[account] = Account(homeOft, homeEid, destRoot);
        _leafHashes[account] = hashes;
        for (uint256 i; i < leaves.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast,costly-loop) index bounded; one write each
            _destinations[account][leaves[i].chainKey] = Destination(leaves[i].eid, leaves[i].oft, uint64(i));
        }
        emit TransmitterCreated(msg.sender, account, salt, homeEid, homeOft, destRoot);
    }

    /// @inheritdoc ILzOftFactory
    function bootstrapRoute(address account, bytes32 chainKey)
        external
        view
        returns (uint32 eid, address dstOft, uint32 homeEid, bytes32 destRoot, bytes32[] memory proof)
    {
        Destination memory d = _destinations[account][chainKey];
        if (d.oft == address(0)) revert NotADestination(account, chainKey);
        Account memory a = _accounts[account];
        return (d.eid, d.oft, a.homeEid, a.destRoot, LzOftMessage.proof(_leafHashes[account], d.index));
    }

    /// @notice No receiver is reported: every chain this binding reaches uses Ethereum's CREATE2.
    function reportsReceiver(bytes32) external pure returns (bool) {
        return false;
    }

    /// @notice Where the calling account's receiver sits on any destination: its own address,
    ///         since this factory and the salt are the same there.
    /// @dev Read from the caller rather than recomputed from `(owner, salt)`, which would also
    ///      need `homeOft` and the root, and would move if the account's owner changed.
    function predictReceiver(bytes32, address, bytes32) external view returns (bytes memory) {
        if (_accounts[msg.sender].homeOft == address(0)) revert UnknownAccount(msg.sender);
        return abi.encodePacked(msg.sender);
    }

    /* =============================== destination ============================== */

    /// @notice Create a receiver from the account's bootstrap, delivered as a compose by this
    ///         chain's OFT.
    ///
    /// @dev Checks, in order: the endpoint `_from` uses is the caller; `_from` is this chain's
    ///      leaf in the root the message names; the source eid is the message's `homeEid`, and
    ///      `_from` peers the message's `homeOft` for it, so the packet came from it, verified by
    ///      `_from`'s own DVNs; and `composeFrom` is the account the message's fields derive.
    ///      Without the eid check, the account's receiver on another chain with the same OFT
    ///      address could send this compose and become the receiver's home.
    ///
    /// @dev The account sends no tokens, so the compose carries an amount of 0 and nothing is
    ///      credited here. Any native value the executor attaches goes to the account.
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
        _createReceiver(_from, _message);
    }

    function _createReceiver(address from, bytes calldata message) private {
        (LzOftMessage.Bootstrap memory b, bytes32 s, address account, uint32 srcEid) = _authenticate(from, message);
        _forwardValue(account);

        CrossAccounts.requireLanded(account, CrossAccounts.deploy(s, _crossProxyInitCode));
        bytes memory init = abi.encodeCall(ILzOftReceiverInit.initialize, (account, srcEid, b.homeOft, from, b.calls));
        CrossAccounts.arm(account, receiverImplementation, init);
        emit ReceiverCreated(account, srcEid, from);
    }

    /// @dev The four checks `lzCompose` names, then the vacancy check, before anything moves.
    function _authenticate(address from, bytes calldata message)
        private
        view
        returns (LzOftMessage.Bootstrap memory b, bytes32 s, address account, uint32 srcEid)
    {
        ILayerZeroEndpointV2 endpoint = IOAppCore(from).endpoint();
        if (msg.sender != address(endpoint)) revert NotTheEndpoint(msg.sender);

        b = LzOftMessage.decodeBootstrap(message[LzOftMessage.COMPOSE_MSG_OFFSET:]);
        bytes32 leaf = LzOftMessage.leaf(localChainKey, endpoint.eid(), from);
        if (!MerkleProof.verify(b.proof, b.destRoot, leaf)) revert NotInRoot(leaf);

        srcEid = OFTComposeMsgCodec.srcEid(message);
        if (srcEid != b.homeEid) revert NotTheHomeEid(srcEid, b.homeEid);
        if (b.homeOft == address(0)) revert NotAnOft(address(0));
        LzOftMessage.requirePeer(from, srcEid, b.homeOft);

        s = accountSalt(b.owner, b.salt, b.homeChainKey, b.homeEid, b.homeOft, b.destRoot);
        account = Create2.computeAddress(s, CROSS_PROXY_INIT_CODE_HASH);
        address composeFrom = ProviderAddress.evmSender(OFTComposeMsgCodec.composeFrom(message));
        if (composeFrom != account) revert NotTheAccount(composeFrom, account);
        CrossAccounts.requireVacant(account, b.owner, b.salt);
    }

    /// @dev Before the account has code: an address with none accepts value without running
    ///      anything, and the bootstrap calls the receiver runs when armed can spend it.
    function _forwardValue(address account) private {
        if (msg.value != 0) {
            // forge-lint: disable-next-line(arbitrary-send-eth) the account the compose was proven for
            (bool ok,) = account.call{value: msg.value}("");
            if (!ok) revert ValueNotForwarded(account);
        }
    }

    /* ================================== leaves ================================= */

    function _homeEid(address homeOft) private view returns (uint32) {
        if (homeOft.code.length == 0) revert NotAnOft(homeOft);
        ILayerZeroEndpointV2 endpoint = IOAppCore(homeOft).endpoint();
        if (address(endpoint).code.length == 0) revert NotAnOft(homeOft);
        return endpoint.eid();
    }

    function _checkLeaves(address homeOft, uint32 homeEid, Leaf[] calldata leaves)
        private
        view
        returns (bytes32[] memory hashes)
    {
        if (leaves.length == 0) revert NoDestinations();
        hashes = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; ++i) {
            Leaf calldata l = leaves[i];
            if (i != 0 && l.chainKey <= leaves[i - 1].chainKey) revert LeavesNotSorted(i);
            if (l.chainKey == localChainKey || l.eid == 0 || l.eid == homeEid || l.oft == address(0)) {
                revert BadLeaf(i);
            }
            LzOftMessage.requirePeer(homeOft, l.eid, l.oft);
            hashes[i] = LzOftMessage.leaf(l.chainKey, l.eid, l.oft);
        }
    }
}
