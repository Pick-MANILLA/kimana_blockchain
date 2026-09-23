# Contributing to kimana_contract

Thanks for helping build Kimana's settlement layer. This code moves real money, so the bar is high but clear.

## Workflow

1. Pick an open issue. Comment to claim it and wait for a maintainer to assign you.
2. Fork the repo, or branch from `main` if you have access: `feat/<issue-number>-short-name`.
3. Keep PRs small, with one issue per PR. Reference the issue (`Closes #12`).
4. CI must be green. A maintainer must review and approve before merge.

## Local checks (run all before pushing)

```bash
make install            # first time only
forge fmt
forge build --sizes
forge test -vvv
forge coverage          # new code should be covered
FOUNDRY_PROFILE=ci forge snapshot --check --no-match-path 'test/{fork,invariant}/*' --tolerance 1
```

### Gas snapshots

`forge snapshot` records each test's gas usage in the committed `.gas-snapshot` file. CI runs
`forge snapshot --check` over the **unit tests only** and fails if gas usage changes without the
snapshot being refreshed, so refresh it whenever you touch code that affects gas. Fork and invariant
tests are excluded on purpose: fork tests are skipped without an RPC and record zero gas, and
invariant runs record a revert count that differs on every seed. Generate with the `ci` profile so it
matches CI, and with the same Foundry release CI pins (`FOUNDRY_VERSION` in
`.github/workflows/test.yml`) — gas accounting differs between Foundry versions, so a snapshot taken
on a different one will not match:

```bash
FOUNDRY_PROFILE=ci forge snapshot --no-match-path 'test/{fork,invariant}/*'
```

Then re-run the check to confirm it is clean:

```bash
FOUNDRY_PROFILE=ci forge snapshot --check --no-match-path 'test/{fork,invariant}/*' --tolerance 1
```

## Rules for contract code

- **Solidity 0.8.28**, OpenZeppelin v5. No new dependencies without discussion.
- **Integer money only.** USDC has 6 decimals; use `UsdcUnits` when converting from cents.
- **Custom errors**, not revert strings.
- **Checks-effects-interactions.** Update state and emit events before external calls; keep `nonReentrant` on functions that move funds.
- **Every function that moves funds** needs:
  - a unit test for the happy path;
  - a unit test for every revert branch;
  - a fuzz test when it takes amounts;
  - an update to the invariant handler when it changes accounting.
- **No private keys** in code, scripts, tests (except Anvil defaults) or `.env`. Use `cast wallet` keystores.
- **NatSpec** on every external function and event.
- If you change the ABI or events, update `docs/architecture.md` and mention it in the PR, because the backend depends on them.

## Commit style

Conventional commits: `feat:`, `fix:`, `test:`, `docs:`, `chore:`, `ci:`.

## Security

Found a vulnerability? Do **not** open a public issue. Contact the maintainers privately.
