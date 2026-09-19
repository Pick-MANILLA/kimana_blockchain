# FX quote: acceptance criteria and Definition of Done

Source: the Kimana PRD ("User Acceptance Criteria & Definition of Done: FX Quote").

The FX quote is a cross-team feature. The **frontend** shows it, the **backend** produces it, and this repo, the
**settlement layer**, enforces the parts that decide whether money may move. This page records what the
settlement layer guarantees, how it is tested, and what other teams must still deliver.

Legend: ✅ enforced and tested here · 🔗 depends on another team · — not applicable on-chain

## Acceptance criteria

| # | Criterion | Settlement layer | How it is enforced | Tests | Other teams |
|---|---|---|---|---|---|
| 1 | User can enter transaction amount and currencies | — | Not an on-chain concern | – | 🔗 Frontend form, backend `POST /quotes` |
| 2 | System retrieves current rates | ✅ (reference side) | Rate oracle publishes an independent reference rate per currency with `setReferenceRate`; its age is tracked. `oracle/` implements the publisher: integer-only scaling, republish on staleness or a 0.5% move, and a jump guard that refuses an implausible rate rather than poisoning the reference | `test_setReferenceRate_*`, `oracle/test.mjs` | 🔗 Backend fetches the customer-facing rate from the quoting provider(s), which **must be a different source** |
| 3 | System displays exchange rate | ✅ (record) | The accepted rate is stored in the locked quote and emitted in `QuoteLocked` | `test_lock_recordsRateFeeAndCounterpartyAmount` | 🔗 Frontend displays it |
| 4 | System displays all applicable fees | ✅ (record) | `feeUsdc` is stored and emitted, so every settlement can be audited against the disclosed fee | `test_lock_recordsRateFeeAndCounterpartyAmount` | 🔗 Backend computes fees/spread; frontend displays them |
| 5 | System displays counterparty amount | ✅ | `lockQuote` rejects a quote whose `receiveAmountMinor` is not exactly `floor(usdcAmount × rate × 10^dec / 10^14)`, or rounds to zero. `dec` comes from the admin currency registry (`setCurrency`), never from the caller. Integer-only maths (NGN 2, XOF 0) | `test_counterpartyAmount_knownValue`, `test_receiveAmount_independentVectors`, `test_lock_rejectsWrongCounterpartyAmount`, `test_wrongDecimals_rejected`, `test_zeroDecimalCurrency` | 🔗 Backend must use the same formula; frontend displays it |
| 6 | Quote has an expiry time | ✅ | Every lock carries `expiresAt`; lifetimes longer than `maxQuoteTtl` (default 15 min) are rejected | `test_lock_rejectsTtlLongerThanConfigured`, `testFuzz_lockThenSettle` | 🔗 Frontend shows a countdown |
| 7 | Expired quotes cannot be accepted | ✅ | `lockQuote` reverts with `QuoteExpired` when `now ≥ expiresAt`; `settle` reverts with `QuoteNotLocked` if no quote was locked | `test_lock_rejectsExpiredQuote`, `test_lock_acceptsOneSecondBeforeExpiry`, `test_settle_requiresLockedQuote` | 🔗 Backend already rejects expired quotes at transfer creation |
| 8 | Accepted quotes are locked within their validity period | ✅ | One lock per transfer (`QuoteAlreadyLocked`), one use per quote id (`QuoteAlreadyUsed`), settlement must equal the locked amount (`SettleAmountMismatch`), locked terms honoured after expiry for up to `maxSettleDelay` (default 7 days, `QuoteLockTooOld` after that), `cancelQuote` for abandoned transfers | `test_lockedQuote_*`, `test_quoteId_isSingleUse`, `test_settle_mustMatchLockedAmount`, `test_cancelQuote_*`, invariant `invariant_perRefStateConsistent` | 🔗 Backend should also mark quotes as consumed in its database |
| 9 | Provider divergence triggers an internal alert | ✅ | Deviation (rounded **up**) ≥ 1% emits `RateDivergence`; > 5% blocks the lock; stale reference emits `ReferenceRateStale`. Only registered currencies can be quoted, so the check cannot be skipped with an unknown code. `monitor/` alerts on these events **and** on reverted vault transactions, so blocked quotes (`RateDivergenceTooHigh`) raise a critical alert | `test_divergence_*`, `testFuzz_divergence_behaviour`, `test_staleReference_emitsAlertButLocks`, `test_referenceAgeExactlyMax_isFresh`, `test_unknownCurrency_cannotBypassDivergence`, `script/e2e-local.sh` | 🔗 Ops routes the webhook to Slack/PagerDuty |

## Definition of Done

| Item | Settlement layer status | Evidence |
|---|---|---|
| Functional tests passed | ✅ | `forge test`: 132 unit/fuzz/invariant tests, 100% line and branch coverage of `src/` |
| Integration tests passed | ✅ (on-chain + monitor) | `make e2e`: Anvil deployment, lock → settle → return → refund, divergence alert, blocked quote (reverted tx alert), pause/unpause, monitor assertions (runs in CI) |
| Failure scenarios tested | ✅ | Expired, reused, re-locked, cancelled, mismatched amount, wrong decimals, unknown/disabled currency, zero counterparty amount, oversized rate/fee, divergence above max, stale/missing reference, lock too old, lowered limits, paused, unauthorised callers, invalid config |
| Security review completed | 🟡 Internal review + threat model done | [`security/review.md`](security/review.md) and [`security/threat-model.md`](security/threat-model.md). An **external audit** is still required before mainnet |
| Audit events implemented | ✅ | `QuoteLocked`, `QuoteCancelled`, `CurrencyUpdated`, `ReferenceRateUpdated`, `QuoteConfigUpdated`, `RateDivergence`, `ReferenceRateStale`, plus the settlement events |
| Monitoring implemented | ✅ | `monitor/index.mjs`: event stream, alert levels, reverted-transaction alerts with decoded error, webhook, low-float check, resumable state |
| Product/design approval completed | 🔗 | Needs a product/design sign-off on the quote screen (not in this repo) |
| Compliance requirements satisfied | 🔗 | Compliance must approve fee/spread disclosure and the divergence thresholds |

## What the backend must do to use this

1. Admin registers each receive currency once with `setCurrency(code, decimals, true)` (e.g. `NGN`, 2).
2. When the customer confirms a quote, call `lockQuote(ref, quote)` **before** `expiresAt`, with:
   - `quoteId = keccak256(backend quote UUID)`,
   - `rate` with 8 decimals,
   - `usdcAmount = net cents × 10_000`,
   - `feeUsdc = fee cents × 10_000`,
   - `receiveAmountMinor` from the shared formula.
3. Only call `settle(ref, partner, usdcAmount)` after `QuoteLocked` is confirmed, with the same `usdcAmount`,
   and within `maxSettleDelay` of the lock.
4. Call `cancelQuote(ref)` when a locked transfer expires or is rejected before settlement. The `ref` cannot be
   reused afterwards; a re-quoted transfer needs a new transfer id.
5. Run the rate oracle as a **separate** service/key from the quoting provider, publishing at least every
   `referenceMaxAge`. `oracle/` does this; point it at a different FX source than the one you quote from.
6. If the on-ramp partner delivers USDC per transfer, have them call `fund(ref, usdcAmount + feeUsdc)` before
   `settle`, and ask admin to turn on `setRequireFunding(true)`. The deposit is then provably tied to the quote.
