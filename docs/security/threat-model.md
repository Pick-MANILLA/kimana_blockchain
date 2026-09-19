# Threat model and audit readiness

Issue #14. Builds on [`review.md`](review.md), which records the internal review of the quote-locking release
(Slither output, a manual checklist and nine findings with resolutions). This document is what an external
auditor should read first.

**Scope:** `src/` only — `SettlementVault.sol` and the three libraries. The backend ledger, the partner APIs,
the custody provider and the frontend are out of scope here and each need their own review.

---

## 1. What is actually at risk

| Asset | Where it lives | Worst case |
|---|---|---|
| **USDC float** | the vault's token balance | Drained to an attacker-controlled address. Capped per settlement and per UTC day, so a compromise bleeds rather than empties. |
| **Reserved refunds** | `reservedForRefunds` | Money a partner already sent back, owed to a customer. `sweep` cannot touch it; only `refund` can move it, and only to an on-ramp partner. |
| **Quote integrity** | `_quotes`, `_quoteUsed` | A customer is settled at a rate they never agreed to, or the same transfer pays twice. This is the reason the contract exists, not a side concern. |
| **Reference rates** | `_referenceRates` | A poisoned reference either hides a bad quote (too permissive) or blocks every honest quote (denial of service). |
| **Audit trail** | events | If events lie or are missing, reconciliation against the backend ledger silently fails. |

The float is the obvious target. **Quote integrity is the subtle one** and is where a clever attacker would go:
stealing $50k is loud, settling a thousand transfers at a 3% worse rate is quiet.

---

## 2. Actors, and what happens if each is compromised

### 2.1 Admin — `DEFAULT_ADMIN_ROLE`, a Safe multisig

**Can:** allowlist partners, set limits and quote config, register currencies, `sweep` free balance, unpause,
grant and revoke every other role, transfer admin (two-step, `adminTransferDelay`).

**If compromised:** total loss, but not instant. The attacker must allowlist their own address and then either
sweep (free balance only) or settle through a fake partner (capped per settlement and per day). Every one of
those steps emits an event the monitor flags as a warning.

**Mitigations:** a real Safe with hardware-wallet signers and a threshold above 1; the two-step admin transfer
with a delay, so a stolen admin cannot be made permanent silently; `sweep` cannot touch `reservedForRefunds`;
`PartnerUpdated`, `LimitsUpdated`, `RoleGranted` are all alerted.

**Residual risk:** an admin that sets a huge `maxPerSettlement` and settles through its own partner drains the
float in one transaction. Accepted: whoever holds the admin can always eventually take the funds. The controls
buy detection time, not prevention. **Signer separation is the real control here, and it lives outside this repo.**

### 2.2 Operator — `OPERATOR_ROLE`, the custody provider's MPC wallet

**Can:** `lockQuote`, `cancelQuote`, `settle`, `refund`.

**If compromised:** the attacker cannot invent a destination — money still only moves to an **allowlisted
off-ramp partner that pays the quoted currency** (`settle`) or an **allowlisted on-ramp partner** (`refund`).
So the damage is bounded by who is allowlisted. What they *can* do is settle real transfers to the wrong
partner, lock quotes at bad rates within the 5% divergence band, or cancel quotes to deny service.

**Mitigations:** limits; the divergence band; `maxSettleDelay` caps how long a stale lock stays usable;
allowlists; pause.

**Residual risk:** a compromised operator plus a compromised partner address is a drain up to the daily limit.
This is the single strongest argument for keeping the daily limit tight and the partner list short.

### 2.3 Pauser — `PAUSER_ROLE`

**Can:** `pause` only. Cannot unpause (that needs the admin).

**If compromised:** denial of service. Payments stop until the Safe unpauses.

**Mitigations:** deliberately asymmetric — a low-privilege key can stop the world but cannot restart it, so it
can be held somewhere convenient (an on-call laptop, an automation) without being a theft risk. `Paused` is a
critical alert.

### 2.4 Rate oracle — `RATE_ORACLE_ROLE`

**Can:** `setReferenceRate` for enabled currencies.

**If compromised or wrong:**

- **Rate set far from truth** → the divergence check inverts. Honest quotes now look divergent and are
  **blocked** (`RateDivergenceTooHigh`), so payments stop. A denial of service, visible immediately.
- **Rate set to match a malicious quote** → the check passes and a bad rate settles. This needs the operator
  *and* the oracle, which is exactly why they must be different keys from different systems.
- **Oracle goes offline** → references go stale. `ReferenceRateStale` fires on every lock and **locks still
  succeed**. This is a deliberate choice: a dead oracle should not stop payments. It does mean divergence is
  unchecked while it lasts, so a stale-rate alert is an incident, not noise.

**Mitigations:** separate key and separate data source from the quoting provider (`oracle/`, #15); the service
refuses to publish a move larger than `MAX_JUMP_BPS` (default 10%) and alerts instead; `setReferenceRate`
rejects `0` and anything above `FxMath.MAX_RATE`; both divergence thresholds are admin-settable.

**Residual risk:** slow poisoning — an attacker who moves the reference 9% a day walks it anywhere in a week
without tripping the jump guard. Detection is the answer, not the contract: the monitor should chart published
rates against an independent third source. **Not yet implemented; worth an issue.**

### 2.5 Partners

**Can:** `fund` (on-ramp), `returnSettlement` for their own settlements (off-ramp), receive settlements and
refunds.

**If compromised:** an attacker who controls a partner address receives settlements meant for that partner.
They cannot take anything not already destined for them. `returnSettlement` only ever moves money *into* the
vault, so it is harmless and is deliberately allowed while paused.

**Mitigations:** the allowlist; `NotSettlementPartner` binds returns to the exact settling partner; per-currency
restriction on off-ramp partners.

---

## 3. Trust assumptions

These are things the contract cannot defend against and does not try to. An auditor should confirm they are
acceptable to the business, not look for code fixes.

| We trust | Why we have to | What breaks if the trust fails |
|---|---|---|
| **Circle (USDC issuer)** | They can blocklist any address, including the vault's, and can pause the token entirely. | A blocklisted **counterparty** is routable around: `settle` and `refund` both take the destination as a parameter, and [`test/Blocklist.t.sol`](../../test/Blocklist.t.sol) proves the failing transaction reverts atomically with vault state untouched. A blocklisted **vault** is unrecoverable on-chain — not even admin `sweep` works. Recovery requires Circle. |
| **Off-ramp partners** | They receive USDC and pay fiat off-chain. Nothing on-chain proves they did. | Money leaves and no naira arrives. Mitigated commercially (contracts, float limits, reconciliation), not in code. `returnSettlement` exists for the honest-failure case. |
| **On-ramp partners** | They convert USD and deliver USDC. | With `fund`, a deposit is at least bound on-chain to a locked quote. Without it (`requireFunding` off), the backend ledger is the only record. |
| **Custody provider** | Holds the operator key. | See 2.2. Their own security review is a separate exercise (#11). |
| **Quoting provider ≠ oracle source** | The divergence check is meaningless if both read the same API. | The check silently passes on everything. **This must be verified at integration time, not assumed.** |
| **RPC providers** | The backend and monitor see the chain through them. | A lying RPC shows false confirmations. Mitigated by using more than one provider for the monitor and by confirmation counts. |

---

## 4. Mitigations already in the contract

| Control | Where | Stops |
|---|---|---|
| One settlement per `ref` | `RefAlreadyUsed` | Double payment of the same transfer. |
| One lock per `ref`, one use per `quoteId` | `QuoteAlreadyLocked`, `QuoteAlreadyUsed` | Re-quoting at a better rate after the fact; replaying a quote. |
| Exact counterparty amount | `ReceiveAmountMismatch` | Settling at a rate different from the one the customer saw. |
| `settle` amount must equal the locked amount | `SettleAmountMismatch` | Quietly paying more than quoted. |
| Quote expiry + `maxQuoteTtl` | `QuoteExpired`, `QuoteTtlTooLong` | Stale rates; absurdly long locks. |
| `maxSettleDelay` | `QuoteLockTooOld` | A months-old lock settling at a dead rate. |
| Divergence band | `RateDivergence` (≥1%), `RateDivergenceTooHigh` (>5%) | A quoting provider that is broken or captured. |
| Currency registry | `CurrencyNotSupported` | Bypassing the divergence check with an unregistered code; caller-supplied decimals. |
| Partner allowlist with types | `PartnerNotAllowed`, `PartnerCurrencyMismatch` | Money leaving to an arbitrary address; an NGN payout going to a partner who only pays cedi. |
| Per-settlement and per-day limits | `ExceedsPerSettlementLimit`, `ExceedsDailyLimit` | Turning a key compromise into total loss in one transaction. |
| `reservedForRefunds` excluded from `sweep` | `InsufficientFreeBalance` | Treasury operations eating money owed to a customer. |
| Pause | `Pausable` | Buying time during an incident. |
| Two-step admin transfer with delay | `AccessControlDefaultAdminRules` | A stolen admin becoming permanent before anyone notices. |
| 6-decimal asset check in the constructor | `UnsupportedAssetDecimals` | Deploying against 18-decimal bridged USDC, where every amount would be off by 10¹². |
| Integer-only maths | `FxMath`, `UsdcUnits` | Rounding drift between the chain and the ledger. |
| Checks-effects-interactions + `ReentrancyGuard` | every external call | Reentrancy. |

---

## 5. Per-network considerations

The contract is chain-agnostic; the operational envelope is not.

| Concern | What to do |
|---|---|
| **Reorgs** | A settlement reported at 1 confirmation can un-happen. The backend must not mark a transfer complete, and the monitor must not alert, until `CONFIRMATIONS` blocks have passed. **2 on testnets, 5 or more on mainnet.** |
| **Sequencer outages (L2s)** | Base and Arbitrum have a single sequencer. During an outage nothing settles and the vault appears frozen. This is a liveness risk, not a safety one; the backend must queue rather than retry into a wall, and the customer-facing SLA should account for it. |
| **Sequencer censorship** | Both chains have escape hatches (forced inclusion via L1). Not implemented here; acceptable given the amounts and the pause-and-wait fallback. |
| **`block.timestamp`** | Used for expiry, `maxSettleDelay` and rate age. A sequencer can drift it by seconds. Every window is minutes or days, so drift is immaterial. |
| **Gas price spikes** | Each transfer needs at least two transactions (`lockQuote`, `settle`). On Ethereum mainnet this can exceed the fee on an SME-sized payment; part of the #1 decision. |
| **Chain-specific USDC** | Only **native** 6-decimal USDC. The constructor enforces it. BNB Chain's bridged USDC (18 decimals) is refused. See [`../networks.md`](../networks.md). |
| **One vault per chain** | Nothing in this repo moves value between chains. Each deployment has its own float, partners, roles, monitor and audit. |

---

## 6. Known issues and accepted risks

Carry this list into the audit rather than letting the auditor rediscover it:

1. **A compromised admin can eventually drain the float.** Accepted; mitigated by Safe signer separation and
   detection, not by code.
2. **Operator + partner compromise together** drains up to the daily limit. Accepted; keep the limit tight.
3. **The vault being blocklisted by Circle is unrecoverable on-chain.** Accepted; recovery requires Circle.
4. **Slow reference-rate poisoning** is not detected on-chain (§2.4). Needs a monitoring rule.
5. **`requireFunding` is off by default**, so an unfunded `ref` can be settled. Deliberate: the on-ramp
   partner's delivery model is not yet confirmed (#1, #8). **Turn it on once it is.**
6. **No on-chain proof of fiat payout.** By design — the chain cannot observe a bank.
7. **Fees accumulate in the vault** and are withdrawn with `sweep`. There is no separate fee account.

---

## 7. Audit readiness checklist

**Scope to hand the auditor**

- [ ] `src/SettlementVault.sol`, `src/interfaces/ISettlementVault.sol`,
      `src/libraries/{FxMath,UsdcUnits,TransferRef}.sol`
- [ ] This document, [`review.md`](review.md), [`../architecture.md`](../architecture.md),
      [`../fx-quote-criteria.md`](../fx-quote-criteria.md)
- [ ] The exact commit hash: `______________` *(fill in — audit a frozen commit, not a branch)*
- [ ] Solidity 0.8.28, optimizer on, 10,000 runs, `evm_version = cancun`
- [ ] OpenZeppelin v5.4.0, pinned in the `Makefile`

**Invariants to state explicitly** (all enforced by `test/invariant/`)

- [ ] `balance == initial + funded + returned − settled − refunded − swept`
- [ ] `totalRefunded ≤ totalReturned ≤ totalSettled`
- [ ] `reservedForRefunds ≤ balance` — reserved funds are always backed
- [ ] every `ref` is in exactly one consistent state; a cancelled `ref` never settles
- [ ] on-chain counters always equal the test harness's independent ghost counters

**Evidence to provide**

- [ ] `forge test` — 126 unit and fuzz tests (1,000 fuzz runs) plus 6 invariants
- [ ] `forge coverage` — 100% line, statement, branch and function coverage of `src/`
- [ ] `make e2e` — full lifecycle on a live chain with monitor assertions, running in CI
- [ ] `make slither` — output and triage in `review.md`
- [ ] §6 above, unedited

**Before mainnet**

- [ ] Audit findings resolved or formally accepted, in writing
- [ ] Admin is a production Safe with hardware-wallet signers, threshold ≥ 2
- [ ] Operator and oracle keys are in custody (#11); no raw keys anywhere
- [ ] Limits start small and rise with experience
- [ ] Monitor running per network with paging wired up (#16), `CONFIRMATIONS ≥ 5`
- [ ] Rate oracle running with a source independent of the quoting provider (#15)
- [ ] `requireFunding` decided (#5 in §6)
- [ ] Regulatory and partner approvals the PRD requires are in hand
