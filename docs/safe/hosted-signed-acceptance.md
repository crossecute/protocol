# Hosted Safe signing and direct delivery acceptance

Use a disposable route from a Safe Queue-supported home chain. The home Safe needs the
release guard, selected authority, and an EOA quorum controlled by Ledger signers. Bootstrap
a signed receiver on the destination using that authority. Use an independent destination
submitter and a test target with a readable counter or equivalent observable effect. Record
the protocol and SDK revisions, chain IDs, Safe, transmitter, receiver, and target addresses.
The pinned provider forks and package consumer tests run separately.

## Collect the signatures

Use the candidate SDK's [signed bundle and Safe Queue guide](https://github.com/crossecute/sdk/blob/main/docs/usage.md#propose-confirm-and-export-through-safe-queue)
to prepare a standalone send and a one-leaf Merkle registration, each with the target's
harmless call and an unused source Safe nonce. Read the receiver's `nextNonce()` when
building the leaf and set a validity window that covers the test. The operators can use a
separate disposable Safe and receiver for each case, or use distinct Safe nonces on the
same route. Record the Safe nonce, receiver nonce, target state, and Merkle registration state
before collecting signatures.

For each unsigned bundle, use an authorized `SAFE_API_KEY` and the candidate SDK CLI:

```bash
crossecute signed-propose "$UNSIGNED_BUNDLE" "$OWNER_A"
crossecute signed-confirm "$UNSIGNED_BUNDLE" "$OWNER_B"
crossecute signed-export "$UNSIGNED_BUNDLE" "$OWNER_A" "$OWNER_B" > "$DELIVERY_BUNDLE"
```

Confirm that both proposals appear pending in the hosted queue with their expected Safe
transaction hashes. Every signer uses the SDK's acknowledgment prompt and checks the home
Safe, destination receiver, and calls before signing on the Ledger. Leave both proposals
pending and leave the Merkle root unregistered throughout the delivery test.

## Verify independent delivery

From a Node project that has installed the candidate SDK, the submitter can encode the
first leaf or the standalone message from the exported bundle:

```bash
CALLDATA=$(node --input-type=module - "$DELIVERY_BUNDLE" <<'JS'
import { readFileSync } from "node:fs";
import { parseDeliveryBundle, submitLeafFromBundle, submitMessageFromBundle } from "@crossecute/sdk";

const bundle = parseDeliveryBundle(readFileSync(process.argv[2], "utf8"));
console.log(bundle.merkle ? submitLeafFromBundle(bundle, 0) : submitMessageFromBundle(bundle));
JS
)
cast call "$RECEIVER" "$CALLDATA" --from "$SUBMITTER" --rpc-url "$DESTINATION_RPC_URL"
```

After simulating, have the independent submitter send the same calldata to that receiver
using their test-chain wallet. For each case, verify these results against receipts and
contract reads:

1. The destination emits `MessageExecuted` with the standalone Safe transaction hash or
   `LeafExecuted` with the Merkle execution nonce. The target effect occurs exactly once.
2. The source queue entry remains pending and the source Safe's `nonce()` stays unchanged.
   In the Merkle case, `isRootRegistered(root)` on the transmitter still returns `false`.
3. Simulate the exact calldata again. Repeat delivery either returns without executing or
   reverts. Verify no second execution event or target effect, and record the receiver's
   execution state and the destination block used for the replay check.

Record the source and destination block numbers, queue lookup hashes, destination receipts,
the target and nonce readings, and the replay outcome. Keep the RPC and queue credentials
out of the record. Hosted signing and independent delivery are verified only after both
cases pass on the disposable route with the Ledger signers.
