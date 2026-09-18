NETWORK ?= base_sepolia

# Dependency versions are pinned here. `lib/` is not committed.
FORGE_STD    := foundry-rs/forge-std@v1.16.2
OPENZEPPELIN := OpenZeppelin/openzeppelin-contracts@v5.4.0

.PHONY: install build test fmt coverage clean abi e2e slither monitor preflight verify

install:
	rm -rf lib
	forge install --no-git $(FORGE_STD) $(OPENZEPPELIN)

build:
	forge build --sizes

test:
	forge test -vvv

fmt:
	forge fmt

coverage:
	forge coverage --report summary --no-match-coverage "(test|script)/"

clean:
	forge clean

# Regenerate the ABI the backend and monitor use
abi:
	forge inspect SettlementVault abi --json > abi/SettlementVault.json

# Local integration test: Anvil + LocalE2E.s.sol + monitor
e2e:
	cd monitor && npm ci --silent
	bash script/e2e-local.sh

# Pre-deployment checks (read-only; no keys, no transactions).
#   make preflight NETWORK=base_sepolia
preflight:
	NETWORK=$(NETWORK) bash script/preflight.sh

# Post-deployment checks against a live vault.
#   make verify NETWORK=base_sepolia VAULT=0x...
verify:
	NETWORK=$(NETWORK) VAULT=$(VAULT) bash script/verify-deploy.sh

slither:
	slither . --config-file slither.config.json

# Watch a deployed vault (needs RPC_URL and VAULT_ADDRESS)
monitor:
	cd monitor && npm ci --silent && node index.mjs
