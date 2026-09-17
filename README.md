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
| `SettlementVault` contract | ✅ v0: settle, partner return, refund, limits, pause, roles |
| Unit, fuzz and invariant tests | ✅ 47 tests, 100% line and branch coverage |
| Local deploy script | ✅ verified against Anvil |
| Testnet deployment | ⏳ pending chain decision (see below) |
| Backend integration (Rust / alloy) | ⏳ not started |
| Custody (Fireblocks, Cobo or Dfns) integration | ⏳ not started |
| External audit | ⏳ required before mainnet |

See the [open issues](https://github.com/Pick-MANILLA/kimana_blockchain/issues) for what to pick up.

> **Open decision:** the PRD names **Stellar** as the v1 settlement chain, but Stellar does not run Solidity.
> This repo assumes an **EVM chain** (Base is the default target). Until the product and engineering leads
> confirm the chain, treat testnet and mainnet work as provisional.

## How it works

```
USD payer ──► On-ramp partner ──USDC──► SettlementVault ──settle(ref)──► NGN off-ramp partner ──NGN──► exporter's bank
                                             ▲                                   │
                                             └────── returnSettlement(ref) ◄─────┘  (payout failed)
                                             │
                                             └────── refund(ref, to) ──► allowlisted partner
```

- `ref` is `keccak256("kimana:transfer:" + transferId)`. Each `ref` can move money **once**.
- Funds only leave to **allowlisted partners**. The one exception is admin `sweep`, which can never touch funds reserved for refunds.
- **Per-settlement and per-UTC-day limits** cap how much can move.
- **Roles:**
  - admin: a Safe multisig, transferred in two steps with a delay;
  - operator: the custody provider's MPC wallet;
  - pauser: an emergency key.

Full design, state mapping and decimals rules: [`docs/architecture.md`](docs/architecture.md).

## Repo layout

```
src/
  SettlementVault.sol            core contract
  interfaces/ISettlementVault.sol
  libraries/UsdcUnits.sol        cents <-> USDC (6 dp) integer conversion
  libraries/TransferRef.sol      backend transfer id -> bytes32 ref
script/
  DeploySettlementVault.s.sol
test/
  SettlementVault.t.sol          unit and fuzz tests
  Libraries.t.sol
  invariant/                     handler-based invariant tests
  mocks/MockUSDC.sol
docs/
  architecture.md
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
```

Dependencies live in `lib/`, which is gitignored. Their versions are pinned in the `Makefile`. Run `make install` again after a version bump.

## Deploying (testnet)

Never put a private key in `.env`. Use a Foundry keystore:

```bash
cast wallet import kimana-deployer --interactive
cp .env.example .env   # fill in addresses and limits
source .env

forge script script/DeploySettlementVault.s.sol \
  --rpc-url base_sepolia --account kimana-deployer --broadcast --verify
```

The deployer gets **no roles**. Admin, operator and pauser come from the environment.

## Security

- Report vulnerabilities privately to the maintainers. Do not open a public issue.
- No mainnet deployment happens without an external audit and the regulatory and partner approvals the PRD requires.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
