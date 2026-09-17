# Dependency versions are pinned here. `lib/` is not committed.
FORGE_STD    := foundry-rs/forge-std@v1.16.2
OPENZEPPELIN := OpenZeppelin/openzeppelin-contracts@v5.4.0

.PHONY: install build test fmt coverage clean

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
