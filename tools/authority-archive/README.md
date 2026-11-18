# Authority evidence archive

`archive.py` preserves full source graphs and exact portable update submissions for
[#145](https://github.com/crossecute/protocol/pull/145). It uses Python's standard
library and Foundry `cast` (tested with the repository's CI version, 1.8.1). It
performs no RPC calls and sends no transactions.

The archive is a local directory, scoped by source chain, guard and Safe. Graphs are
keyed by authority hash; submissions are keyed by SafeTx head. Imports require an
expected graph or publication hash and check the graph's source identity, graph hash
and SafeTx hash. These are data-integrity checks. They do not verify quorums, child
proofs, source finality or the pinned MultiSend helper. The guard and receivers remain
the authority verifiers. Archive contents cannot authorize an update on their own.

## Capture and import

Put the archive on persistent storage outside the checkout. Preserve a copy on an
independent host or storage service, and test restoration before relying on it. Local
writes flush each complete object and install it without replacing an existing
object. Imports are idempotent; conflicting contents reject. There is no mutable
"latest" pointer. A partial import can leave an unused graph, but cannot expose a
partial submission. Filesystem guarantees and backups determine actual durability.

For activation, retain the full graph supplied to `stageUpdate` before executing the
Safe transaction. Activation emits no full submission. Its graph can also be obtained
from a later bootstrap carrying that same selection. For successors, retain the full
`submission` field of every `AuthorityPublished` emitted by the configured guard,
including its embedded child evidence. Also retain source receipts/block hashes and
apply the source chain's finality policy before treating a log as canonical. A scanner
and storage-service deployment are operational integration work; this utility imports
explicit evidence files and does not run a background indexer.

Obtain the expected values independently from the configured source guard, using the
same finalized block as the corresponding receipt:

- `selection(safe)` returns `(updateHead, authorityHash)` for a graph witness.
- `publishedAuthority(safe, updateHead)` returns the exact submission hash for a
  successor. A zero hash is not a publication.

Do not trust an expected hash supplied by an untrusted archive. A receiver's current
head determines where catch-up starts; a newly bootstrapped receiver needs only the
successors of its bootstrap head. A retained child's missing links cannot be replaced
with an older cached graph.

Each input file below contains one `0x`-prefixed ABI byte string, with no selector.
`graph.hex` is `abi.encode(AuthorityGraph)`. `submission.hex` is exactly
`abi.encode(SafeTxEvidence, AuthorityGraph, ChildUpdate[])`, as published. Decode a
log's data as `(bytes)` to extract the submission, rather than storing the log's ABI
wrapper. The graph can be extracted from staging calldata or a signed bootstrap's
encoded graph. The Solidity types are defined in `contracts/evm/src/messaging/`.

```bash
# Fill these values from the configured source and finalized state.
archive_args=(--archive /persistent/authority --chain "$source_chain" --guard "$guard" --safe "$safe")

python3 tools/authority-archive/archive.py "${archive_args[@]}" put-graph \
  --file graph.hex --hash "$authority_hash"

python3 tools/authority-archive/archive.py "${archive_args[@]}" put-submission \
  --file submission.hex --head "$update_head" --publication "$publication_hash"
```

A submission import also stores its full new graph. Child updates remain embedded
in the exact parent submission. To retrieve a child's own full graph, import that
child's staging graph or its own publication under the child's Safe namespace; a
parent's embedded child entries alone do not reconstruct that full graph.

## Retrieve and recover

```bash
python3 tools/authority-archive/archive.py "${archive_args[@]}" get-graph \
  --hash "$selected_authority_hash" > current-graph.hex

python3 tools/authority-archive/archive.py "${archive_args[@]}" get-chain \
  --start "$receiver_head" --target "$source_head" > catchup.json
```

`get-graph` recomputes the requested hash. `get-chain` follows predecessor hashes
from the target back to the exact start and returns a JSON array of submissions in
forward order. Consume the output only after a successful exit. It checks every object's publication digest, root graph commitment
and SafeTx hash on read. Missing objects, corrupt data and a target on another branch
fail with a nonzero exit and no partial JSON result. No update is sent, and no
historical checkpoint substitutes for a missing link. The same start and target
produce an empty array. After an interrupted destination batch, read the receiver's
head again and retrieve successors from that head.

If an object is missing, restore it from an independent copy or the original source
calldata/logs, check it against source state, and retry. A hash cannot recover missing
bytes. Do not change the receiver's starting head or bypass its proof checks. If
source history and all copies are lost, this utility cannot restore availability.
Before relaying recovered bytes, `quoteAuthority`/`relayAuthority` recheck their exact
publication on source; direct destination submissions verify their full evidence
under the receiver's selected authority. Modifying the archive and its local digest
is not proof that evidence was published on source.

Archive bytes add no on-chain storage, gas or wire-format cost. Disk use grows with
the full graphs and submissions retained. Store every source update needed by any
lagging receiver and every graph still needed as a source witness. A later update
with the same owners does not make intermediate links disposable.

## Verification

```bash
PATH="$HOME/.foundry/bin:$PATH" python3 -B -m unittest discover -s tools/authority-archive -v
```

Tests recover accepted shared receiver vectors, import the activation/bootstrap
graph, restore an independent backup, detect corrupted and missing files, reject
wrong domains/hashes, and recover ordered catch-up after restoring a missing prefix.
The generated successor uses the existing public vector-fixture keys and quorum.
Solidity tests separately reject missing child links and catch-up prefixes, then
accept restored evidence; out-of-gas tests cover interrupted batch rollback.
