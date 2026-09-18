# kimana_blockchain

[![CI](https://github.com/Pick-MANILLA/kimana_blockchain/actions/workflows/test.yml/badge.svg)](https://github.com/Pick-MANILLA/kimana_blockchain/actions/workflows/test.yml)

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
| Unit, fuzz and invariant tests | ✅ 97 tests, 100% line and branch coverage |
| Local integration test (Anvil + monitor) | ✅ `make e2e`, runs in CI |
| Monitoring | ✅ `monitor/`: event and reverted-transaction alerts, webhook, low-float check |
| Internal security review | ✅ [Slither + manual](docs/security/review.md) |
| Local deploy script | ✅ verified against Anvil |
| Deploy preflight and post-deploy checks | ✅ `make preflight`, `make verify` |
| Testnet deployment | ⏳ next: Base Sepolia |
| Backend integration (Rust / alloy) | ⏳ not started |
| Custody (Fireblocks, Cobo or Dfns) integration | ⏳ not started |
| External audit | ⏳ required before mainnet |

See the [open issues](https://github.com/Pick-MANILLA/kimana_blockchain/issues) for what to pick up.

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
script/
  DeploySettlementVault.s.sol
  preflight.sh                   pre-deployment checks (`make preflight`)
  verify-deploy.sh               post-deployment checks (`make verify`)
  LocalE2E.s.sol                 local end-to-end scenario (Anvil only)
  e2e-local.sh                   runs the scenario and checks results (`make e2e`)
monitor/
  index.mjs                      event monitor and alerts (`make monitor`)
test/
  SettlementVault.t.sol          unit and fuzz tests
  QuoteLock.t.sol                FX quote acceptance criteria
  Libraries.t.sol
  invariant/                     handler-based invariant tests
  mocks/MockUSDC.sol
deployments/
  84532.example.json             per-network address registry (copy to <chainId>.json)
docs/
  architecture.md
  runbooks/deploy.md             step-by-step testnet deployment
  runbooks/incident.md           pause, rotate keys, respond to alerts
  fx-quote-criteria.md           acceptance criteria -> enforcement -> tests
  networks.md                    supported EVM chains and USDC addresses
  security/review.md
```

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/Pick-MANILLA/kimana_blockchain.git
cd kimana_blockchain

make install          # installs forge-std + OpenZeppelin v5.4.0 into lib/ (pinned in Makefile)
forge build
forge test            # unit + fuzz + invariant
forge test -vvv --mt test_refund   # run a subset
forge fmt             # format before committing
forge coverage        # coverage report
make e2e              # local integration test (needs Node 20+)
```

Dependencies live in `lib/`, which is gitignored. Their versions are pinned in the `Makefile`. Run `make install` again after a version bump.

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
