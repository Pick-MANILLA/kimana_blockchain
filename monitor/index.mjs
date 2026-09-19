#!/usr/bin/env node
// SettlementVault monitor.
//
// Reads vault events from an RPC endpoint, prints one JSON line per event, and raises alerts for
// anything ops must look at: FX provider divergence, stale reference rates, pauses, payout failures,
// role changes and low USDC float. Alerts are also POSTed to ALERT_WEBHOOK_URL when it is set
// (Slack-compatible `{ text }` body).
//
// Usage:
//   RPC_URL=... VAULT_ADDRESS=0x... node index.mjs            # follow the chain
//   RPC_URL=... VAULT_ADDRESS=0x... node index.mjs --once     # scan once, print summary, exit
//
// Env:
//   RPC_URL, VAULT_ADDRESS                (required)
//   START_BLOCK        first block to scan (default: latest - 5000, or saved state)
//   CONFIRMATIONS      blocks to wait before reporting (default 0)
//   POLL_MS            polling interval in follow mode (default 15000)
//   MIN_FLOAT_USDC     alert if free USDC (balance - reserved refunds) drops below this many whole USDC
//   ALERT_WEBHOOK_URL  optional webhook for all alerts (Slack-compatible {text})
//   PAGER_WEBHOOK_URL  optional second webhook that receives CRITICAL alerts only (page on-call)
//   NETWORK_LABEL      prefix on every alert, e.g. "base-sepolia", so one channel can carry many networks
//   HEALTH_PORT        serve GET /health on this port (503 once the last successful tick goes stale)
//   HEALTH_MAX_STALE_MS  how old the last tick may be before /health fails (default max(POLL_MS*4, 120s))
//   HEARTBEAT_MS       heartbeat log interval (default 300000)
//   STATE_FILE         where the last processed block is stored (default .monitor-state.json)
//   WATCH_REVERTS      "0" to disable scanning for reverted vault transactions (default on). Reverted
//                      transactions leave no events, so this is how blocked quotes (RateDivergenceTooHigh,
//                      QuoteExpired, ...) and failed settlements are alerted.
//   MAX_REVERT_SCAN    most blocks to scan per tick for reverted transactions (default 2000)

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient,
  http,
  decodeEventLog,
  decodeFunctionData,
  decodeErrorResult,
  erc20Abi,
  formatUnits,
  getAddress,
  hexToString,
} from "viem";

const here = dirname(fileURLToPath(import.meta.url));
const vaultAbi = JSON.parse(readFileSync(join(here, "..", "abi", "SettlementVault.json"), "utf8"));

// Event name -> alert level. Anything not listed is "info".
export const LEVELS = {
  Paused: "critical",
  RateDivergence: "warning",
  ReferenceRateStale: "warning",
  SettlementReturned: "warning", // off-chain payout failed
  RoleGranted: "warning",
  RoleRevoked: "warning",
  DefaultAdminTransferScheduled: "warning",
  DefaultAdminDelayChangeScheduled: "warning",
  PartnerUpdated: "warning",
  LimitsUpdated: "warning",
  QuoteConfigUpdated: "warning",
  Swept: "warning",
  Unpaused: "warning",
};

const args = process.argv.slice(2);
const once = args.includes("--once");

function env(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === "") {
    if (fallback === undefined) throw new Error(`Missing env ${name}`);
    return fallback;
  }
  return v;
}

const jsonSafe = (_k, v) => (typeof v === "bigint" ? v.toString() : v);

// bytes3 currency codes are easier to read as text ("NGN").
function prettyArgs(args) {
  const out = {};
  for (const [k, v] of Object.entries(args ?? {})) {
    out[k] = typeof v === "string" && /^0x[0-9a-f]{6}$/i.test(v) ? hexToString(v).replace(/\0/g, "") : v;
  }
  return out;
}

function describe(e) {
  const a = e.args;
  switch (e.event) {
    case "RateDivergence":
      return `FX divergence ${a.deviationBps} bps on ${a.currency} for ref ${a.ref} (quoted ${a.quotedRate}, reference ${a.referenceRate})`;
    case "ReferenceRateStale":
      return `No fresh reference rate for ${a.currency}; divergence not checked for ref ${a.ref}`;
    case "Paused":
      return `SettlementVault PAUSED by ${a.account}`;
    case "SettlementReturned":
      return `Payout failed: partner ${a.partner} returned ${formatUnits(a.amount, 6)} USDC for ref ${a.ref}`;
    default:
      return `${e.event} ${JSON.stringify(a, jsonSafe)}`;
  }
}

async function post(url, text) {
  try {
    await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text }),
    });
  } catch (err) {
    console.error(JSON.stringify({ level: "error", message: `webhook failed: ${err.message}` }));
  }
}

/**
 * `webhook` is either a URL string (the original form) or a routing object:
 *   { url, criticalUrl, label }
 * Critical alerts go to BOTH, so the team channel keeps the full history while on-call gets paged.
 * `label` prefixes every message, so one Slack channel can carry several networks legibly.
 */
async function sendAlert(webhook, line) {
  if (!webhook) return;
  const cfg = typeof webhook === "string" ? {url: webhook} : webhook;
  const text = `${cfg.label ? `[${cfg.label}]` : ""}[${line.level.toUpperCase()}] ${line.message}`;
  const targets = new Set();
  if (cfg.url) targets.add(cfg.url);
  if (line.level === "critical" && cfg.criticalUrl) targets.add(cfg.criticalUrl);
  for (const target of targets) await post(target, text);
}

export async function scan({ client, vault, fromBlock, toBlock, webhook, emit = console.log }) {
  const counts = {};
  let alerts = 0;
  if (fromBlock > toBlock) return { counts, alerts };
  const logs = await client.getLogs({ address: vault, fromBlock, toBlock });
  for (const log of logs) {
    let decoded;
    try {
      decoded = decodeEventLog({ abi: vaultAbi, data: log.data, topics: log.topics });
    } catch {
      continue;
    }
    const event = decoded.eventName;
    const level = LEVELS[event] ?? "info";
    const pretty = { event, args: prettyArgs(decoded.args) };
    const line = {
      ts: new Date().toISOString(),
      level,
      event,
      block: log.blockNumber,
      tx: log.transactionHash,
      args: pretty.args,
      message: describe(pretty),
    };
    counts[event] = (counts[event] ?? 0) + 1;
    emit(JSON.stringify(line, jsonSafe));
    if (level !== "info") {
      alerts++;
      await sendAlert(webhook, line);
    }
  }
  return { counts, alerts };
}

// Reverts that mean something is wrong with pricing or funds, not just a retryable hiccup.
export const CRITICAL_REVERTS = new Set([
  "RateDivergenceTooHigh",
  "ExceedsDailyLimit",
  "InsufficientFreeBalance",
  "QuoteLockTooOld",
  "SettleAmountMismatch",
  "ReceiveAmountMismatch",
  "AccessControlUnauthorizedAccount",
]);

function findRevertData(err) {
  for (let e = err; e; e = e.cause) {
    if (typeof e.data === "string" && e.data.startsWith("0x")) return e.data;
    if (e.data && typeof e.data.data === "string") return e.data.data;
  }
  const m = /(0x[0-9a-fA-F]{8,})/.exec(String(err?.details ?? err?.message ?? ""));
  return m ? m[1] : undefined;
}

export async function scanReverts({ client, vault, fromBlock, toBlock, webhook, maxBlocks = 2000n, emit = console.log }) {
  let alerts = 0;
  if (fromBlock > toBlock) return alerts;
  const start = toBlock - fromBlock + 1n > maxBlocks ? toBlock - maxBlocks + 1n : fromBlock;
  for (let n = start; n <= toBlock; n++) {
    const block = await client.getBlock({ blockNumber: n, includeTransactions: true });
    for (const tx of block.transactions) {
      if (!tx.to || getAddress(tx.to) !== vault) continue;
      const receipt = await client.getTransactionReceipt({ hash: tx.hash });
      if (receipt.status !== "reverted") continue;

      let fn = "unknown";
      let fnArgs;
      try {
        const d = decodeFunctionData({ abi: vaultAbi, data: tx.input });
        fn = d.functionName;
        fnArgs = d.args;
      } catch {}

      // Replay against the parent block to recover the custom error (best effort).
      let error = "unknown";
      let errorArgs;
      try {
        await client.call({ account: tx.from, to: tx.to, data: tx.input, blockNumber: n - 1n });
      } catch (err) {
        const data = findRevertData(err);
        if (data) {
          try {
            const e = decodeErrorResult({ abi: vaultAbi, data });
            error = e.errorName;
            errorArgs = e.args;
          } catch {}
        }
      }

      const level = CRITICAL_REVERTS.has(error) ? "critical" : "warning";
      const line = {
        ts: new Date().toISOString(),
        level,
        event: "TransactionReverted",
        block: n,
        tx: tx.hash,
        args: { from: tx.from, function: fn, error, errorArgs, input: fnArgs },
        message: `Vault call ${fn} from ${tx.from} reverted with ${error}`,
      };
      emit(JSON.stringify(line, jsonSafe));
      alerts++;
      await sendAlert(webhook, line);
    }
  }
  return alerts;
}

export async function checkFloat({ client, vault, minFloatUsdc, webhook, emit = console.log }) {
  if (minFloatUsdc === undefined) return 0;
  const [asset, reserved, paused] = await Promise.all([
    client.readContract({ address: vault, abi: vaultAbi, functionName: "asset" }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "reservedForRefunds" }),
    client.readContract({ address: vault, abi: vaultAbi, functionName: "paused" }),
  ]);
  const balance = await client.readContract({
    address: asset,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
  });
  const free = balance - reserved;
  const min = BigInt(minFloatUsdc) * 1_000_000n;
  const line = {
    ts: new Date().toISOString(),
    level: free < min ? "warning" : "info",
    event: "FloatCheck",
    args: { balance, reserved, free, min, paused },
    message: `Vault free float ${formatUnits(free, 6)} USDC (minimum ${minFloatUsdc})${paused ? ", vault is paused" : ""}`,
  };
  emit(JSON.stringify(line, jsonSafe));
  if (line.level !== "info") {
    await sendAlert(webhook, line);
    return 1;
  }
  return 0;
}

async function main() {
  const client = createPublicClient({ transport: http(env("RPC_URL")) });
  const vault = getAddress(env("VAULT_ADDRESS"));
  const confirmations = BigInt(env("CONFIRMATIONS", "0"));
  const pollMs = Number(env("POLL_MS", "15000"));
  const label = process.env.NETWORK_LABEL || undefined;
  const webhookUrl = process.env.ALERT_WEBHOOK_URL || undefined;
  const criticalUrl = process.env.PAGER_WEBHOOK_URL || undefined;
  const webhook = webhookUrl || criticalUrl ? {url: webhookUrl, criticalUrl, label} : undefined;
  const minFloatUsdc = process.env.MIN_FLOAT_USDC || undefined;
  const stateFile = env("STATE_FILE", join(here, ".monitor-state.json"));
  const watchReverts = env("WATCH_REVERTS", "1") !== "0";
  const maxRevertScan = BigInt(env("MAX_REVERT_SCAN", "2000"));

  const latest = await client.getBlockNumber();
  let fromBlock;
  if (process.env.START_BLOCK) fromBlock = BigInt(process.env.START_BLOCK);
  else if (!once && existsSync(stateFile)) fromBlock = BigInt(JSON.parse(readFileSync(stateFile, "utf8")).next);
  else fromBlock = latest > 5000n ? latest - 5000n : 0n;

  const tick = async () => {
    const head = await client.getBlockNumber();
    const toBlock = head > confirmations ? head - confirmations : 0n;
    const result = await scan({ client, vault, fromBlock, toBlock, webhook });
    const revertAlerts = watchReverts
      ? await scanReverts({ client, vault, fromBlock, toBlock, webhook, maxBlocks: maxRevertScan })
      : 0;
    const floatAlerts = await checkFloat({ client, vault, minFloatUsdc, webhook });
    if (toBlock >= fromBlock) fromBlock = toBlock + 1n;
    if (!once) writeFileSync(stateFile, JSON.stringify({ next: fromBlock.toString() }));
    return { ...result, alerts: result.alerts + revertAlerts + floatAlerts };
  };

  if (once) {
    const { counts, alerts } = await tick();
    console.log(JSON.stringify({ level: "summary", counts, alerts }));
    return;
  }

  // Health signal, so a monitor that has silently stopped is itself noticed (#16).
  const health = {startedAt: Date.now(), lastOkAt: 0, lastBlock: null, ticks: 0, errors: 0, alerts: 0, label};
  const healthPort = Number(process.env.HEALTH_PORT || 0);
  const maxStaleMs = Number(process.env.HEALTH_MAX_STALE_MS || Math.max(pollMs * 4, 120_000));
  if (healthPort) startHealthServer(healthPort, health, maxStaleMs);

  const heartbeatMs = Number(process.env.HEARTBEAT_MS || 300_000);
  const heartbeat = setInterval(
    () => console.log(JSON.stringify({ ts: new Date().toISOString(), level: "info", heartbeat: true, ...health })),
    heartbeatMs
  );
  heartbeat.unref?.();

  for (;;) {
    try {
      const { alerts } = await tick();
      health.lastOkAt = Date.now();
      health.lastBlock = fromBlock.toString();
      health.ticks += 1;
      health.alerts += alerts;
    } catch (err) {
      health.errors += 1;
      console.error(JSON.stringify({ ts: new Date().toISOString(), level: "error", message: err.message }));
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
}

/**
 * GET /health -> 200 while the last successful tick is recent, 503 once it is not.
 * Point a container healthcheck or an uptime probe at it: a monitor nobody watches is not monitoring.
 */
function startHealthServer(port, health, maxStaleMs) {
  createServer((req, res) => {
    const age = health.lastOkAt ? Date.now() - health.lastOkAt : null;
    const ok = age !== null && age <= maxStaleMs;
    res.writeHead(ok ? 200 : 503, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok, ageMs: age, maxStaleMs, ...health }));
  })
    .listen(port, () => console.log(JSON.stringify({ level: "info", message: `health endpoint on :${port}/health` })))
    .unref?.();
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
