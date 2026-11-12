# Safe authority updates — spec walkthrough

Sequential decision list for [#109](https://github.com/crossecute/protocol/issues/109),
to work through before any #109 code. Companion to the planning tracker
[`safe-authority-updates.md`](../safe-authority-updates.md), whose IDs (D, C, Q, E, R)
are cited in the Ref column so answers can be copied back. W-IDs are new to this
walkthrough. Started 2026-11-12; also kept as a Claude Doc for review together.

## How to use this walkthrough

We go through 15 stages in order, answering each row before moving on, and write no
#109 code until every row has an answer or an explicit deferral with a reason. The
order follows dependencies: what the owners sign (stages 2 and 3) fixes what the source
guard checks (4 to 7), which fixes what receivers verify (8 to 12).

"Proposed" is a recommendation, not a decision. Rows marked "(new)" are gaps the
tracker does not list yet. Record each answer in the Answer column and the decision log,
then beside its Q or C ID in the tracker.

1. Scope and migration
2. Authority model and node commitment
3. Signed objects, domains and witnesses
4. Source registration
5. Source mutation and post-hook
6. Pending lock and nested liveness
7. Source configuration and bypass matrix
8. Graph evolution on receivers
9. Receiver update algorithm and batching
10. Dispatch and commitment binding to counters
11. Bootstrap and late receivers
12. Transmitter counter sync
13. Publication, transport and fees
14. Stale authority, freeze and equivocation
15. Contract surface: storage, upgradeability, size, events, errors, cost

Then the edge-case map and the test plan, which every stage feeds.

## Settled baseline (do not reopen)

#109 asks for a general authority-update protocol: owner add, remove and swap,
threshold changes and nested-Safe changes, authorized by the pre-change quorum and
verified independently by every receiver, with no bridge trust and no light clients.
These 22 points are already agreed in the tracker and frame every stage below.

| ID | Settled point |
| --- | --- |
| D1 | Receivers verify exact signed content against previously trusted authority. Bridge claims, guard events, source post-state or new-owner signatures never authorize alone. |
| D2 | EOA and nested-Safe owners both in the first release. Per-node thresholds kept; no flattening. |
| D3 | Update first: current owners sign `n -> n+1`, exact mutation and resulting authority; the guard records it as pending; a separate signed self-call performs the mutation. |
| D4 | A receiver may apply the update before the source mutation runs. |
| D5 | One successor per counter: no duplicates, replacement or override. Cross-chain conflicting successors stay possible. |
| D6 | Per-Safe counters: guard per Safe, transmitter per parent, receiver per node. Child changes never advance ancestors. Genesis is zero. |
| D7 | Ordinary nested signatures verify against the receiver's current child composition. Unused children cannot block quorum. |
| D8, D16 | One signed update is reusable by anyone at every receiver that already trusts that Safe, as root or child. |
| D9 | Catch-up verifies every step; batches allowed, skips are not. |
| D10 | Safe 1.5.0 owner rules: add prepends, swap in place, remove keeps order, `prevOwner` checked. No owner mutation inside a signed MultiSend. |
| D11 | Conduit address commits to the initial authority and stays stable through rotations. |
| D12 | Production needs both guard slots on parent and participating nested Safes. Module self-calls and delegatecalls blocked. |
| D13 | Signed dispatch carries the parent counter; execution needs exact equality. |
| D14 | Management proofs and execution proofs never substitute for each other. |
| D15 | After registration, the guard blocks every transaction on that Safe except the registered mutation, on owner and module paths. |
| D17 | Updates use the normal pre-change threshold; no stricter rotation quorum. |
| D18 | Post-hook reads actual owners and threshold, hashes them and must match the registered next commitment before advancing. |
| D19 | The mutation must use the immediately next Safe nonce. |
| D20 | No cancellation once quorum is reached. |
| D21 | If another transaction takes the registration nonce, receivers may stay ahead of source; no rollback. |
| D22 | A commitment stores the hash of the receiver's whole active authority graph (every node's identity, ordered owners, threshold and counter) at acceptance. Execution after any change to that hash is rejected, including a change to an unused child. |

Starting code (#108, commit `5d7be13`): `SafeAuthorityRecord { safe, threshold,
SafeOwner[] owners }` with owner kinds EOA and SAFE only; `SafeAuthorityState` keyed by
source address with one `sourceChainId`; `graphHash = keccak256(abi.encode(records))`.
`ExecutionLeaf` and `BootstrapLeaf` have no counter field yet. `SafeAuthorityGraph`
rejects cycles and bad thresholds but has no depth or node-count constant. `Proxy`
locks a conduit's implementation once armed.

## Stage 1: Scope and migration

These answers bound everything else, so they come first.

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W1.1 | Which authority sources ship in the first release? | Safe only; Safe plus a DAO/home-contract adapter | Safe only. Explicitly reject other home-contract paths until a portable signed adapter has its own threat model. | Q4.4 | |
| W1.2 | Which Safe versions are supported? | 1.5.0 only; 1.4.1 and 1.5.0 | 1.5.0 only, since D10 and D12 rely on 1.5.0 owner rules and the module guard slot. | D10, D12 | |
| W1.3 | Do existing #108 conduits gain update support? | Upgrade in place; new implementation only; never | New implementation only. `Proxy` locks a conduit's implementation once armed, so #108 receivers cannot gain update logic in place and keep fixed authority. Decide whether #108 and #109 conduits may coexist for one Safe. (new) | Q4.1 | |
| W1.4 | Must every Safe in a graph live on the same source chain? | Yes; allow cross-chain nested owners | Yes. `SafeAuthorityState` already holds one `sourceChainId`. (new) | | |
| W1.5 | Owner kinds | EOA and Safe; also generic ERC-1271 contracts | EOA and Safe only, matching `OWNER_EOA`/`OWNER_SAFE`. A non-Safe contract owner makes the graph unsupported. (new) | Q4.3 | |
| W1.6 | Out of scope confirmations | | zkSync, Tron and signed OFT stay out, as the tracker says. #107's selector-only `sendMessage` staging is unchanged. | Tracker end | |

## Stage 2: Authority model and node commitment

This fixes the value that owners sign as "resulting authority" and that the post-hook
(D18) and receivers recompute. Every later hash depends on it.

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W2.1 | Contents of an immediate node commitment | Version, source chain, Safe address, ordered owners with kinds, threshold; plus counter or not | Commit to version, chain id, Safe, ordered `SafeOwner[]`, threshold. A child is referenced by address and kind only, never by its composition. | Q2.1 | |
| W2.2 | Is the counter inside the node commitment? | Inside; bound separately in the transition leaf | Separate. The transition leaf binds `prevCommitment, n, n+1, nextCommitment`, so the same composition reached twice still has distinct transitions. | Q2.1 | |
| W2.3 | Relation to the genesis `graphHash` and the D22 graph hash | Keep `graphHash` as identity only; replace it | Three distinct hashes: immutable genesis `graphHash` for identity (D11), mutable per-node commitments for transitions, and the D22 whole-graph hash (W10.8) for commitment validity. | C6, Q2.5, D22 | |
| W2.4 | Encoding of the commitment | `abi.encode`; packed; EIP-712 struct hash | `keccak256(abi.encode(tag, ...))` with a versioned tag, to match #108 hashing. EIP-712 is only needed if wallets must render it. (new) | Q1.3 | |
| W2.5 | Can the post-hook compute it cheaply on source? | Read `getOwners()` and `getThreshold()` and hash | Yes for the changing Safe only. It never reads children, because a child reference has no composition (W2.1). | D18 | |
| W2.6 | Counter width and overflow | `uint64`; `uint256` with checked math | `uint256` with checked increment; overflow is unreachable but must revert, never wrap. | Q3.1, E19 | |

## Stage 3: Signed objects, domains and witnesses

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W3.1 | Leaf types | Execution, bootstrap, node update; plus freeze if W14.2 says yes | Distinct versioned type tags per leaf. A proof is only checked after its expected tag is checked (D14). | Q1.3 | |
| W3.2 | Mixed or separate Merkle roots for execution and update leaves | One root holds both; separate roots | Separate roots. A root signed for updates cannot carry an execution leaf, which removes cross-type confusion at the root level too. | Q1.3, D14 | |
| W3.3 | Update leaf domain | Destination-bound; source-Safe and protocol-bound (reusable) | Source chain, changing Safe and a protocol update tag, with no destination or conduit (D16). | C1 | |
| W3.4 | Exact update leaf fields | | Tag, version, source chain id, Safe, `prevCommitment`, `n`, `n+1`, mutation calldata, Safe nonce of the mutation (D19), `nextCommitment`, plus introduced child records if W8.1 needs them. | Q1.1, Q3.2 | |
| W3.5 | Does the receiver need the Safe nonce? | Ignore it; check it | Carry it in the leaf because the source binds it, but receivers do not check it against anything. (new) | D19, D21 | |
| W3.6 | Which signature types are portable | All Safe types; exclude `v = 1` approved hashes | Keep #108 rules: reject `v = 1`, accept contract signatures only from stored nested Safes with full offsets. | Q1.5, E18 | |
| W3.7 | What digest each nested approval covers | Child-domain Safe message hash of the parent tx hash | Same as #108 `NestedSafeApproval`; write it down per leaf type in shared vectors. | Q1.5 | |
| W3.8 | Merkle tree shape | Sorted pairs; ordered with index; OpenZeppelin `MerkleProof` | Reuse whatever #108 `DispatchLeaves` uses, so one proof verifier serves both roots. (new) | | |

## Stage 4: Source registration

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W4.1 | Where the pending update lives | Shared guard per Safe; per transmitter | Shared guard, one pending transition per Safe. | Q1.1 | |
| W4.2 | Registration call shape | Guard function called by the Safe; staged selector like `sendMessage` | A dedicated Safe-signed call to the guard. Its selector and arguments are still to be fixed. | Q1.1, C5 | |
| W4.3 | Registration inputs | Opaque root only; root plus leaf plus proof | Root, update leaf and proof. The guard verifies membership, checks live prior state and counter, simulates the mutation with Safe rules and compares `nextCommitment`. | Q3.2, E24 | |
| W4.4 | Signature capture | Pre-hook stores the signed tx like #107; reread later | Capture the signed registration tx and full nested signatures in the pre-hook as the portable witness. | #109 text | |
| W4.5 | A second registration while one is pending | Reject; replace | Reject (D5, D15). | E25 | |
| W4.6 | Registration for a child-only change | Same entry point; separate | Same entry point, called by the child Safe through its own guard. Parents are never touched (D6). | D8 | |
| W4.7 | Event on registration | None; event with root, leaf hash and counters | Emit an event with Safe, `n`, root and leaf hash for discovery. A public view returns the pending transition. | Q1.1, Q6.1 | |
| W4.8 | Registration that is itself a module call | Allow; reject | Reject. Registration needs owner signatures to be a portable witness. (new) | D12 | |

## Stage 5: Source mutation and post-hook

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W5.1 | How the mutation is matched | Byte-exact calldata; decoded ABI equality | Byte-exact `to == safe`, `value == 0`, `operation == CALL`, data equal to the registered bytes. Simplest to audit. | Q3.2 | |
| W5.2 | No-op mutations (swap to the same owner, threshold to the same value) | Allow; reject | Reject at registration: `nextCommitment == prevCommitment` would burn a counter for nothing. Safe already rejects some of these itself. (new) | Q3.1, E19 | |
| W5.3 | Several mutations in one registration | One per registration; many | One. Each further change needs its own registration (D19). | E25 | |
| W5.4 | Retry after a failed mutation | Same signed mutation; any matching mutation | The pending record keeps the bytes; a new Safe tx with the same bytes at the reserved nonce may retry. Define whether a replacement nonce is allowed or needs fresh signatures. | Q3.7, D21 | |
| W5.5 | Source retry after a nonce race before recording | New registration at a fresh nonce | Fresh signatures over the same prior state, mutation and next commitment. Spell out the exact equality fields. | D21, C7 | |
| W5.6 | Transient correlation between pre- and post-hook | Reuse #107 transient slots; new slots | Reuse the per-Safe transient layout and add a marker for "this tx is the registered mutation". Transient storage persists across Safe txs in one outer tx (D19 allows several), so the guard must clear its own slots. | Q3.4 | |
| W5.7 | Reentrancy during the mutation | Owner change can't call out; still guard | Safe owner functions make no external calls, but the guard should not unlock until its own post-hook finishes. | E22 | |

## Stage 6: Pending lock and nested liveness

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W6.1 | Does a locked child block its parents? | Block parents; parents free | Parents stay free. The lock is on the child's own txs; a parent using other owners must still reach quorum (D7). | Q3.6 | |
| W6.2 | Locked child needs to approve a parent's mutation via `signMessage` | Allow `signMessage` while locked; forbid | Forbid, and require all approvals to be gathered before registering. Document the readiness check. | Q3.6, E22 | |
| W6.3 | What readiness can be enforced at registration | None; simulate the mutation; check guards installed | Simulate the mutation in memory and check config (W7). Signer cooperation cannot be enforced. | C4 | |
| W6.4 | Permanent lock if the mutation never runs | Accept; add an escape | Accept, since D20 forbids cancellation. Record it as a known liveness risk. | C4, E8 | |
| W6.5 | Parent update authorized using child B, then B rotates before delivery | Verify against B at signing time; at delivery time | Delivery time (D7 current composition). If B's new quorum no longer satisfies it, the parent update fails and must be re-signed. | Q3.5, E11 | |

## Stage 7: Source configuration and bypass matrix

Each row of W7.2 gets an allow, reject or treat-as-update answer.

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W7.1 | Activation checks before a Safe can register | | Both guard slots set to the crossecute guard, version 1.5.0, fallback handler on an allowlist, no modules outside policy. | Q4.1 | |
| W7.2 | Bypass matrix | `addOwnerWithThreshold`, `removeOwner`, `swapOwner`, `changeThreshold` without registration; owner delegatecall; module call; MultiSend; `setGuard`; `setModuleGuard`; `enableModule`; `setFallbackHandler`; policy change | Owner methods without registration: reject. Delegatecall and module self-call: reject. Guard, module guard, fallback handler and module changes: reject, or treat as an authority change. Policy changes: protected. | Q4.2, E15 | |
| W7.3 | Fallback handler changes | Reject; treat as an authority update | Reject while enrolled, since the handler sets nested `isValidSignature` behavior that receivers emulate. | Q4.3 | |
| W7.4 | Enrolling an existing Safe atomically | One MultiSend setup; separate txs | Define an atomic setup path so there is no window where one guard slot is empty. | Q4.1, C5 | |
| W7.5 | Leaving the protocol | Allowed by owners; never | Allowed only through a signed path that also stops receivers trusting the Safe, or not at all. Needs a decision. (new) | | |

## Stage 8: Graph evolution on receivers

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W8.1 | Adding a nested Safe owner | Old quorum signs the child's full record; child record arrives by its own genesis proof | The parent update leaf includes the introduced child's record. The parent's old quorum vouches for it at counter 0. | Q2.2 | |
| W8.2 | Child already stored at counter k in the same receiver | Reuse the stored record; overwrite | Reuse it, never reset to 0. The leaf's child record must then match the stored commitment, or the update is rejected. | Q2.2, Q2.3 | |
| W8.3 | Child removed from every parent in a receiver | Delete; keep as an orphan | Keep it, so its counter cannot restart if it is added again (D22 relies on counters never resetting). It gets no authority while unreachable. | Q2.3, E10, E28 | |
| W8.4 | Do orphaned nodes accept updates? | Yes; no | Yes, so they stay current if reattached. Confirm this does not create an unbounded storage path, and decide whether orphans are in the D22 hash (W10.8). | Q2.4 | |
| W8.5 | Graph validation after every transition | | Same `requireCanonical` rules: valid thresholds, no duplicate owners, known kinds, no dangling references, no cycles. | Q2.4 | |
| W8.6 | Depth and node limits | None (today); fixed constants | Fixed constants for depth, nodes and owners per node, sized from gas measurements. Today there are none. | Q2.4, E19 | |
| W8.7 | Owner kind change (Safe owner swapped for an EOA or the reverse) | Allow; reject | Allow; it is a normal swap. A removed child follows W8.3. (new) | | |

## Stage 9: Receiver update algorithm and batching

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W9.1 | Verification order | | Tag and version; locate stored node; check source chain and Safe; check `prevCommitment` and `n` equal stored; verify pre-change quorum and proof; apply the Safe mutation; validate the graph; check `nextCommitment`; write node and counter. Any failure reverts. | Q5.1 | |
| W9.2 | Who may submit | Anyone; relayer allowlist | Anyone (D8). | D8 | |
| W9.3 | Entry point shape | Single update; array | An array of consecutive updates, applied atomically. Callers split batches when gas runs short. | Q5.2 | |
| W9.4 | Batch bounds | | Max updates per call set from gas measurements. | Q5.2 | |
| W9.5 | Updates arriving through providers | Direct call only; also via a transceiver message | Both. A provider message ends in the same entry point and gains no extra trust. | D1 | |
| W9.6 | Can execution reach the update entry point? | Allow; block | Block calls from the receiver itself, including through `commit`/`finalize`. | D14, E20 | |
| W9.7 | Event on update | | Emit Safe, new counter and new commitment. | (new) | |

## Stage 10: Dispatch and commitment binding to counters

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W10.1 | Where the counter goes in an execution leaf | New field in `ExecutionLeaf`; in the registered root call | A new signed field in `ExecutionLeaf` and in the standalone payload. An envelope field the owners did not sign binds nothing. | Q5.3, C3 | |
| W10.2 | Standalone `sendMessage` messages | Add counter to calldata; read it from the guard at send time | Owners must sign it, so it goes into the signed calldata. This changes #107's ABI; confirm. | C3 | |
| W10.3 | Dispatch signed at n+1 arrives before the update | Reject; queue | Reject. The relayer delivers the update first. (new) | | |
| W10.4 | Execution nonce and replay state across rotation | Keep; reset | Keep unchanged. Already executed digests stay executed. | Q5.4 | |
| W10.5 | Order of checks for an exact duplicate after rotation | Replay check first; counter check first | Replay check first, so a duplicate reports "already executed", not a counter mismatch. Neither path writes state. | Q5.4, E13 | |
| W10.6 | Same commitment hash reauthorized under the new quorum | Allow with a fresh signature; forbid | Allow only by a fresh current-quorum authorization, never overwriting a stale entry silently, never reopening executed work. | D22, Q5.5 | |
| W10.7 | Child-only rotation and pending commitments | No effect; invalidate | Settled by revised D22: any active node change, including an unused child, changes the graph hash and invalidates the commitment. | D22, Q5.5, E27 | Decided (D22) |
| W10.8 | Canonical encoding and upkeep of the D22 graph hash | Recompute by walking the graph at each execution; recompute at each update and store it | Recompute after each applied update (and at bootstrap) and store `currentAuthorityHash`, so execution is one comparison. Fix the canonical node order (reuse `SafeAuthorityGraph.walk`) and whether orphans count (W8.4). | D22, Q5.5 | |

## Stage 11: Bootstrap and late receivers

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W11.1 | Receiver created after rotations | Bootstrap at genesis, then catch up; bootstrap at current | Verify immutable genesis first, then every update in order, then the bootstrap setup under the authority now current. | Q5.6, C2 | |
| W11.2 | Which authority signs the bootstrap leaf | Genesis owners only; current owners | Needs a decision. Current owners after verified catch-up, with the counter in the signed leaf (W10.1). | C2 | |
| W11.3 | Atomicity | Creation, catch-up and bootstrap in one tx; split | One tx, so a half-created receiver never exists. Check gas against W8.6 and W9.4. | Q5.6 | |
| W11.4 | Salt formula | Keep #108's; change | Keep `keccak256(abi.encode(owner, userSalt, homeChainKey, graphHash))`. Update the issue's "open salt" wording. | Q2.5 | |

## Stage 12: Transmitter counter sync

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W12.1 | How transmitters learn the counter | Push to every transmitter; read the guard on each send | Read the guard's `authorityCounter[safe]` at send time. No push, so no transmitter can be forgotten. | Q3.3, E12 | |
| W12.2 | Does a transmitter need its own copy at all? | Store; read only | Read only, if W12.1 is accepted. This simplifies D6's "transmitter stores its parent counter". | D6 | |
| W12.3 | Transmitter created after rotation | | Nothing special under W12.1; it reads the live counter. | E12 | |

## Stage 13: Publication, transport and fees

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W13.1 | What the guard does at registration | Emit only; also call a transport | Emit only. Direct permissionless submission must work without any provider. | Q6.1, Q6.2 | |
| W13.2 | Witness recovery | Event logs; calldata; guard storage | Rebuild from the registration tx calldata and nested approvals; the event points to it. Logs can be pruned by nodes, storage cannot. Decide whether the guard stores anything beyond the pending record. | Q6.1 | |
| W13.3 | Optional relay helper | None; transmitter function that sends one update to chosen receivers | A transmitter call that sends a stored update to receivers the caller names, paid by the caller. No automatic fan-out, since a shared child cannot list future receivers. | Q6.2, E17 | |
| W13.4 | Who pays | Caller; Safe | Caller of the relay or the direct submitter. | Q6.2 | |
| W13.5 | Provider message cost | | State the update payload size. LayerZero and CCIP price per byte, so nested witnesses cost more there. | Repo CLAUDE.md | |

## Stage 14: Stale authority, freeze and equivocation

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W14.1 | How long a lagging receiver accepts old keys | Unbounded until the update lands; bounded by signed windows | Each dispatch has its own `deadline`, but a receiver's authority has no age limit. Decide whether to accept that and state it, or add a maximum. | Q6.3 | |
| W14.2 | Freeze below ordinary quorum | None; freeze leaf at a lower threshold set at genesis | Needs a decision. If yes: its own leaf type, scope (one receiver or all), replay domain, who unfreezes, and a time limit so a minority has no unbounded veto. | Q6.4 | |
| W14.3 | Freeze and a pending update | Freeze blocks updates; blocks only execution | Needs a decision. Blocking updates could trap a receiver on compromised keys. | Q6.4 | |
| W14.4 | Equivocation evidence | None; anyone submits two signed successors for the same `n` | Needs a decision. Effect could be freeze-like. Any effect must keep D5 (no replacement). | Q6.5, E7 | |
| W14.5 | Prior work comparison | | Compare against [protocol-v2 PR #2](https://github.com/crossecute/protocol-v2/pull/2) (nonexpiring rotations) and [issue #1](https://github.com/crossecute/protocol-v2/issues/1) (relay and freeze) before deciding W14.1 to W14.4. | #109 text | |

## Stage 15: Contract surface

| ID | Decision | Options | Proposed | Ref | Answer |
| --- | --- | --- | --- | --- | --- |
| W15.1 | Receiver storage additions | | Per-node counter and commitment next to `SafeOwnerState`; stored current graph hash (W10.8); commitment hash to graph hash map (D22). Write the layout before code. | R2, R6 | |
| W15.2 | Upgradeability | None; guard upgradeable | Conduits stay non-upgradeable (`Proxy`). Decide whether the shared guard is a fixed deployment and how a new guard version is adopted (ties to W7.2 guard changes). | (new) | |
| W15.3 | Admin roles | | No role can change receiver authority except a verified update. Confirm no existing role on `SignedReceiver` can. | D1 | |
| W15.4 | Contract size | | Run `forge build --sizes src`; update logic plus graph code may push `SignedReceiver` past EIP-170. Decide early whether to move it to an external library. | Repo CLAUDE.md | |
| W15.5 | Error names | | One error per rejected check in W9.1 and W4.3, so tests can assert which check failed. | (new) | |
| W15.6 | Events | | Registration (W4.7), mutation completed, receiver update (W9.7), and freeze if selected. | Q6.1 | |
| W15.7 | Gas budget | | Measure registration, mutation post-hook, one update, and a batch of N at the depth limits, like `safe-signed-dispatch-measurements.md`. | (new) | |
| W15.8 | Docs to update | | `safe-guard-design.md`, `safe-signed-dispatch.md`, `encoding.md`, the issue text, then the tracker moves to `docs/planning/`. | Tracker end | |

## Edge-case map

Every edge case maps to the stage whose answer settles it; after each stage, we confirm
its cases still have a defined outcome. E1 to E28 come from the tracker (shortened
here) and keep its IDs; E29 onward are new.

| ID | Case | Settled by |
| --- | --- | --- |
| E1 | Malicious bridge alters genesis, mutation, next owners, source identity or leaf type | W3, W9.1 |
| E2 | New owner signs its own installation without old quorum | D17, W9.1 |
| E3 | One child update delivered to two receivers with different parents | D8, W9 |
| E4 | Parent 2/3 of B, C, D; B changes; C+D still works | D7 |
| E5 | Add, swap, remove ordering and wrong `prevOwner` | D10, W9.1 |
| E6 | Catch-up 3 -> 4 -> 5 -> 6 with changing signers | D9, W9.3 |
| E7 | Two different signed successors delivered in opposite order on two chains | D5, W14.4 |
| E8 | Source mutation fails after registration; receivers already advanced | W5.4, W6.4 |
| E9 | Two signed changes in one outer tx; the second fails | W5.6, Q3.4 |
| E10 | Child introduced twice, removed and reintroduced, shared across depths, or cyclic | W8 |
| E11 | Parent update signed using B, then B rotates before delivery | W6.5 |
| E12 | Many transmitters per parent; new transmitter at counter above 0 | W12 |
| E13 | Old standalone, root or commitment delivered around a rotation; exact duplicate follows | W10 |
| E14 | Earlier child approval keeps, loses or crosses a threshold change | D7 |
| E15 | Module self-call, delegatecall, guard, policy or handler change bypass attempts | W7.2 |
| E16 | Receiver bootstraps after several parent and child transitions | W11 |
| E17 | No provider, no publication, unaffordable fan-out, failed relay | W13 |
| E18 | Truncated or dynamic-offset nested signatures, `v = 1`, wrong hashes, unused evidence | W3.6, W3.7 |
| E19 | Zero, no-op or maximum counters; huge graphs or proofs; bad thresholds; duplicates | W2.6, W5.2, W8.6 |
| E20 | Application calls update entry point directly or via `commit`/`finalize`; reentry | W9.6 |
| E21 | Any other tx after registration (transfer, send, config, module call) | D15 |
| E22 | Mutation reenters, mismatches post-state, or needs approval from a locked Safe | W5.7, W6.2 |
| E23 | Same update to receivers where the Safe is root at one, child at another | D16, W9 |
| E24 | Registration leaf inconsistent with its mutation, bad proof, or wrong prior state | W4.3 |
| E25 | Nonce gap, second registration while pending, mutation B without its registration | D19, W4.5, W5.3 |
| E26 | Competing no-op at the registration or mutation nonce; outer tx replaced | D20, D21, W5.5 |
| E27 | Root or nested authority (including an unused child) changes after commitment acceptance; missing hash reads as default; duplicate acceptance overwrites | D22, W10.6, W10.8 |
| E28 | Graph returns A -> B -> A while an old commitment is unexecuted | D22, W8.3 |
| E29 | Dispatch signed at n+1 arrives before the update reaches that receiver | W10.3 |
| E30 | Registration tx authorized by `approveHash` (`v = 1`) | W3.6 |
| E31 | Registration or owner method attempted through a module | W4.8, W7.2 |
| E32 | No-op mutation: swap to the same owner, threshold to the same value | W5.2 |
| E33 | Owner swaps a Safe owner for an EOA, orphaning a child that later returns at counter k | W8.2, W8.3, W8.7 |
| E34 | Source reorg drops the registration after receivers applied the update | D4, D21 |
| E35 | Update submitted to a #108 receiver, or #108 and #109 conduits coexist for one Safe | W1.3 |
| E36 | Two Safes register and mutate in one outer tx; transient slots not cleared between them | W5.6 |
| E37 | Nested owner Safe lives on another chain | W1.4 |
| E38 | Catch-up batch or late bootstrap exceeds block gas | W9.4, W11.3 |
| E39 | Same update arrives once directly and once via a provider message | W9.5, D5 |
| E40 | Fallback handler, guard or module guard replaced while enrolled or while pending | W7.2, W7.3 |
| E41 | Freeze issued while an update is pending, or by a minority repeatedly (only if W14.2 is yes) | W14.2, W14.3 |

## Test plan and done criteria

The spec is ready for code when every W row has an answer or a deferral with a reason,
every E row has a defined outcome, and the items below are written down.

Shared vectors (one suite, run against both the source guard simulation and the
receiver):

- Node commitment, D22 graph hash and update leaf hashes for EOA-only, nested, mixed, multilevel and shared-child graphs
- Each Safe mutation (add, swap, remove, threshold) producing the same ordered owners and threshold as Safe 1.5.0
- Dynamic signature offsets, nested approvals at depth, and every rejected signature form
- Wrong authority, skipped counter, conflicting successor, cross-type replay (update as execution and the reverse)

End-to-end scenarios required by #109:

1. EOA owner change on the root Safe, then a dispatch under the new owners
2. Threshold change, then a dispatch at the new threshold
3. Child Safe B changes owners while parent A runs no transaction; A then dispatches under B's new authority
4. One B update delivered by arbitrary callers to two receivers with different parents
5. Late receiver created after several parent and child changes
6. Malicious bridge: chosen genesis root, altered payload, redirected update, malformed signatures, new-key self-authorization

Written artifacts before code: exact encodings in `encoding.md`, source and receiver
algorithms as numbered steps, the W7.2 enforcement matrix, storage layout (W15.1), size
and gas estimates (W15.4, W15.7).

## Decision log

One row per answer, newest first; copy each into the tracker beside its Q or C ID.

| Date | W-ID | Answer | Tracker IDs updated |
| --- | --- | --- | --- |
| 2026-11-12 | W10.7 | Settled by the tracker's revised D22 (whole-graph hash including node counters). | D22, Q5.5, E27, E28 |
