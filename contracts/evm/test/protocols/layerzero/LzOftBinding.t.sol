// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProviderWideSenderSpec, ProviderTransmitterSpec} from "test/protocols/ProviderBindingSpec.t.sol";
import {LzOftFixture} from "test/protocols/layerzero/LzOftFixture.sol";

/// @dev `layerzero-oft` runs the account specs; it has no transceiver for the others.
contract LzOftReceiveTest is ProviderWideSenderSpec, LzOftFixture {}

contract LzOftTransmitterInboundTest is ProviderTransmitterSpec, LzOftFixture {}
