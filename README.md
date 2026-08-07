# xsafe protocol

## Spec

Secure multisig operations across chains from the most decentralized EVM: Ethereum.

## Design docs

- [`docs/message-flow.md`](docs/message-flow.md) — the two send paths, wire formats, and
  what each contract does
- [`docs/encoding.md`](docs/encoding.md) — call serialization and the commitment preimage,
  on EVM and elsewhere
- [`docs/todo.md`](docs/todo.md) — everything outstanding, ordered by what blocks what

Where this file and those disagree, they are the newer statement.

## Layout

```
src/
  addressing/     Erc7930, ChainType, ChainKey, Move        no imports outside itself
  derivation/     AddressDerive, VmDeriver, Starknet/Sui, Blake2b256
  registry/       ChainRegistry, ForeignRef, IRefValidator, IChainRegistryRoutes
  validators/     StarknetValidator, MoveValidator          pluggable, per chainKey
  messaging/      MessagingContext, Commitment, Call, Payload, Envelope, Executor
    outbound/     OutboundBase -> TransmitterBase
    inbound/      InboundBase  -> ReceiverBase
    transceiver/  TransceiverBase -> Hub / Spoke
  protocols/      per message provider; the only files naming an SDK
  factories/      XSafeProxy
```

Dependencies run one way — `addressing` is a leaf, and nothing above it is imported by
anything below:

```
addressing <- derivation <- registry <- validators
     ^                          ^
     +------- messaging --------+ <- protocols
```

**There is no `libs/` or `utils/` folder.** A folder named for what a file *is not* is a
place to put things rather than a statement about them, and every file here has a domain:

- **`derivation/AddressDerive`** holds zkSync, Tron, Cosmos `instantiate2`, Solana PDA/ATA,
  NEAR, and Bitcoin derivations — the computational core `VmDeriver` dispatches into, so it
  sits beside it
- **`addressing/Move`** is Move address encoding and the `MoveQualifier` that travels
  alongside one. The ref type it attaches to is `ForeignRef`, in the registry
- **`messaging/Commitment`** computes *the* commitment the whole protocol turns on, and
  `Commitment.hashCalls(destinationChainKey, calls)` says so at the call site
- **`registry/ForeignRef`** is the registry's record type, not a utility
- **`registry/IRefValidator`** is the registry's generic extension point, so it lives with
  the registry rather than inside any one deriver — otherwise `Move` would have to import
  Starknet to say what shape its validator is
- **`validators/`** holds `StarknetValidator` and `MoveValidator`, pluggable components
  wired per chainKey via `setValidator` rather than buried in the derivation library each
  happens to call
- **`derivation/Blake2b256`** is a general EIP-152 hash primitive, not a Sui detail
- **`Erc7930.minimalBigEndian`** is the eip155 chain-reference *encoding* rule, so it lives
  next to `parseStrict`, which rejects violations of it. In `derivation` it would make
  `addressing` import `derivation` while every deriver imports `addressing` back — a folder
  cycle over one integer helper

## Assumptions

- All contracts are created via Arachnids's create2 factory with salt.
  - 0x4e59.. if possible, zk-chains for example utilize their own respective create2 factory
- Compiled against `evm_version = "paris"`, pinned in `contracts/evm/foundry.toml`
  - PUSH0 (Shanghai) is unavailable on zkSync, Tron, and several L2s. CREATE2 parity
    requires byte-identical initcode on every chain, so the target must not vary.
- Proxies
  - All are upgradeable
  - Initial arguments
    - Deployer as owner
    - Nick's factory as implementation
  - Immediately upgraded to
    - ProxyAdmin as owner
    - Proper implementation
- All ProxyAdmins are owned by the omnsig msig

### Protocol: Registries

#### Ethereum: ChainRegistry

Owned by the xsafe msig. Two halves that only make sense together: a **directory** of
declared routes, and a **resolution table** of where those routes actually land.

##### Directory (owner-declared)

- Enumerable set of `chainKey` — `keccak256` of the canonical ERC-7930 chain identifier
  - `addChainKey(bytes identifier)` takes the envelope, not a bare hash, so the key is
    always reproducible and `parseStrict` rejects a non-canonical framing before it
    becomes a permanent mapping key. An account envelope is reduced to chain-identifier
    form, so `chainKey` is stable across every address on a chain.
  - `removeChainKey` refuses while any route still points at the chain
- Enumerable set of `messageProvider` — `keccak256` of the provider name
  - `addMessageProvider(string name)` / `removeMessageProvider(bytes32)`
- `chainKey => messageProvider => transceiverId` via `setTransceiverId` (both keys must
  already be registered)

**The registry holds no provider routes.** A message provider's own name for a chain — a
LayerZero eid, a Hyperlane domain, a Wormhole uint16 — lives on the **transceiver**,
because that is the contract that sends and receives. Keeping it here would put a second
shared contract in the path of every send and let a compromised one misroute a payload;
on the execute-on-arrival path there is no commitment binding the destination, so a wrong
id means the payload runs on the wrong chain.

##### Resolution (`transceiverId => ForeignRef`)

A transceiver's location is not a declaration, it is a claim carrying a trust grade.
`ForeignRef` is `{ id, chainKey, provenance, interop }`, where `id` is `keccak256` of the
canonical ERC-7930 envelope and is the only key. Arbitrary-length identifiers are handled
by the envelope, so NEAR named accounts, Cardano addresses, TON workchain+account_id,
Move type tags, and 20-byte EVM addresses all take the same shape.

`Provenance` is ordered and monotonic — upgrades allowed, downgrades revert:

| Grade | Meaning | How |
| --- | --- | --- |
| `Derived` | Recomputed on Ethereum from inputs in the signed calldata | `resolveEvmCreate2` / `resolveEvmCreate3` / `resolveDerived`, or the default counterpart |
| `Committed` | **No producer today** — retained only as a cap value | — |
| `Attested` | The destination asserted it; nothing here checks | callback alone |
| `Unresolved` | Empty slot | — |

`Committed` has no producer. It exists only as a **cap**: several chains are configured at
it through `setMaxProvenance`, where its job is to make `Derived` unrepresentable, and
removing it would renumber `Derived` and silently loosen every one of those caps. What
protects a reported reference instead is that its slot is **write-once** — a replayed or
hostile second report cannot repoint a receiver already on record.

- CREATE2/CREATE3 derivation is the **default** for EVM destinations: no message, no
  latency, no bridge trust
- Grading happens in the registry, never at the caller — no provenance field is accepted
  over the wire, so a remote party cannot mark its own homework
- `setMaxProvenance(chainKey, cap)` caps what a chain may be recorded at. Starknet must
  be capped at `Committed`: its address derivation is Pedersen and cannot be recomputed
  on the EVM, so without a cap an owner could compute it off-chain and store it as
  `Derived`. The cap makes the stronger claim unrepresentable rather than discouraged.
- `setValidator(chainKey, IRefValidator)` adds value-range checks the envelope cannot
  express structurally (e.g. Starknet's `L2_ADDRESS_UPPER_BOUND`)
- Reads state their bar: `requireRef(slot, minProvenance)`,
  `transceiverLocation(transceiverId, minProvenance)`, and `transceiverFor(chainKey,
  messageProvider, minProvenance)` which does route lookup and location read in one call
- **Callbacks are authenticated per provider, and the caller names the provider.**
  `localTransceiver[messageProvider]` is the only address permitted to deliver a
  resolution callback for that provider, and `providerOfTransceiver` reads it back. A
  single `sourceTransceiver` address meant a second provider's hub could never report at
  all — the directory was keyed per provider while the permission was not. The callback
  therefore takes no `messageProvider` argument: it is a property of `msg.sender`, not a
  claim the message gets to make about itself
- **Routes are declared by the owner, once.** `setTransceiverId` refuses a repoint —
  re-writing the same id is a no-op, a different one reverts. A transceiver id names the
  contract every message to that chain authenticates against, so a mutable pointer is a
  standing ability to redirect the route; moving one is a redeploy, not a config edit. The
  callback deliberately does **not** write routes any more: a destination reporting its own
  address was choosing that authentication target for us, which inverts who decides
- **An unset route defaults to address parity**, so the common case needs no configuration
  at all. A transceiver is deployed as a proxy through Nick's factory, so hub and spoke
  share initcode and salt and land on one address wherever Ethereum's CREATE2 formula
  holds — the local transceiver's own address is the right answer for every such chain at
  once, graded `Derived` because it is recomputed here with no bridge trust.
  `defaultCounterpart` withdraws in exactly the two places the parity argument fails:
  non-`eip155` chains, where a 20-byte address means nothing, and any chain capped below
  `Derived` by `setMaxProvenance`, which is how zkSync and Tron — `eip155` with different
  CREATE2 formulas — are excluded without a second flag that could disagree with the cap

##### Salted deployment (`messageProvider => ProviderDeployment`)

A provider records the CREATE2 inputs its contracts deploy from, so Ethereum can reproduce
every address in the system without deploying anything.

```
setProviderDeployment(messageProvider, salt, transceiverInitCodeHash, accountInitCodeHash)
setCreate2Factory(chainKey, factory)          // defaults to Arachnid's 0x4e59..

predictTransceiver(chainKey, messageProvider) view
predictXSafeAccount(chainKey, messageProvider, owner, salt) view
```

- **The salt is per provider, not per chain.** One salt used everywhere is what makes a
  provider's transceiver land on one address on every parity chain — the property
  `defaultCounterpart` rests on, but stated as inputs rather than assumed from a local
  deployment
- **It exists to be mined.** A transceiver is deployed as a proxy and then frozen, so its
  address is fixed for the life of the protocol and appears in calldata forever after: in
  peer tables, in payload targets, in every account address derived from it. Calldata zero
  bytes cost 4 gas against 16, so a salt ground for leading zeros is a permanent discount.
  Recording the salt is what makes the mined address reproducible here
- **Two CREATE2 steps, both inputs known.** The transceiver derives from the provider's
  salt; an account derives from the transceiver with the owner as its salt. So an account
  address is computable on Ethereum for any owner on any parity chain before a single
  message has crossed — which is what lets it be pinned inside a payload not yet sent
- `accountInitCodeHash` is `XSafeProxy`'s, the same constant for a transmitter and a
  receiver. That independence from the implementation is exactly why one owner has one
  address everywhere
- **Write-once.** Changing it moves every address derived from it — the transceiver on
  every chain, and every account under all of them. That is a redeploy of the provider's
  entire footprint, not a config edit
- `defaultCounterpart` prefers this derivation over address parity when a record exists.
  Both answer `Derived`, but this one states its inputs and works before a hub exists

##### Uniform derivation (`derivation/VmDeriver.sol`)

One standalone stateless contract implements every derivation the EVM can perform, and
`ChainRegistry` holds `chainKey => IVmDeriver` plus the stored params for that chain. The
result is that configuring any destination is the same three calls, and reading any
destination is the same function, regardless of VM:

```
setDeriver(chainKey, vmDeriver)
setDeriveParams(chainKey, abi.encode(Scheme, schemeParams))
setTransceiverId(chainKey, messageProvider, transceiverId)

expectedTransceiver(chainKey)            -> canonical ERC-7930 envelope
expectedTransceivers(messageProvider)    -> the same, for every registered chain
resolveTransceiver(chainKey, messageProvider, paramsCommitment)
```

**How it normalizes.** No argument list fits every VM — CREATE2 wants
`(deployer, salt, initCodeHash)`, a Solana PDA wants `(seeds[], bump, programId)`,
CosmWasm wants `(checksum, creator, salt, initMsg)`. So the params stay **opaque**: an
ABI-encoded blob the deriver decodes per scheme. What is uniform is the two ends — every
deriver takes an ERC-7930 chain identifier and returns an ERC-7930 account envelope on
that same chain, so the registry stores the result without knowing which VM produced it.

**Dispatch is two-dimensional and has to be.** Ethereum, zkSync Era, and Tron are all
`eip155` with three different CREATE2 formulas, so ChainType alone is insufficient; the
same scheme must also work across chains, so Scheme alone is insufficient. `supportsScheme
(chainType, scheme)` is checked when params are wired, not at first resolve.

| Chain type | Schemes |
| --- | --- |
| `eip155` | `EvmCreate2`, `EvmCreate3`, `EvmCreate`, `ZkSyncCreate2`, `ZkSyncCreate`, `TronCreate2` |
| `solana` | `SolanaPda`, `SolanaAta`, `SolanaCreateWithSeed` |
| `bip122` | `BitcoinP2wpkh`, `BitcoinP2wsh`, `BitcoinP2sh` |
| `cosmos` | `CosmosInstantiate2` (with wasmd truncation length) |
| `near` | `NearDeterministic`, `NearEthImplicit`, `NearImplicit` |
| `sui` | `SuiAddress`, `SuiMultisig`, `SuiObjectId` |
| `aptos`, `starknet` | none — deliberately underivable, route through committed/attested |

- The interface is `view`, not `pure`: Sui's BLAKE2b-256 goes through precompile 0x09,
  and one non-pure member forces the whole interface
- `expectedTransceiver` re-checks that the deriver's envelope hashes to the **requested**
  chainKey. A deriver is external code; without that check a wrong or hostile one could
  return an envelope for a different registered chain and land it in this chain's route
- `resolveTransceiver` requires a `paramsCommitment`. `_deriveParams` was written in an
  earlier transaction, so without it the signers approving the resolve would be approving
  a pointer rather than the inputs — and `Derived` specifically claims the inputs were
  approved
- `expectedTransceivers` skips chains with no deriver, params, or route rather than
  reverting, so one unconfigured chain does not blind the view of the rest

##### Onboarding a chain type

**The registry accepts a ChainType it has never heard of, and that is the hazard.**
`ChainType.sol` is an allocation table rather than an enum — every value is a plain
`uint16`, and `Erc7930.parseStrict` reads the field as an opaque integer without checking
it against the table. So an unallocated type registers, routes, and resolves refs with no
code changes at all. What it does *not* get is a canonicity rule, and nothing reports that.

`parseStrict` carries per-profile rules only for the profiles it knows: minimal chain
references for eip155, fixed 32-byte addresses for starknet. A type with no rule accepts
**both** `0x00cafe` and `0xcafe` as chain references for the same chain, calls both
canonical, and hashes them to two different chainKeys — the exact split-brain the canonicity
argument exists to prevent, arrived at silently. `test/UnknownChainType.t.sol` demonstrates
it, alongside the contrast case where eip155 rejects the identical mistake.

Adding the constant is therefore necessary and not sufficient. The full checklist:

1. **Allocate the value in `addressing/ChainType.sol`** and nowhere else. Two files each
   picking a provisional value is how two chains silently share a registry key. Keep
   CASA-assigned values below `PROVISIONAL_FLOOR` (0xFF00); `isProvisional` keys off that
   range, and a provisional value means every `id` for that chain changes if CASA later
   publishes a different one — a re-keying migration, not a config edit
2. **Write its canonicity rule into `Erc7930.parseStrict`**, next to the eip155 and starknet
   cases. This is the step with no compiler or test to remind you, and the only one whose
   omission fails silently
3. **Attach an `IRefValidator` via `setValidator`** for value-range constraints the envelope
   cannot express structurally — Starknet's `L2_ADDRESS_UPPER_BOUND` is the worked example
4. **Set `setMaxProvenance`** to the strongest grade the chain can honestly reach. Without a
   cap, `resolveDerived` lets an owner store an off-chain computation as `Derived`
5. **Deploy an `IVmDeriver` and `setDeriver`** if the chain needs better than `Attested`.
   `VmDeriver.supportsScheme` is a closed two-dimensional dispatch, so the stock deriver
   rejects every scheme for a type it does not know — this is the one step that needs code
   rather than configuration, and the registry's per-chain `deriverOf` is the seam for it
6. **Decide the commitment scheme** if the chain does not hash with keccak256 — see
   [`docs/encoding.md`](docs/encoding.md)

Steps 1, 3, 4, and 6 fail loudly if skipped. Step 5 fails loudly. **Step 2 does not.**

##### Move chains (Aptos, Movement, Sui)

Two gaps the ERC-7930 envelope cannot close, handled in `addressing/Move.sol`:

1. **No assigned chain type.** CASA defines CAIP-350 profiles for eip155, bip122, solana,
   and starknet only. `aptos/` and `sui/` have CAIP-2 profiles but no CAIP-350, so there
   is no standard ChainType. `CT_PROV_APTOS` (0xFF01) and `CT_PROV_SUI` (0xFF02) are
   **provisional**, confined to 0xFF00..0xFFFF so `isProvisional(slot)` can flag affected
   refs. If CASA assigns different values, every `id` for those chains changes — that is
   a re-keying migration, not a config edit.
2. **A Move module has no address.** A transceiver on Aptos is
   `account_address::module_name`; on Sui it is a function in a package. The 7930 Address
   field carries **only** the 32-byte account/package ID. Everything else — module name,
   function name, BCS type args, Sui `originalPackageId` and `initialSharedVersion` —
   lives in a `MoveQualifier` attached alongside.

- `ForeignRef.qualifierHash` is kept **outside** `id`, so a call target and the address it
  lives at remain the same registry key
- `setQualifier(transceiverId, q)` validates the Move identifier charset and rejects
  Sui-only fields on Aptos, so one logical reference cannot hash two ways. A qualifier is
  a declaration, not a derivation: it has no provenance of its own and inherits the
  grade of the ref it attaches to
- The qualifier travels **over the wire** with the address:
  `onForeignRefResolved(slot, requestId, interop, qualifierData)`. A commitment
  registered via `registerExpectationWithQualifier` is checked against what the
  destination reported, not against local storage
  - Committing to a qualifier and receiving none fails — silence is not agreement
  - An uncommitted message may not repoint a live call target; that needs a fresh
    transceiver id
- `_store` preserves an attached qualifier across re-resolution — the module and function
  names are a deployment convention that outlives an address change
- `MoveValidator` enforces the fixed 32-byte address width. AIP-40 short form (`0x1`) and
  the padded form are the same address, so accepting both would give one address two
  registry keys. Register it per Move `chainKey` via `setValidator`
- Suggested caps: Aptos/Movement at `Committed` (SHA3-256 is not the EVM's keccak256, so
  addresses are not recomputable here). Sui can reach `Derived` via `SuiDerive`'s
  Blake2b-256 through `resolveDerived`, since that derivation is `view`, not `pure`

### Protocol: Accounts

**One owner, one address, every EVM chain.** An owner's transmitter on Ethereum and their
receiver on Base are the same address. That is the property everything in this section
exists to produce.

#### XSafeProxy

Every xsafe account — transmitter and receiver alike — is deployed as this proxy and then
frozen.

**It takes no constructor arguments, and that is the entire point.** CREATE2 hashes the
initcode, so anything baked into it changes the address. A minimal clone cannot serve here
for exactly that reason: EIP-1167 embeds the implementation address in its initcode, so a
transmitter clone and a receiver clone could never share an address however their deployer
and salt were chosen. With no arguments the initcode is one constant byte string, and the
address depends only on deployer and salt.

**There is no way to upgrade without locking.** The single admin operation —
`upgradeInitializeAndLock` — installs the implementation, runs the initializer by
delegatecall, and zeroes the admin, in that order and in one call. Not "the deployer is
expected to lock afterwards": there is no reachable state in which an account has real
logic and a live upgrade key. The key exists for part of one transaction, held by the
transceiver that created the account, and cannot outlive it.

**Dispatch is transparent-style**, routed inside `fallback` rather than declared. A
declared admin function would shadow that selector on the implementation forever; once the
admin is zeroed no caller can match it — `msg.sender` is never the zero address — so every
selector delegates from then on and the proxy is indistinguishable from a plain one.

- A blank proxy delegates to the zero address, which **succeeds silently** — a call to a
  codeless account returns empty rather than reverting. That is tolerable only because a
  blank proxy never survives the transaction that created it: `_createXSafeAccount`
  deploys, arms, and locks in one function. It would become a real hole if those were ever
  split

#### Account creation

`TransceiverBase` holds one concrete creation path and two virtuals for what each side
installs:

```
accountSalt(address owner, bytes32 salt) pure       // keccak256(abi.encode(owner, salt))
predictXSafeAccount(address owner, bytes32 salt) view
_createXSafeAccount(owner, salt, calls)             // deploy -> arm -> locked, one call

_accountImplementation() virtual                    // hub: transmitter  spoke: receiver
_accountInitializer(owner, salt, calls) virtual
```

- **The salt is `(owner, salt)`, and the owner half had to be there.** A CREATE2 address
  cannot be derived from itself, so the transmitter's own address could never have served;
  the owner is the one identity Ethereum and the destination both name. The caller's half
  is what lets one owner hold several accounts — one per purpose, per counterparty, per
  mandate — each with its own address on every chain. The two are hashed together, so no
  choice of salt reaches another owner's account
- **The salt crosses with the bootstrap message.** A spoke that only knew the owner could
  not reproduce the address its transmitter occupies on Ethereum, which is the whole
  property
- The proxy, the salt, and the deployer address are identical on both sides. Only
  `_accountImplementation` differs, and the derivation never sees it — the same argument
  that lets a hub and a spoke share an address, one level down
- `createTransmitter(bytes32 salt)` takes only the salt: **`owner` is `msg.sender` by
  construction, not by argument.** An owner passed in could be anyone, and the derivation
  only means something if the party it names is the party that asked for it. That binding
  is what stops one party squatting an address another intends to use — and here the
  address is theirs on every chain, not just this one
- **There is no public creation path on a spoke.** An account there exists because a
  bootstrap message arrived, and nothing else. An open one would let anyone deploy an
  owner's account empty, one transaction ahead of their bootstrap, and permanently deny it,
  since `XSafeProxy` arms exactly once

### Protocol: Endpoints

**A transmitter is its own message-provider endpoint, and it sends to its receiver
directly.** The transceiver is not in the path of a normal message. See
[`docs/message-flow.md`](docs/message-flow.md) for the full flows.

#### Normal send — transmitter to its own receiver

```
owner → transmitter.send(8453, calls)          onlyOwner, payable for the bridge fee
      → _sendMessage(chainKey, abi.encode(calls))
      ══ bridge ══
      → receiver: origin.sender == peer, decode, execute      nonReentrant
```

The peer relationship is exactly 1:1 — one transmitter, one receiver, one chain pair —
which is the shape every provider's peer table already has. That is what lets a transmitter
be an endpoint at all; a shared transceiver fanning in from N transmitters would not fit.

**Deferring execution uses the same path.** To pin a hash now and run the array later, send
a payload whose one element calls the receiver's own `commit`. It arrives, executes, and
stores the hash; anyone supplies the matching array to `finalize` afterwards. Nothing on
the wire distinguishes this from any other payload, so there is no message-type tag
anywhere in the protocol.

#### Bootstrap — no receiver on the destination yet

There is no peer to send to, so the message goes to the one contract that already exists on
that chain.

```
owner → transmitter.bootstrap(chainId, calls)  onlyOwner
      → hub transceiver: (counterpart, route) = _route(chainKey)   ← provenance bar here
      ══ bridge ══   Envelope.encodeBootstrap(owner, salt, calls)
      → spoke transceiver: authenticate as the hub, then
        _createXSafeAccount(owner, calls):
          deploy XSafeProxy at accountSalt(owner, salt)
          arm it with the receiver implementation, run the payload, lock  — one call
        → receiver executes the calls, then reports its own address back
      ══ bridge ══
      → hub transceiver → onDestinationReceiver → registry
```

**The message carries the owner and their salt, not the transmitter.** The destination derives the account
address from it, which is what puts the transmitter and the receiver on one address; the
transmitter's own address could not serve, since a CREATE2 address cannot be derived from
itself.

The provenance bar therefore gates the **first** message to a chain, not every send.

#### Transceiver

Two jobs, and nothing else: stand up an account on a chain that has none, and report back
where it landed. One per message provider per chain, owned by the xsafe msig.

**A hub makes transmitters; a spoke makes receivers.** Manufacturing lives on each side
rather than in the shared base, so a hub does not merely decline to create a receiver — it
has no function that could. That matters because an address holds exactly one contract: a
receiver on Ethereum would collide with the transmitter that belongs there.

#### Receiver

One per owner per destination, at the same address that owner's transmitter occupies on
Ethereum. Holds the provider's receiving half with that address as its peer, a queue of
pending commitments, and the call policy.

**Its peer is its own address.** Since transmitter and receiver share an address, the
contract on Ethereum a receiver answers to sits exactly where the receiver sits here.

### Inherited contracts

```
MessagingContext                       errors shared by both directions
 ├── OutboundBase                      _sendMessage. NO owner, NO storage
 │     └── TransmitterBase             + owner, send/sendTo/bootstrap/execute
 │                                       + the provider's endpoint half
 ├── InboundBase                       the two commitment rules. NO owner, NO storage
 │     └── ReceiverBase                + commitment queue, reentrancy guard
 │                                       + the provider's receiving half
 └── Executor                          _execute + isAllowed. NO owner, NO storage

TransceiverBase is OutboundBase, Initializable, UUPSUpgradeable
 ├── HubTransceiverBase                + registry, provenance bar, MAKES TRANSMITTERS
 └── SpokeTransceiverBase              + HOME_CHAIN_KEY constant,  MAKES RECEIVERS
```

`TransmitterBase` and `ReceiverBase` both inherit `Executor`. **A transceiver does not** —
it has no payload of its own, and keeping the capability out of its inheritance makes that
structural rather than a promise not to call something.

**`Executor` is shared because both ends run payloads**, not because the code was long. A
receiver runs what arrives over a bridge; a transmitter runs what its owner hands it
directly on this chain. Those differ in how the payload was authorized and in nothing else,
so the loop, the policy check, and the all-or-nothing rule are stated once.

**A transceiver sends and it authenticates. It is not a receiver.** It takes `OutboundBase`
for the sending half and an inbound funnel of its own; it is deliberately neither a
`TransmitterBase` nor a `ReceiverBase`:

- Inheriting `TransmitterBase` would collide on `owner`. That contract does two jobs — the
  sending mechanics, and the per-user entry point that owns them — and a transceiver needs
  the first while already having its own (different) authority for the second.
  `OutboundBase` is the mechanics with no ownership and no storage
- Inheriting `ReceiverBase` would cost three fields the transceiver never writes
  (`sourceTransmitter`, `parentTransceiver`, the commitment queue) and four entry points it
  would have to override into reverting. It is not an `InboundBase` either: the two
  commitment rules (`_requireCommittable`, `_requireMatchingCalls`) live where the
  commitment lives, in the receiver. What the transceiver holds during bootstrap is
  *calls*, not a commitment
- `OutboundBase`, `InboundBase`, and `Executor` all declare **no storage**, which is what
  makes them free to mix into a contract that already has a layout: no slot to collide, no
  gap to reserve

#### MessagingContext

Roles, modifiers, and errors shared by both halves. The commit/finalize error vocabulary
(`NothingCommitted`, `CommitmentMismatch`, `ZeroCommitment`) is declared here because
`OutboundBase`, `InboundBase`, and `Executor` all derive from it and duplicate declarations
would collide in a contract that mixes them.

#### TransceiverBase

**Stands up an account on a chain that has none, and reports back where it landed.** Two
jobs, and nothing else. It is not in the path of a normal message: once a receiver exists,
its transmitter sends to it directly.

One transceiver per protocol per chain, **owned by the xsafe msig**.

```
// TransceiverBase — both sides
accountSalt(address owner) pure            // keccak256(abi.encode(owner))
predictXSafeAccount(address owner) view
counterpartOn(bytes32 chainKey) view       // -> _counterpartOn, hub or spoke
routeTo(bytes32 chainKey) view             // -> _routeTo, hub or spoke
lockUpgrades()

// HubTransceiverBase — Ethereum
createTransmitter(bytes32 salt) returns (address)   // owner is msg.sender
predictTransmitter(address owner, bytes32 salt) view

// SpokeTransceiverBase — everywhere else
bootstrapInbound(address owner, bytes32 salt, Call[] calls)   // self-call
```

**The route table lives here, and both directions come from one setter.** `setRoute` is
write-once and `onlyAdmin`: re-pointing one would redirect every message to that
destination at once, which is a redeploy rather than an edit. It maintains the reverse
index in the same call, because two setters is how the two directions drift apart, and it
is injective — two chains sharing one provider id would let an inbound message be
attributed to the wrong source, which is a forgery primitive rather than a config mistake.

The stored type is `bytes`, because the shape is the provider's business. A concrete
binding wraps it in a typed setter: `LzHubTransceiver.setEid(chainKey, uint32)`, and a
Hyperlane one would wrap the same slot as a `uint32 domain`. A spoke needs no table at all
— it has one destination and knows it at compile time.

**A hub cannot make a receiver — not gated, absent.** Manufacturing lives on each side
rather than in this base, so there is no entry point on the Ethereum side for a later
change to expose. That is what a transmitter and its receivers sharing one address
requires: an address holds exactly one contract, so a receiver on Ethereum would collide
with the transmitter that belongs there.

Consequently `TransmitterBase.execute` runs its payload **in the transmitter itself**
rather than through a local receiver. There is no receiver on Ethereum to run it in.

`bootstrap` is **permissionless**, and the argument is the one `createTransmitter` also
rests on: the only reachable outcome is an account keyed to the caller's own address, which
answers to nobody else. It is also the only caller of `_route`, and therefore the only
place `minCounterpartProvenance` is enforced — a bar on the first message to a chain rather
than on every send.

**This base is the symmetric half, and only that.** Account creation, reporting, and the
upgrade lock work identically wherever the transceiver is deployed; only what gets
installed differs, behind `_accountImplementation` and `_accountInitializer`. Everything about *addressing* a
counterpart does not, because the two sides have opposite cardinality — see the hub/spoke
split below. That asymmetry is isolated behind two virtual hooks, `_counterpartOn` and
`_routeTo`.

- They are **separate hooks, not one returning a pair.** The counterpart and the provider
  route are configured independently and can be missing independently: a chain can have a
  resolved counterpart with no eid set yet, or an eid with the counterpart still
  unresolved. One combined lookup would make a half-wired destination un-inspectable — you
  could not read the part that *is* configured to find out which part is not

- **One inbound funnel, two virtuals.** `_onInbound(route, sender, message)` is what every
  protocol adapter routes an arriving message into. It authenticates first, then dispatches:
  - `_authenticateOrigin(route, sender) -> chainKey` varies by **cardinality**. A spoke
    compares against two constants; a hub reverse-indexes the route through the registry
    and checks the sender against that chain's counterpart **at its provenance bar**, so a
    chain whose counterpart is only `Attested` cannot drive a hub demanding `Derived`
  - `_handleInbound(chainKey, message)` varies by **direction**. A spoke receives bootstrap
    messages, a hub receives receiver reports — nothing else, either way
  - They are separate hooks because those two things vary independently, and folding them
    into one overridable method would let a subclass get the second right and the first
    wrong
  - **Authentication is not the adapter's job.** It runs in the base, before anything is
    decoded, so a new protocol binding cannot ship without it. A transceiver decides which
    cross-chain payloads are authentic; leaving that to be re-implemented per provider is
    how one provider ends up without it
- **`Envelope` carries no message-type tag**, because every channel carries exactly one
  shape. Bootstrap messages travel hub → spoke, reports travel spoke → hub, and a normal
  payload never touches a transceiver at all. Committing is folded into the call array as a
  self-call to the receiver's `commit`, so even the transmitter → receiver channel has one
  shape rather than two. See [`docs/message-flow.md`](docs/message-flow.md)
  - The transmitter is **in** the bootstrap message rather than inferred. The destination
    needs it for the receiver's CREATE2 salt, for the identity that receiver answers to,
    and to set the receiver's peer — and nothing the bridge reports says who on Ethereum
    authorized it, since the hub transceiver is shared by every transmitter
- **The transceiver manufactures. It does not relay.** A bootstrap message arrives, the
  receiver for that transmitter is created, and the calls are handed to it inside
  `initialize`. Creating and initializing is its entire relationship with a receiver — it
  never calls `commit`, `finalize`, or `execute`, so it holds no standing authority over
  one after the first message. A bootstrap for a receiver that already exists reverts with
  `ReceiverAlreadyExists`: `initialize` is single-shot and there is no other way in. On an EVM destination the bootstrap queue is transient — store, deploy, and flush
  all happen in the inbound handler — and it is storage rather than a local only because
  deployment is not synchronous on Starknet or the Move chains
  - It is **not an `InboundBase`**. Both commitment rules live where the commitment lives:
    `_requireCommittable` in the receiver's `commit`, `_requireMatchingCalls` in its
    `finalize`. What the transceiver holds during bootstrap is calls, not a commitment. It
    keeps `OutboundBase` because it does send — bootstrap messages onward, and the spoke's
    receiver-address report home
  - **There is no public creation path on a spoke.** An account exists there because a
    bootstrap message arrived, and nothing else. An open one would let anyone deploy an
    owner's account empty, one transaction ahead of their bootstrap, and permanently deny
    it — `XSafeProxy` arms exactly once
  - **`initialize` takes the calls and runs them**, delegatecalled inside the same
    `upgradeInitializeAndLock` that installs the logic and drops the key. The receiver then
    calls back here with its own address so the transceiver can report it home
  - **Provider setup happens in the initializer, because there is no second chance.** The
    proxy locks in the same call that arms it, and an account's peer table and delegate are
    gated on its owner — which the transceiver is not. So a transceiver has no authority
    over an account after creating it, and anything the provider needs configured is folded
    into `_accountInitializer`, which is `virtual` all the way down for that reason. The
    peer value itself is not provider-specific: it is the account's own address
- **Nothing to wedge.** A payload that can never execute fails at its own account — one per
  `(owner, salt)` — and blocks nobody. Isolation is
  structural rather than bookkeeping
- The salt is the **owner and their chosen salt**. An account address is therefore fixed
  for the life of the protocol — known before the first message, unchanged after the thousandth —
  so it can be pinned in a signed payload, and so the transmitter can point its peer at the
  address before the receiver exists
- **Upgrades lock one way.** The proxy must be upgradeable to get off the
  Arachnid/Nick's-factory implementation it is created with; once the real transceiver is
  in place, `lockUpgrades()` makes the change permanent and irreversible. A transceiver
  decides which cross-chain payloads are authentic, so a live upgrade key is a standing
  ability to forge one — locking turns "we promise not to" into "we cannot"
- **The account implementation is set at initialization and has no setter** — the
  transmitter's on the hub, the receiver's on the spoke. Changing it moves no account that
  already exists, since every proxy is locked the moment it is armed; it would only affect
  owners who have not created theirs yet, silently forking the population into two logic
  versions distinguishable only by when each arrived. That is a redeploy, not a config
  edit. Zero is refused at initialization, so a transceiver that cannot produce accounts
  never exists
- `LzHubTransceiver` does **not** inherit `LzTransmitter`: a transceiver is shared,
  msig-owned infrastructure and a transmitter is per-user, so merging them gives one
  contract two different owners. It takes `OutboundBase` instead, which is the sending
  half without the owner
- **`TransceiverBase` inherits no ownership.** Privileged operations go through
  `onlyAdmin`, and `_checkAdmin()` is declared and never implemented; the concrete contract
  satisfies it from whatever authority it already has — `_checkOwner()` for
  `OwnableUpgradeable` or LayerZero's `Ownable`, a role check for `AccessControl`, a bare
  address comparison for a msig
  - This is what lets a protocol binding join at the concrete contract: `LzTransceiver` can
    inherit `OAppUpgradeable` and satisfy `_checkAdmin` with OApp's own owner, and `OApp`
    never appears in `TransceiverBase`
  - Two ownership systems in one contract is not a style problem. It means a transceiver
    whose upgrades are "locked" behind one authority can still be reconfigured through the
    other — and a transceiver decides which cross-chain payloads are authentic
  - `test_authorityCanBeSuppliedWithoutOwnable` gates a transceiver that has no `Ownable`
    anywhere in its tree, which is the property the OApp case depends on

#### HubTransceiverBase / SpokeTransceiverBase

**The cardinality is the whole split.** Ethereum's hub talks to every destination; every
destination talks only back to the hub. A directory is what you need to hold N claims
about where remote code lives and how much each claim is worth. A spoke holds one, knows
it at compile time, and would gain nothing from the machinery but a mutable pointer to be
compromised.

| | Hub (Ethereum) | Spoke (everywhere else) |
| --- | --- | --- |
| Counterparts | N, learned | 1, a literal |
| `chainRegistry` | yes | **absent** |
| `messageProvider` | yes | **absent** |
| `minCounterpartProvenance` | yes | **absent** |
| `_counterpartOn` | registry lookup at the provenance bar | stored `homeTransceiver`, else revert |
| `_routeTo` | `providerRoute(chainKey, provider)` | `_homeRoute()` literal |
| `_handleInbound` | a receiver report | a bootstrap message |
| `onDestinationReceiver` | records into the registry | n/a — the spoke *sends* this |
| bootstrap queue | n/a | per transmitter, transient on EVM |

- `minCounterpartProvenance` is **inherently a hub concept**. It grades how much to trust
  a claim about a remote address, a question that only arises when the address was learned
  rather than known. A spoke's counterpart is a literal in its own bytecode, which is a
  stronger guarantee than `Derived`; carrying the field there would imply a grading
  decision nothing actually makes
- **The spoke's peer check is a comparison against a constant.** A hub must authenticate
  inbound against an N-entry set, which is mutable state an owner could repoint. There is
  no configuration by which a spoke could be made to accept a second origin, so the set of
  chains that can drive it is fixed at deployment and cannot be widened by anyone —
  including the local msig. Both halves are write-once: `HOME_CHAIN_KEY` is a compile-time
  literal, and `_homeTransceiver` is an initializer argument with no setter after it
- **The split moved no address, despite the different bytecode.** A transceiver is
  deployed as a *proxy* through Nick's factory, so the CREATE2 initcode is the proxy's —
  deployer as owner, factory as placeholder implementation — and is byte-identical for a
  hub and a spoke. They diverge only in what they are upgraded to afterwards, which the
  derivation never sees. On every EVM chain sharing Ethereum's CREATE2 formula, hub and
  spokes land on the same address
  - The registry's derivation holds for the same reason: it needs every spoke to be
    identical to the **other spokes**, not to the hub, so one `resolveEvmCreate2` at
    `Derived` still covers every EVM destination at once. `setDeriveParams` must carry the
    **proxy's** initcode hash, not an implementation's
  - The counterpart is nonetheless written rather than derived, because the chains where a
    spoke most needs certainty — zkSync and Tron, whose CREATE2 formulas differ, and every
    non-EVM VM — are exactly where the derivation does not hold, and a spoke has no
    registry to ask. One initializer argument is simpler and stronger than a derivation
    with three exceptions in it
  - **It is an initializer argument, not a setter plus a lock.** `setHomeTransceiver`
    followed by `lockHome` left a window in which the admin could repoint the one address
    the spoke authenticates every inbound message against. Writing it once at
    initialization closes the window rather than documenting it: there is no reachable
    state in which the value is set and still changeable. It costs nothing, because hub
    and spoke proxies share initcode and salt, so the hub's address is a
    `predictTransceiver` call rather than a deployment-ordering constraint
- `SpokeTransceiverBase.HOME_CHAIN_KEY` is a **`constant`, not an `immutable`**. An
  immutable set from a constructor argument lands in the deployed initcode, and CREATE2
  parity requires byte-identical initcode on every chain. The literal is
  `keccak256(0x00010000010100)`; `test_homeChainKeyMatchesEthereum` asserts it equals
  `ChainKey.forEvm(1)`, which is what keeps a hardcoded value honest
- The provider's id for the hub (`_homeRoute`) is likewise a literal in the concrete
  protocol contract — `LzSpokeTransceiver` returns eid 30101. An eid is exactly the kind of
  value that is wrong once and wrong forever; it belongs in the source a reviewer reads,
  not in a deploy script
- The **spoke still needs a transmitting half**, and only for one thing: reporting the
  receiver address home, which the receiver asks it to do during `initialize`. That is
  `_sendMessage(HOME_CHAIN_KEY, ...)` — the mirror of the hub's `onDestinationReceiver`.
  It is why `_send(bytes32, bytes32)` had to widen: a report is an address, a requestId,
  and a variable-length envelope, none of which fit in thirty-two bytes
  - **TODO:** the report goes out from inside the destination's inbound callback, and that
    costs native currency on the destination. Either the spoke carries a msig-funded
    balance per chain or the bootstrap message drops value across. Without one of those,
    bootstrap reverts on the return leg

#### ReceiverBase

The destination-side half, and **the endpoint a transmitter actually talks to.** Deployed
as an `XSafeProxy` by the transceiver, never directly, and holding the message provider's
receiving half with its transmitter as the peer.

```
initialize(address sourceTransmitter, Call[] calls)   // single-shot, by the transceiver
isSourceTransmitter(address) view returns (bool)

// the provider's inbound callback -> Payload.decodeCalls -> _execute   nonReentrant

// ICommitFinalize — two steps, separated in time
commit(bytes32 commitment) returns (uint256 index)  // onlyAuthorizedCommitter, incl. self
cancel(uint256 index, bytes32 expected)             // onlyAuthorizedCommitter
finalize(Call[] calls)                              // permissionless, head of queue
finalize(Call[][] batches)                          // permissionless, N in queue order

// IExecute — one step, same transaction
execute(Call[] calls)          // onlyAuthorizedCommitter

// queue reads
commitment() / nextIndex() / commitmentAt(i) / head() / queueLength() / pendingCount()
```

**Approvals are a queue, and execution is strictly FIFO.** `finalize` accepts only the array
matching the oldest outstanding approval, so a relayer holding two valid payloads cannot
choose which lands first. That matters because a payload sequence usually means something
only in order — approve then transfer, set then use.

- The queue is **append-only**. An entry is never moved, so the index `commit` returns
  names that approval for the life of the receiver
- `cancel` names the approval **twice** — the index says which slot, `expected` says which
  approval. Cancelling the wrong slot is otherwise silent: the queue loses a payload nobody
  chose to drop, and the first sign is a `finalize` that stops matching. It matters most
  on the remote path, where `cancellationCall` builds the element at approval time and it
  executes later, unwatched, against a queue that may have moved
- A **consumed** entry keeps its value and is passed by the head pointer; a **cancelled**
  one is zeroed in place. The two stay distinguishable on-chain afterwards, which deleting
  on finalize would collapse
- `finalize(Call[][])` is the same FIFO rule applied repeatedly, all-or-nothing. It cannot
  reorder the queue
- The head advances **before** `_execute`, so a payload that re-enters `finalize` finds its
  own approval already spent rather than discharging it twice
- A second `commit` does not collide with a live one; it appends. The same hash may be
  queued twice: two identical payloads are two separate approvals

**Ordering and cancellation are load-bearing for each other.** Strict FIFO means a payload
that can never execute — a target that always reverts, a call that is now invalid — would
stall every approval behind it forever. `cancel` is the escape hatch, and it is gated
exactly like `commit`: an authorized committer can already queue any approval, so letting it
withdraw one adds no authority, while leaving cancellation permissionless would hand any
caller a way to strip approvals. Neither feature should be removed without the other.

**The entry points take `Call[]` only.** An EVM receiver executes EVM calls; there is no
payload it can run that is not `(target, value, data)`, so an opaque overload would accept
elements it could only decode into this shape anyway or revert on. One entry shape means
one caller gate and one policy check rather than two of each that can drift.

The commitment it discharges may still have been built over opaque `bytes[]` — that layer
stays VM-agnostic, and `Commitment` hashes both forms to one value. See
[`docs/encoding.md`](docs/encoding.md).

**A proxy can hold a provider endpoint.** The endpoint address is an immutable in the
implementation's bytecode, which is correct because every receiver on a chain uses the same
one; the peer is per-account storage. Standing one up costs a peer and a delegatecall when
the transceiver arms it.

**The peer relationship is 1:1, and both ends are the same address.** One owner, one
account, one chain pair — which is exactly the shape every provider's peer table has. A
shared transceiver fanning in from N owners would not fit, and that is the reason the
receiver rather than the transceiver is the endpoint.

**Committing is a call, not a message kind.** A payload that should wait rather than run
carries one element targeting the receiver itself:

```solidity
calls[0] = Call({
    target: address(this),
    value:  0,
    data:   abi.encodeCall(ICommitFinalize.commit, (hash))
});
```

`isAuthorizedCommitter` therefore accepts `address(this)`. That is safe for a specific
reason: the only way to produce `msg.sender == address(this)` is through `_execute`, which
is reachable only via an authenticated inbound message or a gated `execute()`. A target
calling back presents itself, not the receiver. `commit` stays `external` so the self-call
is a real CALL rather than an internal jump.

**Two interfaces, and the trade between them is exact.** Exactly one of "the payload is
checked" or "the caller is checked" has to hold, and each interface picks a different one:

| | `finalize` | `execute` |
| --- | --- | --- |
| Payload checked against a hash | yes | **no** |
| Caller checked | **no** | yes |
| Steps | two, any distance apart in time | one |
| Event | `ReceiverFinalized` | `ReceiverExecuted` |

- **`execute` grants no authority `commit` does not already grant.** That is the argument
  the gate rests on. An authorized committer can pin the hash of *any* array and then let
  anyone finalize it, so it can already cause any array to run here. `execute` removes a
  round trip and a redundant hash, not a check — and because both are gated on
  `isAuthorizedCommitter`, widening one widens the other, which is the correct coupling
- **The check it skips has already happened one level up.** Commit/finalize exists for when
  the two steps are separated in *time* — a payload that lands now and is pushed through
  later, by anyone. When they happen in one transaction there is nothing left for a
  commitment to protect against
- **`execute` does not touch a pending commitment.** A hash pinned by `commit` stays
  pinned and still requires its own matching `finalize`. Consuming it would let an
  unrelated array silently discharge an approval made over a different one
- The event is deliberately distinct. An execution that skipped the hash comparison must
  be distinguishable on-chain from one that did not; a monitor that cannot tell them apart
  cannot audit either
- An empty array is refused by `execute`: with no commitment, nothing else establishes
  intent. Note that a commitment over an empty array *is* representable — zero calls hashes
  to `keccak256(abi.encode(chainKey))`, which is non-zero — so `finalize` does not refuse
  one. Worth deciding whether it should

- **`initialize` takes the calls and executes them.** It does not set a commitment. A
  payload that should wait rather than run says so itself, by carrying a self-call to
  `commit`, so nothing about the initializer has to know the difference. The reentrancy
  guard is initialized before the calls run
- **A receiver's only outbound message is its own address.** It is not an `OutboundBase`
  and has no `_sendMessage`. During `initialize` it calls back into the transceiver that
  created it, and the transceiver puts the report on the wire. That is the right shape
  because on the chains this path exists for the address is not predictable from Ethereum —
  Starknet's is a Pedersen hash chain the EVM cannot run — so the receiver is the only party
  that knows it. Reporting through the receiver rather than from the transceiver's own
  `predictXSafeAccount` also means the address that lands in the registry is one that exists
  and initialized, not one that was computed and might not
- `isSourceTransmitter` is the authorization predicate, exposed as a view so a caller can
  check before spending gas on a transaction that would revert. It returns false for the
  zero address so an unarmed account never authorizes a zero caller
- State, not immutables. The spec describes the transmitter and transceiver as immutables,
  but every account shares one implementation's bytecode — so every account would see the
  same value. They are set once in `initialize`, which `initializer` makes single-shot
- One receiver per owner per destination, reused for every payload. Commitments are a
  **queue**, not a single slot, so one pending approval does not block the next from being
  *recorded* — though it does block the next from being *executed*, since the queue is
  ordered. See the queue rules above, and `cancel` for the way out
- `commit` and `cancel` are gated on `isAuthorizedCommitter`: the parent transceiver, the
  source transmitter, or the receiver itself. **The last two are currently the same
  address** — a receiver's peer is its own address, since transmitter and receiver share
  one. Worth deciding whether to collapse them or keep them distinct against a future where
  they diverge. `finalize` is deliberately **not** gated —
  only the array matching the queued commitment at the head does anything, which is the
  whole point of committing to a hash instead of trusting a caller
- `parentTransceiver`, not `transceiver` — `TransmitterBase.transceiver` means the opposite
  direction
- `Commitment.hashCalls` folds the **chainKey** in as the first element, so a payload
  approved for one chain cannot be finalized here. Receivers sit at deterministic
  addresses across chains, which is exactly where a cross-chain replay would otherwise work.
  It is a chainKey rather than `block.chainid` because the destination is not always an EVM
  chain — a Sui or Solana receiver has no `uint256` chain id to fold, but every chain has an
  ERC-7930 identifier. The EVM case still derives it from `block.chainid` alone, so nothing
  on the destination has to be configured for this to work
- A call is `Call { address target; uint256 value; bytes data; }` — the ERC-7579 /
  ERC-7821 tuple, so payload builders that already speak modular-account formats work
  unchanged. Target and value are **inside** the committed element, so the approval covers
  who is called and how much they receive, not only what is sent. See
  [`docs/encoding.md`](docs/encoding.md) for the wire layout, the commitment preimage, and
  why neither is portable across VMs
- **`_execute` is concrete, not an empty virtual.** It checks the policy and calls with the
  committed value, so a protocol that does not override it still executes rather than
  verifying a payload perfectly and silently doing nothing with it
  - **One failure reverts everything.** The commitment approves the array as a unit, so a
    prefix would discharge an approval that was never satisfied. `CallFailed` carries the
    index and the original revert reason
  - Under four bytes there is no selector, so the policy sees `bytes4(0)`. `bytes4` of a
    short `bytes` right-pads with zeros, and reading one anyway would invent a selector the
    payload never named and could match a policy entry by accident
- **`isAllowed` defaults to `true`**, in the base rather than only on paper. A receiver is
  a full-power account answering to one owner, the same way a Safe on Ethereum is; anything
  that can deliver an authenticated message to it can make it do anything. Failing closed
  would not add security — it would only mean every payload reverted until a protocol
  overrode it, including the bootstrap payload that runs inside `initialize`.
  **This is an EVM property, not a protocol property** — a Move receiver is vocabulary-limited whether anyone wants it to be or not,
  because Move has no dynamic dispatch. See
  [`docs/encoding.md`](docs/encoding.md#commitments-off-the-evm), which also records where
  the account model and the isolation argument stop holding off the EVM. The policy is a self-imposed restriction, not a
  defence against an outside party — a compromised bridge could forge a commitment hash
  just as easily as a call array, so gating on `(target, selector)` was never what stood
  between a forged message and execution
  - **Merkle-verified calls remain the plan, as an opt-in.** Follow Veda's
    [`ManagerWithMerkleVerification`](https://github.com/Veda-Labs/boring-vault/blob/main/src/base/Roles/ManagerWithMerkleVerification.sol):
    a root of permitted leaves binding target, selector, and the argument constraints that
    matter, with each call supplying a proof. That moves the policy from "which functions"
    to "which exact operations", and makes the permitted set one 32-byte root the signers
    approve and rotate. Owners who want their receiver constrained set a root; owners who
    do not get a plain account
- **Reentrancy.** Execution now runs inside the provider's inbound callback, calling
  arbitrary targets, which is a surface a purely local execution path would not have. The inbound handler, `finalize`, and `execute` share one guard. It has
  to be the **storage-based** `ReentrancyGuardUpgradeable`: the transient version needs
  Cancun's `TSTORE` and the build is pinned to `paris` for CREATE2 parity. It is initialized
  in `initialize`, since a proxy runs no constructor of its own
- **Value comes from a pre-funded balance.** Payloads spend native from the receiver's own
  balance rather than value delivered with the message: the address is deterministic and
  fundable before the receiver exists, and it needs no provider-specific native-drop
  machinery. `receive()` exists to allow it. `execute` is payable for the local path;
  `finalize` is not, because it is permissionless
  - It composes with retry. A payload that fails for want of funds is not lost — top the
    address up and the provider's retry lands it

#### TransmitterBase

The source-side entry point, and **its own message-provider endpoint.** One transmitter
per protocol per user, routing to every destination.

```
send(uint256 chainId, Call[] calls)              onlyOwner payable   // path A
sendTo(bytes identifier, Call[] calls)           onlyOwner payable   // path A, EVM
sendTo(bytes identifier, bytes[] elements)       onlyOwner payable   // path A, portable
bootstrap(uint256 chainId, Call[] calls)         onlyOwner payable   // path B
bootstrapTo(bytes identifier, Call[] calls)      onlyOwner payable   // path B, EVM
bootstrapTo(bytes identifier, bytes[] elements)  onlyOwner payable   // path B, portable
execute(Call[] calls)                            onlyOwner payable   // local, no bridge

// each send/bootstrap has a twin taking `bytes providerData` for this one message

commitmentCall(receiver, commitment) pure        // deferring, as a call
cancellationCall(receiver, index, expected) pure
commitmentFor / commitmentForChain               // the hash a signer checks
```

**There is no `commit` entry point, because committing is not a message kind.** To approve
a payload now and run it later, `send` a payload whose one element is `commitmentCall`. It
arrives, executes, and stores the hash; anyone supplies the matching array to `finalize`
afterwards. Nothing on the wire distinguishes it from any other payload, which is why no
message-type tag exists anywhere in the protocol.

**The form follows the destination, and both directions are enforced at the source.**
`Call[]` is what an EVM receiver executes and nothing else decodes it; opaque elements are
what every other VM receives and an EVM receiver cannot decode them. So each envelope-taking
overload — `sendTo` and `bootstrapTo` alike — refuses the wrong pairing rather than letting
a payload cross a bridge, cost a fee, and arrive undeliverable.

**Provider options ride per send, opaquely.** `_sendMessage(chainKey, payload,
providerData)` carries a blob the adapter decodes into whatever its provider wants —
LayerZero executor options and a refund address, a Wormhole consistency level, a CCIP
`extraArgs`. No fixed argument list fits them all, and one would have to be widened again
for the next provider; it is the same reasoning that keeps `route` opaque in the registry.

It is **per send rather than configuration** because destination gas is a property of the
payload: a three-call array needs more than a bare `commit`, and a stored default would
strand the first message that needed more. Every entry point has a twin that takes it, and
the short form passes empty — which means "the adapter's default", not a silent fallback.

**The check has to live here.** This is the last point that holds the ERC-7930 envelope;
downstream everything speaks chainKeys, which are hashes and cannot be asked what chain type
they came from. `bootstrap(uint256, Call[])` needs no check — a `uint256` chain id is an
`eip155` reference by construction.

| | `send` | `bootstrap` | `execute` |
| --- | --- | --- | --- |
| Reaches | any destination with a receiver | a destination with none | **this chain only** |
| Goes via | the bridge, directly to the receiver | the bridge, via both transceivers | nothing — a direct call |
| Destination does | decodes and runs the array | creates the receiver, then runs it | runs the array, here |

- **The provider endpoint lives here, not on the transceiver.** A transmitter's peer is its
  own receiver on the destination, which is a genuine 1:1 pair — the shape every provider's
  peer table already has. The cost is that peers and any send-side security configuration
  are per-user rather than shared; the benefit is that no shared contract sits in the path
  of a normal message, and fees and refunds flow owner → transmitter → endpoint with no
  forwarding
- **How the transmitter learns its receiver's address.** On EVM it is CREATE2 from the
  destination transceiver, the receiver implementation, and a salt that is the transmitter
  — derivable before the receiver exists. Where it is not derivable, the spoke reports it
  home and the registry records it at a grade. Either way the owner sets one peer per
  destination, once
- **`execute` takes no destination, because it cannot have one.** It is a direct call to a
  local receiver, with no bridge in between. It is also the caller
  `ReceiverBase.isAuthorizedCommitter`'s `sourceTransmitter` arm was written for
- **Deferring is not a separate entry point.** To pin a hash rather than run an array, send
  a payload whose one element calls the receiver's `commit`. Derive the hash with
  `commitmentFor`, which is `pure` and runs off-chain against the exact array the signers
  reviewed. The trade is reviewability: they approve thirty-two bytes inside a call, and
  whether they can see what those bytes mean depends on their tooling

- **It inherits no ownership, for the same reason `TransceiverBase` does not.** An account
  is its own message-provider endpoint, so it composes with that provider's SDK — and
  those bring their own authority: LayerZero's `OAppCore` is `Ownable`, another might use
  `AccessControl`. Two ownership systems in one contract is not a style problem; it means a
  contract gated behind one authority can still be driven through the other.

  So the base states the requirement — `_owner()` and `_checkOwner()`, declared and not
  implemented — and the concrete contract satisfies both from whatever it already has.
  `LzTransmitter` answers with `OwnableUpgradeable` today and will answer with OApp's own
  `Ownable` when it becomes one, without `OApp` appearing anywhere in the base.

  The modifier is **`onlyAccountOwner`, not `onlyOwner`** — an SDK that brings `Ownable`
  brings an `onlyOwner` too, and two base classes declaring one modifier name forces every
  derived contract to override it. `TransceiverBase` sidesteps the same trap with
  `onlyAdmin`.

  The user-facing half — `transferOwnership`, and the `renounceOwnership` that would brick
  an account since every entry point is gated — therefore comes from the concrete contract
  - It also exposes `renounceOwnership`, which **bricks** the transmitter: every entry
    point is owner-gated. Recorded rather than prevented — disabling it is a separate
    decision
- The destination is a **parameter, not state** — a single transmitter fans out to every
  chain. That still yields one receiver per (transmitter, destination), because the salt
  on the far side is the transmitter and there is exactly one per user per protocol
- **The caller still names a plain chain id.** `send(8453, ...)` is the entire interface
  for an EVM destination: no chainKey to look up, no eid to know, no per-provider table to
  keep. A signer reviewing the payload sees the chain id they expect rather than a hash
  they would have to verify out of band
- `sendTo` is the escape hatch for destinations that have no `uint256` chain id at all —
  Solana, Sui, Starknet. It takes the ERC-7930 envelope rather than a bare key so the
  destination stays reproducible from the signed calldata, and accepts an account envelope
  (reduced to its chain identifier), so a caller holding only a remote address need not
  strip it by hand
- **It holds no registry pointer, deliberately.** The chainKey derivation is pure, so
  nothing here reads the directory; the hub transceiver does that lookup once, on Ethereum,
  and only on the bootstrap path. One contract on one chain owns the dependency
- **The commitment is hashed for the destination, not for here.** `Commitment.hashCalls`
  folds in the local chainKey, which on the transmitter is Ethereum, while the receiver
  recomputes the hash on the *destination*. `commitmentFor` therefore hashes with the
  destination's key. Getting this wrong produces a commitment nothing on the destination
  can ever match, and it fails only on a live message
- The chain-binding still does its job: the payload is pinned to one destination and
  cannot be replayed onto a sibling deployment at the same address
- `commitmentFor` is public so the value can be checked before signing, and so the
  receiver address it feeds into (`predictXSafeAccount`) can be pinned in the approved
  payload
- `_sendMessage(destinationChainKey, payload)` is the protocol's virtual hook. It carries
  `bytes` rather than a `bytes32`, which is what every provider's transport actually is —
  and what lets one primitive serve a payload, a bootstrap message, and a receiver report.
  It receives a chainKey, which is what `counterpartOn` and `receiverSlot` already speak,
  so nothing translates at that boundary

### Questions

Kept in [`docs/todo.md`](docs/todo.md), together with everything else outstanding, so there
is one list rather than three that drift.
