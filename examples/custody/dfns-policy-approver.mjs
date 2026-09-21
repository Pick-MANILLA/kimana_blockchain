/**
 * dfns-policy-approver.mjs — Programmable approver for Kimana operator / oracle wallets
 *
 * Dfns does not have a native "allow only function selector X" policy rule.
 * The supported workaround is a programmable approver: a service account that
 * intercepts every pending signing request, decodes the ABI calldata, and
 * approves or rejects it based on the function selector and arguments.
 *
 * How it works:
 *   1. In Dfns Console, create policies for the operator and oracle wallets
 *      with action = "RequestApproval" (not "AutoApproval").
 *   2. Add this service account as an approver in the policy.
 *   3. This process polls for pending approval requests, decodes each one,
 *      and calls the Dfns approval API to approve or reject.
 *
 * Reference:
 *   https://docs.dfns.co/solutions/build-programmable-approval-policies
 *
 * IMPORTANT:
 *   - This is a skeleton / reference implementation, not production code.
 *   - The DFNS_APP_PRIVATE_KEY_PATH must be the service-account approver
 *     credential, not the operator wallet credential.
 *   - Run alongside the main backend service, not as a one-shot script.
 *
 * Usage:
 *   node dfns-policy-approver.mjs
 */

import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";
import { Interface } from "ethers";
import "dotenv/config";

const {
  DFNS_APP_ID,
  DFNS_CRED_ID,
  DFNS_APP_PRIVATE_KEY_PATH,
  DFNS_AUTH_TOKEN,
  DFNS_BASE_URL = "https://api.dfns.io",
  OPERATOR_WALLET_ID,
  ORACLE_WALLET_ID,
  VAULT_ADDRESS,
  APPROVER_POLL_MS = "2000",
} = process.env;

const POLL_MS = parseInt(APPROVER_POLL_MS, 10);

// ---------------------------------------------------------------------------
// Allowed functions per wallet
// ---------------------------------------------------------------------------

import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const VAULT_ABI = require("./abi.json");

const iface = new Interface(VAULT_ABI);

/**
 * Function selectors (first 4 bytes of keccak256(signature)) that each wallet
 * role is permitted to call.
 *
 * This is the enforcement point for the PRD requirement:
 *   - OPERATOR_ROLE: lockQuote, cancelQuote, settle, refund only
 *   - RATE_ORACLE_ROLE: setReferenceRate only
 */
const ALLOWED_SELECTORS = {
  [OPERATOR_WALLET_ID]: new Set([
    iface.getFunction("lockQuote").selector,
    iface.getFunction("cancelQuote").selector,
    iface.getFunction("settle").selector,
    iface.getFunction("refund").selector,
  ]),
  [ORACLE_WALLET_ID]: new Set([
    iface.getFunction("setReferenceRate").selector,
  ]),
};

// ---------------------------------------------------------------------------
// Dfns API helpers (duplicated from dfns-poc.mjs for self-contained clarity)
// ---------------------------------------------------------------------------

async function signUserAction(body) {
  const privateKeyPem = readFileSync(DFNS_APP_PRIVATE_KEY_PATH, "utf8");

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
    throw new Error(`Dfns challenge failed: ${await challengeRes.text()}`);
  }

  const { challenge } = await challengeRes.json();
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
    headers["X-DFNS-USERACTION"] = Buffer.from(
      JSON.stringify(assertion)
    ).toString("base64url");
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
// Approval logic
// ---------------------------------------------------------------------------

/**
 * Decide whether to approve or reject a pending policy approval request.
 *
 * @param {object} approval  Dfns policy approval object
 * @returns {{ approve: boolean, reason: string }}
 */
function evaluate(approval) {
  const walletId = approval.activity?.walletId;
  const allowed = ALLOWED_SELECTORS[walletId];

  if (!allowed) {
    return {
      approve: false,
      reason: `Unknown wallet ${walletId} — not in approver allowlist`,
    };
  }

  // The transaction data is in approval.activity.request.transaction.data
  const calldata = approval.activity?.request?.transaction?.data ?? "";
  if (!calldata || calldata.length < 10) {
    // No calldata or less than 4 bytes — not a contract call; reject
    return {
      approve: false,
      reason: "No calldata or calldata too short to decode function selector",
    };
  }

  // Extract 4-byte function selector (0x + 8 hex chars)
  const selector = calldata.slice(0, 10).toLowerCase();

  if (!allowed.has(selector)) {
    let funcName = "(unknown)";
    try {
      funcName = iface.parseTransaction({ data: calldata })?.name ?? "(unknown)";
    } catch {
      // best effort
    }
    return {
      approve: false,
      reason: `Function ${funcName} (${selector}) is not in the allowlist for wallet ${walletId}`,
    };
  }

  // Verify the destination is the vault (defence-in-depth)
  const destination = approval.activity?.request?.transaction?.to ?? "";
  if (
    VAULT_ADDRESS &&
    destination.toLowerCase() !== VAULT_ADDRESS.toLowerCase()
  ) {
    return {
      approve: false,
      reason: `Destination ${destination} is not the vault ${VAULT_ADDRESS}`,
    };
  }

  let funcName = "(unknown)";
  try {
    funcName = iface.parseTransaction({ data: calldata })?.name ?? "(unknown)";
  } catch {
    // best effort
  }

  return {
    approve: true,
    reason: `Approved: ${funcName} (${selector}) to ${destination}`,
  };
}

/**
 * Fetch all pending approvals and resolve each one.
 */
async function processPendingApprovals() {
  // List policy approvals that are in Pending state
  const { items = [] } = await dfns("GET", "/policies/approvals?status=Pending");

  for (const approval of items) {
    const { approve, reason } = evaluate(approval);
    const decision = approve ? "Approve" : "Reject";

    console.log(
      `[approver] ${decision} approval ${approval.id}: ${reason}`
    );

    const body = JSON.stringify({
      approvalId: approval.id,
      decision,
      reason,
    });

    try {
      await dfns(
        "PUT",
        `/policies/approvals/${approval.id}`,
        { decision, reason },
        true /* requiresAction */
      );
    } catch (err) {
      console.error(
        `[approver] Failed to resolve approval ${approval.id}: ${err.message}`
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Poll loop
// ---------------------------------------------------------------------------

async function run() {
  console.log(
    `[approver] Starting. Polling every ${POLL_MS} ms for pending approvals.`
  );
  console.log(`[approver] Operator wallet : ${OPERATOR_WALLET_ID}`);
  console.log(`[approver] Oracle wallet   : ${ORACLE_WALLET_ID}`);
  console.log(`[approver] Vault address   : ${VAULT_ADDRESS}`);
  console.log();

  // Validate selectors are resolvable
  for (const [walletId, selectors] of Object.entries(ALLOWED_SELECTORS)) {
    console.log(`[approver] Wallet ${walletId} allowed selectors:`);
    for (const sel of selectors) {
      const name = [...Object.values(iface.functions)].find(
        (f) => f.selector === sel
      )?.name ?? sel;
      console.log(`  ${sel}  (${name})`);
    }
  }
  console.log();

  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await processPendingApprovals();
    } catch (err) {
      console.error(`[approver] Poll error: ${err.message}`);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
