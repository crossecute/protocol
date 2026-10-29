# How token-vote DAOs execute across chains

Status: research, dated 2026-10-29. It records how four large token-vote DAOs turn a passed
vote into execution on other chains, and which parties can override the vote. It is the
evidence behind the rotation-authority item in
[`signed-dispatch-spec.md`](signed-dispatch-spec.md#9-open-integration-with-this-repository)
section 9, and the starting point for proposing signed dispatch to these DAOs as a
replacement for their cross-chain execution.

Each fact is marked by where it came from:

- **Onchain**: read with `cast` from Ethereum, Arbitrum One or Polygon PoS on 2026-10-29.
  The addresses of Arbitrum's council Safes and L1 timelock, Uniswap's governor and timelock,
  Optimism's `ProxyAdmin` and council, and Aave's governance contract and Polygon controller
  were recalled, not looked up in each DAO's published address list. Each returned values
  consistent with its role (for example 9 of 12 owners, a 3-day delay), but confirm them
  against the published lists before a proposal cites them.
- **Docs**: the DAO's own documentation or forum. Not checked onchain.
- **Secondary**: third-party reporting. Treat as unconfirmed.

Like [`provider-research.md`](provider-research.md), this goes stale on the DAOs' schedule,
not ours. Re-read the onchain values before quoting them in a proposal.

## Contents

| | |
| --- | --- |
| [1. Summary](#1-summary) | one row per DAO |
| [2. Uniswap](#2-uniswap) | |
| [3. Aave](#3-aave) | |
| [4. Arbitrum](#4-arbitrum) | |
| [5. Optimism](#5-optimism) | |
| [6. What Safe supports today](#6-what-safe-supports-today) | owner control by a DAO, on one chain and across chains |
| [7. What this means for signed dispatch](#7-what-this-means-for-signed-dispatch) | |
| [8. Sources](#8-sources) | |

## 1. Summary

| DAO | Where votes are cast | What makes a vote take effect | Cross-chain path | Who can override the vote |
| --- | --- | --- | --- | --- |
| Uniswap | Ethereum, Governor Bravo | Timelock (2 days) | One bridge per chain: native on Arbitrum, Wormhole on others | None found; each destination trusts its bridge |
| Aave | Voting chains, with storage proofs of Ethereum balances | Governance contract on Ethereum, then a payloads controller per chain | a.DI: several bridges per route, k of n must agree | Governance guardian, 5 of 9 |
| Arbitrum | Arbitrum One | L2 timelock, L1 timelock, `UpgradeExecutor` | Arbitrum's native bridges only | Security Council, 9 of 12, no delay |
| Optimism | OP Mainnet, Token House | Not bound to the vote; a 2-of-2 of Safes upgrades L1 | Not applicable | The 2-of-2 executes or does not |

Every one of the four already trusts something other than the vote: a bridge per chain, a
quorum of bridges, or a multisig that can act without a vote.

## 2. Uniswap

**Voting.** Onchain on Ethereum. The governor at
`0x408ED6354d4973f66138C91495F2f2FCbd8724C3` is a Governor Bravo delegator (it answers
`implementation()`, currently `0x53a328F4086d7C0F1Fa19e594c9b842125263026`). Onchain:

| Parameter | Value | At 12-second blocks |
| --- | --- | --- |
| `proposalThreshold` | 1,000,000 UNI | |
| `quorumVotes` | 40,000,000 UNI | |
| `votingDelay` | 13,140 blocks | about 1.8 days |
| `votingPeriod` | 40,320 blocks | about 5.6 days |
| Timelock `0x1a9C8182C09F50C8318d769245beA52c32BE35BC` `delay` | 172,800 s | 2 days |

Uniswap's docs describe a 2-day wait and a 7-day vote. The block counts give less at
today's 12-second blocks; 40,320 blocks is 7 days only at 15-second blocks. The block counts
are what the contract enforces. Snapshot temperature checks before the onchain vote are
signals only.

**Cross-chain execution (docs).** The Timelock owns the protocol on Ethereum. On another
chain the owner is a receiver that accepts messages from the Timelock over one bridge: the
native bridge on Arbitrum, where the owner is the Timelock's aliased address, and a
`UniswapWormholeReceiver` on chains such as Avalanche and MegaETH (proposal 98, executed,
proposed 2026-07-04). A destination trusts its one bridge in full. The Uniswap Foundation
has recommended moving to a multi-bridge design; no sign it has been adopted.

**Override.** No multisig that can override a vote was found. The trust in a third party is
all in the bridges.

## 3. Aave

**Voting (docs).** Governance v3 keeps balances on Ethereum and casts votes on voting chains
(initially Polygon PoS and Avalanche, with Ethereum as a fallback). A voter submits a
storage proof of their balance against a snapshot Ethereum block hash, so a voting chain
cannot forge balances. It can censor or delay votes. The block hash reaches the voting chain,
and the result returns to Ethereum, over a.DI. Onchain, the governance contract at
`0x9AEE0B04504CeF83A65AC3f0e838D0593BCb2BC7` reports 3 voting portals.

**a.DI (Aave Delivery Infrastructure).** A `CrossChainController` on each chain sends every
message through each bridge adapter enabled for the route, and the receiving controller acts
once a set number of distinct adapters have delivered the same message. Onchain, for the
Ethereum to Polygon PoS route:

| Ethereum-side adapter | `adapterName()` |
| --- | --- |
| `0xB7a6618df58626C3a122ABAFD6Ee63Af63f3Ef29` | CCIP adapter |
| `0x1562F1b2487F892BBA8Ef325aF054Fd157510a71` | Polygon native adapter |
| `0x8410d9BD353b420ebA8C48ff1B0518426C280FCC` | LayerZero adapter |
| `0x01dcb90Cf13b82Cde4A0BAcC655585a83Af3cCC1` | Hyperlane adapter |

The Polygon controller (`0xF6B99959F0b5e79E1CC7062E12aF632CEb18eF0d`) requires 3 of its 4
receiver adapters for messages from Ethereum. So forging a governance message to Polygon
takes 3 bridges, and blocking one takes 2. Other routes differ: a forum post set a newer
network's route to 1 of 1 (docs), which is single-bridge trust. Routes other than Polygon
were not read onchain.

**Override.** Onchain, the governance contract's `guardian()` is
`0xCe52ab41C40575B072A18C9700091Ccbe4A06710`, a Safe with threshold 5 of 9 owners. Aave's
docs describe an "Aave Guardian" as a 6-of-10 multisig elected by governance that can cancel
malicious payloads; that description may refer to a different guardian or be out of date.
The governance contract's `owner()` is `0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A`, not
identified here.

## 4. Arbitrum

**Voting.** Onchain on Arbitrum One. A constitutional proposal then runs (docs): L2 timelock
(8 days since the constitutional AIP that extended it) → `ArbSys.sendTxToL1` → outbox → L1
timelock → retryable ticket back to L2 → `UpgradeExecutor`. Every hop uses Arbitrum's native
bridges, so the vote is as safe as the rollup, and it reaches only Ethereum and Arbitrum
chains.

**Security Council, onchain.** The L1 council Safe
`0xF06E95eF589D9c38af242a8AAee8375f14023F85`:

- Safe v1.3.0, threshold 9 of 12 owners;
- **no guard** (the guard slot is zero);
- one module, `0x3ffFbAdAF827559da092217e474760E2b2c3CeDd`, the L1 `UpgradeExecutor`. Both
  the L1 timelock `0xE6841D92B0C345144506576eC13ECf5103aC7f49` (`getMinDelay` 259,200 s,
  3 days) and the council Safe itself hold its `EXECUTOR_ROLE`.

The Arbitrum One emergency council `0x423552c0F05baCCac5Bfa91C6dCF1dc53a0A1641` is also
Safe v1.3.0, 9 of 12, with no guard. L2BEAT reported "10/13" in July 2026; the onchain
values above are 9 of 12.

**Elections.** Token holders elect the council. A manager contract turns results into
cross-chain calls of `SecurityCouncilMemberSyncAction.perform()` through the L1 timelock,
which change the owners of the four council Safes (L1, Arbitrum One emergency and propose,
Nova). After the March 2026 election the L1 timelock scheduled four such calls (secondary:
L2BEAT).

**Override.** The council's emergency path can upgrade any core contract with no delay and
no vote. It has been used, including in October 2025 and May 2026 (docs); secondary sources
report it was used to recover KelpDAO funds (not verified). Because the Safe has no guard,
9 of 12 owners can also change the council's own owners and threshold, or disable the
module, directly. Only the Arbitrum Constitution limits this: members may remove a member
only when the removal criteria are met. The contracts do not.

## 5. Optimism

**Voting (docs).** Token House votes have been onchain on OP Mainnet since 2023, through
Agora's governor. Citizens' House votes, including its veto over protocol upgrades,
historically ran on Snapshot, which is offchain; not confirmed whether they still do.

**Execution, onchain.** The vote does not execute anything. The L1 `ProxyAdmin`
`0x543bA4AADBAb8f9025686Bd03993043599c6fB04` is owned by
`0x5a0Aae59D09fccBdDb6C6CcEB07B7279367C3d2A`, a Safe needing 2 of 2 owners:

- `0xc2819DC788505Aac350142A7A707BF9D03E3Bd03`, the Security Council: Safe v1.3.0, 10 of 13;
- `0x847B5c174615B1B7fDF770882256e2D3E95b9D92`, assumed here to be the Optimism Foundation's
  Safe (not identified onchain).

So an L1 upgrade needs both. A vote binds only because both choose to honor it. The 2026
Optimism blog says the Security Council implements upgrades; the onchain owner shows that is
true only together with the second Safe.

**Council membership, onchain.** The council Safe has a guard,
`0x24424336F04440b1c28685a38303aC33C9D14a25` (`version()` 1.0.0, `safe()` is the council),
and one module, `0x0454092516c9A4d636d3CAfA1e82161376C8a748` (`version()` 1.2.0) with
`livenessInterval` 8,467,200 s (98 days), `minOwners` 8, `thresholdPercentage` 75, and
`fallbackOwner` `0x847B…9D92`. From those values these are Optimism's liveness guard and
liveness module: owners who have not signed within 98 days can be removed, and if the council
falls below 8 owners, control passes to the fallback owner. Whether the guard also stops the
owners from changing the owner set themselves was not checked; its code was not read.

## 6. What Safe supports today

**On one chain.** Safe's owner functions (`addOwnerWithThreshold`, `removeOwner`,
`swapOwner`, `changeThreshold`) can be called only by the Safe itself, which happens through
an owner-signed `execTransaction` or an enabled module's `execTransactionFromModule`. So a
module that only a DAO's executor can call already lets the DAO change owners; Arbitrum works
this way. Safe has no built-in setting that makes the DAO the only one who can. That needs a
transaction guard (Safe v1.3.0 and later) that rejects owner-signed calls to the owner
functions, `disableModule`, `setGuard` and `setModuleGuard`, plus Safe v1.5.0's module guard
for the module path. Neither Arbitrum council Safe has a guard.

**Across chains.** Each chain's Safe is a separate contract with its own owners. Safe's own
October 2024 post says owner changes must be repeated on each chain. Proposals exist: an
Optimism grant for a hub module that propagates owner changes, and Safe forum threads dated
2026-01-28 ("Cross-Chain Signers Synchronization for Multi-sig Wallets") and 2026-03-17
("Safe Unified Account: One Signature, Every Chain"), read by title only. No shipped
mechanism was found.

## 7. What this means for signed dispatch

- **The trust signed dispatch asks for is not new to these DAOs.** Each already accepts a
  multisig that can act without a vote (Arbitrum, Optimism, Aave), or one bridge per chain
  (Uniswap). A council elected by the DAO that signs dispatches, with the DAO's approval
  checked at home, adds no trust beyond that, and removes the trust in bridges that Uniswap
  and Aave carry today.
- **Kind 2 of the rotation authority is stricter than all four.** None of them stops its
  council from changing its own members by contract: Arbitrum's council Safes have no guard,
  and Optimism's guard was not shown to block it. Under kind 2, destinations refuse rotations
  signed by the current tree, so the council can change only through the DAO's write at home.
- **Arbitrum's native-bridge path is the closest existing design to kind 2**, and it reaches
  only Ethereum and Arbitrum chains. Kind 2 generalizes it to any chain that can verify a
  home block hash.
- **Aave's a.DI is the closest existing design to a provider quorum.** On Polygon it needs 3
  of 4 bridges. Signed dispatch removes the bridges from the safety question instead of
  needing several to agree; a quorum across providers would still help liveness.

Open before a proposal to any of these DAOs: Aave's routes other than Polygon, the identity
of the second Optimism Safe and Aave's guardian, and whether Optimism's liveness guard
blocks owner-initiated changes.

## 8. Sources

Onchain values are from public RPCs on 2026-10-29, at the addresses given above.

- Uniswap: [governance process](https://developers.uniswap.org/docs/ecosystem/governance/governance-process.md),
  [Governance Proposal 8 (Bravo)](https://gov.uniswap.org/t/governance-proposal-8-upgrade-governance-contract-to-compounds-governor-bravo/13835),
  [proposal 98](https://www.tally.xyz/gov/uniswap/proposal/98),
  [crosschain parameters temp check](https://gov.uniswap.org/t/temp-check-update-crosschain-governance-parameters-for-avalanche-megaeth-soneium-and-x-layer/26127),
  [cross-chain governance grant update](https://gov.uniswap.org/t/grant-update-cross-chain-governance/22589),
  [governance overview](https://docs.uniswap.org/contracts/v3/reference/governance/overview)
- Aave: [governance docs](https://aave.com/docs/developers/governance),
  [BGD: a.DI](https://governance.aave.com/t/bgd-a-di-aave-delivery-infrastructure/13951),
  [technical maintenance proposals](https://governance.aave.com/t/technical-maintenance-proposals/15274/114),
  [Sonic enablement](https://governance.aave.com/t/technical-maintenance-proposals/15274/69),
  [Aave Guardians](https://docs.aave.com/governance/master/aave-guardians),
  [Guardian renewal 2024](https://governance.aave.com/t/arfc-renewal-of-aave-guardian-2024/17523)
- Arbitrum: [Security Council](https://docs.arbitrum.foundation/concepts/security-council),
  [AIP-6 elections](https://forum.arbitrum.foundation/t/aip-6-security-council-elections/15425),
  [elections guide](https://code4rena.com/blog/the-security-council-elections-within-the-arbitrum-dao-a-comprehensive-guide),
  [Security Council improvement proposal analysis](https://forum.arbitrum.foundation/t/aip-security-council-improvement-proposal-security-analysis/24755),
  [L2 timelock delay review](https://forum.arbitrum.foundation/t/arbitrum-l2-time-lock-delay-proposal-security-review/26837),
  [emergency action 2025-10-13](https://forum.arbitrum.foundation/t/security-council-emergency-action-10-13-2025/30093),
  [emergency action 2026-05-24](https://forum.arbitrum.foundation/t/security-council-emergency-action-24-05-2026/30910),
  [L2BEAT: security councils in practice](https://l2beat.com/publications/security-councils-in-practice),
  [L2BEAT monthly update 2026-07](https://l2beat.com/publications/monthly-update-2026-07)
- Optimism: [governance facts (2026)](https://optimism.io/blog/optimism-governance-sequencer-enterprise-facts),
  [transitioning to onchain voting](https://gov.optimism.io/t/transitioning-to-on-chain-voting/4193?page=2),
  [governance FAQ](https://docs.optimism.io/governance/gov-faq),
  [Security Council charter v0.1](https://gov.optimism.io/t/security-council-charter-v0-1/6884)
- Safe: [cross-chain smart account challenges](https://safefoundation.org/blog/the-challenges-in-offering-cross-chain-smart-accounts),
  [Unified Safe owner management grant](https://gov.optimism.io/t/unified-safe-owner-management-across-superchain/10430),
  [Safe Foundation forum](https://forum.safefoundation.org/)
