# Runbook: incidents

Who does what when the monitor raises an alert, or something looks wrong on-chain. Alerts come from
`monitor/` (see [`deploy.md`](deploy.md) step 9); each one names the event, the transfer `ref` and the
transaction.

## Stop everything (pause)

Use when funds may be at risk: an operator key may be compromised, settlements are going to the wrong
place, or amounts look wrong.

```bash
cast send $VAULT "pause()" --rpc-url $RPC --private-key <pauser key or custody wallet>
```

While paused: `lockQuote`, `settle` and `refund` are blocked. `returnSettlement` and `cancelQuote` still
work, because both only reduce risk. Unpausing is an **admin (Safe)** action:

```
setUnpause via Safe: unpause()
```

Tell the backend team immediately: their `settle` calls will fail while paused.

## Alert: `RateDivergence`

The quoted rate is 1% or more away from the reference rate. The lock still succeeded.

1. Compare the quoted rate and the reference rate in the alert.
2. Check the quoting provider's feed and the oracle's source for that currency.
3. If the quoting provider is wrong: stop quoting that currency (backend), and consider pausing.
4. If the oracle is wrong: fix its source, then republish with `setReferenceRate`.

## Alert: `TransactionReverted` with `RateDivergenceTooHigh`

A quote was **blocked**: more than 5% away from the reference. No money moved, and the customer's
transfer will fail.

Same checks as above, but treat it as urgent: either pricing is broken or the oracle is broken, and
customers are being turned away.

## Alert: `ReferenceRateStale`

No reference rate newer than an hour, so divergence could not be checked. Payments continue.

1. Check whether the rate oracle service is running (issue #15).
2. Republish manually if needed:
   ```bash
   cast send $VAULT "setReferenceRate(bytes3,uint256)" 0x4e474e <rate 8dp> \
     --rpc-url $RPC --private-key <oracle key>
   ```

## Alert: `SettlementReturned`

A partner sent USDC back, meaning an off-chain payout failed.

1. Find the transfer by its `ref` and check the partner's reason.
2. Refund it to an allowlisted on-ramp/treasury address:
   ```bash
   cast send $VAULT "refund(bytes32,address)" $REF $TO --rpc-url $RPC --private-key <operator>
   ```
3. If a partner returns payments repeatedly, remove it from the allowlist (below).

## Alert: low float (`FloatCheck`)

The vault's free USDC is below the configured minimum. Top it up from treasury, or reduce the daily
limit until it is funded. Money reserved for pending refunds is never spendable.

## Rotate the operator or oracle key

Admin (Safe) actions, done in this order:

1. Grant the role to the new wallet: `grantRole(<role>, newWallet)`.
2. Revoke it from the old one: `revokeRole(<role>, oldWallet)`.
3. Update the backend or oracle service configuration.

Role ids: `cast keccak "OPERATOR_ROLE"`, `cast keccak "RATE_ORACLE_ROLE"`, `cast keccak "PAUSER_ROLE"`.

## Remove a partner or disable a currency

Admin (Safe):

- `setPartner(partner, (false, false, false, 0x000000))` — blocks new settlements to that partner, and stops
  it funding or receiving refunds. Settlements already made are
  unaffected, and the partner can still return funds.
- `setCurrency(code, decimals, false)` — blocks new quote locks in that currency. Quotes already locked
  still settle.

## Abandoned transfer

A quote was locked but funding never arrived, or compliance rejected the transfer:

```bash
cast send $VAULT "cancelQuote(bytes32)" $REF --rpc-url $RPC --private-key <operator>
```

The `ref` and the quote id are then used up for good. A re-quoted transfer needs a new backend transfer id.

## Stuck or dropped transaction

Retry with the **same** `ref` and the same amount. The contract rejects a second successful settlement,
so retries are safe.

## After any incident

- Record what happened, the transaction hashes and the fix in the team's incident log.
- If the contract behaved in a way the docs don't describe, open an issue.

## Rate oracle outage (quotes are being blocked)

Symptom: `lockQuote` reverts with `ReferenceRateUnavailable`, and the monitor raises a critical
`TransactionReverted` alert. Payments have stopped.

This is the fail-closed behaviour working as designed (issue #24) — the vault refuses to lock a rate it cannot
check.

1. **Fix the oracle first.** It is usually the `oracle/` service having stopped. Restart it and confirm a fresh
   `ReferenceRateUpdated` event. Locking resumes immediately, with no admin action.
2. **Only if the outage will be long** and the business accepts the risk, admin may set
   `setAllowStaleReferenceRate(true)`. While that is on, **there is no on-chain protection against a
   manipulated or fat-fingered rate.**
3. Treat step 2 as an incident with an explicit end time. Set a reminder, turn it off, and record who
   authorised it. The `AllowStaleReferenceRateUpdated` event is the audit trail.

## Partner capital stuck on a cancelled transfer

A partner funded a `ref` that will never settle.

```bash
cast send $VAULT "cancelQuote(bytes32)" $REF --rpc-url $RPC --private-key $OPERATOR_KEY
cast send $VAULT "returnFunding(bytes32)" $REF --rpc-url $RPC --private-key <any funded key>
```

`returnFunding` can be called by anyone and always pays the address that made the deposit, so the partner can
do it themselves. It works while paused. If the operator never cancelled, it becomes callable anyway once the
lock is older than `maxSettleDelay`.
