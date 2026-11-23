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
| fraxtal | 30255 | `0x1a44076050125825900e736c501f859c50fE728c` |

**CCIP.** Source: `smartcontractkit/documentation`,
`src/config/data/ccip/v1_2_0/mainnet/chains.json`.

| Chain | Selector | `CCIP_ROUTER` |
| --- | --- | --- |
| ethereum | 5009297550715157269 | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` |
| base | 15971525489660198786 | `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD` |
| arbitrum | 4949039107694359620 | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` |
| optimism | 3734403246176062136 | `0x3206695CaE29952f4b0c22a169725a865bc8Ce0f` |
| zksync | 1562403441176082196 | `0x748Fd769d81F5D94752bf8B0875E9301d0ba71bB` |
| fraxtal | 1462016016387883143 | `0x4bdF20477744Ec5F9DE738b5cC9ACd01763905ee` |

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
| fraxtal | 252 | `0x2f9DB5616fa3fAd1aB06cB2C906830BA63d135e3` | `0x71a55E56c0bB394Fee2B73A494Dfac387fBc298F` |

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

A parity chain needs Arachnid's factory with Ethereum's code, and `ProxyDeployer`'s address
free until the deploy:

```sh
cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url $RPC | cast keccak   # equals Ethereum's
cast code 0x415DaAF39EB13593a0Fe5E140bc97C4C9a63e116 --rpc-url $RPC                 # 0x until deployed
```

Code at Arachnid's address does not make a chain parity: zkSync Era has it too (README §1).

For a zkSync or Tron chain, the conduit formula must match the chain's own. On zkSync Era,
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
mainnet. Tron's matches the source. What neither shows is the conduit bytecode hash each
transceiver is born with (`conduitBytecodeHash`), which comes from zksolc and TRON-solc.

### 2. EIP-152, if the chain may compute BLAKE2b commitments

`Blake2b256` calls the F function at `0x09`. Call it for BLAKE2b-256(`"abc"`), one final
block of EIP-152's 213-byte input, and compare with any other implementation
(`bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319`):

```sh
cast call 0x0000000000000000000000000000000000000009 --rpc-url $RPC 0x0000000c28c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001
```

The first 32 bytes of the 64 returned must equal the digest.

Results measured on 2026-10-25 with the 213-byte input above:
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

A CCIP quote does not show the lane's version: a legacy lane can quote, or can require
`allowOutOfOrderExecution = true` and reject the bindings' default. `CcipPreflight`
(`script/deploy/CcipPreflight.sol`) therefore resolves each lane through the router
(`getOnRamp(selector)` for sends, `getOffRamps()` for deliveries) and compares each ramp's
`typeAndVersion()` with `OnRamp <v>` or `OffRamp <v>` for each `v` in `providers/ccip.toml`'s
`versions`, then quotes with the exact default options at both default gas values. Routers keep
superseded OffRamps registered, so a source needs one supported OffRamp, and the source's OnRamp
version, checked on the source chain, decides which executes. `DeployCcip` runs it for the
chain being deployed; `script/PreflightCcip.s.sol` runs it on every parity chain, so each direction
is checked at both ends:

```sh
for c in ETHEREUM BASE ARBITRUM OPTIMISM; do export RPC_URL_$c=... CCIP_ROUTER_$c=...; done
forge script script/PreflightCcip.s.sol
```

Result, 2026-11-20, over public RPCs at about blocks 26,457,692 (ethereum), 60,020,248 (base),
525,990,558 (arbitrum) and 159,797,824 (optimism): `script/PreflightCcip.s.sol` passed for all 12
directions among the four chains, with the routers in the table above. Each router reports
`Router 1.2.0`. Each chain's OnRamp reports `OnRamp 2.0.0` for every other chain (ethereum
`0xc3423F3FB30857D9C14717b119884b1B63d250b7`, base `0xF75bf16b03aaE98677926F0987F195A2153996B9`,
arbitrum `0x7B73923E101950eFe098C2Eca74C8320b2813f48`, optimism
`0xcBfaAbCb95358817d2FE859f1ca223Cf83FaE199`). Each source also has `OffRamp 2.0.0` registered
alongside `EVM2EVMOffRamp 1.2.0` and `1.5.0` and `OffRamp 1.6.0`, which stay registered. The
default-option quotes succeed at both gas values on all 12. A check that required every registered
OffRamp to be supported failed all 12, which is why one supported OffRamp is the rule. This
covered Ethereum, Base, Arbitrum and Optimism. With Fraxtal added, the same run passes on all five
chains with the Fraxtal pairs to Arbitrum and Optimism blocked in `ccip.toml`. The OffRamp
version string is also pinned by `test/deploy/CcipPreflightRealRouter.t.sol`.

A Hyperlane quote of 0 is a missing lane, and the binding refuses it (`NoHyperlaneRoute`). The Mailbox's default hook is a fallback-routing
hook; a domain with no route falls back to the Merkle tree hook alone, which charges nothing
and pays no relayer, so the dispatch would succeed and never be delivered. The IGP itself
reverts `IGP: no gas oracle for domain` for such a domain.

### 4. Destination gas

A bootstrap creates a conduit on the destination, so the gas it is sent with must cover
that. `ProviderDeliveryGasSpec` (`test/protocols/ProviderBindingSpec.t.sol`) measures each
delivery through every binding's fixture with `DeliveryGasMeter`, and fails if a `DeliveryGas`
default is not at least 10% above it; `forge test --mc DeliveryGasTest -vv` prints the numbers.
Each is the smallest gas limit under which the delivery succeeds from cold storage, less what
the same message costs delivered to a contract that does nothing:

| Delivery | CCIP | Hyperlane | LayerZero | OP Stack | Wormhole |
| --- | --- | --- | --- | --- | --- |
| Bootstrap to a standard EVM transceiver, no calls | 443,268 | 442,586 | 496,727 | 445,687 | 486,695 |
| The same with one call to an address with no code | 449,660 | 448,978 | 503,109 | 452,180 | 494,083 |
| Report arriving at the home transceiver | 122,763 | 122,121 | 122,750 | 119,827 | n/a (166,178) |
| Payload to an existing receiver, no calls | 26,223 | 24,421 | 27,621 | 23,164 | 67,785 |

Measured 2026-11-23 at `b9e60f8`, with Forge 1.8.1 and the repository's compiler settings,
against mock gateways. Wormhole's numbers include verifying the VAA
and recording it consumed, inside the receiver; its mock Core checks no guardian signatures,
so a real delivery costs more. A payload's default also pays for the caller's calls, so the
row is only the receiver's share. Wormhole reaches no reporting chain, so it never carries a
report; the spec measures one there only because it runs every delivery on every binding.

`layerzero-oft` has no transceiver, so `LzOftDeliveryGasTest` measures it with the same meter
(`forge test --mc LzOftDeliveryGasTest -vv`). Its defaults are lzCompose gas, the factory's or
the receiver's frame; the OFT's own lzReceive gas is the operator's enforced options:

| Delivery, `layerzero-oft` | Gas |
| --- | --- |
| Bootstrap to the factory, 1 destination, no calls | 469,908 |
| Bootstrap to the factory, 8 destinations, one call | 477,459 |
| Payload to an existing receiver, no calls | 34,357 |

Measured 2026-11-23 at `b45a484` against the mock endpoint and OFT. `LzOftForkDeliveryGasTest`
(`test/fork/LzOftFork.t.sol`) measures the same way through frxUSD on a fork of each destination:
homed on Fraxtal, to Ethereum and Arbitrum; homed on Ethereum, to Fraxtal, the only one of these
chains Ethereum's frxUSD peers. It runs lzCompose through the real `EndpointV2` into the factory
or the receiver, and the real OFT's `lzReceive` frame against the lzReceive gas the home's frxUSD
enforces for a send with a compose message (250,000 to all three):

| Delivery through frxUSD, no calls | Ethereum (from Fraxtal) | Arbitrum (from Fraxtal) | Fraxtal (from Ethereum) |
| --- | --- | --- | --- |
| Bootstrap, lzCompose into the factory | 470,273 | 470,348 | 469,963 |
| Bootstrap, the OFT's `lzReceive` | 107,863 | 90,832 | 109,471 |
| Payload, lzCompose into the receiver | 42,246 | 42,274 | 42,256 |
| Payload, the OFT's `lzReceive` | 99,372 | 82,342 | 101,993 |

Measured 2026-11-20 through public RPCs at the blocks in "Fraxtal as an OFT destination" below, at
`dcd1048`. A payload costs about 7,900 more than against the mocks and a
bootstrap 300 to 700 more; each stays well under its default. The `lzReceive` figure leaves out
the endpoint's clearing of the verified payload around it. The Fraxtal column is Forge executing
Fraxtal's state under `cancun` rules, not Fraxtal's own client; Fraxtal is an OP Stack chain with
Ethereum's gas schedule, but no run on its own node is recorded.

Without a gas attribute every binding sends `DeliveryGas`: 1,000,000 for a bootstrap,
250,000 for a report, 200,000 for a payload (#52). CCIP, LayerZero, and Hyperlane quote
1,000,000 on every configured pair; CCIP refuses 3,000,000 toward zkSync, so a caller's own
attribute can exceed a lane's cap. Nothing checks an attribute against these measurements:
one below them makes the delivery revert, and it is retried with more gas
([provider-spec R1.5](../../../docs/providers/provider-spec.md#r1-send)).

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
except where a DVN is pinned. Every pathway touching zkSync or Fraxtal defaults to the dead DVN,
so both ends pin LayerZero Labs' DVN alone (#51, #94). The pinned chains and each chain's DVN are
`pinned` and `[dvns]` in `providers/layerzero.toml`:

- each transceiver, by `setDvn(eid, dvn)` with its own chain's DVN, write-once, which the
  governance plan sets for every pinned pair; a pinned chain's transceiver is born with it for
  the governor home's eid, and so is any transceiver whose own pathway to the home is pinned;
- each receiver, at creation, for its home's eid, from its transceiver;
- each transmitter that sends over a pinned pathway, by its owner, with
  `LzTransmitter.setDvn(eid, required, optional, optionalThreshold)`. The owner chooses the
  stack and may change it, so a conduit that has not called it quotes no message there. A
  conduit's bootstrap is its transceiver's send and needs only the transceiver's pin. The plan
  sets LayerZero Labs' DVN on the governor's transmitter before the messages `connect` sends to a
  pinned chain.

LayerZero Labs' messaging DVN on each chain (metadata API, 2026-11-20; not the lzRead one):

| Chain | DVN |
| --- | --- |
| ethereum | `0x589dEDbD617e0CBcB916A9223F4d1300c294236b` |
| base | `0x9e059a54699a285714207b43b055483e78faac25` |
| arbitrum | `0x2f55c492897526677c5b68fb199ea31e2c126416` |
| optimism | `0x6a02d83e8d433304bba74ef1c427913958187142` |
| zksync | `0x620a9df73d2f1015ea75aea1067227f9013f5c51` |
| fraxtal | `0xcce466a522984415bc91338c232d98869193d46e` |

`LzFraxtalDvnForkTest` (`test/fork/LzDvnFork.t.sol`) checks Ethereum's side toward Fraxtal and
Fraxtal's side toward all four chains on forks: each quote reverts on the default and succeeds
once `LzMessage` pins the DVN, and the pin and its record fit the gas the plan budgets for a
transceiver's `setDvn` (`GovernancePlan.DVN_GAS`). Ethereum's side toward zkSync is checked the
same way. The zkSync side cannot be, since Forge does not run EraVM, and needs a zkSync Sepolia
run.

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
those of the OFT a conduit sends through. Two things are checked: that the factory lands at
its one address, and, per candidate OFT, the prerequisites O1 to O7 of
[`layerzero-oft-spec.md` §2](../../../docs/providers/layerzero-oft-spec.md#2-oft-prerequisites).

**Placement.** The factory and its two logic contracts deploy through Arachnid's factory at
salt zero (§1). The address depends on the compiled and linked bytecode, the canonical treasury
from `governance.toml`, and the receiver's two authority pins
(`CROSSECUTE_AUTHORITY_GUARD`, `CROSSECUTE_MULTISEND_CALL_ONLY`), which are in the receiver's
initcode. Deploy the chain treasury with `DeployChain.s.sol` before running the factory deploy
on each parity chain. Record the predicted factory address once per release.

```sh
forge script script/DeployLzOft.s.sol --sig 'predict()'
export CROSSECUTE_OFT_FACTORY='<predicted factory address>'
cast code "$CROSSECUTE_OFT_FACTORY" --rpc-url "$RPC"
forge script script/DeployLzOft.s.sol --rpc-url "$RPC"
```

Use the same release inputs on every chain. The dry run checks that they produce the recorded
address. Predict the address again whenever the build, treasury or authority pins change.

**Per OFT.** `<oft>` is the OFT on the chain `RPC` reaches, `<eid>` the other end's eid, and
`<peer32>` the other end's OFT as `bytes32`:

```sh
cast call <oft> "peers(uint32)(bytes32)" <eid> --rpc-url $RPC                      # O2: the other end, both ways
cast call <oft> "enforcedOptions(uint32,uint16)(bytes)" <eid> 2 --rpc-url $RPC     # O3: type 3 with an lzReceive option
cast call <oft> "nextNonce(uint32,bytes32)(uint64)" <eid> <peer32> --rpc-url $RPC  # O5: 0, unordered
cast call <oft> "owner()(address)" --rpc-url $RPC                                  # O7
cast call $LZ_ENDPOINT "delegates(address)(address)" <oft> --rpc-url $RPC         # O7
cast storage <oft> 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 --rpc-url $RPC  # O7: ERC-1967 admin
# The DVNs a conduit trusts: the ULN config (type 2) of the send library on the home, and of
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

`LzOftForkTest` passes O1 and O4 through all three. Fraxtal failed O6 when this was run: it was not
in `chains.toml`. It is configured since 2026-11-20 (#94), so `DeployLzOft.s.sol` and
`LzOftLeaves.s.sol` accept it; only the fork test has deployed the factory there. Every OApp owner is a 171-byte contract; who signs
for it was not checked.

## Fraxtal (2026-11-20)

Chain id 252, `https://rpc.frax.com`, read at block 44,191,952. Added to `chains.toml` as a parity
chain with an id in the LayerZero, CCIP and Hyperlane files and its messenger in
`op-stack-l1-l2.toml`. Wormhole does not reach it. CCIP carries Fraxtal only to and from Ethereum
and Base, so `ccip.toml` blocks the four pairs with Arbitrum and Optimism. LayerZero is pinned on
every Fraxtal pathway (#94).

The [signed-mode check](https://github.com/crossecute/protocol/issues/169) found no canonical
Safe 1.5.0 code at the release pins. Fraxtal can verify signed operations from a supported
home at the receiver level. The current deployment scripts require local guard code before
deploying that receiver. A Fraxtal Safe requires the canonical contracts to serve as a
signed home.

| Check | Result |
| --- | --- |
| §1 Arachnid's factory | same code hash as Ethereum (`0x2fa86add…e4989`); `ProxyDeployer`'s address is empty: parity |
| §2 EIP-152 | correct BLAKE2b-256 of `"abc"` |
| §3 LayerZero | all 8 quotes between Fraxtal and Ethereum, Base, Arbitrum and Optimism revert on the default; pinned, Ethereum to Fraxtal and Fraxtal to all four quote on forks (§5) |
| §3 CCIP | Fraxtal reaches only Ethereum and Base, in both directions (OnRamp `OnRamp 2.0.0`, `OffRamp 2.0.0` registered); `isChainSupported` is false and `getFee` reverts `UnsupportedDestinationChain` for Arbitrum and Optimism both ways; quotes pass at 1,000,000 and 200,000 gas on the four lanes that exist |
| §3 Hyperlane | all 8 directions quote at 50,000 and 1,000,000 gas |
| §3 Wormhole | not reached: the SDK's `Chains.sol` has no Fraxtal |
| §5 Hyperlane | default ISM `0x71a55E…298F` is the 2-of-2 aggregation of a `NULL` module and a per-origin route to a 1-of-2 Merkle-root and message-id multisig; thresholds into Fraxtal are 6 of 9 from Ethereum and 3 of 5 from Base, Arbitrum and Optimism; Ethereum's default ISM takes Fraxtal at 3 of 4 |
| §5 LayerZero | the default send ULN of all 8 pathways requires only `0x…dEaD`, with 5 to 20 confirmations; LayerZero Labs' DVN on Fraxtal is `0xcce466a522984415bc91338c232d98869193d46e` (metadata API) |
| §4 `layerzero-oft` gas | into Fraxtal through frxUSD from Ethereum: lzCompose 469,963 (bootstrap) and 42,256 (payload) against defaults of 1,000,000 and 200,000; the lockbox's `lzReceive` 109,471 and 101,993 against 250,000 enforced (below) |
| §6 OP Stack | Fraxtal's `L2CrossDomainMessenger.OTHER_MESSENGER()` is `0x126bcc31Bc076B3d515f60FBC81FddE0B0d542Ed`, whose `OTHER_MESSENGER()` on Ethereum is `0x4200…0007` |
| §7 `layerzero-oft` | a conduit homed on Ethereum bootstraps into Fraxtal's frxUSD lockbox and sends a message after; the factory lands at one address on both chains (below) |

`PreflightCcip.s.sol` passes for every carried pair of the five chains. Not run: the transceiver
providers' (LayerZero, Hyperlane, OP Stack) delivery gas on Fraxtal, whose gas table is Forge's
against mocks.

## What these checks do not cover

- That a conduit deploys where `ZkSyncConduits` and `TronConduits` predict, with the real
  zksolc and TRON-solc artifacts. It needs one funded deployment per chain. On a local EraVM
  node it did, with foundry-zksync's build (§4).
- What pubdata adds to a delivery on zkSync (§4).
- End-to-end delivery through each provider's real relayers. Fork tests can cover the
  contracts for free ([todo §3](../../../docs/todo.md#3-infrastructure)); the off-chain
  relaying needs a real send.
- Float sizing for reporting chains, which depends on traffic.
- Whether a deployment is the one a registry should mark live. `markLive` is the timelock's mark
  after a manual list (README, "Marking a chain live"); no script runs it, and the generated
  governance payloads mark every chain they add without checking the chain.
- Messages from a chain that is `Pending`. The registry's prediction is authenticated inbound
  before `markLive`, so an unverified deployer-placed contract at that address could originate
  messages if a route to the chain exists. Routes and peers wait for `markLive`; nothing enforces
  it.

## 8. Safe-signed dispatch (#134, 2026-11-17)

For signed deployments and route enablement:

- Before deploying receiver implementations, run `DeploySafeGuard.s.sol` with the pinned guard
  build. Compare `predict()` with `address` in [`safe-guard.toml`](safe-guard.toml), then dry-run
  the deployment on each chain. The dry run checks Arachnid's factory and the five canonical
  Safe 1.5.0 runtime hashes.
- After deploying the guard, run `DeploySafeGuard.s.sol --sig 'verify()' --rpc-url "$RPC"` on
  each deployment chain. The script confirms the recorded address and all five guard pins.
  See the [guard runbook](README.md#source-guard-for-signed-mode) for the full commands.
- Before enabling a signed route, read `SOURCE_AUTHORITY_GUARD()` and `MULTISEND_CALL_ONLY()`
  from the destination receiver implementation. Compare them with the verified release guard
  and its MultiSendCallOnly pin. Confirm that the source Safe has activated.

The [signed dispatch benchmark](../../../docs/benchmarks/safe-signed-dispatch-measurements.md)
records Paris receiver gas, wire sizes, Cancun real-Safe integration, and runtime sizes.
Before enabling a signed route, simulate the exact destination provider call and sign
explicit gas attributes where supported. Use the report's
[gas guidance](../../../docs/benchmarks/safe-signed-dispatch-measurements.md#delivery-gas-decision)
and [provider size and fee checks](../../../docs/benchmarks/safe-signed-dispatch-measurements.md#provider-size-and-per-byte-fee-checks).

### Pinned provider checks for a release candidate

Run `contracts/evm/script/check-provider-forks.sh layerzero` and
`contracts/evm/script/check-provider-forks.sh ccip` from the repo root. The
[provider forks workflow](../../../.github/workflows/provider-forks.yml) also runs on a selected
candidate ref and before protocol npm staging. The script verifies the block hashes and requires
every named suite to run without skips. It uses public RPCs by default. Set `ETH_RPC_URL`,
`ARBITRUM_RPC_URL`, `FRAXTAL_RPC_URL`, `BASE_RPC_URL`, or `OPTIMISM_RPC_URL` to an archival
RPC for the same chain if the public endpoint cannot serve the pinned state.
In GitHub Actions, `PROVIDER_FORK_` followed by one of those variable names overrides a
public endpoint. The workflow uses the script defaults when no override is configured.

- LayerZero uses deployed endpoints and OFTs for source quote and send, and real OFT and
  endpoint compose code to execute bootstrap and payloads. A reverted compose stays queued
  for retry after its target is repaired. Test calls stand in for the DVNs and executor.
- CCIP checks configured parity lanes with the deployed Router and tests Ethereum-to-Base
  bootstrap and send fee parity on the Ethereum fork. Separate tests drive CCIP's upstream
  Router and OffRamp binaries through bootstrap, delivery failure, retry, and replay protection
  with a local RMN and verifiers.

The workflow makes read-only RPCs and executes transactions locally on forks. Actual provider
delivery and the [hosted Safe Queue and Ledger acceptance run](../../../docs/safe/hosted-signed-acceptance.md)
require a disposable deployed route.

### LayerZero fork regression run (#118)

All three RPC-dependent regressions passed on 2026-11-19 Pacific time with Forge 1.8.1
and solc 0.8.28. The protocol code was from commit
`25b436e619c87c4ce9e14ab7b56061c01ae6296b`. The test harness accepts block numbers
to replay the same chain state.

| Network | Block | Block hash |
| --- | ---: | --- |
| Ethereum | 26,452,787 | `0xa0f39d06250d8e90d447063e7bfe97354564270482e5e1036d12ff18a1be1653` |
| Fraxtal | 44,161,882 | `0x715467e210341ecc933a710c7cef720e31c12d7490e2caf4e9fd21d6b742f9c2` |
| Arbitrum One | 525,772,439 | `0xd36b2bccd4298aa2296342270ca1a08c8109d2c36013767267cbf0888340c8c2` |

Run from `contracts/evm` with RPCs that can serve account state at these heights.

```sh
ETH_RPC_URL=https://ethereum-rpc.publicnode.com \
FRAXTAL_RPC_URL=https://fraxtal-rpc.publicnode.com \
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc \
ETH_FORK_BLOCK=26452787 FRAXTAL_FORK_BLOCK=44161882 ARBITRUM_FORK_BLOCK=525772439 \
forge test --match-contract '^(LzDvnForkTest|LzOftForkTest|LzOftForkDeliveryGasTest)$' -vv
```

- `LzDvnForkTest` confirmed Ethereum's zkSync quote reverted with the default DVN
  and returned a nonzero fee after pinning LayerZero Labs' DVN.
- `LzOftForkTest` sent a frxUSD OFT bootstrap and payload from Fraxtal to both
  Ethereum and Arbitrum on local forks.
- `LzOftForkDeliveryGasTest` passed the receive and compose gas assertions on both
  destinations. Bootstrap compose used 470,273 gas on Ethereum and 470,348 on Arbitrum.

These OFT regressions simulate provider delivery of unsigned bootstrap and payload messages.

### A native LayerZero conduit toward Fraxtal on Ethereum's real endpoint

On 2026-11-20, `LzConduitDvnForkTest` (`test/fork/LzConduitDvnFork.t.sol`) deployed the real
`LzTransceiver` and `LzTransmitter` on a fork of Ethereum and sent to Fraxtal through the real
endpoint, with Ethereum block 26,458,885 (`0x2b756d8dbe5739843874a1e8ca708860b2a410e5e08f742b51256a60c7552264`).
It showed who sends what:

- The conduit's bootstrap is the transceiver's send. It quoted `0x…dEaD::getFee` and reverted until
  the transceiver's `setDvn` (governance's pin) was in place, after which it quoted and went out
  without the conduit setting anything.
- A message after the bootstrap is the conduit's own send. It reverted on the same dead DVN until
  the conduit's owner called `LzTransmitter.setDvn`, after which it quoted and the real endpoint
  emitted `PacketSent`. A second conduit of the same transceiver, bootstrapped the same way,
  still could not quote a message: the pin is per conduit.

```sh
ETH_RPC_URL=https://ethereum-rpc.publicnode.com ETH_FORK_BLOCK=26458885 \
forge test --match-contract LzConduitDvnForkTest -vv
```

### Fraxtal as an OFT destination

On 2026-11-20, `LzOftForkTest` and `LzOftForkDeliveryGasTest` passed with Fraxtal as a
destination: the conduit homed on Ethereum, through Ethereum's frxUSD
(`0x566a6442A5A6e9895B9dCA97cC7879D632c6e4B0`, which peers Fraxtal's lockbox but not Arbitrum's
OFT). The run used Forge 1.8.1 and the protocol code of `8b7c570` plus the test change. The
bootstrap and the message after it ran on forks of both chains, with the factory at one address
on each, so Fraxtal's deterministic deployer holds for it too. Delivery gas is in §4.

| Network | Block | Block hash |
| --- | ---: | --- |
| Ethereum | 26,458,714 | `0x3eb68b00f48a61cd64d0e11e6b1d0c1e18805d9b376c6fa70cd3aa03bd3777b8` |
| Fraxtal | 44,198,047 | `0x045e5b2728072c6823a6d545bf52c1cc747a6b4016381626311389257e706ab8` |
| Arbitrum One | 526,037,294 | `0x6464dfa11fc92945cbed4c56038dda469ae9ae4619d012aa0c5cde1be4fe167e` |

```sh
ETH_RPC_URL=https://ethereum-rpc.publicnode.com \
FRAXTAL_RPC_URL=https://fraxtal-rpc.publicnode.com \
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc \
ETH_FORK_BLOCK=26458714 FRAXTAL_FORK_BLOCK=44198047 ARBITRUM_FORK_BLOCK=526037294 \
forge test --match-contract '^(LzOftForkTest|LzOftForkDeliveryGasTest)$' -vv
```

### Signed LayerZero OFT routes

On 2026-11-19 Pacific time, `LzOftSignedForkTest` passed for the frxUSD lockbox
on Fraxtal as home and the frxUSD peers on Ethereum and Arbitrum One as destinations.
The run used Forge 1.8.1, solc 0.8.28, and protocol code from
`25b436e619c87c4ce9e14ab7b56061c01ae6296b`.

| Network | Block | Block hash |
| --- | ---: | --- |
| Ethereum | 26,452,948 | `0xd2ad49c4ced7f212002688cbca10650a69182d9c3a5409c3f982473db4e4253d` |
| Fraxtal | 44,163,272 | `0xa54723a2be56691d03752f4d335645eb676b494675c28984ba4885bb06bc0de6` |
| Arbitrum One | 525,780,069 | `0x7586c9921ff9e854a93d35602c9258b3b733e8b768283be83c1ea03b1ccd9dd4` |

Run from `contracts/evm` with RPCs that serve state at these heights.

```sh
ETH_RPC_URL=https://ethereum-rpc.publicnode.com \
FRAXTAL_RPC_URL=https://fraxtal-rpc.publicnode.com \
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc \
ETH_FORK_BLOCK=26452948 FRAXTAL_FORK_BLOCK=44163272 ARBITRUM_FORK_BLOCK=525780069 \
forge test --match-contract LzOftSignedForkTest -vv
```

| Destination | Signed bootstrap quote paid (wei) | Standalone signed message quote paid (wei) |
| --- | ---: | ---: |
| Ethereum | 11,244,113,148,395,502,652 | 10,977,624,258,985,439,048 |
| Arbitrum One | 17,061,238,848,128,624,735 | 18,593,363,804,397,285,854 |

Both lanes emitted a zero-token packet of 1,657 bytes for bootstrap and 1,593 bytes
for the standalone message, including the packet header. The real destination
endpoint composed within the signed option budgets of 1,500,000 and 600,000 gas,
respectively. Each receiver installed the selected authority and executed the setup
and message calls. Direct resubmission of the delivered message used the same replay
state. The fixture stages source evidence with Safe and guard stubs, verifies real
2-of-2 EOA signatures at the receiver, and simulates DVN and executor delivery.

Before enabling signed OFT routes, run the #118 deployment validation against each intended
OFT pair. Verify zero-amount sends and compose support, peers and endpoint/eid configuration,
complete signed-bootstrap and message wire sizes, byte-sensitive quote/send fee parity and
refund recipients. Simulate the complete factory/receiver compose entry point with the actual
authority graph and application calls, and provide explicit compose gas attributes. The fork
results apply to the pinned blocks, two-owner graph, and calls in the fixture. Confirm all
copies of the factory, its logic and linked libraries use the same release build and
deterministic addresses, including the receiver authority pins, by running
every chain's deploy with the release's `CROSSECUTE_OFT_FACTORY`. Unsigned and
signed modes use the same route-bound salt and six-argument factory prediction.

## CCIP 2.0 options

Existing CCIP checks and recorded results do not establish V3 compatibility. V3 is
initially disabled for every outbound lane. Before the transceiver owner calls
`setCcipV3Lane(selector, true, evidenceHash)`:

1. Verify the source lane's deployed OnRamp/FeeQuoter supports V3 and the destination
   OffRamp supports the receiver policy interface. Record contract addresses, versions,
   block numbers, direction, and date. Do not infer this from the npm package version.
2. Quote representative V3 messages with defaults and every intended custom option.
   Confirm the reverse direction independently where it is used. An arbitrary quote
   failure is not evidence that fallback to V2 is safe.
3. Check the configured CCVs, executor, and finality modes on that lane. Confirm that
   receiver/transceiver inbound policies are satisfiable, including automatic reports
   which still send without attributes. A receiver policy that becomes unsatisfiable also
   blocks the message that would reset it
   ([options guide](../../../docs/providers/ccip-v2.md#configure-inbound-policies)).
4. Validate actual delivery, full-finality rejection of faster requests, policy updates
   with pending messages, No Exec/manual execution, and delivery gas on the target VM.
5. Store the results in this file or a linked versioned record and use its content hash
   as evidenceHash. The contract records this hash in an event; it does not verify the
   evidence or detect lane versions itself.

V3 lane results are pending in
[deployment issue #118](https://github.com/crossecute/protocol/issues/118). See the
[CCIP options guide](../../../docs/providers/ccip-v2.md) for configuration and defaults.
