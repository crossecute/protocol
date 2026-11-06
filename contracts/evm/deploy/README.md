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
| `parity` | Standard EVM; Arachnid's factory places `LockedProxyDeployer` at `0x4973…249C` | `Predetermined` by every chain but `other` | `Predetermined` if they are parity | Conduits share their address with every parity chain of the same deployer; the deploy scripts support it |
| `zksync` | EraVM's CREATE2 | `Unique` | `Predetermined` if they are parity; otherwise `Unique`, itself included | Its transceivers report every receiver home, paid from a float; no production script yet |
| `tron` | TVM's CREATE2 (`0x41` prefix) | `Unique` | as zkSync | As zkSync |
| `other` | EVM without Arachnid's factory | `Unique` | `Unique`, itself included | Its transceivers cannot be born configured (the governor's home is not `Predetermined` from it, which `initialize` refuses); unsupported until the home's counterpart can be seeded ([todo §2](../../../docs/todo.md#2-chain-checks-before-mainnet)) |

A chain is `Predetermined` from another exactly when it is a parity chain and the grading chain
is not `other` (`ChainConfig.gradeOf`): a zkSync or Tron transceiver finds a parity chain's
transceiver from the registry's prediction, as every transceiver does, but a plain transceiver on
an `other` chain sits off the shared address and can use no parity address (#33). Code at Arachnid's address does not settle it: zkSync Era returns
the same 69 bytes there as Ethereum, but EraVM's CREATE2 would put `LockedProxyDeployer`
elsewhere. Classify a chain by its VM, then let the deploy's own check confirm it:
`lockedProxyDeployer()` refuses a chain where the deployer does not land where Ethereum's
formula predicts.

The governor's home must be a parity chain: every chain's transceiver is born accepting the
home, which requires the home to be `Predetermined` from there.

## 2. Check the chain

Run every check in [CHECKS.md](CHECKS.md) against the new chain and each chain it will talk
to: where contracts land, EIP-152, each provider's lanes, destination gas, the destination's
verification, and OP Stack's messengers. None spends gas. It also records each provider's
endpoint addresses, which the deploy scripts take from the environment.

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

**Step 1:**

```
forge script script/DeployChain.s.sol --rpc-url <rpc> --broadcast
```

It deploys the chain's `TimelockController`, then `ChainRegistry(timelock, seed)` and
`Treasury(timelock)`, through Arachnid's factory. Every argument comes from
[`governance.toml`](governance.toml), so each lands at one address on every parity chain: the
seed names the governor's home, graded `Predetermined`, each provider's salt and initcode hash,
and the first deployer (`deployed_by`), which it records live on the home. The timelock's proposers are the governor's conduits under the two providers it names. Any
conduit may broadcast, and a rerun deploys nothing. It refuses a chain that is not parity, a
`governance.toml` with an owner, `deployed_by`, or salt unset, and a build whose `LockedProxy` initcode
hash is not the one `governance.toml` records, since every registry records that value for
every provider (R8.4). Never change `governance.toml` once a chain is deployed: every address
derives from it.

**Step 2, per provider:**

```
forge script script/Deploy<Provider>.s.sol --rpc-url <rpc> --broadcast --sender <deployer>
```

The broadcaster must be the deployer the registry records for this chain: the entry for its own
chain if governance added one, otherwise `currentDeployer`, which is `deployed_by` until a
rotation. The salt is read from the provider's record. The
governor's owner, salt, and home come from [`governance.toml`](governance.toml), and the
registry and treasury are step 1's, at the addresses it predicts. The rest comes from the
environment, listed in [`DeployProvider.s.sol`](../script/DeployProvider.s.sol) and each
provider's script (its endpoint addresses). `GATEWAYS` is fixed here: a transceiver's gateways
cannot be added later. Provider ids come from this directory.

Before deploying, the script refuses a chain missing from `chains.toml` or not parity, a
governor's home that is not `Predetermined` from it, and a registry that has not registered
the home or whose grades disagree with this configuration. Every deployment then checks the proxy's address and lock, the
transceiver's configuration, and the registry's record (R8.4). The deployer chooses the
implementation behind the proxy, and nothing on chain checks it, so no registry marks the
transceiver live because the script passed: see "Marking a chain live".

Wormhole's and LayerZero's contracts link `WormholeMessage` (#29) and `LzMessage`. `forge script`
deploys each before them, through Arachnid's factory, so it has one address on every parity
chain.

Every transceiver implementation names the chain's `TransceiverExtension` (#70), which
`script/deploy/` deploys on first use through Arachnid's factory, so one serves every provider
on the chain and it has one address on every parity chain.

LayerZero takes `LZ_GOVERNOR_HOME_DVN`, unset unless the governor home's pathway defaults to the
dead DVN; it is then this chain's LayerZero Labs DVN ([CHECKS §5](CHECKS.md#5-verification-on-the-destination)).

zkSync and Tron have deploy functions, which the tests use, but no production script: their
bytecode, and step 1's `ChainRegistry` there, comes from zksolc and TRON-solc.

`op-stack-l2-l2` deploys only to a chain its configuration lists, with a governor's home on an
L2 it lists too, and only where the `L2ToL2CrossDomainMessenger` predeploy has code. Where the
chain's registry was seeded with another home, register the L2 home there first. It lists none
until interop is live ([todo §5](../../../docs/todo.md#5-post-launch-superchain-interop)).

## 5. Bring it into the protocol

Everything here is governance, and it runs in both directions: the new chain learns about
every existing chain, and every existing chain learns about the new one. That is the N × N
part. The order is forced. A bootstrap and a counterpart both need the chain registered
first, and the new chain has no owner, and its timelock no proposer, until the governor's
bootstrap creates the governor's conduits there.

1. **Prepare the home** (§6 step 3). On the governor's home, through its timelock,
   `addChainKey(newChain, grade)` with `ChainConfig.gradeOf(home, newChain)`, then
   `addProviderOnChain(newChain, provider, currentDeployer)` for each provider deployed on the
   new chain and, once those deployments are verified ("Marking a chain live"), `markLive`:
   the bootstrap below is refused until the home's registry has the chain live. Then, by the
   governor, configure each home transceiver for the new chain (the calls in step 4 below).
   The new chain's transceivers were born accepting the home, so nothing is needed there yet.
2. **Bootstrap it** (§6 step 4). The governor's transmitter on the home bootstraps the new
   chain. The receiver it creates is the owner of each transceiver there.
3. **Register chains** (§6 step 6), through each chain's timelock, which waits out its delay:
   - on every other existing chain, `addChainKey(newChain, grade)` graded from that chain, then
     `addProviderOnChain` and, after verification, `markLive` for each provider on the new
     chain, in the same batch;
   - on the new chain, `addChainKey` for every existing chain, graded from the new chain,
     `addProviderOnChain` and `markLive` for each provider on each (the home's entries are
     seeded live), and `setLocalTransceiver` for each provider.
4. **Configure transceivers** (§6 step 5), by payload from the home, on every chain for every
   other chain it will talk to, once the chain it names is registered there and marked live (a
   chain that is only `Pending` is already authenticated inbound at its predicted address, so
   no route or peer to it before `markLive`):
   - `setRoute`;
   - the provider's id setter (`setEid`, `setSelector`, `setDomain`, `setWormholeChain`),
     with the id from `providers/`;
   - `setCounterpart` or `resolveCounterpart` where the destination is not `Predetermined`;
   - LayerZero's `setPeer`, after the two above: it refuses a peer other than the counterpart
     on the chain the eid maps to (#62);
   - `setBootstrapFee` where the destination reports its receivers (a zkSync or Tron
     destination);
   - `setOperator`, naming a key on this chain that may reprice or halt bootstraps without a
     cross-chain governance message, if the chain has one.
5. **Fund floats** (§6 step 7) on chains whose transceivers report, sized from
   [R7.5](../../../docs/provider-spec.md#r7-fees-and-value)'s quote.

For the parity chains, these payloads come from this directory, so every chain's tables agree:

```
forge script script/GovernancePayloads.s.sol
```

It reads nothing on chain, so a commit always writes the same files to `out/governance/`, Safe
Transaction Builder batches numbered in the order they are submitted:

1. `1-prepare-home.json`, by the governor's owner on the home: create its transmitter under each
   provider, set the home transceivers' routes and ids, and schedule the home registry.
2. `2-execute-registry-<home>.json`, by anyone after the timelock delay.
3. `3-bootstrap.json`, by the governor's owner: the home's LayerZero peers, then a bootstrap of
   every other chain under every provider that reaches it. Each payload sets that transceiver's
   routes and ids, and the first proposer's also schedules that chain's registry. Each
   transmitter pays from its own balance, so send it its quotes first. Wormhole's go
   publish-only, and wait for a deliverer ([todo §3](../../../docs/todo.md#3-infrastructure)).
4. `4-execute-registry-<chain>.json` for every other chain, by anyone there once its bootstrap
   has arrived and the delay has passed.
5. `5-connect.json`, by the governor's owner once every file 4 has executed: each chain's
   LayerZero peers, which need its registry.

`3-bootstrap.json` and the registry batches add each provider on every chain it was deployed to
(`addProviderOnChain`, under `deployed_by`) and mark it live (`markLive`), except on the home,
which the seed already records live. Schedule a batch only after step 2 is verified for every
chain it lists (next section): the timelock delay is the review window, and `markLive` is
never undone.

The files are for the first deployment. For a chain added later, a rerun writes every entry
again, and creating a transmitter or bootstrapping a chain a second time reverts, so submit only
the entries that name the new chain. zkSync and Tron are left out: their transceivers
are not at a predicted address, so neither they nor any lane to them is in these files.

## Marking a chain live

A registry refuses every bootstrap, and its quote, to a chain until its owner, the timelock,
calls `markLive(chainKey, provider)`. A send follows only a bootstrap, so none reaches an
unmarked chain either. The check the proposers make before scheduling it must not
rely on the deployer, whose script checks (`checkTransceiver`) are its own. Read each of these
from the chain, with an RPC the deployer does not control:

1. Code at `registry.predictTransceiver(chainKey, provider)`, and the implementation in its
   EIP-1967 slot has the code hash the build produces. That slot being set is what locks the
   proxy.
2. `owner()` is the governor's conduit on that chain (`predictConduit` of the governor's
   owner, salt, and home), `chainRegistry()` is that chain's registry, and `messageProvider()` is the
   provider's id.
3. The treasury, gateways, and conduit implementations are the configured ones.

Any other result leaves the entry `Pending`.

Three rules keep the review meaningful:

- **Add and mark live in one batch, or mark live first.** A `Pending` entry already gets its
  predicted address authenticated on inbound (`_authenticateOrigin` reads the prediction, not the
  status), so an address nobody has verified can originate messages once a route to its chain
  exists. Set no route, id, or peer to a chain until it is `Live`. The generated payloads add and
  mark in one batch, so they never leave a chain `Pending` with a route. A chain the provider was
  never added on is refused.
- **`markLive` names no deployer.** It marks whatever the entry holds when it executes. Schedule it
  with the operation that holds any `rekeyPending` or `addProviderOnChain` for the pair as its
  `predecessor`, and read `deployedBy` and `predictTransceiver` again on the day it executes: a
  re-key that lands between your review and the mark moves the address you reviewed.
- **The seeded home is live with no review.** The first deployer's transceivers on the home are
  not checked by any registry. Deploy them and run this list before relying on the seed.

## Rotating the deployer

Use this when the account that broadcasts `LockedProxyDeployer.deploy` is compromised, or retired.
Chains already `Live` keep their addresses: the deployer is write-once per (provider, chain).

1. Pick the new deployer: any address that can call `LockedProxyDeployer.deploy` on every chain
   to be added, a plain key or a contract at one address everywhere. It needs no role.
2. Schedule `setCurrentDeployer(new)` on every registry. Schedule every later call with this
   operation as its `predecessor`, so it executes first on every chain. For the parity chains
   this is scripted, with step 3 in the same timelock batch (see below).
3. For each (provider, chain) that is `Pending`, schedule `rekeyPending(chainKey, provider, new)`.
   Until then the compromised key can still deploy at the old address. It cannot be marked live,
   so nothing is sent there, but a `Pending` entry is still authenticated inbound (previous
   section), which is why the re-key should be scheduled with step 2 and routes to a `Pending`
   chain should wait. A `Live` entry cannot be re-keyed.
4. For each chain added from now on, schedule `addProviderOnChain(chainKey, provider, new)`. A
   registry that applied step 2 later than this reverts `DeployerMismatch` and can be retried
   once it has.
5. Deploy each new chain's contracts with `--sender <new>`, verify them (previous section), then
   `markLive`.

```
NEW_DEPLOYER=<address> PENDING_CHAINS=<chain,...> PENDING_PROVIDERS=<provider,...> \
  forge script script/RotateDeployer.s.sol
```

It reads nothing on chain and writes Safe Transaction Builder batches to `out/rotation/`: 1.
`1-schedule-home.json` and 2. `2-schedule-remote.json`, both by the governor's owner (the second
is one message per other chain, from the first proposer's transmitter to its receiver there, a
proposer of that chain's timelock), then 3. `3-execute-<chain>.json` on each chain, by anyone once
its delay has passed. Each registry gets one batch: `setCurrentDeployer(new)`, then `rekeyPending`
for every pair named by `PENDING_CHAINS` and `PENDING_PROVIDERS` (equal-length lists of the names
used in `deploy/`). Name only pairs that are `Pending` in the registries: a `Live` pair makes the
whole batch revert, and the script cannot tell, because it reads nothing on chain. It refuses a
zero `NEW_DEPLOYER` and `governance.toml`'s `deployed_by`, and covers chains the first deployer
deployed.

A chain deployed under another deployer has a different transceiver address, so every conduit
homed elsewhere has a different receiver address there than its transmitter's, and
`predictConduit` gives it. Every transceiver reads each remote chain's transceiver from the
registry, so a chain's peers (LayerZero's `setPeer`, Wormhole's emitters) are that prediction. The
generated payloads in `out/governance/` cover the first generation only.

zkSync, Tron, and `other` chains take their counterparts from the registry's deriver params, not
from the deployer, so `rekeyPending` does not change what a transceiver derives there. Re-key
such a chain with `setDeriveParams` as before, and gate it the same way: `addProviderOnChain`
then `markLive`. Nothing tests this path.

One deployer serves every provider, so one `setCurrentDeployer` and a `rekeyPending` for each
`Pending` pair retire a compromised key for all of them before any replacement transceiver is
deployed. A pair is exposed only until those operations execute, one timelock delay after they are
scheduled, so schedule them together. Provider salts must differ (the scripts check; a registry
does not).

The registry stores one 32-byte slot per (provider, chain).
