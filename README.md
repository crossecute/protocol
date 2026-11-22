# crossecute protocol

Manage smart contracts across chains from one wallet, Safe, or DAO governor. You approve changes on a home chain you choose. A messaging provider delivers the instructions, and a receiver on each destination carries them out. This gives your team one approval process and fewer admin accounts to maintain.

## How it works

```mermaid
flowchart LR
    Create["Create a transmitter on the home chain"] --> Setup["Bootstrap a receiver on each destination"]
    Setup --> Send["Approve and send an operation from home"]
    Send --> A["Receiver executes on chain A"]
    Send --> B["Receiver executes on chain B"]
```

Bootstrap is a one-time setup for each destination and can run its first operation.
For later operations, send one message per destination or use a Safe-signed Merkle root
to approve multiple executions at once. Each destination settles independently.

Use the [SDK](https://github.com/crossecute/sdk) to plan an operation. See the [operator guide](docs/operator-guide.md) for setup and trust assumptions, and the [deployment checklist](docs/todo.md) for work still open before mainnet.

## Full operation flow

### Create and bootstrap

The owner chooses the home chain by calling `createTransmitter` there. The home
transceiver deploys, initializes, and locks the transmitter proxy in one transaction.
The owner can also run calls locally with `transmitter.execute(calls)`.

```mermaid
sequenceDiagram
    participant O as Owner
    participant H as Home transceiver
    participant T as Transmitter
    participant P as Messaging provider
    participant D as Destination transceiver
    participant R as Receiver

    O->>H: createTransmitter(salt)
    H->>T: Deploy, initialize, and lock transmitter
    O->>T: bootstrap(payload, attributes)
    T->>T: Check authorization and record dispatch
    alt Receiver address is derivable at home
        T->>H: predictReceiver
        H-->>T: Predicted address to record
    else Destination reports its address
        Note over T: Receiver address stays unset
    end
    T->>H: Pay the quoted bootstrap cost
    H->>P: Send the bootstrap envelope
    Note over T,P: Home transaction ends with bootstrap dispatched
    P->>D: Deliver bootstrap on the destination
    D->>D: Authenticate home transceiver
    D->>R: Deploy, bind source, run setup calls, and lock
    opt Destination reports its address
        D->>P: Send receiver report in the same delivery transaction
    end
    Note over D,R: Successful delivery leaves a live receiver
    opt Report was sent
        P->>H: Deliver report on the home chain
        H->>T: Authenticate report and record receiver address
    end
```

The bootstrap payload names the destination and its setup calls. In signed mode it
also carries the authority graph and update head selected by the source Safe's guard.
On a predicted route, home records the address at dispatch, before the receiver exists.
Wait for successful destination delivery. On a reporting route, also wait for the
report to reach home. The native LayerZero binding requires a write-once transmitter
peer for the destination.

If setup calls or the report send revert, receiver creation rolls back and the
bootstrap delivery can be retried. [Bootstrap checks, fees, and retry behavior](docs/architecture/message-flow.md#b-bootstrap-no-receiver-on-the-destination-yet)

### Send and execute

On an EVM route, `recipientOn(chainId)` returns the receiver's ERC-7930 address.
The transmitter checks the recipient, quotes the provider and protocol fees, and
sends through its own provider endpoint. The receiver authenticates the transport,
home chain, and transmitter before running the payload.

```mermaid
sequenceDiagram
    participant O as Owner
    participant T as Transmitter
    participant P as Messaging provider
    participant F as Any destination caller
    participant R as Receiver
    participant C as Target contracts

    O->>T: sendMessage(recipient, payload, attributes)
    T->>P: Dispatch to the receiver and pay the provider quote
    Note over T,P: Home transaction ends with message dispatched
    P->>R: Deliver in a destination transaction
    R->>R: Authenticate delivery and decode payload
    alt Execute on arrival
        R->>C: Run calls in order in the delivery callback
    else Approve for later
        R->>R: commit(hash) records one approval
        Note over F,R: Delivery ends with the approval recorded
        F->>R: finalize(calls) in a separate transaction
        R->>R: Hash calls with the local chain key
        alt Matching approval exists
            R->>R: Consume one approval
            R->>C: Run approved calls in order
        else No matching approval
            R-->>F: Revert
        end
    end
```

A deferred payload calls the receiver's own `commit`. A later `cancel(hash)` self-call
removes all outstanding approvals for that hash when it lands. A reverting call rolls
back its whole batch, including any approval consumed by `finalize`. Failed provider
deliveries can be retried. [Delivery and failure handling](docs/architecture/message-flow.md#failure-handling)

### Verify a Safe-signed operation

A Safe-signed receiver checks the Safe authorization against its stored authority
graph before executing. The Safe can sign a standalone send or sign a Merkle root
that covers multiple execution leaves. Each leaf names its destination, calls,
local nonce, and validity window.

```mermaid
sequenceDiagram
    participant S as Source Safe
    participant T as Transmitter
    participant L as Any relayer
    participant P as Messaging provider
    participant R as Signed receiver
    participant C as Target contracts

    alt Standalone operation
        alt Send through the provider
            S->>T: Signed sendMessage through the guard
            T->>P: Dispatch payload and Safe evidence
            P->>R: Deliver signed message
        else Submit directly
            L->>R: submitMessage with signed Safe evidence
        end
    else Merkle operation
        S->>T: registerRoot(root)
        alt Relay through the provider
            L->>T: relayLeaf with signed registration, leaf, and proof
            T->>P: Dispatch registration, leaf, and proof
            P->>R: Deliver signed leaf
        else Submit directly
            L->>R: submitLeaf with signed registration, leaf, and proof
        end
    end
    R->>R: Verify authorization and replay state
    R->>C: Execute newly authorized calls atomically
```

Provider delivery and direct submission share replay state. Receivers follow
linked authority updates to track Safe ownership and threshold changes.
[Safe-signed dispatch](docs/safe/safe-signed-dispatch.md) ·
[Safe authority updates](docs/safe/safe-authority-updates.md)

### Change authority in plain mode

The current owner transfers ownership of the transmitter on the home chain. The
receivers authenticate the same transmitter address after the handoff, so the new
owner can use the existing receivers as soon as the transfer succeeds.

```mermaid
sequenceDiagram
    participant O as Current owner
    participant N as New owner
    participant T as Transmitter
    participant P as Messaging provider
    participant R as Receiver

    O->>T: transferOwnership(newOwner)
    T->>T: Check current owner and store new owner
    Note over T: Home transaction ends with the handoff complete
    N->>T: sendMessage(recipient, payload, attributes)
    T->>P: Dispatch from the existing transmitter address
    P->>R: Deliver the next operation
    R->>R: Authenticate the same transmitter and run the calls
```

If the plain-mode owner is a Safe and its address stays the same, changing the
Safe's signers or threshold happens entirely within that Safe.

### Change authority in Safe-signed mode

The transmitter stays owned by the source Safe. The current quorum signs an update
that links the previous update head to the new authority graph. Each receiver
advances its own head and graph when it accepts the update.

```mermaid
sequenceDiagram
    participant S as Source Safe
    participant L as Any submitter
    participant G as Source Safe guard
    participant T as Transmitter
    participant P as Messaging provider
    participant R as Signed receiver

    Note over S,L: Current Safe quorum signs the linked update
    alt Relay a published update
        L->>G: stageUpdate with graph and portable evidence
        L->>S: Execute the signed Safe transaction in the same transaction
        S->>G: Guard verifies update and publishes evidence on success
        L->>T: relayAuthority with the exact published submission
        T->>P: Check publication and send update
        P->>R: Deliver from the authenticated transmitter
    else Submit signed evidence directly
        L->>R: submitAuthority with the signed update and graph
    end
    R->>R: Check predecessor, graph, and quorum
    R->>R: Store the new head and authority graph atomically
```

Direct submission can use valid signed evidence without source execution or
publication. A receiver that missed several updates applies them in predecessor
order, optionally in one `submitAuthorityBatch` transaction.
[Safe authority transport and publication](docs/safe/safe-authority-updates.md#authority-transport-and-publication)

### Bootstrap and send through a LayerZero OFT

The `layerzero-oft` factory creates a transmitter for a fixed set of destinations
and OFTs. Messages use a zero-token OFT send and a LayerZero compose callback.

```mermaid
sequenceDiagram
    participant O as Owner
    participant H as Home factory
    participant T as Transmitter
    participant P as OFTs and LayerZero endpoints
    participant D as Destination factory
    participant R as Receiver

    O->>H: createTransmitter(salt, homeOft, leaves)
    H->>T: Deploy and lock with destination set bound to address
    O->>T: bootstrap(payload, attributes)
    T->>P: Send bootstrap compose with destination proof
    P->>D: lzCompose to the factory
    D->>D: Verify endpoint, OFT peer, proof, and source conduit
    D->>R: Deploy, bind source, run setup calls, and lock
    O->>T: sendMessage(recipient, payload, attributes)
    T->>P: Send operation compose addressed to the receiver
    P->>R: lzCompose to the receiver
    R->>R: Authenticate delivery and execute the operation
```

Both plain and Safe-signed conduits can use the OFT route. [OFT binding specification](docs/providers/layerzero-oft-spec.md)
