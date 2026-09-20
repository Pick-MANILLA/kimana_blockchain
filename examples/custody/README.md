# Custody PoC — lockQuote → settle on Base Sepolia

This directory contains a proof-of-concept that exercises the `OPERATOR_ROLE` flow through
the **Dfns** custody API: lock a quote, then settle it, on a real testnet vault.

The scripts are reference implementations and annotated walkthroughs, not production-ready code.

## Files

| File | Purpose |
|---|---|
| `README.md` | This file |
| `dfns-poc.mjs` | End-to-end PoC: set reference rate, lock quote, settle — all via Dfns |
| `dfns-policy-approver.mjs` | Skeleton programmable approver that enforces function-level restrictions |
| `abi.json` | Minimal ABI fragment for `lockQuote`, `settle`, `setReferenceRate` |
| `.env.example` | Required environment variables (no private keys) |

## Prerequisites

- Node.js 20+
- A Dfns sandbox account (free 30-day trial, no credit card — <https://app.dfns.io>)
- A deployed `SettlementVault` on Base Sepolia (see [`docs/runbooks/deploy.md`](../../docs/runbooks/deploy.md))
- Two Dfns wallets:
  - `OPERATOR_WALLET_ID` — holds `OPERATOR_ROLE` on the vault
  - `ORACLE_WALLET_ID` — holds `RATE_ORACLE_ROLE` on the vault
- Testnet ETH in the operator wallet (Base Sepolia faucet: <https://faucet.quicknode.com/base/sepolia>)
- The off-ramp partner address added to the vault's allowlist by the admin

## Setup

```bash
cp .env.example .env
# Fill in the values — no private keys; Dfns signs everything
npm install
```

## Running the PoC

```bash
node dfns-poc.mjs
```

Expected output:

```
[1/4] Oracle sets reference rate for NGN…
      tx: 0x<hash>  status: Confirmed
[2/4] Operator locks quote for ref 0x<ref>…
      tx: 0x<hash>  status: Confirmed
      QuoteLocked event: rate=164525000000 usdcAmount=100000000 receiveAmountMinor=164525
[3/4] Operator settles ref 0x<ref>…
      tx: 0x<hash>  status: Confirmed
      SettlementInitiated event: partner=0x<partner> amount=100000000
[4/4] Verifying settlement state on-chain…
      settlement.status = Settled ✓
Done.
```

## Running the policy approver (optional)

The approver runs as a background service next to the Dfns API. It intercepts every pending
signing request for the operator and oracle wallets, decodes the calldata, and approves only
the four allowed functions (`lockQuote`, `cancelQuote`, `settle`, `refund` for the operator;
`setReferenceRate` for the oracle).

```bash
node dfns-policy-approver.mjs
```

See inline comments in `dfns-policy-approver.mjs` for how to register the service account and
configure the policy to use `RequestApproval` instead of `AutoApproval`.

## Why Dfns?

See [`docs/custody-comparison.md`](../../docs/custody-comparison.md) for the full comparison
against Fireblocks and Cobo. The short version: Dfns is the only provider with a free sandbox
that works on all eight Kimana testnets immediately, with no Sales contact required.

## Security notes

- **No private keys** appear anywhere in this directory. All signing happens inside Dfns's MPC
  network. The only secrets are the `DFNS_APP_PRIVATE_KEY` (a short-lived credential key used
  to authenticate the service account with Dfns, not a blockchain key) and `DFNS_AUTH_TOKEN`.
- The `DFNS_APP_PRIVATE_KEY` should be stored in a secrets manager (AWS Secrets Manager,
  HashiCorp Vault, etc.) in production, not in `.env`.
- The PoC uses `requireFunding: false` (the vault default). In production the on-ramp partner
  calls `fund(ref, amount)` before `settle` is called.
