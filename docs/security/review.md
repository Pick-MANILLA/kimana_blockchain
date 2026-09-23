# Internal security review: SettlementVault (quote locking release)

Scope: `src/SettlementVault.sol`, `src/interfaces/ISettlementVault.sol`, `src/libraries/*`.
This is an internal review. It does **not** replace the external audit required before mainnet.

> The full threat model and the audit-readiness checklist now live in [`threat-model.md`](threat-model.md)
> (issue #14). This page remains the record of the Slither run and the nine findings from the quote-locking
> review; start with the threat model.

## Static analysis (Slither 0.11.6)

Command: `make slither` (config: `slither.config.json`, excludes `lib/`, `test/`, `script/`).

CI runs Slither on every push and pull request. `script/slither-gate.sh` fails the build on any Medium or High
finding that is not accepted in the table below. The gate reads this table, so keep its format: the detector name
in backticks in the first column, the affected functions in backticks in the second, and an assessment that starts
with **Accepted.** A finding matches on detector and function, not on line numbers.

| Finding | Location | Assessment |
|---|---|---|
| `timestamp`: comparisons with `block.timestamp` | `lockQuote`, `settle`, `_checkDivergence` | **Accepted.** Quote windows are 90 s to 15 min and reference ages are about 1 hour. A few seconds of sequencer or validator skew cannot change the outcome in a way that matters. |
| `incorrect-equality`: `r.updatedAt == 0` | `_checkDivergence` | **Accepted.** `0` is the "never set" sentinel; `setReferenceRate` always writes `block.timestamp > 0`. |
| `cyclomatic-complexity` (13) | `lockQuote` | **Accepted.** The function is a linear list of input checks, and every branch has a dedicated test (100% branch coverage). |

No other findings.

## Manual review checklist

| Area | Result |
|---|---|
| **Access control** | Every state-changing function is role-gated: operator (`lockQuote`, `cancelQuote`, `settle`, `refund`), rate oracle (`setReferenceRate`), admin (`setPartner`, `setLimits`, `setQuoteConfig`, `setRequireFunding`, `sweep`, `unpause`), pauser (`pause`). The two exceptions are `returnSettlement`, which only the settlement's own partner can call, and `fund`, which only an allowlisted on-ramp partner can call. Admin transfer is two-step with a delay. |
| **Reentrancy** | Functions that move funds are `nonReentrant` and follow checks-effects-interactions. `lockQuote` and `cancelQuote` make no external calls. |
| **Duplicate money movement** | A `ref` can be settled once; a `quoteId` can be locked once. Invariant tests cover this. |
| **Arithmetic** | Solidity 0.8 checked maths. `FxMath.receiveAmount` cannot overflow for realistic values: amount < 2^64, rate < 2^64, 10^18 gives about 2^188. Rounds down, and the backend uses the same rule. |
| **Oracle manipulation** | The reference rate only gates the lock (alert or block). It never sets amounts. A compromised oracle can at worst block quotes (denial of service) or hide divergence alerts. Mitigations: separate key, `ReferenceRateStale` alerting, admin can revoke the role. |
| **Compromised operator** | Can lock and settle only to allowlisted partners, within per-settlement and daily limits, and only with self-consistent quotes. Mitigations: pause, role revocation, custody-provider policy engine. |
| **Denial of service** | A stale oracle does not block payments (alert only). A divergence above the maximum blocks only that quote. |
| **Pausing** | `lockQuote`, `settle` and `refund` stop when paused. `returnSettlement` still works, because it only reduces risk. `cancelQuote` still works, because it only restricts. |

## Findings from the internal review, and what was done

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The operator could skip the divergence check by using an unregistered currency code, and could choose the decimals for the counterparty-amount check. | **Fixed.** Admin currency registry (`setCurrency`); decimals come only from the registry; unknown or disabled codes revert. |
| 2 | Medium | A lock blocked for divergence reverts, so it leaves no event to alert on. | **Fixed.** The monitor scans reverted vault transactions, decodes the custom error and raises a critical alert (tested in `make e2e`). |
| 3 | Low | A huge `maxQuoteTtl` could overflow and block every lock. | **Fixed.** Config bounds: TTL ≤ 1 day, reference age ≤ 7 days, settle delay ≤ 30 days. |
| 4 | Low | Rounding the deviation down under-reported thresholds (5.0099% counted as 500 bps). | **Fixed.** Deviation is rounded up. |
| 5 | Low | An oversized rate caused a bare arithmetic panic. | **Fixed.** `FxMath.MAX_RATE` bound, reverting with a named error. |
| 6 | Low | Zero counterparty amounts and absurd fees were accepted. | **Fixed.** Zero amounts are rejected; `feeUsdc` is bounded by `maxPerSettlement`. |
| 7 | Info | `QuoteLocked` does not include decimals. | **Accepted.** Decimals come from `CurrencyUpdated` / `getCurrency`. |
| 8 | Info | A cancelled `ref` can never be reused. | **Intended**, and now documented. |
| 9 | Low | FX risk on locked quotes had no time limit. | **Fixed.** `maxSettleDelay` (default 7 days). |

## Open items (tracked as issues)

- External audit (#14)
- Fork tests against real USDC, including blocklisting (#3, #7)
- Partner-type restrictions (#8)
