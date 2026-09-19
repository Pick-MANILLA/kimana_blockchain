# Rate oracle service (issue #15)

Publishes an **independent** reference rate for each registered currency, so `lockQuote` can compare the
customer-facing rate against something the quoting provider does not control.

The vault treats a reference older than `quoteConfig().referenceMaxAge` (default 1 hour) as stale and emits
`ReferenceRateStale` on every lock. Nothing publishes these rates unless this service runs.

## Why it must be a different source

The whole point of the divergence check is to catch a bad or manipulated quote. If this service reads the same
API the backend quotes from, the two will always agree and the check is theatre. Use a different provider, and
say which one in `docs/adr/`.

## Run

```bash
cd oracle && npm ci

RPC_URL=https://sepolia.base.org \
VAULT_ADDRESS=0x... \
CURRENCIES=NGN \
ORACLE_PRIVATE_KEY=0x...        # testnets only; refused on mainnet chain ids
node index.mjs

node index.mjs --once           # one pass, useful in CI and for a first smoke test
DRY_RUN=1 node index.mjs --once # decide and log, publish nothing
```

## Env

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL`, `VAULT_ADDRESS` | — | required |
| `CURRENCIES` | `NGN` | comma-separated ISO codes to publish |
| `RATE_API_URL` | `https://open.er-api.com/v6/latest/USD` | any endpoint returning `"<CODE>": <number>` |
| `POLL_MS` | `60000` | how often to check |
| `MAX_AGE_MS` | `1500000` (25 min) | republish once the on-chain rate is older than this |
| `MOVE_BPS` | `50` (0.5%) | republish when the rate moves at least this much |
| `MAX_JUMP_BPS` | `1000` (10%) | refuse to publish a jump larger than this; alert instead |
| `ORACLE_PRIVATE_KEY` | — | testnet signing key. Refused when the chain id is a mainnet |
| `CUSTODY_SIGN_URL` | — | production signing through the custody provider (#11) |
| `ALERT_WEBHOOK_URL` | — | Slack-compatible `{ text }` webhook for failures |
| `DRY_RUN` | off | log decisions, send nothing |

## Integer-only conversion

Rates are parsed out of the raw response body as **text** and scaled to 8 decimals with `BigInt` string
surgery — the value never becomes a JavaScript float, so it cannot pick up binary rounding error that would
make the on-chain reference disagree with the backend's own integer maths.

`1645.25` → `"1645"` + `"25000000"` → `164525000000n`.

## Safety

- Rates outside `0 < rate <= 1e20` are refused (the vault's `FxMath.MAX_RATE`).
- A move larger than `MAX_JUMP_BPS` is **not** published. A bad API response that got through would poison the
  reference and start blocking legitimate quotes with `RateDivergenceTooHigh`, so a big jump raises a critical
  alert for a human instead.
- Currencies that are not enabled on-chain are skipped: `setReferenceRate` would revert.
- On mainnet chain ids the service refuses to start with a raw key. Use `CUSTODY_SIGN_URL` (#11).
