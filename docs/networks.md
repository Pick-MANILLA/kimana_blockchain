# Supported networks

`SettlementVault` is plain Solidity and runs on any EVM chain that has **native USDC with 6 decimals**. Deploy one
vault per chain; each vault needs its own USDC float, partners, roles and monitor instance.

Addresses below are Circle's native USDC, from
<https://developers.circle.com/stablecoins/usdc-contract-addresses> (checked September 2026). Always re-check that
page before deploying.

| Network | Foundry alias | Chain ID | USDC | Status |
|---|---|---|---|---|
| Base Sepolia (testnet) | `base_sepolia` | 84532 | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | ✅ default testnet |
| Arbitrum Sepolia (testnet) | `arbitrum_sepolia` | 421614 | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` | ✅ |
| Polygon Amoy (testnet) | `polygon_amoy` | 80002 | `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582` | ✅ |
| Ethereum Sepolia (testnet) | `sepolia` | 11155111 | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | ✅ |
| Base | `base` | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | ✅ default mainnet (after audit) |
| Arbitrum One | `arbitrum` | 42161 | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | ✅ |
| Polygon PoS | `polygon` | 137 | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | ✅ |
| Ethereum | `mainnet` | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | ✅ works, but gas is expensive for frequent payouts |
| BNB Smart Chain | — | 56 | none from Circle; bridged "USDC" has **18 decimals** | ❌ not supported: the constructor reverts with `UnsupportedAssetDecimals(18)` |

## Choosing a chain

Pick the chain(s) that your **NGN off-ramp partner** and your **custody provider** both support, with native USDC.
Lower fees matter because every transfer is at least two transactions (`lockQuote`, `settle`).

## Deploying to a chain

```bash
source .env
forge script script/DeploySettlementVault.s.sol --rpc-url <alias> --account kimana-deployer --broadcast --verify
```

After deploying:
- record the address in `deployments/<chainId>.json`;
- register currencies and partners through that chain's Safe;
- run a monitor for that chain (`RPC_URL=... VAULT_ADDRESS=... make monitor`).

## BNB Chain later

Supporting 18-decimal bridged USDC would need the USDC decimals to be a constructor parameter (used by
`UsdcUnits` and `FxMath`), plus a risk review of the bridge. Open an issue if the business needs it.
