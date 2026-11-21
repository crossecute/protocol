# Protocol documentation

## Architecture

- [Message flow](architecture/message-flow.md) explains delivery, receiver bootstrap, and failure handling.
- [Call encoding](architecture/encoding.md) defines the payload and commitment formats.

## Naming

- [Naming and function reference](naming-spec.md) states the naming rules for the protocol and the SDK and lists every function by file, with its callers.
- [Foundry scripts reference](scripts-spec.md) lists the SDK's Foundry scripting files the same way.

## Message providers

- [Operator guide](operator-guide.md) covers setup and deployment assumptions, including [how to add a chain or provider](operator-guide.md#adding-a-chain-or-provider).
- [Provider compliance](providers/provider-spec.md) defines the requirements and compliance tests for bindings.
- [LayerZero OFT binding](providers/layerzero-oft-spec.md) specifies OFT prerequisites and transport behavior.
- [CCIP 2.0 options](providers/ccip-v2.md) describes lane configuration, message options, and inbound policies. The [validation report](providers/ccip-v2-validation.md) records local test coverage.
- [Provider research](https://github.com/crossecute/research/blob/main/protocol/provider-research.md) covers transport guarantees and candidate bindings.

## Safe integration

- [Safe-signed dispatch](safe/safe-signed-dispatch.md) describes message registration, relay, and signature verification.
- [Safe guard](safe/safe-guard-design.md) describes source-side signature staging and child approval evidence.
- [Safe authority updates](safe/safe-authority-updates.md) specifies ownership changes and receiver catch-up. The [shared test vectors](vectors/safe-authority-updates-109.json) pin the encodings and hashes.

## Benchmarks

- [Safe-signed dispatch measurements](benchmarks/safe-signed-dispatch-measurements.md) records verification gas, runtime sizes, and reproduction steps.
- [Child approval evidence sizing](../contracts/safe-guard/README.md#child-approval-evidence-sizing) covers the cost of storing approvals in the guard.
- [Safe authority benchmark](benchmarks/authority-109/README.md) records signature verification gas and wire sizes. [Authority update measurements](benchmarks/authority-109/updates.md) covers the implemented update paths.

## Planning

- [Outstanding work](todo.md) tracks open protocol and deployment work.
- [Authority verification plan](planning/safe-authority-verification-review.md) maps requirements to implementation and acceptance coverage.
- [Authority review decisions](planning/safe-authority-review-109.md) records the disposition of design review findings.
