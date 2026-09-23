# ADR 0001 — Settlement network

- **Status:** **Accepted** — Base
- **Date:** 2026-09-19, accepted 2026-09-23
- **Decides:** issue #1
- **Deciders:** product lead, engineering lead, blockchain

## 1. Decision

> **Settle on Base.** Base Sepolia (84532) for the testnet deployment (#12), Base mainnet (8453) after the
> external audit (#14) and the regulatory and partner approvals the PRD requires.

One chain. Not "Base first, then others" as a roadmap item — a second chain is a business decision with a
cost, taken only when a partner we want forces it (§6).

## 2. Context

`SettlementVault` is chain-agnostic: it works on any EVM chain with **native, 6-decimal USDC**. Base,
Arbitrum, Polygon and Ethereum are configured in `foundry.toml`, each with a testnet. That list is a *menu of
what the contract supports*, not a deployment plan.

Each additional chain needs its own USDC float, Safe, partner allowlist, operator key in custody, monitor
instance and deployment review. Nothing in this repo moves value between chains, and adding a bridge is
explicitly out of scope: bridges are the largest single category of loss in crypto, and the problem they
solve is one we can avoid by settling where the money already is.

Already decided elsewhere and not reopened here:

- **EVM**, confirmed with the team. The PRD's Stellar assumption was superseded.
- **Native USDC only**, recorded in [`../networks.md`](../networks.md). BNB Chain is excluded because its
  bridged USDC has 18 decimals and the constructor refuses it.

## 3. Why Base

| | Base | Arbitrum | Polygon | Ethereum |
|---|---|---|---|---|
| Native 6-decimal USDC | yes | yes | yes | yes |
| Fees per transfer (2 tx: `lockQuote` + `settle`) | lowest | low | lowest | **high — can exceed the fee on an SME payment** |
| Finality / reorg exposure | L2, single sequencer | L2, single sequencer | sidechain-style, faster reorg risk | strongest |
| Confirmations to use | 5+ | 5+ | 10+ | 5+ |
| African off-ramp support | good and growing | thinner | good, common with African PSPs | universal but rarely used for payouts |
| Sequencer outage risk | yes | yes | n/a | n/a |

Base wins on the two things that decide it: **lowest fees of the four**, which matters because every
transfer costs two transactions against a fee charged on a few thousand dollars, and **native USDC issued by
Circle** rather than a bridged representation. It is also already the repo's configured default, so
`preflight`, `verify`, the monitor and the runbooks need no changes.

**Ethereum mainnet is ruled out** on economics alone: two transactions at mainnet gas does not survive
contact with the P&L. **Polygon** was the main alternative and would have won had the off-ramp partner
supported it and not Base.

Base runs the Cancun opcodes, so the default `evm_version = "cancun"` build is correct here.
`make preflight` proves this against the live RPC before any gas is spent (#25).

## 4. What this decision rests on, and what would reopen it

The chain must sit where our counterparties can actually transact. Base was accepted on the **backend team's
confirmation that it supports USDC on Base**, plus the economics above.

**Still outstanding, and it is not blocking this decision:** the NGN off-ramp partner has not confirmed in
writing which networks they accept USDC on for payouts. If that answer comes back excluding Base, it
overrides everything in §3 and this ADR is reopened — the correct response is to **change chain or change
partner, never to add a bridge**.

The same message to the partner still decides two things that are *not* settled here:

> Which blockchain networks can you receive USDC on for NGN payouts, and is it **native** USDC on each (not a
> bridged version)? Do you require pre-funding of a float with you, or do you pay out per transaction after we
> settle? What are your minimum and maximum per-transaction amounts, and how many confirmations do you wait for?

- **#2 / `requireFunding`** — a pre-funded float means the on-ramp cannot fund per transfer, so
  `requireFunding` stays **off**. Per-transaction delivery means it should be turned **on**. It defaults to
  off and is an admin call, so this can be answered after deployment.
- **#8** — whether off-ramp partners need a per-currency payout restriction in practice. The contract
  supports it either way; it is a `setPartner` argument.

## 5. Consequences

- one float, one Safe, one operator key, one monitor — the smallest operable surface;
- a transfer that starts on Base settles on Base, always;
- confirmations: 2 on testnet, **5 or more** on mainnet (`CONFIRMATIONS` in the monitor);
- Base is an L2 with a single sequencer. A sequencer outage stops settlement until it resumes. This is
  accepted: the alternative chains carry the same or worse risk, and the incident runbook covers it;
- a second chain later costs about a day of engineering (`make preflight NETWORK=x` → deploy → `make
  verify`) and considerably more in float, custody, monitoring and audit.

## 6. Revisit when

- the off-ramp partner's written answer excludes Base (§4);
- a partner we want requires a chain we are not on;
- Base fees or sequencer outages start showing up in customer complaints;
- volume justifies redundancy across two chains.

## 7. Sign-off

| Role | Name | Date |
|---|---|---|
| Product lead | | |
| Engineering lead | | |
| Blockchain | | |
