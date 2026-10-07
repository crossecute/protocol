# Adding a chain

What it takes to bring a new EVM chain into the protocol, in order. A chain that is not EVM
also needs a chain type first; see "Adding a chain type" in the [root README](../../../README.md).

Most of what is set below is write-once on chain: a chain's grade in each registry, each
transceiver's route, provider id, and counterpart for it, and LayerZero's peers. A wrong value
is fixed only by redeploying. The steps follow
[spec §6](../../../docs/provider-spec.md#6-configuration-a-compliant-deployment-performs),
which is their specification.

## 1. Decide how the chain places contracts

Every grade follows from this, so it comes first. It is the chain's `derivation` in
[`chains.toml`](chains.toml):

| Derivation | What it is | Graded by others | Grades others | Consequences |
| --- | --- | --- | --- | --- |
| `parity` | Standard EVM; Arachnid's factory places `CrossProxyDeployer` at `0x4973…249C` | `Predetermined` by every chain but `other` | `Predetermined` if they are parity | Accounts share their address with every parity chain; the deploy scripts support it |
| `zksync` | EraVM's CREATE2 | `Unique` | `Predetermined` if they are parity; otherwise `Unique`, itself included | Its transceivers report every receiver home, paid from a float; no production script yet |
| `tron` | TVM's CREATE2 (`0x41` prefix) | `Unique` | as zkSync | As zkSync |
| `other` | EVM without Arachnid's factory | `Unique` | `Unique`, itself included | Its transceivers cannot be born configured (the governor's home is not `Predetermined` from it, which `initialize` refuses); unsupported until the home's counterpart can be seeded ([todo §2](../../../docs/todo.md#2-chain-checks-before-mainnet)) |

A chain is `Predetermined` from another exactly when it is a parity chain and the grading chain
is not `other` (`ChainConfig.gradeOf`): a zkSync or Tron transceiver finds a parity chain's
transceiver from the provider's deployment record, but a plain transceiver on an `other` chain
sits off the shared address and can use no parity address (#33). Code at Arachnid's address does not settle it: zkSync Era returns
the same 69 bytes there as Ethereum, but EraVM's CREATE2 would put `CrossProxyDeployer`
elsewhere. Classify a chain by its VM, then let the deploy's own check confirm it:
`crossProxyDeployer()` refuses a chain where the deployer does not land where Ethereum's
formula predicts.

The governor's home must be a parity chain: every chain's transceiver is born accepting the
home, which requires the home to be `Predetermined` from there.

## 2. Check the chain

Before mainnet, from [todo §2](../../../docs/todo.md#2-chain-checks-before-mainnet):

- **Arachnid's factory** at `0x4e59b44847b379578588920cA78FbF26c0B4956C` with Ethereum's code,
  for a parity chain.
- **EIP-152** (BLAKE2b at `0x09`) if the chain may be a home or use the BLAKE2b commitment
  scheme. Without it the scheme reverts.
- **zkSync and Tron derivations** are unverified against a real deployment. Each needs a
  one-account check before it carries value.
- **Lanes.** For each provider, which existing chains it actually connects to the new one.
  CCIP lanes, Wormhole Executor quotes, and Hyperlane routes exist per pair.
- **Hyperlane's ISM.** The new chain's Mailbox decides what counts as verified for every
  origin it accepts.

## 3. Add it to `deploy/`

- [`chains.toml`](chains.toml): one table, keyed by a short name the provider files use, with
  `chain_id` and `derivation`.
- [`providers/<provider>.toml`](providers): one line per provider that reaches the chain, keyed
  by that name. Take each id from the provider's own registry; the header of each file names
  it. Leave a provider out where it does not reach the chain. `op-stack-l1-l2`'s ids are
  messenger addresses, which depend on the chain they are read from, so its file has its own
  shape: add the chain's `L1CrossDomainMessenger` under `[l1_messengers]` if it is an OP Stack
  chain. `op-stack-l2-l2` has no ids; add the chain to its `chains` list once interop is live
  on it.

Then run `forge test`. `test/deploy/ChainConfig.t.sol` reads both and refuses a duplicate
chain id, an unknown derivation, a provider key that is not a configured chain, and an id that
is zero, repeated, or wider than the provider's `id_bits`. Deployments run the same checks.

Never change a deployed chain's ids. Transceivers hold them write-once.

## 4. Deploy on the new chain

**Step 1, not scripted yet.** Deploy the chain's `TimelockController`, then
`ChainRegistry(timelock, seed)` and `Treasury(timelock)`. The seed names the governor's home,
graded `Predetermined`, and each provider's deployment record exactly as every other chain's
registry has it. A record that differs moves that provider's transceiver off its shared
address.

**Step 2, per provider:**

```
forge script script/Deploy<Provider>.s.sol --rpc-url <rpc> --broadcast --sender <deployedBy>
```

The broadcaster must be the record's `deployedBy`; the salt is read from the record. Inputs
come from the environment, listed in [`DeployProvider.s.sol`](../script/DeployProvider.s.sol)
and each provider's script (its endpoint addresses). `GATEWAYS` is fixed here: a transceiver's
gateways cannot be added later. Provider ids come from this directory.

Before deploying, the script refuses a chain missing from `chains.toml` or not parity, a
governor's home that is not `Predetermined` from it, and a registry whose grades disagree with
this configuration. Every deployment then checks the proxy's address and lock, the
transceiver's configuration, and the registry's record (R8.4).

Wormhole's contracts link the `WormholeMessage` library (#29). `forge script` deploys it before
them, through Arachnid's factory, so it has one address on every parity chain.

zkSync and Tron have deploy functions, which the tests use, but no production script: their
bytecode comes from zksolc and TRON-solc.

`op-stack-l2-l2` deploys only to a chain its configuration lists, with a governor's home on an
L2 it lists too, and only where the `L2ToL2CrossDomainMessenger` predeploy has code. Where the
chain's registry was seeded with another home, register the L2 home there first. It lists none
until interop is live ([todo §5](../../../docs/todo.md#5-post-launch-superchain-interop)).

## 5. Bring it into the protocol

Everything here is governance, and it runs in both directions: the new chain learns about
every existing chain, and every existing chain learns about the new one. That is the N × N
part. The order is forced. A bootstrap and a counterpart both need the chain registered
first, and the new chain has no owner, and its timelock no proposer, until the governor's
bootstrap creates the governor's accounts there.

1. **Prepare the home** (§6 step 3). On the governor's home, through its timelock,
   `addChainKey(newChain, grade)` with `ChainConfig.gradeOf(home, newChain)`; then, by the
   governor, configure each home transceiver for the new chain (the calls in step 4 below).
   The new chain's transceivers were born accepting the home, so nothing is needed there yet.
2. **Bootstrap it** (§6 step 4). The governor's transmitter on the home bootstraps the new
   chain. The receiver it creates is the owner of each transceiver there.
3. **Register chains** (§6 step 6), through each chain's timelock, which waits out its delay:
   - on every other existing chain, `addChainKey(newChain, grade)` graded from that chain;
   - on the new chain, `addChainKey` for every existing chain, graded from the new chain,
     and `setLocalTransceiver` for each provider.
4. **Configure transceivers** (§6 step 5), by payload from the home, on every chain for every
   other chain it will talk to, once the chain it names is registered there:
   - `setRoute`;
   - the provider's id setter (`setEid`, `setSelector`, `setDomain`, `setWormholeChain`),
     with the id from `providers/`;
   - LayerZero's `setPeer`;
   - `setCounterpart` or `resolveCounterpart` where the destination is not `Predetermined`;
   - `setBootstrapFee` where the destination reports its receivers (a zkSync or Tron
     destination).
5. **Fund floats** (§6 step 7) on chains whose transceivers report, sized from
   [R7.5](../../../docs/provider-spec.md#r7-fees-and-value)'s quote.

Generating these payloads from this directory, so that every chain's tables agree, is not
scripted yet ([todo §3](../../../docs/todo.md#3-infrastructure)).
