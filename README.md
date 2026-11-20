# crossecute protocol

Manage smart contracts on multiple chains from one account. A team can use an
existing wallet, Safe multisig, or DAO governor to authorize operations such as
upgrades and ownership transfers from a home chain of its choice.

## How it works

The owner creates a cross-chain account called a **conduit** on a supported
home chain. A messaging provider delivers instructions to the conduit's
receiver on each connected destination. The receiver can execute the calls on
arrival or record an approval for later execution. Messages arrive
independently, so each destination executes on its own schedule.

In plain mode, receivers rely on the configured messaging provider to
authenticate instructions. With a compatible guard, a Safe can create a
conduit whose receivers also verify Safe signatures on subsequent operations.
The initial setup on each destination still relies on the provider. See the
[message flow](docs/architecture/message-flow.md) and
[Safe-signed dispatch](docs/safe/safe-signed-dispatch.md) for details.

## Why use it

Teams can use one approval process for changes across multiple chains and
avoid running a separate admin wallet or multisig on every destination.
Each receiver needs the permissions for the contracts it manages.

## Get started

Use the [SDK](https://github.com/crossecute/sdk) to simulate destination calls
and prepare a transaction for review. To evaluate or deploy the contracts, see
the [operator guide](docs/operator-guide.md), [deployment checks](contracts/evm/deploy/CHECKS.md),
and [protocol docs](docs/README.md).

Run the EVM contract tests from a checkout with [Foundry](https://getfoundry.sh/):

```bash
git submodule update --init
cd contracts/evm
forge test
```

The [deployment checklist](docs/todo.md) tracks work still needed before mainnet.
