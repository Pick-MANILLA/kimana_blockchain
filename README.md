# kimana_contract

[![CI](https://github.com/Pick-MANILLA/kimana_contract/actions/workflows/test.yml/badge.svg)](https://github.com/Pick-MANILLA/kimana_contract/actions/workflows/test.yml)

The on-chain settlement layer for **Kimana**, a cross-border payment and trade workflow platform for African SMEs.

Kimana moves value between US dollars and Nigerian naira. USDC is the settlement asset on-chain. Licensed
partners handle the fiat legs: an on-ramp turns USD into USDC, and an off-ramp turns USDC into NGN in the
customer's bank account. **This repo covers only the USDC movement between the Kimana vault and those partners.**

> Customers never see blockchain. They see "certain, documented payments". The backend ledger in
> [`Kimana_backend`](https://github.com/Pick-MANILLA/Kimana_backend) is authoritative. The chain is one step in
> the transfer lifecycle.

## Status

| Area | State |
|---|---|
| `SettlementVault` contract | ✅ quote lock, settle, partner return, refund, limits, pause, roles |
| FX quote criteria (settlement side) | ✅ expiry, single-use lock, counterparty-amount check, divergence alerts ([details](docs/fx-quote-criteria.md)) |
| Fork tests against real USDC (blocklist + pause) | ✅ `test/fork/`, on demand with RPC URLs, skipped otherwise (see below) |
| Unit, fuzz and invariant tests | ✅ 151 unit and fuzz tests + 8 invariants, 100% line and branch coverage |
| Local integration test (Anvil + monitor) | ✅ `make e2e`, runs in CI |
| Inbound USDC accounting (`fund`) | ✅ deposits bound to the quote, reserved against sweep, returnable if cancelled |
| Partner types | ✅ on-ramp / off-ramp, with per-currency payout restriction |
| Monitoring | ✅ `monitor/`: event and reverted-transaction alerts, alert routing, `/health`, Docker + systemd |
| Rate oracle service | ✅ `oracle/`: independent reference rates, integer-only, jump guard |
| Threat model | ✅ [`docs/security/threat-model.md`](docs/security/threat-model.md) |
| Internal security review | ✅ [Slither + manual](docs/security/review.md) |
| Local deploy script | ✅ verified against Anvil |
| Deploy preflight and post-deploy checks | ✅ `make preflight`, `make verify` |
| Testnet deployment | ⏳ next: Base Sepolia |
| Backend integration (Rust / alloy) | ⏳ not started |
| Custody (Fireblocks, Cobo or Dfns) integration | ⏳ not started |
| External audit | ⏳ required before mainnet |

See the [open issues](https://github.com/Pick-MANILLA/kimana_contract/issues) for what to pick up.

> **Chain:** EVM (confirmed). The vault works on any EVM chain with native USDC: **Base** (default), **Arbitrum**,
> **Polygon** and **Ethereum** are configured, with testnets. BNB Chain is not supported (its bridged USDC has 18
> decimals). See [`docs/networks.md`](docs/networks.md).

## How it works

```
USD payer ──► On-ramp partner ──USDC──► SettlementVault ──settle(ref)──► NGN off-ramp partner ──NGN──► exporter's bank
                                             ▲                                   │
                                             └────── returnSettlement(ref) ◄─────┘  (payout failed)
                                             │
                                             └────── refund(ref, to) ──► allowlisted partner
```

- `ref` is `keccak256("kimana:transfer:" + transferId)`. Each `ref` can move money **once**.
- The on-ramp partner can deliver the USDC with `fund(ref, usdcAmount + feeUsdc)`, which binds the deposit
  on-chain to the accepted quote. Admin can then require it with `setRequireFunding(true)`.
- A deposit is **reserved**: neither `sweep` nor another transfer's settlement can spend it, and
  `returnFunding(ref)` sends it home if the transfer is cancelled or abandoned.
- **A quote cannot lock without a fresh reference rate.** The divergence check fails closed; admin can override
  with `setAllowStaleReferenceRate(true)` during an oracle outage.
- Before paying, the backend calls `lockQuote(ref, quote)` with the rate, fee and counterparty amount the customer
  accepted. Expired, reused or inconsistent quotes are rejected, and rates far from the oracle's reference rate
  raise an alert (or are blocked). `settle` only pays the exact locked amount.
- Funds only leave to **allowlisted partners**. The one exception is admin `sweep`, which can never touch funds reserved for refunds.
- **Per-settlement and per-UTC-day limits** cap how much can move.
- **Roles:**
  - admin: a Safe multisig, transferred in two steps with a delay;
  - operator: the custody provider's MPC wallet;
  - pauser: an emergency key;
  - rate oracle: publishes independent reference rates.

Full design, state mapping and decimals rules: [`docs/architecture.md`](docs/architecture.md).

## Repo layout

```
src/
  SettlementVault.sol            core contract
  interfaces/ISettlementVault.sol
  libraries/UsdcUnits.sol        cents <-> USDC (6 dp) integer conversion
  libraries/TransferRef.sol      backend transfer id -> bytes32 ref
  libraries/FxMath.sol           rate -> counterparty amount, divergence (integer only)
abi/
  SettlementVault.json           ABI for the backend and monitor (`make abi`)
  SettlementVault.errors.json    4-byte selector -> custom error signature, for decoding reverts
  SettlementVault.storage.json   storage layout, diffed in CI so a moved slot cannot pass unnoticed
script/
  DeploySettlementVault.s.sol
  error-selectors.sh             regenerates abi/SettlementVault.errors.json
  storage-layout.sh              regenerates abi/SettlementVault.storage.json
  preflight.sh                   pre-deployment checks (`make preflight`)
  verify-deploy.sh               post-deployment checks (`make verify`)
  FloatReport.s.sol              on-demand treasury report (`make float`)
  LocalE2E.s.sol                 local end-to-end scenario (Anvil only)
  e2e-local.sh                   runs the scenario and checks results (`make e2e`)
monitor/
  index.mjs                      event monitor and alerts (`make monitor`)
  Dockerfile, docker-compose.yml, kimana-monitor@.service   one instance per network
oracle/
  index.mjs                      publishes independent reference rates (`make oracle`)
test/
  SettlementVault.t.sol          unit and fuzz tests
  QuoteLock.t.sol                FX quote acceptance criteria
  FundingAndPartners.t.sol       fund() accounting and partner types
  Blocklist.t.sol                behaviour when Circle blocklists an address
  fork/                          fork tests against real USDC on testnets (optional, need RPC URLs)
  Libraries.t.sol
  invariant/                     handler-based invariant tests
  mocks/MockUSDC.sol
deployments/
  84532.example.json             per-network address registry (copy to <chainId>.json)
docs/
  architecture.md
  adr/0001-settlement-network.md which chain to settle on (pending sign-off)
  runbooks/deploy.md             step-by-step testnet deployment
  runbooks/incident.md           pause, rotate keys, respond to alerts
  runbooks/monitoring.md         running the monitor per network
  fx-quote-criteria.md           acceptance criteria -> enforcement -> tests
  networks.md                    supported EVM chains and USDC addresses
  security/review.md
  security/threat-model.md       actors, trust assumptions, audit readiness
```

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/Pick-MANILLA/kimana_contract.git
cd kimana_contract

make install          # installs forge-std + OpenZeppelin v5.4.0 into lib/ (pinned in Makefile)
forge build
forge test            # unit + fuzz + invariant
forge test -vvv --mt test_refund   # run a subset
forge fmt             # format before committing
forge coverage        # coverage report
make e2e              # local integration test (needs Node 20+)
make float VAULT=0x... NETWORK=base_sepolia   # treasury report
```

Dependencies live in `lib/`, which is gitignored. Their versions are pinned in the `Makefile`. Run `make install` again after a version bump.

## Fork tests against real USDC (optional)

The unit tests use `MockUSDC`. `test/fork/SettlementVault.fork.t.sol` additionally forks a testnet and exercises the
vault against **Circle's real USDC proxy** on the [configured networks](docs/networks.md) — including its
6-decimal check and the blocklist/pause behaviour mocked by `MockBlocklistUSDC` (issue #3). To run them, set the
RPC URLs (fill `.env` from `.env.example`, or export them):

```bash
. .env   # already provides BASE_SEPOLIA_RPC_URL
forge test --match-path test/fork/SettlementVault.fork.t.sol -vv
```

Each network's suite only runs when its variable is set — `BASE_SEPOLIA_RPC_URL` (required), plus optionally
`ARBITRUM_SEPOLIA_RPC_URL` and `POLYGON_AMOY_RPC_URL`. Without them the tests are **skipped**, so plain `forge test`
stays green in CI with no RPC access. The tests impersonate the real USDC `blacklister`/`pauser` role holders to
blocklist a test partner and pause the token, exactly as Circle can, and assert `settle`/`fund`/`refund` revert
with the real token's revert data while vault state stays untouched.

## Deploying (testnet)

Never put a private key in `.env`. Use a Foundry keystore:

```bash
cast wallet import kimana-deployer --interactive
cp .env.example .env   # fill in addresses and limits

make preflight NETWORK=base_sepolia     # read-only checks; fix every failure first

source .env
forge script script/DeploySettlementVault.s.sol \
  --rpc-url base_sepolia --account kimana-deployer --broadcast --verify

make verify NETWORK=base_sepolia VAULT=0x...   # roles, limits, currencies, deployer holds nothing
```

Other networks: use `arbitrum_sepolia`, `polygon_amoy` or `sepolia` (testnets), or `base`, `arbitrum`, `polygon` or
`mainnet`. See [`docs/networks.md`](docs/networks.md) for USDC addresses.

The deployer gets **no roles**. Admin, operator and pauser come from the environment.

## Security

- Report vulnerabilities privately to the maintainers. Do not open a public issue.
- No mainnet deployment happens without an external audit and the regulatory and partner approvals the PRD requires.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
