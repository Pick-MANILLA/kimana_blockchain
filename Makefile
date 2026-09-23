NETWORK ?= base_sepolia

# Dependency versions are pinned here. `lib/` is not committed.
FORGE_STD    := foundry-rs/forge-std@v1.16.2
OPENZEPPELIN := OpenZeppelin/openzeppelin-contracts@v5.4.0

.PHONY: install build test fmt coverage clean abi e2e slither monitor preflight verify float oracle

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

# Everything a client needs to talk to the vault and to explain what it said when it refused.
abi:
	forge inspect SettlementVault abi --json > abi/SettlementVault.json
	bash script/error-selectors.sh > abi/SettlementVault.errors.json
	bash script/storage-layout.sh > abi/SettlementVault.storage.json

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

# On-demand treasury report.
#   make float NETWORK=base_sepolia VAULT=0x...
float:
	VAULT_ADDRESS=$(VAULT) forge script script/FloatReport.s.sol --rpc-url $(NETWORK)

# Rate oracle service (needs RPC_URL, VAULT_ADDRESS and a signer; see oracle/README.md)
oracle:
	cd oracle && npm ci --silent && node index.mjs

slither:
	slither . --config-file slither.config.json

# Watch a deployed vault (needs RPC_URL and VAULT_ADDRESS)
monitor:
	cd monitor && npm ci --silent && node index.mjs
