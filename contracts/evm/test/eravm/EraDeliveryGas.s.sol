// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";

import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {ZkSyncTransceiverExtension} from "src/messaging/transceiver/DivergentTransceiver.sol";
import {TransceiverExtension} from "src/messaging/transceiver/TransceiverExtension.sol";
import {HyperlaneZkSyncTransceiver} from "src/protocols/hyperlane/HyperlaneDivergentTransceiver.sol";
import {HyperlaneTransceiverBase} from "src/protocols/hyperlane/HyperlaneTransceiver.sol";
import {HyperlaneDeploy} from "script/deploy/HyperlaneDeploy.sol";
import {ChainRegistry} from "src/registry/ChainRegistry.sol";
import {IChainRegistryRefs} from "src/registry/IChainRegistryRefs.sol";
import {Provenance} from "src/registry/Provenance.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {ChainKey} from "src/addressing/ChainKey.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {Payload} from "src/messaging/Payload.sol";
import {Call} from "src/messaging/Call.sol";

import {MockHyperlaneMailbox} from "test/protocols/hyperlane/MockHyperlaneMailbox.sol";
import {transceiverConfig, toBytes32} from "test/Harness.sol";
import {unseeded} from "test/RegistrySeed.sol";

/// @notice The Hyperlane mock, also delivering with a set gas limit, as a relayer's executor does.
contract GasLimitedMailbox is MockHyperlaneMailbox {
    function deliver(address to, uint32 origin, bytes32 sender, bytes calldata message, uint256 gasLimit) external {
        IMessageRecipient(to).handle{gas: gasLimit}(origin, sender, message);
    }
}

interface IAccountCodeStorage {
    function getRawCodeHash(address account) external view returns (bytes32);
}

/// @notice Deploys a Hyperlane zkSync transceiver, with the mock mailbox as its gateway, for
///         `era-delivery-gas.sh` to measure deliveries on an EraVM node. Run with
///         `forge script --zk-compile`; under solc the account guard refuses every bootstrap.
/// @dev Deployed with `new CrossProxy()` and the admin call rather than `CrossProxyDeployer`,
///      whose raw-initcode CREATE2 EraVM cannot run. Neither changes what a delivery costs.
contract EraDeliveryGas is Script {
    uint32 internal constant HOME_DOMAIN = 8453;
    address internal constant HOME_TRANSCEIVER = address(0xC0DE);
    address internal constant ACCOUNT_CODE_STORAGE = address(0x8002);

    function run() external {
        vm.startBroadcast();
        GasLimitedMailbox mailbox = new GasLimitedMailbox();
        address extension = address(new ZkSyncTransceiverExtension());
        address implementation = address(new HyperlaneZkSyncTransceiver(address(mailbox), extension));
        address receiverImplementation = HyperlaneDeploy.receiverImplementation(address(mailbox));

        // The versioned hash EraVM's deployer keys accounts by, read from a deployed copy.
        bytes32 accountBytecodeHash =
            IAccountCodeStorage(ACCOUNT_CODE_STORAGE).getRawCodeHash(address(new CrossProxy()));

        (, address deployer,) = vm.readCallers();
        ChainRegistry registry = new ChainRegistry(deployer, unseeded());
        bytes32 provider = registry.addMessageProvider("hyperlane");
        bytes32 home = registry.addChainKey(Erc7930.encodeEvmChain(HOME_DOMAIN), Provenance.Unique);

        address t = address(new CrossProxy());
        ICrossProxy(t)
            .upgradeInitializeAndLock(
                implementation,
                abi.encodeCall(
                    HyperlaneZkSyncTransceiver.initialize,
                    (transceiverConfig(receiverImplementation), 0, accountBytecodeHash)
                )
            );
        // The float that pays each bootstrap's report.
        (bool ok,) = t.call{value: 1 ether}("");
        require(ok, "float");
        vm.stopBroadcast();

        console.log("mailbox", address(mailbox));
        console.log("transceiver", t);
        console.log("accountBytecodeHash");
        console.logBytes32(accountBytecodeHash);

        // The owner's calls, which the runner sends from the impersonated owner.
        console.log("ownerCalls");
        console.logBytes(
            abi.encodeCall(
                TransceiverExtension.setRouting, (IChainRegistryRefs(address(registry)), provider, Provenance.Unique)
            )
        );
        console.logBytes(abi.encodeCall(TransceiverExtension.setRoute, (home, Erc7930.encodeEvmChain(HOME_DOMAIN))));
        console.logBytes(
            abi.encodeCall(
                TransceiverExtension.setCounterpart, (home, Erc7930.encodeEvm(HOME_DOMAIN, HOME_TRANSCEIVER))
            )
        );
        console.logBytes(
            abi.encodeCall(HyperlaneTransceiverBase.setDomain, (ChainKey.forEvm(HOME_DOMAIN), HOME_DOMAIN))
        );

        // Two bootstraps for fresh owners, so each creates an account against cold storage, and
        // a payload for the first one's receiver once it exists.
        console.log("messages");
        console.logBytes(_bootstrap(address(0xA110), address(mailbox), 0));
        console.logBytes(_bootstrap(address(0xA111), address(mailbox), 1));
        console.logBytes(Payload.encodeCalls(new Call[](0)));
        console.logBytes32(home);
    }

    /// @notice A bootstrap for `owner`'s account from the home's transmitter `0x7A11`, with
    ///         `callCount` calls to the mailbox's `fee()`. A fresh `owner` keeps storage cold.
    function _bootstrap(address owner, address mailbox, uint256 callCount) internal pure returns (bytes memory) {
        Call[] memory calls = new Call[](callCount);
        for (uint256 i; i < callCount; ++i) {
            calls[i] = Call({target: mailbox, value: 0, data: abi.encodeWithSignature("fee()")});
        }
        return Envelope.encodeBootstrap(owner, bytes32(0), toBytes32(address(0x7A11)), calls);
    }
}
