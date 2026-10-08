# Checking a chain

The checks that decide whether the protocol works on a chain, before anything is deployed
there. Run every one for a new chain, against every chain it will talk to, and repeat them
before mainnet for the chains already here: providers change their deployments and defaults.

Every check is a read (`eth_call`, `eth_getCode`, or the provider's own source), so none
spends gas. What only a real deployment can show is listed at the end.

The results below are from 2026-10-07, over these public RPCs:

| Chain | `chains.toml` | Chain id | Derivation | RPC |
| --- | --- | --- | --- | --- |
| Ethereum | `ethereum` | 1 | parity | `https://ethereum-rpc.publicnode.com` |
| Base | `base` | 8453 | parity | `https://base-rpc.publicnode.com` |
| Arbitrum One | `arbitrum` | 42161 | parity | `https://arbitrum-one-rpc.publicnode.com` |
| OP Mainnet | `optimism` | 10 | parity | `https://optimism-rpc.publicnode.com` |
| zkSync Era | `zksync` | 324 | zksync | `https://mainnet.era.zksync.io` |
| Tron | not listed | 728126428 | tron | `https://api.trongrid.io/jsonrpc` |

## Provider values

Provider ids are written once into every transceiver, so the files under
[`providers/`](providers) are their source of truth, and `forge test` checks their shape
(README §3). The endpoint addresses are environment inputs to each `Deploy<Provider>.s.sol`
and are recorded only here. Each was read from the source named and then confirmed on chain.

**LayerZero V2.** Source: `https://metadata.layerzero-api.com/v1/metadata/deployments`.

| Chain | eid | `LZ_ENDPOINT` (EndpointV2) |
| --- | --- | --- |
| ethereum | 30101 | `0x1a44076050125825900e736c501f859c50fE728c` |
| base | 30184 | `0x1a44076050125825900e736c501f859c50fE728c` |
| arbitrum | 30110 | `0x1a44076050125825900e736c501f859c50fE728c` |
| optimism | 30111 | `0x1a44076050125825900e736c501f859c50fE728c` |
| zksync | 30165 | `0xd07C30aF3Ff30D96BDc9c6044958230Eb797DDBF` |

**CCIP.** Source: `smartcontractkit/documentation`,
`src/config/data/ccip/v1_2_0/mainnet/chains.json`.

| Chain | Selector | `CCIP_ROUTER` |
| --- | --- | --- |
| ethereum | 5009297550715157269 | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` |
| base | 15971525489660198786 | `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD` |
| arbitrum | 4949039107694359620 | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` |
| optimism | 3734403246176062136 | `0x3206695CaE29952f4b0c22a169725a865bc8Ce0f` |
| zksync | 1562403441176082196 | `0x748Fd769d81F5D94752bf8B0875E9301d0ba71bB` |

**Hyperlane.** Source: `hyperlane-xyz/hyperlane-registry`, `chains/<name>/addresses.yaml`.
The default ISM is read from the Mailbox, not the registry, which lists a different one for
zkSync.

| Chain | Domain | `HYPERLANE_MAILBOX` | `defaultIsm()` |
| --- | --- | --- | --- |
| ethereum | 1 | `0xc005dc82818d67AF737725bD4bf75435d065D239` | `0xDD0998A3533b137a3520bca7c0Fb0b4F5886Ae82` |
| base | 8453 | `0xeA87ae93Fa0019a82A727bfd3eBd1cFCa8f64f1D` | `0x0C53271f445D5f0Cd1C7388f04A8C2EC55cf88b9` |
| arbitrum | 42161 | `0x979Ca5202784112f4738403dBec5D0F3B9daabB9` | `0x9E1cB2258BaCBb5fe36CCcC5b5F9a7fD8dEC2051` |
| optimism | 10 | `0xd4C1905BB1D26BC93DAC913e13CaCC278CdCC80D` | `0x5EBdc44365FEb72ab99FE76Bdd0c47D0bd674c21` |
| zksync | 324 | `0x6bD0A2214797Bc81e0b006F7B74d6221BcD8cb6E` | `0xf55CB3c8C4b20276AF9F979B0D94Bd7ae5487fa2` |

**Wormhole.** Source: `wormhole-foundation/wormhole-solidity-sdk`,
`src/testing/ChainConsts.sol` (a36ed90c). zkSync Era has no Wormhole chain id or Core bridge.

| Chain | Chain id | `WORMHOLE_CORE` | Executor | `WORMHOLE_EXECUTOR_ROUTER` |
| --- | --- | --- | --- | --- |
| ethereum | 2 | `0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B` | `0x84EEe8dBa37C36947397E1E11251cA9A06Fc6F8a` | none (#53) |
| base | 30 | `0xbebdb6C8ddC678FfA9f8748f85C815C556Dd8ac6` | `0x9E1936E91A4a5AE5A5F75fFc472D6cb8e93597ea` | none (#53) |
| arbitrum | 23 | `0xa5f208e072434bC67592E4C49C1B991BA79BCA46` | `0x3980f8318fc03d79033Bbb421A622CDF8d2Eeab4` | none (#53) |
| optimism | 24 | `0xEe91C335eab126dF5fDB3797EA9d6aD93aeC9722` | `0x85B704501f6AE718205C0636260768C4e72ac3e7` | none (#53) |

**op-stack-l1-l2.** In [`providers/op-stack-l1-l2.toml`](providers/op-stack-l1-l2.toml): on
Ethereum, Base's `L1CrossDomainMessenger` is `0x866E82a600A1414e583f7F13623F1aC5d58b0Afa` and
OP Mainnet's is `0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1`; on each L2, the predeploy
`0x4200000000000000000000000000000000000007`.

## The checks

Commands assume `RPC` is the chain's RPC and Foundry's `cast` is on the path.

### 1. Contracts land where the protocol expects

A parity chain needs Arachnid's factory with Ethereum's code, and `CrossProxyDeployer`'s address
free until the deploy:

```sh
cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url $RPC | cast keccak   # equals Ethereum's
cast code 0x49731f3c3b6Fbdb54f6c2d7614cAdd7957A8249C --rpc-url $RPC                 # 0x until deployed
```

Code at Arachnid's address does not make a chain parity: zkSync Era has it too (README §1).

For a zkSync or Tron chain, the account formula must match the chain's own. On zkSync Era,
`ContractDeployer` computes it for any inputs, and `AddressDerive.zksyncCreate2` must agree:

```sh
cast call 0x0000000000000000000000000000000000008006 \
  "getNewAddressCreate2(address,bytes32,bytes32,bytes)(address)" <sender> <bytecodeHash> <salt> 0x --rpc-url $RPC
```

Tron has no such view, so the check is java-tron's source: `Program.createContract2` derives
from `WalletUtil.generateContractAddress2(getContextAddress(), salt, code)`, which is
`keccak256(0x41 ‖ sender ‖ salt ‖ keccak256(code))` because a context address is the 21-byte
Tron form. That is `AddressDerive.tronCreate2`. Before `allowTvmIstanbul` it used the caller
instead; mainnet has it on (`wallet/getchainparameters`).

Results: Arachnid's factory matches on all five EVM chains and is absent on Tron and Shasta;
the deployer's address is empty on all five. zkSync's formula matched `ContractDeployer` on
mainnet. Tron's matches the source. What neither shows is the account bytecode hash each
transceiver is born with (`accountBytecodeHash`), which comes from zksolc and TRON-solc.

### 2. EIP-152, if the chain may compute BLAKE2b commitments

`Blake2b256` calls the F function at `0x09`. Call it for BLAKE2b-256(`"abc"`), one final
block, and compare with any other implementation
(`bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319`):

```sh
cast call 0x0000000000000000000000000000000000000009 --rpc-url $RPC 0x0000000c28c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b6162630000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001
```

The first 32 bytes of the 64 returned must equal the digest.

Results: correct on Ethereum, Base, Arbitrum, and OP Mainnet. zkSync Era reverts. On Tron,
`0x09` is `BatchValidateSign`; java-tron puts BLAKE2F at `0x020009`, behind
`allowTvmCompatibleEvm`, which is off on mainnet. `Blake2b256` fails closed on both, because
it requires a 64-byte return.

### 3. Lanes

For each provider, every pair the chain will use must quote, and a pair the provider does not
connect should revert at the quote. The configured pairs, checked 2026-10-07:

| Provider | Configured pairs that quote | A pair with no lane |
| --- | --- | --- |
| LayerZero | all 12 among the four parity chains, with `lzReceive` options at 200,000 and 1,000,000 gas; empty options revert on all 20 (#50, why the binding never sends them) | zkSync pairs revert at quote for the dead-DVN default (#51) |
| CCIP | all 20 | reverts `UnsupportedDestinationChain` (`0xae236d9c`) |
| Hyperlane | all 20 | the Mailbox quotes 0; the binding refuses that quote and the send (#56) |
| Wormhole | not quotable: no quoter router (#53) | |
| op-stack-l1-l2 | Ethereum to Base and OP Mainnet and back; nothing to quote | |

```sh
# LayerZero: options must be non-empty; this is type 3 with lzReceive gas 200,000
cast call $LZ_ENDPOINT "quote((uint32,bytes32,bytes,bytes,bool),address)((uint256,uint256))" \
  "(<dstEid>,<receiver32>,0x00,0x00030100110100000000000000000000000000030d40,false)" <sender> --rpc-url $RPC
# CCIP
cast call $CCIP_ROUTER "isChainSupported(uint64)(bool)" <selector> --rpc-url $RPC
cast call $CCIP_ROUTER "getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))(uint256)" \
  <selector> "(<abi.encode(receiver)>,0x00,[],0x0000000000000000000000000000000000000000,0x)" --rpc-url $RPC
# Hyperlane: hook metadata variant 1, gas limit 50,000, refund address
cast call $HYPERLANE_MAILBOX "quoteDispatch(uint32,bytes32,bytes,bytes)(uint256)" <domain> <receiver32> 0x00 \
  0x0001<uint256 msgValue><uint256 gasLimit><address refund> --rpc-url $RPC
```

A Hyperlane quote of 0 is a missing lane, and the binding refuses it (`NoHyperlaneRoute`). The Mailbox's default hook is a fallback-routing
hook; a domain with no route falls back to the Merkle tree hook alone, which charges nothing
and pays no relayer, so the dispatch would succeed and never be delivered. The IGP itself
reverts `IGP: no gas oracle for domain` for such a domain.

### 4. Destination gas

A bootstrap creates an account on the destination, so the gas it is sent with must cover
that. Measured with the provider fixtures (mock gateways, cold storage):

| Delivery | Gas |
| --- | --- |
| Bootstrap to a plain transceiver, no calls | 589,000 to 641,000 by binding |
| The same with one call | 597,000 to 649,000 |
| Report arriving at the home transceiver | up to about 135,000 |
| Payload to an existing receiver | under 16,000 plus its calls |

Without a gas attribute every binding sends `DeliveryGas`: 1,000,000 for a bootstrap,
250,000 for a report, 200,000 for a payload (#52). CCIP, LayerZero, and Hyperlane quote
1,000,000 on every configured pair; CCIP refuses 3,000,000 toward zkSync, so a caller's own
attribute can exceed a lane's cap. EraVM prices differently and Forge cannot measure it;
zkSync needs its own number.

### 5. Verification on the destination

Hyperlane: the destination Mailbox's ISM decides what is verified for each origin. Walk it
per origin: `moduleType()` 1 is routing (`route(message)`), 2 aggregation
(`modulesAndThreshold(message)`), 4 and 5 multisig (`validatorsAndThreshold(message)`). The
message only needs its origin field set.

Results: on Ethereum, Base, Arbitrum, and OP Mainnet the default ISM is a 2-of-2 aggregation
of a pausable `NULL` module and a per-origin route to a 1-of-2 aggregation of a Merkle-root and
a message-id multisig. zkSync routes straight to a message-id multisig. Thresholds per origin:

| Destination ← origin | Validators |
| --- | --- |
| any ← ethereum | 6 of 9 |
| any ← base, arbitrum, optimism | 3 of 5 (zkSync ← optimism: 4 of 6) |
| any ← zksync | 2 of 3 |

The Mailbox owner can change any of this. The binding implements no ISM of its own
(`HyperlaneReceiver`).

LayerZero: the OApp's DVNs and executor are the endpoint defaults, which LayerZero sets, and
every pathway touching zkSync defaults to a dead DVN. The transceiver is its own delegate with
no way to call `setConfig` (#51).

### 6. OP Stack messengers pair up

On each L2, `L2CrossDomainMessenger.OTHER_MESSENGER()` must be the L1 messenger in
`op-stack-l1-l2.toml`, and that one's `OTHER_MESSENGER()` must be `0x4200…0007`:

```sh
cast call 0x4200000000000000000000000000000000000007 "OTHER_MESSENGER()(address)" --rpc-url $L2_RPC
cast call <l1Messenger> "OTHER_MESSENGER()(address)" --rpc-url $L1_RPC
```

Results: Base and OP Mainnet both pair with their listed L1 messengers. Arbitrum and zkSync
have no code at the predeploy, as expected.

## What these checks do not cover

- That an account deploys where `ZkSyncAccounts` and `TronAccounts` predict, with the real
  zksolc and TRON-solc artifacts. It needs one funded deployment per chain.
- End-to-end delivery through each provider's real relayers. Fork tests can cover the
  contracts for free ([todo §3](../../../docs/todo.md#3-infrastructure)); the off-chain
  relaying needs a real send.
- Float sizing for reporting chains, which depends on traffic.
