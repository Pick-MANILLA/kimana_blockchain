# Runbook: deploy SettlementVault to a testnet

Target: **Base Sepolia** (chain id 84532). The same steps work for any network in
[`../networks.md`](../networks.md) — swap the alias and the USDC address.

Time: about half a day, mostly waiting on faucets and the Safe.

Deploy to **one** chain. Each chain needs its own USDC float, partners, roles, monitor and audit, so only
add a second when a partner or the custody provider requires it.

---

## 0. Prerequisites

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
git clone https://github.com/Pick-MANILLA/kimana_blockchain.git && cd kimana_blockchain
make install
forge test          # 97 tests must pass
make e2e            # full flow on a local chain (needs Node 20+)
```

You also need a free Etherscan API key (one key verifies all chains) from <https://etherscan.io/myapikey>.

---

## 1. Create the wallets

Testnet wallets are throwaway, but never reuse them on mainnet — there, the operator and oracle keys come
from the custody provider and the admin is a real Safe.

```bash
cast wallet new      # run 4 times
```

Record what each one is for:

| Role | Purpose | Needs testnet ETH |
|---|---|---|
| deployer | Sends the deployment transaction; **gets no powers** | yes |
| operator | Stands in for the backend/custody wallet: `lockQuote`, `settle`, `refund` | yes |
| pauser | Emergency stop | yes (a little) |
| rate oracle | Publishes reference rates | yes (a little) |
| partner | Stands in for the off-ramp partner in the test run | yes (a little) |

Import the deployer into an encrypted keystore, so no private key sits in a file:

```bash
cast wallet import kimana-deployer --interactive    # paste the deployer key, set a password
cast wallet address --account kimana-deployer       # confirm the address
```

Get Base Sepolia ETH from a faucet (Coinbase Developer Platform, Alchemy or QuickNode) for each address
above.

---

## 2. Create the Safe (the admin)

1. Go to <https://app.safe.global>, connect a wallet and switch the network to **Base Sepolia**.
2. Create a Safe with at least two signers (you and a teammate). Threshold 2/2 is closest to production;
   1/2 is acceptable on a testnet.
3. Copy the Safe address. This is `ADMIN_ADDRESS`.

---

## 3. Fill in `.env`

```bash
cp .env.example .env
```

```bash
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
ETHERSCAN_API_KEY=<your key>

USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e   # Base Sepolia USDC (check docs/networks.md)
ADMIN_ADDRESS=<Safe address>
OPERATOR_ADDRESS=<operator address>
PAUSER_ADDRESS=<pauser address>
RATE_ORACLE_ADDRESS=<oracle address>

ADMIN_TRANSFER_DELAY=172800      # 2 days
MAX_PER_SETTLEMENT=50000000000   # $50,000  (USDC has 6 decimals)
DAILY_LIMIT=100000000000         # $100,000
```

Never put a private key in this file.

---

## 4. Deploy

```bash
source .env
forge script script/DeploySettlementVault.s.sol \
  --rpc-url base_sepolia --account kimana-deployer --broadcast --verify
```

Save the printed address:

```bash
export VAULT=0x...            # SettlementVault
export USDC=$USDC_ADDRESS
export RPC=base_sepolia
```

Check that the roles landed where they should (the deployer must hold nothing):

```bash
cast call $VAULT "defaultAdmin()(address)" --rpc-url $RPC                      # the Safe
cast call $VAULT "hasRole(bytes32,address)(bool)" \
  $(cast keccak "OPERATOR_ROLE") $OPERATOR_ADDRESS --rpc-url $RPC              # true
cast call $VAULT "hasRole(bytes32,address)(bool)" \
  $(cast keccak "RATE_ORACLE_ROLE") $RATE_ORACLE_ADDRESS --rpc-url $RPC        # true
cast call $VAULT "maxPerSettlement()(uint256)" --rpc-url $RPC
cast call $VAULT "quoteConfig()((uint64,uint64,uint64,uint16,uint16))" --rpc-url $RPC
```

The contract should appear as verified on <https://sepolia.basescan.org>.

---

## 5. Configure through the Safe

Admin actions must come from the Safe, not from your own wallet. In the Safe UI, open
**New transaction → Transaction Builder**, paste the vault address, and paste the ABI from
`abi/SettlementVault.json` if it isn't fetched automatically.

Queue and execute two calls:

| Function | Values |
|---|---|
| `setCurrency(bytes3 currency, uint8 decimals, bool enabled)` | `0x4e474e` (that's "NGN"), `2`, `true` |
| `setPartner(address partner, bool allowed)` | your partner test address, `true` |

Currency codes as bytes3: `cast --from-utf8 NGN` → `0x4e474e`.

Verify:

```bash
cast call $VAULT "getCurrency(bytes3)((uint8,bool))" 0x4e474e --rpc-url $RPC   # (2, true)
cast call $VAULT "isPartner(address)(bool)" $PARTNER --rpc-url $RPC            # true
```

---

## 6. Publish a reference rate

From the oracle wallet. The rate is receive-currency units per 1 USD with **8 decimals**, so
NGN 1,645.25 is `164525000000`.

```bash
export ORACLE_KEY=<oracle private key>       # testnet only
cast send $VAULT "setReferenceRate(bytes3,uint256)" 0x4e474e 164525000000 \
  --rpc-url $RPC --private-key $ORACLE_KEY

cast call $VAULT "getReferenceRate(bytes3)((uint256,uint64))" 0x4e474e --rpc-url $RPC
```

Reference rates go stale after an hour by default, so re-run this before testing, or leave the rate
oracle service running (issue #15). A stale rate doesn't block payments; it only raises an alert.

---

## 7. Fund the vault

Get test USDC from <https://faucet.circle.com> (choose **Base Sepolia**), then send some to the vault:

```bash
cast send $USDC "transfer(address,uint256)" $VAULT 10000000000 \
  --rpc-url $RPC --private-key <the wallet holding the faucet USDC>   # 10,000 USDC

cast call $USDC "balanceOf(address)(uint256)" $VAULT --rpc-url $RPC
```

---

## 8. Run the flow by hand

This is the demo. Save every transaction hash.

```bash
export OPERATOR_KEY=<operator private key>
export PARTNER_KEY=<partner private key>
export PARTNER=<partner address>

# Transfer reference and quote id (the backend derives these the same way)
export REF=$(cast keccak "kimana:transfer:demo_001")
export QID=$(cast keccak "quote_demo_001")

# Quote: $1,000 at NGN 1,645.25, $25 fee, expires in 90 seconds
export AMOUNT=1000000000            # 1,000 USDC (6 decimals)
export FEE=25000000                 # 25 USDC
export RATE=164525000000            # 1,645.25 with 8 decimals
export RECV=164525000               # floor(AMOUNT * RATE * 10^2 / 10^14) = NGN 1,645,250.00 in kobo
export EXPIRY=$(( $(cast block latest --field timestamp --rpc-url $RPC) + 90 ))

# 8.1 Lock the accepted quote
cast send $VAULT "lockQuote(bytes32,(bytes32,bytes3,uint64,uint256,uint256,uint256,uint256))" \
  $REF "($QID,0x4e474e,$EXPIRY,$RATE,$AMOUNT,$FEE,$RECV)" \
  --rpc-url $RPC --private-key $OPERATOR_KEY

cast call $VAULT "getQuote(bytes32)((bytes32,bytes3,uint8,bool,uint64,uint64,uint256,uint256,uint256,uint256))" \
  $REF --rpc-url $RPC

# 8.2 Pay the partner
cast send $VAULT "settle(bytes32,address,uint256)" $REF $PARTNER $AMOUNT \
  --rpc-url $RPC --private-key $OPERATOR_KEY

cast call $USDC "balanceOf(address)(uint256)" $PARTNER --rpc-url $RPC     # = AMOUNT

# 8.3 Pretend the naira payout failed: the partner returns the USDC
cast send $USDC "approve(address,uint256)" $VAULT $AMOUNT \
  --rpc-url $RPC --private-key $PARTNER_KEY
cast send $VAULT "returnSettlement(bytes32)" $REF \
  --rpc-url $RPC --private-key $PARTNER_KEY

# 8.4 Refund (on a testnet the partner address stands in for the on-ramp)
cast send $VAULT "refund(bytes32,address)" $REF $PARTNER \
  --rpc-url $RPC --private-key $OPERATOR_KEY

# 8.5 Final state: status 3 = Refunded, nothing reserved
cast call $VAULT "getSettlement(bytes32)((address,uint64,uint8,uint256))" $REF --rpc-url $RPC
cast call $VAULT "reservedForRefunds()(uint256)" --rpc-url $RPC           # 0
```

Worth trying too, to see the guard rails. `cast` prints the revert reason; if it shows raw hex instead,
decode it with `cast 4byte-decode <data>`:

```bash
# An expired quote is rejected
export OLD=$(( $(cast block latest --field timestamp --rpc-url $RPC) - 1 ))
cast send $VAULT "lockQuote(bytes32,(bytes32,bytes3,uint64,uint256,uint256,uint256,uint256))" \
  $(cast keccak "kimana:transfer:demo_002") \
  "($(cast keccak "quote_demo_002"),0x4e474e,$OLD,$RATE,$AMOUNT,$FEE,$RECV)" \
  --rpc-url $RPC --private-key $OPERATOR_KEY     # reverts (QuoteExpired)

# A rate 6% away from the reference is blocked
export BAD_RATE=174396500000
cast send $VAULT "lockQuote(bytes32,(bytes32,bytes3,uint64,uint256,uint256,uint256,uint256))" \
  $(cast keccak "kimana:transfer:demo_003") \
  "($(cast keccak "quote_demo_003"),0x4e474e,$EXPIRY,$BAD_RATE,$AMOUNT,$FEE,174396500)" \
  --rpc-url $RPC --private-key $OPERATOR_KEY     # reverts (RateDivergenceTooHigh)
```

---

## 9. Start the monitor

```bash
cd monitor && npm ci
RPC_URL=https://sepolia.base.org VAULT_ADDRESS=$VAULT MIN_FLOAT_USDC=100 \
  CONFIRMATIONS=2 node index.mjs
```

Add `ALERT_WEBHOOK_URL=<Slack webhook>` to send alerts to a channel. Re-run step 8 and watch the events
and alerts appear. Running it as a service is issue #16.

---

## 10. Record and hand off

Create `deployments/84532.json` (copy `deployments/84532.example.json`) with the vault, USDC, Safe,
operator, pauser and oracle addresses, the deployment block, and the confirmation count. Commit it.

Then tell the backend team:
- the vault address and chain id;
- `abi/SettlementVault.json`;
- [`../fx-quote-criteria.md`](../fx-quote-criteria.md), "What the backend must do to use this".

That unblocks issues #9 and #10.

---

## Mainnet differences (after the audit)

- Admin is a production Safe with hardware-wallet signers.
- Operator and rate-oracle keys come from the custody provider (issue #11); no raw keys anywhere.
- Limits start small and rise with experience.
- `CONFIRMATIONS` of 5 or more in the monitor.
- Deploy only after the external audit (#14) and the regulatory and partner approvals the PRD requires.
