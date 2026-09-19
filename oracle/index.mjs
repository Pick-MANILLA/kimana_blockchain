#!/usr/bin/env node
// Kimana rate oracle (issue #15).
//
// Publishes an independent FX reference rate per registered currency to SettlementVault, so that
// `lockQuote` can compare the customer-facing rate against a source the quoting provider does not control.
//
// See README.md for env and rationale.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createPublicClient, createWalletClient, http, hexToString, stringToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const here = dirname(fileURLToPath(import.meta.url));
const vaultAbi = JSON.parse(readFileSync(join(here, "..", "abi", "SettlementVault.json"), "utf8"));

const RATE_DECIMALS = 8n;
const MAX_RATE = 10n ** 20n; // FxMath.MAX_RATE
const BPS = 10_000n;

// Chain ids where a raw private key must never be used.
const MAINNETS = new Set([1, 8453, 42161, 137, 10, 56]);

const env = (k, d) => process.env[k] ?? d;
const ONCE = process.argv.includes("--once");
const DRY_RUN = env("DRY_RUN", "") === "1";

const RPC_URL = env("RPC_URL");
const VAULT_ADDRESS = env("VAULT_ADDRESS");
const CURRENCIES = env("CURRENCIES", "NGN").split(",").map((c) => c.trim().toUpperCase()).filter(Boolean);
const RATE_API_URL = env("RATE_API_URL", "https://open.er-api.com/v6/latest/USD");
const POLL_MS = Number(env("POLL_MS", "60000"));
const MAX_AGE_MS = BigInt(env("MAX_AGE_MS", "1500000")); // 25 minutes
const MOVE_BPS = BigInt(env("MOVE_BPS", "50")); // 0.5%
const MAX_JUMP_BPS = BigInt(env("MAX_JUMP_BPS", "1000")); // 10%
const ALERT_WEBHOOK_URL = env("ALERT_WEBHOOK_URL");
const CUSTODY_SIGN_URL = env("CUSTODY_SIGN_URL");

// ---------------------------------------------------------------------------
// Integer-only rate handling
// ---------------------------------------------------------------------------

/**
 * Scale a decimal *string* to 8 decimals without ever creating a float.
 * "1645.25" -> 164525000000n   "0.000123456789" -> 12345n (truncated, never rounded up)
 */
export function toScaled8(text) {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(text.trim());
  if (!m) throw new Error(`not a decimal number: ${text}`);
  const whole = m[1];
  const frac = (m[2] ?? "").padEnd(Number(RATE_DECIMALS), "0").slice(0, Number(RATE_DECIMALS));
  return BigInt(whole) * 10n ** RATE_DECIMALS + BigInt(frac);
}

/** Deviation of `a` from `b` in basis points, rounded up, mirroring FxMath.deviationBps. */
export function deviationBps(a, b) {
  if (b === 0n) return BPS;
  const diff = a > b ? a - b : b - a;
  return (diff * BPS + b - 1n) / b;
}

/**
 * Pull `"NGN": 1645.25` out of a raw JSON body as text. Deliberately not JSON.parse: that turns the
 * number into a float and loses exactness before we can scale it.
 */
export function extractRateText(body, code) {
  const re = new RegExp(`"${code}"\\s*:\\s*(\\d+(?:\\.\\d+)?)`);
  const m = re.exec(body);
  if (!m) throw new Error(`no rate for ${code} in the response`);
  return m[1];
}

const bytes3 = (code) => stringToHex(code, { size: 3 });
const fromBytes3 = (hex) => hexToString(hex).replace(/\0/g, "");
const fmt = (r) => `${r / 10n ** RATE_DECIMALS}.${(r % 10n ** RATE_DECIMALS).toString().padStart(8, "0")}`;

// ---------------------------------------------------------------------------
// Logging and alerting
// ---------------------------------------------------------------------------

const log = (o) => console.log(JSON.stringify({ ts: new Date().toISOString(), ...o }));

async function alert(level, message) {
  log({ level, alert: message });
  if (!ALERT_WEBHOOK_URL) return;
  try {
    await fetch(ALERT_WEBHOOK_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: `[rate-oracle][${level}] ${message}` }),
    });
  } catch (e) {
    log({ level: "error", message: `webhook failed: ${e.message}` });
  }
}

async function withRetry(label, fn, attempts = 3) {
  let lastErr;
  for (let i = 1; i <= attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      log({ level: "warn", message: `${label} failed (attempt ${i}/${attempts}): ${e.message}` });
      if (i < attempts) await new Promise((r) => setTimeout(r, 1000 * 2 ** (i - 1)));
    }
  }
  throw lastErr;
}

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------

// Created lazily so the pure helpers above can be imported (and unit-tested) without any env at all.
let _publicClient;
function client() {
  if (!_publicClient) _publicClient = createPublicClient({ transport: http(RPC_URL) });
  return _publicClient;
}

async function makeSigner(chainId) {
  if (DRY_RUN) return null;
  if (CUSTODY_SIGN_URL) {
    // Production path (#11): the custody provider holds RATE_ORACLE_ROLE and signs on request.
    return {
      kind: "custody",
      async send(currency, rate) {
        const res = await fetch(CUSTODY_SIGN_URL, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            chainId,
            to: VAULT_ADDRESS,
            function: "setReferenceRate(bytes3,uint256)",
            args: [currency, rate.toString()],
          }),
        });
        if (!res.ok) throw new Error(`custody signer returned ${res.status}`);
        const { txHash } = await res.json();
        return txHash;
      },
    };
  }

  const key = env("ORACLE_PRIVATE_KEY");
  if (!key) throw new Error("set ORACLE_PRIVATE_KEY (testnets) or CUSTODY_SIGN_URL (production)");
  if (MAINNETS.has(chainId)) {
    throw new Error(
      `refusing to use a raw private key on chain ${chainId}. Use CUSTODY_SIGN_URL (issue #11).`
    );
  }
  const account = privateKeyToAccount(key);
  const wallet = createWalletClient({ account, transport: http(RPC_URL) });
  return {
    kind: `key:${account.address}`,
    async send(currency, rate) {
      return wallet.writeContract({
        address: VAULT_ADDRESS,
        abi: vaultAbi,
        functionName: "setReferenceRate",
        args: [currency, rate],
        chain: null,
      });
    },
  };
}

// ---------------------------------------------------------------------------
// One pass
// ---------------------------------------------------------------------------

async function fetchBody() {
  return withRetry("rate API", async () => {
    const res = await fetch(RATE_API_URL, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) throw new Error(`rate API returned ${res.status}`);
    return res.text();
  });
}

async function tick(signer) {
  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  let body;
  try {
    body = await fetchBody();
  } catch (e) {
    await alert("critical", `could not reach the rate API: ${e.message}`);
    return;
  }

  for (const code of CURRENCIES) {
    try {
      const cur = bytes3(code);
      const info = await client().readContract({
        address: VAULT_ADDRESS, abi: vaultAbi, functionName: "getCurrency", args: [cur],
      });
      if (!info.enabled) {
        log({ level: "info", currency: code, skipped: "not enabled on-chain" });
        continue;
      }

      const next = toScaled8(extractRateText(body, code));
      if (next === 0n || next > MAX_RATE) {
        await alert("critical", `${code}: refusing an out-of-range rate ${next}`);
        continue;
      }

      const onchain = await client().readContract({
        address: VAULT_ADDRESS, abi: vaultAbi, functionName: "getReferenceRate", args: [cur],
      });
      const current = BigInt(onchain.rate);
      const ageMs = current === 0n ? null : (nowSec - BigInt(onchain.updatedAt)) * 1000n;
      const move = current === 0n ? null : deviationBps(next, current);

      // A huge jump is more likely to be a bad response than a real market move. Publishing it would
      // poison the reference and start blocking honest quotes, so a human decides instead.
      if (move !== null && move > MAX_JUMP_BPS) {
        await alert(
          "critical",
          `${code}: rate jumped ${move} bps (${fmt(current)} -> ${fmt(next)}), not publishing. ` +
            `Check the source, then raise MAX_JUMP_BPS or publish manually if it is real.`
        );
        continue;
      }

      const stale = ageMs === null || ageMs >= MAX_AGE_MS;
      const moved = move !== null && move >= MOVE_BPS;
      if (!stale && !moved) {
        log({ level: "info", currency: code, rate: fmt(next), ageMs: Number(ageMs), moveBps: Number(move), action: "hold" });
        continue;
      }

      const reason = stale ? (ageMs === null ? "no reference on-chain" : `age ${ageMs}ms`) : `moved ${move} bps`;
      if (DRY_RUN) {
        log({ level: "info", currency: code, rate: fmt(next), reason, action: "would publish (DRY_RUN)" });
        continue;
      }

      const txHash = await withRetry(`${code} setReferenceRate`, () => signer.send(cur, next));
      log({ level: "info", currency: code, rate: fmt(next), reason, action: "published", txHash });
    } catch (e) {
      await alert("critical", `${code}: could not update the reference rate: ${e.message}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  if (!RPC_URL || !VAULT_ADDRESS) throw new Error("RPC_URL and VAULT_ADDRESS are required");
  const chainId = await client().getChainId();
  const signer = await makeSigner(chainId);
  log({
    level: "info",
    message: "rate oracle starting",
    chainId, vault: VAULT_ADDRESS, currencies: CURRENCIES,
    source: RATE_API_URL, signer: signer?.kind ?? "none (DRY_RUN)",
    maxAgeMs: Number(MAX_AGE_MS), moveBps: Number(MOVE_BPS), maxJumpBps: Number(MAX_JUMP_BPS),
  });

  await tick(signer);
  if (ONCE) return;

  // Heartbeat so a stopped oracle is visible in logs, same idea as the monitor's.
  setInterval(() => log({ level: "info", heartbeat: true, currencies: CURRENCIES }), 300_000).unref?.();
  for (;;) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    await tick(signer);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch(async (e) => {
    await alert("critical", `rate oracle stopped: ${e.message}`);
    process.exit(1);
  });
}

export { fromBytes3 };
