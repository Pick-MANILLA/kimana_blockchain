# Dependency versions are pinned here. `lib/` is not committed.
FORGE_STD    := foundry-rs/forge-std@v1.16.2
OPENZEPPELIN := OpenZeppelin/openzeppelin-contracts@v5.4.0

.PHONY: install build test fmt coverage clean abi e2e slither monitor

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

slither:
	slither . --config-file slither.config.json

# Watch a deployed vault (needs RPC_URL and VAULT_ADDRESS)
monitor:
	cd monitor && npm ci --silent && node index.mjs
