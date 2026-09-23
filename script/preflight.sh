#!/usr/bin/env bash
# Pre-deployment checks. Run this before `forge script script/DeploySettlementVault.s.sol`.
# Nothing here sends a transaction or needs a private key.
#
#   NETWORK=base_sepolia bash script/preflight.sh
#   NETWORK=base_sepolia DEPLOYER_ADDRESS=0x... bash script/preflight.sh   # also checks gas balance
#   NETWORK=base SKIP_TESTS=1 bash script/preflight.sh                     # skip `forge test`
#
# Reads the same .env the deploy script reads. See docs/runbooks/deploy.md.
set -uo pipefail

NETWORK="${NETWORK:-base_sepolia}"
ENV_FILE="${ENV_FILE:-.env}"

PASS=0
WARN=0
FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1";   PASS=$((PASS+1)); }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1";   WARN=$((WARN+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1";   FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Expected chain id per foundry.toml alias, and whether it is a real-money network.
case "$NETWORK" in
  anvil)            EXPECT_CHAIN=31337;    MAINNET=0; EXPLORER="(local)" ;;
  base_sepolia)     EXPECT_CHAIN=84532;    MAINNET=0; EXPLORER="https://sepolia.basescan.org" ;;
  arbitrum_sepolia) EXPECT_CHAIN=421614;   MAINNET=0; EXPLORER="https://sepolia.arbiscan.io" ;;
  polygon_amoy)     EXPECT_CHAIN=80002;    MAINNET=0; EXPLORER="https://amoy.polygonscan.com" ;;
  sepolia)          EXPECT_CHAIN=11155111; MAINNET=0; EXPLORER="https://sepolia.etherscan.io" ;;
  base)             EXPECT_CHAIN=8453;     MAINNET=1; EXPLORER="https://basescan.org" ;;
  arbitrum)         EXPECT_CHAIN=42161;    MAINNET=1; EXPLORER="https://arbiscan.io" ;;
  polygon)          EXPECT_CHAIN=137;      MAINNET=1; EXPLORER="https://polygonscan.com" ;;
  mainnet)          EXPECT_CHAIN=1;        MAINNET=1; EXPLORER="https://etherscan.io" ;;
  *) echo "Unknown NETWORK '$NETWORK'. Use an alias from foundry.toml [rpc_endpoints]." >&2; exit 2 ;;
esac

echo "Preflight for SettlementVault on: $NETWORK (expected chain id $EXPECT_CHAIN)"

# ---------------------------------------------------------------- toolchain
head_ "Toolchain"
for bin in forge cast; do
  if command -v "$bin" >/dev/null 2>&1; then ok "$bin: $($bin --version 2>/dev/null | head -1)"
  else bad "$bin not found - install Foundry (https://book.getfoundry.sh)"; fi
done
[ -d lib/forge-std ] && [ -d lib/openzeppelin-contracts ] && ok "dependencies installed in lib/" \
  || bad "lib/ is missing - run: make install"

# ---------------------------------------------------------------- env file
head_ "Configuration ($ENV_FILE)"
if [ -f "$ENV_FILE" ]; then
  ok "$ENV_FILE exists"
  set -a; . "./$ENV_FILE"; set +a
else
  bad "$ENV_FILE not found - run: cp .env.example .env"
fi

if grep -Eq '^[[:space:]]*(PRIVATE_KEY|DEPLOYER_PRIVATE_KEY|OPERATOR_KEY|ORACLE_KEY|PARTNER_KEY)=.+' "$ENV_FILE" 2>/dev/null; then
  bad "$ENV_FILE contains a private key - remove it and use: cast wallet import kimana-deployer --interactive"
else
  ok "no private key in $ENV_FILE"
fi

is_addr() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
require_addr() { # name
  local name="$1" v="${!1:-}"
  if [ -z "$v" ]; then bad "$name is not set"; return 1; fi
  if ! is_addr "$v"; then bad "$name is not a 20-byte address: $v"; return 1; fi
  if [ "${v,,}" = "0x0000000000000000000000000000000000000000" ]; then bad "$name is the zero address"; return 1; fi
  ok "$name = $(cast to-check-sum-address "$v" 2>/dev/null || echo "$v")"
}
require_addr USDC_ADDRESS
require_addr ADMIN_ADDRESS
require_addr OPERATOR_ADDRESS
require_addr PAUSER_ADDRESS
if [ -n "${RATE_ORACLE_ADDRESS:-}" ]; then require_addr RATE_ORACLE_ADDRESS
else warn "RATE_ORACLE_ADDRESS unset - no reference rates, so divergence alerts stay silent until admin grants RATE_ORACLE_ROLE"; fi

# Distinct roles: one key holding two roles defeats the separation.
dupes=$(printf '%s\n' "${ADMIN_ADDRESS:-a}" "${OPERATOR_ADDRESS:-b}" "${PAUSER_ADDRESS:-c}" "${RATE_ORACLE_ADDRESS:-d}" \
  | tr 'A-Z' 'a-z' | sort | uniq -d)
[ -z "$dupes" ] && ok "admin, operator, pauser and oracle are four different addresses" \
  || bad "the same address holds more than one role: $dupes"

# Limits
if [ -n "${MAX_PER_SETTLEMENT:-}" ] && [ -n "${DAILY_LIMIT:-}" ]; then
  if [ "$MAX_PER_SETTLEMENT" -gt 0 ] 2>/dev/null && [ "$DAILY_LIMIT" -ge "$MAX_PER_SETTLEMENT" ] 2>/dev/null; then
    usdc6() { awk -v v="$1" 'BEGIN{printf "%\047.2f", v/1000000}' 2>/dev/null || echo "$1"; }
    ok "limits: \$$(usdc6 "$MAX_PER_SETTLEMENT") per settlement, \$$(usdc6 "$DAILY_LIMIT") per day"
  else
    bad "limits invalid: need 0 < MAX_PER_SETTLEMENT <= DAILY_LIMIT (got $MAX_PER_SETTLEMENT / $DAILY_LIMIT)"
  fi
else
  bad "MAX_PER_SETTLEMENT and DAILY_LIMIT must both be set (USDC base units, 6 decimals)"
fi

DELAY="${ADMIN_TRANSFER_DELAY:-172800}"
if [ "$DELAY" -ge 86400 ] 2>/dev/null; then ok "admin transfer delay: $((DELAY/3600))h"
elif [ "$MAINNET" -eq 1 ]; then bad "ADMIN_TRANSFER_DELAY is $DELAY s - use at least 1 day on a mainnet"
else warn "ADMIN_TRANSFER_DELAY is $DELAY s - short, but acceptable on a testnet"; fi

rpc_var="$(echo "$NETWORK" | tr 'a-z' 'A-Z')_RPC_URL"
if [ "$NETWORK" = "anvil" ]; then
  ok "anvil: foundry.toml points the alias at http://127.0.0.1:8545"
else
  [ -n "${!rpc_var:-}" ] && ok "$rpc_var is set" || bad "$rpc_var is empty - foundry.toml resolves the '$NETWORK' alias from it"
  [ -n "${ETHERSCAN_API_KEY:-}" ] && ok "ETHERSCAN_API_KEY is set (needed for --verify)" \
    || warn "ETHERSCAN_API_KEY is empty - deploy without --verify, then verify later"
fi

# ---------------------------------------------------------------- chain
head_ "Chain"
CHAIN=$(cast chain-id --rpc-url "$NETWORK" 2>/dev/null)
if [ -z "$CHAIN" ]; then
  bad "cannot reach the RPC for '$NETWORK' - check $rpc_var"
elif [ "$CHAIN" != "$EXPECT_CHAIN" ]; then
  bad "RPC reports chain id $CHAIN, expected $EXPECT_CHAIN - $rpc_var points at the wrong network"
else
  ok "chain id $CHAIN, block $(cast block-number --rpc-url "$NETWORK" 2>/dev/null)"
fi

# --------------------------------------------------------- EVM compatibility
# Issue #25. `evm_version` is compiled into the bytecode. Under cancun, solc emits MCOPY (EIP-5656)
# for memory copies; a chain that has not activated Cancun rejects it as an invalid opcode. That
# surfaces either as a failed deployment or -- worse -- as a vault that deploys and then reverts on
# the first call that copies memory. Prove the chain runs the opcodes before anyone spends gas.
head_ "EVM compatibility"
EVM_VERSION=$(forge config --json 2>/dev/null | jq -r '.evm_version // empty')
if [ -z "$EVM_VERSION" ]; then
  warn "could not read evm_version from foundry.toml"
else
  ok "building for evm_version '$EVM_VERSION'"
fi
case "$EVM_VERSION" in
  cancun|prague|osaka)
    if [ -z "$CHAIN" ]; then
      warn "skipping the opcode probe - the RPC did not answer above"
    else
      # eth_call on throwaway init code that performs one MCOPY and returns. No transaction, no key,
      # no state change. Returns 0x00 where Cancun is live; reverts with an invalid-opcode error where
      # it is not.
      MCOPY_PROBE=0x6020600060405e60016000f3
      if cast call --rpc-url "$NETWORK" --create "$MCOPY_PROBE" >/dev/null 2>&1; then
        ok "chain executes MCOPY - Cancun is live here, '$EVM_VERSION' bytecode will run"
      else
        bad "chain rejects MCOPY - it has not activated Cancun, so '$EVM_VERSION' bytecode will not run.
        Build and deploy with the fallback profile instead:  FOUNDRY_PROFILE=shanghai forge build --sizes
        Note the bytecode differs from the default profile, so verify with the same profile."
      fi
    fi
    ;;
  *)
    ok "'$EVM_VERSION' predates Cancun - no MCOPY, nothing to probe"
    ;;
esac

# ---------------------------------------------------------------- the token
head_ "Settlement token"
if [ -n "$CHAIN" ] && is_addr "${USDC_ADDRESS:-}"; then
  if [ "$(cast code "$USDC_ADDRESS" --rpc-url "$NETWORK" 2>/dev/null)" = "0x" ]; then
    bad "USDC_ADDRESS has no code on chain $CHAIN - wrong address or wrong network (see docs/networks.md)"
  else
    DEC=$(cast call "$USDC_ADDRESS" "decimals()(uint8)" --rpc-url "$NETWORK" 2>/dev/null | awk '{print $1}')
    SYM=$(cast call "$USDC_ADDRESS" "symbol()(string)" --rpc-url "$NETWORK" 2>/dev/null | tr -d '"')
    if [ "$DEC" = "6" ]; then ok "token $SYM has 6 decimals"
    else bad "token $SYM has ${DEC:-?} decimals - the constructor reverts with UnsupportedAssetDecimals; this is not native USDC"; fi
    case "${SYM^^}" in
      USDC) ok "symbol is USDC" ;;
      "")   warn "could not read symbol()" ;;
      *)    warn "symbol is '$SYM', not USDC - confirm against docs/networks.md" ;;
    esac
  fi
fi

# ---------------------------------------------------------------- the roles
head_ "Role holders"
if [ -n "$CHAIN" ]; then
  if is_addr "${ADMIN_ADDRESS:-}"; then
    if [ "$(cast code "$ADMIN_ADDRESS" --rpc-url "$NETWORK" 2>/dev/null)" = "0x" ]; then
      if [ "$MAINNET" -eq 1 ]; then bad "ADMIN_ADDRESS is an EOA - the admin must be a Safe multisig on a mainnet"
      else warn "ADMIN_ADDRESS is an EOA, not a Safe - fine for a testnet, never for a mainnet"; fi
    else
      ok "ADMIN_ADDRESS is a contract (expected: a Safe)"
    fi
  fi
  for v in OPERATOR_ADDRESS PAUSER_ADDRESS RATE_ORACLE_ADDRESS; do
    a="${!v:-}"; is_addr "$a" || continue
    bal=$(cast balance "$a" --rpc-url "$NETWORK" 2>/dev/null)
    if [ "${bal:-0}" = "0" ]; then warn "$v has no gas - it cannot send transactions yet"
    else ok "$v has $(awk -v b="$bal" 'BEGIN{printf "%.4f", b/1e18}') native token"; fi
  done
  if [ -n "${DEPLOYER_ADDRESS:-}" ] && is_addr "$DEPLOYER_ADDRESS"; then
    bal=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$NETWORK" 2>/dev/null)
    if [ "${bal:-0}" = "0" ]; then bad "DEPLOYER_ADDRESS has no gas - fund it before deploying"
    else ok "deployer has $(awk -v b="$bal" 'BEGIN{printf "%.4f", b/1e18}') native token for gas"; fi
    for v in ADMIN_ADDRESS OPERATOR_ADDRESS PAUSER_ADDRESS RATE_ORACLE_ADDRESS; do
      [ "${!v:-x}" = "$DEPLOYER_ADDRESS" ] && bad "DEPLOYER_ADDRESS is also $v - the deployer must hold no roles"
    done
  else
    warn "DEPLOYER_ADDRESS unset - skipping the gas check. Get it with: cast wallet address --account kimana-deployer"
  fi
fi

# ---------------------------------------------------------------- the code
head_ "Contracts"
if [ "${SKIP_TESTS:-0}" = "1" ]; then
  warn "forge test skipped (SKIP_TESTS=1)"
else
  if forge test >/tmp/preflight-test.log 2>&1; then
    ok "forge test: $(grep -Eo '[0-9]+ tests passed' /tmp/preflight-test.log | tail -1 | head -1)"
  else
    bad "forge test failed - see /tmp/preflight-test.log"
  fi
fi
if forge inspect SettlementVault abi --json 2>/dev/null | diff -q - abi/SettlementVault.json >/dev/null 2>&1; then
  ok "abi/SettlementVault.json matches the contract"
else
  bad "abi/SettlementVault.json is stale - run: make abi"
fi

# ---------------------------------------------------------------- mainnet gates
if [ "$MAINNET" -eq 1 ]; then
  head_ "Mainnet gates"
  grep -qi 'audit.*complete\|audit report' docs/security/review.md 2>/dev/null \
    && warn "check docs/security/review.md: has the external audit (#14) actually been signed off?" \
    || bad "no external audit recorded in docs/security/review.md - mainnet deployment is blocked (issue #14)"
  bad "confirm regulatory and partner approvals with the product lead before deploying to $NETWORK"
fi

# ---------------------------------------------------------------- verdict
printf '\n\033[1m%s\033[0m\n' "$PASS passed, $WARN warnings, $FAIL failures"
if [ "$FAIL" -gt 0 ]; then
  echo "Fix the failures above before deploying."
  exit 1
fi
cat <<EOF
Ready. Deploy with:

  source $ENV_FILE
  forge script script/DeploySettlementVault.s.sol \\
    --rpc-url $NETWORK --account kimana-deployer --broadcast --verify

Then: NETWORK=$NETWORK VAULT=<address> bash script/verify-deploy.sh
Explorer: $EXPLORER
EOF
