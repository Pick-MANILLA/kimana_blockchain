# Runbook: run the vault monitor in production

Issue #16. One monitor instance **per deployed network**. A vault nobody is watching is a vault whose first
sign of trouble is a customer complaint.

## What it watches

`monitor/index.mjs` reads the chain and raises alerts for:

| Signal | Level | What it means |
|---|---|---|
| `Paused` | critical | Someone hit the emergency stop. Payments have stopped. |
| reverted vault transaction | critical | A `lockQuote` or `settle` failed. Includes blocked quotes (`RateDivergenceTooHigh`), expired quotes and failed payouts. Reverted transactions emit **no events**, so this is the only way they surface. |
| free float below `MIN_FLOAT_USDC` | critical | Settlements will start failing. Top up. |
| `RateDivergence` | warning | The quoted rate is at least 1% from the oracle's reference. One of them is wrong. |
| `ReferenceRateStale` | warning | Only appears when admin has set `allowStaleReferenceRate` — meaning the rate check is **currently bypassed**. Otherwise a missing rate blocks the lock instead, surfacing as a critical `TransactionReverted` with `ReferenceRateUnavailable`. |
| `FundingReturned` | info | A partner's deposit went back for a cancelled or abandoned transfer. |
| `AllowStaleReferenceRateUpdated` | warning | The rate check was switched on or off. Should always match a recorded incident. |
| `SettlementReturned` | warning | An off-chain payout failed and the partner sent the USDC back. |
| `RoleGranted` / `RoleRevoked` / admin transfers | warning | Someone changed who controls the vault. If it was not you, treat it as an incident. |
| `PartnerUpdated`, `LimitsUpdated`, `QuoteConfigUpdated`, `Swept`, `Unpaused` | warning | Admin actions. Each should match a Safe transaction someone can point to. |
| everything else | info | Normal traffic. |

## Alert routing

Two webhooks, deliberately:

- `ALERT_WEBHOOK_URL` — the team Slack channel. Receives **everything**, so there is a full history.
- `PAGER_WEBHOOK_URL` — PagerDuty, Opsgenie, or a second Slack channel with notifications on. Receives
  **critical only**, so on-call is woken for a paused vault or a dry float, not for routine traffic.

Critical alerts go to both. `NETWORK_LABEL` prefixes every message (`[base-sepolia][CRITICAL] …`), so one
channel can carry several networks without confusion.

## Run it with Docker

```bash
cd monitor
cp .env.monitor.example .env
$EDITOR .env                  # RPC, vault address, webhooks
docker compose up -d
docker compose logs -f monitor-base-sepolia
curl -s localhost:8081/health | jq
```

The compose file has one service per network; copy the commented block for each mainnet once #1 is decided.
State lives on a named volume, so a restart resumes from the last processed block instead of re-scanning.

## Run it with systemd

```bash
sudo cp monitor/kimana-monitor@.service /etc/systemd/system/
sudo mkdir -p /etc/kimana
sudo cp monitor/.env.monitor.example /etc/kimana/monitor-base-sepolia.env
sudo $EDITOR /etc/kimana/monitor-base-sepolia.env
sudo systemctl enable --now kimana-monitor@base-sepolia
journalctl -u kimana-monitor@base-sepolia -f
```

Give each instance its own `HEALTH_PORT`.

## Per-network settings

| Setting | Testnet | Mainnet | Why |
|---|---|---|---|
| `CONFIRMATIONS` | 2 | **5 or more** | Reorgs. Reporting a settlement that later un-happens is worse than reporting it late. |
| `MIN_FLOAT_USDC` | 100 | enough for a busy day, agreed with finance | Below this, settlements start reverting. |
| `POLL_MS` | 15000 | 15000 | Lower burns RPC quota for little benefit. |
| `HEALTH_PORT` | unique per instance | unique per instance | Two instances cannot share a port. |

## Who watches the watcher

The monitor serves `GET /health`, which returns **503** once the last successful tick is older than
`HEALTH_MAX_STALE_MS` (default `max(POLL_MS × 4, 120s)`). Docker's `HEALTHCHECK` and the restart policy use
it; point an external uptime probe (Better Stack, Pingdom, a Kubernetes liveness probe) at it as well.

It also logs a heartbeat line every `HEARTBEAT_MS` (default 5 minutes) with tick, error and alert counters.

**Do this, or the rest is theatre:** put an external probe on `/health`. A monitor that has crashed reports
nothing, which looks exactly like a quiet day.

## First-run smoke test

After deploying (#12), prove the whole chain works before relying on it:

```bash
# 1. Alerts reach Slack at all.
ALERT_WEBHOOK_URL=<your webhook> node -e \
  'fetch(process.env.ALERT_WEBHOOK_URL,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({text:"[TEST] kimana monitor wiring"})})'

# 2. A real critical alert: pause from the pauser key, confirm the page fires, then unpause via the Safe.
cast send $VAULT "pause()" --rpc-url $RPC --private-key $PAUSER_KEY

# 3. A reverted-transaction alert: lock a quote 6% off the reference and watch it be blocked.
#    docs/runbooks/deploy.md step 8 has the exact command.
```

Tick all three off before calling #16 done.

## When an alert fires

Go to [`incident.md`](incident.md). In short:

- **Paused** — find out who paused it and why before unpausing. Unpausing needs the Safe.
- **reverted `RateDivergenceTooHigh`** — the quoting provider and the oracle disagree by more than 5%. Do not
  raise the threshold to make it go away; work out which source is wrong.
- **reverted `ReferenceRateUnavailable`** — the rate oracle (#15) is down and quotes are being blocked. Restart
  the oracle; see `incident.md`. Do not reach for `allowStaleReferenceRate` first.
- **`ReferenceRateStale`** — the rate check is currently bypassed by admin. Should be time-limited.
- **low float** — top up before settlements start failing. `script/FloatReport.s.sol` (#13) gives the full picture.
