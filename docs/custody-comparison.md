# Custody provider comparison

**Purpose:** choose an MPC custody provider for the `OPERATOR_ROLE` and `RATE_ORACLE_ROLE` wallets.

**PRD constraints:**
- No private keys in code or environment variables; signing goes through an MPC/HSM provider.
- The `OPERATOR_ROLE` wallet (and ideally `RATE_ORACLE_ROLE`) must be custody-provider wallets.
- The operator may call only `lockQuote`, `cancelQuote`, `settle`, and `refund` on the vault.
- The oracle may call only `setReferenceRate` on the vault.
- Per-transaction and per-UTC-day value limits must be enforced at the custody layer.

**Providers evaluated:** Fireblocks, Cobo, Dfns.

---

## 1. Sandbox availability

| Provider | Sandbox | Notes |
|---|---|---|
| **Dfns** | ✅ Free 30-day trial, no credit card | All EVM testnets available immediately. Full API + SDK access. |
| **Fireblocks** | ✅ Free ~30-day developer sandbox | Policies are **non-editable** (all transactions auto-approved). Real policy testing requires a paid testnet workspace. |
| **Cobo** | ⚠️ Dev environment exists but is not self-serve | Must contact Sales to provision. No immediate trial access. |

---

## 2. Supported networks

Kimana requires all eight networks listed in [`docs/networks.md`](networks.md): Base, Base Sepolia, Arbitrum One, Arbitrum Sepolia, Polygon PoS, Polygon Amoy, Ethereum mainnet, Ethereum Sepolia. BNB Smart Chain is not supported by the vault.

| Network | Dfns | Fireblocks | Cobo |
|---|---|---|---|
| Base (mainnet) | ✅ Tier-1 | ✅ Confirmed | ✅ Confirmed |
| Base Sepolia | ✅ Tier-1 | ✅ Confirmed | ✅ Confirmed |
| Arbitrum One | ✅ Tier-1 | ✅ Confirmed | ✅ Confirmed |
| Arbitrum Sepolia | ✅ Tier-1 | ✅ Likely (verify) | ⚠️ Not confirmed in docs |
| Polygon PoS | ✅ Tier-1 | ✅ Confirmed | ✅ Confirmed |
| Polygon Amoy | ✅ Tier-1 | ⚠️ Likely (verify) | ⚠️ Not confirmed in docs |
| Ethereum mainnet | ✅ Tier-1 | ✅ Confirmed | ✅ Confirmed |
| Ethereum Sepolia | ✅ Tier-1 | ✅ Confirmed | ✅ Confirmed |

Dfns is the only provider that explicitly confirms all eight networks as Tier-1 in its published documentation. Fireblocks and Cobo likely support the missing testnets but require verification via their asset-list APIs or account teams.

---

## 3. Contract-call support

All three providers can call arbitrary EVM smart contract functions from an MPC wallet. The mechanism in each case is to construct ABI-encoded calldata and pass it to the provider's API.

| Provider | API / mechanism |
|---|---|
| **Dfns** | `POST /wallets/{walletId}/transactions` with `"kind": "Transaction"` and `"data": "0x<calldata>"`. Gas estimation is automatic. |
| **Fireblocks** | `createTransaction` with `operationType: CONTRACT_CALL` and `extraParameters.contractCallData: "0x<calldata>"`. |
| **Cobo** | `POST /v2/transactions/contract_call` with `destination_type: "EVM_Contract"` and `calldata: "0x<calldata>"`. |

All three providers allow calling `lockQuote`, `settle`, `cancelQuote`, `refund`, and `setReferenceRate` by encoding the function selector and arguments with any standard ABI library (ethers, viem, alloy).

---

## 4. Policy engine

This is the most important dimension for Kimana's security requirements.

### Required policies

| Policy | Fireblocks | Cobo | Dfns |
|---|---|---|---|
| Operator wallet restricted to vault only (contract address allowlist) | ✅ TAP destination rules | ✅ Contract-level policy | ✅ `TransactionRecipientWhitelist` + programmable approver |
| Operator wallet restricted to `lockQuote`, `cancelQuote`, `settle`, `refund` (function-level) | ✅ TAP `CONTRACT_CALL` + function restriction | ✅ Method-level policy (UI-configured) | ⚠️ No native rule; requires custom programmable approver service |
| Oracle wallet restricted to `setReferenceRate` only | ✅ TAP function restriction | ✅ Method-level policy | ⚠️ Requires programmable approver |
| Per-transaction USDC amount cap | ✅ `amountScope: SINGLE_TX` | ✅ Per-transaction limit | ✅ `TransactionAmountLimitNominal` |
| Per-UTC-day USDC amount cap | ✅ `amountScope: TIMEFRAME`, `periodSec: 86400` | ✅ Rolling 24 h window | ✅ `TransactionAmountVelocity` (86400 s) |
| Policy editable in sandbox | ❌ Non-editable in free sandbox | N/A (no self-serve sandbox) | ✅ Full policy engine in free trial |

#### Dfns policy gap detail

Dfns's built-in rules (`TransactionAmountLimit`, `TransactionAmountVelocity`, `TransactionRecipientWhitelist`) operate on plain value transfers. They do not inspect ABI calldata. This means there is no native "only allow `settle()` selector" rule.

The documented workaround is a **programmable approver**: a small service account that intercepts every signing request put into `Pending` state, decodes the calldata, checks the 4-byte function selector, validates arguments (e.g., the vault address, the `ref`, the `amount`), and calls the Dfns approval API to approve or reject. This service gives more control than any static rule engine but must be built, hosted, and monitored. See [`examples/custody/dfns-poc.mjs`](../examples/custody/dfns-poc.mjs) for an annotated sketch.

#### Fireblocks policy gap detail

Fireblocks's Transaction Authorization Policy (TAP) supports function-level restrictions for `CONTRACT_CALL` in fully editable workspaces (testnet / mainnet). The free sandbox has non-editable policies (all transactions auto-approved), so real policy testing requires a paid testnet workspace. This is a meaningful friction for pre-commercial teams.

#### Cobo policy advantage

Cobo's off-chain policy engine provides contract-level, method-level, and parameter-level restrictions configured through a UI without writing additional code. A rule such as "wallet W may only call `settle(bytes32,address,uint256)` on `0x<vault>`" can be set up directly in Cobo Portal. This is the most operator-friendly policy model of the three.

---

## 5. Webhooks

All three providers emit transaction-lifecycle webhooks sufficient for the Kimana backend state machine.

| Event needed | Dfns | Fireblocks | Cobo |
|---|---|---|---|
| Transaction confirmed on-chain | `wallet.transaction.confirmed` | `transaction.status.updated` (COMPLETED) | `wallets.transaction.succeeded` |
| Transaction failed / reverted | `wallet.transaction.failed` | `transaction.status.updated` (FAILED) | `wallets.transaction.failed` |
| Policy rejected transaction | `policy.triggered` / `wallet.transaction.rejected` | `transaction.approval_status.updated` | `wallets.transaction.failed` (with policy reason) |
| Inbound USDC deposit detected | `wallet.blockchainevent.detected` | `BALANCE_UPDATE` (v2, 2025) | `wallet.mpc.balance.updated` |
| MPC TSS key request | `wallet.signature.requested` | `transaction.created` | `wallets.mpc.tss_request.created` |

Dfns provides the most granular policy-event webhooks (`policy.triggered`, `policy.approval.pending`, `policy.approval.resolved`), which is useful when the programmable approver is in use.

---

## 6. Pricing

| | Dfns | Fireblocks | Cobo |
|---|---|---|---|
| Free trial | ✅ 30 days, all testnets | ✅ ~30 days, sandbox only | ❌ Contact Sales |
| Entry plan | $800 / yr (Starter, 1 chain) | $999 / mo (Essentials) | $299 / mo (Starter, MPC only) |
| Multi-chain plan (4 chains) | $35,000 / yr (Pro, 10 chains) | Custom (Pro, $36k+/yr) | $999 / mo (Standard) or Enterprise |
| Volume / AUM overage | None | 0.20% per tx beyond quota | 0.25% (Starter), 0.20% (Standard) |
| Raw signing | Included | Paid add-on | Included |
| Per-transaction fee | None | 0.20% of outbound volume | 0.20–0.25% overage |
| Custodial wallets | MPC only | MPC + Custodial | Custodial requires Enterprise |

Key observations:

- **Dfns** has no AUM or per-transaction percentage fee. For a high-volume corridor (e.g., $10 M/month settled), this could be significantly cheaper than Fireblocks or Cobo.
- **Fireblocks** charges a percentage overage on outbound volume and makes Raw Signing a paid add-on. For the `CONTRACT_CALL` path (which is what Kimana needs), Raw Signing is not required.
- **Cobo Starter ($299/mo)** is the cheapest entry point for a commercial MPC wallet, but does not include Custodial wallets, and testnet coverage for Arbitrum Sepolia and Polygon Amoy needs confirmation.

---

## 7. Policy requirement checklist

| Requirement | Fireblocks | Cobo | Dfns |
|---|---|---|---|
| Operator wallet: `lockQuote` only to vault | ✅ TAP + function rule | ✅ Method-level | ⚠️ Programmable approver |
| Operator wallet: `cancelQuote` only to vault | ✅ | ✅ | ⚠️ |
| Operator wallet: `settle` only to vault | ✅ | ✅ | ⚠️ |
| Operator wallet: `refund` only to vault | ✅ | ✅ | ⚠️ |
| Oracle wallet: `setReferenceRate` only to vault | ✅ | ✅ | ⚠️ |
| Per-transaction USDC cap | ✅ | ✅ | ✅ |
| Per-UTC-day USDC cap | ✅ | ✅ | ✅ |
| Policy testable without paying | ❌ (sandbox non-editable) | ❌ (no self-serve sandbox) | ✅ |

---

## 8. Recommendation

### Primary choice: **Dfns**

Dfns is recommended for the initial integration phase for three reasons:

1. **Fastest path to a working PoC.** The free 30-day sandbox requires no credit card and no Sales call, and all eight Kimana testnets are Tier-1 supported. The team can have a working `lockQuote → settle` loop on Base Sepolia within hours of signing up.

2. **All eight networks confirmed.** Dfns is the only provider that explicitly documents Tier-1 support for every network Kimana targets (including Arbitrum Sepolia and Polygon Amoy). Fireblocks and Cobo have gaps for these two testnets that need manual confirmation.

3. **Predictable pricing.** The flat annual subscription with no AUM or per-transaction percentage makes cost modelling straightforward. At moderate settlement volumes, Dfns will be cheaper than Fireblocks or Cobo.

**Known gap:** Dfns has no native function-selector policy rule. Restricting the operator wallet to only call `lockQuote`, `cancelQuote`, `settle`, and `refund` requires a programmable approver service. This is documented, supported, and relatively small to build (see `examples/custody/`), but it is an additional operational component that Cobo eliminates.

### Fallback: **Cobo**

If the team requires function-level policy restrictions configurable through a UI without additional code, Cobo is the better production choice. Its method-level policy engine directly satisfies all five policy requirements above. The trade-offs are: no self-serve sandbox, unconfirmed testnet coverage for Arbitrum Sepolia and Polygon Amoy (verify with Cobo Sales before committing), and a volume-based overage fee.

### Why not Fireblocks first?

Fireblocks is a strong option but is the most expensive entry point ($999/mo vs $299/mo Cobo Starter or $8k/yr Dfns Basic). More importantly, its free sandbox has non-editable policies, which means the team cannot test the full policy configuration without a paid workspace. Given that Kimana has not yet done its testnet deployment, starting with Fireblocks means paying for a testnet workspace before any production revenue exists.

---

## 9. Open questions before production commitment

1. **Dfns:** Confirm that the programmable approver can be deployed with acceptable latency for time-sensitive `lockQuote` calls (the backend must call `lockQuote` before `expiresAt`, typically within 15 minutes of the customer confirming).
2. **Cobo:** Verify Arbitrum Sepolia and Polygon Amoy testnet support via the `GET /v2/chains` API or directly with Cobo Sales.
3. **All providers:** Confirm USDC (6-decimal native) is the tracked asset for amount-based policy limits (not ETH/gas token).
4. **All providers:** Obtain a written commitment on SLA for signing API latency (target < 2 s for `lockQuote` to avoid race with `expiresAt`).
5. **Regulatory:** Confirm that the chosen provider meets Kimana's compliance obligations under Nigerian and US regulations (AML, travel rule).

---

## 10. References

- Dfns docs: <https://docs.dfns.co>
- Dfns pricing: <https://dfns.co/pricing>
- Fireblocks developer docs: <https://developers.fireblocks.com>
- Fireblocks pricing: <https://fireblocks.com/pricing>
- Cobo WaaS 2.0 docs: <https://cobo.com/developers/v2>
- Cobo pricing: <https://manuals.cobo.com/en/portal/bills-and-payments/introduction>
- Kimana networks: [`docs/networks.md`](networks.md)
- Kimana architecture: [`docs/architecture.md`](architecture.md)
- PoC: [`examples/custody/`](../examples/custody/)
