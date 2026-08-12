// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {HubTransceiverBase} from "src/messaging/transceiver/HubTransceiverBase.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice The transceiver on the home chain. One instance, owned by the crossecute msig,
///         shared by every user's transmitter.
///
/// @dev IT CARRIES NO PROVIDER VOCABULARY AT ALL, AND THAT IS WHAT ERC-7786 BOUGHT. A
///      gateway takes a recipient that NAMES ITS OWN CHAIN, so there is nothing to translate
///      and the route slot holds that chain's ERC-7930 identifier, which `setRoute` is
///      already typed for. A native SDK binding would need a codec and a chainKey table of
///      its own, since `_lzSend` still takes a `uint32`.
///
/// @dev Does NOT inherit a transmitter. A transceiver is shared, msig-owned infrastructure
///      and a transmitter is per-user; merging them would give one contract two owners,
///      which is why `owner` and `onlyOwner` collide when you try.
contract LzHubTransceiver is HubTransceiverBase, OwnableUpgradeable {
    /// @dev NO RECEIVER IMPLEMENTATION, because a hub never makes a receiver. The
    ///      manufacturing half lives on the spoke; see `TransceiverBase`.
    function initialize(address owner_, address transmitterImplementation_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __HubTransceiverBase_init(transmitterImplementation_);
    }

    /// @notice Where the transceiver's `isAdmin` requirement is satisfied.
    function isAdmin(address who) public view override returns (bool) {
        return who == owner();
    }

    /// @notice Which gateway may carry this contract's messages. Satisfies `GatewayBound`.
    /// @dev UNANSWERED UNTIL A BINDING EXISTS, so it accepts nothing. There is no LayerZero
    ///      gateway behind this yet, and a base that guessed an address would be worse than
    ///      one that refuses. A real binding returns `instance == address(endpoint)`.
    function _isAuthorizedGateway(address) internal pure override returns (bool) {
        return false;
    }

}
