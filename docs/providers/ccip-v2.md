# CCIP 2.0 options

The binding supports optional CCIP 2.0 settings. Messages without attributes use
GenericExtraArgsV2 encoding and protocol default gas. Unconfigured inbound policies
use CCIP default verification and full finality. Outbound V3 requires explicit lane
configuration.

## Enable an outbound lane

The transceiver owner calls `setCcipV3Lane(destinationSelector, enabled, evidenceHash)`.
The selector must already be registered with `setProviderId`. Enabling requires a nonzero
hash of the operator's recorded deployment/version checks. This hash records an
attestation; the contract cannot verify the document or discover lane versions on-chain.
Follow [the deployment checks](../../contracts/evm/deploy/CHECKS.md#ccip-20-options) first.

`ccipV3LaneEnabled(selector)` is false until configured. Both transceiver and transmitter
quotes and sends consult this same setting for V3. Transmitters read their creating
transceiver's setting rather than maintaining another copy. Disabling stops new V3 quotes
and sends without changing already submitted messages. No provider error triggers a
fallback to another format. Enabling a lane does not change messages without attributes.

## Select message options

Supply either `CCIP_EXTRA_ARGS_ATTRIBUTE` with
`abi.encode(uint256 gasLimit, bool allowOutOfOrderExecution)`, or
`CCIP_EXTRA_ARGS_V3_ATTRIBUTE` with `abi.encode(ExtraArgsCodec.GenericExtraArgsV3)`.
Each attribute is its four-byte selector followed by the ABI-encoded body. At most one
attribute is allowed, so V2 and V3 cannot be combined. CCIP 2.0 accepts the legacy encoding
but ignores `allowOutOfOrderExecution`; older infrastructure retains its own behavior.

The V3 struct has these fields:

| Field | Behavior |
| --- | --- |
| `gasLimit` | A `uint32`. Zero selects the protocol's default gas, which must also fit `uint32`. |
| `requestedFinalityConfig` | Zero requests full finality. A numeric depth or the safe-head flag explicitly requests faster execution. |
| `ccvs`, `ccvArgs` | Equal-length arrays of verifiers and their opaque arguments. Empty arrays select CCIP defaults. Duplicate verifiers are rejected. |
| `executor` | Zero selects the default executor; a custom source-chain executor address selects that executor. |
| `executorArgs` | Opaque executor-specific arguments, validated and priced by the provider. |
| `tokenReceiver`, `tokenArgs` | Must be empty because this binding carries no tokens. |

Use `GasAttribute.ccip(options)` when constructing V3 deployment/governance payloads;
`GasAttribute.ccip(gas)` and `forMultisig` retain legacy defaults. Both sending and quoting
use `CcipMessage.buildOnLane` to build and validate the same provider message. Router
validation and pricing still apply; enabling a lane does not guarantee that a custom
verifier, executor, or finality mode is supported there.

V3 attributes are available wherever the protocol accepts provider attributes, including
user sends and transceiver bootstrap sends. Automatically generated receiver reports
supply no attributes and keep legacy/default behavior. A custom inbound policy for those
reports must be satisfiable by that default sending path and the deployed verifiers.

## Configure inbound policies

`setCcipPolicy(sourceSelector, abi.encode(sourceSender), policy)` updates exactly one
source selector and sender pair. The source selector and sender must be nonzero, and the
sender must have the canonical 32-byte EVM encoding. This setter does not authorize the
sender: existing home-origin, transmitter/counterpart, gateway-role, and replay checks
still apply when the message arrives.

A receiver accepts policy changes from its authenticated source transmitter or itself,
the same callers allowed by its execution entry point. A remote owner can therefore send
a normal authenticated payload containing a receiver self-call to change policy. A
receiver delivers only from its home selector and source transmitter, so it accepts a
policy for that one pair and refuses any other. A transceiver accepts changes only from
its owner, for any pair. Changes do not reopen upgrades or role
grants. Both standard EVM and divergent transceivers expose the v2 policy interface.

| Policy field | Rule |
| --- | --- |
| `requiredCCVs` | Every listed verifier is required. Include `address(0)` to retain the lane defaults alongside custom verifiers. |
| `optionalCCVs` | Nonzero addresses, with no duplicates within or across either list. |
| `optionalThreshold` | Zero for an empty optional list; otherwise from 1 through its length. |
| `allowedFinalityConfig` | Zero requires full finality. A minimum block depth, the safe-head flag, or their combination explicitly permits faster finality. Reserved flags are rejected. |

The combined verifier list is bounded to 255 entries. Empty verifier arrays restore
CCIP defaults. Empty arrays, zero threshold, and zero finality restore the full default
policy. A custom nonempty verifier policy replaces the default verifier set unless it
includes the zero-address placeholder. Required verification and optional thresholds
are enforced by CCIP's v2 OffRamp, not by trusting a sender-provided policy. Full finality
is always allowed. A requested nonfinal mode must meet the receiver's allowed policy;
sender attributes cannot relax it.

Policies are read at execution time. Updates apply to pending messages as well as new
ones, and can prevent pending messages from executing or relax their requirements. Plan
policy changes with the sending side and pending-message state before applying them.

A custom verifier policy on a receiver can stop its conduit permanently. The receiver
accepts policy changes only from itself and its source transmitter on the home chain, so
the only way to change its policy is a self-call delivered under that same policy. If a
required verifier stops attesting, or fewer optional verifiers than the threshold still
attest, the message that would reset the policy cannot be delivered either. Set a custom
verifier on a receiver only when its availability for the conduit's whole life is
acceptable. Finality settings cannot lock a receiver this way, since full finality is
always allowed. A transceiver's owner sets its policy directly, so a transceiver policy
locks only if the owner is itself reached through a locked receiver.

## Custom execution and No Exec

Set `executor` to a custom executor address, or to `Client.NO_EXECUTION_ADDRESS` to opt
out of automated execution. No Exec is not an application approval or an execution
schedule. An operator must track the message and arrange permissionless execution after
verification, supply transaction gas, and fund the receiver for any native-value calls.
Use CCIP's execution tooling with the message's verification data; a failed execution
needs a retry with sufficient gas and funds. Verification and protocol sender/origin
checks still apply. No configuration means the normal default executor remains in use.

## Storage, size, and validation

Policies and outbound lane flags use the ERC-7201 namespace
`crossecute.storage.CcipConfig`. They add no sequential fields to the protocol bases or
change Proxy initcode. Configuration has storage/write and execution costs. Receiver
policy reads and custom verification also add work outside the application callback.

Legacy extra args remain 68 bytes. V3's base encoding is 19 bytes. Each verifier adds a
one-byte address length, zero or 20 address bytes, a two-byte argument length, and its
arguments. A nondefault executor adds 20 address bytes; executor arguments add their byte
length. Token fields remain empty. The variable fields are needed for verifier proofs
and execution settings; the upstream codec bounds array counts and field lengths.
These sizes describe provider extra args, not the larger ABI-encoded transaction
attribute. Always use the router quote for fees rather than assuming an encoding saving
implies a fee saving.

See the [local validation report](ccip-v2-validation.md) for integration tests and native
compilation, and the [production enablement requirements](../todo.md#ccip-20-production-enablement)
for live requirements.

Sources: [CCIP message lifecycle](https://docs.chain.link/ccip/concepts/message-lifecycle),
[V3 configuration](https://docs.chain.link/ccip/concepts/architecture/message-configuration-extraargs),
and the pinned upstream files under `contracts/evm/lib/ccip/contracts/`.
