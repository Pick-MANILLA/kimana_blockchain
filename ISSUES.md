# Kimana Blockchain — Security Remediation Issues

This document outlines the actionable security issues and engineering fixes identified during the Static Application Security Testing (SAST) and smart contract architecture audit of `kimana_blockchain`. Each issue contains exact file locations, technical root causes, step-by-step resolution guides, code patches, and testable acceptance criteria.

---

## Issue Summary

| Issue ID | Severity | Target Contract / File | SWC / CWE | Description |
| :--- | :---: | :--- | :--- | :--- |
| **`ISSUE-BC-01`** | **CRITICAL** | `src/SettlementVault.sol:329` | SWC-105 / CWE-682 | Treasury `sweep()` drains unsettled on-ramp partner float (Vault Insolvency). |
| **`ISSUE-BC-02`** | **HIGH** | `src/SettlementVault.sol:155` | SWC-101 / CWE-664 | Pre-funded partner capital permanently trapped if quote is cancelled. |
| **`ISSUE-BC-03`** | **HIGH** | `src/SettlementVault.sol:413` | SWC-113 / CWE-391 | Rate divergence check silently fails open when oracle rate is stale or uninitialized. |
| **`ISSUE-BC-04`** | **MEDIUM** | `foundry.toml:8`, `script/` | SWC-135 / EVM Spec | Cancun `MCOPY` opcode incompatibility on target L2 rollups (e.g. Polygon Amoy). |
| **`ISSUE-BC-05`** | **MEDIUM** | `test/invariant/Handler.sol` | Invariant Gap | Invariant test suite misses asynchronous funding followed by sweep. |

---

### ISSUE-BC-01: Treasury Sweep Drains Unsettled Partner Float (Vault Insolvency)

**Priority:** Critical (P0)  
**Labels:** `security`, `bug`, `accounting`  
**Files:** `src/SettlementVault.sol`, `src/interfaces/ISettlementVault.sol`, `test/SettlementVault.t.sol`  

#### 1. What the Problem Is
In `SettlementVault.sol`, the admin `sweep()` function calculates unencumbered "free" balance as:
```solidity
uint256 free = asset.balanceOf(address(this)) - reservedForRefunds;
if (amount > free) revert InsufficientFreeBalance(amount, free);
```
When an on-ramp partner delivers funds via `fund(ref, amount)`, the vault accepts USDC and increments `totalFunded`. However, `free` only subtracts `reservedForRefunds`. It does **not** subtract pre-funded deposits that have not yet been settled to payout partners (`totalFunded - totalSettled`).

If treasury admins perform a routine rebalancing sweep, customer-funded float is swept out of the vault. Subsequent calls to `settle(ref, partner, amount)` will revert with ERC20 transfer failures due to insufficient vault balance, halting payments and rendering the vault insolvent.

#### 2. Step-by-Step Resolution Guide
1. **Declare Active Settlement Float Storage:**
   In `SettlementVault.sol`, declare:
   ```solidity
   uint256 public reservedForSettlement;
   ```
2. **Increment on Funding:**
   Inside `fund(bytes32 ref, uint256 amount)`:
   ```solidity
   reservedForSettlement += q.usdcAmount;
   ```
3. **Decrement on Settlement:**
   Inside `settle(bytes32 ref, address partner, uint256 amount)`:
   ```solidity
   reservedForSettlement -= amount;
   ```
4. **Enforce Complete Obligation Deduction in Sweep:**
   Update `sweep(address to, uint256 amount)`:
   ```solidity
   function sweep(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
       if (to == address(0)) revert ZeroAddress();
       if (amount == 0) revert ZeroAmount();
       uint256 totalObligations = reservedForRefunds + reservedForSettlement;
       uint256 currentBalance = asset.balanceOf(address(this));
       if (currentBalance <= totalObligations) revert InsufficientFreeBalance(amount, 0);
       uint256 free = currentBalance - totalObligations;
       if (amount > free) revert InsufficientFreeBalance(amount, free);
       emit Swept(to, amount);
       asset.safeTransfer(to, amount);
   }
   ```
5. **Update Interface & Tests:**
   Add `reservedForSettlement() external view returns (uint256)` to `ISettlementVault.sol`. Add unit tests in `test/SettlementVault.t.sol` verifying that `sweep()` reverts when attempting to sweep funded unsettled float.

#### 3. Acceptance Criteria
- [ ] `reservedForSettlement` increments on every successful `fund()`.
- [ ] `reservedForSettlement` decrements on every successful `settle()`.
- [ ] `sweep()` cannot withdraw any portion of `reservedForSettlement`.
- [ ] Unit test `test_sweep_revertsWhenDrainingFundedFloat()` passes.

---

### ISSUE-BC-02: Pre-Funded Partner Capital Trapped Upon Quote Cancellation

**Priority:** High (P1)  
**Labels:** `security`, `bug`, `partner-risk`  
**Files:** `src/SettlementVault.sol`, `src/interfaces/ISettlementVault.sol`, `test/FundingAndPartners.t.sol`  

#### 1. What the Problem Is
When an on-ramp partner deposits USDC for a transfer via `fund(ref, amount)`, the funds are deposited into the vault. If an operator later calls `cancelQuote(ref)` (e.g. because of a compliance hold or an off-ramp partner outage), `q.cancelled` is set to `true`.
However:
- `settle()` reverts because `q.cancelled == true`.
- `returnSettlement()` reverts because status is `Status.None`, not `Status.Settled`.
- `refund()` reverts because status is `Status.None`, not `Status.Returned`.

The on-ramp partner's deposited capital is permanently trapped inside the vault with no mechanism to claim it back.

#### 2. Step-by-Step Resolution Guide
1. **Prevent Cancelling Funded Quotes without Settlement or Refund:**
   In `cancelQuote(bytes32 ref)`, check if the quote was already funded:
   ```solidity
   error AlreadyFundedCannotCancel(bytes32 ref);
   if (_funding[ref].fundedAt != 0) revert AlreadyFundedCannotCancel(ref);
   ```
2. **Add Dedicated Unsettled Partner Refund Method:**
   Implement `refundUnsettledFunding(bytes32 ref)`:
   ```solidity
   event SettlementFundRefunded(bytes32 indexed ref, address indexed to, uint256 amount);

   function refundUnsettledFunding(bytes32 ref) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
       Funding memory f = _funding[ref];
       if (f.fundedAt == 0) revert NotFunded(ref);
       if (_settlements[ref].status != Status.None) revert RefAlreadyUsed(ref);

       uint256 amount = f.amount;
       LockedQuote storage q = _quotes[ref];
       q.cancelled = true;
       reservedForSettlement -= q.usdcAmount;
       delete _funding[ref];

       emit SettlementFundRefunded(ref, f.partner, amount);
       asset.safeTransfer(f.partner, amount);
   }
   ```
3. **Add Tests:**
   Write a test in `test/FundingAndPartners.t.sol` asserting that cancelling an already-funded quote reverts, and calling `refundUnsettledFunding` refunds the on-ramp partner and decrements `reservedForSettlement`.

#### 3. Acceptance Criteria
- [ ] Direct `cancelQuote()` reverts with `AlreadyFundedCannotCancel` if `_funding[ref].fundedAt != 0`.
- [ ] `refundUnsettledFunding()` correctly returns the deposited USDC to the on-ramp partner address.
- [ ] `reservedForSettlement` is reduced by `q.usdcAmount`.
- [ ] State prevents re-settling or re-refunding the cancelled `ref`.

---

### ISSUE-BC-03: Enforce Fail-Closed Oracle Rate Checks & Divergence Enforcement

**Priority:** High (P1)  
**Labels:** `security`, `oracle`, `risk-control`  
**Files:** `src/SettlementVault.sol`, `test/QuoteLock.t.sol`  

#### 1. What the Problem Is
In `SettlementVault.sol`:
```solidity
function _checkDivergence(bytes32 ref, bytes3 currency, uint256 rate) internal {
    ReferenceRate memory r = _referenceRates[currency];
    if (r.updatedAt == 0 || block.timestamp - r.updatedAt > _quoteConfig.referenceMaxAge) {
        emit ReferenceRateStale(ref, currency, r.updatedAt);
        return; // &lt;-- FAILS OPEN
    }
    // ...
}
```
If the external price oracle drops offline or has not yet posted a reference rate, `_checkDivergence()` logs `ReferenceRateStale` and returns without reverting. Any rogue, manipulated, or fat-finger exchange rate submitted by the operator will be accepted and locked on-chain.

#### 2. Step-by-Step Resolution Guide
1. **Define Revert Error:**
   In `ISettlementVault.sol`:
   ```solidity
   error ReferenceRateUnavailable(bytes3 currency, uint64 updatedAt);
   ```
2. **Convert Fail-Open to Fail-Closed:**
   Update `_checkDivergence`:
   ```solidity
   function _checkDivergence(bytes32 ref, bytes3 currency, uint256 rate) internal {
       ReferenceRate memory r = _referenceRates[currency];
       if (r.updatedAt == 0 || block.timestamp - r.updatedAt > _quoteConfig.referenceMaxAge) {
           revert ReferenceRateUnavailable(currency, r.updatedAt);
       }
       uint256 dev = FxMath.deviationBps(rate, r.rate);
       if (dev > _quoteConfig.divergenceMaxBps) revert RateDivergenceTooHigh(ref, dev, _quoteConfig.divergenceMaxBps);
       if (dev >= _quoteConfig.divergenceAlertBps) emit RateDivergence(ref, currency, rate, r.rate, dev);
   }
   ```
3. **Add Fallback Mode for Stale Rates (Optional Admin Toggle):**
   If business operations require locking during oracle outages, add an explicit admin-controlled flag `allowStaleReferenceRate`, defaulting to `false`.
4. **Update Tests:**
   Update `test/QuoteLock.t.sol` to expect `ReferenceRateUnavailable` when locking against currencies with missing or stale rates.

#### 3. Acceptance Criteria
- [ ] Calling `lockQuote` when `r.updatedAt == 0` reverts with `ReferenceRateUnavailable`.
- [ ] Calling `lockQuote` when `block.timestamp - r.updatedAt > referenceMaxAge` reverts.
- [ ] All existing quote locking tests pass when fresh reference rates are seeded.

---

### ISSUE-BC-04: Multi-Chain EVM Compatibility Configuration for L2 Chains

**Priority:** Medium (P2)  
**Labels:** `devops`, `solidity`, `l2-evm`  
**Files:** `foundry.toml`, `script/DeploySettlementVault.s.sol`  

#### 1. What the Problem Is
`foundry.toml` specifies `evm_version = "cancun"` and `solc_version = "0.8.28"`. Under Cancun EVM, the Solidity compiler generates `MCOPY` opcodes for memory allocations and struct copies. Several target EVM chains listed in `foundry.toml` (e.g. Polygon Amoy, older Arbitrum / Base local node versions) do not support the `MCOPY` opcode, causing deployment or method execution transactions to immediately fail with invalid opcode exceptions.

#### 2. Step-by-Step Resolution Guide
1. **Define Chain-Specific Foundry Profiles:**
   In `foundry.toml`, configure:
   ```toml
   [profile.default]
   solc_version = "0.8.28"
   evm_version = "cancun"

   # L2 Rollups that lack Cancun MCOPY opcode support:
   [profile.shanghai]
   evm_version = "shanghai"
   ```
2. **Update Deployment Script / Makefile:**
   In `Makefile`, add:
   ```makefile
   build-shanghai:
   	FOUNDRY_PROFILE=shanghai forge build --sizes
   ```
3. **Verify Deployment Checks:**
   In `script/preflight.sh`, verify the target chain supports Cancun opcodes before broadcasting.

#### 3. Acceptance Criteria
- [ ] `FOUNDRY_PROFILE=shanghai forge build` compiles cleanly without warnings.
- [ ] CI workflow executes compilation tests under both `cancun` and `shanghai` profiles.

---

### ISSUE-BC-05: Invariant Handler Coverage for Asynchronous Funding and Float Sweeping

**Priority:** Medium (P2)  
**Labels:** `testing`, `foundry`, `invariants`  
**Files:** `test/invariant/SettlementVaultHandler.sol`, `test/invariant/SettlementVault.invariant.t.sol`  

#### 1. What the Problem Is
In `SettlementVaultHandler.sol`, the handler function `fundAndSettle` always executed `fund` and `settle` sequentially in the same handler step. The invariant suite never tested:
`fund()` -> random time elapses / sweep occurs -> `settle()`
Because of this atomic execution in the test handler, the invariant test suite failed to detect that `sweep()` could drain the float before `settle()` is called.

#### 2. Step-by-Step Resolution Guide
1. **Split Handler Actions:**
   In `SettlementVaultHandler.sol`:
   - Implement `fundQuote(uint256 amount)` as a separate handler action.
   - Implement `settleFunded(uint256 index)` as a separate handler action that picks from pending funded refs.
2. **Add Invariant Assertion:**
   In `SettlementVault.invariant.t.sol`:
   ```solidity
   function invariant_activeObligationsAreBacked() public view {
       uint256 totalObligations = vault.reservedForRefunds() + vault.reservedForSettlement();
       assertGe(usdc.balanceOf(address(vault)), totalObligations, "vault under-collateralized");
   }
   ```
3. **Run Invariant Suite:** Run `forge test --match-path "test/invariant/*" -vvv`.

#### 3. Acceptance Criteria
- [ ] Invariant suite runs 256+ runs with independent funding, sweeping, and settling actions.
- [ ] `invariant_activeObligationsAreBacked` passes under random fuzzing sequences.
