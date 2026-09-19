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
| Admin | Safe multisig | Manage the partner allowlist and types, set limits, require funding, sweep free funds, unpause, rotate roles |
| Operator | Custody-provider MPC wallet driven by the backend | `lockQuote`, `cancelQuote`, `settle`, `refund` |
| Rate oracle | Independent rate publisher (separate key/service from the quoting provider) | `setReferenceRate` |
| Pauser | Emergency key(s), e.g. an on-call engineer's hardware wallet | `pause` |
| Partner | Licensed on-ramp or off-ramp wallet (allowlisted, typed) | On-ramp: `fund(ref, amount)` and receive refunds. Off-ramp: receive settlements for its payout currency and `returnSettlement` for its own settlements |

## 3. Transfer lifecycle mapping

The backend transfer state machine lives in `Kimana_backend/src/domain/transfers/state_machine.rs`.

| Backend status | On-chain action | Event the backend waits for |
|---|---|---|
| `QUOTED` (customer confirms) | Operator calls `lockQuote(ref, quote)` | `QuoteLocked(ref, quoteId, ...)`, plus `RateDivergence` / `ReferenceRateStale` alerts if raised |
| `AWAITING_FUNDS` | On-ramp partner calls `fund(ref, usdcAmount + feeUsdc)`, or sends a plain ERC-20 transfer into a shared float | `SettlementFunded(ref, partner, amount, feeUsdc)`, or a bare ERC-20 `Transfer(onRamp → vault)` |
| `FUNDED` | none | none |
| `SETTLING` | Operator calls `settle(ref, ngnPartner, amount)`; `amount` must equal the locked quote's `usdcAmount` | `SettlementInitiated(ref, partner, amount)` |
| `SETTLED` | Event confirmed (N confirmations) | none |
| `PAYING_OUT` | Partner pays NGN off-chain | Partner webhook |
| `COMPLETED` | none | Partner webhook: payout succeeded |
| `REVERSING` | Partner calls `returnSettlement(ref)` | `SettlementReturned(ref, partner, amount)` |
| `REVERSED` | Operator calls `refund(ref, to)` | `SettlementRefunded(ref, to, amount)` |
| `EXPIRED` / `REJECTED` before settlement | Operator calls `cancelQuote(ref)` | `QuoteCancelled(ref, quoteId)` |

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
- The FX rate, fee and naira amount are fixed by the backend quote and **recorded** on-chain by `lockQuote` so the
  settlement can be audited against them. The off-ramp partner still pays the naira off-chain.

## 5a. Quote locking and FX rules

See [`fx-quote-criteria.md`](fx-quote-criteria.md) for how this maps to the FX quote acceptance criteria.

- **Rate format:** receive-currency major units per 1 USD, **8 decimals** (`1,645.25` → `164_525_000_000`).
- **Counterparty amount:** `receiveMinor = floor(usdcAmount × rate × 10^receiveDecimals / 10^14)`
  (`FxMath.receiveAmount`). The backend must compute it the same way; `lockQuote` rejects any other value, and
  rejects amounts that round to zero.
- **Currencies:** only codes registered by the admin with `setCurrency(code, decimals, enabled)` can be quoted.
  `decimals` always comes from this registry. Disabling a currency blocks new locks only.
- **Funding:** `fund(ref, amount)` requires `amount == usdcAmount + feeUsdc` of the locked quote, so a deposit
  is bound on-chain to the terms the customer accepted. It is **optional by default**: an on-ramp partner that
  delivers into a shared float rather than per transfer cannot satisfy it. Once the partner's delivery model
  is confirmed, admin calls `setRequireFunding(true)` and `settle` then refuses an unfunded `ref`.
- **Partner types:** a partner is an on-ramp, an off-ramp, or both. An off-ramp partner may carry a
  `payoutCurrency`, and `settle` refuses a quote in any other currency (`bytes3(0)` means "any"). `refund`
  only ever pays an on-ramp partner, because a refund sends money back towards where it came from.
- **Fee:** `feeUsdc` is recorded for audit. `usdcAmount` is the net amount settled to the partner, so the
  customer's send amount is `usdcAmount + feeUsdc`.
- **Expiry:** `lockQuote` requires `block.timestamp < expiresAt ≤ block.timestamp + maxQuoteTtl`.
- **Lock:** one lock per `ref`, one use per `quoteId` (even if cancelled; a cancelled `ref` cannot be re-locked).
  A locked quote is honoured at settlement after `expiresAt`, because the customer accepted it in time, but
  only for `maxSettleDelay` (default 7 days) after the lock.
- **Divergence:** the quoted rate is compared with the oracle's reference rate for the currency. Deviation is
  rounded **up** to whole basis points.
  - deviation ≥ `divergenceAlertBps` (default 1%): `RateDivergence` alert, lock still succeeds;
  - deviation > `divergenceMaxBps` (default 5%): lock reverts with `RateDivergenceTooHigh`;
  - no reference, or older than `referenceMaxAge` (default 1 hour): `ReferenceRateStale` alert, lock succeeds;
  - a blocked lock reverts and leaves no event, so the monitor also alerts on reverted vault transactions.
- The admin changes these values with `setQuoteConfig` (bounded: TTL ≤ 1 day, reference age ≤ 7 days,
  settle delay ≤ 30 days, alert ≤ max ≤ 100%).

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
| Compromised partner | Admin sets it to `(false, false, false, 0x000000)`, which stops it settling, funding and receiving refunds. |
| `lockQuote` reverts with `QuoteExpired` | Customer must request a new quote. Never retry with the same quote. |
| `lockQuote` reverts with `RateDivergenceTooHigh` | Quoting provider is off. Stop quoting that currency and page ops. |
| `RateDivergence` / `ReferenceRateStale` alert | Monitor pages ops; investigate the quoting provider or the oracle. |
| Transfer abandoned after lock | Operator calls `cancelQuote(ref)`. |
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
