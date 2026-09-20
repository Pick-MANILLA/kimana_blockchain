/**
 * dfns-poc.mjs — Dfns custody PoC for Kimana SettlementVault
 *
 * Demonstrates the OPERATOR_ROLE flow against a deployed SettlementVault on
 * Base Sepolia, using the Dfns custody API for all transaction signing.
 *
 * Steps:
 *   1. Oracle wallet publishes a reference rate for NGN via setReferenceRate.
 *   2. Operator wallet locks a quote via lockQuote.
 *   3. Operator wallet settles the quote via settle.
 *   4. Read-only verification that the settlement state is Settled on-chain.
 *
 * IMPORTANT:
 *   - No private keys appear here. All signing is done inside Dfns's MPC
 *     network. The only secrets are the Dfns service-account credential key
 *     (used to authenticate with the Dfns API, not a blockchain key) and
 *     the short-lived auth token.
 *   - Run `cp .env.example .env` and fill in your values before running.
 *   - Requires: Node 20+, a Dfns sandbox account, a deployed vault on
 *     Base Sepolia with the operator and oracle wallet addresses granted
 *     their respective roles by the admin.
 *
 * Usage:
 *   npm install
 *   node dfns-poc.mjs
 */

import { createHash, createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { keccak256, toUtf8Bytes, AbiCoder, Contract, JsonRpcProvider } from "ethers";
import "dotenv/config";

// ---------------------------------------------------------------------------
// Config — loaded from .env (see .env.example)
// ---------------------------------------------------------------------------

const {
  DFNS_APP_ID,
  DFNS_CRED_ID,
  DFNS_APP_PRIVATE_KEY_PATH,
  DFNS_AUTH_TOKEN,
  DFNS_BASE_URL = "https://api.dfns.io",
  OPERATOR_WALLET_ID,
  ORACLE_WALLET_ID,
  VAULT_ADDRESS,
  PARTNER_ADDRESS,
  RPC_URL = "https://sepolia.base.org",
} = process.env;

for (const [name, val] of Object.entries({
  DFNS_APP_ID,
  DFNS_CRED_ID,
  DFNS_APP_PRIVATE_KEY_PATH,
  DFNS_AUTH_TOKEN,
  OPERATOR_WALLET_ID,
  ORACLE_WALLET_ID,
  VAULT_ADDRESS,
  PARTNER_ADDRESS,
})) {
  if (!val) throw new Error(`Missing required environment variable: ${name}`);
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Network name used by Dfns for Base Sepolia. */
const DFNS_NETWORK = "BaseSepolia";

/** ISO-4217 currency code bytes3 "NGN" = 0x4e474e */
const NGN = "0x4e474e";

/**
 * Reference rate: 1,645.25 NGN/USD with 8 decimal places.
 * Must match the formula used on-chain: receiveMinor = usdcAmount * rate * 10^ngn_decimals / 10^14
 * (6 USDC decimals + 8 rate decimals = 14)
 */
const NGN_RATE = 164_525_000_000n;

/**
 * Settlement: $1.00 USDC = 1_000_000 (6 dp).
 * Kept small so the PoC passes within testnet faucet limits.
 */
const USDC_AMOUNT = 1_000_000n; // $1.00

/** Fee: $0.00 for simplicity. The vault allows zero fees. */
const FEE_USDC = 0n;

/**
 * Expected NGN minor units (kobo):
 *   receiveMinor = floor(1_000_000 * 164_525_000_000 * 10^2 / 10^14)
 *               = floor(164_525_000_000_000_000 / 100_000_000_000_000)
 *               = 1645
 */
const RECEIVE_AMOUNT_MINOR = (USDC_AMOUNT * NGN_RATE * 100n) / 10n ** 14n;

/** SettlementVault.Status enum: None=0, Settled=1, Returned=2, Refunded=3 */
const STATUS = { None: 0, Settled: 1, Returned: 2, Refunded: 3 };

// ---------------------------------------------------------------------------
// Minimal ABI (lock, settle, setReferenceRate, getSettlement)
// ---------------------------------------------------------------------------

import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const VAULT_ABI = require("./abi.json");

// ---------------------------------------------------------------------------
// Dfns API helpers
// ---------------------------------------------------------------------------

/**
 * Sign a Dfns API request body using the service-account's PKCS#8 key.
 * Dfns requires a `X-DFNS-USERACTION` header containing a base64url-encoded
 * JSON object signed with the credential private key.
 *
 * @param {string} body  JSON request body string
 * @returns {{ userActionSignature: string, userActionChallenge: string }}
 */
async function signUserAction(body) {
  const privateKeyPem = readFileSync(DFNS_APP_PRIVATE_KEY_PATH, "utf8");

  // Step 1: request a challenge from Dfns
  const challengeRes = await fetch(`${DFNS_BASE_URL}/auth/action/init`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${DFNS_AUTH_TOKEN}`,
      "X-DFNS-APPID": DFNS_APP_ID,
    },
    body: JSON.stringify({ userActionPayload: body }),
  });

  if (!challengeRes.ok) {
    const err = await challengeRes.text();
    throw new Error(`Dfns /auth/action/init failed: ${err}`);
  }

  const { challenge, allowCredentials } = await challengeRes.json();

  // Step 2: sign the challenge with the service-account credential key
  const signerInput = `${challenge}.${Buffer.from(body).toString("base64url")}`;
  const sign = createSign("SHA256");
  sign.update(signerInput);
  const signature = sign.sign(privateKeyPem, "base64url");

  return {
    challengeIdentifier: challenge,
    firstFactor: {
      kind: "Key",
      credentialAssertion: {
        credId: DFNS_CRED_ID,
        clientData: Buffer.from(signerInput).toString("base64url"),
        signature,
      },
    },
  };
}

/**
 * Call the Dfns API.
 *
 * @param {string} method  HTTP method
 * @param {string} path    API path (e.g. "/wallets/{id}/transactions")
 * @param {object} [body]  Request body (will be JSON-stringified)
 * @param {boolean} [requiresAction]  True for state-mutating calls (sign required)
 * @returns {Promise<object>} Parsed JSON response
 */
async function dfns(method, path, body, requiresAction = false) {
  const url = `${DFNS_BASE_URL}${path}`;
  const bodyStr = body ? JSON.stringify(body) : undefined;

  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${DFNS_AUTH_TOKEN}`,
    "X-DFNS-APPID": DFNS_APP_ID,
  };

  if (requiresAction && bodyStr) {
    const assertion = await signUserAction(bodyStr);
    headers["X-DFNS-USERACTION"] = Buffer.from(JSON.stringify(assertion)).toString(
      "base64url"
    );
  }

  const res = await fetch(url, { method, headers, body: bodyStr });
  const json = await res.json();

  if (!res.ok) {
    throw new Error(
      `Dfns API error ${res.status} on ${method} ${path}: ${JSON.stringify(json)}`
    );
  }

  return json;
}

// ---------------------------------------------------------------------------
// Transaction helpers
// ---------------------------------------------------------------------------

/**
 * Broadcast a transaction from a Dfns wallet and wait for confirmation.
 *
 * @param {string} walletId  Dfns wallet ID
 * @param {string} to        Destination address (hex)
 * @param {string} data      ABI-encoded calldata (hex, 0x-prefixed)
 * @param {string} label     Human-readable label for logging
 * @returns {Promise<object>} Confirmed transaction object from Dfns
 */
async function sendTx(walletId, to, data, label) {
  console.log(`  → broadcasting ${label}…`);

  const tx = await dfns(
    "POST",
    `/wallets/${walletId}/transactions`,
    {
      kind: "Transaction",
      transaction: { to, data },
      // gasLimit, maxFeePerGas, nonce are auto-estimated by Dfns when omitted
    },
    true /* requiresAction */
  );

  const txId = tx.id;
  console.log(`    Dfns tx id: ${txId}`);

  // Poll until confirmed or failed (Dfns transactions are async)
  for (let i = 0; i < 60; i++) {
    await sleep(3000);
    const status = await dfns("GET", `/wallets/${walletId}/transactions/${txId}`);

    if (status.status === "Confirmed") {
      console.log(`    on-chain hash: ${status.txHash}  status: Confirmed ✓`);
      return status;
    }

    if (status.status === "Failed" || status.status === "Rejected") {
      throw new Error(
        `Transaction ${label} ${status.status}: ${JSON.stringify(status.error ?? status.rejectionReason)}`
      );
    }

    process.stdout.write(".");
  }

  throw new Error(`Timed out waiting for confirmation of ${label}`);
}

// ---------------------------------------------------------------------------
// FxMath (JS port of the on-chain formula)
// ---------------------------------------------------------------------------

/**
 * Compute the counterparty receive amount in minor units (integer only).
 * Must exactly match FxMath.receiveAmount in the Solidity contract:
 *   receiveMinor = floor(usdcAmount * rate * 10^receiveDecimals / 10^14)
 *
 * @param {bigint} usdcAmount       USDC in base units (6 dp)
 * @param {bigint} rate             Rate with 8 dp (receive-currency major/USD)
 * @param {number} receiveDecimals  Minor-unit exponent of receive currency
 * @returns {bigint}
 */
function receiveAmount(usdcAmount, rate, receiveDecimals) {
  // 10^14 = 10^(USDC_DECIMALS=6 + RATE_DECIMALS=8)
  return (usdcAmount * rate * 10n ** BigInt(receiveDecimals)) / 10n ** 14n;
}

// ---------------------------------------------------------------------------
// TransferRef (JS port of TransferRef.fromTransferId)
// ---------------------------------------------------------------------------

/**
 * Compute the ref for a backend transfer id.
 *
 * @param {string} transferId  Backend transfer UUID or short id
 * @returns {string} bytes32 hex (0x-prefixed)
 */
function transferRef(transferId) {
  return keccak256(toUtf8Bytes(`kimana:transfer:${transferId}`));
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function hex32(str) {
  // Right-pad a short string to 32 bytes (for quoteId construction from UUID)
  const buf = Buffer.alloc(32);
  Buffer.from(str).copy(buf);
  return "0x" + buf.toString("hex");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const vault = new Contract(VAULT_ADDRESS, VAULT_ABI, provider);
  const coder = AbiCoder.defaultAbiCoder();

  // Use a timestamp-based transfer id to avoid collisions across runs.
  const transferId = `poc-${Date.now()}`;
  const ref = transferRef(transferId);
  const quoteId = keccak256(toUtf8Bytes(`quote-${transferId}`));

  const ngn_decimals = 2; // NGN has 2 minor-unit digits (kobo)
  const receiveMinor = receiveAmount(USDC_AMOUNT, NGN_RATE, ngn_decimals);

  // expiresAt: 5 minutes from now (well within the 15-minute maxQuoteTtl default)
  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const expiresAt = nowSec + 300n;

  console.log("Kimana SettlementVault — Dfns PoC");
  console.log(`  vault:        ${VAULT_ADDRESS}`);
  console.log(`  transfer id:  ${transferId}`);
  console.log(`  ref:          ${ref}`);
  console.log(`  quoteId:      ${quoteId}`);
  console.log(`  USDC amount:  ${USDC_AMOUNT} (${Number(USDC_AMOUNT) / 1e6} USDC)`);
  console.log(`  NGN rate:     ${NGN_RATE} (1,645.25 NGN/USD, 8 dp)`);
  console.log(`  NGN receive:  ${receiveMinor} kobo`);
  console.log(`  expiresAt:    ${expiresAt} (unix)`);
  console.log();

  // ── Step 1: Oracle publishes the reference rate ──────────────────────────

  console.log("[1/4] Oracle sets reference rate for NGN…");

  // setReferenceRate(bytes3 currency, uint256 rate)
  const setRateData = vault.interface.encodeFunctionData("setReferenceRate", [
    NGN,
    NGN_RATE,
  ]);

  await sendTx(ORACLE_WALLET_ID, VAULT_ADDRESS, setRateData, "setReferenceRate");
  console.log();

  // ── Step 2: Operator locks the quote ─────────────────────────────────────

  console.log("[2/4] Operator locks quote…");

  // lockQuote(bytes32 ref, QuoteInput q)
  const lockData = vault.interface.encodeFunctionData("lockQuote", [
    ref,
    {
      quoteId,
      receiveCurrency: NGN,
      expiresAt,
      rate: NGN_RATE,
      usdcAmount: USDC_AMOUNT,
      feeUsdc: FEE_USDC,
      receiveAmountMinor: receiveMinor,
    },
  ]);

  const lockTx = await sendTx(OPERATOR_WALLET_ID, VAULT_ADDRESS, lockData, "lockQuote");

  // Decode the QuoteLocked event from the receipt log (informational only)
  if (lockTx.receipt?.logs) {
    try {
      const iface = vault.interface;
      for (const log of lockTx.receipt.logs) {
        try {
          const parsed = iface.parseLog(log);
          if (parsed?.name === "QuoteLocked") {
            console.log(
              `    QuoteLocked event: rate=${parsed.args.rate} usdcAmount=${parsed.args.usdcAmount} receiveAmountMinor=${parsed.args.receiveAmountMinor}`
            );
          }
        } catch {
          // ignore non-vault logs
        }
      }
    } catch {
      // receipt logs not available in this Dfns API version — skip
    }
  }

  console.log();

  // ── Step 3: Operator settles the quote ───────────────────────────────────

  console.log("[3/4] Operator settles…");
  console.log(`  partner: ${PARTNER_ADDRESS}`);

  // settle(bytes32 ref, address partner, uint256 amount)
  const settleData = vault.interface.encodeFunctionData("settle", [
    ref,
    PARTNER_ADDRESS,
    USDC_AMOUNT,
  ]);

  await sendTx(OPERATOR_WALLET_ID, VAULT_ADDRESS, settleData, "settle");
  console.log();

  // ── Step 4: Verify on-chain state ─────────────────────────────────────────

  console.log("[4/4] Verifying settlement state on-chain…");

  const settlement = await vault.getSettlement(ref);
  const statusName =
    Object.entries(STATUS).find(([, v]) => v === Number(settlement.status))?.[0] ??
    "Unknown";

  console.log(`  settlement.status  = ${statusName} (${settlement.status})`);
  console.log(`  settlement.partner = ${settlement.partner}`);
  console.log(
    `  settlement.amount  = ${settlement.amount} (${Number(settlement.amount) / 1e6} USDC)`
  );
  console.log(`  settlement.settledAt = ${settlement.settledAt}`);

  if (Number(settlement.status) !== STATUS.Settled) {
    throw new Error(
      `Expected Settled(1) but got ${statusName}(${settlement.status})`
    );
  }

  console.log();
  console.log("✓ PoC complete: lockQuote → settle confirmed on Base Sepolia via Dfns.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
