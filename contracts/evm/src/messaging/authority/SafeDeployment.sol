// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Safe 1.5.0's canonical deployment: safe-deployments lists this one address set on every network
// it covers (141 on 2026-11-15). Compiled in with no setter (X13); a source chain without it needs
// a new guard and registry generation.
address constant SAFE_PROXY_FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
address constant SAFE_SINGLETON = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b;
address constant SAFE_L2_SINGLETON = 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e;
address constant SAFE_TO_L2_SETUP = 0x900C7589200010D6C6eCaaE5B06EBe653bc2D82a;

// keccak256(proxyCreationCode() ++ uint256(singleton)): the CREATE2 initcode the factory deploys
// for each singleton, from the mainnet factory's proxyCreationCode().
bytes32 constant SAFE_PROXY_INITCODE_HASH = 0x9dd695a8d96e2c0f6ede304e13cc2efe754fa353b7389a23340c9317113bc975;
bytes32 constant SAFE_L2_PROXY_INITCODE_HASH = 0xc00f8ed2d8e1bacf9a81836a956d9be01fbb50416bce76c09d18859e6bb6d223;
