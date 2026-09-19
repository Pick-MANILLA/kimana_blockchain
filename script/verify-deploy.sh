#!/usr/bin/env bash
# Post-deployment checks. Read-only: no transactions, no keys.
#
#   NETWORK=base_sepolia VAULT=0x... bash script/verify-deploy.sh
#   NETWORK=base_sepolia VAULT=0x... CURRENCIES=NGN,GHS bash script/verify-deploy.sh
#   ... WRITE_REGISTRY=1   # also writes deployments/<chainId>.json
#
# Compares what is on-chain against .env, and fails if the deployer kept any power.
set -uo pipefail

NETWORK="${NETWORK:-base_sepolia}"
ENV_FILE="${ENV_FILE:-.env}"
VAULT="${VAULT:-${VAULT_ADDRESS:-}}"

PASS=0; WARN=0; FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -f "$ENV_FILE" ] && { set -a; . "./$ENV_FILE"; set +a; }
VAULT="${VAULT:-${VAULT_ADDRESS:-}}"
[[ "$VAULT" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "Set VAULT=0x... (the deployed SettlementVault)" >&2; exit 2; }

lower() { echo "${1:-}" | tr 'A-Z' 'a-z'; }
same()  { [ "$(lower "${1:-x}")" = "$(lower "${2:-y}")" ]; }
call()  { cast call "$VAULT" "$@" --rpc-url "$NETWORK" 2>/dev/null; }

CHAIN=$(cast chain-id --rpc-url "$NETWORK" 2>/dev/null)
echo "Verifying $VAULT on $NETWORK (chain id ${CHAIN:-?})"

head_ "Deployment"
[ "$(cast code "$VAULT" --rpc-url "$NETWORK" 2>/dev/null)" = "0x" ] \
  && { bad "no code at $VAULT on chain $CHAIN"; echo; echo "1 failure"; exit 1; } \
  || ok "contract code present"

ASSET=$(call "asset()(address)")
if same "$ASSET" "${USDC_ADDRESS:-}"; then ok "asset() is USDC_ADDRESS ($ASSET)"
else bad "asset() is $ASSET but .env says ${USDC_ADDRESS:-<unset>}"; fi
ADEC=$(cast call "$ASSET" "decimals()(uint8)" --rpc-url "$NETWORK" 2>/dev/null | awk '{print $1}')
[ "$ADEC" = "6" ] && ok "asset has 6 decimals" || bad "asset has ${ADEC:-?} decimals"

head_ "Roles"
ADMIN=$(call "defaultAdmin()(address)")
if same "$ADMIN" "${ADMIN_ADDRESS:-}"; then ok "defaultAdmin() is the configured admin ($ADMIN)"
else bad "defaultAdmin() is $ADMIN but .env says ${ADMIN_ADDRESS:-<unset>}"; fi
[ "$(cast code "$ADMIN" --rpc-url "$NETWORK" 2>/dev/null)" = "0x" ] \
  && warn "the admin is an EOA, not a Safe - acceptable on a testnet only" \
  || ok "the admin is a contract (expected: a Safe)"

DELAY=$(call "defaultAdminDelay()(uint48)" | awk '{print $1}')
if [ -n "$DELAY" ]; then
  [ "$DELAY" = "${ADMIN_TRANSFER_DELAY:-172800}" ] \
    && ok "admin transfer delay: $((DELAY/3600))h" \
    || warn "admin transfer delay on-chain is ${DELAY}s, .env says ${ADMIN_TRANSFER_DELAY:-172800}s"
fi

check_role() { # ROLE_NAME env_var
  local role_name="$1" var="$2" addr="${!2:-}" role
  role=$(call "${role_name}()(bytes32)")
  [ -z "$role" ] && { bad "cannot read ${role_name}"; return; }
  if [ -z "$addr" ]; then warn "$var not set in .env - skipping ${role_name}"; return; fi
  if [ "$(call "hasRole(bytes32,address)(bool)" "$role" "$addr")" = "true" ]; then ok "${role_name} held by $var"
  else bad "${role_name} is NOT held by $var ($addr)"; fi
}
check_role OPERATOR_ROLE    OPERATOR_ADDRESS
check_role PAUSER_ROLE      PAUSER_ADDRESS
check_role RATE_ORACLE_ROLE RATE_ORACLE_ADDRESS

# The deployer must have walked away with nothing.
if [ -n "${DEPLOYER_ADDRESS:-}" ]; then
  clean=1
  for r in OPERATOR_ROLE PAUSER_ROLE RATE_ORACLE_ROLE; do
    [ "$(call "hasRole(bytes32,address)(bool)" "$(call "${r}()(bytes32)")" "$DEPLOYER_ADDRESS")" = "true" ] \
      && { bad "the deployer holds $r"; clean=0; }
  done
  same "$ADMIN" "$DEPLOYER_ADDRESS" && { bad "the deployer is the admin"; clean=0; }
  [ "$clean" = "1" ] && ok "the deployer holds no roles"
else
  warn "DEPLOYER_ADDRESS unset - cannot confirm the deployer holds no roles"
fi

head_ "Limits and state"
MPS=$(call "maxPerSettlement()(uint256)" | awk '{print $1}')
DL=$(call "dailyLimit()(uint256)" | awk '{print $1}')
[ "$MPS" = "${MAX_PER_SETTLEMENT:-}" ] && ok "maxPerSettlement = $MPS" || bad "maxPerSettlement is $MPS, .env says ${MAX_PER_SETTLEMENT:-<unset>}"
[ "$DL" = "${DAILY_LIMIT:-}" ] && ok "dailyLimit = $DL" || bad "dailyLimit is $DL, .env says ${DAILY_LIMIT:-<unset>}"
[ "$(call "paused()(bool)")" = "false" ] && ok "not paused" || bad "the vault is paused"
RES=$(call "reservedForRefunds()(uint256)" | awk '{print $1}')
[ "${RES:-0}" = "0" ] && ok "nothing reserved for refunds" || warn "reservedForRefunds = $RES (there are open settlements)"
BAL=$(cast call "$ASSET" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$NETWORK" 2>/dev/null | awk '{print $1}')
echo "        float: ${BAL:-0} USDC base units"
echo "        quoteConfig (maxQuoteTtl, referenceMaxAge, maxSettleDelay, alertBps, maxBps):"
echo "        $(call 'quoteConfig()((uint64,uint64,uint64,uint16,uint16))')"

head_ "Currency registry"
CUR_CODES=$(echo "${CURRENCIES:-NGN}" | tr ',' ' ')
CUR_JSON=""
for c in $CUR_CODES; do
  hexc=$(cast --from-utf8 "$c" 2>/dev/null)
  info=$(call "getCurrency(bytes3)((uint8,bool))" "$hexc")
  dec=$(echo "$info" | tr -d '()' | cut -d, -f1 | tr -d ' ')
  en=$(echo "$info" | tr -d '()' | cut -d, -f2 | tr -d ' ')
  if [ "$en" = "true" ]; then
    ok "$c registered with $dec decimals"
    CUR_JSON="$CUR_JSON{ \"code\": \"$c\", \"decimals\": $dec, \"enabled\": true },"
  else
    bad "$c is not enabled - admin must call setCurrency(\"$hexc\", <decimals>, true) from the Safe"
  fi
  rate=$(call "getReferenceRate(bytes3)((uint256,uint64))" "$hexc" | tr -d '()' | cut -d, -f1 | sed 's/\[.*//' | tr -d ' ')
  if [ "${rate:-0}" = "0" ]; then
    warn "$c has no reference rate - divergence checks stay silent (issue #15)"
  else
    ok "$c reference rate: $(awk -v r="$rate" 'BEGIN{printf "%.4f", r/1e8}') $c per USD"
  fi
done

head_ "Partners"
if [ -n "${PARTNER_ADDRESS:-}" ]; then
  [ "$(call "isPartner(address)(bool)" "$PARTNER_ADDRESS")" = "true" ] \
    && ok "PARTNER_ADDRESS is allowlisted" \
    || bad "PARTNER_ADDRESS is not allowlisted - admin must call setPartner($PARTNER_ADDRESS, (onRamp,offRamp,enabled,payoutCurrency))"
else
  warn "PARTNER_ADDRESS unset - settle() reverts until the admin allowlists the off-ramp partner"
fi

# ---------------------------------------------------------------- registry file
if [ "${WRITE_REGISTRY:-0}" = "1" ] && [ -n "$CHAIN" ]; then
  head_ "deployments/$CHAIN.json"
  BLOCK="${DEPLOYED_AT_BLOCK:-$(cast block-number --rpc-url "$NETWORK" 2>/dev/null)}"
  cat > "deployments/$CHAIN.json" <<EOF
{
  "network": "$(echo "$NETWORK" | tr '_' '-')",
  "chainId": $CHAIN,
  "settlementVault": "$(cast to-check-sum-address "$VAULT")",
  "usdc": "$(cast to-check-sum-address "$ASSET")",
  "admin": "$(cast to-check-sum-address "$ADMIN")",
  "operator": "$(cast to-check-sum-address "${OPERATOR_ADDRESS:-0x0000000000000000000000000000000000000000}")",
  "pauser": "$(cast to-check-sum-address "${PAUSER_ADDRESS:-0x0000000000000000000000000000000000000000}")",
  "rateOracle": "$(cast to-check-sum-address "${RATE_ORACLE_ADDRESS:-0x0000000000000000000000000000000000000000}")",
  "deployedAtBlock": $BLOCK,
  "confirmations": ${CONFIRMATIONS:-2},
  "currencies": [ ${CUR_JSON%,} ],
  "limits": { "maxPerSettlement": "$MPS", "dailyLimit": "$DL" },
  "notes": "Generated by script/verify-deploy.sh. Set deployedAtBlock to the deployment block, not the current one."
}
EOF
  ok "written - check deployedAtBlock, then commit it"
fi

printf '\n\033[1m%s\033[0m\n' "$PASS passed, $WARN warnings, $FAIL failures"
[ "$FAIL" -gt 0 ] && exit 1
echo "Hand the backend team: the vault address, chain id $CHAIN, abi/SettlementVault.json, docs/fx-quote-criteria.md."
exit 0
