# Call encoding

Status: design. Covers how a call array is serialized for the wire and what the
commitment is computed over, on EVM and elsewhere.

## Two things, kept separate

They get conflated, and keeping them apart is what lets each VM do the sensible thing:

**Wire encoding** — how the payload travels. The receiver decodes it.

**Commitment preimage** — what gets hashed. The receiver re-derives it from the decoded
fields and compares.

They are independent. The wire format can change without changing any commitment, and both
are owned by the receiver on the destination chain. Nothing above them — not the
transceiver, not the transmitter, not the bridge — inspects either one.

## The commitment is defined over opaque elements

This is the layer that stays VM-agnostic, and it is what the code already does:

```solidity
function hashCalls(bytes32 destinationChainKey, bytes[] calldata elements)
    internal pure returns (bytes32)
{
    bytes32 hashed = keccak256(abi.encode(destinationChainKey));
    for (uint256 i; i < elements.length; ++i) {
        hashed = keccak256(abi.encodePacked(hashed, keccak256(elements[i])));
    }
    return hashed;
}
```

An element is bytes. The hash never looks inside one. The destination chainKey is folded in
first, so a payload approved for one chain cannot be finalized on another — and, usefully
here, so the element format is namespaced per destination for free.

**The hub's contracts therefore never need to understand a non-EVM call.** `commitTo`
hashes opaque bytes; Solana and Move payload construction happens entirely in off-chain
tooling. There is no Borsh or BCS anywhere in Solidity, ever.

## EVM

### Wire format

```solidity
struct Call {
    address target;
    uint256 value;
    bytes data;
}

// payload = abi.encode(Call[] calls)
```

This is the ERC-7579 `Execution` tuple, also used by ERC-7821. The reason to prefer it over
`bytes[]` is not the bytes saved — it is that payload builders which already speak modular-
account formats work without custom code.

Layout for one call carrying 36 bytes of data:

```
32  offset to array
32  array length            1
32  offset to element 0
    ── element 0 ──
32  target
32  value
32  offset to data
32  data length             36
64  data                    padded to 2 words
─── 288
```

### Commitment preimage

Per element:

```solidity
function hashCall(Call calldata c) internal pure returns (bytes32) {
    return keccak256(abi.encode(c.target, c.value, c.data));
}
```

**Hash the fields, not the struct.** `abi.encode(someStruct)` prepends an offset word,
because a struct with a dynamic member encodes as a dynamic tuple. `keccak256(abi.encode(c))`
and `keccak256(abi.encode(c.target, c.value, c.data))` are different values. The second is
the one that matches the opaque form.

That equivalence is the point: `hashCall(c)` equals `keccak256(element)` whenever the
element is `abi.encode(target, value, data)`. So a typed overload and the canonical opaque
form produce identical commitments, and the transmitter can offer both — typed calls for
EVM destinations, where signers get a readable payload, and opaque bytes for everywhere
else.

```solidity
hashCalls(bytes32 chainKey, bytes[] elements)     // canonical, keccak256, pure
hashCalls(bytes32 chainKey, Call[] calls)         // same hash, typed
hashCalls(Scheme, bytes32 chainKey, bytes[])      // per-destination, view
hashCalls(Scheme, bytes32 chainKey, Call[])       // per-destination, view
```

One name, four shapes. Every array parameter is `memory`: Solidity will not overload on
data location, so a `calldata` twin would need a different name — which is the only reason
a second one ever existed.

The unparameterized pair is the **EVM scheme** — keccak256 — and is what a receiver on an
EVM chain calls. The `Scheme` overloads are for the source side, where the hub builds a
commitment a *different* VM will recompute. See below.

This is asserted directly, not assumed — `test/PayloadEncoding.t.sol` includes a fuzz case
over `(target, value, data, chainKey)`. If the two ever diverge, a payload approved in one
form silently stops matching in the other, and it fails only on a live message.

## The form follows the destination

There is no discriminant on the wire. An EVM destination always receives `Call[]`; every
other VM always receives opaque `bytes[]`.

```
EVM destination       wire = abi.encode(Call[] calls)
everything else       wire = abi.encode(bytes[] elements)
```

The sender picks by destination chain type — `send(uint256)` is `eip155` by construction,
and `sendTo(bytes)` reads it off the envelope it was handed. The receiver decodes the
single shape its own VM implies. Both sides know which before a byte is written, so a field
saying so would carry a value each already holds. That is the same reason `Envelope` has no
message-type tag, and it now holds here too: **every channel carries exactly one shape.**

**This is a structural guarantee, not a decoder guarantee**, and the distinction is worth
holding onto. `abi.decode` of the wrong shape does revert for these two layouts — asserted
in `test_theTwoEncodingsDoNotDecodeAsEachOther` — but that is a property of how they
collide, not a promise the ABI decoder makes. What actually prevents a misread is that no
path exists which sends opaque elements to an EVM receiver. If one is ever added — a
transmitter running on a spoke, a destination that accepts both — the tag has to come back,
because at that point direction stops determining shape. `Payload.sol` carries that
tripwire in a comment.

### The receiver's entry point is `Call[]` only

`ReceiverBase` exposes `finalize(Call[])` and `execute(Call[])`, and no opaque twin. An EVM
receiver executes EVM calls; there is no payload it can run that is not
`(target, value, data)`, so an opaque overload would accept elements it could only decode
into this shape anyway or revert on. One entry shape means one place the caller gate lives
and one place the policy check lives.

The **commitment** it discharges may still have been built in either form — that layer is
VM-agnostic and off-chain tooling naturally produces the canonical opaque elements. The
equivalence is what makes this work: an approval computed over `bytes[]` is satisfied by
the typed array supplied here.

The same applies on the source side. `TransmitterBase.execute` is `Call[]` only, because it
is a direct local call with no bridge in between and therefore always targets an EVM chain.
`commit` and `commitTo` keep both overloads, because they approve payloads for destinations
this chain cannot execute on.

### Note on the empty array

Zero calls hashes to `keccak256(abi.encode(chainKey))`, which is non-zero and therefore a
valid commitment. `execute` refuses an empty array; `finalize` does not. Worth deciding
whether an empty payload should be committable at all.

## Non-EVM

There is no portable `Call`. The blocker is not address width — it is that the call *shape*
differs structurally per VM:

| VM | Call shape | Native serialization |
| --- | --- | --- |
| EVM | `(target, value, data)` | ABI |
| Starknet | `(to, selector, calldata: felt252[])` | felt array |
| Solana | `(program_id, accounts: AccountMeta[], data)` | Borsh |
| Aptos | `(module, function, type_args[], args[])` | BCS |
| Sui | commands + inputs, referencing objects and prior results | BCS |

Starknet carries the selector as its own field rather than as the first four bytes of
calldata. Solana requires every account an instruction touches to be enumerated with
signer/writable flags — information that does not exist in an EVM call and cannot be
derived from one. Sui arguments can reference the output of an earlier command in the same
block.

A universal struct would compile everywhere and be a lie on four of those five, with a
`value` field that means nothing outside the EVM: every other VM moves native currency as
an explicit asset or resource.

**So each VM's receiver owns both its wire format and its commitment preimage**, in its own
native serialization. The container above them is uniform; the elements are not — and
neither, necessarily, is the hash. See `Scheme` below.

### Starknet: `starknet_keccak` is not `keccak256`

It masks the output to 250 bits so the result fits in a felt, and it is what Cairo uses for
entrypoint selectors. A Starknet receiver that computes the commitment with it will never
match the hub. Full keccak256 is available but is the less obvious import.

## Commitments off the EVM

Two questions that get answered together and should not be: **can the destination verify a
commitment**, and **can it execute what the commitment approved**. The first is portable.
The second is not, and on two of the target VMs the answer is no for reasons that cannot be
engineered around at the encoding layer.

### Verifying is portable, and that is by construction

The fold never parses an element, so a destination needs only keccak256 over byte strings
it never interprets:

```
seed = keccak256(chainKey)                     // abi.encode(bytes32) is just the 32 bytes
acc  = keccak256(acc ‖ keccak256(element_i))   // encodePacked of two bytes32 is 64 bytes
```

No ABI decoder, no Borsh, no BCS. Both steps are byte concatenation and a hash. This is the
property the whole VM-agnostic commitment layer buys, and it holds on every chain listed
here.

Two things it depends on that are easy to miss:

**keccak256 is not universal, so the scheme is a parameter.** Where it is a native
primitive, it stays the default; where it is not, the destination hashes with something
else and the source has to build the commitment the same way.

| ChainType | keccak256 there | Scheme |
| --- | --- | --- |
| `EIP155` | opcode | `Keccak256` |
| `SOLANA` | `sol_keccak256` syscall | `Keccak256` |
| `APTOS` | `aptos_hash::keccak256` | `Keccak256` |
| `SUI` | `sui::hash::keccak256` | `Keccak256` |
| `NEAR` | `env::keccak256` host fn | `Keccak256` |
| `COSMOS` | **no host function** — compiled into the wasm | `Keccak256`, priced by payload |
| `STARKNET` | library code, not a builtin; `starknet_keccak` is a *different* hash | `Poseidon` |
| `BIP122` | no opcode exists | n/a — no executor |

Out of scope but referenced elsewhere in the README: **Cardano** would use `Blake2b256`
(its `keccak_256` builtin arrived later than its other hashes, so the Plutus version needs
checking), and **TON** would use `Sha256` — TVM has SHA256 natively and no keccak
primitive. Neither has a `ChainType` allocated today.

**So Starknet is the only in-scope chain where keccak is the deciding obstacle.**
CosmWasm's is a cost difference rather than a capability one — the hash is wasm rather than
a host call, so it is priced by payload size instead of being nearly free.

### `Scheme` — the fold is fixed, the primitive varies

```solidity
enum Scheme { Keccak256, Sha256, Blake2b256Scheme, Poseidon }
```

This is a deliberate narrowing and it gives something up. A fully VM-native commitment
would be TON's **cell hash** — sha256 over a cell tree, because a TVM cell holds only 1023
bits and any real payload is therefore a tree — or Starknet's `poseidon_hash_span` over a
felt array. Neither is a byte-oriented fold, and neither could be reproduced on the hub to
show a signer what they are approving. Holding the fold fixed keeps both sides able to
compute one value; the cost is that a non-EVM receiver implements a byte fold rather than
its idiomatic digest.

**The hub can still compute most of them**, which matters more than it first appears
because `commitmentForChain` is read through `eth_call` when a signer checks a payload —
so gas is not charged in the path that matters.

| Scheme | On the hub | Mutability |
| --- | --- | --- |
| `Keccak256` | opcode | `pure` |
| `Sha256` | builtin (precompile 0x02) | `pure` |
| `Blake2b256Scheme` | `Blake2b256.sol`, EIP-152 precompile 0x09 | **`view`** |
| `Poseidon` | **not implemented** | reverts |

Blake2b is what forces every dispatching function to `view` rather than `pure`: Solidity
forbids `staticcall` inside `pure`. `IVmDeriver` already pays this exact tax for the same
precompile, for the same reason.

`Poseidon` is **declared and not implemented.** Poseidon over the Starknet field needs the
exact round constants and MDS matrix, and one wrong constant produces a silently wrong
digest — so it is not written from memory. It reverts with `SchemeNotComputable` rather
than falling back to keccak, because a silent fallback would hand back a well-formed
commitment that a Starknet receiver can never match, failing only on a live message. Until
it is ported and checked against `test/vectors/starknet.json`, a Starknet commitment is
computed off-chain and approved through the digest-only `commitTo(bytes,bytes32)`.

**Where the scheme is and is not a parameter.** `commit`/`commitmentFor` take a `uint256`
chain id, which is `eip155` by construction, so they stay keccak-only and `pure`. Only
`commitTo`/`commitmentForChain` — the ERC-7930 entry points, which exist precisely for
non-EVM destinations — take a `Scheme`. It is a parameter rather than a registry lookup
for two reasons: the transmitter holds no registry pointer by design, and a parameter puts
the scheme in the calldata the signers approve, which is right because the scheme is part
of what makes the digest mean anything on the far side.

Getting it wrong fails closed — the destination recomputes with its own scheme and simply
does not match, the same failure mode as building a commitment with the local chainKey
instead of the destination's.

**The chainKey is a compile-time constant almost everywhere.** On EVM, `ChainKey.local()`
derives it from `block.chainid` and nothing has to be configured — which is exactly why the
commitment binds to a chain for free there. Off the EVM that does not hold:

| VM | Can it derive its own chainKey? |
| --- | --- |
| EVM | yes, from `block.chainid` |
| Starknet | yes, from `get_tx_info().chain_id` |
| Aptos | partially — `chain_id::get()` is a `u8` |
| Solana | **no** — a program cannot tell which cluster it is on |
| Sui | **no** |

So on the chains where the receiver address is least predictable, the chainKey also has to
be baked in, the same way `SpokeTransceiverBase.HOME_CHAIN_KEY` is a literal rather than a
constructor argument. A mainnet/devnet mixup then produces a receiver that verifies nothing
successfully and fails only on a live message. The mitigation is the one already used on
the spoke: assert the constant against a derived value in that chain's own test suite.

### Executing is where the chains diverge

| VM | Verify | Execute an arbitrary approved array |
| --- | --- | --- |
| EVM | yes | **yes** — a full-power account |
| Solana | yes | **yes**, via CPI, with the account list committed |
| Starknet | yes, awkwardly | **yes** — multicall is already idiomatic |
| Aptos / Sui | yes | **no** — Move has no general dynamic dispatch |
| Cardano | version-dependent | **no** — validators are not executors |

**Solana: the account list has to be inside the committed element.** Every account an
instruction touches must be enumerated in the transaction with signer/writable flags, and a
program can only CPI into accounts already in scope. The executor therefore supplies that
list — which means the approval has to cover it. If the accounts sit outside the
commitment, a relayer can substitute a destination token account and redirect funds at a
perfectly matching hash. That is a privilege escalation, not a formatting detail, and it is
the direct analogue of why `target` and `value` live *inside* the committed element on the
EVM. The element is `(program_id, AccountMeta[], data)`, and the receiver checks the passed
accounts against the committed ones before invoking.

Two Solana limits also shape the flow rather than just the encoding: the 1232-byte
transaction limit means a large payload has to be buffered into an account before it can be
executed, and a batch of CPIs has to fit the compute budget. The commit/finalize split maps
onto the first unusually well — pin the hash, write the payload across several
transactions, then execute against it.

**Starknet: executable, and the obstacles are all encoding.** `Array<Call>` with
`(to, selector, calldata)` is how Starknet accounts already do multicall, so running an
approved batch is idiomatic. What stands in the way is keccak, `felt252` not holding a
32-byte word, and the unsettled bytes↔felt packing convention below.

**Move: a receiver can verify perfectly and still be unable to act.** Move has no general
dynamic dispatch — a module cannot call an arbitrary `address::module::function` chosen at
runtime. Entry functions are dispatched by the transaction, not by other modules. Sui's
programmable transaction blocks come closest, but a PTB is composed off-chain by the sender
and a module cannot introspect the PTB it is part of.

So on Aptos and Sui the receiver implements a **fixed vocabulary of operations it was
compiled to understand**, and the "call array" becomes a command array over that vocabulary.
(Aptos has been adding function values for narrow cases; check the current framework version
before assuming, but general dispatch is not among them.)

**Cardano is not a decoder problem.** eUTxO validators approve or reject spending; they do
not execute. "Run this call array" has no referent. That needs a different receiver model
entirely, and pretending otherwise by picking a container format for it would be solving the
wrong layer.

### What this changes elsewhere

Three claims in the README are EVM properties presented as protocol properties, and the
Move case is where each of them breaks.

**"A receiver is a full-power account answering to one owner, the same way a Safe on
Ethereum is."** That is the justification for `isAllowed` defaulting to `true` and for
treating the call policy as a self-imposed restriction rather than a defence. On a Move
chain the receiver is vocabulary-limited whether anyone wants it to be or not, so the
premise is false there — and the merkle-policy work is moot, because **the vocabulary is
the policy**. Non-EVM receivers are constrained accounts by construction.

**"Deployed as a proxy at a CREATE2 address derived from the owner alone."** Move modules
are published at addresses, not instantiated; there is no per-owner deployment at all. A
Move deployment is one module holding a table keyed by owner. The one-account-per-owner
model, and the single address that goes with it, does not survive the trip.

**"Nothing to wedge — a payload that can never execute fails at its own transmitter's
receiver and blocks nobody. Isolation is structural rather than bookkeeping."** That rests
on one contract per owner. Under a shared Move module it becomes bookkeeping again,
which is the thing that section says it was avoiding. Whatever a Move receiver does about
isolation has to be argued separately rather than inherited.

Finally, `Call.value` is the concrete case of the general rule already stated above: every
other VM moves native currency as an explicit asset or resource, so value is an **operation
in the array**, not a field on an element. Solana moves SOL through a system-program
instruction; Move passes coins as resources. This is why the per-VM element format is not
optional.

### Open

- **A receiver model for Move**, given the vocabulary constraint and the absence of clones.
  This is a design question, not an encoding one, and it is the largest unresolved piece of
  non-EVM support.
- **A receiver model for Cardano**, or a decision that Cardano is out of scope.
- **Whether the Solana element carries the account list**, which the argument above says it
  must — worth stating as settled once someone writes the first vector.

## Testing

The home side and each destination are written in different languages with
non-overlapping toolchains, so they cannot import each other. The interface between them is
a file.

### The vector corpus

```
test/vectors/
  evm.json
  starknet.json      ← when there is a Starknet receiver
  solana.json
```

Each vector holds the logical calls, the destination chainKey, the encoded payload, and the
expected commitment hash. Every implementation reads the same file and neither depends on
the other.

**The VM that executes owns its format and generates its own vectors.** The decoder is the
spec, not the encoder — off-chain tooling that builds payloads is checked against the
destination's vectors, not the other way round.

### Who checks what

| | Checked by | Needs |
| --- | --- | --- |
| Commitment hash, any VM | Foundry | keccak over bytes it never parses |
| EVM wire format and decode | Foundry | — |
| Non-EVM decode, field by field | that VM's own suite | that toolchain |
| Encoder/decoder round-trip | Foundry `--ffi` | target toolchain installed |
| End to end | devnet lane per VM | deployed contracts |

The first row is the useful one: **Foundry can verify the commitment half for every
destination without any non-EVM tooling**, because hashing does not require parsing. The
EVM side holds the line on the commitment while understanding nothing about a Solana
instruction.

### Assert fields, not bytes

Matching hashes prove byte agreement, not semantic agreement. A mismatched *encoder* is
fail-closed — the commitment does not match and nothing runs. A mismatched *decoder* is
not: if the hub's tooling encodes "transfer 100 to A" and the destination reads "transfer
1000 to B" out of those same bytes, the hash matches perfectly and the wrong thing executes.

So vectors must assert the decoded fields individually, not that a blob round-trips. This
matters more on the execute-on-arrival path, where there is no commitment at all and the
decoder is the only thing between a delivered message and execution.

## Open: the opaque container is still ABI-framed

`Payload.encodeElements(bytes[])` wraps the portable form in `abi.encode`, which is an
EVM-ism imposed on exactly the chains least able to pay for it. That contradicts the
principle stated at the top of this file — the container is supposed to be uniform, not
EVM-shaped — and it should be decided before the first non-EVM receiver is written.

Nothing decodes ABI for free off the EVM. Per VM, roughly in order of pain:

| VM | Feasibility | The actual obstacle |
| --- | --- | --- |
| Move (Aptos/Sui) | easy | native `u256`, good `vector<u8>`; only the big-endian swap |
| Solana | workable | compute budget and 32KB heap; must reject non-zero high words in lengths |
| Starknet | hard | `felt252` is ~2^251, so **a 32-byte ABI word does not fit in one** |
| Cardano | wrong model | eUTxO validators are not executors; needs a different receiver design |

This table is about *decoding the container*, and it does not line up with the execution
table above — Move decodes ABI easily and still cannot execute an arbitrary array. The two
are independent problems and picking a container format solves neither of the hard ones.

A length-prefixed container decodes with a cursor in any language, has no 32-byte-word
problem, and is far smaller:

```
count(u32 BE) | [ len(u32 BE) | element bytes ]*
```

One element carrying 36 bytes: **44 bytes packed against 192 ABI-framed.** Most of ABI's
overhead is zero-padding — cheap in EVM calldata gas, but several providers price by raw
byte.

**This costs nothing to defer, and that is why it is deferred rather than guessed at.** The
commitment folds `keccak256(element)` one at a time and never sees the array framing, so
the container can differ per destination without changing a preimage, invalidating a
commitment, or touching anything on the approval path. ABI framing stays for now because
EVM→EVM is the only path that exists and it is the natively cheap choice there.

**Blocking for Starknet specifically:** the bytes↔felt packing convention. Bridges deliver
Starknet payloads as `Array<felt252>`, not bytes, so before any container format can be
parsed there has to be an agreed rule for packing a byte string into felts. That is
unspecified today, is needed in either container format, and is the kind of value that is
wrong once and wrong forever.

Also unverified: **keccak256 availability on Cardano.** Solana, Aptos, and Sui all expose
it natively; Plutus gained a `keccak_256` builtin later than the others and the target
version needs checking. Starknet's `starknet_keccak` is *not* keccak256 — see above.

## Rejected

**`bytes[]` as the EVM wire format.** It costs an extra length word per call, requires N+1
decode passes against one for `Call[]` (the outer array, then each element again, copying
every `data` field twice), carries no standard tooling, and shows a signer opaque blobs
where `Call[]` decodes to named fields in a signing UI. It remains the canonical
*commitment* form, since that layer must stay VM-agnostic, and the only form a non-EVM
destination receives.

**A form tag on the wire.** It would let an EVM caller send either form, but the form is a
property of the destination and both sides know it in advance, so the byte would carry a
value neither side needs told. See above for the condition that would make one necessary.

**Packed, Safe `MultiSend` style** — `to(20) | value(32) | len(2) | data`. Smallest by a
wide margin, and reads straight from calldata with no memory copy. Rejected for now: it
needs hand-written cursor parsing, has no standard tooling, and bakes in a 20-byte address.
Revisit if bridge fees show up in cost modelling.

Wire bytes for comparison:

| Payload | `bytes[]` | `Call[]` | packed |
| --- | --- | --- | --- |
| commit (36B data) | 320 | 288 | 90 |
| ERC-20 transfer (68B data) | 352 | 320 | 122 |
| transfer + approve | 640 | 576 | 244 |
