// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Call} from "src/messaging/Call.sol";
import {ReceiverBase} from "src/messaging/inbound/ReceiverBase.sol";
import {ProviderAddress} from "src/protocols/ProviderAddress.sol";
import {LzOftMessage} from "src/protocols/layerzero/LzOftMessage.sol";

/// @dev The initializer the factory arms a receiver with; `LzOftReceiver.initialize` is
///      overloaded, so it is named here for `abi.encodeCall`.
interface ILzOftReceiverInit {
    function initialize(
        address sourceTransmitter,
        uint32 homeEid,
        address homeOft,
        address localOft,
        Call[] calldata calls
    ) external;
}

/// @notice A `layerzero-oft` account on a destination: takes each message as an OFT compose,
///         from its operator's OFT here, sent by its transmitter through the OFT on its home.
///
/// @dev `lzCompose` authenticates, in order: the endpoint (`GATEWAY_ROLE`, so `revokeGateway`
///      can disconnect it), `_from` as this chain's OFT, the OFT still peering the home OFT,
///      and through `_onMessageFrom` the source eid as the home's and `composeFrom` as the
///      transmitter. `composeFrom` is `send`'s caller, which `OFTMsgCodec` writes and the
///      caller cannot set, and the OFT queues a compose only for a packet its own DVNs
///      verified from a peer.
contract LzOftReceiver is ReceiverBase, ILayerZeroComposer, ILzOftReceiverInit {
    /// @notice The OFT on this account's home, which this chain's OFT must still peer.
    address public homeOft;
    /// @notice This chain's OFT, the only `_from` accepted.
    address public localOft;

    error UseLzOftInitializer();
    error NotTheOft(address from);

    function initialize(address, bytes32, Call[] calldata) external pure override {
        revert UseLzOftInitializer();
    }

    /// @dev The factory proved `localOft_` into the account's root and checked its endpoint and
    ///      peer before calling this. The home is named by eid, as `srcEid` reports it.
    function initialize(
        address sourceTransmitter_,
        uint32 homeEid,
        // forge-lint: disable-next-line(missing-zero-check) the factory refuses a zero home OFT
        address homeOft_,
        // forge-lint: disable-next-line(missing-zero-check) the delivering OFT, proved by the factory
        address localOft_,
        Call[] calldata calls
    ) external override initializer {
        homeOft = homeOft_;
        localOft = localOft_;
        _grantInitialRole(GATEWAY_ROLE, address(IOAppCore(localOft_).endpoint()));
        __ReceiverBase_init(sourceTransmitter_, bytes32(uint256(homeEid)), calls);
    }

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
        _checkRole(GATEWAY_ROLE);
        if (_from != localOft) revert NotTheOft(_from);
        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        // forge-lint: disable-next-line(unsafe-typecast) homeOrigin holds a uint32 eid
        LzOftMessage.requirePeer(localOft, uint32(uint256(homeOrigin)), homeOft);
        _onMessageFrom(
            bytes32(uint256(srcEid)),
            ProviderAddress.evmSender(OFTComposeMsgCodec.composeFrom(_message)),
            _message[LzOftMessage.COMPOSE_MSG_OFFSET:]
        );
    }
}
