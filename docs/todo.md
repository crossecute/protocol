# Outstanding

Everything known to be missing, undecided, or wrong, in one place. Ordered by what blocks
what rather than by size.

[`message-flow.md`](message-flow.md) and [`encoding.md`](encoding.md) describe the design;
this file is the gap between that design and the tree.

---

## 1. No message provider is integrated

**This is the headline.** Both paths are built end to end in-process — `_sendMessage`,
`send` / `sendTo` / `bootstrap`, the inbound funnel, the reentrancy guard — and nothing
crosses a real bridge, because `_sendMessage` reverts `SendNotImplemented` until a protocol
binding overrides it.

Still missing on the transport itself:

| Missing | Where |
| --- | --- |
| The spoke → hub report | `reportSelf` does not exist; `Envelope.encodeReceiverReport` has no caller |
| Provider setup in `_accountInitializer` | The seam exists and is `virtual` throughout; no binding fills it yet |

## 2. The provider binding

`LzTransmitter`, `LzReceiver`, `LzHubTransceiver`, and `LzSpokeTransceiver` inherit no
LayerZero code — no `OApp`, no endpoint, no `@layerzerolabs` in `lib/` or in the remappings.
**Nothing has ever crossed a bridge.**

The claim the whole redesign rests on — that an account can be its own provider endpoint,
and that a *proxy* can hold one — is untested. This is the next thing to build: it is what
turns `_sendMessage` from a seam into a send, and it is what every remaining path is
waiting on.

### What was found in the package

Verified against `@layerzerolabs/oapp-evm-upgradeable@0.1.3` (it imports interfaces from
`@layerzerolabs/oapp-evm`, 0.4.1 at the time of checking). Vendor both under
`contracts/evm/lib/`, matching the existing convention.

```solidity
abstract contract OAppCoreUpgradeable is IOAppCore, OwnableUpgradeable {
    ILayerZeroEndpointV2 public immutable endpoint;
    constructor(address _endpoint) { endpoint = ILayerZeroEndpointV2(_endpoint); }
    function __OAppCore_init(address _delegate) internal onlyInitializing {
        if (_delegate == address(0)) revert InvalidDelegate();
        endpoint.setDelegate(_delegate);
    }
}

abstract contract OAppUpgradeable is OAppSenderUpgradeable, OAppReceiverUpgradeable {
    constructor(address _endpoint) OAppCoreUpgradeable(_endpoint) {}
    function __OApp_init(address _delegate) internal onlyInitializing {
        __OAppCore_init(_delegate);
        __OAppReceiver_init_unchained();
        __OAppSender_init_unchained();
    }
}
```

**One constructor argument, and it does not matter.** It is on the *implementation*, and an
implementation's address lives in the proxy's ERC-1967 storage slot rather than in its
initcode — so `CrossProxy` stays argument-free and no derived address moves. The endpoint
being an `immutable` is correct rather than merely tolerable: every account on a chain uses
the same endpoint, which is exactly what an implementation-level immutable expresses.

**It fits our layout without collisions.** `OAppCoreUpgradeable` keeps its peer mapping in
ERC-7201 namespaced storage (`OAPP_CORE_STORAGE_LOCATION`), as do `OAppOptionsType3`,
`PreCrime`, and the simulator. So it cannot collide with `sourceTransmitter`, `accountSalt`,
or the approval queue however our layout changes — which also removes the storage-gap
question for accounts specifically.

**`Ownable` is deliberately left uninitialized.** The package says so in a comment: *"Ownable
is not initialized here on purpose. It should be initialized in the child contract to
accommodate the different version of Ownable."* Since it derives OZ's `OwnableUpgradeable`,
the same one `LzTransmitter` uses today, `__Ownable_init(owner)` plus `__OApp_init(delegate)`
composes rather than collides — and `TransmitterBase`'s ownership seam means the base is
unaffected either way.

### Where each seam attaches

| Our hook | LayerZero |
| --- | --- |
| `_sendMessage(chainKey, payload, providerData)` | `_lzSend(eid, payload, options, MessagingFee, refund)` — decode `providerData` to `(bytes options, address refund)`; `eid` from `routeFor(chainKey)` |
| `_onMessage(bytes payload)` | called from `_lzReceive(...)`, the override point |
| `_accountInitializer(owner, salt, calls)` | must build `__OApp_init(delegate)` **and** the peer, since the account locks in the same call |
| `_checkAdmin` / `_checkOwner` | answered from OApp's own `Ownable` |

**The peer value is always the account's own address**, since a transmitter and its
receivers share one. One entry per destination, and the value never varies.

### Two consequences to decide on

- **`__OAppCore_init` calls `endpoint.setDelegate(_delegate)`.** That runs inside
  `upgradeInitializeAndLock`'s delegatecall, so `address(this)` is the proxy and the
  delegate is registered per account — correct, but it means **every account creation
  touches the endpoint**. Real gas on the bootstrap path, and the concrete form of the cost
  named as "peers and any send-side security configuration are per-user rather than shared".
- **OApp authenticates inbound before our code runs.** `lzReceive` does
  `if (address(endpoint) != msg.sender) revert OnlyEndpoint(...)` then
  `if (_getPeerOrRevert(_origin.srcEid) != _origin.sender) revert OnlyPeer(...)`. That is
  the open question in §4 below, now concrete: it contradicts the rule stated for the
  transceiver, and for a 1:1 pairing there is nothing extra to verify — so accepting it is
  defensible, but it should be a **written exception** rather than an omission.

## 3. Blockers on specific paths

- **Funding the return report.** `reportSelf` fires from inside the destination's inbound
  callback, and putting a message on the wire costs native currency there. Either the spoke
  carries a msig-funded balance per chain, or the bootstrap message drops value across.
  Without one, bootstrap reverts on the return leg. **Top blocker on the report path.**
- **Starknet bytes↔felt packing.** Bridges deliver Starknet payloads as `Array<felt252>`,
  not bytes. Before any container format can be parsed there has to be an agreed packing
  rule. Unspecified, needed in either container format, and the kind of value that is wrong
  once and wrong forever.
- **A Move receiver model.** Move has no general dynamic dispatch, so a receiver can verify
  a commitment perfectly and have no way to perform the approved calls. It also has no
  per-owner deployment, so the one-account-per-owner model and its single address do not
  survive. The largest unresolved piece of non-EVM support — see
  [`encoding.md`](encoding.md#commitments-off-the-evm).
- **A Cardano receiver model, or a decision that Cardano is out of scope.** eUTxO
  validators approve spending; they do not execute.
- **Poseidon for Starknet commitments.** `Scheme.Poseidon` is declared and reverts
  `SchemeNotComputable`. Porting it needs the exact round constants and MDS matrix over the
  Starknet field — a vector-checked task, not one to write from memory. Until then a
  Starknet commitment is computed off-chain and carried in an opaque element that calls
  that receiver's own `commit`.

  **No longer blocked on a redeploy.** `ICommitmentScheme` plus
  `ChainRegistry.setCommitmentScheme` make a primitive a per-chainKey plugin, so the port
  lands as a deployment and one owner transaction rather than as new account bytecode —
  which frozen accounts could never receive anyway. The enum stays exactly as it is: it is
  compiled into every live transmitter and cannot grow, and new primitives get a contract
  instead of a member. What is still outstanding is Poseidon itself.

## 4. Decisions taken that deserve a second look

None of these are bugs. Each is a deliberate choice with a cost worth confirming before
mainnet.

- **Write-once has no recovery path.** `setTransceiverId`, `setProviderDeployment`, and a
  reported ref slot all refuse a second write. A route declared wrong is permanent; a
  receiver slot written wrong has no fix at all. The alternative is a timelocked repoint
  rather than an outright refusal.
- **`Provenance.Committed` has no producer.** It survives only as a cap value. Chains
  configured at that cap now effectively mean "`Attested` or nothing".
- **Ordered execution blocks the queue.** Strict FIFO means a permanently-failing payload
  stalls everything behind it until `cancel`. Ordering and cancellation are load-bearing for
  each other; neither should be removed alone.
- **Two `isAuthorizedCommitter` arms are the same address.** A receiver's peer is its own
  address, so `sourceTransmitter` and `address(this)` coincide. Collapse them, or keep them
  distinct against a future where they diverge?
- **A blank `CrossProxy` delegates to `address(0)` and succeeds silently.** Only safe
  because deploy, arm, and lock are one function. It becomes a real hole if those are ever
  split.
- **Self-replaying payloads.** `finalize` clears an approval before executing, so a payload
  containing a self-call to `commit` with its own hash re-arms itself indefinitely.
  Owner-approved either way, so not an escalation — but "approvals are single-use" stops
  being true. Disallowing it costs plumbing; allowing it is strictly cheaper.
- **Who authenticates the receiver's inbound message.** A provider's own peer check runs
  before any of our code, which contradicts the rule stated for the transceiver. For a 1:1
  pairing there is nothing extra to verify, so accepting it is defensible — but it should be
  a written exception rather than an omission.

## 5. Smaller open questions

- **The opaque container off the EVM** — ABI framing or a length-prefixed one. Not blocking
  until a non-EVM receiver exists, because the commitment never sees the container.
- **The Solana account list belongs inside the committed element.** Argued in
  [`encoding.md`](encoding.md); worth marking settled when the first vector is written.
- **Empty-array commitments.** `execute` refuses one; `finalize` accepts. Pick one.
- **Registry `slot` namespacing.** Raw `transceiverId`, so two callers choosing the same
  bytes32 collide; only the monotonic provenance rule limits the damage.
- **Owner-writable non-EVM locations** — allowed directly, or only through the graded
  resolution paths?
- **What else a self-call may reach.** Today `commit` / `cancel` / `finalize` / `execute`.
  When a merkle-root setter lands, a self-call could rotate the policy — probably right,
  but it should be deliberate.
- **Whether bootstrap may carry a full payload**, or only enough to stand the account up.
- **Refund plumbing.** `bootstrap` should take a refund address and the transmitter should
  pass its owner.
- **No storage gaps anywhere.** The transceiver is UUPS until `lockUpgrades()`.
- **`renounceOwnership` bricks a transmitter.** Recorded rather than prevented; disabling it
  is a separate decision.
- **Tron CREATE2 against a Shasta deployment**, to resolve the 0x41-vs-0xff docs
  contradiction. A one-afternoon empirical check that de-risks a whole chain family.
- **The home chain is now a deployment parameter**, not Ethereum. `SpokeTransceiverBase`
  takes its home chainKey, the provider's route to it, and the hub's address as
  write-once initializer arguments. Two things follow that are worth deciding rather than
  inheriting: the hub must be an EVM chain with the EIP-152 precompile, since the registry
  recomputes addresses and commitments locally, and every spoke in one deployment must be
  given the SAME home — nothing on-chain cross-checks that, because a spoke has no view of
  its siblings. A deploy script is the natural place to enforce it, and there is no
  `script/` yet.
- **Merkle-verified calls** as an opt-in policy, replacing the `(target, selector)`
  predicate. `isAllowed` defaults open, so this is an owner's restriction rather than a
  safety baseline.

## 6. Infrastructure — none of it exists

- **`lib/` is vendored rather than submoduled** — forge-std 1.16.2, OZ 5.1.0,
  OZ-upgradeable 5.1.0. Committed deliberately: CREATE2 parity depends on byte-identical
  initcode, so the exact dependency bytes are load-bearing. Costs 37MB per clone.
- **No `script/`.** The Assumptions section specifies an elaborate deploy story — Arachnid's
  factory, proxy with deployer-as-owner, immediate upgrade, ProxyAdmin under the msig — with
  no code behind it. The CREATE2 parity argument stands or falls on that initcode being
  byte-identical, and nothing pins it.
- **No CI.** No `.github/`.
- **No `test/vectors/`.** [`encoding.md`](encoding.md) specifies the corpus and the
  "assert fields, not bytes" rule. Foundry can verify the commitment half for every VM with
  no non-EVM tooling — cheap, and the only defence on the execute-on-arrival path where
  there is no commitment at all. **Now load-bearing for the scheme plugins**: an
  `ICommitmentScheme` is only as good as the evidence that its primitive matches what the
  destination's own receiver applies, and a wrong one wedges that receiver's FIFO queue
  until a `cancel` crosses. The corpus is what turns "we believe this is Blake2b" into a
  check.
