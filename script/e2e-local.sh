#!/usr/bin/env bash
# Local integration test: Anvil + LocalE2E.s.sol + monitor.
# Verifies the on-chain quote/settlement flow and that the monitor raises the expected alerts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${ANVIL_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
LOG="$(mktemp)"

anvil --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true; rm -f "$LOG"' EXIT
for _ in $(seq 1 50); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

cd "$ROOT"
forge script script/LocalE2E.s.sol --rpc-url "$RPC" --broadcast --slow > "$LOG" 2>&1 || { cat "$LOG"; exit 1; }
VAULT=$(grep -E '^\s*VAULT ' "$LOG" | awk '{print $2}')
REF1=$(grep -A1 -E '^\s*REF1$' "$LOG" | tail -1 | tr -d ' ')
REF2=$(grep -A1 -E '^\s*REF2$' "$LOG" | tail -1 | tr -d ' ')
echo "vault=$VAULT"

fail() { echo "E2E FAILED: $*"; exit 1; }

# On-chain state
STATUS=$(cast call "$VAULT" "getSettlement(bytes32)((address,uint64,uint8,uint256))" "$REF1" --rpc-url "$RPC" | tr -d '()' | awk -F', ' '{print $3}')
[ "$STATUS" = "3" ] || fail "ref1 status is $STATUS, expected 3 (Refunded)"
[ "$(cast call "$VAULT" "paused()(bool)" --rpc-url "$RPC")" = "true" ] || fail "vault should be paused"
[ "$(cast call "$VAULT" "reservedForRefunds()(uint256)" --rpc-url "$RPC")" = "0" ] || fail "reserved should be 0"
LOCKED2=$(cast call "$VAULT" "getQuote(bytes32)((bytes32,bytes3,uint8,bool,uint64,uint64,uint256,uint256,uint256,uint256))" "$REF2" --rpc-url "$RPC")
echo "$LOCKED2" | grep -q "167815500000" || fail "ref2 quote not locked at divergent rate: $LOCKED2"

# A quote 6% away from the reference rate must be blocked on-chain (and alerted by the monitor).
ADMIN_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
OPERATOR_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
cast send "$VAULT" "unpause()" --private-key "$ADMIN_PK" --rpc-url "$RPC" >/dev/null
NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
REF3=$(cast keccak "kimana:transfer:e2e_txn_003")
QID3=$(cast keccak "e2e_quote_003")
RATE3=174396500000          # 1,645.25 * 1.06
AMT3=1000000000             # 1,000 USDC
RECV3=174396500             # floor(AMT3 * RATE3 * 100 / 1e14)
EXP3=$((NOW + 90))
cast send "$VAULT" "lockQuote(bytes32,(bytes32,bytes3,uint64,uint256,uint256,uint256,uint256))" "$REF3" \
  "($QID3,0x4e474e,$EXP3,$RATE3,$AMT3,0,$RECV3)" \
  --gas-limit 500000 --private-key "$OPERATOR_PK" --rpc-url "$RPC" >/dev/null 2>&1 || true
[ "$(cast call "$VAULT" "isQuoteUsed(bytes32)(bool)" "$QID3" --rpc-url "$RPC")" = "false" ] || fail "divergent quote was not blocked"

# Monitor
OUT=$(cd monitor && RPC_URL="$RPC" VAULT_ADDRESS="$VAULT" START_BLOCK=0 MIN_FLOAT_USDC=2000000 node index.mjs --once)
echo "$OUT" | tail -1
node -e '
const lines = process.argv[1].trim().split("\n").map(JSON.parse);
const summary = lines.at(-1);
const has = (e, lvl) => lines.some(l => l.event === e && (!lvl || l.level === lvl));
const need = [
  ["QuoteLocked"], ["SettlementInitiated"], ["SettlementReturned", "warning"], ["SettlementRefunded"],
  ["RateDivergence", "warning"], ["Paused", "critical"], ["Unpaused", "warning"], ["ReferenceRateUpdated"],
  ["FloatCheck", "warning"], ["TransactionReverted", "critical"],
];
const missing = need.filter(([e, l]) => !has(e, l)).map(([e, l]) => e + (l ? "/" + l : ""));
if (missing.length) { console.error("missing:", missing); process.exit(1); }
if (summary.counts.QuoteLocked !== 2) { console.error("expected 2 QuoteLocked", summary.counts); process.exit(1); }
const div = lines.find(l => l.event === "RateDivergence");
if (div.args.deviationBps !== "200" || div.args.currency !== "NGN") { console.error("bad divergence", div); process.exit(1); }
const rev = lines.find(l => l.event === "TransactionReverted");
if (rev.args.function !== "lockQuote" || rev.args.error !== "RateDivergenceTooHigh") { console.error("bad revert alert", rev); process.exit(1); }
console.log("monitor checks passed:", summary.alerts, "alerts");
' "$OUT"
echo "E2E PASSED"
