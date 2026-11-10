// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice What a transmitter consumes from the guard, and what a relayer reads from it.
///         Compatible guards advertise this interface through ERC-165.
/// @dev Free of policy-engine imports so the protocol's 0.8.28 transmitters can import it. Each
///      `operation` is Safe's `Enum.Operation` as a `uint8`: 0 for CALL, 1 for DELEGATECALL.
///      `safeTxGas` and `gasPrice` are always zero, which the inherited policy check requires.
interface ICrossecuteGuard {
    /// @notice Safe 1.5.0's EIP-712 `SafeTx`, in its field order and types. Safe declares the type
    ///         only as a type hash, so the guard, transmitter and receiver share this declaration.
    struct SafeTx {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
        uint256 nonce;
    }

    /// @notice A Safe transaction and signatures over it. `consume` and `getApproval` each say what
    ///         `signatures` holds.
    struct SignedSafeTx {
        SafeTx safeTx;
        bytes signatures;
    }

    event ApprovalCached(address indexed childSafe, bytes32 indexed messageHash);
    /// @notice One per leaf of a `publishLeaves` call, in leaf order. The leaf bytes are in that
    ///         call's calldata at `index`.
    event LeafPublished(bytes32 indexed root, bytes32 indexed leafHash, uint256 index);

    error NoLiveRecord(address safe);
    error NotSignedTarget(address caller);
    error AlreadyConsumed(address safe);
    error NestedExecution(address safe);
    error HashMismatch(bytes32 live, bytes32 txHash);
    error ModuleStagingDenied(bytes4 selector);
    error ApprovalNotFound(address childSafe, bytes32 messageHash);
    error SignatureExtensionOverlap();
    error NoLeaves();
    error RootNotPublished(bytes32 root);

    /// @notice Marks `safe`'s live staged record, from a `sendMessage` or `registerRoot` owner
    ///         transaction, consumed and returns it. Only the signed target may call, once per
    ///         record.
    /// @return signedSafeTx The signed transaction with `data` empty: the caller is the signed target
    ///         and received that calldata from the Safe, so it sets `data` to its own `msg.data`.
    ///         `signatures` is the Safe hook's argument byte for byte. Safe checks only the first
    ///         threshold-many signatures; anything after them, the policy extension included, is as
    ///         the submitter sent it.
    function consume(address safe) external returns (SignedSafeTx memory signedSafeTx);

    /// @notice The current approval evidence `childSafe` cached for `messageHash`, the hash
    ///         `signMessage` writes into the child's `signedMessages`. Reverts if there is none.
    /// @return signedSafeTx The child's signed `signMessage` transaction. `signatures` is the child
    ///         owners' signatures without the child's policy extension.
    function getApproval(address childSafe, bytes32 messageHash)
        external
        view
        returns (SignedSafeTx memory signedSafeTx);

    /// @notice Records the Merkle root of `leaves` and emits `LeafPublished` for each. Anyone may
    ///         call, any number of times. Publication authorizes nothing: it only lets a Safe on
    ///         this guard execute `registerRoot` for the root.
    /// @dev Each element is a leaf's `abi.encode`d fields, which the guard does not decode. A leaf
    ///      hash is `keccak256(abi.encode(keccak256(leaf)))`. An internal node hashes its two children
    ///      smaller first. A level's unpaired last hash moves up unchanged. One leaf is its own root.
    /// @return root The tree's root.
    function publishLeaves(bytes[] calldata leaves) external returns (bytes32 root);

    /// @notice Whether `publishLeaves` has recorded `root` on this guard.
    function isPublished(bytes32 root) external view returns (bool);
}
