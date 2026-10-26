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
`src/testing/ChainConsts.sol` (a36ed90c). Each Executor answered its own chain id from
`ourChain()` and `Executor-0.0.1` from `EXECUTOR_VERSION()` on 2026-10-08. Wormhole has no
chain id for zkSync Era or Tron.

| Chain | Chain id | `WORMHOLE_CORE` | `WORMHOLE_EXECUTOR` |
| --- | --- | --- | --- |
| ethereum | 2 | `0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B` | `0x84EEe8dBa37C36947397E1E11251cA9A06Fc6F8a` |
| base | 30 | `0xbebdb6C8ddC678FfA9f8748f85C815C556Dd8ac6` | `0x9E1936E91A4a5AE5A5F75fFc472D6cb8e93597ea` |
| arbitrum | 23 | `0xa5f208e072434bC67592E4C49C1B991BA79BCA46` | `0x3980f8318fc03d79033Bbb421A622CDF8d2Eeab4` |
| optimism | 24 | `0xEe91C335eab126dF5fDB3797EA9d6aD93aeC9722` | `0x85B704501f6AE718205C0636260768C4e72ac3e7` |

A Wormhole send carries a relay provider's signed quote, from
`POST https://executor.labsapis.com/v0/quote` with `srcChain`, `dstChain`, and
`relayInstructions`. It expires an hour after it is issued. `GET /v0/capabilities` lists the
chains each request type is served on; all four here serve `ERV1` (VAA v1). A publish-only
send needs no quote: its signed VAA is at
`GET https://api.wormholescan.io/api/v1/vaas/{chain}/{emitter}/{sequence}` (base64 `vaa`;
listing by chain answered on 2026-10-13), for anyone to pass to `executeVAAv1`.

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
block of EIP-152's 213-byte input, and compare with any other implementation
(`bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319`):

```sh
cast call 0x0000000000000000000000000000000000000009 --rpc-url $RPC 0x0000000c28c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001
```

The first 32 bytes of the 64 returned must equal the digest.

Results, rerun on 2026-10-25 with this 213-byte input (an earlier one was 211 bytes, #93):
correct on Ethereum, Base, Arbitrum, and OP Mainnet. zkSync Era reverts. On Tron,
`0x09` is `BatchValidateSign`; java-tron puts BLAKE2F at `0x020009`, behind
`allowTvmCompatibleEvm`, which is off on mainnet. `Blake2b256` fails closed on both, because
it requires a 64-byte return.

### 3. Lanes

For each provider, every pair the chain will use must quote, and a pair the provider does not
connect should revert at the quote. The configured pairs, checked 2026-10-07:

| Provider | Configured pairs that quote | A pair with no lane |
| --- | --- | --- |
| LayerZero | all 12 among the four parity chains, with `lzReceive` options at 200,000 and 1,000,000 gas; empty options revert on all 20 (#50, why the binding never sends them); Ethereum to zkSync once LayerZero Labs' DVN is pinned (`test/fork/LzDvnFork.t.sol`) | zkSync pairs revert at quote on the dead-DVN default until a DVN is pinned (#51) |
| CCIP | all 20 | reverts `UnsupportedDestinationChain` (`0xae236d9c`) |
| Hyperlane | all 20 | the Mailbox quotes 0; the binding refuses that quote and the send (#56) |
| Wormhole | Ethereum to Base priced on chain at the API's `estimatedCost` exactly (`test_aLiveQuoteIsPricedAsTheExecutorApiPricesIt`); the API quotes any pair it lists | the API refuses a pair it does not serve, and the binding a quote for another pair (`QuoteForAnotherRoute`) |
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
that. `ProviderDeliveryGasSpec` (`test/protocols/ProviderBindingSpec.t.sol`) measures each
delivery through every binding's fixture with `DeliveryGasMeter`, and fails if a `DeliveryGas`
default is not at least 10% above it; `forge test --mc DeliveryGasTest -vv` prints the numbers.
Each is the smallest gas limit under which the delivery succeeds from cold storage, less what
the same message costs delivered to a contract that does nothing:

| Delivery | CCIP | Hyperlane | LayerZero | OP Stack | Wormhole |
| --- | --- | --- | --- | --- | --- |
| Bootstrap to a plain transceiver, no calls | 624,484 | 623,943 | 678,164 | 629,844 | 668,001 |
| The same with one call to an address with no code | 631,141 | 630,606 | 684,818 | 636,605 | 675,771 |
| Report arriving at the home transceiver | 127,263 | 126,730 | 127,381 | 124,485 | n/a (170,877) |
| Payload to an existing receiver, no calls | 24,891 | 24,382 | 27,612 | 23,171 | 67,651 |

Measured 2026-10-25 against mock gateways. Wormhole's numbers include verifying the VAA
and recording it consumed, inside the receiver; its mock Core checks no guardian signatures,
so a real delivery costs more. A payload's default also pays for the caller's calls, so the
row is only the receiver's share. Wormhole reaches no reporting chain, so it never carries a
report; the spec measures one there only because it runs every delivery on every binding.

`layerzero-oft` has no transceiver, so `LzOftDeliveryGasTest` measures it with the same meter
(`forge test --mc LzOftDeliveryGasTest -vv`). Its defaults are lzCompose gas, the factory's or
the receiver's frame; the OFT's own lzReceive gas is the operator's enforced options:

| Delivery, `layerzero-oft` | Gas |
| --- | --- |
| Bootstrap to the factory, 1 destination, no calls | 651,291 |
| Bootstrap to the factory, 8 destinations, one call | 659,121 |
| Payload to an existing receiver, no calls | 34,246 |

Measured 2026-10-25 against the mock endpoint and OFT. `LzOftForkDeliveryGasTest`
(`test/fork/LzOftFork.t.sol`) measures the same way through frxUSD, homed on Fraxtal, on a fork
of each destination: lzCompose through the real `EndpointV2` into the factory or the receiver,
and the real OFT's `lzReceive` frame against the lzReceive gas the Fraxtal lockbox enforces for
a send with a compose message (250,000 to both):

| Delivery through frxUSD, from Fraxtal, no calls | Ethereum | Arbitrum |
| --- | --- | --- |
| Bootstrap, lzCompose into the factory, 2 destinations | 649,133 | 649,218 |
| Bootstrap, the OFT's `lzReceive` | 105,826 | 85,369 |
| Payload, lzCompose into the receiver | 42,138 | 42,081 |
| Payload, the OFT's `lzReceive` | 97,337 | 76,878 |

Measured 2026-10-25. A payload costs about 7,900 more than against the mocks and a bootstrap
about 2,100 less; each stays well under its default. The `lzReceive` figure leaves out the
endpoint's clearing of the verified payload around it.

Without a gas attribute every binding sends `DeliveryGas`: 1,000,000 for a bootstrap,
250,000 for a report, 200,000 for a payload (#52). CCIP, LayerZero, and Hyperlane quote
1,000,000 on every configured pair; CCIP refuses 3,000,000 toward zkSync, so a caller's own
attribute can exceed a lane's cap. Nothing checks an attribute against these measurements:
one below them makes the delivery revert, and it is retried with more gas
([provider-spec R1.5](../../../docs/provider-spec.md#r1-send)).

EraVM prices differently and Forge cannot run it, so zkSync is measured on a local node by
`test/eravm/era-delivery-gas.sh`. Each number is the smallest gas limit on the call into
`handle` under which the delivery succeeds, found by `eth_call` against one cold state:

| Delivery to a Hyperlane zkSync transceiver | Gas |
| --- | --- |
| Bootstrap, no calls | 384,948 |
| Bootstrap, one call | 388,793 |
| Payload to an existing receiver, no calls | 30,211 |

Measured 2026-10-20 on anvil-zksync 0.7.1 (protocol version 30), built by foundry-zksync
0.1.10 with zksolc 1.5.15 over era-solc 0.8.28-1.0.1 at its default settings. The bootstrap
includes its report, sent through the mock mailbox, and its reads from a real `ChainRegistry`.
A stub doing the same storage reads, used before zksolc could build the registry (#82), came
in 8,301 lower on each bootstrap.

These are execution only. The node publishes no pubdata (0 bytes at any
`--l1-pubdata-price`), so what a bootstrap's storage writes cost in pubdata, and whether that
counts against the call's gas limit, needs zkSync Sepolia. A report arriving at a zkSync home
is not measured.

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

LayerZero: an OApp follows the endpoint's default DVNs and executor, which LayerZero sets,
except where a DVN is pinned. Every pathway touching zkSync defaults to the dead DVN, so both
ends pin LayerZero Labs' DVN alone (#51):

- each transceiver, by `setDvn(eid, dvn)` with its own chain's DVN, write-once; a zkSync
  transceiver is born with it for the governor home's eid (`LZ_GOVERNOR_HOME_DVN`);
- each receiver, at creation, for its home's eid, from its transceiver;
- each transmitter that sends to zkSync, by its owner, after naming itself delegate.

LayerZero Labs' messaging DVN on each chain (metadata API, 2026-10-07; not the lzRead one):

| Chain | DVN |
| --- | --- |
| ethereum | `0x589dEDbD617e0CBcB916A9223F4d1300c294236b` |
| base | `0x9e059a54699a285714207b43b055483e78faac25` |
| arbitrum | `0x2f55c492897526677c5b68fb199ea31e2c126416` |
| optimism | `0x6a02d83e8d433304bba74ef1c427913958187142` |
| zksync | `0x620a9df73d2f1015ea75aea1067227f9013f5c51` |

The Ethereum side is checked on a fork. The zkSync side cannot be, since Forge does not run
EraVM, and needs a zkSync Sepolia run.

### 6. OP Stack messengers pair up

On each L2, `L2CrossDomainMessenger.OTHER_MESSENGER()` must be the L1 messenger in
`op-stack-l1-l2.toml`, and that one's `OTHER_MESSENGER()` must be `0x4200…0007`:

```sh
cast call 0x4200000000000000000000000000000000000007 "OTHER_MESSENGER()(address)" --rpc-url $L2_RPC
cast call <l1Messenger> "OTHER_MESSENGER()(address)" --rpc-url $L1_RPC
```

Results: Base and OP Mainnet both pair with their listed L1 messengers. Arbitrum and zkSync
have no code at the predeploy, as expected.

### 7. `layerzero-oft`

The binding has no transceiver and no provider ids, so §3's lanes and §5's verification are
those of the OFT an account sends through. Two things are checked: that the factory lands at
its one address, and, per candidate OFT, the prerequisites O1 to O7 of
[`layerzero-oft-spec.md` §2](../../../docs/layerzero-oft-spec.md#2-oft-prerequisites).

**Placement.** The factory and its two logic contracts deploy through Arachnid's factory at
salt zero (§1), so the address follows from their bytecode alone. A dry run prints it, and it
must be empty until the deploy:

```sh
forge script script/DeployLzOft.s.sol --rpc-url $RPC        # factory: 0x96ef3e86a1e5Ce9F8A0c30CD0411d7778480Dd32
cast code 0x96ef3e86a1e5Ce9F8A0c30CD0411d7778480Dd32 --rpc-url $RPC   # 0x until deployed
```

Any change to the three contracts moves the address, so it is rerun after one. The script
refuses a chain `chains.toml` does not list as `parity`.

**Per OFT.** `<oft>` is the OFT on the chain `RPC` reaches, `<eid>` the other end's eid, and
`<peer32>` the other end's OFT as `bytes32`:

```sh
cast call <oft> "peers(uint32)(bytes32)" <eid> --rpc-url $RPC                      # O2: the other end, both ways
cast call <oft> "enforcedOptions(uint32,uint16)(bytes)" <eid> 2 --rpc-url $RPC     # O3: type 3 with an lzReceive option
cast call <oft> "nextNonce(uint32,bytes32)(uint64)" <eid> <peer32> --rpc-url $RPC  # O5: 0, unordered
cast call <oft> "owner()(address)" --rpc-url $RPC                                  # O7
cast call $LZ_ENDPOINT "delegates(address)(address)" <oft> --rpc-url $RPC         # O7
cast storage <oft> 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 --rpc-url $RPC  # O7: ERC-1967 admin
# The DVNs an account trusts: the ULN config (type 2) of the send library on the home, and of
# the receive library on each destination for the home's eid.
cast call $LZ_ENDPOINT "getSendLibrary(address,uint32)(address)" <oft> <eid> --rpc-url $RPC
cast call $LZ_ENDPOINT "getReceiveLibrary(address,uint32)(address,bool)" <oft> <eid> --rpc-url $RPC
cast call $LZ_ENDPOINT "getConfig(address,address,uint32,uint32)(bytes)" <oft> <lib> <eid> 2 --rpc-url $RPC
```

O1 (`composeFrom` is the sender) and O4 (a send of 0 tokens) are behavior, not state: a fork
test like `LzOftForkTest` checks both from the packet the real OFT sends. `LzOftLeaves.s.sol`
reads the peers and checks each destination's eid on its own chain. O6 is `chains.toml`, and
O7 is the operator's judgment of who holds the roles read above.

Results for frxUSD, 2026-10-25 (Fraxtal over `https://rpc.frax.com`):

| | Fraxtal (home) | Ethereum | Arbitrum |
| --- | --- | --- | --- |
| OFT | lockbox `0x96A394058E2b84A89bac9667B19661Ed003cF5D4` | lockbox `0x566a6442A5A6e9895B9dCA97cC7879D632c6e4B0` | OFT `0x80Eede496655FB9047dd39d9f418d5483ED600df` |
| Arachnid's factory | Ethereum's code | Ethereum's code | Ethereum's code |
| Factory address | empty | empty | empty |
| Peers (O2) | both destinations | the lockbox | the lockbox |
| Enforced lzReceive gas, compose send (O3) | 250,000 to both | | |
| `nextNonce` from Fraxtal (O5) | | 0 | 0 |
| `owner()` | `0x5f25218ed9474b721d6a38c115107428E832fA2E` | `0xfFFffF4F3baC444b2C0ecf2A1840d018bE783937` | `0x3da490b19F300E7cb2280426C8aD536dB2df445c` |
| Delegate | the owner | `0xB1748C79709f4Ba2Dd82834B8c82D4a505003f27` | the owner |
| ERC-1967 admin | `0x223a681fc5c5522c85c96157c0efa18cd6c5405c` | the same | the same |
| Its `owner()` | `0xC4EB45d80DC1F079045E75D5d55de8eD1c1090E6` | `0xb898Ad2976b4d8f2E21521C9db16b7497825E503` | the OFT's owner |
| DVNs, each pathway | 5 of 5 required, 5 confirmations, LayerZero Labs' among them | 5 of 5, 5 confirmations, likewise | 5 of 5, 5 confirmations, likewise |

`LzOftForkTest` passes O1 and O4 through all three. Fraxtal fails O6: it is not in
`chains.toml` (#94), so `DeployLzOft.s.sol` and `LzOftLeaves.s.sol` refuse it, and only the
fork test has deployed the factory there. Every OApp owner is a 171-byte contract; who signs
for it was not checked.

## What these checks do not cover

- That an account deploys where `ZkSyncAccounts` and `TronAccounts` predict, with the real
  zksolc and TRON-solc artifacts. It needs one funded deployment per chain. On a local EraVM
  node it did, with foundry-zksync's build (§4).
- What pubdata adds to a delivery on zkSync (§4).
- End-to-end delivery through each provider's real relayers. Fork tests can cover the
  contracts for free ([todo §3](../../../docs/todo.md#3-infrastructure)); the off-chain
  relaying needs a real send.
- Float sizing for reporting chains, which depends on traffic.
