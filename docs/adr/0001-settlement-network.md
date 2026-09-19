# ADR 0001 — Settlement network

- **Status:** Proposed — *awaiting the off-ramp partner's answer (§3) and sign-off (§7)*
- **Date:** 2026-09-19
- **Decides:** issue #1
- **Deciders:** product lead, engineering lead, blockchain

## 1. Context

`SettlementVault` is chain-agnostic: it works on any EVM chain with **native, 6-decimal USDC**. Base,
Arbitrum, Polygon and Ethereum are configured in `foundry.toml`, each with a testnet. That list is a *menu of
what the contract supports*, not a deployment plan.

We deploy to **one** chain. Each additional chain needs its own USDC float, Safe, partner allowlist, operator
key in custody, monitor instance and deployment review. Nothing in this repo moves value between chains, and
adding a bridge is explicitly out of scope: bridges are the largest single category of loss in crypto, and the
problem they solve is one we can avoid by settling where the money already is.

Already decided elsewhere and not reopened here:

- **EVM**, confirmed with the team. The PRD's Stellar assumption was superseded.
- **Native USDC only**, recorded in [`../networks.md`](../networks.md). BNB Chain is excluded because its
  bridged USDC has 18 decimals and the constructor refuses it.

## 2. The decision is made by the partners, not by us

The vault must sit where our counterparties can actually transact. In priority order:

1. **Which networks does the NGN off-ramp partner accept USDC on, for payouts?** This dominates everything
   else. A chain the partner cannot receive on is unusable however good its fees are.
2. **Which networks can the on-ramp partner deliver USDC on?** Usually more flexible.
3. **Which networks does the custody provider support** for the operator and oracle keys (#11)?
4. Only then: fees, finality, liquidity.

If (1) and (2) have no chain in common, the correct response is to **change a partner**, not to add a bridge.

## 3. Open question blocking this ADR

Sent to the off-ramp partner on `____________`:

> Which blockchain networks can you receive USDC on for NGN payouts, and is it **native** USDC on each (not a
> bridged version)? Do you require pre-funding of a float with you, or do you pay out per transaction after we
> settle? What are your minimum and maximum per-transaction amounts, and how many confirmations do you wait for?

Answer: `____________`

That answer also settles two other things, so record it here and link back from those issues:

- **#8** — whether off-ramp partners need a per-currency restriction in practice (the contract supports it).
- **#2 / `requireFunding`** — pre-funded float means the on-ramp cannot fund per transfer, so `requireFunding`
  must stay **off**. Per-transaction delivery means it should be turned **on**.

## 4. Options

| | Base | Arbitrum | Polygon | Ethereum |
|---|---|---|---|---|
| Native 6-decimal USDC | yes | yes | yes | yes |
| Fees per transfer (2 tx: `lockQuote` + `settle`) | lowest | low | lowest | **high — can exceed the fee on an SME payment** |
| Finality / reorg exposure | L2, single sequencer | L2, single sequencer | sidechain-style, faster reorg risk | strongest |
| Confirmations to use | 5+ | 5+ | 10+ | 5+ |
| African off-ramp support | good and growing | thinner | good, common with African PSPs | universal but rarely used for payouts |
| Sequencer outage risk | yes | yes | n/a | n/a |

**Ethereum mainnet is ruled out for the pilot** on economics alone: two transactions at mainnet gas against a
fee charged on a few thousand dollars does not survive contact with the P&L. It stays a candidate only if a
partner insists.

## 5. Proposed decision

> **Deploy to `__________` mainnet, after Base Sepolia (#12) and the external audit (#14).**

**Recommendation pending the §3 answer: Base.** Lowest fees of the four, native USDC, growing support among
African payment providers, and it is already the repo's configured default so `preflight`, `verify`, the
monitor and the runbooks need no changes.

**Switch to Polygon** if the off-ramp partner supports Polygon but not Base — that single fact outweighs
everything in the table above.

Consequences of choosing one chain:

- one float, one Safe, one operator key, one monitor — the smallest operable surface;
- a transfer that starts on this chain settles on this chain, always;
- a second chain later is a **business decision with a cost**, not a config flag. The engineering is about a
  day (`make preflight NETWORK=x` → deploy → `make verify`); the float, custody, monitoring and audit are not.

## 6. Revisit when

- a partner we want requires a chain we are not on;
- fees or outages on the chosen chain start showing up in customer complaints;
- volume justifies redundancy across two chains.

## 7. Sign-off

| Role | Name | Date |
|---|---|---|
| Product lead | | |
| Engineering lead | | |
| Blockchain | | |

Once signed: mark this ADR **Accepted**, set the chosen mainnet in [`../networks.md`](../networks.md), and
close #1 with a link to this file.
