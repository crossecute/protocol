# Pinned CCIP integration artifacts

These are the exact creation binaries from `@chainlink/contracts-ccip` 2.0.0:
`bytecode/v2_0_0/offramp.bin` and `bytecode/v1_2_0/router.bin`. The package ships this
Router version alongside its v2 OffRamp. Its license and license grants are copied
alongside the binaries; these are test artifacts, not MIT application interfaces.

Reproduce with `contracts/evm/script/vendor/ccip-test.sh` from the repo root. It checks
the package archive's pinned SHA-256 before copying, then verifies `SHA256SUMS`.
The package tag is `contracts-ccip-v2.0.0`, commit
`c2c125c27f056db2e98d21501922b6eff5750f36`. The MIT MessageV1 codec under `lib/ccip/`
is separately reproduced by `script/vendor/ccip.sh` at the same commit.

The tests deploy the actual binaries with constructor arguments and use their public
interfaces. No OffRamp verification, finality, quorum, delivery, retry, or replay logic
is replaced. A local uncursed RMN and two distinct signing-key verifier/resolver
contracts provide controlled infrastructure dependencies; attestations cover the exact
encoded message hash. These tests do not establish the behavior of a production CCV
service, RMN network, live lane, or executor service.

The binaries require a Cancun-capable EVM, selected only inside this integration suite
with `vm.setEvmVersion`. Protocol sources remain compiled for Paris. Native zkSync/Tron
execution and deployed-lane readiness require separate environment-specific checks.
