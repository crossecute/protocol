// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CcipConfig} from "src/protocols/ccip/CcipConfig.sol";
import {CcipMessage} from "src/protocols/ccip/CcipMessage.sol";

/// @notice Source-specific inbound security policy. Unset entries use CCIP defaults and full finality.
abstract contract CcipPolicy {
    error InvalidCcipPolicy();
    event CcipPolicySet(uint64 indexed source, bytes sender, CcipConfig.Policy policy);

    /// @dev Changes apply when CCIP reads the policy, including for messages already in flight.
    ///      Include address(0) among requiredCCVs to retain lane-default verification alongside custom CCVs.
    function setCcipPolicy(uint64 source, bytes calldata sender, CcipConfig.Policy memory policy) external {
        if (source == 0 || sender.length != 32) revert InvalidCcipPolicy();
        address evmSender = CcipMessage.sender(sender);
        if (evmSender == address(0)) revert InvalidCcipPolicy();
        _authorizeCcipPolicyChange(source, evmSender);
        uint256 required = policy.requiredCCVs.length;
        uint256 optional = policy.optionalCCVs.length;
        if (
            policy.optionalThreshold > optional || (optional != 0 && policy.optionalThreshold == 0)
                || (uint32(policy.allowedFinalityConfig) & 0xfffe0000) != 0
        ) revert InvalidCcipPolicy();
        address[] memory ccvs = new address[](required + optional);
        for (uint256 i; i < ccvs.length; ++i) {
            ccvs[i] = i < required ? policy.requiredCCVs[i] : policy.optionalCCVs[i - required];
            if (i >= required && ccvs[i] == address(0)) revert InvalidCcipPolicy();
        }
        CcipConfig.validateCCVs(ccvs);
        CcipConfig.layout().policies[CcipConfig.policyKey(source, sender)] = policy;
        emit CcipPolicySet(source, sender, policy);
    }

    function getCCVsAndFinalityConfig(uint64 source, bytes calldata sender)
        public
        view
        virtual
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        )
    {
        CcipConfig.Policy storage policy = CcipConfig.layout().policies[CcipConfig.policyKey(source, sender)];
        return (policy.requiredCCVs, policy.optionalCCVs, policy.optionalThreshold, policy.allowedFinalityConfig);
    }

    /// @dev Reverts unless the caller may set a policy for this source and sender.
    function _authorizeCcipPolicyChange(uint64 source, address sender) internal view virtual;
}
