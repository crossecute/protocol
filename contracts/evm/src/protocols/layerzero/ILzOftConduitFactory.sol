// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The `layerzero-oft` factory as operators, relayers and its conduits use it: conduit
///         creation, the inputs a conduit's address commits to, and each committed destination.
interface ILzOftConduitFactory {
    /// @notice A destination as the operator lists it at creation. Its `LzOftConduitAddress.leafHash`
    ///         is a leaf of the conduit's `destRoot`.
    struct Destination {
        bytes32 chainKey;
        uint32 eid;
        address oft;
    }

    event TransmitterCreated(
        address indexed owner, address indexed conduit, bytes32 salt, uint32 homeEid, address homeOft, bytes32 destRoot
    );
    event ReceiverCreated(address indexed conduit, uint32 homeEid, address localOft);
    event SignedConduitCreated(address indexed conduit);

    error NoImplementation();
    error NoTreasury();
    error NotAnOft(address oft);
    error NoDestinations();
    /// @dev Destinations must be in strictly ascending `chainKey` order, which also refuses a repeat.
    error DestinationsNotSorted(uint256 index);
    /// @dev A zero eid or OFT, or the home chain's key or eid.
    error BadDestination(uint256 index);
    error NotADestination(address conduit, bytes32 chainKey);
    error UnknownConduit(address conduit);
    error NotTheEndpoint(address caller);
    error NotTheHomeEid(uint32 srcEid, uint32 homeEid);
    error NotInRoot(bytes32 leafHash);
    error NotTheConduit(address composeFrom, address conduit);
    error ValueNotForwarded(address conduit);
    /// @dev The compose carries `Call[]`, which only an EVM chain's factory decodes.
    error NotAnEvmChain(bytes32 chainKey);
    error WrongBootstrapMode();
    error HomeChainMismatch(uint256 sourceChainId, bytes32 homeChainKey);
    /// @dev The OFT no longer names `expected` as its peer for `eid`: raised at creation, at each
    ///      send and at each delivery.
    error PeerChanged(uint32 eid, bytes32 expected, bytes32 actual);

    /// @notice Create the caller's conduit, homed on this chain, reaching exactly `destinations`.
    /// @dev The caller is the owner. `destinations` must be in strictly ascending `chainKey`
    ///      order, and each must be a peer of `homeOft`. Signed mode is fixed here from the
    ///      caller's guard.
    function createTransmitter(bytes32 salt, address homeOft, Destination[] calldata destinations)
        external
        returns (address conduit);

    /// @notice The salt a conduit is CREATE2'd at; `LzOftConduitAddress.conduitSalt`.
    function conduitSalt(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 destRoot
    ) external pure returns (bytes32);

    /// @notice The conduit address committed to these creation inputs, on every chain.
    function predictConduit(
        address owner,
        bytes32 salt,
        bytes32 homeChainKey,
        uint32 homeEid,
        address homeOft,
        bytes32 destRoot
    ) external view returns (address);

    /// @notice The eid and OFT `conduit` reaches `chainKey` through, as it was created with.
    /// @dev Reverts for a chain the conduit was not created with.
    function destinationOf(address conduit, bytes32 chainKey) external view returns (uint32 eid, address oft);

    /// @notice The destination and proof a bootstrap from `conduit` to `chainKey` carries, with
    ///         the home eid and root bound into the conduit's address.
    /// @dev Reverts for a chain the conduit was not created with.
    function bootstrapRoute(address conduit, bytes32 chainKey)
        external
        view
        returns (uint32 eid, address dstOft, uint32 homeEid, bytes32 destRoot, bytes32[] memory proof);

    /// @notice Whether `conduit` was created here in signed mode.
    function isSigned(address conduit) external view returns (bool);

    function transmitterImplementation() external view returns (address);

    function receiverImplementation() external view returns (address);

    function treasury() external view returns (address);

    /// @notice This chain's key, which a conduit created here commits to as its home.
    function localChainKey() external view returns (bytes32);

    /// @notice The Proxy initcode hash every conduit address is derived from.
    function PROXY_INIT_CODE_HASH() external view returns (bytes32);

    /// @notice Leading word of a signed bootstrap's compose message.
    function SIGNED_BOOTSTRAP() external view returns (uint256);
}

/// @notice Bootstrap transport for a signed OFT conduit; the conduit remains the OFT sender.
interface ILzOftSignedConduitFactory is ILzOftConduitFactory {
    /// @notice Encode the calling conduit's signed bootstrap and its destination factory route.
    /// @dev Quote and send use identical bytes without making the factory the composeFrom.
    function signedConduitBootstrap(bytes calldata route, bytes calldata body)
        external
        view
        returns (bytes memory recipient, bytes memory message);
}
