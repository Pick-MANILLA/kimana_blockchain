# Settlement architecture

This document explains how the on-chain settlement layer fits into a Kimana transfer. It is the reference for
contract, backend and ops work.

## 1. Principles (from the PRD)

- **The backend ledger is authoritative.** The chain is one step in the transfer lifecycle, not the source of truth.
- **Buy regulated rails and build the workflow.** On- and off-ramps, custody and local liquidity come from licensed partners.
- **No customer private keys in code or environment variables.** Signing goes through an institutional MPC/HSM custody provider.
- **Multi-signature treasury controls.**
- **Money movements are idempotent.** There are no duplicate settlements.
- **Integer money only.** No floating point anywhere.
- **Blockchain is invisible to customers.**

## 2. Actors

| Actor | On-chain identity | Can do |
|---|---|---|
| Admin | Safe multisig | Manage the partner allowlist, set limits, sweep free funds, unpause, rotate roles |
| Operator | Custody-provider MPC wallet driven by the backend | `settle`, `refund` |
| Pauser | Emergency key(s), e.g. an on-call engineer's hardware wallet | `pause` |
| Partner | Licensed on-ramp or off-ramp wallet (allowlisted) | Receive settlements; `returnSettlement` for its own settlements |

## 3. Transfer lifecycle mapping

The backend transfer state machine lives in `Kimana_backend/src/domain/transfers/state_machine.rs`.

| Backend status | On-chain action | Event the backend waits for |
|---|---|---|
| `AWAITING_FUNDS` | On-ramp partner sends USDC to the vault | ERC-20 `Transfer(onRamp → vault)` *(tracking: see issues)* |
| `FUNDED` | none | none |
| `SETTLING` | Operator calls `settle(ref, ngnPartner, amount)` | `SettlementInitiated(ref, partner, amount)` |
| `SETTLED` | Event confirmed (N confirmations) | none |
| `PAYING_OUT` | Partner pays NGN off-chain | Partner webhook |
| `COMPLETED` | none | Partner webhook: payout succeeded |
| `REVERSING` | Partner calls `returnSettlement(ref)` | `SettlementReturned(ref, partner, amount)` |
| `REVERSED` | Operator calls `refund(ref, to)` | `SettlementRefunded(ref, to, amount)` |

On-chain status per `ref` is `None → Settled → Returned → Refunded`. A `ref` never returns to `None`, so it
can never be settled twice, even after a refund.

## 4. References

```
ref = keccak256(utf8("kimana:transfer:" + transferId))
```

- Solidity: `TransferRef.fromTransferId(transferId)`
- Rust (alloy): `keccak256(format!("kimana:transfer:{transfer_id}").as_bytes())`

The domain prefix keeps these hashes apart from other identifiers that might be hashed later.

## 5. Units and decimals

| Where | Unit | Example: $1,500.00 |
|---|---|---|
| Backend ledger | cents (2 dp) | `150_000` |
| USDC on-chain | base units (6 dp) | `1_500_000_000` |

- `usdc = cents × 10_000` (`UsdcUnits.fromCents`)
- `cents = usdc / 10_000`, which **reverts if there is a remainder** (`UsdcUnits.toCents`)
- The naira amount and the FX rate are **never** on-chain. The backend quote fixes them, and the off-ramp partner pays them.

## 6. Limits

- `maxPerSettlement`: cap on a single `settle`.
- `dailyLimit`: cap on the total settled per UTC day (`block.timestamp / 1 days`).
- A partner return does **not** restore the day's limit. This is deliberately conservative.
- Lowering limits takes effect immediately.

## 7. Failure handling

| Failure | Handling |
|---|---|
| `settle` tx reverts (limit, paused, underfunded) | Nothing moved. The backend keeps the transfer in `FUNDED` and alerts ops. |
| `settle` tx dropped or stuck | Retry with the **same `ref`**. The contract rejects a second success, so retries are safe. |
| NGN payout fails | Partner calls `returnSettlement(ref)`, then the operator calls `refund(ref, to)`. |
| Compromised operator key | Pauser pauses. Admin revokes `OPERATOR_ROLE` and grants a new wallet. The operator can only pay allowlisted partners, within limits. |
| Compromised partner | Admin removes it from the allowlist. |
| Chain reorg | The backend waits for N confirmations before moving a transfer to `SETTLED`. |

## 8. Known gaps and next steps

These are tracked as GitHub issues:

- deposit tracking (`fund(ref)`), so inbound USDC is tied to a transfer on-chain;
- rescuing tokens sent by mistake that are not USDC;
- handling USDC blocklisting (Circle can freeze addresses);
- Slither and CI hardening; coverage gates;
- backend indexer and signer (Rust/alloy plus the custody API);
- Safe multisig and testnet deployment runbook;
- the final chain decision (EVM vs Stellar) and, if needed, a Soroban version.
